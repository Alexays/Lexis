import Foundation
import os
import os.signpost

private let measurementLog = Logger(
    subsystem: PipelineSignposts.subsystem, category: "measure"
)

/// Where a run driven by XCTest leaves its trace. Nothing on the Mac can
/// stream a device's unified log and XCTest owns the app's stdout, so the
/// only channel that survives that launch is a file to fetch afterwards with
/// `devicectl device copy from`. Caches rather than Documents: tvOS gives an
/// app no Documents directory to write to at all. Off unless asked for: an
/// app that always wrote a log file would be doing it for every viewer
/// forever.
private let traceFile: FileHandle? = {
    guard ProcessInfo.processInfo.environment["LEXIS_TRACE_FILE"] == "1",
          let directory = FileManager.default.urls(
              for: .cachesDirectory, in: .userDomainMask
          ).first
    else { return nil }
    let url = directory.appendingPathComponent("lexis-trace.log")
    if !FileManager.default.fileExists(atPath: url.path) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    let handle = try? FileHandle(forWritingTo: url)
    handle?.seekToEndOfFile()
    return handle
}()

/// Serial, so lines land in the order they were traced.
private let traceQueue = DispatchQueue(label: "org.lexis.player.trace", qos: .utility)

/// One line of measurement, on every channel a device offers. `print` reaches
/// a console attached with `devicectl --console`, the unified log reaches
/// Console and Instruments, and the file is what a run driven by XCTest
/// leaves behind. Public so the app layer shares the one form.
///
/// Only ever called once per open stage, once per memory warning, or once per
/// window of frames: never per packet and never per frame.
/// Wall clock, because the only way to place the bridge's own first moment
/// against a press that happened outside this process is a clock both sides
/// can read.
private let traceClock: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    return formatter
}()

public func traceLine(_ line: String) {
    // The moment is read on the caller's thread; the formatter, the console,
    // the log and the file run off it, since pipeline threads trace too.
    let now = Date()
    traceQueue.async {
        let line = "\(traceClock.string(from: now)) \(line)"
        print(line)
        measurementLog.info("\(line, privacy: .public)")
        guard let traceFile, let bytes = (line + "\n").data(using: .utf8) else { return }
        try? traceFile.write(contentsOf: bytes)
    }
}

/// Every stage of one press-play, in the order a viewer waits through them.
/// The pull pipeline's own stages (`PipelineSignposts`) only start once the
/// first of these has finished, which is why they never showed where the
/// seconds before a picture went.
public enum OpenStage: String {
    /// The bridge's `open` to FFmpeg being handed the stream: the hop onto
    /// the control queue, the previous file's close, and the AVIO buffer.
    case handoff
    /// `avformat_open_input`, which is where the first bytes are pulled
    /// through the stream and the container header is parsed.
    case formatOpen = "format open"
    /// `avformat_find_stream_info`, which reads far enough in to describe
    /// every track.
    case streamInfo = "stream info"
    /// The format description, the memory budget and the tone-mapping
    /// session: everything built once per file before a packet moves.
    case adopt
    /// Our own `preferredDisplayCriteria` write, on the main thread.
    case displayWrite = "display write"
    /// The display renegotiating HDMI afterwards. Ours to wait for, not ours
    /// to spend: kept apart from `displayWrite` so a slow screen is never
    /// read as slow code.
    case displaySettle = "display settle"
    /// `play()` to the first picture crossing the sink.
    case firstFrame = "first frame"
}

/// One press-play, timed stage by stage. Instruments reads the signpost
/// intervals, and whoever has only a console reads the printed lines, which
/// is how this project is diagnosed on the device.
///
/// Every stage runs once per open, so a `print` here costs a line a playback
/// and never sits on a hot path - unlike `PipelineSignposts`, which fires per
/// packet and is signposts only.
///
/// Off unless a playback open turned it on: the thumbnail strip decoder and
/// the decode-only probe build demuxers of their own, and their stages are
/// not what a viewer is waiting through.
public final class OpenTrace {
    public static let shared = OpenTrace()

    private let lock = NSLock()
    private var origin: DispatchTime?
    private var previous: DispatchTime?
    private var running: (stage: OpenStage, state: OSSignpostIntervalState)?
    private let signpostID = PipelineSignposts.startup.makeSignpostID()

    private init() {}

    /// Starts a trace at the press. Every later call belongs to this open
    /// until `finish`, and calls made outside that window are ignored.
    public func begin(title: String) {
        lock.lock()
        defer { lock.unlock() }
        closeRunning()
        let now = DispatchTime.now()
        origin = now
        previous = now
        traceLine("[lexis.open] --- \(title)")
    }

    /// Closes whatever stage was running and opens `stage`.
    public func enter(_ stage: OpenStage) {
        lock.lock()
        defer { lock.unlock() }
        guard origin != nil else { return }
        closeRunning()
        previous = DispatchTime.now()
        running = (
            stage,
            PipelineSignposts.startup.beginInterval("stage", id: signpostID, "\(stage.rawValue)")
        )
    }

    /// A moment worth a line but no span of its own - the first bytes off the
    /// network, say, which happen inside a stage rather than beside it.
    public func mark(_ note: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let origin else { return }
        PipelineSignposts.startup.emitEvent("mark", id: signpostID, "\(note)")
        traceLine("[lexis.open] \(column(note))"
            + "            t+\(milliseconds(since: origin)) ms")
    }

    /// Closes the last stage and prints what the viewer actually waited.
    /// `note` says how the open ended for one that never reached a picture.
    public func finish(_ note: String = "picture") {
        lock.lock()
        defer { lock.unlock() }
        guard let origin else { return }
        closeRunning()
        traceLine("[lexis.open] === \(note) after \(milliseconds(since: origin)) ms"
            + " in the bridge, footprint \(footprintBytes() / 1_048_576) MiB")
        self.origin = nil
        previous = nil
    }

    /// The caller holds the lock.
    private func closeRunning() {
        guard let running, let origin, let previous else {
            self.running = nil
            return
        }
        PipelineSignposts.startup.endInterval("stage", running.state, "\(running.stage.rawValue)")
        traceLine("[lexis.open] \(column(running.stage.rawValue))"
            + " \(milliseconds(since: previous)) ms   t+\(milliseconds(since: origin)) ms")
        self.running = nil
    }

    /// Pads to the stage column without ever trimming: `padding(toLength:)`
    /// truncates anything longer, which silently ate the very figures these
    /// lines carry.
    private func column(_ text: String) -> String {
        text.count >= 14 ? text : text + String(repeating: " ", count: 14 - text.count)
    }

    private func milliseconds(since start: DispatchTime) -> String {
        let elapsed = DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds
        return String(format: "%7.1f", Double(elapsed) / 1_000_000)
    }
}

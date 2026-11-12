import CoreMedia
import Foundation

/// Times decode on the path a compressed sample takes straight to the sink,
/// which owns no VTDecompressionSession of its own to read back from. This
/// runs a second, throwaway session over the same samples, so the bench has
/// a number here too, not only on the tone-mapped path.
///
/// Bounded to `probeFrameLimit` frames: hardware-or-software and decode
/// speed are both fixed for the life of a file's session, so a short
/// warm-up answers both without paying a second decode for the whole
/// runtime of a playing file.
///
/// `LexisPlayer` never builds one of these: a second session alongside the
/// display layer's own would cost real playback the frames the bench would
/// then report as dropped. This is the bench's own instrument, for its own
/// run with nothing on screen - unused until the task that builds that run
/// wires it in.
public final class PassthroughDecodeProbe {
    /// Frames past this are never handed to the session: hardware-or-software
    /// and decode speed are both fixed for the life of a session, so a short
    /// sample answers both. Public so a caller that feeds more than this many
    /// packets (the bench's own decode-only run) knows how many to wait for.
    public static let frameLimit = 60

    private var decoder: VideoDecoder?
    private let lock = NSLock()
    /// Keyed by presentation time, the same way `ToneMappedVideo`'s
    /// `submitted` is: VideoToolbox's async callbacks are not guaranteed to
    /// return in submission order, and a container may leave every packet's
    /// pts at zero.
    private var submitted: [Int64: [Double]] = [:]
    private var decodeCount = 0
    private var decodeMillisecondsTotal = 0.0
    private var worstDecodeMs = 0.0
    private var fed = 0

    public var isHardwareAccelerated: Bool { decoder?.isHardwareAccelerated ?? false }

    /// 0 until the first frame comes back: nothing has been timed yet.
    public var decodeMillisecondsMean: Double {
        lock.lock(); defer { lock.unlock() }
        return decodeCount > 0 ? decodeMillisecondsTotal / Double(decodeCount) : 0
    }

    public var decodeMillisecondsWorst: Double {
        lock.lock(); defer { lock.unlock() }
        return worstDecodeMs
    }

    /// 0 both before anything is timed and for a real, instant decode: what
    /// tells the two apart from each other.
    public var decodeSampleCount: Int {
        lock.lock(); defer { lock.unlock() }
        return decodeCount
    }

    public init(formatDescription: CMVideoFormatDescription) throws {
        decoder = try VideoDecoder(formatDescription: formatDescription) { [weak self] frame in
            self?.present(frame)
        }
    }

    /// Best-effort and bounded: a call past the limit is a no-op, and a
    /// decode error here costs the stat, not the playback - the same sample
    /// is already on its way to the sink through the caller.
    public func decode(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        guard fed < PassthroughDecodeProbe.frameLimit else { lock.unlock(); return }
        fed += 1
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).value
        submitted[time, default: []].append(hostTimeSeconds())
        lock.unlock()
        try? decoder?.decode(sampleBuffer)
    }

    /// Drops in-flight submission bookkeeping across a seek: a callback that
    /// lands late for a sample fed before it would otherwise be timed
    /// against a submission time that no longer describes it. The session
    /// itself is untouched and keeps decoding whatever is fed to it next.
    public func flush() {
        lock.lock()
        submitted.removeAll()
        lock.unlock()
    }

    private func present(_ frame: DecodedFrame) {
        lock.lock()
        defer { lock.unlock() }
        let time = frame.presentationTime.value
        var times = submitted.removeValue(forKey: time) ?? []
        guard !times.isEmpty else { return }
        let submitTime = times.removeFirst()
        if !times.isEmpty { submitted[time] = times }
        let elapsedMs = (hostTimeSeconds() - submitTime) * 1000
        decodeCount += 1
        decodeMillisecondsTotal += elapsedMs
        worstDecodeMs = max(worstDecodeMs, elapsedMs)
    }
}

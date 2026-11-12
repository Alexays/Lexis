import CFFmpeg
import AVFoundation
import CLexisStream
import CoreMedia
import VideoToolbox
import LexisCoreStream
import LexisTestSupport
import XCTest
@testable import LexisPlayer

/// Collects `EngineEvent`s off an engine's `AsyncStream`, under a lock: the
/// collecting `Task` runs concurrently with whatever the test's own thread
/// is doing to keep a pulling sink drained.
final class EngineEventLog {
    private let lock = NSLock()
    private var events: [EngineEvent] = []

    func append(_ event: EngineEvent) {
        lock.lock(); events.append(event); lock.unlock()
    }

    var all: [EngineEvent] {
        lock.lock(); defer { lock.unlock() }
        return events
    }
}

final class PlayerEngineTests: XCTestCase {
    private func collectEvents(_ engine: PlayerEngine) -> (EngineEventLog, Task<Void, Never>) {
        let log = EngineEventLog()
        let task = Task {
            for await event in engine.events {
                log.append(event)
            }
        }
        return (log, task)
    }

    private func waitFor(
        _ log: EngineEventLog, _ predicate: @escaping ([EngineEvent]) -> Bool, timeout: TimeInterval = 5
    ) {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if predicate(log.all) { return }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        XCTFail("timed out waiting for the expected event; saw \(log.all)")
    }

    /// One playback, streamed the way a film from a Plex server is, long
    /// enough for a slope to be a slope: the whole pipeline from an HTTP range
    /// source through the byte cache, the demuxer and the queues to a sink
    /// that takes every sample at the rate a screen would.
    ///
    /// The footprint is read the way the app's own trace reads it, on a timer
    /// through the playback rather than once at the first picture. That is the
    /// whole difference: a leak that accumulates inside one playback is a
    /// slope, and a harness that weighs a playback once cannot tell a slope
    /// from a step no matter how many playbacks it weighs.
    ///
    /// Paced and at a film's bitrate, so the number it prints is comparable to
    /// a trace taken off a device rather than to nothing.
    ///
    ///     LEXIS_SOAK=1 swift test --filter testALongStreamedPlaybackHoldsItsFootprint
    func testALongStreamedPlaybackHoldsItsFootprint() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["LEXIS_SOAK"] == "1",
            "the soak pass: set LEXIS_SOAK=1")
        let fps: Int32 = 24
        let minutes = Double(ProcessInfo.processInfo.environment["LEXIS_SOAK_MINUTES"] ?? "5") ?? 5
        let frameCount = Int(Double(fps) * minutes * 60)
        // 4.4 Mb/s is what the trace of the killed playback works out to, and
        // the leak this weighs is proportional to bytes and not to pixels, so
        // the bitrate is the part that has to be a film's and the frame size
        // is free to be whatever encodes in reasonable time.
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "soak-stream.mp4",
            codec: .hevc, width: 640, height: 480, frameCount: frameCount, fps: fps,
            noisy: true, bitrate: 4_400_000
        )
        let body = try Data(contentsOf: url)
        let server = try RangeHTTPServer(body: body)
        defer { server.stop() }
        var openError: Int32 = 0
        let handle = try XCTUnwrap(lexis_stream_open_http_range(
            "\(server.baseURL)/library/parts/1/1/soak.mp4", "X-Plex-Token", "tok", &openError
        ))
        let demuxer = try Demuxer(stream: coreStream(handle: handle), interrupt: nil)
        let video = try XCTUnwrap(demuxer.streams.first { $0.kind == .video })
        let sink = CountingSink()
        // A sample per frame period: the drain a screen actually applies, and
        // what makes the reader pull through the byte cache at the film's own
        // rate rather than as fast as a local disk will go.
        sink.setEnqueueDelay(1.0 / Double(fps))
        let engine = PlayerEngine(
            demuxer: demuxer, tracks: .init(video: video, audio: nil, subtitle: nil),
            sink: sink, toneMapped: nil, interrupt: InterruptFlag()
        )
        let (log, task) = collectEvents(engine)
        defer { task.cancel() }

        let base = footprintBytes()
        engine.start(paused: false)
        let deadline = Date(timeIntervalSinceNow: minutes * 60 + 120)
        var samples: [(Double, Int)] = []
        let started = Date()
        while !log.all.contains(EngineEvent.endOfStream), Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 5))
            let at = Date().timeIntervalSince(started)
            let grown = footprintBytes() - base
            samples.append((at, grown))
            print(String(
                format: "SOAK t+%5.0f s  footprint +%5d MiB  fetched %5lld MiB",
                at, grown / 1_048_576,
                (demuxer.ioStatistics?.bytesFetched ?? 0) / 1_048_576))
        }
        engine.stop(join: true)

        let fetched = demuxer.ioStatistics?.bytesFetched ?? 0
        let ran = samples.last?.0 ?? 0
        XCTAssertGreaterThan(fetched, Int64(64 * 1_048_576), "the playback streamed almost nothing")

        // The queues and the pools fill once, in the first seconds, and that
        // step is not the defect: the trace of the killed playback shows the
        // same one, 175 MiB to 980 MiB inside a second. What is weighed here
        // is everything after it - a settled pipeline's footprint against the
        // highest it ever reaches afterwards, which for a window that keeps
        // what it has passed is the whole film so far.
        let settled = samples.first { $0.0 >= 60 }?.1 ?? 0
        let peak = samples.filter { $0.0 >= 60 }.map(\.1).max() ?? 0
        print(String(
            format: "SOAK ran %.1f min, streamed %lld MiB, settled +%d MiB, peak +%d MiB"
                + " (%+.1f MiB/min after settling)",
            ran / 60, fetched / 1_048_576, settled / 1_048_576, peak / 1_048_576,
            Double(peak - settled) * 60 / max(ran - 60, 1) / 1_048_576))
        XCTAssertLessThan(
            peak - settled, 48 * 1_048_576,
            "a settled pipeline still grew \((peak - settled) / 1_048_576) MiB over the"
                + " \(fetched / 1_048_576) MiB this playback streamed")
    }

    func testAFileFlowsDemuxToSinkWithNoThreadSleepingToPace() throws {
        let frameCount = 120
        let fps: Int32 = 24
        // gopSize forces AVVideoAllowFrameReorderingKey off: the passthrough
        // path hands the sink compressed samples in DECODE order (a real
        // renderer reorders B frames itself), so this assertion needs a
        // fixture with none to isolate the flow this test is actually about.
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "engine-flow.mp4",
            codec: .hevc, width: 320, height: 240, frameCount: frameCount, fps: fps, noisy: true,
            gopSize: frameCount
        )
        let demuxer = try Demuxer(url: url)
        let videoStream = try XCTUnwrap(demuxer.streams.first { $0.kind == .video })
        let sink = CountingSink()
        let engine = PlayerEngine(
            demuxer: demuxer, tracks: .init(video: videoStream, audio: nil, subtitle: nil),
            sink: sink, toneMapped: nil, interrupt: InterruptFlag()
        )
        let (log, task) = collectEvents(engine)
        defer { task.cancel() }

        let started = Date()
        let duration = Double(frameCount) / Double(fps)
        engine.start(paused: false)
        // the end waits for the clock to play the film out, and no longer
        waitFor(log, timeout: duration * 1.2 + 1) { $0.contains(.endOfStream) }
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(sink.count, frameCount)
        XCTAssertEqual(sink.samples, sink.samples.sorted { $0.seconds < $1.seconds })
        XCTAssertEqual(engine.statistics.framesDropped, 0)
        XCTAssertEqual(engine.statistics.framesDisplayed, frameCount)
        XCTAssertLessThan(elapsed, duration * 1.2 + 1)

        engine.stop(join: true)
    }

    /// No `gopSize`: the encoder's own default frame reordering (the same
    /// one `DemuxerTests.testReadsEveryPacketInDecodeOrder` confirms by its
    /// negative first dts) is exactly the B-frame content a hardware decoder
    /// needs in decode order. `testAFileFlowsDemuxToSinkWithNoThreadSleeping
    /// ToPace` above sidesteps this with a no-reorder fixture; this test is
    /// the one that requires the decode-order path to be real.
    func testCompressedPassthroughArrivesInDecodeOrderWithBFrames() throws {
        let frameCount = 60
        let fps: Int32 = 24
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "engine-bframes.mp4",
            codec: .hevc, width: 320, height: 240, frameCount: frameCount, fps: fps, noisy: true
        )

        let probe = try Demuxer(url: url)
        let probeStream = try XCTUnwrap(probe.streams.first { $0.kind == .video })
        let probeFormat = try makeFormatDescription(for: probeStream)
        var expectedDecodeOrder: [Double] = []
        var sawReordering = false
        while let packet = try probe.readPacket() {
            guard packet.streamIndex == probeStream.index else { continue }
            if let pts = packet.pts, let dts = packet.dts, pts != dts { sawReordering = true }
            let sample = try makeSampleBuffer(
                packet: packet, formatDescription: probeFormat,
                timeBaseNum: probeStream.timeBaseNum, timeBaseDen: probeStream.timeBaseDen
            )
            expectedDecodeOrder.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
        }
        XCTAssertTrue(sawReordering, "fixture must actually reorder for this test to prove anything")
        XCTAssertNotEqual(
            expectedDecodeOrder, expectedDecodeOrder.sorted(),
            "decode order must differ from presentation order"
        )

        let demuxer = try Demuxer(url: url)
        let videoStream = try XCTUnwrap(demuxer.streams.first { $0.kind == .video })
        let sink = CountingSink()
        let engine = PlayerEngine(
            demuxer: demuxer, tracks: .init(video: videoStream, audio: nil, subtitle: nil),
            sink: sink, toneMapped: nil, interrupt: InterruptFlag()
        )
        let (log, task) = collectEvents(engine)
        defer { task.cancel() }

        engine.start(paused: false)
        waitFor(log) { $0.contains(.endOfStream) }

        XCTAssertEqual(sink.samples.map(\.seconds), expectedDecodeOrder)
        engine.stop(join: true)
    }

    func testAudioAndVideoBothArriveAndBufferedSecondsIsTheirMin() throws {
        try skipUnlessRealtimeTests()
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "engine-av.mp4",
            codec: .h264, width: 320, height: 240, frameCount: 96, fps: 24, audio: true
        )
        let demuxer = try Demuxer(url: url)
        let videoStream = try XCTUnwrap(demuxer.streams.first { $0.kind == .video })
        let audioStream = try XCTUnwrap(demuxer.streams.first { $0.kind == .audio })
        // slows the sink's drain so both queues carry a real, measurable
        // backlog while the pipeline is still running
        let sink = CountingSink()
        sink.setEnqueueDelay(0.005)
        let engine = PlayerEngine(
            demuxer: demuxer, tracks: .init(video: videoStream, audio: audioStream, subtitle: nil),
            sink: sink, toneMapped: nil, interrupt: InterruptFlag()
        )
        let (log, task) = collectEvents(engine)
        defer { task.cancel() }

        // Seeded before the first packet is ever read, the order LexisPlayer
        // itself hands a pipeline over in. A selection applied after start()
        // bumps `audioFlushGeneration`, and every audio packet the demux
        // thread has already pushed carries the generation from before it, so
        // `runAudio` drops all of them - and this fixture is shorter than
        // PacketQueue's 8 s watermark, so the demux thread never parks and
        // can read the whole track within 2 ms of start(). Started first, the
        // sound this test measures is a race whose window is that 2 ms.
        engine.selectAudio(
            audioStream, pipeline: .decoded(try AudioDecoder(stream: audioStream))
        )
        engine.start(paused: false)

        // sampled mid-flight: the relationship must hold at any snapshot,
        // not only once everything has drained back to zero
        var sawBothBuffered = false
        let deadline = Date(timeIntervalSinceNow: 3)
        while Date() < deadline {
            let stats = engine.statistics
            let buffered = engine.statistics.bufferedSeconds
            // two independent live reads a beat apart, not one atomic
            // snapshot: the tolerance absorbs that race, not sloppy math.
            XCTAssertEqual(buffered, min(stats.videoBufferedSeconds, stats.audioBufferedSeconds), accuracy: 0.2)
            if stats.videoBufferedSeconds > 0, stats.audioBufferedSeconds > 0 { sawBothBuffered = true }
            if log.all.contains(.endOfStream) { break }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        waitFor(log) { $0.contains(.endOfStream) }

        XCTAssertTrue(sawBothBuffered, "both queues must have carried a real backlog at some point")
        XCTAssertGreaterThan(sink.count, 0)
        XCTAssertGreaterThan(sink.audio.count, 0)
        XCTAssertEqual(
            engine.statistics.bufferedSeconds, 0, accuracy: 0.001, "drained by the time the stream ends")

        engine.stop(join: true)
    }

    /// A file longer than the packet queues can hold must not strand the
    /// engine in its opening rebuffer. `bufferedSeconds` is a minimum over
    /// the tracks, the tracks share one demux thread, and that thread parks
    /// on whichever packet queue fills first - so the other track stops
    /// growing right there, and a rebuffer waiting on the minimum to reach
    /// the park point waits forever.
    func testALongFileLeavesItsOpeningRebufferAndPlaysOn() throws {
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "engine-long.mp4",
            codec: .h264, width: 320, height: 240, frameCount: 720, fps: 24, audio: true
        )
        let demuxer = try Demuxer(url: url)
        let videoStream = try XCTUnwrap(demuxer.streams.first { $0.kind == .video })
        let audioStream = try XCTUnwrap(demuxer.streams.first { $0.kind == .audio })
        let sink = CountingSink()
        let engine = PlayerEngine(
            demuxer: demuxer, tracks: .init(video: videoStream, audio: audioStream, subtitle: nil),
            sink: sink, toneMapped: nil, interrupt: InterruptFlag()
        )
        let (log, task) = collectEvents(engine)
        defer { task.cancel() }

        engine.start(paused: false)
        engine.selectAudio(
            audioStream, pipeline: .decoded(try AudioDecoder(stream: audioStream))
        )

        // the whole file, not merely "more than the one frame a stranded
        // engine leaves on screen": delivered, which runs ahead of the clock
        // that the end of stream itself waits for
        waitFor(log, timeout: 30) { _ in sink.count >= 720 }
        XCTAssertEqual(sink.count, 720, "the engine stalled partway through the file")

        engine.stop(join: true)
    }

    /// Taking the sound off leaves `audioPacketQueue` in place and nothing
    /// ever fills it again, so a buffer health of min(video, audio) would read
    /// zero for the rest of the file and hold the engine in a rebuffer it can
    /// never leave.
    func testTakingTheSoundOffLeavesTheBufferHealthOnTheVideoAlone() throws {
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "engine-audio-off.mp4",
            codec: .h264, width: 320, height: 240, frameCount: 96, fps: 24, audio: true
        )
        let demuxer = try Demuxer(url: url)
        let videoStream = try XCTUnwrap(demuxer.streams.first { $0.kind == .video })
        let audioStream = try XCTUnwrap(demuxer.streams.first { $0.kind == .audio })
        let sink = CountingSink()
        sink.setEnqueueDelay(0.005)
        let engine = PlayerEngine(
            demuxer: demuxer, tracks: .init(video: videoStream, audio: audioStream, subtitle: nil),
            sink: sink, toneMapped: nil, interrupt: InterruptFlag()
        )
        let (log, task) = collectEvents(engine)
        defer { task.cancel() }

        engine.start(paused: false)
        engine.selectAudio(nil, pipeline: nil)

        var reported = false
        let deadline = Date(timeIntervalSinceNow: 5)
        while Date() < deadline {
            let stats = engine.statistics
            if stats.videoBufferedSeconds > 0 {
                XCTAssertGreaterThan(
                    engine.statistics.bufferedSeconds, 0,
                    "the sound is off and the video carries \(stats.videoBufferedSeconds)s, "
                        + "yet the engine reports an empty buffer")
                reported = true
                break
            }
            if log.all.contains(.endOfStream) { break }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        XCTAssertTrue(reported, "the video never carried a backlog to report")

        engine.stop(join: true)
    }

    func testStopJoinsAllThreeThreads() throws {
        try skipUnlessRealtimeTests()
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "engine-stop.mp4",
            codec: .h264, width: 320, height: 240, frameCount: 200, fps: 30, noisy: true, audio: true
        )
        let demuxer = try Demuxer(url: url)
        let videoStream = try XCTUnwrap(demuxer.streams.first { $0.kind == .video })
        let audioStream = try XCTUnwrap(demuxer.streams.first { $0.kind == .audio })
        let sink = CountingSink()
        let engine = PlayerEngine(
            demuxer: demuxer, tracks: .init(video: videoStream, audio: audioStream, subtitle: nil),
            sink: sink, toneMapped: nil, interrupt: InterruptFlag()
        )
        engine.start(paused: false)
        engine.selectAudio(
            audioStream, pipeline: .decoded(try AudioDecoder(stream: audioStream))
        )

        // a joined stop is a hard synchronization point: by contract nothing
        // may still be delivering to the sink once the call returns, no
        // matter how far playback had already gotten
        engine.stop(join: true)
        let videoCountAfterStop = sink.count
        let audioCountAfterStop = sink.audio.count
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(sink.count, videoCountAfterStop)
        XCTAssertEqual(sink.audio.count, audioCountAfterStop)
    }

    func testTheInterruptUnwindsADemuxParkedInPush() throws {
        try skipUnlessRealtimeTests()
        // long enough (dts span well past PacketQueue's 8 s default high
        // watermark) that even a real pull cannot keep up: an artificial
        // per-frame delay throttles the sink's own drain far below the
        // unthrottled demux/decode rate, so the backlog the demux thread
        // is pushing grows past the watermark and it parks.
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "engine-interrupt.mp4",
            codec: .h264, width: 320, height: 240, frameCount: 300, fps: 30, noisy: true
        )
        let demuxer = try Demuxer(url: url)
        let videoStream = try XCTUnwrap(demuxer.streams.first { $0.kind == .video })
        let sink = CountingSink()
        sink.setEnqueueDelay(0.05)
        let interrupt = InterruptFlag()
        let engine = PlayerEngine(
            demuxer: demuxer, tracks: .init(video: videoStream, audio: nil, subtitle: nil),
            sink: sink, toneMapped: nil, interrupt: interrupt
        )
        engine.start(paused: false)

        // real wall time for the demux thread to run unthrottled and fill
        // both the packet and the sample queue up to their caps
        Thread.sleep(forTimeInterval: 0.5)
        interrupt.raise()

        let stopped = expectation(description: "stop joins after the interrupt unparks the push")
        DispatchQueue.global().async {
            engine.stop(join: true)
            stopped.fulfill()
        }
        wait(for: [stopped], timeout: 5)
    }

    /// A frame that fails to decode is a frame the film never shows, and the
    /// pull pipeline has no recovery for one: waiting does not produce it and
    /// nothing downstream can stand in for it. So it ends the playback and
    /// says so, rather than leaving a viewer 12% of a film and a clean end of
    /// stream - which is indistinguishable, from the couch, from a film that
    /// really ended.
    ///
    /// The stream is an h264 fixture the container is made to call vp8: a
    /// codec FFmpeg has a decoder for, that `appleVideoCodecType` does not
    /// recognize (so the software path is the one taken on any machine), and
    /// that refuses every packet it is fed here. A file whose container lies
    /// about its codec, which is also how the fault reaches the pipeline in
    /// the field.
    func testAPictureThatCannotBeDecodedEndsThePlaybackAndIsCounted() throws {
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "engine-undecodable.mp4",
            codec: .h264, width: 320, height: 240, frameCount: 60, fps: 24, noisy: true
        )
        let demuxer = try Demuxer(url: url)
        let real = try XCTUnwrap(demuxer.streams.first { $0.kind == .video })
        XCTAssertNil(
            isHardwareDecodeSupported(ffmpegCodecName: "vp8"),
            "the mislabel only forces the software path while VideoToolbox has no vp8 mapping"
        )
        let mislabelled = MediaStream(
            index: real.index, kind: real.kind, codecID: UInt32(AV_CODEC_ID_VP8.rawValue),
            codecName: "vp8", width: real.width, height: real.height,
            timeBaseNum: real.timeBaseNum, timeBaseDen: real.timeBaseDen,
            sampleRate: real.sampleRate, channels: real.channels, videoDelay: real.videoDelay,
            language: real.language, title: real.title, isDefault: real.isDefault,
            isForced: real.isForced, colorPrimaries: real.colorPrimaries,
            colorTransfer: real.colorTransfer, colorMatrix: real.colorMatrix,
            isFullRange: real.isFullRange, masteringDisplay: real.masteringDisplay,
            contentLight: real.contentLight, dolbyVision: real.dolbyVision, extradata: nil
        )
        let sink = CountingSink()
        let engine = PlayerEngine(
            demuxer: demuxer, tracks: .init(video: mislabelled, audio: nil, subtitle: nil),
            sink: sink, toneMapped: nil, interrupt: InterruptFlag()
        )
        let (log, task) = collectEvents(engine)
        defer { task.cancel() }

        engine.start(paused: false)
        waitFor(log) { events in
            events.contains { if case .failed = $0 { return true } else { return false } }
        }
        XCTAssertFalse(
            log.all.contains(.endOfStream),
            "a film that broke must never also report having ended"
        )
        XCTAssertGreaterThan(
            engine.statistics.decodeFailures, 0,
            "the failure has to be readable from the statistics the bench and the app both read"
        )
        XCTAssertEqual(engine.statistics.framesDisplayed, 0)

        engine.stop(join: true)
    }

    /// A decoder tvOS took back while the app was off screen reports as
    /// exactly that, never as a film that cannot play: the facade rebuilds
    /// the path on it.
    func testADecoderTakenBackIsNotAFailedFilm() throws {
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "engine-taken-back.mp4",
            codec: .h264, width: 320, height: 240, frameCount: 60, fps: 24
        )
        let demuxer = try Demuxer(url: url)
        let video = try XCTUnwrap(demuxer.streams.first { $0.kind == .video })
        let engine = PlayerEngine(
            demuxer: demuxer, tracks: .init(video: video, audio: nil, subtitle: nil),
            sink: CountingSink(), toneMapped: nil, interrupt: InterruptFlag()
        )
        let (log, task) = collectEvents(engine)
        defer { task.cancel() }
        engine.start(paused: true)
        engine.pictureLost(DecodeError.decodeFailed(kVTInvalidSessionErr))
        waitFor(log) { $0.contains(.decoderTakenBack) }
        XCTAssertFalse(log.all.contains { if case .failed = $0 { return true } else { return false } })
        engine.stop(join: true)
    }

    /// A budget so tight the picture queue holds barely more than the reorder
    /// depth, on the path where a picture is 63 MB at 4K. Every frame still
    /// reaches the sink: the queue holds fewer seconds, which is a shallower
    /// buffer, and never fewer pictures, which would be a film missing frames.
    /// The same defect `f5d4028` fixed, now against a ceiling the device sets
    /// rather than one written down.
    func testATightBudgetCostsSecondsOfBufferAndNeverAPicture() throws {
        try skipUnlessRealtimeTests()
        let frameCount = 60
        let url = try makeHDRFixture(
            directory: FileManager.default.temporaryDirectory, name: "engine-budget.mp4",
            width: 320, height: 180, frameCount: frameCount, transfer: .pq, gopSize: 15
        )
        let demuxer = try Demuxer(url: url)
        let stream = try XCTUnwrap(demuxer.streams.first { $0.kind == .video })
        let format = try makeFormatDescription(for: stream)
        let picture = decodedPictureBytes(
            width: Int(stream.width), height: Int(stream.height),
            pixelFormat: kCVPixelFormatType_64RGBAHalf
        )
        // Just past the floor the budget itself refuses to go below, so the
        // picture queue is sized in single frames rather than in seconds.
        let available = 2 * (
            (PipelineBudget.picturesHeldOutsideTheQueue + Int(stream.videoDelay) + 3) * picture
                + Int(PipelineBudget.minimumReadAheadSeconds * Double(demuxer.bitsPerSecond) / 8)
        )
        let budget = PipelineBudget(
            available: available, pictureBytes: picture, frameRate: stream.frameRate,
            videoDelay: Int(stream.videoDelay),
            videoBytesPerSecond: Int(demuxer.bitsPerSecond / 8),
            audioBytesPerSecond: 0, decodedAudioBytesPerSecond: 0,
            readAheadSeconds: 8, videoTargetSeconds: 1, audioTargetSeconds: 2
        )
        XCTAssertNil(budget.shortfall)
        XCTAssertLessThan(budget.videoSampleBytes, 8 * picture)

        let sink = CountingSink()
        // Paced like a real renderer, so the queue is against its ceiling for
        // the whole run rather than being drained as fast as it fills.
        sink.setEnqueueDelay(1.0 / 30.0)
        final class Box { weak var engine: PlayerEngine? }
        let box = Box()
        let toneMapped = try ToneMappedVideo(
            formatDescription: format, sourcePeakPQ: masteringPeakPQ(stream.masteringDisplay),
            videoDelay: stream.videoDelay, capability: DisplayCapability(headroom: 1),
            budgetBytes: budget.pictureReserveBytes
        ) { [weak box] sample in
            box?.engine?.pushToneMappedFrame(sample)
        }
        let engine = PlayerEngine(
            demuxer: demuxer, tracks: .init(video: stream, audio: nil, subtitle: nil),
            sink: sink, toneMapped: toneMapped, budget: budget, interrupt: InterruptFlag()
        )
        box.engine = engine
        let (log, task) = collectEvents(engine)
        defer { task.cancel() }

        engine.start(paused: false)
        waitFor(log, { $0.contains(.endOfStream) }, timeout: 20)
        engine.stop(join: true)

        XCTAssertEqual(sink.pictures, frameCount)
        XCTAssertEqual(engine.statistics.decodeFailures, 0)
        XCTAssertEqual(engine.statistics.framesDropped, 0)
    }

    /// A stopped engine has given its queues back by the time the stop
    /// returns, not whenever it is released afterwards. The memory budget
    /// weighs the process footprint BEFORE it decides whether the next film
    /// fits, so read-ahead handed back at the next open is read-ahead the
    /// next film is refused for.
    func testAStoppedEngineHasAlreadyGivenItsQueuesBack() throws {
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "engine-teardown.mp4",
            codec: .hevc, width: 320, height: 240, frameCount: 240, fps: 24, noisy: true
        )
        let demuxer = try Demuxer(url: url)
        let videoStream = try XCTUnwrap(demuxer.streams.first { $0.kind == .video })
        let sink = CountingSink()
        // A paused renderer fills its own buffer and stops asking, which is
        // what leaves the queues full at the stop - the state every teardown
        // that is not an end of stream happens in.
        sink.setStopsPullingWhilePaused(true)
        let engine = PlayerEngine(
            demuxer: demuxer, tracks: .init(video: videoStream, audio: nil, subtitle: nil),
            sink: sink, toneMapped: nil, interrupt: InterruptFlag()
        )
        let (_, task) = collectEvents(engine)
        defer { task.cancel() }
        engine.start(paused: true)
        let deadline = Date(timeIntervalSinceNow: 10)
        while engine.statistics.videoBufferedSeconds <= 0, Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        XCTAssertGreaterThan(
            engine.statistics.videoBufferedSeconds, 0, "the queues never filled")

        engine.stop(join: true)
        XCTAssertEqual(engine.statistics.videoBufferedSeconds, 0)
    }
}

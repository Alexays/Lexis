import AVFoundation
import LexisCoreStream
import LexisTestSupport
import XCTest
@testable import LexisPlayer

/// Whether the pipeline puts its pictures up on time, and what it costs the
/// main thread while it does.
///
/// The figure to hold on to is RUNWAY: stream seconds already handed to the
/// renderer and still ahead of the clock. A gap between two enqueues says
/// nothing on its own - the pump idles for over a second at a time against a
/// renderer holding two seconds of picture, which is backpressure working, not
/// judder. A frame misses its slot only where runway reaches zero, so runway
/// is what these assert, and they assert it at every moment the request could
/// have starved the renderer rather than at one chosen instant.
final class FrameDeliveryTests: RealtimeTestCase {
    private static let fps = 24
    private static let frameSeconds = 1.0 / 24
    /// Three seconds of film. The property is over time and needs enough
    /// frames to be one - `assertNeverMissedASlot` holds out for more than
    /// twenty-four of them - but it is a property of every frame, so it fails
    /// on the first one that misses its slot whether the film runs three
    /// seconds or eight. These play at the renderer's own rate, which is the
    /// one clock here that cannot be scaled, so the length is what it costs.
    private static let frameCount = 72

    /// Runway at every `wentDry` after the first picture, and at every enqueue
    /// after it. The cold start is excluded by construction: before the first
    /// enqueue there is no runway to measure, and the engine holds that span
    /// at rate 0 on purpose.
    private func assertNeverMissedASlot(
        _ label: String, _ recorder: FrameDeliveryRecorder, file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let samples = recorder.recorded
        guard let firstEnqueue = samples.firstIndex(where: { $0.mark == .enqueued }) else {
            return XCTFail("\(label): nothing was ever enqueued", file: file, line: line)
        }
        let afterFirstPicture = samples[(firstEnqueue + 1)...]
        XCTAssertGreaterThan(
            afterFirstPicture.filter { $0.mark == .enqueued }.count, 24,
            "\(label): too few frames to be a property over time", file: file, line: line
        )
        for sample in afterFirstPicture where sample.mark == .wentDry {
            XCTAssertGreaterThanOrEqual(
                sample.runwaySeconds, FrameDeliveryTests.frameSeconds,
                "\(label): the request went dry with only "
                    + "\(String(format: "%.1f", sample.runwaySeconds * 1000)) ms of picture "
                    + "left ahead of the clock - the next frame misses its slot",
                file: file, line: line
            )
        }
        for sample in afterFirstPicture where sample.mark == .enqueued {
            XCTAssertGreaterThan(
                sample.runwaySeconds, 0,
                "\(label): the clock had already passed everything enqueued",
                file: file, line: line
            )
        }
    }

    private func playToEnd(
        url: URL? = nil, stream: MediaStreamIO? = nil, timeout: TimeInterval = 120
    ) throws -> (FrameDeliveryRecorder, MainBlockCounter, PlaybackStats) {
        let sink = DisplayLayerSink(layer: AVSampleBufferDisplayLayer())
        let recorder = FrameDeliveryRecorder()
        let counter = MainBlockCounter()
        sink.deliveryRecorder = recorder
        sink.mainBlockCounter = counter
        let player = LexisPlayer(sink: sink)
        let ended = expectation(description: "end of stream")
        let collector = Task {
            for await event in player.events where event == .endOfStream { ended.fulfill() }
        }
        if let url {
            try player.open(url: url)
        } else if let stream {
            try player.open(stream: stream)
        }
        player.play()
        wait(for: [ended], timeout: timeout)
        collector.cancel()
        return (recorder, counter, player.stats)
    }

    func testAQuietSourceNeverRunsTheRendererOutOfPicture() throws {
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "runway-clean.mp4",
            codec: .hevc, width: 1280, height: 720, frameCount: FrameDeliveryTests.frameCount,
            fps: Int32(FrameDeliveryTests.fps), audio: true
        )
        let (recorder, _, stats) = try playToEnd(url: url)
        assertNeverMissedASlot("quiet local source", recorder)
        XCTAssertEqual(stats.framesDropped, 0)
    }

    /// The same property with the source misbehaving the way a real Plex
    /// server does: every range request a little late, all the time.
    func testAJitterySourceNeverRunsTheRendererOutOfPicture() throws {
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "runway-http.mp4",
            codec: .hevc, width: 1280, height: 720, frameCount: FrameDeliveryTests.frameCount,
            fps: Int32(FrameDeliveryTests.fps), noisy: true, audio: true, bitrate: 8_000_000
        )
        let server = try RangeHTTPServer(body: try Data(contentsOf: url))
        defer { server.stop() }
        server.jitterFromNow(0.05...0.35)
        let handle = try XCTUnwrap(
            lexis_stream_open_http_range("\(server.baseURL)/clip.mp4", "", "", nil)
        )
        let (recorder, _, stats) = try playToEnd(stream: coreStream(handle: handle))
        assertNeverMissedASlot("jittery HTTP source", recorder)
        XCTAssertEqual(stats.framesDropped, 0)
    }

    /// The clock's cue observer runs on the MAIN queue, 30 times a second, for
    /// as long as it is installed - and the main queue is what the app's own
    /// `FrameTrace` display link measures. A film with subtitles off has
    /// nothing for any of those blocks to do, and must not pay for them.
    func testAPlaybackWithNoSubtitlesCostsTheMainQueueNothing() throws {
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "runway-main.mp4",
            codec: .hevc, width: 1280, height: 720, frameCount: FrameDeliveryTests.frameCount,
            fps: Int32(FrameDeliveryTests.fps), audio: true
        )
        let (_, counter, _) = try playToEnd(url: url)
        XCTAssertEqual(
            counter.count, 0,
            "a subtitle-free playback put \(counter.count) blocks on the main queue"
        )
    }

    /// The other half of that: a track that IS on must still be driven, or the
    /// saving above would be a subtitle path that never draws.
    func testACueStartsTheObserverThatDrawsIt() throws {
        let sink = DisplayLayerSink(layer: AVSampleBufferDisplayLayer())
        let counter = MainBlockCounter()
        sink.mainBlockCounter = counter
        sink.start(atPresentation: 0)
        sink.enqueueSubtitle(SubtitleCue(
            start: 0, end: 10, lines: ["bonjour"], images: [],
            canvasWidth: 0, canvasHeight: 0
        ))
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.4))
        XCTAssertGreaterThan(counter.count, 0, "the cue observer never ran")
        XCTAssertEqual(sink.shownSubtitle?.lines, ["bonjour"])
    }
}

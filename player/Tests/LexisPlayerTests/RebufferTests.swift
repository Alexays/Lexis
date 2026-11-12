import LexisCoreStream
import LexisTestSupport
import XCTest
@testable import LexisPlayer

/// Stage 3's own rule: a starved buffer pauses visibly, counted, and
/// resumes once refilled. No frame is ever dropped for it - `JitterTests`
/// and the stall suite in `LexisPlayerTests.swift` already prove that part;
/// this file proves the pause, the count and the resume around it.
/// The first reading only: the clock also starts again coming out of a
/// stall, and it is the one at the cold start this file is about.
final class BufferedAtStartBox: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: Double?

    func setOnce(_ value: Double) {
        lock.lock()
        if seconds == nil { seconds = value }
        lock.unlock()
    }

    var value: Double? {
        lock.lock(); defer { lock.unlock() }
        return seconds
    }
}

final class RebufferTests: RealtimeTestCase {
    /// The starvation the stall causes, start to finish, and nothing after it.
    ///
    /// The sink stops asking for picture the moment `.buffering` says the
    /// starvation has begun. Nothing drains behind the refill, so what the
    /// engine does with it is observed rather than raced: `CountingSink` is
    /// paced by nothing at all, and left pulling it empties the whole
    /// refilled buffer within about fifteen milliseconds of the resume and
    /// starves the pipeline a second time - a real starvation, but one this
    /// double causes and no viewer's renderer would. Waiting on the two
    /// events rather than sampling `rates` for the same reason: the resumed
    /// rate stood for fifteen milliseconds and a twenty millisecond poll read
    /// it about two times in three.
    func testStarvationSetsRateZeroCountsOneRebufferAndRefillsToHigh() throws {
        let bytes = bigStallFixtureBytes
        let stream = stallingStream(
            bytes: bytes, contentSeconds: bigStallFixtureSeconds,
            stalls: [(atByte: stallPastTheWindow, seconds: stallOutlastingTheLead)]
        )
        let sink = CountingSink()
        let player = LexisPlayer(sink: sink, policy: testBufferPolicy)
        let starved = expectation(description: "buffering")
        let resumed = expectation(description: "resumed")
        let collector = Task {
            var sawStarvation = false
            var sawResume = false
            for await event in player.events {
                if case .buffering = event, !sawStarvation {
                    sawStarvation = true
                    sink.setStopsPullingVideo(true)
                    starved.fulfill()
                }
                if event == .playing, sawStarvation, !sawResume {
                    sawResume = true
                    resumed.fulfill()
                }
            }
        }
        try player.open(stream: stream)
        player.play()
        wait(for: [starved, resumed], timeout: 60)
        collector.cancel()

        XCTAssertEqual(sink.rates, [0, 1])
        XCTAssertEqual(player.stats.rebufferCount, 1)
        XCTAssertEqual(player.stats.framesDropped, 0)
        // What the count alone never showed: the refill held out past the low
        // watermark it stopped playback at, for the midpoint between the two.
        //
        // Bounded against the low watermark rather than against the midpoint
        // itself. The pull thread parked inside the refill takes its samples
        // the instant the refill resolves, so the reading lands a few frames
        // under whatever the refill reached; at a watermark of a second those
        // few frames are a real fraction of it.
        XCTAssertGreaterThan(player.stats.bufferedSeconds, testBufferPolicy.lowWatermarkSeconds)
        player.stop()
    }

    /// The cold start's own half of the same rule. A pipeline that starts
    /// the clock on the first frame it decodes starts below the very
    /// watermark it calls starved, and stalls on the frame the viewer was
    /// just shown - which is exactly where a stall is most visible. The
    /// first frame goes up, the clock waits for the low watermark behind it.
    ///
    /// A source delivering at content rate, so the buffer can only be built
    /// before playback begins and never during it: no timing in the
    /// assertions, only the buffer the engine itself reports at the instant
    /// its clock first runs.
    func testPlaybackNeverStartsBelowTheLowWatermark() throws {
        let bytes = bigStallFixtureBytes
        let stream = stallingStream(bytes: bytes, contentSeconds: bigStallFixtureSeconds, stalls: [])
        let sink = CountingSink()
        let player = LexisPlayer(sink: sink, policy: testBufferPolicy)
        let bufferedAtStart = BufferedAtStartBox()
        sink.onClockStart = { [weak player] in
            guard let player else { return }
            bufferedAtStart.setOnce(player.stats.bufferedSeconds)
        }
        try player.open(stream: stream)
        player.play()

        let deadline = Date(timeIntervalSinceNow: 60)
        while bufferedAtStart.value == nil, Date() < deadline { usleep(20_000) }
        player.stop()

        let buffered = try XCTUnwrap(bufferedAtStart.value, "the clock never started")
        XCTAssertGreaterThanOrEqual(buffered, testBufferPolicy.lowWatermarkSeconds)
        // The frame itself is up before the wait, never behind it: a viewer
        // watching a film load sees the picture, not black.
        XCTAssertEqual(sink.framesBeforeClockStart, 1)
    }

    /// A clip that runs out to its own natural end, with nothing ever
    /// stalling the source, must not be mistaken for a starved buffer just
    /// because the tail drains toward zero on its way there.
    func testEndOfStreamIsNotARebuffer() throws {
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "rebuffer-eos.mp4",
            codec: .hevc, width: 320, height: 240, frameCount: 96, fps: 24
        )
        let sink = CountingSink()
        sink.setEnqueueDelay(0.02)
        let player = LexisPlayer(sink: sink)
        let ended = expectation(description: "end of stream")
        let collector = Task {
            for await event in player.events where event == .endOfStream { ended.fulfill() }
        }
        try player.open(url: url)
        player.play()
        wait(for: [ended], timeout: 15)
        collector.cancel()

        XCTAssertEqual(player.stats.rebufferCount, 0)
        XCTAssertFalse(sink.rates.contains(0))
    }

    /// A starvation nothing can refill must still be entered at most once.
    ///
    /// A renderer holding a full audio buffer stops asking for sound, so the
    /// audio queues behind it fill and the one demux thread parks on them -
    /// and the video queue it also feeds runs dry with no way to be filled
    /// again by waiting. `refillIsHopeless` is what ends that wait, but it
    /// is true at a buffer of zero, which is also exactly what admits the
    /// next one: leaving the state and re-entering it had nothing between
    /// them, and the pull thread's own retry loop ran the round trip at CPU
    /// speed. Counted over a whole second, because one entry per pull is
    /// what the defect looks like and one entry per episode is what the
    /// hysteresis promises.
    func testAnUnrefillableStarvationIsEnteredOnceNotOnEveryPull() throws {
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "rebuffer-audio-parked.mp4",
            codec: .h264, width: 320, height: 240, frameCount: 720, fps: 24, audio: true
        )
        let sink = CountingSink()
        sink.setStopsPullingAudio(true)
        let player = LexisPlayer(sink: sink)
        try player.open(url: url)
        player.play()

        // Long enough for the audio queues to reach their watermark, park
        // the demux thread, and leave video with nothing.
        usleep(2_500_000)
        let settled = player.stats.rebufferCount
        usleep(1_000_000)
        let afterASecond = player.stats.rebufferCount
        player.stop()

        XCTAssertLessThanOrEqual(
            afterASecond - settled, 1,
            "the engine re-entered buffering \(afterASecond - settled) times in one second"
        )
    }

    func testRebufferEventsCarryBufferedSeconds() throws {
        let bytes = bigStallFixtureBytes
        let stream = stallingStream(
            bytes: bytes, contentSeconds: bigStallFixtureSeconds,
            stalls: [(atByte: stallPastTheWindow, seconds: stallOutlastingTheLead)]
        )
        let sink = CountingSink()
        let player = LexisPlayer(sink: sink, policy: testBufferPolicy)
        var seen: [PlayerEvent] = []
        let collector = Task {
            for await event in player.events { seen.append(event) }
        }
        try player.open(stream: stream)
        player.play()

        let deadline = Date(timeIntervalSinceNow: 30)
        while player.stats.rebufferCount < 1, Date() < deadline { usleep(20_000) }
        player.stop()
        collector.cancel()

        let bufferedSecondsAtEachBuffering = seen.compactMap { event -> Double? in
            if case .buffering(let bufferedSeconds) = event { return bufferedSeconds }
            return nil
        }
        XCTAssertEqual(bufferedSecondsAtEachBuffering.count, 1)
        // Reported exactly because it crossed the low watermark going down.
        XCTAssertGreaterThanOrEqual(bufferedSecondsAtEachBuffering[0], 0)
        XCTAssertLessThan(
            bufferedSecondsAtEachBuffering[0], testBufferPolicy.lowWatermarkSeconds)
    }
}

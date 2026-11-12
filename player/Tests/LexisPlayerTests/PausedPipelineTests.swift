import LexisTestSupport
import XCTest

@testable import LexisPlayer

/// What a paused player owes the app that is still asking it questions. A
/// pause stops the drain and the picture queue behind it fills to its
/// ceiling, which is the pipeline's normal resting state, not a fault: the
/// once-a-second statistics tick still runs on the main thread throughout,
/// and nothing about a full pipeline may make it wait.
final class PausedPipelineTests: RealtimeTestCase {
    private final class StatsBox: @unchecked Sendable {
        private let lock = NSLock()
        private var snapshot: PlaybackStats?

        func set(_ value: PlaybackStats) {
            lock.lock(); snapshot = value; lock.unlock()
        }

        var value: PlaybackStats? {
            lock.lock(); defer { lock.unlock() }
            return snapshot
        }
    }

    func testStatsAnswerWhileAPausedPipelineSitsFull() throws {
        let sink = CountingSink()
        sink.setStopsPullingWhilePaused(true)
        // An SDR display, so this PQ file is tone mapped rather than passed
        // through: the path a decoded picture reaches the queue by.
        let player = LexisPlayer(sink: sink, display: { DisplayCapability(headroom: 1) })
        defer { player.close() }
        let url = try makeHDRFixture(
            directory: FileManager.default.temporaryDirectory, name: "paused-pipeline.mp4",
            width: 320, height: 180, frameCount: 150, transfer: .pq
        )
        try player.open(url: url)
        player.play()
        let playing = Date(timeIntervalSinceNow: 30)
        while sink.pictures < 5, Date() < playing { usleep(10_000) }
        XCTAssertGreaterThanOrEqual(sink.pictures, 5, "nothing ever reached the sink")

        player.pause()
        // Long enough for the decode side to fill the second of pictures the
        // queue holds at this size and rate, and to find there is nowhere to
        // put the next one: at 320x180 that second decodes in a few tens of
        // milliseconds.
        usleep(1_000_000)

        let box = StatsBox()
        let answered = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            box.set(player.stats)
            answered.signal()
        }
        // The app asks once a second, from the main thread. Five is not a
        // slow read, it is a read that is never coming back.
        XCTAssertEqual(
            answered.wait(timeout: .now() + 5), .success,
            "stats never answered while the paused pipeline was full"
        )
        XCTAssertGreaterThan(box.value?.decodeSampleCount ?? 0, 0)

        // And the pause is only a pause: the pipeline it filled starts
        // draining again on the resume, rather than having wedged itself
        // somewhere the queue's own room cannot reach.
        let resumedFrom = sink.pictures
        player.play()
        let flowing = Date(timeIntervalSinceNow: 15)
        while sink.pictures < resumedFrom + 10, Date() < flowing { usleep(10_000) }
        XCTAssertGreaterThanOrEqual(sink.pictures, resumedFrom + 10, "playback never resumed")
    }
}

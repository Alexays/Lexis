import LexisCoreStream
import LexisTestSupport
import XCTest
@testable import LexisPlayer

final class InterruptTests: XCTestCase {
    /// Bigger than the core's 2 MiB range-request span, so opening it takes
    /// more than the one range request the core already made. Noise, not
    /// flat colour, is what gets there without an expensive
    /// high-resolution encode.
    private func fixtureData() throws -> Data {
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "interrupt.mp4",
            codec: .hevc, width: 640, height: 480, frameCount: 480, fps: 24, noisy: true
        )
        return try Data(contentsOf: url)
    }

    /// Megabytes of noise rather than a few hundred kilobytes of flat colour,
    /// and past the read-ahead stream's own 8 MiB buffer: playback has to
    /// keep making range requests through the whole test instead of running
    /// off a buffer that filled while opening and never asks the server for
    /// another byte before a test arms its own stall.
    private func streamingFixtureData() throws -> Data {
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "interrupt-noise.mp4",
            codec: .hevc, width: 640, height: 480, frameCount: 260, fps: 24, noisy: true
        )
        return try Data(contentsOf: url)
    }

    func testARaisedFlagAbandonsAStalledServerAtOnce() throws {
        let server = try RangeHTTPServer(body: try fixtureData())
        defer { server.stop() }
        let handle = try XCTUnwrap(
            lexis_stream_open_http_range("\(server.baseURL)/clip.mp4", "", "", nil)
        )
        // longer than the core agent's 30 s read timeout: without the flag this
        // open would sit here, and stop() would sit behind it
        server.stallFromNow(60)
        let flag = InterruptFlag()
        flag.raise()

        let started = Date()
        XCTAssertThrowsError(try Demuxer(stream: coreStream(handle: handle), interrupt: flag))
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        // only the request the core's own open made: the demuxer never asked
        XCTAssertEqual(server.requests.count, 1)
    }

    func testTheSameStreamOpensWhenNothingIsRaised() throws {
        let server = try RangeHTTPServer(body: try fixtureData())
        defer { server.stop() }
        let handle = try XCTUnwrap(
            lexis_stream_open_http_range("\(server.baseURL)/clip.mp4", "", "", nil)
        )
        let demuxer = try Demuxer(stream: coreStream(handle: handle), interrupt: InterruptFlag())
        XCTAssertEqual(demuxer.streams.count, 1)
        XCTAssertGreaterThan(server.requests.count, 1)
    }

    /// The reader is parked inside a read the interrupt cannot reach, which is
    /// the state the one-outstanding-read bound is about: the read in flight
    /// runs to the end of the stall, and the read after it never reaches the
    /// server.
    func testStoppingAPlayerParkedInsideAReadWaitsForThatReadAndNoOther() throws {
        try skipUnlessRealtimeTests()
        let server = try RangeHTTPServer(body: try streamingFixtureData())
        defer { server.stop() }
        // Armed before anything asks the server for a byte: a loopback
        // server answers fast enough that the read-ahead stream's own
        // prefetching can otherwise fill its buffer, and satisfy every read
        // this test cares about from it, before a stall armed after play()
        // ever catches a request in flight.
        server.stallBodyFromNow(InterruptTests.stall)
        let handle = try XCTUnwrap(
            lexis_stream_open_http_range("\(server.baseURL)/clip.mp4", "", "", nil)
        )
        let sink = CountingSink()
        let player = LexisPlayer(sink: sink)
        let log = EventLog()
        let collector = Task {
            for await event in player.events { log.append(event) }
        }
        try player.open(stream: coreStream(handle: handle))
        player.play()
        try waitForBodyStall(server)

        let requestsWhenParked = server.requests.count
        let started = Date()
        player.cancel()
        player.stop()
        // the stall, and nothing near the core's 30 s read timeout
        XCTAssertLessThan(Date().timeIntervalSince(started), InterruptTests.stall + 3)
        // past the end of the stall, so a request the reader might have made
        // after its parked one came back has had time to land
        Thread.sleep(forTimeInterval: 0.5)
        // The read-ahead stream keeps its pump fetching continuously rather
        // than only when the reader asks, so the interrupt has a narrower
        // race to lose than an unwrapped stream's own read loop does: one
        // more prefetch, already past its own interrupt check, can land in
        // the gap between reading requestsWhenParked and cancel() taking
        // effect. Not two - the loop iteration after that one observes the
        // flag and stops, the same as it always did.
        XCTAssertLessThanOrEqual(server.requests.count, requestsWhenParked + 1)
        collector.cancel()
        let seen = log.all
        XCTAssertTrue(seen.contains(.stopped), "\(seen)")
        XCTAssertFalse(seen.contains(where: { if case .failed = $0 { return true }; return false }), "\(seen)")
    }

    /// The documented flow: cancel() from the thread that cannot block, stop()
    /// from one that can. The refused read lands in between, with nothing
    /// stopping yet, and it is still a cancellation rather than a failure.
    func testACancelWellBeforeTheStopIsNotAPlaybackFailure() throws {
        try skipUnlessRealtimeTests()
        let server = try RangeHTTPServer(body: try streamingFixtureData())
        defer { server.stop() }
        // Armed before anything asks the server for a byte: a loopback
        // server answers fast enough that the read-ahead stream's own
        // prefetching can otherwise fill its buffer, and satisfy every read
        // this test cares about from it, before a stall armed after play()
        // ever catches a request in flight.
        server.stallBodyFromNow(InterruptTests.stall)
        let handle = try XCTUnwrap(
            lexis_stream_open_http_range("\(server.baseURL)/clip.mp4", "", "", nil)
        )
        let sink = CountingSink()
        let player = LexisPlayer(sink: sink)
        let log = EventLog()
        let collector = Task {
            for await event in player.events { log.append(event) }
        }
        try player.open(stream: coreStream(handle: handle))
        player.play()
        try waitForBodyStall(server)

        player.cancel()
        // long enough that the outstanding read finishes and the read after it
        // is refused while stop() has not been called at all
        Thread.sleep(forTimeInterval: InterruptTests.stall + 1)
        let duringCancel = log.all
        XCTAssertFalse(
            duringCancel.contains(where: { if case .failed = $0 { return true }; return false }),
            "\(duringCancel)"
        )
        // the reader went home when its read was refused, so there is no longer
        // a thread to pause
        player.pause()
        XCTAssertFalse(log.all.contains(.paused), "\(log.all)")
        player.stop()
        Thread.sleep(forTimeInterval: 0.1)
        collector.cancel()
        let seen = log.all
        XCTAssertFalse(seen.contains(where: { if case .failed = $0 { return true }; return false }), "\(seen)")
    }

    /// A refused read latches inside the AVIOContext, so a stopped stream is
    /// spent in the same way as one that ran to its end.
    func testAStoppedStreamPlaysAgainOnlyAfterAReopen() throws {
        let body = try fixtureData()
        let server = try RangeHTTPServer(body: body)
        defer { server.stop() }
        let sink = CountingSink()
        let player = LexisPlayer(sink: sink)
        let log = EventLog()
        let collector = Task {
            for await event in player.events { log.append(event) }
        }
        let first = try XCTUnwrap(
            lexis_stream_open_http_range("\(server.baseURL)/clip.mp4", "", "", nil)
        )
        try player.open(stream: coreStream(handle: first))
        player.play()
        let firstFrameDeadline = Date(timeIntervalSinceNow: 10)
        while sink.count == 0, Date() < firstFrameDeadline {
            usleep(20_000)
        }
        player.stop()
        let framesAtStop = sink.count
        XCTAssertGreaterThan(framesAtStop, 0)

        // A stream-backed demuxer is spent the instant stop() (joined,
        // above) sets it so: play() refuses at its very first guard, on this
        // same thread, before it starts anything - there is nothing async
        // left for a wait to gate on.
        player.play()
        XCTAssertEqual(sink.count, framesAtStop, "a stopped stream must not resume")
        let firstPlayingDeadline = Date(timeIntervalSinceNow: 5)
        while log.all.filter({ $0 == .playing }).count < 1, Date() < firstPlayingDeadline {
            usleep(20_000)
        }
        XCTAssertEqual(log.all.filter { $0 == .playing }.count, 1)
        XCTAssertFalse(
            log.all.contains(where: { if case .failed = $0 { return true }; return false }),
            "\(log.all)"
        )

        let second = try XCTUnwrap(
            lexis_stream_open_http_range("\(server.baseURL)/clip.mp4", "", "", nil)
        )
        try player.open(stream: coreStream(handle: second))
        player.play()
        let secondFrameDeadline = Date(timeIntervalSinceNow: 10)
        while sink.count <= framesAtStop, Date() < secondFrameDeadline {
            usleep(20_000)
        }
        XCTAssertGreaterThan(sink.count, framesAtStop)
        let secondPlayingDeadline = Date(timeIntervalSinceNow: 5)
        while log.all.filter({ $0 == .playing }).count < 2, Date() < secondPlayingDeadline {
            usleep(20_000)
        }
        XCTAssertEqual(log.all.filter { $0 == .playing }.count, 2)
        player.stop()
        collector.cancel()
    }

    /// Long enough that a wait bounded by it is telling, short enough to be
    /// nowhere near the core's 30 s read timeout. Every wait here is a
    /// multiple of it, so it is the whole of what this class costs.
    private static let stall: TimeInterval = 2 / testTimeScale

    private struct ReaderNeverAskedForMore: Error {}

    /// Returns once the server is holding a body back, which is the point the
    /// reader is inside a read of it.
    private func waitForBodyStall(_ server: RangeHTTPServer) throws {
        let deadline = Date(timeIntervalSinceNow: 10)
        while server.bodyStalls == 0 {
            if Date() > deadline { throw ReaderNeverAskedForMore() }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }
}

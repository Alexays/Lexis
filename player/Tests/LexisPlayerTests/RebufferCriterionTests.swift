import LexisCoreStream
import LexisTestSupport
import XCTest
@testable import LexisPlayer

/// Stage 3's own criterion: a stream throttled to HALF the fixture's own
/// measured byte rate still plays with zero dropped frames, N counted and
/// visible rebuffers, each one a real pause and a real resume, and reaches
/// end of stream.
final class RebufferCriterionTests: RealtimeTestCase {
    func testHalfBitrateStreamPlaysWithZeroDropsAndCountedRebuffers() throws {
        let bytes = bigStallFixtureBytes
        // The fixture's real size over its real duration, never an invented
        // byte rate: half of THIS is what the server is then held to.
        let measuredBitsPerSecond = Double(bytes.count) * 8 / bigStallFixtureSeconds

        var profile = MeasuredStreamProfile()
        profile.coldPerRequestBitsPerSecond = measuredBitsPerSecond / 2
        profile.reusedBitsPerSecond = measuredBitsPerSecond / 2

        let server = try RangeHTTPServer(body: bytes)
        defer { server.stop() }
        server.serveMeasuredProfile(profile, coldFirstConnection: false)

        let handle = try XCTUnwrap(
            lexis_stream_open_http_range("\(server.baseURL)/clip.mp4", "", "", nil)
        )
        let sink = CountingSink()
        let player = LexisPlayer(sink: sink, policy: testBufferPolicy)
        var seen: [PlayerEvent] = []
        let ended = expectation(description: "end of stream")
        let collector = Task {
            for await event in player.events {
                seen.append(event)
                if event == .endOfStream { ended.fulfill() }
            }
        }
        try player.open(stream: coreStream(handle: handle))
        player.play()
        wait(for: [ended], timeout: 180)
        collector.cancel()

        XCTAssertEqual(player.stats.framesDropped, 0)
        XCTAssertGreaterThan(player.stats.rebufferCount, 0)

        // Every counted rebuffer paired with one `.buffering` and one
        // resumed: `.resumed` reports through `PlayerEvent.playing`
        // (LexisPlayerAPI stays additive), so the very first `.playing` -
        // the one `play()` itself yields before the engine ever starts - is
        // excluded; every one after it is a real resume from a real stall,
        // since nothing in this test ever pauses or seeks.
        var buffering = 0
        var resumedAfterStart = 0
        var sawStart = false
        for event in seen {
            if case .buffering = event { buffering += 1 }
            if event == .playing {
                if sawStart { resumedAfterStart += 1 } else { sawStart = true }
            }
        }
        XCTAssertEqual(buffering, player.stats.rebufferCount)
        XCTAssertEqual(buffering, resumedAfterStart)
    }
}

import LexisCoreStream
import LexisTestSupport
import XCTest
@testable import LexisPlayer

/// A real Plex server over HTTP does not stall once for a second; it answers
/// every range request a little late, all the time. This is that source.
final class JitterTests: RealtimeTestCase {
    /// Noisy so the encoder cannot flatten it to a handful of bytes: enough
    /// packets, and enough range requests to fetch them, for jitter on each
    /// one to matter over the whole clip.
    private func jitteryFixtureData() throws -> Data {
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "jitter.mp4",
            codec: .hevc, width: 960, height: 540, frameCount: 200, fps: 24, noisy: true
        )
        return try Data(contentsOf: url)
    }

    func testJitteryHTTPDeliveryDropsNoFrames() throws {
        let server = try RangeHTTPServer(body: try jitteryFixtureData())
        defer { server.stop() }
        // Shorter than stallThreshold territory and shorter than a second: the
        // hiccups a real byte-range server produces, not one long stall.
        server.jitterFromNow(0.05...0.35)
        let handle = try XCTUnwrap(
            lexis_stream_open_http_range("\(server.baseURL)/clip.mp4", "", "", nil)
        )
        let sink = CountingSink()
        let player = LexisPlayer(sink: sink)
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
        wait(for: [ended], timeout: 90)
        collector.cancel()

        let stats = player.stats
        XCTAssertEqual(stats.packetsRead, 200)
        XCTAssertEqual(
            stats.framesDropped, 0,
            "dropped \(stats.framesDropped) of \(stats.packetsRead) packets read"
        )
    }
}

import CLexisStream
import LexisCoreStream
import LexisTestSupport
import XCTest
@testable import LexisPlayer

/// Stage 1's own criterion: `ByteCache`, reading through the full
/// `Demuxer.readPacket` path exactly as playback does, sustains a byte
/// rate at or above the measured file's own bitrate against the measured
/// profile's server, with `connectionCount` proving the pump reused one
/// connection rather than opening a fresh one per fetch. This is the
/// CI-shaped half of the criterion; the owner-server half is the first
/// slot of the measurement checklist and stays UNMEASURED in the repo
/// until the owner fills it in.
final class IOThroughputCriterionTests: RealtimeTestCase {
    func testSustainedThroughputAtTheMeasuredProfileWithConnectionReuse() throws {
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "io-throughput.mp4",
            codec: .hevc, width: 960, height: 540, frameCount: 200, fps: 24, noisy: true
        )
        let data = try Data(contentsOf: url)
        let server = try RangeHTTPServer(body: data)
        defer { server.stop() }
        let profile = MeasuredStreamProfile()
        server.serveMeasuredProfile(profile, coldFirstConnection: false)

        let handle = try XCTUnwrap(lexis_stream_open_http_range(
            "\(server.baseURL)/clip.mp4", "", "", nil
        ))
        let demuxer = try Demuxer(stream: coreStream(handle: handle))
        XCTAssertEqual(demuxer.streams.count, 1)

        let started = Date()
        var count = 0
        while try demuxer.readPacket() != nil { count += 1 }
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(count, 200)
        let sustained = Double(data.count) * 8 / elapsed
        XCTAssertGreaterThanOrEqual(sustained, profile.fileBitsPerSecond)
        // one connection for the whole file: the pump reused it rather
        // than paying a fresh TLS-shaped handshake per fetch
        XCTAssertEqual(server.connectionCount, 1)
    }
}

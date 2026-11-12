import CLexisStream
import LexisCoreStream
import LexisTestSupport
import XCTest
@testable import LexisPlayer

final class HTTPStreamTests: XCTestCase {
    /// Larger than the core's 2 MiB range-request span on purpose: a smaller
    /// clip is read whole in one request while opening, and no later failure
    /// would reach the demuxer. Noise, not flat colour, is what gets there
    /// without an expensive high-resolution encode.
    private func fixtureData() throws -> Data {
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "avio-http.mp4",
            codec: .hevc, width: 640, height: 480, frameCount: 480, fps: 24, noisy: true
        )
        return try Data(contentsOf: url)
    }

    func testDemuxesOverHTTPRange() throws {
        let data = try fixtureData()
        let server = try RangeHTTPServer(body: data)
        defer { server.stop() }
        var error: Int32 = -7
        let handle = try XCTUnwrap(lexis_stream_open_http_range(
            "\(server.baseURL)/library/parts/1/1/clip.mp4", "X-Plex-Token", "tok", &error
        ))
        XCTAssertEqual(error, LEXIS_STREAM_OK)

        let demuxer = try Demuxer(
            stream: coreStream(handle: handle),
            byteCacheWindow: testBufferPolicy.readAheadBytes)
        XCTAssertEqual(demuxer.streams.count, 1)
        XCTAssertEqual(demuxer.streams[0].codecName, "hevc")
        var count = 0
        while try demuxer.readPacket() != nil { count += 1 }
        XCTAssertEqual(count, 480)
        // the credential travelled in a header, never in the request line
        XCTAssertTrue(server.requests[0].contains("X-Plex-Token: tok"), server.requests[0])
        XCTAssertFalse(server.requests[0].hasPrefix("GET /library/parts/1/1/clip.mp4?"))
    }

    func testUnauthorizedIsAnOpenFailureThatNamesNoCredential() throws {
        let server = try RangeHTTPServer(body: try fixtureData(), unauthorized: true)
        defer { server.stop() }
        var error: Int32 = -7
        XCTAssertNil(lexis_stream_open_http_range(
            "\(server.baseURL)/clip.mp4", "X-Plex-Token", "sekrit-token", &error
        ))
        XCTAssertEqual(error, LEXIS_STREAM_ERR_UNAUTHORIZED)
    }

    func testAServerDyingMidStreamIsAReadFailureNotAnEndOfStream() throws {
        // Larger than the read-ahead window, not merely than one range span:
        // a clip that fits inside the window is fetched whole before the
        // server is told to die, and the death never reaches the demuxer.
        let data = bigStallFixtureBytes
        XCTAssertGreaterThan(
            data.count, testBufferPolicy.readAheadBytes, "a smaller clip is read whole on open")
        let server = try RangeHTTPServer(body: data)
        defer { server.stop() }
        let handle = try XCTUnwrap(lexis_stream_open_http_range(
            "\(server.baseURL)/clip.mp4", "X-Plex-Token", "sekrit-token", nil
        ))
        let demuxer = try Demuxer(
            stream: coreStream(handle: handle),
            byteCacheWindow: testBufferPolicy.readAheadBytes)
        server.failFromNow()
        var thrown: Error?
        do {
            while try demuxer.readPacket() != nil {}
        } catch {
            thrown = error
        }
        guard case .readFailed(let code, let message)? = thrown as? DemuxError else {
            return XCTFail("expected a read failure, got \(String(describing: thrown))")
        }
        XCTAssertLessThan(code, 0)
        XCTAssertFalse(message.contains("127.0.0.1"), message)
        XCTAssertFalse(message.contains("sekrit-token"), message)
    }

    func testACredentialRejectedBeforeTheProbeIsTheSameError() throws {
        let server = try RangeHTTPServer(body: try fixtureData())
        defer { server.stop() }
        let handle = try XCTUnwrap(lexis_stream_open_http_range(
            "\(server.baseURL)/clip.mp4", "X-Plex-Token", "sekrit-token", nil
        ))
        // the token dies between the core opening the stream and the probe
        // reading through it, which is the shape an expired Plex token has
        server.rejectFromNow()
        var thrown: Error?
        do {
            _ = try Demuxer(stream: coreStream(handle: handle))
        } catch {
            thrown = error
        }
        // not openFailed: an open-time refusal is as recoverable as a
        // mid-stream one, and the app tells them apart by nothing else
        XCTAssertEqual(thrown as? DemuxError, .unauthorized)
    }

    func testSeekingOverHTTPLandsOnAKeyframe() throws {
        // past the read-ahead window, so the seek has to reach the server:
        // a film the window already holds whole is seeked in memory, and the
        // cost this test exists to see would be zero
        let data = bigStallFixtureBytes
        XCTAssertGreaterThan(data.count, testBufferPolicy.readAheadBytes)
        let server = try RangeHTTPServer(body: data)
        defer { server.stop() }
        let handle = try XCTUnwrap(lexis_stream_open_http_range(
            "\(server.baseURL)/clip.mp4", "X-Plex-Token", "tok", nil
        ))
        let demuxer = try Demuxer(
            stream: coreStream(handle: handle),
            byteCacheWindow: testBufferPolicy.readAheadBytes)
        let stream = try XCTUnwrap(demuxer.streams.first { $0.kind == .video })
        XCTAssertEqual(demuxer.duration, bigStallFixtureSeconds, accuracy: 0.2)
        let requestsBefore = server.requests.count

        let target = bigStallFixtureSeconds * 2 / 3
        try demuxer.seek(to: target)
        var landed: Packet?
        while let packet = try demuxer.readPacket(), landed == nil {
            if packet.streamIndex == stream.index { landed = packet }
        }
        let packet = try XCTUnwrap(landed)
        XCTAssertTrue(packet.isKeyframe)
        let seconds = Double(try XCTUnwrap(packet.pts))
            * Double(stream.timeBaseNum) / Double(stream.timeBaseDen)
        XCTAssertLessThanOrEqual(seconds, target)
        // the encoder places its own keyframes here, so this only says the
        // seek landed near the target rather than back at the head
        XCTAssertGreaterThan(seconds, target - 4)
        // a seek that far costs at least one more range request: this is the
        // one place the cost of seeking over HTTP is visible
        XCTAssertGreaterThan(server.requests.count, requestsBefore)
    }

    func testACredentialRejectedMidStreamIsItsOwnError() throws {
        // past the read-ahead window, so the refusal lands on a request the
        // reader still has to make rather than on one it already made
        let data = bigStallFixtureBytes
        XCTAssertGreaterThan(data.count, testBufferPolicy.readAheadBytes)
        let server = try RangeHTTPServer(body: data)
        defer { server.stop() }
        let handle = try XCTUnwrap(lexis_stream_open_http_range(
            "\(server.baseURL)/clip.mp4", "X-Plex-Token", "sekrit-token", nil
        ))
        let demuxer = try Demuxer(
            stream: coreStream(handle: handle),
            byteCacheWindow: testBufferPolicy.readAheadBytes)
        XCTAssertNotNil(try demuxer.readPacket())

        // every later request is refused, exactly as a revoked token behaves
        server.rejectFromNow()
        var thrown: Error?
        do {
            while try demuxer.readPacket() != nil {}
        } catch {
            thrown = error
        }
        // not readFailed: the app has to be able to ask for a new credential
        XCTAssertEqual(thrown as? DemuxError, .unauthorized)
    }
}

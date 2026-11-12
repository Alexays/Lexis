import CLexisStream
import LexisCoreStream
import LexisTestSupport
import XCTest
@testable import LexisPlayer

final class StreamDemuxTests: XCTestCase {
    func testAFileReadsTheSameThroughAStreamAsThroughItsPath() throws {
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "avio-file.mp4",
            codec: .hevc, width: 320, height: 240, frameCount: 48, fps: 24
        )
        var error: Int32 = -7
        let handle = try XCTUnwrap(lexis_stream_open_file(url.path, &error))
        XCTAssertEqual(error, LEXIS_STREAM_OK)

        let demuxer = try Demuxer(stream: coreStream(handle: handle))
        let reference = try Demuxer(url: url)
        XCTAssertEqual(demuxer.streams, reference.streams)

        var count = 0
        var bytes = 0
        while let packet = try demuxer.readPacket() {
            let expected = try XCTUnwrap(try reference.readPacket())
            XCTAssertEqual(packet.streamIndex, expected.streamIndex)
            XCTAssertEqual(packet.pts, expected.pts)
            XCTAssertEqual(packet.dts, expected.dts)
            XCTAssertEqual(packet.isKeyframe, expected.isKeyframe)
            XCTAssertEqual(packet.copiedBytes, expected.copiedBytes)
            count += 1
            bytes += packet.copiedBytes.count
        }
        XCTAssertEqual(count, 48)
        XCTAssertGreaterThan(bytes, 1000)
        XCTAssertNil(try reference.readPacket())
    }

    func testAStreamThatIsNotAContainerFailsAndIsClosed() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("avio-not-media.bin")
        try Data(repeating: 7, count: 4096).write(to: url)
        // fifty times over, so a leaked or twice-freed context shows up
        for _ in 0..<50 {
            let handle = try XCTUnwrap(lexis_stream_open_file(url.path, nil))
            XCTAssertThrowsError(try Demuxer(stream: coreStream(handle: handle)))
        }
    }

    func testManyOpenAndCloseCyclesLeakNothing() throws {
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "avio-cycles.mp4",
            codec: .hevc, width: 320, height: 240, frameCount: 24, fps: 24
        )
        for _ in 0..<50 {
            let handle = try XCTUnwrap(lexis_stream_open_file(url.path, nil))
            let demuxer = try Demuxer(stream: coreStream(handle: handle))
            XCTAssertNotNil(try demuxer.readPacket())
        }
    }
}

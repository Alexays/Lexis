import CLexisStream
import LexisCoreStream
import XCTest
@testable import LexisPlayer

/// The core's ABI, exercised straight from Swift. Everything above it in this
/// suite goes through the same six functions.
final class CoreStreamTests: XCTestCase {
    func testReadsAFileThroughTheCoreABI() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("core-stream-smoke.bin")
        let data = Data((0..<5000).map { UInt8($0 % 251) })
        try data.write(to: url)

        var error: Int32 = -7
        let handle = try XCTUnwrap(lexis_stream_open_file(url.path, &error))
        XCTAssertEqual(error, LEXIS_STREAM_OK)
        XCTAssertEqual(lexis_stream_size(handle), 5000)

        var buffer = [UInt8](repeating: 0, count: 16)
        XCTAssertEqual(lexis_stream_read(handle, &buffer, 8), 8)
        XCTAssertEqual(Array(buffer[0..<8]), Array(data[0..<8]))
        XCTAssertEqual(lexis_stream_seek(handle, 1000, 0), 1000)
        XCTAssertEqual(lexis_stream_read(handle, &buffer, 16), 16)
        XCTAssertEqual(Array(buffer), Array(data[1000..<1016]))
        lexis_stream_close(handle)
    }

    func testAMissingFileIsANullHandleWithACode() {
        var error: Int32 = -7
        XCTAssertNil(lexis_stream_open_file("/nope/missing.mkv", &error))
        XCTAssertEqual(error, LEXIS_STREAM_ERR_NOT_FOUND)
    }

    /// The adapter is what the app uses; the suite must exercise the same one.
    func testTheAdapterReadsSeeksSizesAndClosesThroughTheCore() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("core-stream-adapter.bin")
        let data = Data((0..<5000).map { UInt8($0 % 251) })
        try data.write(to: url)

        let handle = try XCTUnwrap(lexis_stream_open_file(url.path, nil))
        let stream = coreStream(handle: handle)
        XCTAssertEqual(stream.size(stream.handle), 5000)

        var buffer = [UInt8](repeating: 0, count: 16)
        XCTAssertEqual(stream.seek(stream.handle, 1000, 0), 1000)
        XCTAssertEqual(stream.read(stream.handle, &buffer, 16), 16)
        XCTAssertEqual(Array(buffer), Array(data[1000..<1016]))
        stream.close(stream.handle)
    }
}

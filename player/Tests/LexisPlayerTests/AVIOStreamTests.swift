import CFFmpeg
import XCTest
@testable import LexisPlayer

final class AVIOStreamTests: XCTestCase {
    /// The callbacks are C function pointers and cannot capture, so the fake
    /// stream's state lives here.
    private static var closeCount = 0
    private static var position: Int64 = 0
    private static var lastSeekOffset: Int64 = -1
    private static var lastSeekWhence: Int32 = -1
    private static let contentSize: Int64 = 4096

    /// An empty stream that frees its handle when it is closed, so a leak or a
    /// double close shows up under the address sanitizer.
    private var emptyStream: MediaStreamIO {
        MediaStreamIO(
            handle: UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1),
            read: { _, _, _ in 0 },
            seek: { _, offset, _ in offset },
            size: { _ in 1024 },
            close: { handle in
                handle?.deallocate()
                AVIOStreamTests.closeCount += 1
            }
        )
    }

    /// A stream of `contentSize` bytes, each one the low byte of its offset.
    private var contentStream: MediaStreamIO {
        MediaStreamIO(
            handle: UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1),
            read: { _, buffer, size in
                guard let buffer else { return -1 }
                let remaining = max(0, AVIOStreamTests.contentSize - AVIOStreamTests.position)
                let count = min(Int64(size), remaining)
                for index in 0..<count {
                    buffer[Int(index)] = UInt8(truncatingIfNeeded: AVIOStreamTests.position + index)
                }
                AVIOStreamTests.position += count
                return count
            },
            seek: { _, offset, whence in
                AVIOStreamTests.lastSeekOffset = offset
                AVIOStreamTests.lastSeekWhence = whence
                switch whence {
                case 1: AVIOStreamTests.position += offset
                case 2: AVIOStreamTests.position = AVIOStreamTests.contentSize + offset
                default: AVIOStreamTests.position = offset
                }
                return AVIOStreamTests.position
            },
            size: { _ in AVIOStreamTests.contentSize },
            close: { handle in
                handle?.deallocate()
                AVIOStreamTests.closeCount += 1
            }
        )
    }

    override func setUp() {
        super.setUp()
        AVIOStreamTests.closeCount = 0
        AVIOStreamTests.position = 0
        AVIOStreamTests.lastSeekOffset = -1
        AVIOStreamTests.lastSeekWhence = -1
    }

    func testTheContextIsSeekableAndReleasingItClosesTheStream() throws {
        do {
            let stream = try AVIOStream(io: emptyStream)
            withExtendedLifetime(stream) {
                XCTAssertNotEqual(stream.context.pointee.seekable, 0)
                XCTAssertEqual(stream.context.pointee.buffer_size, Int32(AVIOStream.bufferSize))
                XCTAssertEqual(AVIOStreamTests.closeCount, 0)
            }
        }
        XCTAssertEqual(AVIOStreamTests.closeCount, 1)
    }

    func testAReadReturnsTheStreamsBytesAndTheEndOfItIsEOF() throws {
        let stream = try AVIOStream(io: contentStream)
        withExtendedLifetime(stream) {
            var buffer = [UInt8](repeating: 0, count: Int(AVIOStreamTests.contentSize))
            XCTAssertEqual(
                avio_read(stream.context, &buffer, Int32(AVIOStreamTests.contentSize)),
                Int32(AVIOStreamTests.contentSize)
            )
            XCTAssertEqual(buffer.first, 0)
            XCTAssertEqual(buffer.last, UInt8(truncatingIfNeeded: AVIOStreamTests.contentSize - 1))
            // the fake reads 0 bytes from here on, which has to reach avio as EOF
            XCTAssertEqual(avio_read(stream.context, &buffer, 16), LexisErrorEOF)
        }
    }

    /// The empty stream's seek answers the offset it is given, so a size taken
    /// by seeking to the end would be 0 rather than 1024.
    func testTheSizeCallbackAnswersAvioSize() throws {
        let stream = try AVIOStream(io: emptyStream)
        withExtendedLifetime(stream) {
            XCTAssertEqual(avio_size(stream.context), 1024)
        }
    }

    func testASeekReachesTheCallbackWithItsWhence() throws {
        let stream = try AVIOStream(io: contentStream)
        withExtendedLifetime(stream) {
            // avio serves a short forward seek by reading instead, so the offset
            // has to be past its short_seek_threshold to reach the callback
            XCTAssertEqual(avio_seek(stream.context, 1 << 20, 0), 1 << 20)
            // the read-ahead stream answers the seek at once and repositions
            // the real one on its own queue, so the mock sees it a beat later
            let deadline = Date(timeIntervalSinceNow: 5)
            while AVIOStreamTests.lastSeekOffset == -1, Date() < deadline {
                usleep(1_000)
            }
            XCTAssertEqual(AVIOStreamTests.lastSeekOffset, 1 << 20)
            XCTAssertEqual(AVIOStreamTests.lastSeekWhence, 0)
        }
    }

    /// The shim's values, so swapping two of them stays visible here.
    func testTheSeekConstantsAreTheFFmpegOnes() {
        XCTAssertEqual(LexisSeekSize, 0x10000)
        XCTAssertEqual(LexisSeekForce, 0x20000)
        XCTAssertEqual(LexisErrorIO, -5)
    }
}

import CFFmpeg
import LexisTestSupport
import XCTest
@testable import LexisPlayer

final class HDRFixtureTests: XCTestCase {
    func testThePQFixtureIsHDR10() throws {
        let url = try makeHDRFixture(
            directory: FileManager.default.temporaryDirectory, name: "fixture-pq.mp4",
            width: 320, height: 180, frameCount: 8, transfer: .pq
        )
        let demuxer = try Demuxer(url: url)
        XCTAssertEqual(demuxer.streams.count, 1)
        XCTAssertEqual(demuxer.streams[0].codecName, "hevc")
        // Main 10: an 8 bit encoder cannot carry PQ. general_profile_idc then
        // bit_depth_luma_minus8, at their fixed offsets in the hvcC record.
        let hvcC = try XCTUnwrap(demuxer.streams[0].extradata)
        XCTAssertEqual(hvcC[1] & 0x1f, 2)
        XCTAssertEqual((hvcC[17] & 0x07) + 8, 10)
        var packets = 0
        while try demuxer.readPacket() != nil { packets += 1 }
        XCTAssertEqual(packets, 8)
    }

    func testTheHLGFixtureCarriesDolbyVisionRPUs() throws {
        let url = try makeHDRFixture(
            directory: FileManager.default.temporaryDirectory, name: "fixture-hlg.mp4",
            width: 320, height: 180, frameCount: 8, transfer: .hlg
        )
        // AVAssetWriter tags an HLG track as Dolby Vision profile 8.4 and puts
        // one RPU in every access unit: this is the DV fixture, unmodified.
        let data = try Data(contentsOf: url)
        XCTAssertNotNil(data.range(of: Data("dvvC".utf8)))
        let demuxer = try Demuxer(url: url)
        var withRPU = 0
        while let packet = try demuxer.readPacket() {
            var offset = packet.copiedBytes.startIndex
            while offset + 6 <= packet.copiedBytes.endIndex {
                var length = 0
                for i in 0..<4 { length = length << 8 | Int(packet.copiedBytes[offset + i]) }
                guard length >= 3, offset + 4 + length <= packet.copiedBytes.endIndex else { break }
                if (packet.copiedBytes[offset + 4] >> 1) & 0x3f == 62 { withRPU += 1 }
                offset += 4 + length
            }
        }
        XCTAssertEqual(withRPU, 8)
    }

    func testTheMasteringPayloadsAreTheOnesTheFileCarries() throws {
        let url = try makeHDRFixture(
            directory: FileManager.default.temporaryDirectory, name: "fixture-meta.mp4",
            width: 320, height: 180, frameCount: 4, transfer: .pq
        )
        let data = try Data(contentsOf: url)
        // The payloads only reach the file as compression properties: as pixel
        // buffer attachments they are dropped without an error.
        let mdcv = try XCTUnwrap(data.range(of: Data("mdcv".utf8)))
        XCTAssertEqual(data[mdcv.upperBound..<mdcv.upperBound + 24], hdrMasteringDisplayVolume)
        let clli = try XCTUnwrap(data.range(of: Data("clli".utf8)))
        XCTAssertEqual(data[clli.upperBound..<clli.upperBound + 4], hdrContentLightLevel)
    }

    func testWithoutTheMetadataTheBoxesAreAbsent() throws {
        let url = try makeHDRFixture(
            directory: FileManager.default.temporaryDirectory, name: "fixture-no-meta.mp4",
            width: 320, height: 180, frameCount: 4, transfer: .pq, metadata: false
        )
        let data = try Data(contentsOf: url)
        XCTAssertNil(data.range(of: Data("mdcv".utf8)))
        XCTAssertNil(data.range(of: Data("clli".utf8)))
    }
}

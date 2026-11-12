import CFFmpeg
import Foundation
import XCTest
@testable import LexisPlayer

/// The pictures a decoder behind the clock may leave undecoded: nothing may
/// predict from them.
final class NonReferencePicturesTests: XCTestCase {
    private func stream(codec: AVCodecID, config: [UInt8]) -> MediaStream {
        MediaStream(
            index: 0, kind: .video, codecID: codec.rawValue, codecName: "",
            width: 1920, height: 1080, timeBaseNum: 1, timeBaseDen: 24000,
            sampleRate: 0, channels: 0, videoDelay: 2, language: "", title: "",
            isDefault: true, isForced: false,
            colorPrimaries: 1, colorTransfer: 1, colorMatrix: 1, isFullRange: false,
            masteringDisplay: nil, contentLight: nil, dolbyVision: nil,
            extradata: Data(config))
    }

    /// An access unit of four byte lengths, one NAL unit per header given,
    /// each with a byte of payload after its header.
    private func accessUnit(_ headers: [[UInt8]]) -> [UInt8] {
        headers.flatMap { header in [0, 0, 0, UInt8(header.count + 1)] + header + [0x80] }
    }

    private func contains(_ pictures: NonReferencePictures, _ unit: [UInt8]) -> Bool {
        unit.withUnsafeBytes { pictures.contains($0) }
    }

    /// avcC with four byte lengths: an H.264 slice with a nal_ref_idc of 0 is
    /// predicted from by nothing, one above 0 and an IDR are; the parameter
    /// sets and SEI ahead of the slice are passed over.
    func testAnH264SliceNothingReferencesIsSkippable() throws {
        let pictures = try XCTUnwrap(NonReferencePictures(
            stream: stream(codec: AV_CODEC_ID_H264, config: [1, 0x64, 0, 0x28, 0xFF])))
        XCTAssertTrue(contains(pictures, accessUnit([[0x09], [0x06], [0x01]])))
        XCTAssertFalse(contains(pictures, accessUnit([[0x09], [0x21]])))
        XCTAssertFalse(contains(pictures, accessUnit([[0x65]])))
        XCTAssertFalse(contains(pictures, accessUnit([[0x06]])), "no slice is no answer")
    }

    /// hvcC with four byte lengths: a `_N` slice is skippable only in the
    /// highest temporal sub-layer, since a lower one's may still be
    /// predicted from by a layer above it; a `_R` slice never is.
    func testAnHEVCSliceIsSkippableOnlyInTheTopSubLayer() throws {
        func hvcC(layers: UInt8) -> [UInt8] {
            var config = [UInt8](repeating: 0, count: 23)
            config[0] = 1
            config[21] = layers << 3 | 0x03
            return config
        }
        // type in bits 1 to 6 of the first byte, temporal id plus one in the
        // low bits of the second
        func slice(_ type: UInt8, temporalId: UInt8) -> [UInt8] { [type << 1, temporalId + 1] }
        let single = try XCTUnwrap(NonReferencePictures(stream: stream(codec: AV_CODEC_ID_HEVC, config: hvcC(layers: 1))))
        XCTAssertTrue(contains(single, accessUnit([[35 << 1, 1], slice(0, temporalId: 0)])), "TRAIL_N")
        XCTAssertFalse(contains(single, accessUnit([slice(1, temporalId: 0)])), "TRAIL_R")
        XCTAssertFalse(contains(single, accessUnit([slice(19, temporalId: 0)])), "IDR")
        let layered = try XCTUnwrap(NonReferencePictures(stream: stream(codec: AV_CODEC_ID_HEVC, config: hvcC(layers: 2))))
        XCTAssertFalse(contains(layered, accessUnit([slice(0, temporalId: 0)])))
        XCTAssertTrue(contains(layered, accessUnit([slice(0, temporalId: 1)])))
        XCTAssertNil(NonReferencePictures(stream: stream(codec: AV_CODEC_ID_HEVC, config: hvcC(layers: 0))),
                     "an unknown layer count tells nothing apart")
    }
}

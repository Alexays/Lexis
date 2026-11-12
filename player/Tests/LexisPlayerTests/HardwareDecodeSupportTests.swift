import CoreMedia
import VideoToolbox
import XCTest
@testable import LexisPlayer

final class HardwareDecodeSupportTests: XCTestCase {
    func testKnownCodecsAnswerFromTheSessionAPIItself() {
        XCTAssertEqual(
            isHardwareDecodeSupported(ffmpegCodecName: "h264"),
            VTIsHardwareDecodeSupported(kCMVideoCodecType_H264)
        )
        XCTAssertEqual(
            isHardwareDecodeSupported(ffmpegCodecName: "hevc"),
            VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
        )
        XCTAssertEqual(
            isHardwareDecodeSupported(ffmpegCodecName: "av1"),
            VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
        )
        XCTAssertEqual(
            isHardwareDecodeSupported(ffmpegCodecName: "vp9"),
            VTIsHardwareDecodeSupported(kCMVideoCodecType_VP9)
        )
        XCTAssertEqual(
            isHardwareDecodeSupported(ffmpegCodecName: "mpeg2video"),
            VTIsHardwareDecodeSupported(kCMVideoCodecType_MPEG2Video)
        )
    }

    func testAnUnrecognizedCodecNameIsUnmeasuredNotFalse() {
        XCTAssertNil(isHardwareDecodeSupported(ffmpegCodecName: "theora"))
        XCTAssertNil(appleVideoCodecType(forFFmpegCodecName: "theora"))
    }

    func testMPEG2HasNoHardwareDecoderOnAnyAppleChip() {
        // The bench's first verdict rests on this staying false everywhere:
        // a codec with no hardware decoder anywhere is a known, named case,
        // not a failure to cry wolf about.
        XCTAssertEqual(VTIsHardwareDecodeSupported(kCMVideoCodecType_MPEG2Video), false)
    }
}

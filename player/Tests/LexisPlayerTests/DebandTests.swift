import CFFmpeg
import XCTest
@testable import LexisPlayer

final class DebandTests: XCTestCase {
    private func stream(
        codec: AVCodecID, width: Int32, height: Int32, bitsPerSecond: Int64
    ) -> MediaStream {
        var stream = MediaStream(
            index: 0, kind: .video, codecID: codec.rawValue, codecName: "",
            width: width, height: height, timeBaseNum: 1, timeBaseDen: 24000,
            sampleRate: 0, channels: 0, videoDelay: 0, language: "", title: "",
            isDefault: true, isForced: false,
            colorPrimaries: 1, colorTransfer: 1, colorMatrix: 1, isFullRange: false,
            masteringDisplay: nil, contentLight: nil, dolbyVision: nil,
            extradata: nil
        )
        stream.frameRateNum = 24
        stream.frameRateDen = 1
        stream.bitsPerSecond = bitsPerSecond
        return stream
    }

    /// A remux keeps the deband's own threshold, a starved encode doubles
    /// it, and H.264 is weighed at half its bits.
    func testTheStrengthFollowsTheBitsPerPixel() {
        let remux = stream(codec: AV_CODEC_ID_HEVC, width: 3840, height: 2160, bitsPerSecond: 60_000_000)
        XCTAssertEqual(Deband.strength(for: remux, fileBitsPerSecond: 0), 1)
        let starved = stream(codec: AV_CODEC_ID_HEVC, width: 3840, height: 2160, bitsPerSecond: 6_000_000)
        XCTAssertEqual(Deband.strength(for: starved, fileBitsPerSecond: 0), 2)
        // 10 Mb/s at 1080p24 is 0.2 bits a pixel: HEVC's full, H.264's half
        let hevc = stream(codec: AV_CODEC_ID_HEVC, width: 1920, height: 1080, bitsPerSecond: 9_953_280)
        let avc = stream(codec: AV_CODEC_ID_H264, width: 1920, height: 1080, bitsPerSecond: 9_953_280)
        XCTAssertEqual(Deband.strength(for: hevc, fileBitsPerSecond: 0), 1, accuracy: 1e-4)
        XCTAssertEqual(Deband.strength(for: avc, fileBitsPerSecond: 0), 1.5, accuracy: 1e-4)
    }

    /// A track that states no rate is read at the file's; a file that states
    /// none either keeps the deband's own threshold.
    func testATrackWithNoRateIsReadAtTheFiles() {
        let silent = stream(codec: AV_CODEC_ID_HEVC, width: 3840, height: 2160, bitsPerSecond: 0)
        XCTAssertEqual(Deband.strength(for: silent, fileBitsPerSecond: 6_000_000), 2)
        XCTAssertEqual(Deband.strength(for: silent, fileBitsPerSecond: 0), 1)
    }
}

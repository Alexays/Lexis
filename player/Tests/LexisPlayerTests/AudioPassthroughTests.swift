import CFFmpeg
import CoreMedia
import Foundation
import XCTest
@testable import LexisPlayer

final class AudioPassthroughTests: XCTestCase {
    func testTheCompressedFormatsQualifyAndPCMCodecsDoNot() {
        XCTAssertEqual(compressedAudioFormat(codecID: AV_CODEC_ID_AC3.rawValue), .ac3)
        XCTAssertEqual(compressedAudioFormat(codecID: AV_CODEC_ID_EAC3.rawValue), .eac3)
        XCTAssertEqual(compressedAudioFormat(codecID: AV_CODEC_ID_DTS.rawValue), .dts)
        XCTAssertEqual(compressedAudioFormat(codecID: AV_CODEC_ID_TRUEHD.rawValue), .trueHD)
        XCTAssertNil(compressedAudioFormat(codecID: AV_CODEC_ID_AAC.rawValue))
        XCTAssertNil(compressedAudioFormat(codecID: AV_CODEC_ID_FLAC.rawValue))
    }

    /// CoreAudio has no public name for either format, so the descriptions
    /// carry the registered FourCCs; whether a route takes them is the
    /// route's own answer, and a refusal is the decode fallback the engine
    /// already runs for a refused AC-3 buffer.
    func testDTSAndTrueHDDescribeThemselvesByTheirFourCCs() throws {
        let dts = try makeCompressedAudioFormatDescription(
            format: .dts, sampleRate: 48000, channels: 6
        )
        let dtsASBD = try XCTUnwrap(
            CMAudioFormatDescriptionGetStreamBasicDescription(dts)
        ).pointee
        XCTAssertEqual(dtsASBD.mFormatID, 0x4454_5320) // 'DTS '
        XCTAssertEqual(dtsASBD.mFramesPerPacket, 512)

        let trueHD = try makeCompressedAudioFormatDescription(
            format: .trueHD, sampleRate: 48000, channels: 8
        )
        let trueHDASBD = try XCTUnwrap(
            CMAudioFormatDescriptionGetStreamBasicDescription(trueHD)
        ).pointee
        XCTAssertEqual(trueHDASBD.mFormatID, 0x7472_6864) // 'trhd'
        // an MLP access unit is 40 samples at 48 kHz
        XCTAssertEqual(trueHDASBD.mFramesPerPacket, 40)
        XCTAssertEqual(trueHDASBD.mChannelsPerFrame, 8)
    }

    func testTheFormatDescriptionNamesTheContainerNotPCM() throws {
        let format = try makeCompressedAudioFormatDescription(
            format: .eac3, sampleRate: 48000, channels: 6
        )
        let asbd = try XCTUnwrap(
            CMAudioFormatDescriptionGetStreamBasicDescription(format)
        ).pointee
        XCTAssertEqual(asbd.mFormatID, kAudioFormatEnhancedAC3)
        XCTAssertEqual(asbd.mSampleRate, 48000)
        XCTAssertEqual(asbd.mChannelsPerFrame, 6)
    }

    func testTheSampleBufferCarriesThePacketsBytesUntouched() throws {
        let format = try makeCompressedAudioFormatDescription(
            format: .ac3, sampleRate: 48000, channels: 6
        )
        let bytes = Data([0x0b, 0x77, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06])
        let packet = Packet(
            streamIndex: 1, pts: 1500, dts: 1500, isKeyframe: true,
            isDisposable: false, duration: 1536, data: bytes
        )
        let sample = try makeCompressedAudioSampleBuffer(
            packet: packet, formatDescription: format, timeBaseNum: 1, timeBaseDen: 48000
        )
        XCTAssertEqual(CMSampleBufferGetTotalSampleSize(sample), bytes.count)
        XCTAssertEqual(
            CMSampleBufferGetPresentationTimeStamp(sample), CMTime(value: 1500, timescale: 48000)
        )
        XCTAssertEqual(
            CMSampleBufferGetDuration(sample), CMTime(value: 1536, timescale: 48000)
        )
        XCTAssertEqual(
            CMSampleBufferGetDecodeTimeStamp(sample), CMTime(value: 1500, timescale: 48000)
        )
        let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample))
        var length = 0
        var pointer: UnsafeMutablePointer<Int8>?
        XCTAssertEqual(
            CMBlockBufferGetDataPointer(
                block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
                dataPointerOut: &pointer
            ), noErr
        )
        let read = Data(bytes: pointer!, count: length)
        XCTAssertEqual(read, bytes)
    }

    func testTimestampsScaleByTheWholeRationalTimeBaseNotJustTheDenominator() throws {
        let format = try makeCompressedAudioFormatDescription(
            format: .ac3, sampleRate: 48000, channels: 6
        )
        let packet = Packet(
            streamIndex: 1, pts: 1500, dts: 1500, isKeyframe: true,
            isDisposable: false, duration: 1536, data: Data([0x0b, 0x77])
        )
        let sample = try makeCompressedAudioSampleBuffer(
            packet: packet, formatDescription: format, timeBaseNum: 2, timeBaseDen: 48000
        )
        XCTAssertEqual(
            CMSampleBufferGetPresentationTimeStamp(sample), CMTime(value: 3000, timescale: 48000)
        )
        XCTAssertEqual(
            CMSampleBufferGetDuration(sample), CMTime(value: 3072, timescale: 48000)
        )
        XCTAssertEqual(
            CMSampleBufferGetDecodeTimeStamp(sample), CMTime(value: 3000, timescale: 48000)
        )
    }
}

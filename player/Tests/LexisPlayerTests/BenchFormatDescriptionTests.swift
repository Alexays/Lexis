import CFFmpeg
import CoreMedia
import XCTest
@testable import LexisPlayer

final class BenchFormatDescriptionTests: XCTestCase {
    static let corpusDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".bench-corpus")

    /// A bare stream this file only needs the codec ID and dimensions of -
    /// VP9's own tests never touch extradata, since VP9 carries none.
    func vp9Stream(width: Int32 = 960, height: Int32 = 540) -> MediaStream {
        MediaStream(
            index: 0, kind: .video, codecID: AV_CODEC_ID_VP9.rawValue, codecName: "vp9",
            width: width, height: height, timeBaseNum: 1, timeBaseDen: 24,
            sampleRate: 0, channels: 0, videoDelay: 0, language: "", title: "",
            isDefault: true, isForced: false,
            colorPrimaries: 2, colorTransfer: 2, colorMatrix: 2, isFullRange: false,
            masteringDisplay: nil, contentLight: nil, dolbyVision: nil, extradata: nil
        )
    }

    // The corpus's own first packet for vp9.mkv, profile 0, 8 bit, 4:2:0,
    // color_space unknown, color_range 0, 960x540 - verified against the
    // real file this task generated, byte for byte, before this parser was
    // written (see task 4b's report).
    static let realVP9FirstPacketPrefix = Data([
        0x82, 0x49, 0x83, 0x42, 0x00, 0x3b, 0xf0, 0x21, 0xb6,
    ])

    func testVP9BuildsFromTheRealBitstreamsOwnHeader() throws {
        let format = try benchFormatDescription(
            for: vp9Stream(), firstKeyframe: Self.realVP9FirstPacketPrefix
        )
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        XCTAssertEqual(dimensions.width, 960)
        XCTAssertEqual(dimensions.height, 540)
    }

    func testVP9ShowingAnExistingFrameIsNotAKeyFrame() {
        // byte0 bit3 (show_existing_frame) set: 1000_1010
        XCTAssertThrowsError(
            try benchFormatDescription(for: vp9Stream(), firstKeyframe: Data([0x8A]))
        ) {
            XCTAssertEqual($0 as? BenchFormatDescriptionError, .vp9FirstPacketNotAKeyFrame)
        }
    }

    func testVP9ANonKeyFrameIsNotAKeyFrame() {
        // byte0 bit2 (frame_type) set to 1 (non-key): 1000_0110
        XCTAssertThrowsError(
            try benchFormatDescription(for: vp9Stream(), firstKeyframe: Data([0x86]))
        ) {
            XCTAssertEqual($0 as? BenchFormatDescriptionError, .vp9FirstPacketNotAKeyFrame)
        }
    }

    func testVP9AWrongFrameSyncCodeIsMalformed() {
        // The real corpus prefix (see realVP9FirstPacketPrefix) with the
        // frame_sync_code bytes (index 1-3) corrupted, keeping every other
        // byte and the overall length identical: a parser that forgot to
        // check the sync code would otherwise sail through this input
        // exactly as it does the valid one, rather than throw.
        var corrupted = Self.realVP9FirstPacketPrefix
        corrupted[1] = 0x00
        corrupted[2] = 0x00
        corrupted[3] = 0x00
        XCTAssertThrowsError(
            try benchFormatDescription(for: vp9Stream(), firstKeyframe: corrupted)
        ) {
            XCTAssertEqual($0 as? BenchFormatDescriptionError, .vp9HeaderMalformed)
        }
    }

    func testVP9ATruncatedHeaderIsMalformedNotACrash() {
        XCTAssertThrowsError(
            try benchFormatDescription(for: vp9Stream(), firstKeyframe: Data([0x82]))
        ) {
            XCTAssertEqual($0 as? BenchFormatDescriptionError, .vp9HeaderMalformed)
        }
    }

    func testAV1UsesTheContainersOwnAv1CRecordUnmodified() throws {
        let url = Self.corpusDir.appendingPathComponent("av1.mkv")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("corpus not generated: run player/scripts/make-benchmark-corpus.sh")
        }
        let demuxer = try Demuxer(url: url)
        let stream = try XCTUnwrap(demuxer.streams.first { $0.kind == .video })
        let packet = try XCTUnwrap(try demuxer.readPacket())
        let format = try benchFormatDescription(for: stream, firstKeyframe: packet.copiedBytes)
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        XCTAssertEqual(Int32(dimensions.width), stream.width)
        XCTAssertEqual(Int32(dimensions.height), stream.height)
    }

    func testMPEG2NeedsNoOutOfBandAtomAtAll() throws {
        let url = Self.corpusDir.appendingPathComponent("mpeg2.ts")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("corpus not generated: run player/scripts/make-benchmark-corpus.sh")
        }
        let demuxer = try Demuxer(url: url)
        let stream = try XCTUnwrap(demuxer.streams.first { $0.kind == .video })
        let packet = try XCTUnwrap(try demuxer.readPacket())
        // Every sample opens with its own sequence_header() in band
        // (verified for this task): an empty firstKeyframe still succeeds,
        // proving nothing here actually reads it for MPEG-2.
        let format = try benchFormatDescription(for: stream, firstKeyframe: Data())
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        XCTAssertEqual(Int32(dimensions.width), stream.width)
        XCTAssertEqual(Int32(dimensions.height), stream.height)
        _ = packet
    }

    func testAnUnrecognizedCodecStillReportsUnsupported() {
        let stream = MediaStream(
            index: 0, kind: .video, codecID: AV_CODEC_ID_THEORA.rawValue, codecName: "theora",
            width: 320, height: 180, timeBaseNum: 1, timeBaseDen: 24,
            sampleRate: 0, channels: 0, videoDelay: 0, language: "", title: "",
            isDefault: true, isForced: false,
            colorPrimaries: 2, colorTransfer: 2, colorMatrix: 2, isFullRange: false,
            masteringDisplay: nil, contentLight: nil, dolbyVision: nil, extradata: nil
        )
        XCTAssertThrowsError(try benchFormatDescription(for: stream, firstKeyframe: Data())) {
            XCTAssertEqual($0 as? SampleBufferError, .unsupportedCodec("theora"))
        }
    }
}

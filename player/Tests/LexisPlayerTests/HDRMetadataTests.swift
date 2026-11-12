import CFFmpeg
import CoreMedia
import LexisTestSupport
import XCTest
@testable import LexisPlayer

final class HDRMetadataTests: XCTestCase {
    func testAPQStreamDescribesItsColour() throws {
        let url = try makeHDRFixture(
            directory: FileManager.default.temporaryDirectory, name: "meta-pq.mp4",
            width: 320, height: 180, frameCount: 8, transfer: .pq
        )
        let stream = try Demuxer(url: url).streams[0]
        // AVCOL_PRI_BT2020, AVCOL_TRC_SMPTE2084, AVCOL_SPC_BT2020_NCL
        XCTAssertEqual(stream.colorPrimaries, 9)
        XCTAssertEqual(stream.colorTransfer, 16)
        XCTAssertEqual(stream.colorMatrix, 9)
        XCTAssertFalse(stream.isFullRange)
        XCTAssertTrue(isHighDynamicRange(stream.colorTransfer))
        // byte for byte what the writer put in the mdcv and clli boxes, which
        // is also the layout a format description wants
        XCTAssertEqual(stream.masteringDisplay, hdrMasteringDisplayVolume)
        XCTAssertEqual(stream.contentLight, hdrContentLightLevel)
        XCTAssertNil(stream.dolbyVision)
        // The stream reorders, which is the window the tone mapped path needs
        // later. The exact depth is the encoder's choice, not the container's,
        // so it is bounded rather than pinned.
        XCTAssertGreaterThan(stream.videoDelay, 0)
        XCTAssertLessThanOrEqual(stream.videoDelay, 16)
    }

    func testAStreamWithoutTheBoxesSaysSo() throws {
        let url = try makeHDRFixture(
            directory: FileManager.default.temporaryDirectory, name: "meta-bare.mp4",
            width: 320, height: 180, frameCount: 4, transfer: .pq, metadata: false
        )
        let stream = try Demuxer(url: url).streams[0]
        XCTAssertEqual(stream.colorTransfer, 16)
        XCTAssertNil(stream.masteringDisplay)
        XCTAssertNil(stream.contentLight)
    }

    func testAnHLGStreamIsDolbyVisionProfile8() throws {
        let url = try makeHDRFixture(
            directory: FileManager.default.temporaryDirectory, name: "meta-hlg.mp4",
            width: 320, height: 180, frameCount: 8, transfer: .hlg
        )
        let stream = try Demuxer(url: url).streams[0]
        // AVCOL_TRC_ARIB_STD_B67
        XCTAssertEqual(stream.colorTransfer, 18)
        XCTAssertTrue(isHighDynamicRange(stream.colorTransfer))
        let dolby = try XCTUnwrap(stream.dolbyVision)
        XCTAssertEqual(dolby.profile, 8)
        XCTAssertEqual(dolby.level, 1)
        XCTAssertTrue(dolby.hasRPU)
        XCTAssertFalse(dolby.hasEnhancementLayer)
        XCTAssertTrue(dolby.hasBaseLayer)
        // 4 is HLG: the base layer is a picture on its own
        XCTAssertEqual(dolby.compatibility, 4)
        XCTAssertTrue(dolby.baseLayerIsDisplayable)
        XCTAssertEqual(dolby.atomKey, "dvvC")
        // rebuilt from FFmpeg's parsed struct, and identical to the box
        let data = try Data(contentsOf: url)
        let box = try XCTUnwrap(data.range(of: Data("dvvC".utf8)))
        XCTAssertEqual(dolby.record, Data(data[box.upperBound..<(box.upperBound + 24)]))
    }

    func testAMalformedRationalConvertsToZero() {
        // A container can carry a 0/0 rational, which scales to NaN. min and
        // max propagate NaN rather than clamp it, and the conversion traps.
        var metadata = AVMasteringDisplayMetadata()
        metadata.has_primaries = 1
        metadata.has_luminance = 1
        let broken = AVRational(num: 0, den: 0)
        // FFmpeg order, so the good pair here is green: it comes out first
        metadata.display_primaries = (
            (broken, broken),
            (AVRational(num: 13250, den: 50000), AVRational(num: 34500, den: 50000)),
            (broken, broken)
        )
        metadata.white_point = (broken, broken)
        metadata.max_luminance = AVRational(num: 1000, den: 1)
        metadata.min_luminance = broken
        var expected = Data([0x33, 0xc2, 0x86, 0xc4])
        expected.append(Data(repeating: 0, count: 12))
        expected.append(Data([0x00, 0x98, 0x96, 0x80]))
        expected.append(Data(repeating: 0, count: 4))
        XCTAssertEqual(masteringDisplayVolume(metadata), expected)
    }

    func testAnSDRStreamIsUntouched() throws {
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "meta-sdr.mp4",
            codec: .h264, width: 320, height: 180, frameCount: 10, fps: 30
        )
        let stream = try Demuxer(url: url).streams[0]
        // AVCOL_*_UNSPECIFIED: the container says nothing and nothing is invented
        XCTAssertEqual(stream.colorPrimaries, 2)
        XCTAssertEqual(stream.colorTransfer, 2)
        XCTAssertEqual(stream.colorMatrix, 2)
        XCTAssertFalse(isHighDynamicRange(stream.colorTransfer))
        XCTAssertNil(stream.masteringDisplay)
        XCTAssertNil(stream.dolbyVision)
    }
}

final class HDRFormatDescriptionTests: XCTestCase {
    func testAPQFormatDescriptionCarriesEverything() throws {
        let url = try makeHDRFixture(
            directory: FileManager.default.temporaryDirectory, name: "fd-pq.mp4",
            width: 320, height: 180, frameCount: 8, transfer: .pq
        )
        let stream = try Demuxer(url: url).streams[0]
        let format = try makeFormatDescription(for: stream)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(format), kCMVideoCodecType_HEVC)
        let extensions = try XCTUnwrap(
            CMFormatDescriptionGetExtensions(format) as? [CFString: Any]
        )
        // as String: a conditional cast to CFString always succeeds, so it is
        // the bridged type that tells a missing key from a wrong one
        XCTAssertEqual(
            extensions[kCMFormatDescriptionExtension_TransferFunction] as? String,
            kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String
        )
        XCTAssertEqual(
            extensions[kCMFormatDescriptionExtension_ColorPrimaries] as? String,
            kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String
        )
        XCTAssertEqual(
            extensions[kCMFormatDescriptionExtension_YCbCrMatrix] as? String,
            kCMFormatDescriptionYCbCrMatrix_ITU_R_2020 as String
        )
        XCTAssertEqual(
            try XCTUnwrap(
                extensions[kCMFormatDescriptionExtension_MasteringDisplayColorVolume] as? Data
            ),
            hdrMasteringDisplayVolume
        )
        XCTAssertEqual(
            try XCTUnwrap(extensions[kCMFormatDescriptionExtension_ContentLightLevelInfo] as? Data),
            hdrContentLightLevel
        )
    }

    /// Without the extensions VideoToolbox invents a colour space, and it
    /// invents an SDR one: this is the whole point of the task.
    func testTheDecoderNoLongerGuesses() throws {
        let url = try makeHDRFixture(
            directory: FileManager.default.temporaryDirectory, name: "fd-guess.mp4",
            width: 320, height: 180, frameCount: 8, transfer: .pq
        )
        let demuxer = try Demuxer(url: url)
        let stream = demuxer.streams[0]
        let format = try makeFormatDescription(for: stream)
        let lock = NSLock()
        var first: CVPixelBuffer?
        let decoder = try VideoDecoder(formatDescription: format) { frame in
            lock.lock()
            if first == nil { first = frame.imageBuffer }
            lock.unlock()
        }
        while let packet = try demuxer.readPacket() {
            try decoder.decode(try makeSampleBuffer(
                packet: packet, formatDescription: format,
                timeBaseNum: stream.timeBaseNum, timeBaseDen: stream.timeBaseDen
            ))
        }
        decoder.waitForPendingFrames()
        lock.lock()
        let buffer = try XCTUnwrap(first)
        lock.unlock()
        let attachments = CVBufferCopyAttachments(buffer, .shouldPropagate) as? [CFString: Any]
        XCTAssertEqual(
            attachments?[kCVImageBufferTransferFunctionKey] as! CFString?,
            kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
        )
        XCTAssertNil(attachments?["ColorInfoGuessedBy" as CFString])
    }

    func testADolbyVisionTrackIsDescribedAsOne() throws {
        let url = try makeHDRFixture(
            directory: FileManager.default.temporaryDirectory, name: "fd-dv.mp4",
            width: 320, height: 180, frameCount: 8, transfer: .hlg
        )
        let stream = try Demuxer(url: url).streams[0]
        let format = try makeFormatDescription(for: stream)
        // The shape the container itself uses, and the one AVFoundation builds
        // for this file: the sample entry stays hvc1 and the record rides along.
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(format), kCMVideoCodecType_HEVC)
        let atoms = try XCTUnwrap(CMFormatDescriptionGetExtension(
            format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms
        ) as? [String: Any])
        XCTAssertEqual(atoms.keys.sorted(), ["dvvC", "hvcC"])
        XCTAssertEqual(
            try XCTUnwrap(atoms["dvvC"] as? Data), try XCTUnwrap(stream.dolbyVision).record
        )
    }

    func testAProfileFiveTrackIsNotHandedToTheDisplay() throws {
        let url = try makeHDRFixture(
            directory: FileManager.default.temporaryDirectory, name: "fd-p5.mp4",
            width: 320, height: 180, frameCount: 4, transfer: .hlg
        )
        var stream = try Demuxer(url: url).streams[0]
        // no profile 5 sample can be authored here, so the configuration is
        // rewritten: what is tested is the branch, not the picture
        let dolby = try XCTUnwrap(stream.dolbyVision)
        stream = MediaStream(
            index: stream.index, kind: stream.kind, codecID: stream.codecID,
            codecName: stream.codecName, width: stream.width, height: stream.height,
            timeBaseNum: stream.timeBaseNum, timeBaseDen: stream.timeBaseDen,
            sampleRate: stream.sampleRate, channels: stream.channels,
            videoDelay: stream.videoDelay, language: stream.language, title: stream.title,
            isDefault: stream.isDefault, isForced: stream.isForced,
            colorPrimaries: stream.colorPrimaries, colorTransfer: stream.colorTransfer,
            colorMatrix: stream.colorMatrix, isFullRange: stream.isFullRange,
            masteringDisplay: stream.masteringDisplay, contentLight: stream.contentLight,
            dolbyVision: DolbyVisionConfiguration(
                profile: 5, level: dolby.level, hasRPU: true, hasEnhancementLayer: false,
                hasBaseLayer: true, compatibility: 0, record: dolby.record
            ),
            extradata: stream.extradata
        )
        XCTAssertFalse(try XCTUnwrap(stream.dolbyVision).baseLayerIsDisplayable)
        XCTAssertEqual(try XCTUnwrap(stream.dolbyVision).atomKey, "dvcC")
        let format = try makeFormatDescription(for: stream)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(format), kCMVideoCodecType_HEVC)
        // no record at all: the base layer is described as plain HEVC
        let atoms = try XCTUnwrap(CMFormatDescriptionGetExtension(
            format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms
        ) as? [String: Any])
        XCTAssertEqual(atoms.keys.sorted(), ["hvcC"])
    }
}

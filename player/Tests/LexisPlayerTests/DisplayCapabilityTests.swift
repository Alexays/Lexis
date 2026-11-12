import CFFmpeg
import CoreMedia
import CoreVideo
import LexisTestSupport
import VideoToolbox
import XCTest
@testable import LexisPlayer

final class DisplayCapabilityTests: XCTestCase {
    func testWhatAHeadroomMeans() {
        let sdr = DisplayCapability(headroom: 1)
        XCTAssertFalse(sdr.isHighDynamicRange)
        // 100 nits is SDR white, and PQ says 0.5081 for it
        XCTAssertEqual(sdr.targetMaxPQ, 0.5081, accuracy: 0.0005)
        let hdr = DisplayCapability(headroom: 10)
        XCTAssertTrue(hdr.isHighDynamicRange)
        // 1000 nits
        XCTAssertEqual(hdr.targetMaxPQ, 0.7518, accuracy: 0.0005)
        // nothing is ever asked to show more than PQ can describe
        XCTAssertEqual(DisplayCapability(headroom: 1000).targetMaxPQ, 1.0, accuracy: 0.0005)
    }

    func testTheMasteringPeakComesOffTheBox() throws {
        // 1000 nits, which is what the fixture is mastered at
        XCTAssertEqual(
            try XCTUnwrap(masteringPeakPQ(hdrMasteringDisplayVolume)), 0.7518, accuracy: 0.0005)
        // A 4000 nit grade, raw field 40_000_000.
        var brighter = hdrMasteringDisplayVolume
        brighter.replaceSubrange(16..<20, with: [0x02, 0x62, 0x5a, 0x00])
        XCTAssertEqual(try XCTUnwrap(masteringPeakPQ(brighter)), 0.9026, accuracy: 0.0005)
        // and off the payload's own start, not off zero
        var padded = Data([0xff, 0xff])
        padded.append(brighter)
        XCTAssertEqual(
            try XCTUnwrap(masteringPeakPQ(padded.dropFirst(2))), 0.9026, accuracy: 0.0005)
        // No box, a box too short to hold the field, and a grade of zero: the
        // stream states nothing, and saying so is the answer. A stand-in
        // returned from here would be indistinguishable from a real 1000 nit
        // grade, and the curve treats the two differently - a stated grade may
        // clip above itself, a guess may not.
        XCTAssertNil(masteringPeakPQ(nil))
        XCTAssertNil(masteringPeakPQ(brighter.prefix(23)))
        var ungraded = hdrMasteringDisplayVolume
        ungraded.replaceSubrange(16..<20, with: [0, 0, 0, 0])
        XCTAssertNil(masteringPeakPQ(ungraded))
    }

    /// MaxCLL is the brightest pixel in the film; the mastering display's peak
    /// is what the monitor could have shown. The curve wants the first.
    func testTheContentPeakComesOffTheLightLevelBox() throws {
        // CTA-861.3: MaxCLL then MaxFALL, big endian, in nits. 800 and 200.
        let light = Data([0x03, 0x20, 0x00, 0xc8])
        XCTAssertEqual(try XCTUnwrap(contentPeakPQ(light)), 0.7275, accuracy: 0.0005)
        // A box stating only a frame average says nothing about the peak, and
        // neither does no box at all.
        XCTAssertNil(contentPeakPQ(Data([0x00, 0x00, 0x00, 0xc8])))
        XCTAssertNil(contentPeakPQ(nil))
        XCTAssertNil(contentPeakPQ(Data([0x03])))
        // Past 10000 nits the PQ curve has nowhere left to go, and a container
        // is free to state anything at all.
        XCTAssertEqual(try XCTUnwrap(contentPeakPQ(Data([0xff, 0xff]))), 1.0, accuracy: 0.0005)
    }

    /// The other half of the same box, and the one nothing was reading.
    func testTheMasteringBlackComesOffTheBox() throws {
        // The fixture's own black, in units of 0.0001 cd/m2.
        var graded = hdrMasteringDisplayVolume
        // 0.005 nits, raw field 50
        graded.replaceSubrange(20..<24, with: [0x00, 0x00, 0x00, 0x32])
        XCTAssertEqual(try XCTUnwrap(masteringBlackPQ(graded)), 0.0151, accuracy: 0.0005)
        // A master graded against absolute black states zero, and a stream
        // with no box states nothing: both are read as absolute black, so
        // both answer the same way.
        var absolute = hdrMasteringDisplayVolume
        absolute.replaceSubrange(20..<24, with: [0, 0, 0, 0])
        XCTAssertNil(masteringBlackPQ(absolute))
        XCTAssertNil(masteringBlackPQ(nil))
        XCTAssertNil(masteringBlackPQ(graded.prefix(23)))
    }

    func testAnSDRStreamIsNeverTouched() throws {
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "path-sdr.mp4",
            codec: .h264, width: 320, height: 180, frameCount: 4, fps: 30
        )
        let stream = try Demuxer(url: url).streams[0]
        XCTAssertEqual(videoPath(for: stream, capability: DisplayCapability(headroom: 1)), .passthrough)
        XCTAssertEqual(videoPath(for: stream, capability: DisplayCapability(headroom: 8)), .passthrough)
    }

    func testAnHDRStreamIsMappedOnlyWhereItHasToBe() throws {
        let url = try makeHDRFixture(
            directory: FileManager.default.temporaryDirectory, name: "path-pq.mp4",
            width: 320, height: 180, frameCount: 4, transfer: .pq
        )
        let stream = try Demuxer(url: url).streams[0]
        XCTAssertEqual(videoPath(for: stream, capability: DisplayCapability(headroom: 1)), .toneMapped)
        XCTAssertEqual(videoPath(for: stream, capability: DisplayCapability(headroom: 4)), .passthrough)
    }

    /// A codec VideoToolbox cannot decode on this device decodes in software
    /// and goes up as it is: every other path is built on a session of its
    /// own.
    func testACodecWithNoHardwareDecoderGoesUpAsItIs() throws {
        // VP9, which VideoToolbox decodes nowhere, stands for AV1 on an A15
        func stream(transfer: Int32, primaries: Int32, matrix: Int32) -> MediaStream {
            var stream = MediaStream(
                index: 0, kind: .video, codecID: AV_CODEC_ID_VP9.rawValue, codecName: "vp9",
                width: 1920, height: 1080, timeBaseNum: 1, timeBaseDen: 24000,
                sampleRate: 0, channels: 0, videoDelay: 0, language: "", title: "",
                isDefault: true, isForced: false,
                colorPrimaries: primaries, colorTransfer: transfer, colorMatrix: matrix, isFullRange: false,
                masteringDisplay: nil, contentLight: nil, dolbyVision: nil,
                extradata: Data([0x81])
            )
            stream.frameRateNum = 24
            stream.frameRateDen = 1
            return stream
        }
        // AVCOL_TRC_SMPTE2084 and BT.2020, then BT.709 throughout
        let hdr = stream(transfer: 16, primaries: 9, matrix: 9)
        let sdr = stream(transfer: 1, primaries: 1, matrix: 1)
        let sdrScreen = DisplayCapability(headroom: 1, pixelHeight: 2160)
        let hdrScreen = DisplayCapability(headroom: 4, pixelHeight: 2160)
        XCTAssertEqual(videoPath(for: hdr, capability: sdrScreen), .passthrough)
        XCTAssertEqual(videoPath(for: hdr, capability: hdrScreen, decodesHDRHere: true), .passthrough)
        XCTAssertEqual(videoPath(for: sdr, capability: hdrScreen, upscalingAllowed: true), .passthrough)
    }

    /// Where the platform decodes HDR itself, an HDR stream a screen could
    /// show as it is is decoded here instead, and only there: an SDR screen
    /// still maps it, and an SDR stream is still never touched.
    func testAnHDRStreamIsDecodedHereWhereThePlatformSaysSo() throws {
        let url = try makeHDRFixture(
            directory: FileManager.default.temporaryDirectory, name: "path-pq-decoded.mp4",
            width: 320, height: 180, frameCount: 4, transfer: .pq
        )
        let stream = try Demuxer(url: url).streams[0]
        guard hardwareDecodes(stream) == true else {
            throw XCTSkip("this device does not decode HEVC in hardware")
        }
        XCTAssertEqual(
            videoPath(for: stream, capability: DisplayCapability(headroom: 4), decodesHDRHere: true),
            .decoded)
        XCTAssertEqual(
            videoPath(for: stream, capability: DisplayCapability(headroom: 1), decodesHDRHere: true),
            .toneMapped)
        XCTAssertEqual(
            videoPath(for: stream, capability: DisplayCapability(headroom: 4), decodesHDRHere: false),
            .passthrough)
        XCTAssertEqual(
            videoPath(
                for: sdrStream(width: 3840, height: 2160), capability: DisplayCapability(headroom: 4),
                decodesHDRHere: true),
            .passthrough)
    }

    /// A profile 5 base layer is no picture without its record, so it stays
    /// with the display layer even where the platform decodes HDR itself;
    /// a profile 8 one goes as Dolby Vision, or with HDR10 chosen is decoded
    /// here as the HDR10 it also is.
    func testDolbyVisionGoesAsDolbyVisionAndOtherwiseADisplayableBaseLayerIsDecodedHere() throws {
        let url = try makeHDRFixture(
            directory: FileManager.default.temporaryDirectory, name: "path-pq-dolby.mp4",
            width: 320, height: 180, frameCount: 4, transfer: .pq
        )
        let base = try Demuxer(url: url).streams[0]
        guard hardwareDecodes(base) == true else {
            throw XCTSkip("this device does not decode HEVC in hardware")
        }
        func withProfile(_ profile: Int, compatibility: Int) -> MediaStream {
            MediaStream(
                index: base.index, kind: base.kind, codecID: base.codecID, codecName: base.codecName,
                width: base.width, height: base.height, timeBaseNum: base.timeBaseNum,
                timeBaseDen: base.timeBaseDen, sampleRate: 0, channels: 0, videoDelay: base.videoDelay,
                language: "", title: "", isDefault: true, isForced: false,
                colorPrimaries: base.colorPrimaries, colorTransfer: base.colorTransfer,
                colorMatrix: base.colorMatrix, isFullRange: base.isFullRange,
                masteringDisplay: nil, contentLight: nil,
                dolbyVision: DolbyVisionConfiguration(
                    profile: UInt8(profile), level: 6, hasRPU: true, hasEnhancementLayer: false,
                    hasBaseLayer: true, compatibility: UInt8(compatibility), record: Data(count: 24)),
                extradata: base.extradata
            )
        }
        let screen = DisplayCapability(headroom: 4, supportsDolbyVision: true)
        XCTAssertEqual(
            videoPath(
                for: withProfile(5, compatibility: 0), capability: screen, dolbyVisionPassthrough: true,
                decodesHDRHere: true),
            .passthrough)
        XCTAssertEqual(
            videoPath(
                for: withProfile(8, compatibility: 1), capability: screen, dolbyVisionPassthrough: true,
                decodesHDRHere: true),
            .passthrough)
        XCTAssertEqual(
            videoPath(for: withProfile(8, compatibility: 1), capability: screen, decodesHDRHere: true),
            .decoded)
    }

    /// An interlaced SDR film a display layer would weave into half the
    /// pictures a second it was shot at is built up a field at a time here;
    /// the upscaler keeps its own path, which builds the fields up too.
    func testAnInterlacedSDRFilmIsDeinterlacedHere() {
        let fourK = DisplayCapability(headroom: 1, pixelHeight: 2160)
        var native = sdrStream(width: 3840, height: 2160)
        native.fieldOrder = Int32(AV_FIELD_TT.rawValue)
        XCTAssertEqual(videoPath(for: native, capability: fourK), .deinterlaced)
        var small = sdrStream(width: 1920, height: 1080)
        small.fieldOrder = Int32(AV_FIELD_TT.rawValue)
        XCTAssertEqual(videoPath(for: small, capability: fourK, upscalingAllowed: true), .upscaled)
        XCTAssertEqual(videoPath(for: sdrStream(width: 3840, height: 2160), capability: fourK), .passthrough)
    }

    /// A hand-built SDR H.264 stream of the given size, for path decisions.
    private func sdrStream(width: Int32, height: Int32) -> MediaStream {
        MediaStream(
            index: 0, kind: .video, codecID: AV_CODEC_ID_H264.rawValue, codecName: "h264",
            width: width, height: height, timeBaseNum: 1, timeBaseDen: 24000,
            sampleRate: 0, channels: 0, videoDelay: 0, language: "", title: "",
            isDefault: true, isForced: false,
            colorPrimaries: 1, colorTransfer: 1, colorMatrix: 1, isFullRange: false,
            masteringDisplay: nil, contentLight: nil, dolbyVision: nil,
            extradata: Data([0x01])
        )
    }

    func testASmallSDRPictureOnABigScreenTakesTheUpscaledPath() throws {
        let fourK = DisplayCapability(headroom: 1, pixelHeight: 2160)
        let stream = sdrStream(width: 1920, height: 1080)
        XCTAssertEqual(
            videoPath(for: stream, capability: fourK, upscalingAllowed: true), .upscaled)
        // the switch off, and the default, both leave yesterday's answer
        XCTAssertEqual(
            videoPath(for: stream, capability: fourK, upscalingAllowed: false), .passthrough)
        XCTAssertEqual(videoPath(for: stream, capability: fourK), .passthrough)
        // a screen of unknown size upscales nothing
        XCTAssertEqual(
            videoPath(
                for: stream, capability: DisplayCapability(headroom: 1), upscalingAllowed: true),
            .passthrough)
        // a picture already the screen's own size rides as it is
        XCTAssertEqual(
            videoPath(
                for: sdrStream(width: 3840, height: 2160), capability: fourK,
                upscalingAllowed: true),
            .passthrough)
    }

    /// Twice the film, the one factor the scaler learned, or the screen where
    /// that falls short: 1080 doubles onto a 4K screen exactly, 720 and SD
    /// are fitted to it, their pixels' shape kept, but at 60 pictures a second,
    /// and 1440 doubles past the screen for the compositor to bring it in.
    func testTheUpscaleTargetIsTwiceTheFilmOrTheScreen() {
        let fourK = DisplayCapability(headroom: 1, pixelHeight: 2160)
        XCTAssertEqual(
            upscaleTarget(for: sdrStream(width: 1920, height: 1080), capability: fourK)?.width,
            3840)
        XCTAssertEqual(
            upscaleTarget(for: sdrStream(width: 1920, height: 1080), capability: fourK)?.height,
            2160)
        XCTAssertEqual(upscaleTarget(for: sdrStream(width: 1280, height: 720), capability: fourK)?.width, 3840)
        XCTAssertEqual(upscaleTarget(for: sdrStream(width: 1280, height: 720), capability: fourK)?.height, 2160)
        // a scope film is fitted to the screen's width
        XCTAssertEqual(upscaleTarget(for: sdrStream(width: 1280, height: 534), capability: fourK)?.height, 1602)
        var widescreenDVD = sdrStream(width: 720, height: 480)
        widescreenDVD.pixelAspectNum = 32
        widescreenDVD.pixelAspectDen = 27
        XCTAssertEqual(upscaleTarget(for: widescreenDVD, capability: fourK)?.width, 3240)
        XCTAssertEqual(upscaleTarget(for: widescreenDVD, capability: fourK)?.height, 2160)
        var fast = sdrStream(width: 1280, height: 720)
        fast.frameRateNum = 60
        fast.frameRateDen = 1
        XCTAssertEqual(upscaleTarget(for: fast, capability: fourK)?.height, 1440)
        // 1.5x is worth the pass; anything under it is not
        XCTAssertEqual(
            upscaleTarget(for: sdrStream(width: 2560, height: 1440), capability: fourK)?.height,
            2880)
        XCTAssertNil(
            upscaleTarget(for: sdrStream(width: 2560, height: 1441), capability: fourK))
        XCTAssertNil(
            upscaleTarget(
                for: sdrStream(width: 1920, height: 1080),
                capability: DisplayCapability(headroom: 1)))
    }

    /// The transfers with paths of their own keep them: upscaling is the SDR
    /// branch's business alone.
    func testHDRKeepsItsOwnPathsWhateverTheScreenSize() throws {
        let url = try makeHDRFixture(
            directory: FileManager.default.temporaryDirectory, name: "path-up-pq.mp4",
            width: 320, height: 180, frameCount: 4, transfer: .pq
        )
        let stream = try Demuxer(url: url).streams[0]
        XCTAssertEqual(
            videoPath(
                for: stream, capability: DisplayCapability(headroom: 1, pixelHeight: 2160),
                upscalingAllowed: true),
            .toneMapped)
        XCTAssertEqual(
            videoPath(
                for: stream, capability: DisplayCapability(headroom: 4, pixelHeight: 2160),
                upscalingAllowed: true),
            .passthrough)
    }

    func testDolbyVisionWithADisplayableBaseLayerGoesToTheDisplay() throws {
        let url = try makeHDRFixture(
            directory: FileManager.default.temporaryDirectory, name: "path-dv.mp4",
            width: 320, height: 180, frameCount: 4, transfer: .hlg
        )
        let stream = try Demuxer(url: url).streams[0]
        XCTAssertEqual(stream.dolbyVision?.compatibility, 4)
        XCTAssertEqual(videoPath(for: stream, capability: DisplayCapability(headroom: 4)), .passthrough)
        // An HLG base layer is a picture an HDR screen shows as it stands; an
        // SDR screen cannot, and the kernel has an HLG EOTF of its own, so
        // the record does not buy the stream back the passthrough path there.
        XCTAssertEqual(videoPath(for: stream, capability: DisplayCapability(headroom: 1)), .toneMapped)
    }

    func testAnHLGStreamIsMappedOnlyWhereItHasToBe() throws {
        let url = try makeHDRFixture(
            directory: FileManager.default.temporaryDirectory, name: "path-hlg.mp4",
            width: 320, height: 180, frameCount: 4, transfer: .hlg, metadata: false
        )
        let stream = try Demuxer(url: url).streams[0]
        XCTAssertTrue(isHybridLogGamma(stream.colorTransfer))
        XCTAssertEqual(videoPath(for: stream, capability: DisplayCapability(headroom: 1)), .toneMapped)
        XCTAssertEqual(videoPath(for: stream, capability: DisplayCapability(headroom: 4)), .passthrough)
    }

    /// A profile 5 stream off the Dolby Vision fixture, with its record rewritten
    /// to say profile 5 and no compatible base layer. `profile`,
    /// `compatibility` and `enhancementLayer` rewrite it into the other
    /// profiles the same way: 7 with id 6 and a layer is a UHD Blu-ray remux,
    /// 8 with id 1 and none is a web release.
    private func profileFiveStream(
        named name: String, profile: UInt8 = 5, compatibility: UInt8 = 0,
        enhancementLayer: Bool = false
    ) throws -> MediaStream {
        let url = try makeHDRFixture(
            directory: FileManager.default.temporaryDirectory, name: name,
            width: 320, height: 180, frameCount: 4, transfer: .hlg
        )
        let base = try Demuxer(url: url).streams[0]
        let dolby = try XCTUnwrap(base.dolbyVision)
        var record = dolby.record
        record[record.startIndex + 2] = (profile << 1) | ((dolby.level >> 5) & 0x01)
        record[record.startIndex + 3] = (record[record.startIndex + 3] & ~0x02)
            | (enhancementLayer ? 0x02 : 0)
        record[record.startIndex + 4] = compatibility << 4
        return MediaStream(
            index: base.index, kind: base.kind, codecID: base.codecID, codecName: base.codecName,
            width: base.width, height: base.height, timeBaseNum: base.timeBaseNum,
            timeBaseDen: base.timeBaseDen, sampleRate: base.sampleRate, channels: base.channels,
            videoDelay: base.videoDelay, language: base.language, title: base.title,
            isDefault: base.isDefault, isForced: base.isForced,
            colorPrimaries: base.colorPrimaries, colorTransfer: base.colorTransfer,
            colorMatrix: base.colorMatrix, isFullRange: base.isFullRange,
            masteringDisplay: base.masteringDisplay, contentLight: base.contentLight,
            dolbyVision: DolbyVisionConfiguration(
                profile: profile, level: dolby.level, hasRPU: true,
                hasEnhancementLayer: enhancementLayer, hasBaseLayer: true,
                compatibility: compatibility, record: record
            ),
            extradata: base.extradata
        )
    }

    func testProfileFiveIsMappedWhereNothingCanDecodeIt() throws {
        let stream = try profileFiveStream(named: "path-p5.mp4")
        // A screen with headroom is not a screen that does Dolby Vision, and
        // nothing but a Dolby Vision decoder can show an IPT-PQ-c2 base layer
        // as it stands.
        XCTAssertEqual(
            videoPath(for: stream, capability: DisplayCapability(headroom: 16)), .toneMapped)
        XCTAssertEqual(
            videoPath(for: stream, capability: DisplayCapability(headroom: 1)), .toneMapped)
        // and the screen is never even asked for a description it could not use
        XCTAssertNil(
            dolbyVisionPassthroughFormat(
                for: stream, capability: DisplayCapability(headroom: 16)))
    }

    func testProfileFiveGoesToTheDisplayWhenTheDisplayDoesDolbyVision() throws {
        let stream = try profileFiveStream(named: "path-p5-dv.mp4")
        XCTAssertEqual(
            videoPath(
                for: stream, capability: DisplayCapability(headroom: 16),
                dolbyVisionPassthrough: true),
            .passthrough
        )
        // The same stream on the same screen, where the device would not take
        // it: the mapped path, exactly as before.
        XCTAssertEqual(
            videoPath(
                for: stream, capability: DisplayCapability(headroom: 16),
                dolbyVisionPassthrough: false),
            .toneMapped
        )
    }

    /// Profile 7, as a UHD Blu-ray carries it: an HDR10 base layer and an
    /// enhancement layer this player does not read. A Dolby Vision display
    /// gets it as 8.1, 'dvh1' with a record that promises no enhancement
    /// layer; any other gets the base layer as the HDR10 it is, described as
    /// plain HEVC with no record promising a layer the decoder will not get.
    func testProfileSevenGoesToADolbyVisionDisplayAsEightOneAndElsewhereAsHDR10() throws {
        let stream = try profileFiveStream(
            named: "path-p7.mp4", profile: 7, compatibility: 6, enhancementLayer: true)
        let dolby = try XCTUnwrap(stream.dolbyVision)
        XCTAssertTrue(dolby.baseLayerIsDisplayable)
        XCTAssertFalse(dolby.recordDescribesWhatIsHandedOver)
        if let offered = dolbyVisionPassthroughFormat(
            for: stream, capability: DisplayCapability(headroom: 16, supportsDolbyVision: true))
        {
            XCTAssertEqual(CMFormatDescriptionGetMediaSubType(offered), kCMVideoCodecType_DolbyVisionHEVC)
            let atoms = try XCTUnwrap(CMFormatDescriptionGetExtension(
                offered, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms
            ) as? [String: Any])
            let record = try XCTUnwrap(atoms["dvvC"] as? Data)
            XCTAssertEqual(record[record.startIndex + 2] >> 1, 8)
            XCTAssertEqual(record[record.startIndex + 3] & 0x07, 0b101)
            XCTAssertEqual(record[record.startIndex + 4] >> 4, 1)
        }
        XCTAssertNil(dolbyVisionPassthroughFormat(for: stream, capability: DisplayCapability(headroom: 16)))
        XCTAssertEqual(
            videoPath(for: stream, capability: DisplayCapability(headroom: 16)), .passthrough)
        XCTAssertEqual(
            videoPath(
                for: stream, capability: DisplayCapability(headroom: 1, eligibleForHDR: true)),
            .passthrough)
        // and an SDR screen maps it, exactly as it maps an HDR10 file
        XCTAssertEqual(
            videoPath(for: stream, capability: DisplayCapability(headroom: 1)), .toneMapped)
        let format = try makeFormatDescription(for: stream)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(format), kCMVideoCodecType_HEVC)
        let atoms = try XCTUnwrap(CMFormatDescriptionGetExtension(
            format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms
        ) as? [String: Any])
        XCTAssertEqual(atoms.keys.sorted(), ["hvcC"])
    }

    /// Profile 8.1 is the base layer plus the RPU, which is the whole
    /// picture: a screen that does Dolby Vision is offered it as 'dvh1', the
    /// way profile 5 is, and one that does not gets the HDR10 base layer
    /// with the record beside the hvcC, as before.
    func testProfileEightIsOfferedTheDolbyVisionPathWhereTheDisplayDoesDolbyVision() throws {
        let stream = try profileFiveStream(named: "path-p81.mp4", profile: 8, compatibility: 1)
        let dolby = try XCTUnwrap(stream.dolbyVision)
        XCTAssertTrue(dolby.recordDescribesWhatIsHandedOver)
        XCTAssertNil(
            dolbyVisionPassthroughFormat(for: stream, capability: DisplayCapability(headroom: 16)))
        let offered = dolbyVisionPassthroughFormat(
            for: stream, capability: DisplayCapability(headroom: 16, supportsDolbyVision: true))
        try XCTSkipIf(offered == nil, "this host has no 'dvh1' decoder")
        XCTAssertEqual(
            CMFormatDescriptionGetMediaSubType(try XCTUnwrap(offered)),
            kCMVideoCodecType_DolbyVisionHEVC)
        XCTAssertEqual(
            videoPath(
                for: stream, capability: DisplayCapability(headroom: 16),
                dolbyVisionPassthrough: true),
            .passthrough)
    }

    func testTheDolbyVisionDescriptionIsDvh1AndCarriesBothRecords() throws {
        let stream = try profileFiveStream(named: "path-p5-format.mp4")
        let format = try makeDolbyVisionFormatDescription(for: stream)
        XCTAssertEqual(
            CMFormatDescriptionGetMediaSubType(format), kCMVideoCodecType_DolbyVisionHEVC)
        let atoms = try XCTUnwrap(
            CMFormatDescriptionGetExtension(
                format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms
            ) as? [String: Any]
        )
        // Both: a description carrying only the Dolby Vision record is refused,
        // measured, and one carrying only the hvcC is an HEVC stream again.
        XCTAssertEqual(atoms["hvcC"] as? Data, stream.extradata)
        XCTAssertEqual(atoms["dvcC"] as? Data, stream.dolbyVision?.record)
        // and the description a non-Dolby-Vision open builds is untouched
        let plain = try makeFormatDescription(for: stream)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(plain), kCMVideoCodecType_HEVC)
    }

    /// A screen that does no Dolby Vision is the case every simulator and every
    /// Mac reports, and the one the fallback exists for.
    func testACapabilityIsSDRAndWithoutDolbyVisionUnlessItSaysOtherwise() {
        XCTAssertFalse(DisplayCapability(headroom: 1).supportsDolbyVision)
        XCTAssertFalse(DisplayCapability(headroom: 16).supportsDolbyVision)
        XCTAssertTrue(
            DisplayCapability(headroom: 1, supportsDolbyVision: true).supportsDolbyVision)
    }

    /// Which container each destination gets, and what one 4K picture of it
    /// weighs - off a real buffer, since only CoreVideo knows the row padding
    /// it chose.
    func testWhatAMappedPictureIsStoredAsAndWeighs() {
        XCTAssertEqual(
            DisplayCapability(headroom: 1).toneMapPixelFormat, kCVPixelFormatType_32BGRA)
        XCTAssertEqual(
            DisplayCapability(headroom: 1.05).toneMapPixelFormat, kCVPixelFormatType_32BGRA)
        XCTAssertEqual(
            DisplayCapability(headroom: 2).toneMapPixelFormat, kCVPixelFormatType_64RGBAHalf)
        XCTAssertEqual(
            DisplayCapability(headroom: 16).toneMapPixelFormat, kCVPixelFormatType_64RGBAHalf)
        let withHeadroom = decodedPictureBytes(
            width: 3840, height: 2160,
            pixelFormat: DisplayCapability(headroom: 16).toneMapPixelFormat
        )
        let without = decodedPictureBytes(
            width: 3840, height: 2160,
            pixelFormat: DisplayCapability(headroom: 1).toneMapPixelFormat
        )
        XCTAssertEqual(withHeadroom, 66_355_200)
        XCTAssertEqual(without, 33_177_600)
    }

    func testTheScreenAnswersSomething() {
        // whatever this machine has, it is a number and it is at least SDR
        XCTAssertGreaterThanOrEqual(DisplayCapability.current().headroom, 1)
    }

    /// The branch the app always takes: both callers open off the main thread,
    /// so the answer comes back through the main queue. The wait is on main,
    /// which is what pumps that hop; a deadlock here is a timeout, not a hang.
    func testTheScreenAnswersFromAnotherThread() {
        let answered = expectation(description: "off the main thread")
        DispatchQueue.global().async {
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertGreaterThanOrEqual(DisplayCapability.current().headroom, 1)
            answered.fulfill()
        }
        wait(for: [answered], timeout: 5)
    }
}

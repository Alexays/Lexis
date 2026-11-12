import CoreMedia
import LexisTestSupport
import XCTest
@testable import LexisPlayer

final class DisplayCriteriaTests: XCTestCase {
    func testAConstantFrameRateFileReadsItsOwnRate() throws {
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "criteria-30.mp4",
            codec: .h264, width: 320, height: 180, frameCount: 6, fps: 30
        )
        let stream = try Demuxer(url: url).streams[0]
        XCTAssertEqual(try XCTUnwrap(stream.frameRate), 30, accuracy: 0.01)
    }

    func testADifferentRateIsNotThirtyInDisguise() throws {
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "criteria-24.mp4",
            codec: .h264, width: 320, height: 180, frameCount: 6, fps: 24
        )
        let stream = try Demuxer(url: url).streams[0]
        XCTAssertEqual(try XCTUnwrap(stream.frameRate), 24, accuracy: 0.01)
    }

    /// A stream built with no frame rate fields at all: the memberwise
    /// initializer's defaults, exactly what a hand-built MediaStream in an
    /// older test still produces.
    func testAStreamWithNoRateAsksForNothing() throws {
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "criteria-bare.mp4",
            codec: .h264, width: 320, height: 180, frameCount: 4, fps: 30
        )
        var stream = try Demuxer(url: url).streams[0]
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
            dolbyVision: stream.dolbyVision, extradata: stream.extradata
        )
        XCTAssertNil(stream.frameRate)
        let format = try makeFormatDescription(for: stream)
        XCTAssertNil(playerDisplayCriteria(for: stream, formatDescription: format))
    }

    /// A rate no display mode runs at is asked for as the nearest one a
    /// mode does run at, a slow one doubled first; a rate a mode runs at,
    /// or one past sixty, is asked for as it is.
    func testARateNoModeRunsAtAsksForTheNearestOne() throws {
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "criteria-odd.mp4",
            codec: .h264, width: 320, height: 180, frameCount: 6, fps: 30
        )
        var stream = try Demuxer(url: url).streams[0]
        let format = try makeFormatDescription(for: stream)
        for (num, den, asked) in [
            (285, 10, 30000.0 / 1001), (273, 10, 25), (15, 1, 30), (25, 2, 25), (24000, 1001, 24000.0 / 1001),
            (50, 1, 50), (120, 1, 120),
        ] as [(Int32, Int32, Double)] {
            stream.frameRateNum = num
            stream.frameRateDen = den
            let request = try XCTUnwrap(playerDisplayCriteria(for: stream, formatDescription: format))
            XCTAssertEqual(Double(request.refreshRate), asked, accuracy: 0.001, "\(num)/\(den)")
        }
    }

    func testTheRequestCarriesTheStreamsOwnFormatDescription() throws {
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "criteria-req.mp4",
            codec: .h264, width: 320, height: 180, frameCount: 6, fps: 30
        )
        let stream = try Demuxer(url: url).streams[0]
        let format = try makeFormatDescription(for: stream)
        let request = try XCTUnwrap(playerDisplayCriteria(for: stream, formatDescription: format))
        XCTAssertEqual(request.refreshRate, 30, accuracy: 0.01)
        XCTAssertEqual(
            CMVideoFormatDescriptionGetDimensions(request.formatDescription).width, 320
        )
    }

    /// `AVDisplayCriteria` reads the dynamic range it asks the screen for out
    /// of the description it is given, so a Dolby Vision open asks for a Dolby
    /// Vision mode only because the description says 'dvh1'.
    func testADolbyVisionOpenAsksTheScreenForDolbyVision() throws {
        let url = try makeHDRFixture(
            directory: FileManager.default.temporaryDirectory, name: "criteria-dv.mp4",
            width: 320, height: 180, frameCount: 6, transfer: .hlg
        )
        let stream = try Demuxer(url: url).streams[0]
        let format = try makeDolbyVisionFormatDescription(for: stream)
        let request = try XCTUnwrap(playerDisplayCriteria(for: stream, formatDescription: format))
        XCTAssertEqual(
            CMFormatDescriptionGetMediaSubType(request.formatDescription),
            kCMVideoCodecType_DolbyVisionHEVC
        )
    }
}

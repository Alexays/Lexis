import CoreVideo
import XCTest
@testable import LexisPlayer

/// The curve adapts to what each frame is measured to hold, on the GPU, in
/// the same pass that maps it: a cut is mapped for the shot it opens from
/// its very first picture, and only a drift within a shot is smoothed.
final class ToneMapAdaptationTests: XCTestCase {
    /// A 300 nit display.
    let display = pqInverseEOTF(0.03)

    /// The PQ code a neutral luma code decodes to through the BT.2020
    /// matrix, as the histogram files it: the top of its bin.
    func filedPeak(code: Int) -> Float {
        let value = 1.1678 * Float(code - 64) / 1023
        return (floor(value * 1024) + 1) / 1024
    }

    /// The peak follows the picture either way, nothing having stated one.
    let follows = ToneMapper.Adaptation(reading: 2)

    func parameters(peak: Float) -> ToneMapParameters {
        ToneMapParameters(sourceMinPQ: 0, sourceMaxPQ: peak, targetMinPQ: 0, targetMaxPQ: display)
    }

    /// A picture with a small bright patch in its top left corner: the patch
    /// sets the peak and barely moves the mean.
    func patched(_ patchCode: Int, base: Int = 200) throws -> CVPixelBuffer {
        try makePicture(
            width: 256, height: 160,
            luma: { x, y in x < 16 && y < 16 ? patchCode : base },
            chroma: { _, _ in (512, 512) })
    }

    /// How far toward a reading the smoothing moves in one frame: a twenty
    /// frame time constant.
    let rate = 1 - expf(-1.0 / 20)

    /// Inside the patch.
    func patchRed(_ buffer: CVPixelBuffer) -> Float { red(buffer, x: 4, y: 4) }

    /// Outside it.
    func baseRed(_ buffer: CVPixelBuffer) -> Float { red(buffer, x: 100, y: 100) }

    /// The picture after a cut is mapped for itself, as if nothing had come
    /// before it: the bright shot that follows a dark one is mapped under its
    /// own peak from its first frame.
    func testACutIsMappedForTheShotItOpens() throws {
        let mapper = try ToneMapper()
        let dark = try makeSource(codes: [250, 250], rows: 4)
        let bright = try makeSource(codes: [900, 900], rows: 4)
        _ = try mapper.mapped(dark, parameters: parameters(peak: 1), adaptation: follows)
        let brightAfterDark = try mapper.mapped(bright, parameters: parameters(peak: 1), adaptation: follows)
        let brightAlone = try ToneMapper().mapped(bright, parameters: parameters(peak: 1), adaptation: follows)
        XCTAssertEqual(red(brightAfterDark, x: 0), red(brightAlone, x: 0))
        let brightPlain = try mapper.mapped(bright, parameters: parameters(peak: filedPeak(code: 900)))
        XCTAssertEqual(red(brightAfterDark, x: 0), red(brightPlain, x: 0))
    }

    /// A stated peak is narrowed to what the frame holds and never widened;
    /// an assumed one follows the frame either way.
    func testAStatedPeakIsNarrowedAndAnAssumedOneFollowed() throws {
        let mapper = try ToneMapper()
        let frame = try makeSource(codes: [700, 700], rows: 4)
        let held = filedPeak(code: 700)
        let narrows = ToneMapper.Adaptation(reading: 1)
        let stated4000 = parameters(peak: pqInverseEOTF(0.4))
        let stated40 = parameters(peak: 0.5)
        let atHeld = red(try mapper.mapped(frame, parameters: parameters(peak: held)), x: 0)
        let at4000 = red(try mapper.mapped(frame, parameters: stated4000), x: 0)
        let at40 = red(try mapper.mapped(frame, parameters: stated40), x: 0)
        XCTAssertNotEqual(atHeld, at4000, accuracy: 0.01)
        XCTAssertNotEqual(atHeld, at40, accuracy: 0.01)
        XCTAssertEqual(red(try mapper.mapped(frame, parameters: stated4000, adaptation: narrows), x: 0), atHeld)
        XCTAssertEqual(red(try mapper.mapped(frame, parameters: stated40, adaptation: narrows), x: 0), at40)
        XCTAssertEqual(red(try mapper.mapped(frame, parameters: stated4000, adaptation: follows), x: 0), atHeld)
        XCTAssertEqual(red(try mapper.mapped(frame, parameters: stated40, adaptation: follows), x: 0), atHeld)
    }

    /// A lone hot pixel does not set the peak, and is held under the peak
    /// of the rest; a row of them does.
    func testALoneSpecularPixelDoesNotSetThePeak() throws {
        func picture(hot: Int) throws -> CVPixelBuffer {
            try makePicture(
                width: 256, height: 160,
                luma: { x, y in y == 0 && x < hot ? 900 : 250 },
                chroma: { _, _ in (512, 512) })
        }
        let lone = try picture(hot: 1)
        let shown = red(try ToneMapper().mapped(lone, parameters: parameters(peak: 1), adaptation: follows), x: 0)
        let underTheRest = red(try ToneMapper().mapped(lone, parameters: parameters(peak: filedPeak(code: 250))), x: 0)
        XCTAssertEqual(shown, underTheRest, accuracy: underTheRest * 0.002)
        let row = try picture(hot: 256)
        let rowShown = red(try ToneMapper().mapped(row, parameters: parameters(peak: 1), adaptation: follows), x: 0)
        let underTheRow = red(try ToneMapper().mapped(row, parameters: parameters(peak: filedPeak(code: 900))), x: 0)
        XCTAssertEqual(rowShown, underTheRow, accuracy: underTheRow * 0.002)
        XCTAssertGreaterThan(rowShown, shown * 2)
    }

    /// A flash within a shot does not raise the peak at once: the mean
    /// hardly moves, so it is no cut, and the peak climbs at the
    /// smoothing's rate like any drift.
    func testAFlashDoesNotRaiseThePeakAtOnce() throws {
        let mapper = try ToneMapper()
        let first = filedPeak(code: 594)
        let flash = filedPeak(code: 606)
        XCTAssertLessThan(flash, display)
        _ = try mapper.mapped(try patched(594), parameters: parameters(peak: 1), adaptation: follows)
        let shown = patchRed(try mapper.mapped(try patched(606), parameters: parameters(peak: 1), adaptation: follows))
        let followed = first + (flash - first) * rate
        let expected = patchRed(try mapper.mapped(try patched(606), parameters: parameters(peak: followed)))
        let atOnce = patchRed(try mapper.mapped(try patched(606), parameters: parameters(peak: flash)))
        XCTAssertEqual(shown, expected, accuracy: expected * 0.005)
        XCTAssertNotEqual(shown, atOnce, accuracy: atOnce * 0.02)
    }

    /// A picture mostly black is no cut however far its few lit pixels
    /// move: the jump of the mean is weighed by the part of the frame it
    /// lights, so a fade or a logo on black drifts rather than jumps.
    func testAMostlyBlackFrameIsNoCut() throws {
        let mapper = try ToneMapper()
        func logo(_ code: Int) throws -> CVPixelBuffer {
            try makePicture(
                width: 256, height: 160,
                luma: { x, y in x < 16 && y < 16 ? code : 64 },
                chroma: { _, _ in (512, 512) })
        }
        let first = filedPeak(code: 900)
        let second = filedPeak(code: 700)
        _ = try mapper.mapped(try logo(900), parameters: parameters(peak: 1), adaptation: follows)
        let shown = patchRed(try mapper.mapped(try logo(700), parameters: parameters(peak: 1), adaptation: follows))
        let expected = patchRed(try mapper.mapped(try logo(700), parameters: parameters(peak: first + (second - first) * rate)))
        let atOnce = patchRed(try mapper.mapped(try logo(700), parameters: parameters(peak: second)))
        XCTAssertEqual(shown, expected, accuracy: expected * 0.005)
        XCTAssertNotEqual(shown, atOnce, accuracy: atOnce * 0.02)
    }

    /// A cut the mean does not show is taken at once all the same: a flat
    /// grey followed by a shot of shadows and highlights averaging that grey
    /// is mapped for the new shot from its first frame, its highlights
    /// compressed under its own peak rather than clipped under the grey's.
    func testACutAtTheSameMeanIsMappedForTheShotItOpens() throws {
        let grey = try makePicture(
            width: 256, height: 160, luma: { _, _ in 400 }, chroma: { _, _ in (512, 512) })
        // shadows at 150, highlights at 600 and 700: the grey's mean
        let split = try makePicture(
            width: 256, height: 160, luma: { x, _ in x < 128 ? 150 : x < 192 ? 600 : 700 },
            chroma: { _, _ in (512, 512) })
        let mapper = try ToneMapper()
        _ = try mapper.mapped(grey, parameters: parameters(peak: 1), adaptation: follows)
        let afterGrey = try mapper.mapped(split, parameters: parameters(peak: 1), adaptation: follows)
        let alone = try ToneMapper().mapped(split, parameters: parameters(peak: 1), adaptation: follows)
        XCTAssertEqual(red(afterGrey, x: 160, y: 80), red(alone, x: 160, y: 80))
    }

    /// A peak falling within a shot is followed at the smoothing's rate:
    /// the curve on the second frame is built from a peak a twentieth of the
    /// way toward the reading, not from the reading itself.
    func testADriftWithinAShotIsFollowedSlowly() throws {
        let mapper = try ToneMapper()
        let first = filedPeak(code: 820)
        let second = filedPeak(code: 790)
        XCTAssertGreaterThan(second, display)
        _ = try mapper.mapped(try patched(820, base: 560), parameters: parameters(peak: 1), adaptation: follows)
        let drifted = baseRed(try mapper.mapped(try patched(790, base: 560), parameters: parameters(peak: 1), adaptation: follows))
        let followed = first + (second - first) * rate
        let expected = baseRed(try mapper.mapped(try patched(790, base: 560), parameters: parameters(peak: followed)))
        let unsmoothed = baseRed(try mapper.mapped(try patched(790, base: 560), parameters: parameters(peak: second)))
        XCTAssertEqual(drifted, expected, accuracy: expected * 0.005)
        XCTAssertNotEqual(drifted, unsmoothed, accuracy: unsmoothed * 0.02)
    }

    /// The smoothing runs in seconds: a frame of a 60 frame film moves the
    /// peak two fifths as far as a frame of a 24 frame one.
    func testTheSmoothingRunsInSeconds() throws {
        let mapper = try ToneMapper()
        let first = filedPeak(code: 820)
        let second = filedPeak(code: 790)
        let fast = ToneMapper.Adaptation(reading: 2, seconds: 1.0 / 60)
        _ = try mapper.mapped(try patched(820, base: 560), parameters: parameters(peak: 1), adaptation: fast)
        let drifted = baseRed(try mapper.mapped(try patched(790, base: 560), parameters: parameters(peak: 1), adaptation: fast))
        let followed = first + (second - first) * (1 - expf(-(1.0 / 60) / (20.0 / 24)))
        let expected = baseRed(try mapper.mapped(try patched(790, base: 560), parameters: parameters(peak: followed)))
        XCTAssertEqual(drifted, expected, accuracy: expected * 0.001)
    }
}

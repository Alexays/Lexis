import QuartzCore
import XCTest
@testable import LexisPlayer

final class SubtitleOverlayTests: XCTestCase {
    private func cue(lines: [String], images: [SubtitleImage] = []) -> SubtitleCue {
        SubtitleCue(
            start: 0, end: 1, lines: lines, images: images,
            canvasWidth: images.isEmpty ? 0 : 1920,
            canvasHeight: images.isEmpty ? 0 : 1080
        )
    }

    func testFitsACanvasWhereTheVideoIs() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        // 16:9 in a square is pillar-boxed top and bottom
        let wide = SubtitleOverlay.fit(canvas: CGSize(width: 1920, height: 1080), in: bounds)
        // the scale is a division, so these land a float epsilon off the round
        // numbers they describe
        XCTAssertEqual(wide.width, 1000, accuracy: 0.001)
        XCTAssertEqual(wide.height, 562.5, accuracy: 0.001)
        XCTAssertEqual(wide.minY, 218.75, accuracy: 0.001)
        // 4:3 in a 16:9 window is bordered left and right
        let narrow = SubtitleOverlay.fit(
            canvas: CGSize(width: 640, height: 480),
            in: CGRect(x: 0, y: 0, width: 1920, height: 1080)
        )
        XCTAssertEqual(narrow.width, 1440, accuracy: 0.001)
        XCTAssertEqual(narrow.height, 1080, accuracy: 0.001)
        XCTAssertEqual(narrow.minX, 240, accuracy: 0.001)
        // a canvas of nothing is not a reason to divide by zero
        XCTAssertEqual(SubtitleOverlay.fit(canvas: .zero, in: bounds), bounds)
    }

    func testStacksLinesAboveTheBottomAndTakesThemAway() throws {
        let overlay = SubtitleOverlay()
        let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        overlay.show(cue(lines: ["one", "two"]), in: bounds)

        let visible = (overlay.layer.sublayers ?? []).filter { !$0.isHidden }
        XCTAssertEqual(visible.count, 2)
        let first = try XCTUnwrap(visible.first as? CATextLayer)
        let second = try XCTUnwrap(visible.last as? CATextLayer)
        XCTAssertEqual(first.string as? String, "one")
        XCTAssertEqual(second.string as? String, "two")
        // the second line is below the first, and the pair sits above the
        // bottom of the picture
        XCTAssertGreaterThan(second.frame.minY, first.frame.minY)
        XCTAssertLessThan(second.frame.maxY, bounds.height)
        XCTAssertGreaterThan(second.frame.maxY, bounds.height * 0.85)

        overlay.show(nil, in: bounds)
        XCTAssertTrue((overlay.layer.sublayers ?? []).allSatisfy(\.isHidden))
        // and the layers are kept for the next line rather than rebuilt
        XCTAssertEqual(overlay.layer.sublayers?.count, 2)
    }

    func testLiftsACueClearOfWhatTheHostDrawsOverThePicture() throws {
        let overlay = SubtitleOverlay()
        let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        overlay.show(cue(lines: ["one"]), in: bounds)
        let line = try XCTUnwrap((overlay.layer.sublayers ?? []).first { !$0.isHidden })
        let rested = line.frame.maxY

        // the band the host's own transport overlay is taking
        overlay.lift = 256
        XCTAssertEqual(line.frame.maxY, bounds.height - 256, accuracy: 0.5)
        // and the cue goes back where the film asks for it
        overlay.lift = 0
        XCTAssertEqual(line.frame.maxY, rested, accuracy: 0.5)
    }

    func testLeavesAnythingAlreadyAboveTheBandWhereItIs() throws {
        let overlay = SubtitleOverlay()
        let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        // a sign at the very top of the picture, the way an author places one
        let sign = SubtitleImage(
            x: 0, y: 0, width: 200, height: 80,
            pixels: Data(repeating: 0xFF, count: 200 * 80 * 4)
        )
        overlay.lift = 256
        overlay.show(cue(lines: [], images: [sign]), in: bounds)
        let drawn = try XCTUnwrap((overlay.layer.sublayers ?? []).first { !$0.isHidden })
        XCTAssertEqual(drawn.frame.minY, 0, accuracy: 0.5)
    }

    func testScalesABitmapIntoThePicture() throws {
        let overlay = SubtitleOverlay()
        let image = SubtitleImage(
            x: 100, y: 900, width: 96, height: 32,
            pixels: Data(repeating: 0xFF, count: 96 * 32 * 4)
        )
        // half of a 1920x1080 canvas, letterboxed in a taller window
        let bounds = CGRect(x: 0, y: 0, width: 960, height: 720)
        overlay.show(cue(lines: [], images: [image]), in: bounds)
        let drawn = try XCTUnwrap((overlay.layer.sublayers ?? []).first { !$0.isHidden })
        XCTAssertEqual(drawn.frame.width, 48, accuracy: 0.01)
        XCTAssertEqual(drawn.frame.height, 16, accuracy: 0.01)
        XCTAssertEqual(drawn.frame.minX, 50, accuracy: 0.01)
        // the picture starts 90 points down, and the rect 450 into it
        XCTAssertEqual(drawn.frame.minY, 540, accuracy: 0.01)
        XCTAssertNotNil(drawn.contents)
    }

    /// `show` is called once a video frame, whether or not the cue changed;
    /// video frames themselves must never cost this overlay a re-upload.
    func testTheOverlayContentsChangeOnlyWhenTheCueDoes() throws {
        let overlay = SubtitleOverlay()
        let image = SubtitleImage(
            x: 100, y: 900, width: 96, height: 32,
            pixels: Data(repeating: 0xFF, count: 96 * 32 * 4)
        )
        let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let oneCue = cue(lines: [], images: [image])
        overlay.show(oneCue, in: bounds)
        let drawn = try XCTUnwrap((overlay.layer.sublayers ?? []).first { !$0.isHidden })
        let firstContents = try XCTUnwrap(drawn.contents)

        for _ in 0..<30 {
            overlay.show(oneCue, in: bounds)
            XCTAssertTrue((drawn.contents as AnyObject) === (firstContents as AnyObject))
        }
    }

    func testDrawsAStyledBitmapWhereTheVideoIs() throws {
        let overlay = SubtitleOverlay()
        let image = SubtitleImage(
            x: 100, y: 900, width: 96, height: 32,
            pixels: Data(repeating: 0xFF, count: 96 * 32 * 4)
        )
        // half of a 1920x1080 canvas, letterboxed in a taller window: the same
        // geometry a PGS rect gets, because it is the same function
        let bounds = CGRect(x: 0, y: 0, width: 960, height: 720)
        overlay.showStyled(image, canvas: CGSize(width: 1920, height: 1080),
                           frameCanvas: CGSize(width: 1920, height: 1080), in: bounds)
        let drawn = try XCTUnwrap((overlay.layer.sublayers ?? []).first { !$0.isHidden })
        XCTAssertEqual(drawn.frame.width, 48, accuracy: 0.01)
        XCTAssertEqual(drawn.frame.height, 16, accuracy: 0.01)
        XCTAssertEqual(drawn.frame.minX, 50, accuracy: 0.01)
        XCTAssertEqual(drawn.frame.minY, 540, accuracy: 0.01)
        XCTAssertNotNil(drawn.contents)

        overlay.showStyled(nil, canvas: CGSize(width: 1920, height: 1080),
                           frameCanvas: CGSize(width: 1920, height: 1080), in: bounds)
        XCTAssertTrue((overlay.layer.sublayers ?? []).allSatisfy(\.isHidden))
        // the layer is kept rather than rebuilt: this runs 30 times a second
        XCTAssertEqual(overlay.layer.sublayers?.count, 1)
    }

    func testAResizeMovesTheStyledBitmapWithoutANewOne() throws {
        let overlay = SubtitleOverlay()
        let canvas = CGSize(width: 1920, height: 1080)
        let image = SubtitleImage(
            x: 100, y: 900, width: 96, height: 32,
            pixels: Data(repeating: 0xFF, count: 96 * 32 * 4)
        )
        overlay.showStyled(image, canvas: canvas, frameCanvas: canvas, in: CGRect(x: 0, y: 0, width: 960, height: 720))
        let drawn = try XCTUnwrap((overlay.layer.sublayers ?? []).first { !$0.isHidden })

        // the same bitmap in a window twice the size is laid out again
        overlay.showStyled(image, canvas: canvas, frameCanvas: canvas, in: CGRect(x: 0, y: 0, width: 1920, height: 1440))
        XCTAssertEqual(drawn.frame.width, 96, accuracy: 0.01)
        XCTAssertEqual(drawn.frame.minX, 100, accuracy: 0.01)
        XCTAssertEqual(drawn.frame.minY, 1080, accuracy: 0.01)
        let bitmap = try XCTUnwrap(drawn.contents as AnyObject?)

        // and a resize the styled caller sleeps through, because libass has
        // nothing new to say, still reaches the layer: the cue tick carries it
        overlay.show(nil, in: CGRect(x: 0, y: 0, width: 960, height: 720))
        XCTAssertFalse(drawn.isHidden)
        // laid out again from what it already holds: that path never builds a
        // CGImage, and the name of this test is that it does not
        XCTAssertTrue(drawn.contents as AnyObject? === bitmap)
        XCTAssertEqual(drawn.frame.width, 48, accuracy: 0.01)
        XCTAssertEqual(drawn.frame.minX, 50, accuracy: 0.01)
        XCTAssertEqual(drawn.frame.minY, 540, accuracy: 0.01)
    }

    func testTheStyledSlotAndTheQueuedCueDoNotClearEachOther() throws {
        let overlay = SubtitleOverlay()
        let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let canvas = CGSize(width: 1920, height: 1080)
        overlay.showStyled(
            SubtitleImage(
                x: 0, y: 0, width: 8, height: 8, pixels: Data(repeating: 0xFF, count: 8 * 8 * 4)
            ),
            canvas: canvas, frameCanvas: canvas, in: bounds
        )
        // the queued path drawing its own thing must not take the styled one
        // off: two observers on two queues both call in here
        overlay.show(cue(lines: ["une ligne"]), in: bounds)
        let visible = (overlay.layer.sublayers ?? []).filter { !$0.isHidden }
        XCTAssertEqual(visible.count, 2)
        XCTAssertEqual(visible.compactMap { ($0 as? CATextLayer)?.string as? String }, ["une ligne"])

        overlay.show(nil, in: bounds)
        XCTAssertEqual((overlay.layer.sublayers ?? []).filter { !$0.isHidden }.count, 1)
    }
}

import XCTest
@testable import Lexis

@MainActor
final class PlayerModelTests: XCTestCase {
    private func model() -> PlayerModel {
        PlayerModel(playing: Playing(fileId: 1, title: "Heat", startAt: 0))
    }

    func testMenuClosesOneLevelAtATime() {
        let model = model()
        model.openMenu(.subtitleLanguage)
        XCTAssertTrue(model.menu())
        XCTAssertEqual(model.overlay, .menu(.subtitles))
        XCTAssertTrue(model.menu())
        XCTAssertEqual(model.overlay, .full)
        model.openTab(.stats)
        XCTAssertTrue(model.menu())
        XCTAssertEqual(model.overlay, .full)
        XCTAssertTrue(model.menu())
        XCTAssertEqual(model.overlay, .hidden)
        XCTAssertFalse(model.menu())
    }

    func testAFileWithoutTracksOrChaptersDrawsNoButtonAndNoChapterPill() {
        let model = model()
        XCTAssertEqual(model.glyphRow, [])
        XCTAssertEqual(model.tabs, [.info, .picture, .stats])
    }

    func testSubtitlesStandAboveWhateverTheOverlayDraws() {
        let model = model()
        let screen = Theme.Layout.screenHeight
        XCTAssertGreaterThan(model.subtitleLift, screen - Theme.Player.contextTop)
        model.openTab(.stats)
        XCTAssertGreaterThan(model.subtitleLift, screen - Theme.Player.contextTop + Theme.Player.tabShift)
        model.openMenu(.audio)
        XCTAssertGreaterThan(model.subtitleLift, screen - Theme.Player.contextTop)
        XCTAssertTrue(model.menu())
        XCTAssertTrue(model.menu())
        XCTAssertEqual(model.subtitleLift, 0)
    }

    func testLandingOnAControlClosesTheOpenTab() {
        let model = model()
        model.openTab(.picture)
        model.focusChanged(.control(.bar))
        XCTAssertEqual(model.overlay, .full)
    }
}

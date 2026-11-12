import XCTest
@testable import Lexis

final class PlayerLayoutTests: XCTestCase {
    /// The native player's stack, top to bottom: the title row ends before
    /// the bar, the time line before the pills, the pills inside the screen.
    func testTheOverlayStacksLikeTheNativePlayer() {
        let p = Theme.Player.self
        XCTAssertLessThanOrEqual(p.titleTop + p.titleHeight, p.barTop)
        XCTAssertLessThanOrEqual(p.timeTop + p.timeHeight, p.pillTop)
        XCTAssertLessThanOrEqual(p.pillTop + p.pillHeight, Theme.Layout.screenHeight)
        XCTAssertEqual(p.rowInset + p.rowWidth, Theme.Layout.screenWidth - p.rowInset)
    }

    /// A tab lifts the stack by one fixed shift, and its band fits under the
    /// lifted pills and inside the screen.
    func testAnOpenTabFitsUnderThePills() {
        let p = Theme.Player.self
        XCTAssertLessThanOrEqual(p.pillTop - p.tabShift + p.pillHeight, p.tabContentTop)
        XCTAssertLessThanOrEqual(p.tabContentTop + p.tabContentHeight, Theme.Layout.screenHeight)
        XCTAssertLessThanOrEqual(p.tabContentTop + p.chapterCard.height, Theme.Layout.screenHeight)
    }

    /// The scrub's frame rests on the tip of the needle.
    func testTheScrubFrameSitsOnTheNeedle() {
        let p = Theme.Player.self
        XCTAssertEqual(p.barTop - p.thumbnailGap, p.barTop + p.barHeight + p.needleOverhang - p.scrubNeedleHeight)
    }

    /// A popover stands on its button: right edges together, its foot above
    /// the round buttons, and never past the top of the screen however many
    /// tracks a file has.
    func testAPopoverStandsOnItsButton() {
        XCTAssertEqual(TrackMenu.buttonRight(.subtitle, row: [.subtitle, .audio]), 1750)
        XCTAssertEqual(TrackMenu.buttonRight(.audio, row: [.subtitle, .audio]), 1840)
        XCTAssertEqual(TrackMenu.buttonRight(.subtitle, row: [.subtitle]), 1840)
        let short = TrackMenu.frame(right: 1750, height: 300)
        XCTAssertEqual(short.maxX, 1750)
        XCTAssertEqual(short.maxY, Theme.Player.roundButtonTop - Theme.Player.menuGap)
        XCTAssertEqual(short.height, 300)
        XCTAssertGreaterThanOrEqual(TrackMenu.frame(right: 1750, height: 5000).minY, 0)
    }

    /// A popover is as tall as its header, its rows and its insets.
    func testAPopoverIsAsTallAsItsRows() {
        let rows = [TrackMenu.Row(label: "a") {}, TrackMenu.Row(label: "b", detail: "c") {}]
        let p = Theme.Player.self
        XCTAssertEqual(
            TrackMenu.height([TrackMenu.Section(header: "h", rows: rows)]),
            p.menuHeader + p.menuRow + p.menuRowTall + 2 * p.menuInset)
    }
}

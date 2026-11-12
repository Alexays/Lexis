import XCTest

/// Photographs every screen the remote can reach.
///
/// The unit tests sum the heights a screen declares; this one is the only
/// thing that can say whether the screen draws them. A layout that overflows
/// compiles, passes every other test, and is wrong the moment it is looked
/// at, which is how a home screen once shipped two hundred points taller
/// than the television it ran on.
final class Shots: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launch()
    }

    func testEveryTab() {
        shoot("1-home")

        // the bar sits above whatever the tab is showing, so Menu lifts the
        // remote out of the content before a sideways press changes tabs
        XCUIRemote.shared.press(.menu)
        sleep(1)
        XCUIRemote.shared.press(.right)
        sleep(1)
        XCUIRemote.shared.press(.select)
        sleep(3)
        shoot("2-films")

        XCUIRemote.shared.press(.menu)
        sleep(1)
        XCUIRemote.shared.press(.right)
        sleep(1)
        XCUIRemote.shared.press(.select)
        sleep(3)
        shoot("3-series")

        XCUIRemote.shared.press(.menu)
        sleep(1)
        XCUIRemote.shared.press(.right)
        sleep(1)
        XCUIRemote.shared.press(.select)
        sleep(3)
        shoot("4-watchlist")

        XCUIRemote.shared.press(.menu)
        sleep(1)
        XCUIRemote.shared.press(.right)
        sleep(1)
        XCUIRemote.shared.press(.select)
        sleep(3)
        shoot("5-settings")
    }

    /// Search is the round mark left of the home's pill.
    func testSearch() {
        XCUIRemote.shared.press(.menu)
        sleep(1)
        XCUIRemote.shared.press(.left)
        sleep(1)
        XCUIRemote.shared.press(.select)
        sleep(3)
        shoot("8-search")
    }

    /// The page of the first title on the home.
    func testATitle() {
        XCUIRemote.shared.press(.down)
        sleep(2)
        XCUIRemote.shared.press(.select)
        sleep(4)
        shoot("9-detail")
    }

    /// A focused card, which is the only state where the evening's gestures
    /// are drawn at all.
    func testAFocusedCard() {
        XCUIRemote.shared.press(.down)
        sleep(2)
        shoot("6-focused")
        XCUIRemote.shared.press(.right)
        sleep(2)
        shoot("7-focused-next")
    }

    private func shoot(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

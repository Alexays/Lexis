import XCTest

/// The player against the native one. Every position here is what tvOS 27's
/// AVPlayerViewController draws on the same 1920 x 1080 screen, read from its
/// accessibility tree; a Lexis element more than two points off is a layout
/// that no longer looks native.
final class PlayerShots: XCTestCase {
    private var app: XCUIApplication!
    private let remote = XCUIRemote.shared

    override func setUpWithError() throws {
        continueAfterFailure = true
        let movie = try XCTUnwrap(
            ProcessInfo.processInfo.environment["LEXIS_SHOTS_MOVIE"],
            "tv/scripts/make-shots-movie.sh writes the film; pass its path as TEST_RUNNER_LEXIS_SHOTS_MOVIE")
        app = XCUIApplication()
        app.launchArguments = ["-lexis-play-local", movie]
        app.launch()
        // long enough for the film to open and the overlay to go away
        sleep(9)
    }

    func testTheBarMatchesTheNativePlayer() {
        remote.press(.select)
        sleep(2)
        shoot("player-bar")
        expect("player.context", x: 84, y: 758)
        expect("player.title", x: 84, y: 802)
        expect("player.subtitles", x: 1684, y: 800, width: 66, height: 66)
        expect("player.audio", x: 1774, y: 800, width: 66, height: 66)
        // an accessibility frame is the union of what is drawn, needle
        // included: the bar is placed by its centre line, as the native one's
        expect("player.bar", x: 80, width: 1760, midY: 910)
        expect("player.remaining", y: 925)
        expect("player.tab.info", x: 76, y: 968, height: 68)
    }

    func testAScrubInPauseShowsTheFrameOnTheNeedle() {
        remote.press(.select)
        sleep(2)
        remote.press(.right)
        sleep(2)
        shoot("player-scrub")
        expect("player.thumbnail", y: 654, width: 400, height: 225)
        XCTAssertFalse(element("player.title").exists)
    }

    func testMenuDuringAPausedScrubLeavesTheFilmWhereItWas() {
        remote.press(.select)
        sleep(2)
        let before = element("player.elapsed").label
        remote.press(.right)
        sleep(1)
        remote.press(.right)
        sleep(1)
        remote.press(.menu)
        sleep(2)
        XCTAssertEqual(element("player.elapsed").label, before)
    }

    func testASkipOrAHoldWhileHiddenDrawsTheBarAlone() {
        remote.press(.left)
        sleep(1)
        shoot("player-skip")
        expect("player.bar", x: 80, midY: 910)
        XCTAssertFalse(element("player.title").exists)
        XCTAssertFalse(element("player.tab.info").exists)
        sleep(5)
        remote.press(.right, forDuration: 2)
        shoot("player-hold")
        XCTAssertFalse(element("player.title").exists)
    }

    func testDownOpensTheTabsUnderThePills() {
        remote.press(.select)
        sleep(2)
        remote.press(.down)
        sleep(2)
        shoot("player-info")
        expect("player.title", x: 84, y: 518)
        expect("player.tab.info", y: 684)
        expect("player.infoCard", x: 80, y: 794, width: 1760, height: 250)
        remote.press(.right)
        sleep(2)
        shoot("player-chapters")
        expect("player.chapter.0", x: 80, y: 794, width: 320, height: 228)
        expect("player.chapter.1", x: 440, y: 794)
    }

    func testThePopoversStandOnTheirButtons() {
        remote.press(.select)
        sleep(2)
        remote.press(.up)
        sleep(1)
        remote.press(.select)
        sleep(2)
        shoot("player-subtitles")
        // row 0 is the unfocused "On": the file's subtitles start off. A row
        // reads as its label, which the native tree puts at x=1390
        expect("player.menuRow.0", x: 1390, height: 30)
        remote.press(.menu)
        sleep(1)
        remote.press(.right)
        sleep(1)
        remote.press(.select)
        sleep(2)
        shoot("player-audio")
        // row 1 is the unfocused second track; the native label is at x=1480
        expect("player.menuRow.1", x: 1480, height: 30)
    }

    func testGoingDownDuringAPausedScrubDropsIt() {
        remote.press(.select)
        sleep(2)
        let before = element("player.elapsed").label
        remote.press(.right)
        sleep(1)
        remote.press(.down)
        sleep(2)
        XCTAssertEqual(element("player.elapsed").label, before)
    }

    func testPausingAfterASkipShowsThePauseMark() {
        // up on the idle catcher brings the overlay and leaves the film playing
        remote.press(.up)
        sleep(2)
        remote.press(.right)
        sleep(2)
        remote.press(.select)
        sleep(2)
        XCTAssertTrue(element("player.state.pause.circle").exists)
    }

    func testPlayPauseDuringAPausedScrubLandsItAndPlays() {
        remote.press(.select)
        sleep(2)
        let before = seconds(element("player.elapsed").label)
        remote.press(.right)
        sleep(1)
        remote.press(.playPause)
        sleep(3)
        remote.press(.up)
        sleep(1)
        XCTAssertGreaterThanOrEqual(seconds(element("player.elapsed").label), before + 12)
    }

    func testDownIntoChaptersLandsOnTheCurrentOne() {
        remote.press(.select)
        sleep(2)
        remote.press(.down)
        sleep(1)
        remote.press(.right)
        sleep(1)
        // chapter 3 is the one playing; five to the right is chapter 8
        remote.press(.down)
        sleep(1)
        for _ in 0..<5 {
            remote.press(.right)
            sleep(1)
        }
        remote.press(.select)
        sleep(3)
        remote.press(.down)
        sleep(1)
        remote.press(.right)
        sleep(1)
        remote.press(.down)
        sleep(2)
        shoot("player-chapters-late")
        XCTAssertTrue(element("player.chapter.7").hasFocus)
    }

    func testTheLanguageListOpensAndMenuComesBackToIt() {
        remote.press(.select)
        sleep(2)
        remote.press(.up)
        sleep(1)
        remote.press(.select)
        sleep(2)
        // the popover opens on "Off"; one down is "Language"
        remote.press(.down)
        sleep(1)
        remote.press(.select)
        sleep(2)
        shoot("player-subtitle-language")
        XCTAssertFalse(element("player.menuRow.2").exists)
        XCTAssertTrue(app.staticTexts["French"].exists)
        remote.press(.menu)
        sleep(2)
        XCTAssertTrue(element("player.menuRow.2").exists)
    }

    /// The seconds a clock label reads, "1:02:03" or "30:40".
    private func seconds(_ label: String) -> Int {
        label.split(separator: ":").reduce(0) { $0 * 60 + (Int($1) ?? 0) }
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func expect(
        _ id: String, x: CGFloat? = nil, y: CGFloat? = nil, width: CGFloat? = nil, height: CGFloat? = nil,
        midY: CGFloat? = nil, line: UInt = #line
    ) {
        let target = element(id)
        guard target.waitForExistence(timeout: 3) else {
            XCTFail("\(id) is not on screen", line: line)
            return
        }
        let frame = target.frame
        if let x { XCTAssertEqual(frame.minX, x, accuracy: 2, "\(id) x", line: line) }
        if let y { XCTAssertEqual(frame.minY, y, accuracy: 2, "\(id) y", line: line) }
        if let width { XCTAssertEqual(frame.width, width, accuracy: 2, "\(id) width", line: line) }
        if let height { XCTAssertEqual(frame.height, height, accuracy: 2, "\(id) height", line: line) }
        if let midY { XCTAssertEqual(frame.midY, midY, accuracy: 2, "\(id) centre", line: line) }
    }

    private func shoot(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

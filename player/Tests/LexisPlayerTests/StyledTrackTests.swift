import AVFoundation
import LexisTestSupport
import XCTest
@testable import LexisPlayer

final class StyledTrackTests: XCTestCase {
    private func openStyledPlayer(_ name: String) throws -> (LexisPlayer, DisplayLayerSink, Int32) {
        let url = try makeStyledSubtitleFixture(
            directory: FileManager.default.temporaryDirectory, name: name
        )
        let sink = DisplayLayerSink(layer: AVSampleBufferDisplayLayer())
        sink.layer.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let player = LexisPlayer(sink: sink)
        try player.open(url: url)
        let subtitle = try XCTUnwrap(
            player.tracks.subtitle.first { SubtitleDecoder.isStyled(codecID: $0.codecID) }
        )
        return (player, sink, subtitle.index)
    }

    /// Waits until `condition` holds, running the main run loop meanwhile: the
    /// styled path publishes through the main queue.
    private func waitUntil(
        _ description: String, timeout: TimeInterval = 5, _ condition: () -> Bool
    ) {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        XCTFail("timed out waiting for \(description)")
    }

    func testSelectingAnASSTrackDrawsItThroughLibass() throws {
        try skipUnlessRealtimeTests()
        let (player, sink, index) = try openStyledPlayer("styled-select.mkv")
        defer { player.close() }
        player.selectSubtitleTrack(index: index)
        player.play()
        waitUntil("the styled subtitle to reach the screen") {
            sink.shownStyledSubtitle != nil
        }
        let image = try XCTUnwrap(sink.shownStyledSubtitle)
        XCTAssertGreaterThan(image.width, 0)
        // the styled path draws it, so the text path must be drawing nothing
        XCTAssertNil(sink.shownSubtitle)
        // and the track list still reports the selection the way it always did
        XCTAssertEqual(player.tracks.selectedSubtitle, index)
    }

    func testTurningSubtitlesOffStopsLibass() throws {
        try skipUnlessRealtimeTests()
        let (player, sink, index) = try openStyledPlayer("styled-off.mkv")
        defer { player.close() }
        player.selectSubtitleTrack(index: index)
        player.play()
        waitUntil("the styled subtitle") { sink.shownStyledSubtitle != nil }
        player.selectSubtitleTrack(index: -1)
        waitUntil("the styled subtitle to go") { sink.shownStyledSubtitle == nil }
        XCTAssertEqual(player.tracks.selectedSubtitle, -1)
        // it must stay gone: the events went with the renderer
        Thread.sleep(forTimeInterval: 0.3)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertNil(sink.shownStyledSubtitle)
    }

    func testASeekRefeedsTheEventsAfterTheTarget() throws {
        try skipUnlessRealtimeTests()
        let (player, sink, index) = try openStyledPlayer("styled-seek.mkv")
        defer { player.close() }
        player.selectSubtitleTrack(index: index)
        player.play()
        waitUntil("the first styled subtitle") { sink.shownStyledSubtitle != nil }
        let before = try XCTUnwrap(sink.shownStyledSubtitle)

        // 3.2 s is where the two-line event starts, which is taller than the
        // one at 1.0 s and so tells them apart without reading pixels
        player.seek(to: 3.3)
        waitUntil("the event after the seek") {
            guard let image = sink.shownStyledSubtitle else { return false }
            return image.height > before.height
        }
        let after = try XCTUnwrap(sink.shownStyledSubtitle)
        XCTAssertGreaterThan(after.height, before.height)
    }

    func testASinkThatRefusesTheTrackGetsItAsTextInstead() throws {
        let url = try makeStyledSubtitleFixture(
            directory: FileManager.default.temporaryDirectory, name: "styled-fallback.mkv"
        )
        // CountingSink draws nothing and so refuses every styled track, which
        // is the answer a sink gives when libass is unavailable
        let sink = CountingSink()
        let player = LexisPlayer(sink: sink)
        try player.open(url: url)
        defer { player.close() }
        let subtitle = try XCTUnwrap(
            player.tracks.subtitle.first { SubtitleDecoder.isStyled(codecID: $0.codecID) }
        )
        player.selectSubtitleTrack(index: subtitle.index)
        XCTAssertEqual(sink.styledOfferCount, 1)
        player.play()
        // What the text path produced, not what a clock says is on screen at
        // one instant: the second event starts 1.5 s in, so sampling the sink's
        // own clock at 1.5 s decided this assertion by a few milliseconds.
        waitUntil("the first text cue") { sink.delivered.contains { !$0.isEmpty } }
        let first = sink.delivered.first { !$0.isEmpty }
        player.stop()
        // the text path drew it: the markup is stripped, as it was before
        // libass was vendored
        XCTAssertEqual(first?.lines, ["Bonjour la nuit"])
    }

    /// The renderer is built before the player re-checks that the file it was
    /// built for is still open, and nothing records it until after that check:
    /// a close in that window has to take it with it, or it draws the closed
    /// file's events over whatever plays next.
    func testASelectionThatLosesItsFileTakesTheRendererWithIt() throws {
        let url = try makeStyledSubtitleFixture(
            directory: FileManager.default.temporaryDirectory, name: "styled-lost.mkv"
        )
        let sink = CountingSink()
        sink.acceptsStyled = true
        let player = LexisPlayer(sink: sink)
        try player.open(url: url)
        let subtitle = try XCTUnwrap(
            player.tracks.subtitle.first { SubtitleDecoder.isStyled(codecID: $0.codecID) }
        )
        // what another thread's close() would have finished doing while this
        // selection was inside libass
        sink.duringStartStyled = { [weak player] in player?.close() }

        // an open closes whatever came before it, and that is a teardown too
        let before = sink.styledStopCount
        player.selectSubtitleTrack(index: subtitle.index)
        XCTAssertEqual(sink.styledOfferCount, 1)
        // the close's own teardown, and then the one this selection owes for
        // the renderer it built after it
        XCTAssertEqual(sink.styledStopCount - before, 2)
        XCTAssertEqual(player.tracks.selectedSubtitle, -1)
    }

    func testSwitchingFromAStyledTrackToNoneAndBack() throws {
        try skipUnlessRealtimeTests()
        let (player, sink, index) = try openStyledPlayer("styled-switch.mkv")
        defer { player.close() }
        player.selectSubtitleTrack(index: index)
        player.play()
        waitUntil("the styled subtitle") { sink.shownStyledSubtitle != nil }
        player.selectSubtitleTrack(index: -1)
        waitUntil("it to go") { sink.shownStyledSubtitle == nil }
        // a second start must build a second renderer rather than reuse a freed
        // one, and a seek is what makes the events arrive again
        player.selectSubtitleTrack(index: index)
        player.seek(to: 0.5)
        waitUntil("the styled subtitle again") { sink.shownStyledSubtitle != nil }
    }
}

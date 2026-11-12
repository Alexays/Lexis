import CoreMedia
import LexisTestSupport
import XCTest
@testable import LexisPlayer

/// The screen a viewer plugs in mid-film. The capability was read at open
/// and decided the path; when the platform says the screens moved, the
/// player asks again and turns the file round without re-opening it.
final class DisplayChangeTests: XCTestCase {
    /// A screen whose answer the test moves while the player holds on to it.
    final class Screen: @unchecked Sendable {
        private let lock = NSLock()
        private var current: DisplayCapability

        init(_ capability: DisplayCapability) { current = capability }

        var capability: DisplayCapability {
            get { lock.lock(); defer { lock.unlock() }; return current }
            set { lock.lock(); current = newValue; lock.unlock() }
        }
    }

    private func pqFixture(named name: String, frameCount: Int = 30) throws -> URL {
        try makeHDRFixture(
            directory: FileManager.default.temporaryDirectory, name: name,
            width: 320, height: 180, frameCount: frameCount, transfer: .pq
        )
    }

    func testAScreenGainingHeadroomTurnsThePathRound() throws {
        let screen = Screen(DisplayCapability(headroom: 1))
        let player = LexisPlayer(
            sink: CountingSink(), display: { screen.capability }, policy: testBufferPolicy
        )
        try player.open(url: try pqFixture(named: "display-gain.mp4"))
        XCTAssertFalse(player.stats.videoPassthrough, "PQ on an SDR screen must map")

        screen.capability = DisplayCapability(headroom: 4)
        player.displayConfigurationChanged()
        XCTAssertTrue(player.stats.videoPassthrough, "the path never turned round")
        player.close()
    }

    func testAScreenLosingHeadroomTurnsThePathRoundTheOtherWay() throws {
        let screen = Screen(DisplayCapability(headroom: 4))
        let player = LexisPlayer(
            sink: CountingSink(), display: { screen.capability }, policy: testBufferPolicy
        )
        try player.open(url: try pqFixture(named: "display-loss.mp4"))
        XCTAssertTrue(player.stats.videoPassthrough, "PQ on an HDR screen rides as it is")

        screen.capability = DisplayCapability(headroom: 1)
        player.displayConfigurationChanged()
        XCTAssertFalse(player.stats.videoPassthrough, "the path never turned round")
        player.close()
    }

    /// A screen with far more pixels than the film is the upscaled path's
    /// whole reason to exist, and plugging one in mid-life must find it.
    func testAScreenGainingPixelsTurnsTheSmallFilmOntoTheUpscaledPath() throws {
        try skipUnlessUpscaler()
        let screen = Screen(DisplayCapability(headroom: 1, pixelHeight: 180))
        let player = LexisPlayer(
            sink: CountingSink(), display: { screen.capability }, policy: testBufferPolicy
        )
        try player.open(
            url: try makeVideoFixture(
                directory: FileManager.default.temporaryDirectory, name: "display-pixels.mp4",
                codec: .h264, width: 320, height: 180, frameCount: 24, fps: 24
            ))
        XCTAssertFalse(player.stats.videoUpscaled)
        XCTAssertTrue(player.stats.videoPassthrough)

        screen.capability = DisplayCapability(headroom: 1, pixelHeight: 2160)
        player.displayConfigurationChanged()
        XCTAssertTrue(player.stats.videoUpscaled)
        XCTAssertFalse(player.stats.videoPassthrough)

        screen.capability = DisplayCapability(headroom: 1, pixelHeight: 180)
        player.displayConfigurationChanged()
        XCTAssertFalse(player.stats.videoUpscaled)
        XCTAssertTrue(player.stats.videoPassthrough)
        player.close()
    }

    /// The raw headroom reading drifts between asks. A drift that stays on
    /// the same side of every threshold moves no decision, and must not
    /// cost the viewer a rebuild - here it must at least not change what
    /// the player reports or end the playback.
    func testADriftThatMovesNoDecisionChangesNothing() throws {
        let screen = Screen(DisplayCapability(headroom: 4))
        let player = LexisPlayer(
            sink: CountingSink(), display: { screen.capability }, policy: testBufferPolicy
        )
        try player.open(url: try pqFixture(named: "display-drift.mp4"))
        XCTAssertTrue(player.stats.videoPassthrough)

        screen.capability = DisplayCapability(headroom: 4.2)
        player.displayConfigurationChanged()
        XCTAssertTrue(player.stats.videoPassthrough)
        XCTAssertTrue(player.isOpen)
        player.close()
    }
}

/// The same turn-round under a live engine: the film has to keep playing,
/// on the other path, without the stream being re-opened.
final class DisplayChangePlaybackTests: RealtimeTestCase {
    func testTheFilmKeepsPlayingAcrossAScreenChange() throws {
        let url = try makeHDRFixture(
            directory: FileManager.default.temporaryDirectory, name: "display-live.mp4",
            width: 320, height: 180, frameCount: 300, transfer: .pq, gopSize: 30
        )
        let screen = DisplayChangeTests.Screen(DisplayCapability(headroom: 1))
        let sink = CountingSink()
        sink.setEnqueueDelay(0.02)
        let player = LexisPlayer(
            sink: sink, display: { screen.capability }, policy: testBufferPolicy
        )
        try player.open(url: url)
        XCTAssertFalse(player.stats.videoPassthrough)
        player.play()
        pollUntil("a mapped picture crosses the sink") { sink.pictures > 0 }

        screen.capability = DisplayCapability(headroom: 4)
        player.displayConfigurationChanged()
        XCTAssertTrue(player.stats.videoPassthrough, "the live path never turned round")
        let landed = sink.samples.count
        pollUntil("compressed samples flow on the new path") { sink.samples.count > landed }
        player.stop()
    }
}

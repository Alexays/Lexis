import XCTest
@testable import LexisPlayer

/// A 23.976 fps film on a screen switched to 23.976 Hz, timed by an audio
/// clock a few ppm off the screen's: the frame grid drifts against the
/// refreshes over a film, and the renderer's own clock jitter decides which
/// refresh shows a frame whose time sits near a refresh edge.
final class RefreshSlotTests: XCTestCase {
    private let period = 1001.0 / 24000

    /// The drops and repeats of `frames` frames whose times run `drift` fast
    /// against the refreshes, from the middle of refresh 0 as a clock start
    /// lines them up, each shown at the first refresh its time plus up to
    /// `jitter` either way has reached; `placed` retimes them onto
    /// `refreshSlot` first.
    private func screen(
        frames: Int, drift: Double, jitter: Double, placed: Bool, cutEvery: Int = 70, seesCuts: Bool = false
    ) -> (drops: Int, repeats: Int, offCut: Int) {
        var seed: UInt64 = 0x2545_F491_4F6C_DD1D
        var previousSlot: Double?
        var previousRefresh: Int?
        var drops = 0
        var repeats = 0
        var offCut = 0
        for k in 0..<frames {
            let frameHost = period / 2 + Double(k) * period / (1 + drift)
            var host = frameHost
            if placed {
                // the display link's last reading, a quarter second or so behind
                let vsync = ((frameHost - 0.3) / period).rounded(.down) * period
                host = DisplayLayerSink.refreshSlot(
                    frameHost: frameHost, previous: previousSlot, vsync: vsync, period: period,
                    refreshesPerFrame: 1, atCut: seesCuts && k % cutEvery == 0)
                if let previousSlot { XCTAssertGreaterThan(host, previousSlot) }
                previousSlot = host
            }
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let noise = (Double(seed >> 11) / Double(1 << 53) * 2 - 1) * jitter
            let refresh = Int(((host + noise) / period).rounded(.up))
            if let previousRefresh {
                if refresh == previousRefresh { drops += 1 }
                if refresh > previousRefresh + 1 { repeats += refresh - previousRefresh - 1 }
                if refresh != previousRefresh + 1, k % cutEvery != 0 { offCut += 1 }
            }
            previousRefresh = refresh
        }
        return (drops, repeats, offCut)
    }

    /// Two and a half hours at 3 ppm is two thirds of a refresh of drift: the
    /// frames left on their own times cross the refresh edge and drop in a
    /// burst around it, the placed ones keep their refreshes.
    func testLessThanARefreshOfDriftDropsNothingOncePlaced() {
        let frames = 5 * 1800 * 24
        let own = screen(frames: frames, drift: 3e-6, jitter: 0.003, placed: false)
        let placed = screen(frames: frames, drift: 3e-6, jitter: 0.003, placed: true)
        XCTAssertGreaterThan(own.drops, 10)
        XCTAssertGreaterThan(own.repeats, 10)
        XCTAssertEqual(placed.drops, 0)
        XCTAssertEqual(placed.repeats, 0)
    }

    /// Over a refresh and a half of drift each way, the placed frames move
    /// across the refreshes once per refresh of drift, as one drop on a fast
    /// clock and one repeat on a slow one, whatever the jitter.
    func testEachRefreshOfDriftCostsOneFrameOncePlaced() {
        let frames = 3 * 3600 * 24
        let fast = screen(frames: frames, drift: 6e-6, jitter: 0.005, placed: true)
        XCTAssertEqual(fast.drops, 1)
        XCTAssertEqual(fast.repeats, 0)
        let slow = screen(frames: frames, drift: -6e-6, jitter: 0.005, placed: true)
        XCTAssertEqual(slow.drops, 0)
        XCTAssertEqual(slow.repeats, 1)
        let own = screen(frames: frames, drift: 6e-6, jitter: 0.005, placed: false)
        XCTAssertGreaterThan(own.drops, 10 * fast.drops)
    }

    /// An Apple TV's sound clock a film's bitstream runs on drifts tens of
    /// ppm from its screen: the grid has to move every few minutes, and with
    /// a cut every few seconds every move lands on one.
    func testTheGridMovesAtCuts() {
        let frames = 20 * 60 * 24
        for drift in [73e-6, -73e-6] {
            let cut = screen(frames: frames, drift: drift, jitter: 0.003, placed: true, seesCuts: true)
            XCTAssertGreaterThan(cut.drops + cut.repeats, 0)
            XCTAssertEqual(cut.offCut, 0)
            let anywhere = screen(frames: frames, drift: drift, jitter: 0.003, placed: true)
            XCTAssertGreaterThan(anywhere.offCut, 0)
        }
    }
}

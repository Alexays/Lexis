import XCTest
@testable import LexisPlayer

final class PlaybackActivityGateTests: XCTestCase {
    override func tearDown() {
        // The gate is a process-wide singleton: leave it exactly as this test
        // found it, or the next test to run inherits whichever hold this one
        // forgot to release.
        PlaybackActivityGate.shared.endPlayer()
        PlaybackActivityGate.shared.endProbe()
        super.tearDown()
    }

    func testAPlayerRefusesAProbeAndAProbeRefusesAPlayer() throws {
        try PlaybackActivityGate.shared.beginPlayer()
        XCTAssertThrowsError(try PlaybackActivityGate.shared.beginProbe()) {
            XCTAssertEqual($0 as? PlaybackActivityGate.Busy, .playbackRunning)
        }
        PlaybackActivityGate.shared.endPlayer()

        try PlaybackActivityGate.shared.beginProbe()
        XCTAssertThrowsError(try PlaybackActivityGate.shared.beginPlayer()) {
            XCTAssertEqual($0 as? PlaybackActivityGate.Busy, .probeRunning)
        }
        PlaybackActivityGate.shared.endProbe()
    }

    func testReleasingLetsTheOtherSideBeginAgain() throws {
        try PlaybackActivityGate.shared.beginPlayer()
        PlaybackActivityGate.shared.endPlayer()
        try PlaybackActivityGate.shared.beginProbe()
        PlaybackActivityGate.shared.endProbe()
        try PlaybackActivityGate.shared.beginPlayer()
        PlaybackActivityGate.shared.endPlayer()
    }

    func testTheGateStaysHeldUntilTheLastOfTwoPlayersLetsGo() throws {
        try PlaybackActivityGate.shared.beginPlayer()
        try PlaybackActivityGate.shared.beginPlayer()
        PlaybackActivityGate.shared.endPlayer()
        // one of the two players is still open: a probe must still be refused
        XCTAssertThrowsError(try PlaybackActivityGate.shared.beginProbe())
        PlaybackActivityGate.shared.endPlayer()
        try PlaybackActivityGate.shared.beginProbe()
        PlaybackActivityGate.shared.endProbe()
    }

    func testEndingAnUnheldGateIsHarmless() throws {
        // a stray endPlayer()/endProbe() (a close() on a LexisPlayer that
        // never actually opened, or a stray defer with no matching begin)
        // must not go negative or flip the holder: the gate is left exactly
        // as it was, open to either side
        PlaybackActivityGate.shared.endPlayer()
        PlaybackActivityGate.shared.endPlayer()
        PlaybackActivityGate.shared.endProbe()
        PlaybackActivityGate.shared.endProbe()
        try PlaybackActivityGate.shared.beginProbe()
        PlaybackActivityGate.shared.endProbe()
        try PlaybackActivityGate.shared.beginPlayer()
        PlaybackActivityGate.shared.endPlayer()
    }

    /// The case the count on the probe side exists for: two probes racing
    /// each other (two mounted views, since `DecodeOnlyProbeRun.run` is
    /// `public static` and callable from anywhere), the first finishing
    /// while the second is still decoding. A player must stay refused for
    /// as long as either probe is still running, not just the first.
    func testTheGateStaysHeldUntilTheLastOfTwoProbesLetsGo() throws {
        try PlaybackActivityGate.shared.beginProbe()
        try PlaybackActivityGate.shared.beginProbe()
        PlaybackActivityGate.shared.endProbe()
        // one of the two probes is still running: a player must still be refused
        XCTAssertThrowsError(try PlaybackActivityGate.shared.beginPlayer()) {
            XCTAssertEqual($0 as? PlaybackActivityGate.Busy, .probeRunning)
        }
        PlaybackActivityGate.shared.endProbe()
        try PlaybackActivityGate.shared.beginPlayer()
        PlaybackActivityGate.shared.endPlayer()
    }
}

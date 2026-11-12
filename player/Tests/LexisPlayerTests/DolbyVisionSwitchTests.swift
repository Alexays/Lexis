import LexisTestSupport
import XCTest
@testable import LexisPlayer

/// The viewer's own say over Dolby Vision: off, a base layer that is a
/// picture on its own is handed over as the HDR it also is, record and all
/// gone, and the range reported to the display follows.
final class DolbyVisionSwitchTests: XCTestCase {
    /// The HLG fixture carries a profile 8.4 record: a base layer any HDR
    /// screen shows, so the record rides beside the hvc1 entry by default.
    private func fixture(named name: String) throws -> URL {
        try makeHDRFixture(
            directory: FileManager.default.temporaryDirectory, name: name,
            width: 320, height: 180, frameCount: 4, transfer: .hlg
        )
    }

    func testTheRecordRidesByDefaultAndTheRangeSaysSo() throws {
        let url = try fixture(named: "dv-switch-on.mp4")
        let stream = try Demuxer(url: url).streams[0]
        try XCTSkipUnless(
            stream.dolbyVision?.recordDescribesWhatIsHandedOver == true,
            "this fixture carries no record a display would take")
        let player = LexisPlayer(sink: CountingSink(), display: { DisplayCapability(headroom: 4) })
        try player.open(url: url)
        defer { player.stop() }
        XCTAssertEqual(player.dynamicRange, .dolbyVision)
    }

    func testSwitchedOffTheBaseLayerGoesAsTheHDRItIs() throws {
        let url = try fixture(named: "dv-switch-off.mp4")
        let stream = try Demuxer(url: url).streams[0]
        try XCTSkipUnless(
            stream.dolbyVision?.recordDescribesWhatIsHandedOver == true,
            "this fixture carries no record a display would take")
        let player = LexisPlayer(sink: CountingSink(), display: { DisplayCapability(headroom: 4) })
        player.setDolbyVisionAllowed(false)
        try player.open(url: url)
        defer { player.stop() }
        XCTAssertEqual(player.dynamicRange, .hlg)
        XCTAssertEqual(player.stats.videoDescription, "hvc1")
    }

    /// A switch thrown mid-film turns the open file round, the way a screen
    /// change does: the range moves without a second open.
    func testASwitchThrownMidFilmTurnsTheFilmRound() throws {
        let url = try fixture(named: "dv-switch-mid.mp4")
        let stream = try Demuxer(url: url).streams[0]
        try XCTSkipUnless(
            stream.dolbyVision?.recordDescribesWhatIsHandedOver == true,
            "this fixture carries no record a display would take")
        let player = LexisPlayer(sink: CountingSink(), display: { DisplayCapability(headroom: 4) })
        try player.open(url: url)
        defer { player.stop() }
        XCTAssertEqual(player.dynamicRange, .dolbyVision)
        player.setDolbyVisionAllowed(false)
        let deadline = Date(timeIntervalSinceNow: 10)
        while player.dynamicRange == .dolbyVision, Date() < deadline { usleep(20_000) }
        XCTAssertEqual(player.dynamicRange, .hlg)
    }
}

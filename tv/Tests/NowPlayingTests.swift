import MediaPlayer
import XCTest
@testable import Lexis

@MainActor
final class NowPlayingTests: XCTestCase {
    // NowPlaying holds its model weakly: the test keeps both alive.
    private var models: [PlayerModel] = []
    private var attached: [NowPlaying] = []

    override func tearDown() async throws {
        for nowPlaying in attached { nowPlaying.detach() }
        attached = []
        models = []
    }

    private func attach(_ title: String, context: String = "") -> NowPlaying {
        let model = PlayerModel(playing: Playing(fileId: 1, title: title, startAt: 0, context: context))
        let nowPlaying = NowPlaying(model: model)
        nowPlaying.attach()
        models.append(model)
        attached.append(nowPlaying)
        return nowPlaying
    }

    private var info: [String: Any] { MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:] }

    private func track(_ index: Int, _ language: String, selected: Bool) -> MediaTrack {
        MediaTrack([
            "index": NSNumber(value: index), "codec": "aac", "language": language, "title": "",
            "graphic": NSNumber(value: false), "selected": NSNumber(value: selected),
        ] as NSDictionary)
    }

    func testAttachingPublishesTheFilm() {
        _ = attach("Heat", context: "Michael Mann, 1995")
        XCTAssertEqual(info[MPMediaItemPropertyTitle] as? String, "Heat")
        XCTAssertEqual(info[MPMediaItemPropertyArtist] as? String, "Michael Mann, 1995")
        XCTAssertEqual(info[MPNowPlayingInfoPropertyMediaType] as? UInt, MPNowPlayingInfoMediaType.video.rawValue)
        XCTAssertEqual(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0)
    }

    func testAFilmWithoutContextHasNoArtist() {
        _ = attach("Heat")
        XCTAssertNil(info[MPMediaItemPropertyArtist])
    }

    func testPublishingFollowsPlayback() {
        let nowPlaying = attach("Heat")
        nowPlaying.publish(playing: true, position: 42, duration: 3600)
        XCTAssertEqual(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 42)
        XCTAssertEqual(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 1)
        XCTAssertEqual(info[MPMediaItemPropertyPlaybackDuration] as? Double, 3600)
        nowPlaying.publish(playing: false, position: 50, duration: 3600)
        XCTAssertEqual(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 50)
        XCTAssertEqual(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0)
        XCTAssertEqual(info[MPMediaItemPropertyTitle] as? String, "Heat")
    }

    func testAnUnknownDurationIsLeftOut() {
        let nowPlaying = attach("Heat")
        nowPlaying.publish(playing: true, position: 3600, duration: 7200)
        nowPlaying.publish(playing: true, position: 5, duration: 0)
        XCTAssertNil(info[MPMediaItemPropertyPlaybackDuration])
    }

    func testLanguagesOfferAudioAndSubtitlesWithTheCurrentOnes() throws {
        let nowPlaying = attach("Heat")
        nowPlaying.publishLanguages(
            audio: [track(1, "fre", selected: true), track(2, "eng", selected: false)],
            subtitle: [track(3, "eng", selected: false)])
        let groups = try XCTUnwrap(info[MPNowPlayingInfoPropertyAvailableLanguageOptions] as? [MPNowPlayingInfoLanguageOptionGroup])
        XCTAssertEqual(groups.count, 2)
        XCTAssertFalse(groups[0].allowEmptySelection)
        XCTAssertEqual(groups[0].languageOptions.map(\.identifier), ["audio:1", "audio:2"])
        XCTAssertEqual(groups[0].languageOptions.map(\.languageTag), ["fr", "en"])
        XCTAssertEqual(groups[0].languageOptions.map(\.languageOptionType), [.audible, .audible])
        XCTAssertTrue(groups[1].allowEmptySelection)
        XCTAssertEqual(groups[1].languageOptions.map(\.identifier), ["subtitle:3"])
        XCTAssertEqual(groups[1].languageOptions.map(\.languageOptionType), [.legible])
        let current = try XCTUnwrap(info[MPNowPlayingInfoPropertyCurrentLanguageOptions] as? [MPNowPlayingInfoLanguageOption])
        XCTAssertEqual(current.map(\.identifier), ["audio:1"])
    }

    func testAnAudioAndASubtitleTrackAtTheSameIndexStayApart() throws {
        let nowPlaying = attach("Heat")
        nowPlaying.publishLanguages(audio: [track(2, "fre", selected: true)], subtitle: [track(2, "fre", selected: true)])
        let current = try XCTUnwrap(info[MPNowPlayingInfoPropertyCurrentLanguageOptions] as? [MPNowPlayingInfoLanguageOption])
        XCTAssertEqual(current.map(\.identifier), ["audio:2", "subtitle:2"])
    }

    func testAFileWithoutSubtitlesOffersOnlyItsAudio() throws {
        let nowPlaying = attach("Heat")
        nowPlaying.publishLanguages(audio: [track(1, "eng", selected: true)], subtitle: [])
        let groups = try XCTUnwrap(info[MPNowPlayingInfoPropertyAvailableLanguageOptions] as? [MPNowPlayingInfoLanguageOptionGroup])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].languageOptions.map(\.languageOptionType), [.audible])
    }

    func testTheLastFilmLeavingLateDoesNotTouchTheNext() {
        let last = attach("Episode 1")
        _ = attach("Episode 2")
        last.publish(playing: false, position: 2500, duration: 2600)
        XCTAssertEqual(info[MPMediaItemPropertyTitle] as? String, "Episode 2")
        XCTAssertNil(info[MPNowPlayingInfoPropertyElapsedPlaybackTime])
        last.detach()
        XCTAssertEqual(info[MPMediaItemPropertyTitle] as? String, "Episode 2")
    }

    func testClosingTheLastFilmsPlayerLeavesTheNextFilmShown() {
        let last = attach("Episode 1")
        _ = attach("Episode 2")
        let host = PlayerHostView(frame: .zero)
        last.detach()
        host.bridge.close()
        XCTAssertEqual(info[MPMediaItemPropertyTitle] as? String, "Episode 2")
    }

    func testDetachingEmptiesTheCenter() {
        let nowPlaying = attach("Heat")
        nowPlaying.detach()
        XCTAssertNil(MPNowPlayingInfoCenter.default().nowPlayingInfo)
    }
}

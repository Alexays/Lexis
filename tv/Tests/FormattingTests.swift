import LexisCore
import XCTest
@testable import Lexis

final class FormattingTests: XCTestCase {
    override func setUp() {
        I18n.shared.choose(.pinned(.en))
    }

    func testRuntimeReadsHoursAndMinutes() {
        XCTAssertEqual(Format.runtime(48 * 60), "48 min")
        XCTAssertEqual(Format.runtime(112 * 60), "1h 52m")
        XCTAssertEqual(Format.runtime(3605), "1h 00m")
        I18n.shared.choose(.pinned(.fr))
        XCTAssertEqual(Format.runtime(112 * 60), "1h52")
    }

    func testClockCarriesHoursOnlyWhenAsked() {
        XCTAssertEqual(Format.clock(243, withHours: false), "4:03")
        XCTAssertEqual(Format.clock(3723, withHours: false), "62:03")
        XCTAssertEqual(Format.clock(3723, withHours: true), "1:02:03")
        XCTAssertEqual(Format.clock(-5, withHours: true), "0:00")
    }

    func testWallClockFollowsTheLanguage() {
        XCTAssertEqual(Format.wallClock(minutes: 22 * 60 + 30), "22:30")
        I18n.shared.choose(.pinned(.fr))
        XCTAssertEqual(Format.wallClock(minutes: 22 * 60 + 5), "22h05")
    }

    /// A library holds a genre in whichever language its server named it:
    /// each is said in the language on screen, and one nobody knows as it is.
    func testAGenreIsSaidInTheLanguageOnScreen() {
        XCTAssertEqual(Format.genre("Drame"), "Drama")
        XCTAssertEqual(Format.genre("Adventure"), "Adventure")
        I18n.shared.choose(.pinned(.fr))
        XCTAssertEqual(Format.genre("Adventure"), "Aventure")
        XCTAssertEqual(Format.genre("Science Fiction"), "Science-fiction")
        XCTAssertEqual(Format.genre("Polar nordique"), "Polar nordique")
    }

    func testMonogramSkipsArticles() {
        XCTAssertEqual(Format.monogram("The Dark Knight"), "DK")
        XCTAssertEqual(Format.monogram("Le fabuleux destin"), "FD")
        XCTAssertEqual(Format.monogram("The A"), "TA")
        XCTAssertEqual(Format.monogram("Zendaya"), "Z")
    }

    func testInitialsTakeFirstAndLast() {
        XCTAssertEqual(Format.initials("Jean-Pierre Bacri"), "JB")
        XCTAssertEqual(Format.initials("Zendaya"), "Z")
        XCTAssertEqual(Format.initials("Anne Marie Rose"), "AR")
    }

    func testBadgesPromiseOnlyWhatTheFileSays() {
        let media = TitleMedia(
            videoResolution: "4k", videoCodec: "hevc", dynamicRange: "dolby_vision",
            audioCodec: "truehd", audioChannels: 8, atmos: true, audioLanguages: [],
            subtitleLanguages: [])
        XCTAssertEqual(Format.badges(media), ["4K", "DOLBY VISION", "ATMOS"])
        var hdr = media
        hdr.dynamicRange = "hdr10"
        hdr.atmos = false
        hdr.videoResolution = "1080"
        XCTAssertEqual(Format.badges(hdr), ["1080P", "HDR"])
        XCTAssertEqual(Format.badges(nil), [])
        XCTAssertEqual(Format.audioLine(media), "Dolby Atmos  ·  Dolby TrueHD 7.1")
        var stereo = media
        stereo.audioCodec = "aac"
        stereo.audioChannels = 2
        stereo.atmos = false
        XCTAssertEqual(Format.audioLine(stereo), "AAC Stereo")
    }

    func testAVersionReadsItsCutItsPictureItsWeightAndItsLength() {
        let media = TitleMedia(
            videoResolution: "1080", videoCodec: "h264", dynamicRange: "", audioCodec: "dca",
            audioChannels: 6, atmos: false, audioLanguages: [], subtitleLanguages: [])
        var version = TitleVersion(
            fileId: 1, edition: "Extended Edition", sizeBytes: 14_100_000_000, runtimeSecs: 159 * 60, media: media)
        XCTAssertEqual(Format.version(version), "Extended Edition  ·  1080P  ·  14.1 GB  ·  2h 39m")
        version.edition = ""
        version.sizeBytes = 0
        XCTAssertEqual(Format.version(version), "1080P  ·  2h 39m")
    }

    func testLanguagesNameEveryTrackTheFileSays() {
        I18n.shared.choose(.pinned(.fr))
        var media = TitleMedia(
            videoResolution: "", videoCodec: "", dynamicRange: "", audioCodec: "", audioChannels: 0,
            atmos: false, audioLanguages: ["en", "fr"], subtitleLanguages: ["fr"])
        XCTAssertEqual(Format.languagesLine(media), "Anglais, Français  ·  sous-titres Français")
        // "mul" is a release naming more tracks than it lists, not a language
        media.audioLanguages = ["fr", "mul"]
        media.subtitleLanguages = []
        XCTAssertEqual(Format.languagesLine(media), "Français")
        media.audioLanguages = []
        XCTAssertNil(Format.languagesLine(media))
    }

    func testScoresNameTheirProvider() {
        XCTAssertEqual(Format.score(TitleScore(value: 8.04, source: "imdb"))?.value, "8.0 / 10")
        XCTAssertEqual(Format.score(TitleScore(value: 8.04, source: "imdb"))?.source, "IMDb")
        XCTAssertEqual(Format.score(TitleScore(value: 9.3, source: "rottentomatoes"))?.value, "93%")
        XCTAssertNil(Format.score(TitleScore(value: 5, source: "metacritic")))
        I18n.shared.choose(.pinned(.fr))
        XCTAssertEqual(Format.score(TitleScore(value: 8.04, source: "themoviedb"))?.value, "8,0 / 10")
    }

    func testEpisodeCodeAndDecades() {
        XCTAssertEqual(Format.episodeCode(season: 1, episode: 2), "S1, E2")
        XCTAssertEqual(Format.episodeCode(season: nil, episode: 2), "")
        XCTAssertEqual(Format.decadeName(1990), "1990")
        I18n.shared.choose(.pinned(.fr))
        XCTAssertEqual(Format.episodeCode(season: 1, episode: 2), "S1, É2")
        XCTAssertEqual(Format.decadeName(1990), "90")
        XCTAssertEqual(Format.decadeName(2000), "2000")
    }
}

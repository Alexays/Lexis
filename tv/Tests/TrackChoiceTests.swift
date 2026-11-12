import XCTest
@testable import Lexis

final class TrackChoiceTests: XCTestCase {
    private func track(
        _ index: Int, _ language: String, codec: String = "aac", title: String = "", channels: Int = 2,
        isDefault: Bool = false, forced: Bool = false, graphic: Bool = false, selected: Bool = false
    ) -> MediaTrack {
        MediaTrack([
            "index": NSNumber(value: index), "codec": codec, "language": language, "title": title,
            "channels": NSNumber(value: channels), "default": NSNumber(value: isDefault),
            "forced": NSNumber(value: forced), "graphic": NSNumber(value: graphic),
            "selected": NSNumber(value: selected),
        ] as NSDictionary)
    }

    func testAudioTakesTheLanguageAskedForOverTheOneOpened() {
        let tracks = [track(1, "eng", isDefault: true, selected: true), track(2, "fre", channels: 6)]
        XCTAssertEqual(MediaTrack.bestAudio(tracks, language: "fr")?.index, 2)
    }

    func testAudioFallsBackToTheDefaultTracksLanguage() {
        let tracks = [track(1, "ita", selected: true), track(2, "eng", isDefault: true)]
        XCTAssertEqual(MediaTrack.bestAudio(tracks, language: "fr")?.index, 2)
    }

    func testAudioNeverOpensOnACommentary() {
        let tracks = [
            track(1, "fre", title: "Commentaire du réalisateur", isDefault: true),
            track(2, "fre", channels: 6),
        ]
        XCTAssertEqual(MediaTrack.bestAudio(tracks, language: "fr")?.index, 2)
    }

    func testAudioKeepsTheBitstreamTwinOfATrueHDTrack() {
        let tracks = [
            track(1, "eng", selected: true),
            track(2, "fre", codec: "truehd", channels: 8),
            track(3, "fre", codec: "eac3", channels: 6),
        ]
        XCTAssertEqual(MediaTrack.bestAudio(tracks, language: "fr")?.index, 3)
    }

    func testAudioNeverTradesATrueHDTrackForAStereoDownmix() {
        let tracks = [
            track(1, "eng", selected: true),
            track(2, "fre", codec: "truehd", channels: 8),
            track(3, "fre", codec: "ac3", channels: 2),
        ]
        XCTAssertEqual(MediaTrack.bestAudio(tracks, language: "fr")?.index, 2)
    }

    func testAnUntaggedTrackNamedVFFIsFrench() {
        // an untagged Matroska track reads "eng"
        let tracks = [track(1, "eng", title: "VO", selected: true), track(2, "eng", title: "VFF 5.1")]
        XCTAssertEqual(MediaTrack.bestAudio(tracks, language: "fr")?.index, 2)
    }

    func testFranceComesBeforeQuebec() {
        let tracks = [
            track(1, "eng", selected: true), track(2, "fre", title: "VFQ", channels: 6),
            track(3, "fre", title: "VFF", channels: 2),
        ]
        XCTAssertEqual(MediaTrack.bestAudio(tracks, language: "fr")?.index, 3)
    }

    func testSubtitlesPreferPlainTextOverSDHAndPictures() {
        let tracks = [
            track(1, "fre", codec: "hdmv_pgs_subtitle", graphic: true),
            track(2, "fre", codec: "subrip", title: "SDH"),
            track(3, "fre", codec: "subrip", title: "Forcés", forced: true),
            track(4, "fre", codec: "subrip"),
        ]
        XCTAssertEqual(MediaTrack.bestSubtitle(tracks, language: "fr")?.index, 4)
    }
}

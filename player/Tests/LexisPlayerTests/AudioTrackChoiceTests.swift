import XCTest
@testable import LexisPlayer

final class AudioTrackChoiceTests: XCTestCase {
    private func stream(
        _ index: Int32, kind: StreamKind = .audio, codec: String, language: String,
        channels: Int32 = 6, title: String = ""
    ) -> MediaStream {
        MediaStream(
            index: index, kind: kind, codecID: 0, codecName: codec, width: 0, height: 0,
            timeBaseNum: 1, timeBaseDen: 1000, sampleRate: 48000, channels: channels, videoDelay: 0,
            language: language, title: title, isDefault: false, isForced: false,
            colorPrimaries: 2, colorTransfer: 2, colorMatrix: 2, isFullRange: false,
            masteringDisplay: nil, contentLight: nil, dolbyVision: nil, extradata: nil
        )
    }

    func testATrueHDFirstTrackYieldsToTheEAC3OfTheSameLanguage() {
        let streams = [
            stream(0, kind: .video, codec: "hevc", language: ""),
            stream(1, codec: "truehd", language: "fre"),
            stream(2, codec: "eac3", language: "fre"),
            stream(3, codec: "eac3", language: "eng"),
        ]
        XCTAssertEqual(preferredAudioStream(among: streams)?.index, 2)
    }

    func testSurroundIsNeverTradedForAStereoDownmixOrACommentary() {
        let streams = [
            stream(1, codec: "truehd", language: "eng", channels: 8),
            stream(2, codec: "ac3", language: "eng", channels: 2),
            stream(3, codec: "ac3", language: "eng", channels: 6, title: "Director's Commentary"),
        ]
        XCTAssertEqual(preferredAudioStream(among: streams)?.index, 1)
        let withTwin = streams + [stream(4, codec: "ac3", language: "eng", channels: 6)]
        XCTAssertEqual(preferredAudioStream(among: withTwin)?.index, 4)
    }

    func testALanguageIsNeverTradedForAFormat() {
        let streams = [
            stream(1, codec: "dts", language: "fre"),
            stream(2, codec: "eac3", language: "eng"),
        ]
        XCTAssertEqual(preferredAudioStream(among: streams)?.index, 1)
    }

    func testAnARCRouteTakesTheDolbyTrackOverSurroundItWouldFoldToStereo() {
        let arc = AudioRoute(channels: 2, takesDolby: true)
        let streams = [
            stream(1, codec: "flac", language: "fre"),
            stream(2, codec: "ac3", language: "fre", channels: 2),
            stream(3, codec: "eac3", language: "eng"),
            stream(4, codec: "ac3", language: "fre"),
        ]
        XCTAssertEqual(preferredAudioStream(among: streams, route: arc)?.index, 4)
        XCTAssertEqual(preferredAudioStream(among: streams)?.index, 1)
        XCTAssertEqual(preferredAudioStream(among: Array(streams.prefix(3)), route: arc)?.index, 1)
    }

    func testAStereoFirstTrackFitsAnARCRouteAsItIs() {
        let streams = [
            stream(1, codec: "aac", language: "eng", channels: 2),
            stream(2, codec: "eac3", language: "eng"),
        ]
        XCTAssertEqual(preferredAudioStream(among: streams, route: AudioRoute(channels: 2, takesDolby: true))?.index, 1)
    }

    func testARouteThatDecodesEveryTrackKeepsTheLosslessOne() {
        let streams = [
            stream(1, codec: "truehd", language: "eng", channels: 8),
            stream(2, codec: "eac3", language: "eng"),
        ]
        XCTAssertEqual(preferredAudioStream(among: streams, route: AudioRoute(channels: 2, takesDolby: false))?.index, 1)
        XCTAssertEqual(preferredAudioStream(among: streams, route: AudioRoute(channels: 8, takesDolby: false))?.index, 1)
        XCTAssertEqual(preferredAudioStream(among: streams, route: AudioRoute(channels: 2, takesDolby: true))?.index, 2)
    }

    func testAnyOtherFirstTrackStandsAsTheContainerOrderedIt() {
        let streams = [
            stream(1, codec: "aac", language: "eng"),
            stream(2, codec: "eac3", language: "eng"),
        ]
        XCTAssertEqual(preferredAudioStream(among: streams)?.index, 1)
        XCTAssertNil(preferredAudioStream(among: [stream(0, kind: .video, codec: "hevc", language: "")]))
    }
}

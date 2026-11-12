import CoreGraphics
import LexisTestSupport
import XCTest
@testable import LexisPlayer

final class SubtitleDecoderTests: XCTestCase {
    private func fixture(_ name: String) throws -> URL {
        try makeSubtitleFixture(directory: FileManager.default.temporaryDirectory, name: name)
    }

    /// Every cue one subtitle stream of the fixture carries.
    private func decodeCues(_ url: URL, kind: String) throws -> [SubtitleCue] {
        let demuxer = try Demuxer(url: url)
        let stream = try XCTUnwrap(demuxer.streams.first { $0.codecName == kind })
        let decoder = try SubtitleDecoder(stream: stream)
        var cues: [SubtitleCue] = []
        while let packet = try demuxer.readPacket() {
            guard packet.streamIndex == stream.index else { continue }
            if let cue = try decoder.decode(packet) { cues.append(cue) }
        }
        return cues
    }

    func testDecodesASSDialogueToItsText() throws {
        let cues = try decodeCues(try fixture("subs-ass.mkv"), kind: "ass")
        XCTAssertEqual(cues.count, 2)
        // the block says when it starts and how long it lasts, and the override
        // blocks the dialogue carries are not text
        XCTAssertEqual(cues[0].start, 1.0, accuracy: 0.001)
        XCTAssertEqual(cues[0].end, 3.0, accuracy: 0.001)
        XCTAssertEqual(cues[0].lines, ["Bonjour la nuit"])
        XCTAssertTrue(cues[0].images.isEmpty)
        XCTAssertFalse(cues[0].isEmpty)
        // no canvas on a text stream, which is what tells an empty cue that
        // draws nothing apart from a graphic stream's clear
        XCTAssertEqual(cues[0].canvasWidth, 0)
        XCTAssertEqual(cues[0].canvasHeight, 0)

        XCTAssertEqual(cues[1].start, 3.2, accuracy: 0.001)
        XCTAssertEqual(cues[1].end, 4.0, accuracy: 0.001)
        // \N is where the author broke the line, and it is the only break
        XCTAssertEqual(cues[1].lines, ["Deuxieme ligne", "sur deux"])
    }

    func testDecodesSubRipThroughTheSameParser() throws {
        let cues = try decodeCues(try fixture("subs-srt.mkv"), kind: "subrip")
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].start, 1.5, accuracy: 0.001)
        XCTAssertEqual(cues[0].end, 2.5, accuracy: 0.001)
        // the decoder turns <i> into an ASS override block on the way out, and
        // the parser takes it back off
        XCTAssertEqual(cues[0].lines, ["Hello there"])
    }

    func testFlushingKeepsTheDecoderUsable() throws {
        let url = try fixture("subs-flush.mkv")
        let demuxer = try Demuxer(url: url)
        let stream = try XCTUnwrap(demuxer.streams.first { $0.codecName == "ass" })
        let decoder = try SubtitleDecoder(stream: stream)
        var first: SubtitleCue?
        while let packet = try demuxer.readPacket(), first == nil {
            guard packet.streamIndex == stream.index else { continue }
            first = try decoder.decode(packet)
        }
        XCTAssertNotNil(first)

        decoder.flush()
        try demuxer.seek(to: 3.0)
        var second: SubtitleCue?
        while let packet = try demuxer.readPacket(), second == nil {
            guard packet.streamIndex == stream.index else { continue }
            second = try decoder.decode(packet)
        }
        XCTAssertEqual(try XCTUnwrap(second).lines, ["Deuxieme ligne", "sur deux"])
    }

    /// An .mkv carrying one ASS track and nothing else, one event to a second.
    /// What an event's text parses to is all these tests read.
    private func assFixture(_ name: String, events: [String]) throws -> URL {
        let frames = events.enumerated().map { index, event in
            MatroskaFrame(
                track: 1, milliseconds: 1000 * (index + 1), durationMilliseconds: 800,
                isKeyframe: true, data: Data("\(index),0,Default,,0,0,0,,\(event)".utf8)
            )
        }
        return try makeMatroskaFixture(
            directory: FileManager.default.temporaryDirectory,
            name: name,
            tracks: [MatroskaTrack(
                number: 1, kind: .subtitle, codecID: "S_TEXT/ASS",
                codecPrivate: Data(assFixtureHeader.utf8)
            )],
            frames: frames,
            durationMilliseconds: 4000,
            cueTrack: 1
        )
    }

    func testADrawingShowsNothingRatherThanItsCoordinates() throws {
        let url = try assFixture("subs-drawing.mkv", events: [#"{\p1}m 0 0 l 10 0 10 10{\p0}"#])
        let cues = try decodeCues(url, kind: "ass")
        XCTAssertEqual(cues.count, 1)
        // a drawing is out of scope, and out of scope means not drawn at all
        XCTAssertEqual(cues[0].lines, [])
        XCTAssertTrue(cues[0].isEmpty)
    }

    func testTextAroundADrawingSurvivesIt() throws {
        let url = try assFixture("subs-drawing-mixed.mkv", events: [
            #"Avant {\p1}m 0 0 l 5 5{\p0}apres"#,
            // \pos opens no drawing, whatever it starts with
            #"{\pos(10,20)}Place"#,
        ])
        let cues = try decodeCues(url, kind: "ass")
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].lines, ["Avant apres"])
        XCTAssertEqual(cues[1].lines, ["Place"])
    }

    func testDecodesAPGSDisplaySetToABitmap() throws {
        let cues = try decodeCues(try fixture("subs-pgs.mkv"), kind: "hdmv_pgs_subtitle")
        XCTAssertEqual(cues.count, 1)
        let cue = try XCTUnwrap(cues.first)
        XCTAssertEqual(cue.start, 2.0, accuracy: 0.001)
        // PGS itself never says when a subtitle ends; the container's block
        // duration is the only thing that does
        XCTAssertEqual(cue.end, 3.5, accuracy: 0.001)
        XCTAssertTrue(cue.lines.isEmpty)
        // the composition segment's video size, which the stream carries
        XCTAssertEqual(cue.canvasWidth, 1920)
        XCTAssertEqual(cue.canvasHeight, 1080)

        let image = try XCTUnwrap(cue.images.first)
        XCTAssertEqual(cue.images.count, 1)
        XCTAssertEqual(image.x, 100)
        XCTAssertEqual(image.y, 900)
        XCTAssertEqual(image.width, 96)
        XCTAssertEqual(image.height, 32)
        XCTAssertEqual(image.pixels.count, 96 * 32 * 4)
        // the fixture's one palette entry is opaque white, and it covers the
        // whole rectangle
        XCTAssertTrue(image.pixels.allSatisfy { $0 == 0xFF })

        let drawn = try XCTUnwrap(image.makeImage())
        XCTAssertEqual(drawn.width, 96)
        XCTAssertEqual(drawn.height, 32)
    }

    func testVobSubPaletteComesFromTheIdx() throws {
        // 16 entries, all black except index 9, which is what SET_COLOR maps
        // this rectangle's one pixel value onto: a decoder falling back to
        // any built-in default rather than genuinely reading this text would
        // draw black, not red.
        var palette = [UInt32](repeating: 0x000000, count: 16)
        palette[9] = 0xFF0000
        let idx = makeVobSubIdxExtradata(canvasWidth: 720, canvasHeight: 480, palette: palette)
        let url = try makeMatroskaFixture(
            directory: FileManager.default.temporaryDirectory,
            name: "subs-vobsub.mkv",
            tracks: [MatroskaTrack(number: 1, kind: .subtitle, codecID: "S_VOBSUB", codecPrivate: idx)],
            frames: [MatroskaFrame(
                track: 1, milliseconds: 1000, durationMilliseconds: 500, isKeyframe: true,
                data: makeVobSubPacket(x: 10, y: 20, width: 8, height: 2, paletteIndex: 9)
            )],
            durationMilliseconds: 4000,
            cueTrack: 1
        )
        let cues = try decodeCues(url, kind: "dvd_subtitle")
        XCTAssertEqual(cues.count, 1)
        let image = try XCTUnwrap(cues.first?.images.first)
        XCTAssertEqual(image.x, 10)
        XCTAssertEqual(image.y, 20)
        XCTAssertEqual(image.width, 8)
        XCTAssertEqual(image.height, 2)
        // opaque red, native-order ARGB in memory as blue, green, red, alpha -
        // the same layout the PGS palette test already proves
        let pixel: [UInt8] = [0x00, 0x00, 0xFF, 0xFF]
        XCTAssertEqual(image.pixels.count, 8 * 2 * 4)
        XCTAssertTrue(
            stride(from: 0, to: image.pixels.count, by: 4)
                .allSatisfy { Array(image.pixels[$0..<$0 + 4]) == pixel }
        )
    }

    /// An .mkv carrying one PGS track and nothing else: one display set of one
    /// colour, 96x32 at 100,900, from 2.0 to 3.5 s.
    private func pgsFixture(
        _ name: String, color: (luma: UInt8, cr: UInt8, cb: UInt8, alpha: UInt8)
    ) throws -> URL {
        try makeMatroskaFixture(
            directory: FileManager.default.temporaryDirectory,
            name: name,
            tracks: [MatroskaTrack(number: 1, kind: .subtitle, codecID: "S_HDMV/PGS")],
            frames: [MatroskaFrame(
                track: 1, milliseconds: 2000, durationMilliseconds: 1500, isKeyframe: true,
                data: makePGSDisplaySet(
                    x: 100, y: 900, width: 96, height: 32, colorIndex: 1, color: color
                )
            )],
            durationMilliseconds: 4000,
            cueTrack: 1
        )
    }

    func testADimmedWhiteStaysGreyRatherThanBlack() throws {
        // opaque white, drawn at the HDR white an HDR film gets
        let image = SubtitleImage(
            x: 0, y: 0, width: 1, height: 1, pixels: Data([0xFF, 0xFF, 0xFF, 0xFF])
        )
        let drawn = try XCTUnwrap(image.makeImage(white: SubtitleOverlay.hdrWhite))
        var readback = [UInt8](repeating: 0, count: 4)
        readback.withUnsafeMutableBytes { raw in
            let context = CGContext(
                data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            )
            context?.draw(drawn, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        XCTAssertEqual(readback, [0xBF, 0xBF, 0xBF, 0xFF])
    }

    func testAPGSTrackSilentThroughTheProbeStillGetsItsCanvas() throws {
        // A forced track's first display set lands minutes in, long after the
        // probe gave up: the stream opens with no size, and a filler track
        // carries the probe past its byte budget before the PGS block arrives.
        let filler = Data(repeating: 0x61, count: 20_000)
        var frames = stride(from: 0, to: 30_000, by: 100).map {
            MatroskaFrame(track: 1, milliseconds: $0, durationMilliseconds: 100, isKeyframe: true, data: filler)
        }
        frames.append(MatroskaFrame(
            track: 2, milliseconds: 30_000, durationMilliseconds: 1500, isKeyframe: true,
            data: makePGSDisplaySet(x: 100, y: 900, width: 96, height: 32, colorIndex: 1)
        ))
        let url = try makeMatroskaFixture(
            directory: FileManager.default.temporaryDirectory,
            name: "subs-pgs-late.mkv",
            tracks: [
                MatroskaTrack(number: 1, kind: .subtitle, codecID: "S_TEXT/UTF8"),
                MatroskaTrack(number: 2, kind: .subtitle, codecID: "S_HDMV/PGS", isForced: true),
            ],
            frames: frames,
            durationMilliseconds: 31_500,
            cueTrack: 1
        )
        let demuxer = try Demuxer(url: url)
        let stream = try XCTUnwrap(demuxer.streams.first { $0.codecName == "hdmv_pgs_subtitle" })
        XCTAssertEqual(stream.width, 0, "the probe reached the display set; the fixture tests nothing")

        let cues = try decodeCues(url, kind: "hdmv_pgs_subtitle")
        let cue = try XCTUnwrap(cues.first)
        XCTAssertEqual(cue.images.count, 1)
        XCTAssertEqual(cue.canvasWidth, 1920)
        XCTAssertEqual(cue.canvasHeight, 1080)
    }

    func testAPartlyTransparentColourKeepsItsChannelsAndItsPremultiply() throws {
        // red at half alpha: asymmetric and unsaturated, so a swapped channel or
        // a dropped premultiply shows up where opaque white hides both
        let url = try pgsFixture(
            "subs-pgs-red.mkv", color: (luma: 81, cr: 240, cb: 90, alpha: 128)
        )
        let cues = try decodeCues(url, kind: "hdmv_pgs_subtitle")
        let image = try XCTUnwrap(cues.first?.images.first)
        // the entry decodes to r=255 g=24 b=0, half alpha halves each of them,
        // and native-order ARGB puts them in memory as blue, green, red, alpha
        let pixel: [UInt8] = [0x00, 0x0C, 0x80, 0x80]
        XCTAssertEqual(image.pixels.count, 96 * 32 * 4)
        XCTAssertTrue(stride(from: 0, to: image.pixels.count, by: 4).allSatisfy {
            Array(image.pixels[$0..<$0 + 4]) == pixel
        })

        // and the layout makeImage declares is that same one: drawn 1:1 into an
        // RGBA context, the channels land where they were meant to
        let drawn = try XCTUnwrap(image.makeImage())
        var readback = [UInt8](repeating: 0, count: 96 * 32 * 4)
        readback.withUnsafeMutableBytes { raw in
            let context = CGContext(
                data: raw.baseAddress, width: 96, height: 32, bitsPerComponent: 8,
                bytesPerRow: 96 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            )
            context?.draw(drawn, in: CGRect(x: 0, y: 0, width: 96, height: 32))
        }
        XCTAssertEqual(Array(readback.prefix(4)), [0x80, 0x0C, 0x00, 0x80])
    }

    func testGraphicStreamsAreToldFromTextOnes() throws {
        let demuxer = try Demuxer(url: try fixture("subs-kinds.mkv"))
        let graphic = demuxer.streams
            .filter { $0.kind == .subtitle }
            .map { SubtitleDecoder.isGraphic(codecID: $0.codecID) }
        XCTAssertEqual(graphic, [false, false, true])
        // and nothing else is ever graphic
        let audio = try XCTUnwrap(demuxer.streams.first { $0.kind == .audio })
        XCTAssertFalse(SubtitleDecoder.isGraphic(codecID: audio.codecID))
    }

    func testStyledTracksAreToldFromTheRest() throws {
        let demuxer = try Demuxer(url: try fixture("subs-styled-kinds.mkv"))
        let styled = demuxer.streams
            .filter { $0.kind == .subtitle }
            .map { SubtitleDecoder.isStyled(codecID: $0.codecID) }
        // ass, subrip, hdmv_pgs_subtitle: only the first goes to libass
        XCTAssertEqual(styled, [true, false, false])
        let audio = try XCTUnwrap(demuxer.streams.first { $0.kind == .audio })
        XCTAssertFalse(SubtitleDecoder.isStyled(codecID: audio.codecID))
    }

    func testAStreamWithNoDecoderIsRefused() {
        let stream = MediaStream(
            index: 0, kind: .subtitle, codecID: 0, codecName: "none",
            width: 0, height: 0, timeBaseNum: 1, timeBaseDen: 1000,
            sampleRate: 0, channels: 0, videoDelay: 0, language: "", title: "",
            isDefault: false, isForced: false,
            colorPrimaries: 2, colorTransfer: 2, colorMatrix: 2, isFullRange: false,
            masteringDisplay: nil, contentLight: nil, dolbyVision: nil, extradata: nil
        )
        XCTAssertThrowsError(try SubtitleDecoder(stream: stream)) { error in
            XCTAssertEqual(error as? SubtitleDecodeError, .decoderUnavailable("none"))
        }
    }
}

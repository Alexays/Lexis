import CLibass
import CoreGraphics
import LexisTestSupport
import XCTest
@testable import LexisPlayer

final class AssRendererTests: XCTestCase {
    /// The process's one libass queue, the same one the sink renders on: a
    /// second queue here would overlap the sink's tests inside this process.
    private let queue = AssRenderer.sharedQueue

    /// Everything libass owns lives on one queue, so every test body does too.
    private func onQueue<T>(_ body: () throws -> T) rethrows -> T {
        try queue.sync(execute: body)
    }

    private func makeRenderer(fonts: [Data] = []) throws -> AssRenderer {
        try onQueue {
            try AssRenderer(
                header: Data(assStyledFixtureHeader.utf8), fonts: fonts,
                canvasWidth: 1920, canvasHeight: 1080
            )
        }
    }

    func testRendersAStyledEventIntoOnePremultipliedBitmap() throws {
        let renderer = try makeRenderer()
        // The canvas is the video, as it is for a PGS rect, and the script's
        // own PlayRes is 1280x720: libass is what scales one into the other.
        XCTAssertEqual(renderer.canvas, CGSize(width: 1920, height: 1080))
        onQueue {
            renderer.process(
                event: Data(#"0,0,Default,,0,0,0,,{\i1}Bonjour{\i0} la nuit"#.utf8),
                start: 1.0, duration: 2.0
            )
        }
        let image = try XCTUnwrap(onQueue { renderer.render(at: 1.5) })
        // a bottom-aligned Default style: near the bottom, near the middle
        XCTAssertGreaterThan(image.y, 900)
        XCTAssertLessThan(image.y + image.height, 1080)
        XCTAssertGreaterThan(image.x, 500)
        XCTAssertLessThan(image.x + image.width, 1420)
        XCTAssertEqual(image.pixels.count, image.width * image.height * 4)
        // premultiplied: no channel may exceed the alpha it is multiplied by
        for index in stride(from: 0, to: image.pixels.count, by: 4) {
            let alpha = image.pixels[index + 3]
            XCTAssertLessThanOrEqual(image.pixels[index], alpha)
            XCTAssertLessThanOrEqual(image.pixels[index + 1], alpha)
            XCTAssertLessThanOrEqual(image.pixels[index + 2], alpha)
        }
        XCTAssertNotNil(image.makeImage())
        // white glyphs over a black outline: something in there is opaque white
        XCTAssertTrue(image.pixels.contains(255))
    }

    func testBlendsTheGlyphsAtTheWhiteItIsGiven() throws {
        let renderer = try makeRenderer()
        onQueue {
            renderer.process(
                event: Data(#"0,0,Default,,0,0,0,,Bonjour"#.utf8), start: 1.0, duration: 2.0
            )
        }
        let full = try XCTUnwrap(onQueue { renderer.render(at: 1.5) })
        XCTAssertTrue(full.pixels.contains(255))
        let before = renderer.generation
        let dimmed = try XCTUnwrap(onQueue { () -> SubtitleImage? in
            renderer.setWhite(SubtitleOverlay.hdrWhite)
            return renderer.render(at: 1.5)
        })
        // a white that changes is a new bitmap, even with nothing else moving
        XCTAssertGreaterThan(renderer.generation, before)
        var opaque = false
        var brightest: UInt8 = 0
        for index in stride(from: 0, to: dimmed.pixels.count, by: 4) {
            if dimmed.pixels[index + 3] == 255 { opaque = true }
            brightest = max(brightest, dimmed.pixels[index], dimmed.pixels[index + 1], dimmed.pixels[index + 2])
        }
        XCTAssertEqual(Double(brightest), 255 * SubtitleOverlay.hdrWhite, accuracy: 1.5)
        XCTAssertTrue(opaque, "the alpha must not be scaled with the colour")
    }

    func testHonoursPositionAndColour() throws {
        let renderer = try makeRenderer()
        onQueue {
            renderer.process(
                event: Data(#"0,0,Sign,,0,0,0,,{\pos(300,200)\c&H00FF00&}Panneau"#.utf8),
                start: 1.0, duration: 2.0
            )
        }
        let image = try XCTUnwrap(onQueue { renderer.render(at: 1.5) })
        // \pos is in the script's PlayRes of 1280x720; the canvas is 1920x1080,
        // so libass scales by 1.5. The Sign style is \an5, so \pos names the
        // centre of the text, which is what the rect's own centre must land on.
        XCTAssertEqual(Double(image.x) + Double(image.width) / 2, 450, accuracy: 40)
        XCTAssertEqual(Double(image.y) + Double(image.height) / 2, 300, accuracy: 40)
        // \c&H00FF00& is BGR, so this is green, and premultiplied green over a
        // red outline means some pixel is opaque green
        var foundGreen = false
        for index in stride(from: 0, to: image.pixels.count, by: 4)
        where image.pixels[index + 3] == 255 {
            let blue = image.pixels[index], green = image.pixels[index + 1]
            let red = image.pixels[index + 2]
            if green == 255, red == 0, blue == 0 { foundGreen = true; break }
        }
        XCTAssertTrue(foundGreen, "no opaque green pixel: the colour was lost")
    }

    func testNothingIsRenderedOutsideAnEventAndTwoLinesStack() throws {
        let renderer = try makeRenderer()
        onQueue {
            renderer.process(
                event: Data(#"0,0,Default,,0,0,0,,Une seule ligne"#.utf8),
                start: 1.0, duration: 1.0
            )
            renderer.process(
                event: Data(#"1,0,Default,,0,0,0,,Deuxieme ligne\Nsur deux"#.utf8),
                start: 3.2, duration: 0.8
            )
        }
        XCTAssertNil(onQueue { renderer.render(at: 0.5) })
        XCTAssertNil(onQueue { renderer.render(at: 2.5) })
        let one = try XCTUnwrap(onQueue { renderer.render(at: 1.5) })
        let two = try XCTUnwrap(onQueue { renderer.render(at: 3.5) })
        // two lines are taller and start higher up than one
        XCTAssertGreaterThan(two.height, one.height)
        XCTAssertLessThan(two.y, one.y)
        XCTAssertNil(onQueue { renderer.render(at: 4.5) })
    }

    func testADuplicateEventIsDroppedAndAFlushTakesThemAllBack() throws {
        let renderer = try makeRenderer()
        let event = Data(#"0,0,Default,,0,0,0,,Bonjour"#.utf8)
        onQueue {
            renderer.process(event: event, start: 1.0, duration: 2.0)
            // ReadOrder 0 again: this is what a re-read after a seek looks like
            renderer.process(event: event, start: 1.0, duration: 2.0)
        }
        let once = try XCTUnwrap(onQueue { renderer.render(at: 1.5) })
        // an event drawn twice would be no wider, but it would be drawn twice:
        // the proof it was dropped is that the track holds one of it
        XCTAssertEqual(onQueue { renderer.eventCount }, 1)
        XCTAssertGreaterThan(once.width, 0)

        onQueue { renderer.flush() }
        XCTAssertEqual(onQueue { renderer.eventCount }, 0)
        XCTAssertNil(onQueue { renderer.render(at: 1.5) })
        // and the same event is accepted again, which is what a seek needs
        onQueue { renderer.process(event: event, start: 1.0, duration: 2.0) }
        XCTAssertNotNil(onQueue { renderer.render(at: 1.5) })
    }

    func testGenerationRisesOnlyWhenTheBitmapChanges() throws {
        let renderer = try makeRenderer()
        let event = Data(#"0,0,Default,,0,0,0,,Bonjour"#.utf8)
        // the probe frame init draws is taken back, so nothing was published
        XCTAssertEqual(onQueue { renderer.generation }, 0)
        XCTAssertNil(onQueue { renderer.render(at: 0.5) })
        XCTAssertEqual(onQueue { renderer.generation }, 0)

        onQueue { renderer.process(event: event, start: 1.0, duration: 2.0) }
        XCTAssertNotNil(onQueue { renderer.render(at: 1.5) })
        let drawn = onQueue { renderer.generation }
        XCTAssertGreaterThan(drawn, 0)
        // a subtitle sitting still: the same bitmap, so the same generation
        XCTAssertNotNil(onQueue { renderer.render(at: 1.6) })
        XCTAssertEqual(onQueue { renderer.generation }, drawn)
        // the line ends: the empty screen is a change, the next empty is not
        XCTAssertNil(onQueue { renderer.render(at: 3.5) })
        XCTAssertEqual(onQueue { renderer.generation }, drawn + 1)
        XCTAssertNil(onQueue { renderer.render(at: 3.6) })
        XCTAssertEqual(onQueue { renderer.generation }, drawn + 1)
        XCTAssertNotNil(onQueue { renderer.render(at: 1.5) })
        // a seek: the flush takes that bitmap back and the re-fed event builds
        // one again, which libass calls no change and the cache cannot answer
        onQueue { renderer.flush() }
        XCTAssertEqual(onQueue { renderer.generation }, drawn + 3)
        onQueue { renderer.process(event: event, start: 1.0, duration: 2.0) }
        XCTAssertNotNil(onQueue { renderer.render(at: 1.5) })
        XCTAssertEqual(onQueue { renderer.generation }, drawn + 4)
    }

    func testAnEmbeddedFontIsWhatDrawsAFamilyTheSystemCannotResolve() throws {
        // The script names a family no machine has, so with nothing attached
        // libass falls back to its default and draws the wrong glyphs. The
        // attachment carries that family, and the two bitmaps differing is
        // what proves libass reached it: drop the attachment and they match.
        let family = "LexisEmbeddedProbe"
        let font = try renamedFont(systemFontData(), family: family)
        let header = Data(
            assStyledFixtureHeader.replacingOccurrences(of: "Helvetica", with: family).utf8
        )
        let event = Data(#"0,0,Default,,0,0,0,,Avec une police embarquee"#.utf8)
        func draw(fonts: [Data]) throws -> SubtitleImage {
            try onQueue {
                let renderer = try AssRenderer(
                    header: header, fonts: fonts,
                    canvasWidth: 1920, canvasHeight: 1080
                )
                renderer.process(event: event, start: 1.0, duration: 2.0)
                return try XCTUnwrap(renderer.render(at: 1.5))
            }
        }
        XCTAssertNotEqual(try draw(fonts: [font]).pixels, try draw(fonts: []).pixels)
    }

    func testSomethingThatIsNotAFontIsRefusedRatherThanFatal() throws {
        let notAFont = Data(repeating: 0x42, count: 4096)
        let renderer = try makeRenderer(fonts: [notAFont, try systemFontData()])
        onQueue {
            renderer.process(
                event: Data(#"0,0,Default,,0,0,0,,Toujours dessine"#.utf8),
                start: 1.0, duration: 2.0
            )
        }
        XCTAssertNotNil(onQueue { renderer.render(at: 1.5) })
    }

    /// The same font under a family name no system has. The rebuilt `name`
    /// table goes at the end of the file and the table directory is repointed
    /// at it: FreeType does not verify sfnt checksums, so nothing else moves.
    private func renamedFont(_ font: Data, family: String) throws -> Data {
        var sfnt = [UInt8](font)
        let tag = Array("name".utf8)
        let tableCount = Int(sfnt[4]) << 8 | Int(sfnt[5])
        let entries = stride(from: 12, to: 12 + 16 * tableCount, by: 16)
        let directory = try XCTUnwrap(
            entries.first { sfnt[$0..<($0 + 4)].elementsEqual(tag) },
            "the font has no name table"
        )

        // Format 0: a header, one 12-byte record per name, then the strings.
        // Every record is Windows/Unicode/en-US, which is what FreeType reads.
        let names: [(id: UInt16, value: String)] = [
            (1, family), (2, "Regular"), (4, family), (6, family),
        ]
        var records: [UInt8] = [0, 0, UInt8(names.count >> 8), UInt8(names.count & 0xFF)]
        let storageStart = 6 + 12 * names.count
        records += [UInt8(storageStart >> 8), UInt8(storageStart & 0xFF)]
        var storage: [UInt8] = []
        for name in names {
            let utf16 = Array(name.value.utf16).flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
            for field in [3, 1, 0x0409, Int(name.id), utf16.count, storage.count] {
                records += [UInt8(field >> 8), UInt8(field & 0xFF)]
            }
            storage += utf16
        }
        let table = records + storage

        while sfnt.count % 4 != 0 { sfnt.append(0) }
        let offset = sfnt.count, length = table.count
        sfnt += table
        for byte in 0..<4 {
            sfnt[directory + 4 + byte] = 0
            sfnt[directory + 8 + byte] = UInt8((offset >> ((3 - byte) * 8)) & 0xFF)
            sfnt[directory + 12 + byte] = UInt8((length >> ((3 - byte) * 8)) & 0xFF)
        }
        return Data(sfnt)
    }

    func testRendersTheFixturesOwnEvents() throws {
        let url = try makeStyledSubtitleFixture(
            directory: FileManager.default.temporaryDirectory, name: "ass-render.mkv"
        )
        let demuxer = try Demuxer(url: url)
        let subtitle = try XCTUnwrap(demuxer.streams.first { $0.kind == .subtitle })
        XCTAssertEqual(subtitle.codecID, LexisCodecIDASS)
        let attachments = demuxer.streams.filter { $0.kind == .other }.compactMap(\.extradata)
        XCTAssertEqual(attachments.count, 1)
        let renderer = try onQueue {
            try AssRenderer(
                header: try XCTUnwrap(subtitle.extradata), fonts: attachments,
                canvasWidth: 1920, canvasHeight: 1080
            )
        }
        let base = Double(subtitle.timeBaseNum) / Double(subtitle.timeBaseDen)
        while let packet = try demuxer.readPacket() {
            guard packet.streamIndex == subtitle.index, let pts = packet.pts else { continue }
            onQueue {
                renderer.process(
                    event: packet.copiedBytes, start: Double(pts) * base,
                    duration: Double(packet.duration) * base
                )
            }
        }
        XCTAssertEqual(onQueue { renderer.eventCount }, 3)
        // 1.2 s: only the Default line. 2.0 s: the sign as well, so the union
        // reaches much further up the picture.
        let alone = try XCTUnwrap(onQueue { renderer.render(at: 1.2) })
        let both = try XCTUnwrap(onQueue { renderer.render(at: 2.0) })
        XCTAssertLessThan(both.y, alone.y)
        XCTAssertGreaterThan(both.height, alone.height)
        XCTAssertNil(onQueue { renderer.render(at: 0.5) })
    }
}

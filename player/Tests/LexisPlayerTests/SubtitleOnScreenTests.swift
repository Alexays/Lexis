import AVFoundation
import CoreGraphics
import LexisTestSupport
import XCTest
@testable import LexisPlayer

/// The one thing the rest of the subtitle tests never ask: whether anything a
/// viewer could see actually lands in the layer tree the sink hangs off the
/// display layer. Every other assertion in this suite reads a decision -
/// `shownSubtitle`, `shownStyledSubtitle`, a bitmap a renderer produced - and
/// a cue can satisfy all of them while the screen stays empty.
final class SubtitleOnScreenTests: RealtimeTestCase {
    /// Draws `layer` and everything under it into a bitmap and counts the
    /// pixels that came out other than transparent black. This is the whole
    /// point of the file: it renders the tree the app puts on screen.
    private func drawnPixels(_ layer: CALayer, size: CGSize) throws -> Int {
        let width = Int(size.width)
        let height = Int(size.height)
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ))
        layer.render(in: context)
        let data = try XCTUnwrap(context.data)
        let pixels = data.bindMemory(to: UInt32.self, capacity: width * height)
        var drawn = 0
        for index in 0..<(width * height) where pixels[index] != 0 { drawn += 1 }
        return drawn
    }

    private func waitUntil(
        _ description: String, timeout: TimeInterval = 10, _ condition: () -> Bool
    ) {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        XCTFail("timed out waiting for \(description)")
    }

    private func sizedSink() -> DisplayLayerSink {
        let layer = AVSampleBufferDisplayLayer()
        layer.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        return DisplayLayerSink(layer: layer)
    }

    func testAStyledCueReachesTheScreen() throws {
        let url = try makeStyledSubtitleFixture(
            directory: FileManager.default.temporaryDirectory, name: "on-screen-styled.mkv"
        )
        let sink = sizedSink()
        let player = LexisPlayer(sink: sink)
        try player.open(url: url)
        defer { player.close() }
        let track = try XCTUnwrap(
            player.tracks.subtitle.first { SubtitleDecoder.isStyled(codecID: $0.codecID) }
        )
        player.selectSubtitleTrack(index: track.index)
        player.play()
        waitUntil("libass to publish a cue") { sink.shownStyledSubtitle != nil }
        // the publish hops to the main queue, and so does the layer write
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))

        let drawn = try drawnPixels(sink.layer, size: sink.layer.bounds.size)
        XCTAssertGreaterThan(drawn, 0, "libass drew a cue and nothing reached the layer tree")
    }

    func testATrackTurnedOnDuringPlaybackReachesTheScreen() throws {
        let url = try makeStyledSubtitleFixture(
            directory: FileManager.default.temporaryDirectory, name: "on-screen-late.mkv"
        )
        let sink = sizedSink()
        let player = LexisPlayer(sink: sink)
        try player.open(url: url)
        defer { player.close() }
        let track = try XCTUnwrap(
            player.tracks.subtitle.first { SubtitleDecoder.isStyled(codecID: $0.codecID) }
        )
        player.play()
        waitUntil("the clock to reach the cue at 1.0 s") { sink.presentationTime > 1.2 }
        player.selectSubtitleTrack(index: track.index)
        waitUntil("libass to publish a cue") { sink.shownStyledSubtitle != nil }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))

        let drawn = try drawnPixels(sink.layer, size: sink.layer.bounds.size)
        XCTAssertGreaterThan(drawn, 0, "the cue that is live now never reached the layer tree")
    }

    func testATextCueReachesTheScreen() throws {
        let url = try makeSubtitleFixture(
            directory: FileManager.default.temporaryDirectory, name: "on-screen-text.mkv"
        )
        let sink = sizedSink()
        let player = LexisPlayer(sink: sink)
        try player.open(url: url)
        defer { player.close() }
        let track = try XCTUnwrap(
            player.tracks.subtitle.first { $0.codecName == "subrip" }
        )
        player.selectSubtitleTrack(index: track.index)
        player.play()
        waitUntil("the text path to publish a cue") { sink.shownSubtitle != nil }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))

        let drawn = try drawnPixels(sink.layer, size: sink.layer.bounds.size)
        XCTAssertGreaterThan(drawn, 0, "a cue was shown and nothing reached the layer tree")
    }

    func testATextTrackTurnedOnDuringPlaybackReachesTheScreen() throws {
        let url = try makeSubtitleFixture(
            directory: FileManager.default.temporaryDirectory, name: "on-screen-text-late.mkv"
        )
        let sink = sizedSink()
        let player = LexisPlayer(sink: sink)
        try player.open(url: url)
        defer { player.close() }
        // 1.5 to 2.5 s, so the clock below is inside it rather than before it
        let track = try XCTUnwrap(player.tracks.subtitle.first { $0.codecName == "subrip" })
        player.play()
        waitUntil("the clock to reach the cue at 1.5 s") { sink.presentationTime > 1.7 }
        player.selectSubtitleTrack(index: track.index)
        waitUntil("the text path to publish a cue") { sink.shownSubtitle != nil }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))

        let drawn = try drawnPixels(sink.layer, size: sink.layer.bounds.size)
        XCTAssertGreaterThan(drawn, 0, "the cue that is live now never reached the layer tree")
    }
}

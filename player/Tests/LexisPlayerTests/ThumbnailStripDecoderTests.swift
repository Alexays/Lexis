import CoreGraphics
import LexisCoreStream
import LexisTestSupport
import XCTest
@testable import LexisPlayer

final class ThumbnailStripDecoderTests: XCTestCase {
    /// 12 s of noise, a keyframe on every whole second (4 fps, gopSize 4 -
    /// 48 frames): two seconds past the last thumbnail any test here ever
    /// asks for (9), so a seek at the last requested second still has real
    /// content beyond it rather than landing flush against the fixture's
    /// own end - the margin the last-two-flakes pass on the playing
    /// pipeline's own packet queue paid for in a repeated-seek fixture that
    /// had none. Noise, not a solid fill, because the color a solid fill
    /// cycles through repeats every 5 frames at this fixture's own math
    /// (memset value mod 200 has period 5), which would collide two
    /// "distinct" keyframes into the same picture; noise never repeats.
    /// 640x480, taller than the strip's own 240 px and 4:3: a thumbnail's
    /// width proves VideoToolbox actually scaled the picture down (to 320,
    /// following the source's own aspect ratio) rather than happening to
    /// already match the requested height by coincidence.
    private func stripFixture(name: String) throws -> URL {
        try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: name,
            codec: .h264, width: 640, height: 480, frameCount: 48, fps: 4,
            noisy: true, gopSize: 4
        )
    }

    private func openStripDecoder(_ url: URL) throws -> ThumbnailStripDecoder {
        let handle = try XCTUnwrap(lexis_stream_open_file(url.path, nil))
        return try ThumbnailStripDecoder(stream: coreStream(handle: handle), analysis: nil)
    }

    /// The same one-keyframe-a-second shape, 16:9 and filled with a flat grey
    /// that changes every frame rather than with noise. 1280x720 is the shape
    /// a real film has, and the one that scales to an odd 427 px wide.
    private func flatFixture(name: String) throws -> URL {
        try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: name,
            codec: .h264, width: 1280, height: 720, frameCount: 48, fps: 4,
            noisy: false, gopSize: 4
        )
    }

    private func pixelData(_ image: CGImage) -> Data {
        (image.dataProvider?.data as Data?) ?? Data()
    }

    /// What a thumbnail is actually made of: the mean of each channel, how far
    /// any one pixel's channels spread apart, and how far the picture varies
    /// from its own mean.
    ///
    /// The last two columns are left out. A 16:9 source scales to an odd 427
    /// px wide and those two columns come back dark whatever the picture is -
    /// an artifact of the odd width that predates every commit here, measured
    /// identical at `7cc1e01` and at HEAD.
    private func statistics(
        _ image: CGImage
    ) -> (mean: Double, channelSpread: Double, deviation: Double) {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var total = 0.0
        var channelSpread = 0.0
        var counted = 0
        for y in 0..<height {
            for x in 0..<(width - 2) {
                let index = (y * width + x) * 4
                let r = Double(pixels[index])
                let g = Double(pixels[index + 1])
                let b = Double(pixels[index + 2])
                total += (r + g + b) / 3
                channelSpread = max(channelSpread, max(r, max(g, b)) - min(r, min(g, b)))
                counted += 1
            }
        }
        let mean = total / Double(counted)
        var squares = 0.0
        for y in 0..<height {
            for x in 0..<(width - 2) {
                let index = (y * width + x) * 4
                let level = (Double(pixels[index]) + Double(pixels[index + 1])
                    + Double(pixels[index + 2])) / 3
                squares += (level - mean) * (level - mean)
            }
        }
        return (mean, channelSpread, (squares / Double(counted)).squareRoot())
    }

    func testStripDecodesTenDistinctThumbnailsFromAOneSecondGOPFixture() throws {
        let decoder = try openStripDecoder(try stripFixture(name: "strip-distinct.mp4"))

        let seconds = (0..<10).map(Double.init)
        let done = expectation(description: "strip decoded")
        var images: [Double: CGImage] = [:]
        decoder.strip(at: seconds) { result in
            images = result
            done.fulfill()
        }
        wait(for: [done], timeout: 15)

        XCTAssertEqual(Set(images.keys), Set(seconds))
        for image in images.values {
            XCTAssertEqual(image.height, 240)
            // 640x480 scaled to 240 tall, the source's own 4:3 preserved
            XCTAssertEqual(image.width, 320)
        }
        // every second's own picture differs from its neighbour: proof each
        // one seeked and decoded its own keyframe, not a stale buffer handed
        // back ten times over
        for second in 0..<9 {
            let here = try XCTUnwrap(images[Double(second)])
            let next = try XCTUnwrap(images[Double(second + 1)])
            XCTAssertNotEqual(pixelData(here), pixelData(next))
        }
    }

    /// A thumbnail carries the picture it decoded, not merely bytes that
    /// differ from the last one's.
    ///
    /// The test above asks only that neighbouring thumbnails differ, which
    /// stripes and a green cast satisfy as readily as a scene does: it passed
    /// unchanged through every shape of corruption this path can produce. So
    /// this one reads the pixels instead. The fixture's keyframes are flat
    /// grey, one level per second, which pins all three at once - a stride
    /// mismatch smears the flat field into bands, a YUV buffer read as RGB
    /// pulls the channels apart, and either would have to survive both to
    /// still land its own frame's level in the right order.
    func testEachThumbnailCarriesItsOwnKeyframesPicture() throws {
        let decoder = try openStripDecoder(try flatFixture(name: "strip-flat.mp4"))

        // One cycle of the fixture's own fill: 20 + (frame * 40) % 200 over a
        // keyframe every 4 frames repeats every 5 seconds, so five seconds is
        // every level it has, each one distinct.
        let seconds = (0..<5).map(Double.init)
        let done = expectation(description: "strip decoded")
        var images: [Double: CGImage] = [:]
        decoder.strip(at: seconds) { result in
            images = result
            done.fulfill()
        }
        wait(for: [done], timeout: 15)

        XCTAssertEqual(Set(images.keys), Set(seconds))
        var measured: [Double: Double] = [:]
        for second in seconds {
            let image = try XCTUnwrap(images[second])
            XCTAssertEqual(image.height, 240)
            // 1280x720 scaled to 240 tall, the source's own 16:9 preserved
            XCTAssertEqual(image.width, 427)
            let (mean, channelSpread, deviation) = statistics(image)
            // a flat grey frame stays grey: the channels of any one pixel
            // cannot part company, which is what a YUV buffer read as RGB or a
            // half-plane offset does first
            XCTAssertLessThanOrEqual(
                channelSpread, 12, "second \(second) has a colour cast, spread \(channelSpread)")
            // and it stays flat: a row stride read wrong turns one level into
            // bands, and bands are what this refuses
            XCTAssertLessThanOrEqual(
                deviation, 6, "second \(second) is not a flat field, deviation \(deviation)")
            measured[second] = mean
        }

        // Each second's own level, in the order the fixture wrote them. The
        // ranking rather than the value: the encode is studio range and the
        // decode expands it, so the levels come back shifted, but nothing on
        // this path may reorder them. A thumbnail showing the wrong keyframe -
        // a stale buffer, a seek that missed - lands out of order here.
        let expected = seconds.sorted { fillLevel(at: $0) < fillLevel(at: $1) }
        let actual = seconds.sorted { measured[$0, default: 0] < measured[$1, default: 0] }
        XCTAssertEqual(
            actual, expected, "thumbnail levels \(measured) do not follow the fixture's own fills")
    }

    /// What `makeVideoFixture` filled the keyframe at `second` with, by its
    /// own arithmetic: a keyframe every 4 frames at 4 fps.
    private func fillLevel(at second: Double) -> Int {
        20 + (Int(second) * 4 * 40) % 200
    }

    func testCancelStopsMidStrip() throws {
        let decoder = try openStripDecoder(try stripFixture(name: "strip-cancel.mp4"))

        // Far more targets than the fixture has distinct seconds, each one
        // real work (a seek, a read, a VideoToolbox decode, a CoreImage
        // render): cancel() runs on the very next line, nothing awaited in
        // between, so it reliably wins the race against 600 real decodes
        // rather than racing a handful of near-instant ones.
        let seconds = (0..<600).map { Double($0 % 10) + Double($0 % 7) / 100 }
        let done = expectation(description: "strip completion after cancel")
        var images: [Double: CGImage] = [:]
        decoder.strip(at: seconds) { result in
            images = result
            done.fulfill()
        }
        decoder.cancel()
        wait(for: [done], timeout: 15)

        XCTAssertLessThan(images.count, seconds.count)
    }

    /// The proof that matters for the plan's own gate rule: a strip decodes
    /// on its own session, over its own stream, while a real `LexisPlayer`
    /// is open and playing - never refused (which touching
    /// `PlaybackActivityGate` the way the bench's decode-only probe does
    /// would cause, since the gate refuses a probe outright while a film
    /// plays) and never at that playing engine's own expense.
    func testAConcurrentlyPlayingEngineOwnStatsAreUnaffectedByAStripDecode() throws {
        try skipUnlessRealtimeTests()
        let sink = CountingSink()
        // A consumer real enough to cost real wall time without ever
        // refusing a sample (CountingSink's own doc comment): without this,
        // nothing paces this short a fixture to content time at all, and it
        // would finish playing before the strip decode below ever overlaps
        // it. 288 frames at 20ms each is a little under 6s of real playing
        // time - comfortably longer than the sleeps and the strip decode
        // this test runs inside it.
        sink.setEnqueueDelay(0.02)
        let player = LexisPlayer(sink: sink)
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "strip-concurrent.mp4",
            codec: .h264, width: 320, height: 240, frameCount: 288, fps: 24, gopSize: 24
        )
        try player.open(url: url)
        player.play()
        usleep(600_000)
        let before = player.stats

        let decoder = try openStripDecoder(url)
        let done = expectation(description: "strip decoded alongside a playing engine")
        var images: [Double: CGImage] = [:]
        decoder.strip(at: [1, 3, 5, 7, 9]) { result in
            images = result
            done.fulfill()
        }
        wait(for: [done], timeout: 15)
        usleep(600_000)

        let after = player.stats
        player.stop()
        player.close()

        XCTAssertEqual(images.count, 5)
        // the playing engine kept moving and dropped nothing while a second,
        // wholly separate session decoded a strip alongside it. packetsRead
        // is not part of this: a 288-frame file this short is read to its
        // own end well inside the first sleep, so it plateaus regardless of
        // what else runs alongside it - position and framesDisplayed are
        // what actually keep moving with the clock.
        XCTAssertGreaterThan(after.position, before.position)
        XCTAssertGreaterThan(after.framesDisplayed, before.framesDisplayed)
        XCTAssertEqual(after.framesDropped, 0)
        XCTAssertEqual(after.rebufferCount, before.rebufferCount)
    }
}

import CoreMedia
import CoreVideo
import LexisTestSupport
import XCTest
@testable import LexisPlayer

extension Upscaler {
    /// The scaler hands its picture back from the pass's own completion; the
    /// tests read pixels out of it, so they wait where playback does not.
    func scaled(_ frame: CVPixelBuffer) throws -> CVPixelBuffer {
        var scaled: CVPixelBuffer?
        let landed = DispatchSemaphore(value: 0)
        try scale(frame) { scaled = $0; landed.signal() }
        landed.wait()
        return scaled!
    }
}

final class UpscalerTests: XCTestCase {
    /// A GPU the scaler refuses keeps the compositor's path, and so do the
    /// tests on such a machine.
    private func makeUpscaler(
        inputWidth: Int, inputHeight: Int, sourceFormat: CMVideoFormatDescription? = nil
    ) throws -> Upscaler {
        do {
            return try Upscaler(
                inputWidth: inputWidth, inputHeight: inputHeight,
                // room for plenty: these tests are about the picture that
                // comes back, not about what the ceiling refuses
                ceilingBytes: 256 * 1024 * 1024, sourceFormat: sourceFormat)
        } catch UpscaleError.unsupportedDevice {
            throw XCTSkip("the upscaler does not take this GPU")
        } catch UpscaleError.noDevice {
            throw XCTSkip("no Metal device")
        }
    }

    /// The luma and the chroma pair of a ten bit 4:2:0 picture, as codes, at
    /// a luma pixel and at the chroma sample over it.
    private func codes(_ buffer: CVPixelBuffer, x: Int, y: Int) -> (y: Int, cb: Int, cr: Int) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt16.self)
        let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt16.self)
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) / 2
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) / 2
        let at = (y / 2) * chromaStride + (x / 2) * 2
        return (Int(luma[y * lumaStride + x] >> 6), Int(chroma[at] >> 6), Int(chroma[at + 1] >> 6))
    }

    /// The network doubles the luma in the filters' place: a checkerboard's
    /// squares keep their codes within the few its ringing moves them, its
    /// colours come through the GPU's chroma as they do, and three pictures
    /// in a row each land whole.
    func testTheNetworkDoublesACheckerboard() throws {
        let upscaler: Upscaler
        do {
            upscaler = try Upscaler(
                inputWidth: 64, inputHeight: 64, ceilingBytes: 256 * 1024 * 1024, starvation: 1.5, neural: true)
        } catch UpscaleError.unsupportedDevice {
            throw XCTSkip("the upscaler does not take this GPU")
        } catch UpscaleError.noDevice {
            throw XCTSkip("no Metal device")
        }
        try XCTSkipUnless(upscaler.isNeural, "no network on this machine")
        let filters = try makeUpscaler(inputWidth: 64, inputHeight: 64)
        for _ in 0..<3 {
            let output = try upscaler.scaled(try makeCheckerboard(width: 64, height: 64))
            let reference = try filters.scaled(try makeCheckerboard(width: 64, height: 64))
            XCTAssertEqual(CVPixelBufferGetWidth(output), 128)
            // the centre of each doubled square, and of the last
            for (x, y) in [(16, 16), (48, 16), (112, 112)] {
                let (got, want) = (codes(output, x: x, y: y), codes(reference, x: x, y: y))
                XCTAssertEqual(got.y, want.y, accuracy: 8, "luma at \(x), \(y)")
                XCTAssertEqual(got.cb, want.cb, accuracy: 2, "cb at \(x), \(y)")
                XCTAssertEqual(got.cr, want.cr, accuracy: 2, "cr at \(x), \(y)")
            }
        }
    }

    /// A checkerboard of 16 pixel squares, each its own colour.
    private func makeCheckerboard(width: Int, height: Int) throws -> CVPixelBuffer {
        try makePicture(
            width: width, height: height,
            luma: { x, y in ((x / 16) + (y / 16)) % 2 == 0 ? 200 : 800 },
            chroma: { x, y in ((x / 8) + (y / 8)) % 2 == 0 ? (400, 600) : (620, 450) })
    }

    /// The decoder's YCbCr comes back doubled, each flat square its own
    /// codes, tagged BT.709 for a file that names nothing but for a small
    /// picture's matrix, 601, and sited left.
    func testACheckerboardComesBackDoubledWithItsColors() throws {
        var untagged: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreate(
            allocator: nil, codecType: kCMVideoCodecType_H264, width: 64, height: 64, extensions: nil,
            formatDescriptionOut: &untagged)
        let upscaler = try makeUpscaler(inputWidth: 64, inputHeight: 64, sourceFormat: untagged)
        let output = try upscaler.scaled(try makeCheckerboard(width: 64, height: 64))

        XCTAssertEqual(CVPixelBufferGetWidth(output), 128)
        XCTAssertEqual(CVPixelBufferGetHeight(output), 128)
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(output), Upscaler.pixelFormat)
        XCTAssertNotNil(CVPixelBufferGetIOSurface(output))
        func tag(_ key: CFString) -> String? { CVBufferCopyAttachment(output, key, nil) as? String }
        XCTAssertEqual(tag(kCVImageBufferTransferFunctionKey), kCVImageBufferTransferFunction_ITU_R_709_2 as String)
        XCTAssertEqual(tag(kCVImageBufferYCbCrMatrixKey), kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String)
        XCTAssertEqual(tag(kCVImageBufferChromaLocationTopFieldKey), kCVImageBufferChromaLocation_Left as String)
        // the centre of each doubled square, far from any edge the scaler
        // reconstructs
        let dark = codes(output, x: 16, y: 16)
        XCTAssertEqual(dark.y, 200, accuracy: 1)
        XCTAssertEqual(dark.cb, 400, accuracy: 1)
        XCTAssertEqual(dark.cr, 600, accuracy: 1)
        let bright = codes(output, x: 48, y: 16)
        XCTAssertEqual(bright.y, 800, accuracy: 1)
        XCTAssertEqual(bright.cb, 620, accuracy: 1)
        XCTAssertEqual(bright.cr, 450, accuracy: 1)
    }

    func testAFrameOfTheWrongShapeIsRefused() throws {
        let upscaler = try makeUpscaler(inputWidth: 64, inputHeight: 64
        )
        let wrong = try makeCheckerboard(width: 32, height: 32)
        XCTAssertThrowsError(try upscaler.scale(wrong) { _ in }) { error in
            XCTAssertEqual(error as? UpscaleError, .unsupportedFormat(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange))
        }
    }
}

/// Skips the caller on a GPU the upscaler refuses, where the upscaled path
/// never exists to test.
func skipUnlessUpscaler() throws {
    do {
        _ = try Upscaler(inputWidth: 64, inputHeight: 64, ceilingBytes: 1024 * 1024)
    } catch UpscaleError.unsupportedDevice {
        throw XCTSkip("the upscaler does not take this GPU")
    }
}

final class UpscaledPathTests: XCTestCase {
    private func smallFixture(named name: String, frameCount: Int = 24) throws -> URL {
        try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: name,
            codec: .h264, width: 320, height: 180, frameCount: frameCount, fps: 24
        )
    }

    func testASmallFilmOpensOnTheUpscaledPathAndTheSwitchTurnsItBack() throws {
        try skipUnlessUpscaler()
        let player = LexisPlayer(
            sink: CountingSink(),
            display: { DisplayCapability(headroom: 1, pixelHeight: 720) },
            policy: testBufferPolicy
        )
        try player.open(url: try smallFixture(named: "upscale-open.mp4"))
        XCTAssertTrue(player.stats.videoUpscaled)
        XCTAssertFalse(player.stats.videoPassthrough)

        player.setUpscalingAllowed(false)
        XCTAssertFalse(player.stats.videoUpscaled)
        XCTAssertTrue(player.stats.videoPassthrough)

        player.setUpscalingAllowed(true)
        XCTAssertTrue(player.stats.videoUpscaled)
        player.close()
    }

    /// The same film on a screen no bigger than it: yesterday's path,
    /// untouched, whatever the switch says.
    func testAScreenNoBiggerThanTheFilmChangesNothing() throws {
        let player = LexisPlayer(
            sink: CountingSink(),
            display: { DisplayCapability(headroom: 1, pixelHeight: 180) },
            policy: testBufferPolicy
        )
        try player.open(url: try smallFixture(named: "upscale-small-screen.mp4"))
        XCTAssertFalse(player.stats.videoUpscaled)
        XCTAssertTrue(player.stats.videoPassthrough)
        player.close()
    }
}

/// The upscaled path under a live engine: the pictures that cross the sink
/// have to be the screen's own size, not the file's.
final class UpscaledPlaybackTests: RealtimeTestCase {
    func testThePicturesCrossTheSinkAtTwiceTheFilmsSize() throws {
        try skipUnlessUpscaler()
        let sink = CountingSink()
        sink.setEnqueueDelay(0.02)
        let player = LexisPlayer(
            sink: sink,
            display: { DisplayCapability(headroom: 1, pixelHeight: 720) },
            policy: testBufferPolicy
        )
        try player.open(
            url: try makeVideoFixture(
                directory: FileManager.default.temporaryDirectory, name: "upscale-live.mp4",
                codec: .h264, width: 320, height: 180, frameCount: 300, fps: 30
            ))
        XCTAssertTrue(player.stats.videoUpscaled)
        player.play()
        pollUntil("an upscaled picture crosses the sink") { sink.pictures > 0 }
        player.stop()
        let size = try XCTUnwrap(sink.lastPictureSize)
        XCTAssertEqual(size.width, 640)
        XCTAssertEqual(size.height, 360)
    }
}

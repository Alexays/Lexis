import CoreVideo
import XCTest
@testable import LexisPlayer

/// A 4K HDR remux on a device with a stated amount of memory left, as the
/// engine would size it: a 63 MB picture, a 24 fps stream, 80 Mbps of video
/// and a lossless 7.1 track.
private func remuxBudget(availableMB: Int, width: Int = 3840, height: Int = 2160)
    -> PipelineBudget
{
    PipelineBudget(
        available: availableMB * 1_048_576,
        pictureBytes: decodedPictureBytes(
            width: width, height: height, pixelFormat: kCVPixelFormatType_64RGBAHalf),
        frameRate: 24,
        videoDelay: 2,
        videoBytesPerSecond: 80_000_000 / 8,
        audioBytesPerSecond: 24_500_000 / 8,
        decodedAudioBytesPerSecond: 48_000 * 8 * 4,
        readAheadSeconds: 8,
        videoTargetSeconds: 1,
        audioTargetSeconds: 2
    )
}

final class MemoryBudgetTests: XCTestCase {
    /// The property the whole budget exists for: the same film on a device
    /// with less to give holds fewer seconds of picture rather than dying,
    /// and on one with more it holds more, with nobody editing anything.
    func testThePictureQueueFollowsWhatTheDeviceHasLeft() {
        let small = remuxBudget(availableMB: 2400)
        let large = remuxBudget(availableMB: 4000)
        XCTAssertNil(small.shortfall)
        XCTAssertNil(large.shortfall)
        XCTAssertGreaterThan(large.videoSampleBytes, small.videoSampleBytes)
        XCTAssertGreaterThan(small.videoSampleBytes, 0)
        // Never more than the second it was asked for: past that the seconds
        // target is the bound that matters and bytes are no longer scarce.
        let oneSecond = 24 * decodedPictureBytes(
            width: 3840, height: 2160, pixelFormat: kCVPixelFormatType_64RGBAHalf)
        XCTAssertLessThanOrEqual(large.videoSampleBytes, oneSecond)
    }

    /// And the same device with a bigger film. A budget that counted pictures
    /// instead of weighing them would hand 8K the same depth it hands 1080p,
    /// which is four times the memory for the same number.
    func testABiggerPictureIsGivenFewerOfThemFromTheSameDevice() {
        let device = 4000
        let hd = remuxBudget(availableMB: device, width: 1920, height: 1080)
        let uhd = remuxBudget(availableMB: device, width: 3840, height: 2160)
        let hdPicture = decodedPictureBytes(
            width: 1920, height: 1080, pixelFormat: kCVPixelFormatType_64RGBAHalf)
        let uhdPicture = decodedPictureBytes(
            width: 3840, height: 2160, pixelFormat: kCVPixelFormatType_64RGBAHalf)
        XCTAssertLessThan(
            uhd.videoSampleBytes / uhdPicture, hd.videoSampleBytes / hdPicture)
    }

    /// The defect this bound exists for, measured on a device: an upscaled 4K
    /// picture costs 31 MiB, a second of them came to 759 MiB, and the pictures
    /// together took 980 MiB of a 1004 MiB allowance - leaving nothing for
    /// everything the budget cannot see, which is what jetsam then took the
    /// process for. The queue stops at a share of the allowance now.
    func testAnExpensivePictureCannotSwallowTheWholeAllowance() {
        let deviceMB = 2400
        let budget = remuxBudget(availableMB: deviceMB)
        let allowance = Int(
            Double(deviceMB * 1_048_576) * PipelineBudget.claimedShareOfAvailable)
        XCTAssertNil(budget.shortfall)
        // The reorder floor may stand above the share - a queue shallower
        // than the window cannot put frames back in order at all - and so may
        // the fewest pictures the queue is given, up to their own cap: the
        // bound proven here is the highest of the three.
        let floor = (2 + 2) * decodedPictureBytes(
            width: 3840, height: 2160, pixelFormat: kCVPixelFormatType_64RGBAHalf)
        XCTAssertLessThanOrEqual(
            budget.videoSampleBytes,
            max(Int(Double(allowance) * PipelineBudget.mostOfAllowanceForFewestPictures), floor))
        XCTAssertLessThan(budget.videoSampleBytes, allowance / 2)
        // And what actually absorbs a network dip is untouched: the bound is
        // on pictures, which absorb decode jitter and nothing else.
        XCTAssertGreaterThan(budget.videoPacketBytes, 0)
    }

    /// A 4K ten bit picture on a device with room for it: the share alone
    /// would hold a quarter second of them, and the queue gets its fewest.
    func testAFourKPictureStillGetsTheFewestPicturesTheQueueIsSizedFor() {
        let picture = decodedPictureBytes(
            width: 3840, height: 2160, pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        let budget = PipelineBudget(
            available: 2400 * 1_048_576, pictureBytes: picture, frameRate: 24,
            videoDelay: 2, videoBytesPerSecond: 80_000_000 / 8,
            audioBytesPerSecond: 24_500_000 / 8, decodedAudioBytesPerSecond: 48_000 * 8 * 4,
            readAheadSeconds: 8, videoTargetSeconds: 1, audioTargetSeconds: 2)
        XCTAssertNil(budget.shortfall)
        XCTAssertGreaterThanOrEqual(
            budget.videoSampleBytes / picture, PipelineBudget.fewestPicturesQueued)
    }

    /// A cheap picture never meets the bound. This is what keeps every path
    /// where a picture costs little exactly as it was: the bound is there for
    /// the pictures that are ruinous, and invisible to the rest.
    func testACheapPictureIsStillGivenTheSecondItAskedFor() {
        let picture = decodedPictureBytes(
            width: 320, height: 240, pixelFormat: kCVPixelFormatType_420YpCbCr8Planar)
        let budget = PipelineBudget(
            available: 2400 * 1_048_576, pictureBytes: picture, frameRate: 24,
            videoDelay: 2, videoBytesPerSecond: 1_000_000 / 8, audioBytesPerSecond: 0,
            decodedAudioBytesPerSecond: 0,
            readAheadSeconds: 8, videoTargetSeconds: 1, audioTargetSeconds: 2)
        XCTAssertEqual(budget.videoSampleBytes, 24 * picture)
    }

    /// What the viewer is told instead of what jetsam would do: a device that
    /// cannot afford the pictures this film cannot hold fewer of says so, with
    /// the two numbers that say it, and the film never opens.
    func testAFilmTooLargeForTheDeviceIsRefusedRatherThanStarted() throws {
        let budget = remuxBudget(availableMB: 400)
        let shortfall = try XCTUnwrap(budget.shortfall)
        XCTAssertGreaterThan(shortfall.requiredBytes, shortfall.allowedBytes)
        // The reorder depth plus one to hand on plus one being decoded, and
        // the pictures the pipeline holds outside the queue whether or not
        // the budget agrees to them.
        let picture = decodedPictureBytes(
            width: 3840, height: 2160, pixelFormat: kCVPixelFormatType_64RGBAHalf)
        XCTAssertGreaterThanOrEqual(
            shortfall.requiredBytes,
            (PipelineBudget.picturesHeldOutsideTheQueue + 2 + 2) * picture)
    }

    /// The passthrough path decodes nothing here, so there is no picture to
    /// weigh and the second the queue was asked for is the whole of its cost.
    /// A budget that reserved for pictures on this path would refuse films it
    /// can play comfortably.
    func testThePassthroughPathReservesNothingForPicturesItNeverMakes() {
        let budget = PipelineBudget(
            available: 400 * 1_048_576, pictureBytes: 0, frameRate: 24, videoDelay: 2,
            videoBytesPerSecond: 80_000_000 / 8, audioBytesPerSecond: 24_500_000 / 8,
            decodedAudioBytesPerSecond: 48_000 * 8 * 4,
            readAheadSeconds: 8, videoTargetSeconds: 1, audioTargetSeconds: 2)
        XCTAssertNil(budget.shortfall)
        XCTAssertEqual(budget.pictureReserveBytes, 0)
        XCTAssertEqual(budget.videoSampleBytes, 80_000_000 / 8)
    }

    /// Read-ahead comes from the file's own rate, not from a figure chosen for
    /// a library: the same eight seconds cost what this file costs, with room
    /// for a scene over the mean, and a track half the bitrate is given half
    /// the bytes to hold them in.
    func testReadAheadIsTheFilesOwnBitrateTimesTheSecondsItIsAskedFor() {
        func budget(videoBitsPerSecond: Int) -> PipelineBudget {
            PipelineBudget(
                available: 8000 * 1_048_576, pictureBytes: 0, frameRate: 24, videoDelay: 0,
                videoBytesPerSecond: videoBitsPerSecond / 8, audioBytesPerSecond: 0,
                decodedAudioBytesPerSecond: 0,
                readAheadSeconds: 8, videoTargetSeconds: 1, audioTargetSeconds: 2)
        }
        let peak = PipelineBudget.packetPeakOverMean
        XCTAssertEqual(budget(videoBitsPerSecond: 80_000_000).videoPacketBytes, peak * 8 * 80_000_000 / 8)
        XCTAssertEqual(budget(videoBitsPerSecond: 40_000_000).videoPacketBytes, peak * 8 * 40_000_000 / 8)
    }

    /// Read-ahead is cut before depth, and never below the span the engine
    /// itself calls a starved buffer: seconds of read-ahead are what absorbs
    /// a network stall, where depth in the picture queue only absorbs decode
    /// jitter.
    func testReadAheadIsCutBeforeDepthAndNeverBelowTheStarvationWatermark() {
        let roomy = remuxBudget(availableMB: 4000)
        let tight = remuxBudget(availableMB: 1560)
        XCTAssertLessThan(tight.videoPacketBytes, roomy.videoPacketBytes)
        XCTAssertGreaterThanOrEqual(
            Double(tight.videoPacketBytes),
            PipelineBudget.minimumReadAheadSeconds * 80_000_000 / 8)
    }

    /// A picture weighed off a real buffer, never computed from the format's
    /// own bits per pixel: 4K is four times 1080p and 64-bit RGBA half is
    /// twice the 10-bit 4:2:0 it was mapped from, and the padding CoreVideo
    /// chose is in both readings.
    func testAPictureIsWeighedRatherThanComputed() {
        let hd = decodedPictureBytes(
            width: 1920, height: 1080, pixelFormat: kCVPixelFormatType_64RGBAHalf)
        let uhd = decodedPictureBytes(
            width: 3840, height: 2160, pixelFormat: kCVPixelFormatType_64RGBAHalf)
        let source = decodedPictureBytes(
            width: 3840, height: 2160,
            pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        XCTAssertEqual(Double(uhd) / Double(hd), 4, accuracy: 0.05)
        XCTAssertEqual(Double(uhd) / Double(source), 8.0 / 3.0, accuracy: 0.05)
    }

    /// The device is asked what it will give, and an answer it cannot give is
    /// not the answer zero. `os_proc_available_memory` returns 0 wherever the
    /// jetsam limit cannot be read - every simulator, measured on tvOS 26.5,
    /// whose runningboardd loads no jetsam database - and a 0 taken at face
    /// value makes the allowance 0 and refuses every film ever opened.
    ///
    /// This runs on macOS, where the fallback is the only branch there is, so
    /// what it pins is the fallback itself: a figure large enough that an
    /// ordinary film opens on it. The tvOS branch cannot be reached from
    /// here; that the call answers 0 on the simulator was measured directly
    /// rather than asserted.
    func testAnUnreadableJetsamLimitStillPlaysAnOrdinaryFilm() {
        let available = availableMemoryBytes()
        XCTAssertGreaterThan(available, 0)
        let budget = PipelineBudget(
            available: available,
            pictureBytes: decodedPictureBytes(
                width: 1920, height: 1080,
                pixelFormat: kCVPixelFormatType_420YpCbCr8Planar),
            frameRate: 30,
            videoDelay: 2,
            videoBytesPerSecond: 10_000_000 / 8,
            audioBytesPerSecond: 128_000 / 8,
            decodedAudioBytesPerSecond: 48_000 * 2 * 4,
            readAheadSeconds: 8,
            videoTargetSeconds: 1,
            audioTargetSeconds: 2
        )
        XCTAssertNil(budget.shortfall)
    }
}

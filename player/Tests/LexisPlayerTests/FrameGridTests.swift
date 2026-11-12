import CoreMedia
import XCTest
@testable import LexisPlayer

final class FrameGridTests: XCTestCase {
    /// 23.976 fps: the period is 1001/24000 s, the grid a Matroska file
    /// rounds to milliseconds.
    private let film = CMTime(value: 1001, timescale: 24000)
    private let millisecond = CMTime(value: 1, timescale: 1000)

    func testAMillisecondRoundedFrameGoesBackOnTheGrid() {
        // frame 1 is 41.708 ms, which the container wrote down as 42
        let snapped = snappedToFrameGrid(
            CMTime(value: 42, timescale: 1000), frameDuration: film, tolerance: millisecond)
        XCTAssertEqual(CMTimeCompare(snapped, film), 0)
        // frame 2 is 83.417 ms, written down as 83
        let second = snappedToFrameGrid(
            CMTime(value: 83, timescale: 1000), frameDuration: film, tolerance: millisecond)
        XCTAssertEqual(CMTimeCompare(second, CMTime(value: 2002, timescale: 24000)), 0)
    }

    func testAFrameOffTheGridIsLeftWhereTheContainerPutIt() {
        // 60 ms is nowhere near 41.7 or 83.4: a variable rate, not a rounding
        let time = CMTime(value: 60, timescale: 1000)
        let kept = snappedToFrameGrid(time, frameDuration: film, tolerance: millisecond)
        XCTAssertEqual(CMTimeCompare(kept, time), 0)
    }

    /// A film that starts 10 ms in has every frame 10 ms off a grid through
    /// zero, which is further than the rounding: only a grid through its own
    /// first keyframe puts them back.
    func testAFilmThatStartsOffTheZeroGridSnapsToItsOwnFirstKeyframe() {
        let origin = CMTime(value: 10, timescale: 1000)
        // frame 1 is 51.708 ms, written down as 52
        let time = CMTime(value: 52, timescale: 1000)
        let zeroGrid = snappedToFrameGrid(time, frameDuration: film, tolerance: millisecond)
        XCTAssertEqual(CMTimeCompare(zeroGrid, time), 0)
        let ownGrid = snappedToFrameGrid(
            time, frameDuration: film, tolerance: millisecond, origin: origin)
        XCTAssertEqual(ownGrid.seconds, 0.010 + 1001.0 / 24000, accuracy: 1e-9)
    }

    func testAnExactTimestampAndAnUnknownRateAreUntouched() {
        // an mp4 in 24000ths is already on the grid
        let exact = CMTime(value: 3003, timescale: 24000)
        XCTAssertEqual(
            CMTimeCompare(
                snappedToFrameGrid(exact, frameDuration: film, tolerance: CMTime(value: 1, timescale: 24000)),
                exact),
            0)
        let time = CMTime(value: 42, timescale: 1000)
        XCTAssertEqual(
            CMTimeCompare(snappedToFrameGrid(time, frameDuration: nil, tolerance: millisecond), time), 0)
        XCTAssertFalse(snappedToFrameGrid(.invalid, frameDuration: film, tolerance: millisecond).isValid)
    }

    func testASampleBufferCarriesTheSnappedTimestamps() throws {
        var description: CMVideoFormatDescription?
        XCTAssertEqual(
            CMVideoFormatDescriptionCreate(
                allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_H264,
                width: 16, height: 16, extensions: nil, formatDescriptionOut: &description),
            noErr)
        let packet = Packet(
            streamIndex: 0, pts: 125, dts: 42, isKeyframe: false, isDisposable: false,
            duration: 42, data: Data([0, 0, 0, 1, 0x65])
        )
        let sample = try makeSampleBuffer(
            packet: packet, formatDescription: try XCTUnwrap(description),
            timeBaseNum: 1, timeBaseDen: 1000, frameDuration: film
        )
        XCTAssertEqual(
            CMTimeCompare(
                CMSampleBufferGetPresentationTimeStamp(sample), CMTime(value: 3003, timescale: 24000)),
            0)
        XCTAssertEqual(
            CMTimeCompare(CMSampleBufferGetDecodeTimeStamp(sample), CMTime(value: 1001, timescale: 24000)),
            0)
        // and without a rate the millisecond stays what it was
        let plain = try makeSampleBuffer(
            packet: packet, formatDescription: try XCTUnwrap(description),
            timeBaseNum: 1, timeBaseDen: 1000
        )
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(plain).seconds, 0.125, accuracy: 1e-9)
    }
}

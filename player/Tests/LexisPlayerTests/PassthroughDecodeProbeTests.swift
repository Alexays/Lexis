import CoreMedia
import LexisTestSupport
import VideoToolbox
import XCTest
@testable import LexisPlayer

final class PassthroughDecodeProbeTests: XCTestCase {
    func openFixture(frames: Int) throws -> (Demuxer, MediaStream, CMVideoFormatDescription) {
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "probe-\(frames).mp4",
            codec: .h264, width: 320, height: 180, frameCount: frames, fps: 30
        )
        let demuxer = try Demuxer(url: url)
        let stream = demuxer.streams[0]
        return (demuxer, stream, try makeFormatDescription(for: stream))
    }

    func videoPackets(from demuxer: Demuxer, stream: MediaStream) throws -> [Packet] {
        var packets: [Packet] = []
        while let packet = try demuxer.readPacket() {
            if packet.streamIndex == stream.index { packets.append(packet) }
        }
        return packets
    }

    func testItAnswersHardwareTheSameWayTheSessionDoes() throws {
        let (_, _, format) = try openFixture(frames: 2)
        let probe = try PassthroughDecodeProbe(formatDescription: format)
        XCTAssertEqual(probe.isHardwareAccelerated, VTIsHardwareDecodeSupported(kCMVideoCodecType_H264))
    }

    func testTimingIsUnmeasuredBeforeAnyFrameAndGrowsAsFramesReturn() throws {
        let (demuxer, stream, format) = try openFixture(frames: 8)
        let probe = try PassthroughDecodeProbe(formatDescription: format)
        XCTAssertEqual(probe.decodeSampleCount, 0)
        XCTAssertEqual(probe.decodeMillisecondsMean, 0)
        for packet in try videoPackets(from: demuxer, stream: stream) {
            probe.decode(try makeSampleBuffer(
                packet: packet, formatDescription: format,
                timeBaseNum: stream.timeBaseNum, timeBaseDen: stream.timeBaseDen
            ))
        }
        // best-effort and async: give VideoToolbox a moment to call back
        let deadline = Date(timeIntervalSinceNow: 5)
        while probe.decodeSampleCount < 8, Date() < deadline { usleep(10_000) }
        XCTAssertEqual(probe.decodeSampleCount, 8)
        XCTAssertGreaterThan(probe.decodeMillisecondsMean, 0)
        XCTAssertGreaterThanOrEqual(probe.decodeMillisecondsWorst, probe.decodeMillisecondsMean)
    }

    func testItStopsCountingPastTheProbeLimit() throws {
        let (demuxer, stream, format) = try openFixture(frames: 90)
        let probe = try PassthroughDecodeProbe(formatDescription: format)
        for packet in try videoPackets(from: demuxer, stream: stream) {
            probe.decode(try makeSampleBuffer(
                packet: packet, formatDescription: format,
                timeBaseNum: stream.timeBaseNum, timeBaseDen: stream.timeBaseDen
            ))
        }
        let deadline = Date(timeIntervalSinceNow: 5)
        while probe.decodeSampleCount < 60, Date() < deadline { usleep(10_000) }
        usleep(200_000)
        // fed 90, bounded at 60: the 61st through 90th packets were never
        // handed to the session at all
        XCTAssertEqual(probe.decodeSampleCount, 60)
    }

    func testAFlushClearsInFlightBookkeepingWithoutClosingTheSession() throws {
        let (demuxer, stream, format) = try openFixture(frames: 4)
        let probe = try PassthroughDecodeProbe(formatDescription: format)
        let packets = try videoPackets(from: demuxer, stream: stream)
        probe.decode(try makeSampleBuffer(
            packet: packets[0], formatDescription: format,
            timeBaseNum: stream.timeBaseNum, timeBaseDen: stream.timeBaseDen
        ))
        probe.flush()
        // a decode still allowed after a flush: the session survives it,
        // only the pending submission bookkeeping is dropped
        probe.decode(try makeSampleBuffer(
            packet: packets[1], formatDescription: format,
            timeBaseNum: stream.timeBaseNum, timeBaseDen: stream.timeBaseDen
        ))
        let deadline = Date(timeIntervalSinceNow: 5)
        while probe.decodeSampleCount < 1, Date() < deadline { usleep(10_000) }
        XCTAssertGreaterThanOrEqual(probe.decodeSampleCount, 1)
    }
}

import AVFoundation
import CoreMedia
import LexisTestSupport
import VideoToolbox
import XCTest
@testable import LexisPlayer

final class VideoDecoderTests: XCTestCase {
    private func decodeFixture(
        codec: AVVideoCodecType, name: String, expectedCodec: String
    ) throws {
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: name,
            codec: codec, width: 320, height: 240, frameCount: 48, fps: 24
        )
        let demuxer = try Demuxer(url: url)
        let stream = demuxer.streams[0]
        XCTAssertEqual(stream.codecName, expectedCodec)
        let formatDescription = try makeFormatDescription(for: stream)
        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
        XCTAssertEqual(dimensions.width, 320)
        XCTAssertEqual(dimensions.height, 240)

        let lock = NSLock()
        var times: [CMTime] = []
        var sizes: [(Int, Int)] = []
        let decoder = try VideoDecoder(formatDescription: formatDescription) { frame in
            lock.lock()
            times.append(frame.presentationTime)
            sizes.append((
                CVPixelBufferGetWidth(frame.imageBuffer),
                CVPixelBufferGetHeight(frame.imageBuffer)
            ))
            lock.unlock()
        }
        var packets = 0
        while let packet = try demuxer.readPacket() {
            packets += 1
            try decoder.decode(try makeSampleBuffer(
                packet: packet, formatDescription: formatDescription,
                timeBaseNum: stream.timeBaseNum, timeBaseDen: stream.timeBaseDen
            ))
        }
        decoder.waitForPendingFrames()
        lock.lock()
        let decoded = times
        let decodedSizes = sizes
        lock.unlock()

        XCTAssertEqual(packets, 48)
        XCTAssertEqual(decoded.count, packets)
        // frames come out in decode order, so only the set of timestamps is
        // meaningful here; each one must still be distinct
        XCTAssertEqual(Set(decoded.map(\.value)).count, packets)
        XCTAssertEqual(decodedSizes.first?.0, 320)
        XCTAssertEqual(decodedSizes.first?.1, 240)
        let ordered = decoded.sorted { $0.seconds < $1.seconds }
        XCTAssertEqual(ordered.first!.seconds, 0, accuracy: 0.001)
        XCTAssertEqual(ordered.last!.seconds, 47.0 / 24.0, accuracy: 0.001)
    }

    func testDecodesHEVC() throws {
        try decodeFixture(codec: .hevc, name: "decode-hevc.mp4", expectedCodec: "hevc")
    }

    func testDecodesH264() throws {
        try decodeFixture(codec: .h264, name: "decode-h264.mp4", expectedCodec: "h264")
    }

    func testEmptyPacketDoesNotTrap() throws {
        var description: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_H264,
            width: 320, height: 240, extensions: nil, formatDescriptionOut: &description
        ), noErr)
        let packet = Packet(
            streamIndex: 0, pts: 0, dts: 0, isKeyframe: false, isDisposable: false,
            duration: 0, data: Data()
        )
        // av_read_frame can hand back a zero-length packet; either outcome is
        // fine as long as it never traps
        do {
            let sample = try makeSampleBuffer(
                packet: packet, formatDescription: try XCTUnwrap(description),
                timeBaseNum: 1, timeBaseDen: 600
            )
            XCTAssertEqual(CMSampleBufferGetTotalSampleSize(sample), 0)
        } catch {
            XCTAssertTrue(error is SampleBufferError, "must fail cleanly, got \(error)")
        }
    }

    func testTimestampsCarryTheWholeRationalTimeBase() throws {
        var description: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_H264,
            width: 320, height: 240, extensions: nil, formatDescriptionOut: &description
        ), noErr)
        // 1001/30000 is the everyday time base that a num == 1 assumption gets
        // wrong by three orders of magnitude.
        let packet = Packet(
            streamIndex: 0, pts: 90, dts: 60, isKeyframe: true, isDisposable: false,
            duration: 0, data: Data([0, 0, 0, 1])
        )
        let sample = try makeSampleBuffer(
            packet: packet, formatDescription: try XCTUnwrap(description),
            timeBaseNum: 1001, timeBaseDen: 30_000
        )
        XCTAssertEqual(
            CMSampleBufferGetPresentationTimeStamp(sample).seconds,
            90.0 * 1001.0 / 30_000.0, accuracy: 1e-9
        )
        XCTAssertEqual(
            CMSampleBufferGetDecodeTimeStamp(sample).seconds,
            60.0 * 1001.0 / 30_000.0, accuracy: 1e-9
        )
    }

    func testRejectsAStreamWithoutExtradata() {
        let stream = MediaStream(
            index: 0, kind: .video, codecID: 0, codecName: "hevc",
            width: 320, height: 240, timeBaseNum: 1, timeBaseDen: 600,
            sampleRate: 0, channels: 0, videoDelay: 0, language: "", title: "",
            isDefault: true, isForced: false,
            colorPrimaries: 2, colorTransfer: 2, colorMatrix: 2, isFullRange: false,
            masteringDisplay: nil, contentLight: nil, dolbyVision: nil, extradata: nil
        )
        XCTAssertThrowsError(try makeFormatDescription(for: stream)) { error in
            XCTAssertEqual(error as? SampleBufferError, .missingExtradata)
        }
    }

    func testSamplesCarryTheirSyncFlags() throws {
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "attach-h264.mp4",
            codec: .h264, width: 320, height: 240, frameCount: 48, fps: 24
        )
        let demuxer = try Demuxer(url: url)
        let stream = demuxer.streams[0]
        let formatDescription = try makeFormatDescription(for: stream)
        var keyframes = 0
        var others = 0

        while let packet = try demuxer.readPacket() {
            let sample = try makeSampleBuffer(
                packet: packet, formatDescription: formatDescription,
                timeBaseNum: stream.timeBaseNum, timeBaseDen: stream.timeBaseDen
            )
            let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sample, createIfNecessary: false
            ) as? [[CFString: Any]]
            let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool
            let dependsOnOthers =
                attachments?.first?[kCMSampleAttachmentKey_DependsOnOthers] as? Bool
            let isDependedOnByOthers =
                attachments?.first?[kCMSampleAttachmentKey_IsDependedOnByOthers] as? Bool
            // present and false is CoreMedia's droppable; absent is unknown
            XCTAssertEqual(isDependedOnByOthers, packet.isDisposable ? false : nil)
            if packet.isKeyframe {
                // the absence of the key is what CoreMedia reads as a sync sample
                XCTAssertNil(notSync)
                XCTAssertEqual(dependsOnOthers, false)
                keyframes += 1
            } else {
                XCTAssertEqual(notSync, true)
                XCTAssertEqual(dependsOnOthers, true)
                others += 1
            }
        }
        XCTAssertGreaterThan(keyframes, 0)
        XCTAssertGreaterThan(others, 0)
    }

    func testTheSessionReportsWhetherHardwareDecodedIt() throws {
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "decode-hw.mp4",
            codec: .h264, width: 320, height: 180, frameCount: 2, fps: 30
        )
        let stream = try Demuxer(url: url).streams[0]
        let format = try makeFormatDescription(for: stream)
        let decoder = try VideoDecoder(formatDescription: format) { _ in }
        // VideoToolbox's own answer for whether this machine can hardware
        // decode H.264 at all; the session's honest report must agree with
        // what it was asked to enable, not silently disagree with it.
        XCTAssertEqual(
            decoder.isHardwareAccelerated,
            VTIsHardwareDecodeSupported(kCMVideoCodecType_H264)
        )
    }
}

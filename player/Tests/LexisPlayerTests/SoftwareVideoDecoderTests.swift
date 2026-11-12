import CoreMedia
import CoreVideo
import Foundation
import LexisTestSupport
import XCTest
@testable import LexisPlayer

final class SoftwareVideoDecoderTests: XCTestCase {
    /// 64-aligned on every side: no plane in an 8 bit 4:2:0 picture this
    /// size can ever need a stride CVPixelBufferPool would not already
    /// hand out, which is what makes the zero-copy path the rule here
    /// rather than the exception.
    private func vp9Stream(
        width: Int = 640, height: Int = 384, frameCount: Int = 24, gopSize: Int? = nil
    ) throws -> (demuxer: Demuxer, stream: MediaStream) {
        let url: URL
        do {
            url = try makeVP9Fixture(
                directory: FileManager.default.temporaryDirectory, name: "software-decode.mkv",
                width: width, height: height, frameCount: frameCount, fps: 24, gopSize: gopSize
            )
        } catch VP9FixtureError.ffmpegUnavailable {
            throw XCTSkip("no ffmpeg on PATH to encode a real VP9 fixture")
        }
        let demuxer = try Demuxer(url: url)
        let stream = try XCTUnwrap(demuxer.streams.first { $0.kind == .video })
        XCTAssertEqual(stream.codecName, "vp9")
        return (demuxer, stream)
    }

    func testAVP9FixtureDecodesAndEveryBufferIsIOSurfaceBacked() throws {
        let (demuxer, stream) = try vp9Stream()
        let decoder = try SoftwareVideoDecoder(stream: stream, threadCount: 2, poolCeilingBytes: 1 << 30)
        var decoded = 0
        while let packet = try demuxer.readPacket() {
            guard packet.streamIndex == stream.index else { continue }
            for sample in try decoder.decode(packet) {
                let pixelBuffer = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample) as CVPixelBuffer?)
                XCTAssertNotNil(CVPixelBufferGetIOSurface(pixelBuffer))
                decoded += 1
            }
        }
        for sample in try decoder.drainAtEndOfStream() {
            let pixelBuffer = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample) as CVPixelBuffer?)
            XCTAssertNotNil(CVPixelBufferGetIOSurface(pixelBuffer))
            decoded += 1
        }
        XCTAssertGreaterThan(decoded, 0)
    }

    func testZeroCopyIsCountedAndCopyOutIsTheException() throws {
        let (demuxer, stream) = try vp9Stream()
        let decoder = try SoftwareVideoDecoder(stream: stream, threadCount: 2, poolCeilingBytes: 1 << 30)
        while let packet = try demuxer.readPacket() {
            guard packet.streamIndex == stream.index else { continue }
            _ = try decoder.decode(packet)
        }
        _ = try decoder.drainAtEndOfStream()
        XCTAssertGreaterThan(decoder.zeroCopyFrames, 0)
        XCTAssertEqual(decoder.copiedFrames, 0, "a 64-aligned, 8 bit 4:2:0 fixture has no reason to fall back")
    }

    func testThreadCountIsTheCoreCount() throws {
        let (_, stream) = try vp9Stream()
        let decoder = try SoftwareVideoDecoder(stream: stream, threadCount: 5, poolCeilingBytes: 1 << 30)
        XCTAssertEqual(decoder.threadCount, 5)
        let live = try SoftwareVideoDecoder(
            stream: stream, threadCount: ProcessInfo.processInfo.activeProcessorCount,
            poolCeilingBytes: 1 << 30
        )
        XCTAssertEqual(live.threadCount, Int32(ProcessInfo.processInfo.activeProcessorCount))
    }

    /// What a real, paced sink does to this decoder: an
    /// `AVSampleBufferRenderSynchronizer` holds each picture until its
    /// presentation time comes due, and the sample queue holds a second more
    /// behind it, so far more pictures are alive at once than the pool keeps
    /// warm. Every one of them still has to come back - a picture the pool
    /// refuses is not a slow frame, it is a frame the film never shows, and
    /// `PlayerEngine` swallows the error it arrives as.
    func testEveryFrameSurvivesADownstreamHoldingEveryPicture() throws {
        let frameCount = 48
        let (demuxer, stream) = try vp9Stream(frameCount: frameCount)
        let decoder = try SoftwareVideoDecoder(stream: stream, threadCount: 2, poolCeilingBytes: 1 << 30)
        var held: [CMSampleBuffer] = []
        while let packet = try demuxer.readPacket() {
            guard packet.streamIndex == stream.index else { continue }
            held.append(contentsOf: try decoder.decode(packet))
        }
        held.append(contentsOf: try decoder.drainAtEndOfStream())
        XCTAssertEqual(held.count, frameCount)
    }

    private func av1Stream(tenBit: Bool, name: String) throws -> (demuxer: Demuxer, stream: MediaStream) {
        let url: URL
        do {
            url = try makeAV1Fixture(
                directory: FileManager.default.temporaryDirectory, name: name,
                width: 320, height: 192, frameCount: 24, fps: 24, tenBit: tenBit
            )
        } catch AV1FixtureError.ffmpegUnavailable {
            throw XCTSkip("no ffmpeg on PATH to encode a real AV1 fixture")
        } catch AV1FixtureError.ffmpegFailed {
            throw XCTSkip("the ffmpeg on PATH cannot encode AV1")
        }
        let demuxer = try Demuxer(url: url)
        let stream = try XCTUnwrap(demuxer.streams.first { $0.kind == .video })
        XCTAssertEqual(stream.codecName, "av1")
        return (demuxer, stream)
    }

    func testAnAV1FixtureDecodesThroughDav1d() throws {
        let (demuxer, stream) = try av1Stream(tenBit: false, name: "software-av1.mkv")
        let decoder = try SoftwareVideoDecoder(stream: stream, threadCount: 2, poolCeilingBytes: 1 << 30)
        var decoded = 0
        while let packet = try demuxer.readPacket() {
            guard packet.streamIndex == stream.index else { continue }
            decoded += try decoder.decode(packet).count
        }
        decoded += try decoder.drainAtEndOfStream().count
        XCTAssertEqual(decoded, 24)
    }

    /// An eight bit track asked for ten bit biplanar, as a mapped path asks,
    /// leaves with every code four times itself: the eight bit picture the
    /// default format hands back, in the top of sixteen bits.
    func testEightBitAV1WidensToTenBitBiplanar() throws {
        let (plainDemuxer, stream) = try av1Stream(tenBit: false, name: "software-av1-widen.mkv")
        func firstPicture(_ demuxer: Demuxer, _ decoder: SoftwareVideoDecoder) throws -> CVPixelBuffer {
            while let packet = try demuxer.readPacket() {
                guard packet.streamIndex == stream.index else { continue }
                if let sample = try decoder.decode(packet).first, let picture = CMSampleBufferGetImageBuffer(sample) {
                    return picture
                }
            }
            return try XCTUnwrap(decoder.drainAtEndOfStream().first.flatMap(CMSampleBufferGetImageBuffer))
        }
        let plain = try firstPicture(
            plainDemuxer, SoftwareVideoDecoder(stream: stream, threadCount: 2, poolCeilingBytes: 1 << 30))
        let (widenedDemuxer, _) = try av1Stream(tenBit: false, name: "software-av1-widen.mkv")
        let widened = try firstPicture(
            widenedDemuxer,
            SoftwareVideoDecoder(
                stream: stream, pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                threadCount: 2, poolCeilingBytes: 1 << 30))
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(widened), kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        CVPixelBufferLockBaseAddress(plain, .readOnly)
        CVPixelBufferLockBaseAddress(widened, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(plain, .readOnly)
            CVPixelBufferUnlockBaseAddress(widened, .readOnly)
        }
        let plainLuma = CVPixelBufferGetBaseAddressOfPlane(plain, 0)!.assumingMemoryBound(to: UInt8.self)
        let plainStride = CVPixelBufferGetBytesPerRowOfPlane(plain, 0)
        let wideLuma = CVPixelBufferGetBaseAddressOfPlane(widened, 0)!.assumingMemoryBound(to: UInt16.self)
        let wideStride = CVPixelBufferGetBytesPerRowOfPlane(widened, 0) / 2
        let plainCb = CVPixelBufferGetBaseAddressOfPlane(plain, 1)!.assumingMemoryBound(to: UInt8.self)
        let plainCr = CVPixelBufferGetBaseAddressOfPlane(plain, 2)!.assumingMemoryBound(to: UInt8.self)
        let cbStride = CVPixelBufferGetBytesPerRowOfPlane(plain, 1)
        let crStride = CVPixelBufferGetBytesPerRowOfPlane(plain, 2)
        let wideChroma = CVPixelBufferGetBaseAddressOfPlane(widened, 1)!.assumingMemoryBound(to: UInt16.self)
        let wideChromaStride = CVPixelBufferGetBytesPerRowOfPlane(widened, 1) / 2
        for y in stride(from: 0, to: 192, by: 23) {
            for x in stride(from: 0, to: 320, by: 17) {
                XCTAssertEqual(wideLuma[y * wideStride + x], UInt16(plainLuma[y * plainStride + x]) << 8)
            }
        }
        for y in stride(from: 0, to: 96, by: 11) {
            for x in stride(from: 0, to: 160, by: 13) {
                XCTAssertEqual(wideChroma[y * wideChromaStride + 2 * x], UInt16(plainCb[y * cbStride + x]) << 8)
                XCTAssertEqual(wideChroma[y * wideChromaStride + 2 * x + 1], UInt16(plainCr[y * crStride + x]) << 8)
            }
        }
    }

    /// The container itself says nothing about depth in Matroska: the ten
    /// comes off the probe decode, and the picture leaves as biplanar ten
    /// bit with the samples in the high bits and the colour tags attached -
    /// what the display layer needs to read an HDR picture as one.
    func testTenBitAV1LeavesAsTenBitBiplanarWithItsColours() throws {
        let (demuxer, stream) = try av1Stream(tenBit: true, name: "software-av1-ten.mkv")
        XCTAssertEqual(stream.bitDepth, 10)
        XCTAssertEqual(
            pictureFormat(for: stream, toneMapPixelFormat: nil) != nil,
            isHardwareDecodeSupported(ffmpegCodecName: "av1") != true
        )
        let decoder = try SoftwareVideoDecoder(
            stream: stream, pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            threadCount: 2, poolCeilingBytes: 1 << 30
        )
        var first: CVPixelBuffer?
        while first == nil, let packet = try demuxer.readPacket() {
            guard packet.streamIndex == stream.index else { continue }
            if let sample = try decoder.decode(packet).first {
                first = CMSampleBufferGetImageBuffer(sample)
            }
        }
        let buffer = try XCTUnwrap(first)
        XCTAssertEqual(
            CVPixelBufferGetPixelFormatType(buffer),
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        )
        XCTAssertNotNil(CVPixelBufferGetIOSurface(buffer))
        XCTAssertEqual(
            CVBufferCopyAttachment(buffer, kCVImageBufferTransferFunctionKey, nil) as? String,
            kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String
        )
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!
            .assumingMemoryBound(to: UInt16.self)
        // mid grey through the BT.2020 matrix is ten bit 504; the encode is
        // lossy but a flat field is nearly its DC coefficient
        XCTAssertEqual(Int(luma[0] >> 6), 504, accuracy: 24)
        let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!
            .assumingMemoryBound(to: UInt16.self)
        XCTAssertEqual(Int(chroma[0] >> 6), 512, accuracy: 24)
        XCTAssertEqual(Int(chroma[1] >> 6), 512, accuracy: 24)
    }

    func testAnAV1StreamGetsAPassthroughDescription() throws {
        let (_, stream) = try av1Stream(tenBit: false, name: "software-av1-format.mkv")
        let format = try makeFormatDescription(for: stream)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(format), kCMVideoCodecType_AV1)
        let atoms = try XCTUnwrap(
            CMFormatDescriptionGetExtension(
                format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms
            ) as? [String: Any]
        )
        XCTAssertEqual(atoms["av1C"] as? Data, stream.extradata)
    }

    /// A seek is a flush landing while pictures are still in flight, and
    /// every one of those the flush discards has to come back to the pool:
    /// they are never output, so nothing downstream ever hands them back.
    /// Nothing here holds a picture, so a pool that ever runs short over ten
    /// seeks - which is what a copy-out counts - is one a flush is emptying
    /// a few pictures at a time, until the film goes dark for good.
    func testAFlushGivesBackThePicturesItDiscards() throws {
        try skipUnlessRealtimeTests()
        let (demuxer, stream) = try vp9Stream(width: 320, height: 240, frameCount: 240, gopSize: 24)
        let decoder = try SoftwareVideoDecoder(
            stream: stream, threadCount: 4, poolCeilingBytes: 12 * 320 * 240 * 3 / 2
        )
        for target in [4.0, 1.0, 7.0, 2.0, 8.0, 0.5, 6.0, 3.0, 9.0, 1.5] {
            try demuxer.seek(to: target)
            decoder.flush()
            var decoded = 0
            var read = 0
            // Two GOPs' worth of packets, dropped as they come: nothing here
            // holds a picture, so the pool is only ever short if the decoder
            // failed to give one back.
            while read < 48, let packet = try demuxer.readPacket() {
                guard packet.streamIndex == stream.index else { continue }
                read += 1
                decoded += try decoder.decode(packet).count
            }
            XCTAssertGreaterThan(decoded, 0, "no picture came back after seeking to \(target)")
        }
        XCTAssertEqual(decoder.copiedFrames, 0, "a flush left pictures out of the pool")
    }

    /// What the sample queue may hold is what the pipeline hands this
    /// decoder as its ceiling, and FFmpeg's own in-flight and reference
    /// pictures are not part of that figure: a queue sitting at its
    /// watermark must not be what pushes the decoder onto the copy-out
    /// path, on every frame, for the rest of the film.
    func testAFullQueueDoesNotCostTheDecoderItsOwnPictures() throws {
        let frameCount = 48
        let queuePictures = 24
        let pictureBytes = 640 * 384 * 3 / 2
        let (demuxer, stream) = try vp9Stream(frameCount: frameCount)
        let decoder = try SoftwareVideoDecoder(
            stream: stream, threadCount: 4, poolCeilingBytes: queuePictures * pictureBytes
        )
        var queued: [CMSampleBuffer] = []
        while let packet = try demuxer.readPacket() {
            guard packet.streamIndex == stream.index else { continue }
            queued.append(contentsOf: try decoder.decode(packet))
            queued.removeFirst(max(0, queued.count - queuePictures))
        }
        XCTAssertGreaterThan(decoder.zeroCopyFrames, 0)
        XCTAssertEqual(decoder.copiedFrames, 0)
    }

    /// The ceiling can still be reached - a device short of memory gets a
    /// pool of a few pictures whatever the decoder needs - and a picture the
    /// pool refuses is already decoded. It costs a buffer from outside the
    /// pool and a copy into it; it never costs the picture, which
    /// `PlayerEngine` would end the playback over.
    func testAPictureThePoolRefusesCostsACopyAndNotTheFilm() throws {
        let frameCount = 48
        let (demuxer, stream) = try vp9Stream(frameCount: frameCount)
        let decoder = try SoftwareVideoDecoder(
            stream: stream, threadCount: 1, poolCeilingBytes: 640 * 384 * 3 / 2
        )
        var held: [CMSampleBuffer] = []
        while let packet = try demuxer.readPacket() {
            guard packet.streamIndex == stream.index else { continue }
            held.append(contentsOf: try decoder.decode(packet))
        }
        held.append(contentsOf: try decoder.drainAtEndOfStream())
        XCTAssertEqual(held.count, frameCount)
        XCTAssertGreaterThan(decoder.copiedFrames, 0, "the ceiling was never actually reached")
    }
}

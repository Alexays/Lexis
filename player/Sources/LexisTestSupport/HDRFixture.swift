import AVFoundation
import CoreVideo
import Foundation
import VideoToolbox

public enum HDRFixtureTransfer {
    case pq
    case hlg

    var name: CFString {
        switch self {
        case .pq: return kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
        case .hlg: return kCVImageBufferTransferFunction_ITU_R_2100_HLG
        }
    }
}

/// SMPTE ST 2086 as the box stores it: green, blue and red chromaticities then
/// the white point, in units of 0.00002, then the maximum and minimum
/// luminance in units of 0.0001 cd/m2. DCI-P3 primaries, D65, 1000 nits.
public let hdrMasteringDisplayVolume: Data = {
    var data = Data(capacity: 24)
    for value: UInt16 in [13250, 34500, 7500, 3000, 34000, 16000, 15635, 16450] {
        data.append(UInt8(value >> 8))
        data.append(UInt8(value & 0xff))
    }
    for value: UInt32 in [10_000_000, 1] {
        data.append(UInt8((value >> 24) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8(value & 0xff))
    }
    return data
}()

/// CTA-861.3: 1000 nits of peak content, 400 of frame average.
public let hdrContentLightLevel = Data([0x03, 0xe8, 0x01, 0x90])

/// Writes a 10-bit HEVC mp4 tagged BT.2020 with `transfer`, and with the
/// mastering display and content light boxes when `metadata` is set.
///
/// The two payloads go in as compression properties: attached to the source
/// pixel buffers instead, they never reach the file.
///
/// An HLG file comes back tagged Dolby Vision profile 8.4 with one RPU per
/// access unit, which is what makes it the Dolby Vision fixture.
public func makeHDRFixture(
    directory: URL, name: String, width: Int, height: Int, frameCount: Int,
    transfer: HDRFixtureTransfer, metadata: Bool = true,
    /// Forces a keyframe every `gopSize` frames, so a test that seeks
    /// mid-stream knows exactly where each one lands. nil leaves the
    /// encoder's own placement, which is not test-predictable.
    gopSize: Int? = nil
) throws -> URL {
    let url = fixtureURL(in: directory, named: name)
    try? FileManager.default.removeItem(at: url)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    var compression: [String: Any] = [
        kVTCompressionPropertyKey_ProfileLevel as String: kVTProfileLevel_HEVC_Main10_AutoLevel,
    ]
    if let gopSize {
        compression[kVTCompressionPropertyKey_MaxKeyFrameInterval as String] = gopSize
        compression[kVTCompressionPropertyKey_AllowFrameReordering as String] = false
    }
    if metadata {
        compression[kVTCompressionPropertyKey_MasteringDisplayColorVolume as String] =
            hdrMasteringDisplayVolume as CFData
        compression[kVTCompressionPropertyKey_ContentLightLevelInfo as String] =
            hdrContentLightLevel as CFData
    }
    let input = AVAssetWriterInput(
        mediaType: .video,
        outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: transfer.name,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
            ],
            AVVideoCompressionPropertiesKey: compression,
        ]
    )
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ]
    )
    guard writer.canAdd(input) else {
        throw VideoFixtureError.writerFailed("cannot add the video input")
    }
    writer.add(input)
    guard writer.startWriting() else {
        throw VideoFixtureError.writerFailed(String(describing: writer.error))
    }
    writer.startSession(atSourceTime: .zero)

    for index in 0..<frameCount {
        // One input and one loop, so the deadlock the two-input fixture writer
        // works around cannot happen here. A failed writer never becomes ready
        // again, so the wait needs the status check and the bound anyway.
        var waited = 0
        while !input.isReadyForMoreMediaData {
            guard writer.status == .writing else {
                throw VideoFixtureError.writerFailed(String(describing: writer.error))
            }
            guard waited < 120_000 else {
                throw VideoFixtureError.writerFailed(
                    "writer stalled, status \(writer.status.rawValue)"
                )
            }
            usleep(1000)
            waited += 1
        }
        guard let pool = adaptor.pixelBufferPool else {
            throw VideoFixtureError.writerFailed("no pixel buffer pool")
        }
        // The pool refuses transiently while the writer still holds buffers it
        // has not recycled yet, so one refusal is not a fixture failure.
        var created: CVPixelBuffer?
        var allocation = kCVReturnSuccess
        for attempt in 0..<32 where created == nil {
            if attempt > 0 { usleep(1000) }
            allocation = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &created)
        }
        guard let buffer = created else {
            throw VideoFixtureError.writerFailed(
                "pixel buffer allocation failed with \(allocation), writer status "
                    + "\(writer.status.rawValue), error \(String(describing: writer.error))"
            )
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { continue }
            let samples = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
                * CVPixelBufferGetHeightOfPlane(buffer, plane) / 2
            let words = base.assumingMemoryBound(to: UInt16.self)
            // A ramp that moves with the frame: consecutive frames differ, so
            // the encoder emits inter frames instead of collapsing the GOP.
            for word in 0..<samples {
                words[word] = UInt16(truncatingIfNeeded: (index * 37 + word) % 1024) << 6
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        CVBufferSetAttachment(
            buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            buffer, kCVImageBufferTransferFunctionKey, transfer.name, .shouldPropagate
        )
        CVBufferSetAttachment(
            buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020,
            .shouldPropagate
        )
        guard adaptor.append(
            buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: 30)
        ) else {
            throw VideoFixtureError.writerFailed(String(describing: writer.error))
        }
    }
    input.markAsFinished()
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    done.wait()
    guard writer.status == .completed else {
        throw VideoFixtureError.writerFailed(String(describing: writer.error))
    }
    return url
}

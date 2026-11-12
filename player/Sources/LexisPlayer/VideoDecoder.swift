import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

public struct DecodedFrame {
    public let imageBuffer: CVPixelBuffer
    public let presentationTime: CMTime
}

public enum DecodeError: Error, Equatable {
    case sessionCreationFailed(OSStatus)
    case decodeFailed(OSStatus)
}

/// The VideoToolbox callback carries a raw pointer, not a Swift closure; this
/// box is what the pointer refers to for the life of the session.
private final class DecoderCallbackBox {
    let onFrame: (DecodedFrame) -> Void
    /// Set before the first decode and never after: VideoToolbox reads it
    /// from its own threads.
    var onFailure: ((CMTime, OSStatus) -> Void)?

    init(_ onFrame: @escaping (DecodedFrame) -> Void) {
        self.onFrame = onFrame
    }
}

public final class VideoDecoder {
    private let session: VTDecompressionSession
    private let box: DecoderCallbackBox
    public let formatDescription: CMVideoFormatDescription
    /// Read once at creation, honestly: false when VideoToolbox did not pick
    /// a hardware decoder, never guessed and never left unreported.
    public let isHardwareAccelerated: Bool

    /// `onFrame` runs on VideoToolbox decode threads, out of decode order and
    /// possibly concurrently; it must do its own synchronization.
    ///
    /// `scaledSize`, when given, asks VideoToolbox to scale every decoded
    /// picture down to it directly - the strip decoder's own use, so a
    /// thumbnail never carries a full-resolution buffer through CoreImage.
    /// `bufferAttributes` is what whoever takes the pictures next requires of
    /// them beyond their format - a frame processor's own list - resolved
    /// against the session's; the session's alone where the two disagree.
    public init(
        formatDescription: CMVideoFormatDescription,
        pixelFormat: OSType? = nil,
        scaledSize: (width: Int, height: Int)? = nil,
        bufferAttributes: [String: Any] = [:],
        onFrame: @escaping (DecodedFrame) -> Void
    ) throws {
        let box = DecoderCallbackBox(onFrame)
        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { refcon, _, status, _, imageBuffer, pts, _ in
                guard let refcon else { return }
                let box = Unmanaged<DecoderCallbackBox>.fromOpaque(refcon).takeUnretainedValue()
                guard status == noErr, let imageBuffer else {
                    box.onFailure?(pts, status == noErr ? kVTVideoDecoderBadDataErr : status)
                    return
                }
                box.onFrame(DecodedFrame(imageBuffer: imageBuffer, presentationTime: pts))
            },
            decompressionOutputRefCon: Unmanaged.passUnretained(box).toOpaque()
        )
        // No pixel format: asking for one makes VideoToolbox convert whenever
        // the stream is not 8 bit 4:2:0, which a 10 bit HEVC file always is.
        // IOSurface backing is the one thing the display path does require.
        var attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        // Only the tone mapped path names a format. A lossless buffer, which
        // is what VideoToolbox hands back when nobody asks, reads back as all
        // ones through a Metal texture cache.
        if let pixelFormat {
            attributes[kCVPixelBufferPixelFormatTypeKey] = pixelFormat
            attributes[kCVPixelBufferMetalCompatibilityKey] = true
        }
        if let scaledSize {
            attributes[kCVPixelBufferWidthKey] = scaledSize.width
            attributes[kCVPixelBufferHeightKey] = scaledSize.height
        }
        if !bufferAttributes.isEmpty {
            var resolved: CFDictionary?
            let own = Dictionary(uniqueKeysWithValues: attributes.map { ($0.key as String, $0.value) })
            if CVPixelBufferCreateResolvedAttributesDictionary(
                kCFAllocatorDefault, [own, bufferAttributes] as CFArray, &resolved
            ) == kCVReturnSuccess, let merged = resolved as? [String: Any] {
                attributes = Dictionary(uniqueKeysWithValues: merged.map { ($0.key as CFString, $0.value) })
            }
        }
        // Enable, not Require: Require fails session creation outright with
        // no hardware present, which is the simulator and any Mac without
        // one, and would end playback there instead of reporting honestly.
        let decoderSpecification: [CFString: Any] = [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true,
        ]
        var created: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: decoderSpecification as CFDictionary,
            imageBufferAttributes: attributes as CFDictionary,
            outputCallback: &callback,
            decompressionSessionOut: &created
        )
        guard status == noErr, let created else {
            throw DecodeError.sessionCreationFailed(status)
        }
        // The default already treats a session as realtime; set anyway, so
        // the intent is explicit rather than inherited silently.
        _ = VTSessionSetProperty(created, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        var hardwareFlag: Unmanaged<CFTypeRef>?
        let hardwareStatus = VTSessionCopyProperty(
            created, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
            allocator: kCFAllocatorDefault, valueOut: &hardwareFlag
        )
        isHardwareAccelerated = hardwareStatus == noErr
            && (hardwareFlag?.takeRetainedValue() as? Bool ?? false)
        self.box = box
        session = created
        self.formatDescription = formatDescription
    }

    /// Runs on a VideoToolbox thread for every submitted frame that comes
    /// back without a picture, with that frame's own presentation time. Set
    /// right after construction, before anything is decoded: a submitter
    /// that counts frames in flight has no other way to learn one is lost.
    public var onDecodeFailure: ((CMTime, OSStatus) -> Void)? {
        get { box.onFailure }
        set { box.onFailure = newValue }
    }

    deinit {
        // Drain first: a frame emitted after the box is deallocated would leave
        // the callback dereferencing a dangling refcon.
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        VTDecompressionSessionInvalidate(session)
    }

    public func decode(_ sampleBuffer: CMSampleBuffer) throws {
        var flagsOut = VTDecodeInfoFlags()
        let status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            // Asynchronous only: temporal processing lets VideoToolbox hold
            // pictures back for its own post-processing, which is latency the
            // reorder window downstream already pays for the right reason.
            flags: [._EnableAsynchronousDecompression],
            frameRefcon: nil,
            infoFlagsOut: &flagsOut
        )
        guard status == noErr else { throw DecodeError.decodeFailed(status) }
    }

    public func waitForPendingFrames() {
        VTDecompressionSessionWaitForAsynchronousFrames(session)
    }
}

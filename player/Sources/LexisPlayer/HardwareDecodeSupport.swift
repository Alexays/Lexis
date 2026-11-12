import CoreMedia
import Foundation
import VideoToolbox

/// Maps the demuxer's own codec name (FFmpeg's `avcodec_get_name`, what
/// `MediaStream.codecName` already carries) to what `VTIsHardwareDecodeSupported`
/// takes. Never a table of which codec is hardware-capable: this only names
/// what the two APIs call the same thing, apart from a codec this mapping
/// does not recognize.
public func appleVideoCodecType(forFFmpegCodecName name: String) -> CMVideoCodecType? {
    switch name {
    case "h264": return kCMVideoCodecType_H264
    case "hevc": return kCMVideoCodecType_HEVC
    case "av1": return kCMVideoCodecType_AV1
    case "vp9": return kCMVideoCodecType_VP9
    case "mpeg2video": return kCMVideoCodecType_MPEG2Video
    default: return nil
    }
}

/// Whether this stream decodes through VideoToolbox here: a codec the device
/// decodes in hardware, and one `makeFormatDescription` can describe to a
/// session or a display layer. A decoder the system registers for a codec
/// nothing here can describe - VP9, once the supplemental decoder is
/// registered - is a decoder no sample of this pipeline ever reaches, and
/// reading it as the hardware path would build a pipeline with no decoder
/// on either side. nil where the codec is unknown to both.
public func hardwareDecodes(_ stream: MediaStream) -> Bool? {
    guard describesForVideoToolbox(codecID: stream.codecID) else { return false }
    return isHardwareDecodeSupported(ffmpegCodecName: stream.codecName)
}

/// VideoToolbox's own answer, for the device this code is running on, right
/// now. nil when `name` is a codec this mapping does not recognize:
/// unmeasured, never guessed as unsupported.
public func isHardwareDecodeSupported(ffmpegCodecName name: String) -> Bool? {
    guard let type = appleVideoCodecType(forFFmpegCodecName: name) else { return nil }
    // A decoder the system carries but does not register by default is only
    // there for a process that asked: asked here, before the question that
    // decides whether this stream decodes in software.
    VTRegisterSupplementalVideoDecoderIfAvailable(type)
    return VTIsHardwareDecodeSupported(type)
}

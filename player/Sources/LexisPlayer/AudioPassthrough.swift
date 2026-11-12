import CFFmpeg
import CoreMedia
import Foundation

/// The compressed formats a route may be asked to carry unmodified. Atmos
/// over HDMI travels as E-AC-3 with Dolby's JOC extension, which FFmpeg
/// reports as plain EAC3: there is no separate case for it, and DTS-HD rides
/// inside a DTS stream's own extension substreams the same way.
public enum CompressedAudioFormat: Equatable {
    case ac3
    case eac3
    case dts
    case trueHD

    /// CoreAudio has public names only for the Dolby pair. The other two
    /// carry their registered FourCCs: whether a route takes them is the
    /// route's own answer, given through `audioRenderer.error`, and a
    /// refusal lands on the same decode fallback a refused AC-3 buffer does.
    var formatID: AudioFormatID {
        switch self {
        case .ac3: return kAudioFormatAC3
        case .eac3: return kAudioFormatEnhancedAC3
        case .dts: return 0x4454_5320 // 'DTS '
        case .trueHD: return 0x7472_6864 // 'trhd'
        }
    }

    /// Samples per bitstream frame, which is what an ASBD with no byte rate
    /// states about time. An MLP access unit is 40 samples at 48 kHz.
    var framesPerPacket: UInt32 {
        switch self {
        case .ac3, .eac3: return 1536
        case .dts: return 512
        case .trueHD: return 40
        }
    }
}

/// nil for anything this route is never asked to carry unmodified: today's
/// decode path runs for it instead.
public func compressedAudioFormat(codecID: UInt32) -> CompressedAudioFormat? {
    switch codecID {
    case AV_CODEC_ID_AC3.rawValue: return .ac3
    case AV_CODEC_ID_EAC3.rawValue: return .eac3
    case AV_CODEC_ID_DTS.rawValue: return .dts
    case AV_CODEC_ID_TRUEHD.rawValue: return .trueHD
    default: return nil
    }
}

public enum AudioPassthroughError: Error, Equatable {
    case formatDescriptionFailed(OSStatus)
    case blockBufferFailed(OSStatus)
    case sampleBufferFailed(OSStatus)
}

/// Names the container format only: the route decodes the bitstream itself,
/// so nothing here describes PCM layout the way `AudioDecoder`'s does.
public func makeCompressedAudioFormatDescription(
    format: CompressedAudioFormat, sampleRate: Int32, channels: Int32
) throws -> CMAudioFormatDescription {
    var asbd = AudioStreamBasicDescription(
        mSampleRate: Double(sampleRate),
        mFormatID: format.formatID,
        mFormatFlags: 0,
        mBytesPerPacket: 0,
        mFramesPerPacket: format.framesPerPacket,
        mBytesPerFrame: 0,
        mChannelsPerFrame: UInt32(channels),
        mBitsPerChannel: 0,
        mReserved: 0
    )
    var description: CMAudioFormatDescription?
    let status = CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
        magicCookieSize: 0, magicCookie: nil, extensions: nil,
        formatDescriptionOut: &description
    )
    guard status == noErr, let description else {
        throw AudioPassthroughError.formatDescriptionFailed(status)
    }
    return description
}

/// Wraps `packet`'s bytes exactly as the container carries them: what a
/// route that accepts the format decodes on its own.
public func makeCompressedAudioSampleBuffer(
    packet: Packet, formatDescription: CMAudioFormatDescription,
    timeBaseNum: Int32, timeBaseDen: Int32
) throws -> CMSampleBuffer {
    let block: CMBlockBuffer
    do {
        block = try makeBlockBuffer(over: packet)
    } catch SampleBufferError.blockBufferFailed(let status) {
        throw AudioPassthroughError.blockBufferFailed(status)
    }

    let scaled = { (stamp: Int64?) -> CMTime in
        guard let stamp else { return .invalid }
        return CMTimeMultiplyByRatio(
            CMTime(value: stamp, timescale: timeBaseDen), multiplier: timeBaseNum, divisor: 1
        )
    }
    var timing = CMSampleTimingInfo(
        duration: scaled(packet.duration), presentationTimeStamp: scaled(packet.pts),
        decodeTimeStamp: scaled(packet.dts)
    )
    var size = packet.byteCount
    var sample: CMSampleBuffer?
    let status = CMSampleBufferCreateReady(
        allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: formatDescription,
        sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
        sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample
    )
    guard status == noErr, let sample else {
        throw AudioPassthroughError.sampleBufferFailed(status)
    }
    return sample
}

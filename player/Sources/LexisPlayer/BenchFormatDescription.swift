import CFFmpeg
import CoreMedia
import Foundation

/// `SampleBuffers.makeFormatDescription` only opens a session for H.264 and
/// HEVC - the two codecs `LexisPlayer.adopt()` ever commits to passthrough
/// playback, unchanged by this file. The bench asks a wider question: can
/// THIS DEVICE decode every codec the corpus carries, in hardware or at
/// all - which needs a session for AV1, VP9 and MPEG-2 too. Reached only
/// from `DecodeOnlyProbeRun`, never from `LexisPlayer`.
public enum BenchFormatDescriptionError: Error, Equatable {
    /// The first video packet was not a real key frame VP9 could derive its
    /// config from - it shows an existing frame, or is not a key frame.
    case vp9FirstPacketNotAKeyFrame
    /// The VP9 uncompressed header ended before color_config finished, or
    /// its frame_sync_code did not match: a malformed or exotic clip, not a
    /// codec this function forgot to handle.
    case vp9HeaderMalformed
}

/// Builds a format description for whatever codec `stream` carries, wide
/// enough for the bench's own decode-only run. `firstKeyframe` is read only
/// for VP9, which this task found carries no CodecPrivate in Matroska at
/// all (verified against the corpus's own vp9.mkv) - its profile, bit depth
/// and chroma layout come from the bitstream's own uncompressed header
/// instead, the same place a muxer that does write a vpcC box reads them
/// from.
public func benchFormatDescription(
    for stream: MediaStream, firstKeyframe: Data
) throws -> CMVideoFormatDescription {
    switch stream.codecID {
    case AV_CODEC_ID_HEVC.rawValue, AV_CODEC_ID_H264.rawValue, AV_CODEC_ID_AV1.rawValue:
        return try makeFormatDescription(for: stream)
    case AV_CODEC_ID_VP9.rawValue:
        let vpcC = try vp9CodecConfigurationRecord(firstKeyframe: firstKeyframe)
        return try videoFormatDescription(
            for: stream, codecType: kCMVideoCodecType_VP9, atoms: ["vpcC": vpcC]
        )
    case AV_CODEC_ID_MPEG2VIDEO.rawValue:
        // Verified against the corpus's own mpeg2.ts: every sample already
        // opens with its own sequence_header() and sequence_extension(), in
        // band, the way a closed-GOP MPEG transport stream repeats them at
        // every GOP boundary - VideoToolbox parses those from the sample
        // data itself and needs no out-of-band atom at all.
        return try videoFormatDescription(
            for: stream, codecType: kCMVideoCodecType_MPEG2Video, atoms: [:]
        )
    default:
        throw SampleBufferError.unsupportedCodec(stream.codecName)
    }
}

/// The VP9 uncompressed header, VP9 Bitstream & Decoding Process
/// Specification section 6.2 - read only far enough to build a
/// VPCodecConfigurationRecord: profile, bit depth, chroma layout and color
/// range. Never the compressed header, which VideoToolbox has no need of
/// out of band. Reuses `BitReader` (DolbyVisionRPU.swift): the same
/// most-significant-bit-first reader an RPU is already parsed with.
private func vp9CodecConfigurationRecord(firstKeyframe: Data) throws -> Data {
    var reader = BitReader([UInt8](firstKeyframe))
    do {
        guard try reader.read(2) == 0b10 else { throw BenchFormatDescriptionError.vp9HeaderMalformed }
        let profileLowBit = try reader.read(1)
        let profileHighBit = try reader.read(1)
        let profile = (profileHighBit << 1) | profileLowBit
        if profile == 3 { try reader.skip(1) } // reserved_zero
        guard try reader.read(1) == 0 else { // show_existing_frame
            throw BenchFormatDescriptionError.vp9FirstPacketNotAKeyFrame
        }
        guard try reader.read(1) == 0 else { // frame_type: 0 == KEY_FRAME
            throw BenchFormatDescriptionError.vp9FirstPacketNotAKeyFrame
        }
        try reader.skip(2) // show_frame, error_resilient_mode
        guard try reader.read(24) == 0x49_83_42 else { // frame_sync_code
            throw BenchFormatDescriptionError.vp9HeaderMalformed
        }

        var bitDepth: UInt32 = 8
        if profile >= 2 {
            bitDepth = try reader.read(1) == 1 ? 12 : 10 // ten_or_twelve_bit
        }
        let colorSpace = try reader.read(3)
        let colorRange: UInt32
        var subsamplingX: UInt32 = 1
        var subsamplingY: UInt32 = 1
        if colorSpace != 0b111 { // != CS_RGB
            colorRange = try reader.read(1)
            if profile == 1 || profile == 3 {
                subsamplingX = try reader.read(1)
                subsamplingY = try reader.read(1)
                try reader.skip(1) // reserved_zero
            }
        } else {
            colorRange = 1
            if profile == 1 || profile == 3 { try reader.skip(1) } // reserved_zero
        }

        let chromaSubsampling: UInt8
        switch (subsamplingX, subsamplingY) {
        case (1, 1): chromaSubsampling = 1 // 4:2:0, colocated with luma: libvpx's own default siting
        case (1, 0): chromaSubsampling = 2 // 4:2:2
        case (0, 0): chromaSubsampling = 3 // 4:4:4
        default: throw BenchFormatDescriptionError.vp9HeaderMalformed // (0,1): not a valid VP9 layout
        }
        // The VP9 spec's color_space carries primaries, transfer and matrix
        // as one bundled enum; only CS_UNKNOWN (0) is verified against this
        // task's own corpus, which tags none of the three. The other
        // enumerated values map to real, distinct CICP triples this
        // function does not yet know precisely enough to state as fact, so
        // they read as Unspecified too (CICP 2) rather than a guessed
        // number - this task confirmed VideoToolbox accepts an Unspecified
        // triple and does not use it to refuse a session, only honest about
        // what color_space actually told us.
        let cicpUnspecified: UInt8 = 2
        // CS_RGB (7) signals the identity matrix (CICP 0); every other
        // value, known or not, reads as Unspecified for the same reason.
        let matrixCoefficients: UInt8 = colorSpace == 0b111 ? 0 : cicpUnspecified

        var record = Data()
        record.append(contentsOf: [1, 0, 0, 0]) // FullBox version 1, flags 0
        record.append(UInt8(profile))
        // VP9 signals no level in the bitstream itself - level 10 ("Level 1")
        // is a fixed placeholder, not computed from this clip's resolution
        // or bitrate: VideoToolbox's own decision to accept or refuse a
        // session rests on profile, bit depth and dimensions, not this field.
        record.append(10)
        record.append(UInt8(bitDepth << 4) | (chromaSubsampling << 1) | UInt8(colorRange))
        record.append(cicpUnspecified) // colourPrimaries
        record.append(cicpUnspecified) // transferCharacteristics
        record.append(matrixCoefficients)
        record.append(contentsOf: [0, 0]) // codecInitializationDataSize: none
        return record
    } catch let error as RPUParseError {
        // Truncated is the only case BitReader itself raises; every other
        // error above is a BenchFormatDescriptionError thrown directly and
        // passes through this catch's rethrow untouched.
        guard case .truncated = error else { throw error }
        throw BenchFormatDescriptionError.vp9HeaderMalformed
    }
}

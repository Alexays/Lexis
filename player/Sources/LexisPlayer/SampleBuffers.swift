import CFFmpeg
import CoreMedia
import Foundation
import Synchronization

public enum SampleBufferError: Error, Equatable {
    case unsupportedCodec(String)
    case missingExtradata
    case formatDescriptionFailed(OSStatus)
    case blockBufferFailed(OSStatus)
    case sampleBufferFailed(OSStatus)
}

/// Builds the format description a VideoToolbox session or a display layer
/// needs, straight from the container's config box. Packets stay in mp4
/// length-prefixed form; nothing here converts to Annex B. The codecs
/// `LexisPlayer.adopt()` commits to playback - `benchFormatDescription` is
/// the wider question the bench asks instead.
/// The codecs `makeFormatDescription` can describe out of the container's
/// own config box: the one question the path decision has to agree with it on.
public func describesForVideoToolbox(codecID: UInt32) -> Bool {
    codecID == AV_CODEC_ID_HEVC.rawValue || codecID == AV_CODEC_ID_H264.rawValue
        || codecID == AV_CODEC_ID_AV1.rawValue
}

/// `dolbyVisionRecord` false leaves the record off a base layer that would
/// otherwise carry it: what a decoder of our own is handed, since nothing
/// on that path applies the record and a description that promises it lies.
public func makeFormatDescription(
    for stream: MediaStream, dolbyVisionRecord: Bool = true
) throws -> CMVideoFormatDescription {
    guard let extradata = stream.extradata, !extradata.isEmpty else {
        throw SampleBufferError.missingExtradata
    }
    let codecType: CMVideoCodecType
    let atomKey: String
    switch stream.codecID {
    case AV_CODEC_ID_HEVC.rawValue:
        codecType = kCMVideoCodecType_HEVC
        atomKey = "hvcC"
    case AV_CODEC_ID_H264.rawValue:
        codecType = kCMVideoCodecType_H264
        atomKey = "avcC"
    case AV_CODEC_ID_AV1.rawValue:
        // FFmpeg's Matroska demuxer hands back exactly the
        // AV1CodecConfigurationRecord bytes as extradata - verified against
        // the bench corpus's av1.mkv, whose embedded sequence header OBU
        // matches the first sample's byte for byte.
        codecType = kCMVideoCodecType_AV1
        atomKey = "av1C"
    default:
        throw SampleBufferError.unsupportedCodec(stream.codecName)
    }
    return try videoFormatDescription(
        for: stream, codecType: codecType, atoms: [atomKey: extradata],
        dolbyVisionRecord: dolbyVisionRecord)
}

/// The same stream described as Dolby Vision rather than as HEVC, so the
/// platform's own Dolby Vision decoder reads the RPU out of each access unit
/// instead of an HEVC decoder walking past it. Profiles 5 and 8: the two
/// whose whole picture is the base layer plus the RPU.
///
/// 'dvh1' and not 'dvhe': VideoToolbox has no decoder for 'dvhe' at all, which
/// `VTDecompressionSessionCreate` answers with kVTCouldNotFindVideoDecoderErr.
/// The hvcC has to travel with the record - a description carrying only the
/// Dolby Vision record is refused.
public func makeDolbyVisionFormatDescription(
    for stream: MediaStream, configuration: DolbyVisionConfiguration? = nil
) throws -> CMVideoFormatDescription {
    guard let extradata = stream.extradata, !extradata.isEmpty else {
        throw SampleBufferError.missingExtradata
    }
    guard stream.codecID == AV_CODEC_ID_HEVC.rawValue, let dolbyVision = configuration ?? stream.dolbyVision else {
        throw SampleBufferError.unsupportedCodec(stream.codecName)
    }
    return try videoFormatDescription(
        for: stream, codecType: kCMVideoCodecType_DolbyVisionHEVC,
        atoms: ["hvcC": extradata, dolbyVision.atomKey: dolbyVision.record]
    )
}

/// The tail every codec shares once its own config atom (or none, for a
/// codec whose samples carry their own header in band) is known: the color
/// and HDR metadata extensions, this stream's Dolby Vision record if it has
/// one, and the `CMVideoFormatDescriptionCreate` call itself. `atoms` may be
/// empty - the sample description extension atoms key is then left out
/// entirely, which is what a codec needing no out-of-band config wants.
func videoFormatDescription(
    for stream: MediaStream, codecType: CMVideoCodecType, atoms: [String: Data],
    dolbyVisionRecord: Bool = true
) throws -> CMVideoFormatDescription {
    var atoms = atoms
    var extensions: [CFString: Any] = [:]
    // Without these VideoToolbox guesses, and it guesses SDR 601: measured on
    // a PQ stream whose buffers came back tagged ITU_R_709_2 and SMPTE_C.
    if let primaries = colorPrimariesName(stream.colorPrimaries) {
        extensions[kCMFormatDescriptionExtension_ColorPrimaries] = primaries
    }
    if let transfer = transferFunctionName(stream.colorTransfer) {
        extensions[kCMFormatDescriptionExtension_TransferFunction] = transfer
    }
    if let matrix = yCbCrMatrixName(stream.colorMatrix) {
        extensions[kCMFormatDescriptionExtension_YCbCrMatrix] = matrix
    }
    extensions[kCMFormatDescriptionExtension_FullRangeVideo] = stream.isFullRange
    // Left out, a non-square pixel is drawn square: a widescreen DVD comes
    // out at 5:4.
    if let pixelAspect = pixelAspectRatio(of: stream) {
        extensions[kCMFormatDescriptionExtension_PixelAspectRatio] = pixelAspect
    }
    if let location = chromaLocationName(stream.chromaLocation) {
        extensions[kCMFormatDescriptionExtension_ChromaLocationTopField] = location
        extensions[kCMFormatDescriptionExtension_ChromaLocationBottomField] = location
    }
    if let mastering = stream.masteringDisplay {
        extensions[kCMFormatDescriptionExtension_MasteringDisplayColorVolume] = mastering as CFData
    }
    if let light = stream.contentLight {
        extensions[kCMFormatDescriptionExtension_ContentLightLevelInfo] = light as CFData
    }
    // Only a base layer that stands on its own, with no enhancement layer
    // behind it, carries its record here, keeping the hvc1 sample entry the
    // container uses: that is the shape AVFoundation writes. A base layer that
    // does not stand on its own needs the 'dvh1' sample entry with it, which
    // `makeDolbyVisionFormatDescription` builds, profile 7's as 8.1; here a
    // profile 7 base layer goes as the HDR10 it is, with no record to
    // promise a layer it will not get.
    if dolbyVisionRecord, let dolbyVision = stream.dolbyVision,
        dolbyVision.recordDescribesWhatIsHandedOver
    {
        atoms[dolbyVision.atomKey] = dolbyVision.record
    }
    if !atoms.isEmpty {
        extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] = atoms
    }
    var description: CMVideoFormatDescription?
    let status = CMVideoFormatDescriptionCreate(
        allocator: kCFAllocatorDefault,
        codecType: codecType,
        width: stream.width,
        height: stream.height,
        extensions: extensions as CFDictionary,
        formatDescriptionOut: &description
    )
    guard status == noErr, let description else {
        throw SampleBufferError.formatDescriptionFailed(status)
    }
    return description
}


/// A `CMBlockBuffer` over the packet's own bytes, never a copy of them. The
/// block buffer takes a reference to the buffer FFmpeg owns and releases it
/// when CoreMedia finalizes: that reference is what lets the sample outlive
/// the `Packet` it was made from, which it must, since the sink holds samples
/// long after the demux thread has moved past the packet.
func makeBlockBuffer(over packet: Packet) throws -> CMBlockBuffer {
    guard let owner = packet.buffer, packet.byteCount > 0,
        let base = owner.packet.pointee.data
    else {
        throw SampleBufferError.blockBufferFailed(kCMBlockBufferBadLengthParameterErr)
    }
    // Retained here, released by FreeBlock. CoreMedia calls FreeBlock only for
    // a block buffer it actually created, so the failure path below has to
    // release it by hand or the packet's bytes are never given back.
    let retained = Unmanaged.passRetained(owner)
    var source = CMBlockBufferCustomBlockSource(
        version: kCMBlockBufferCustomBlockSourceVersion,
        AllocateBlock: nil,
        FreeBlock: { refCon, _, _ in
            guard let refCon else { return }
            Unmanaged<PacketBuffer>.fromOpaque(refCon).release()
        },
        refCon: retained.toOpaque()
    )
    var blockBuffer: CMBlockBuffer?
    let status = CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault,
        memoryBlock: UnsafeMutableRawPointer(base),
        blockLength: packet.byteCount,
        blockAllocator: nil,
        customBlockSource: &source,
        offsetToData: 0,
        dataLength: packet.byteCount,
        flags: 0,
        blockBufferOut: &blockBuffer
    )
    guard status == noErr, let blockBuffer else {
        retained.release()
        throw SampleBufferError.blockBufferFailed(status)
    }
    return blockBuffer
}

/// Puts a frame time back on the grid its container rounded it off.
///
/// A Matroska file times every frame to the millisecond, and at 23.976 fps
/// the period is 41.708 ms, so the frames land at 0, 42, 83, 125, 167 ... A
/// renderer shows a frame at the first refresh that has reached its time,
/// and a frame rounded to just past its own refresh slips onto the next one,
/// where the frame after it is also due: one is repeated and one dropped,
/// at a rate that follows the phase between the clock and the screen - a
/// tenth of the frames, measured, and never the same tenth twice. An mp4
/// times its frames in 24000ths and never shows this.
///
/// `time` is moved only when it is within `tolerance` - one tick of the
/// container's time base - of a grid point, which is exactly the rounding
/// and nothing else: a frame further off is one the container really timed
/// there, and is left alone. So is a stream with no known frame rate.
///
/// The grid runs through `origin`, the stream's first keyframe: a film that
/// does not start on a multiple of its own period has no frame on a grid
/// through zero.
public func snappedToFrameGrid(
    _ time: CMTime, frameDuration: CMTime?, tolerance: CMTime, origin: CMTime = .zero
) -> CMTime {
    guard let frameDuration, time.isValid, frameDuration.value > 0 else { return time }
    let index = ((time.seconds - origin.seconds) / frameDuration.seconds).rounded()
    guard index.isFinite else { return time }
    let snapped = CMTimeAdd(
        origin,
        CMTime(value: frameDuration.value * Int64(index), timescale: frameDuration.timescale)
    )
    guard abs(snapped.seconds - time.seconds) <= tolerance.seconds + 1e-9 else {
        FrameGridTally.count(snapped: false)
        return time
    }
    FrameGridTally.count(snapped: true)
    return snapped
}

/// How many timestamps the grid took and how many it refused, over the
/// process: what a trace reads to say whether a film's timestamps are the
/// rounding the grid exists for, or something else.
public enum FrameGridTally {
    private static let snappedCount = Atomic<Int>(0)
    private static let offGridCount = Atomic<Int>(0)

    static func count(snapped: Bool) {
        if snapped {
            _ = snappedCount.wrappingAdd(1, ordering: .relaxed)
        } else {
            _ = offGridCount.wrappingAdd(1, ordering: .relaxed)
        }
    }

    public static var reading: (snapped: Int, offGrid: Int) {
        (snappedCount.load(ordering: .relaxed), offGridCount.load(ordering: .relaxed))
    }
}

/// `timeBaseNum` / `timeBaseDen` is the stream's own time base: both halves
/// matter, 1001/30000 being the everyday case a numerator of 1 gets wrong.
/// `frameDuration` is the stream's frame period where the container states
/// a rate, for `snappedToFrameGrid`, and `gridOrigin` the time its grid runs
/// through; nil leaves the timestamps as they are.
public func makeSampleBuffer(
    packet: Packet,
    formatDescription: CMVideoFormatDescription,
    timeBaseNum: Int32,
    timeBaseDen: CMTimeScale,
    frameDuration: CMTime? = nil,
    gridOrigin: CMTime = .zero,
    data: CMBlockBuffer? = nil
) throws -> CMSampleBuffer {
    let blockBuffer = try data ?? makeBlockBuffer(over: packet)

    let tick = CMTime(value: Int64(timeBaseNum), timescale: timeBaseDen)
    let scaled = { (stamp: Int64?) -> CMTime in
        guard let stamp else { return .invalid }
        let time = CMTimeMultiplyByRatio(
            CMTime(value: stamp, timescale: timeBaseDen), multiplier: timeBaseNum, divisor: 1
        )
        return snappedToFrameGrid(
            time, frameDuration: frameDuration, tolerance: tick, origin: gridOrigin)
    }
    var timing = CMSampleTimingInfo(
        duration: .invalid,
        presentationTimeStamp: scaled(packet.pts),
        decodeTimeStamp: scaled(packet.dts)
    )
    var size = CMBlockBufferGetDataLength(blockBuffer)
    var sampleBuffer: CMSampleBuffer?
    let status = CMSampleBufferCreateReady(
        allocator: kCFAllocatorDefault,
        dataBuffer: blockBuffer,
        formatDescription: formatDescription,
        sampleCount: 1,
        sampleTimingEntryCount: 1,
        sampleTimingArray: &timing,
        sampleSizeEntryCount: 1,
        sampleSizeArray: &size,
        sampleBufferOut: &sampleBuffer
    )
    guard status == noErr, let sampleBuffer else {
        throw SampleBufferError.sampleBufferFailed(status)
    }
    try attachDependencies(of: packet, to: sampleBuffer)
    return sampleBuffer
}

/// A renderer takes every sample for a sync sample unless told otherwise, and
/// after a flush it has to start on one. Without these, a seek landing
/// mid-GOP feeds the decoder frames whose references it never saw.
private func attachDependencies(of packet: Packet, to sampleBuffer: CMSampleBuffer) throws {
    guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
        sampleBuffer, createIfNecessary: true
    ), CFArrayGetCount(attachments) > 0 else {
        throw SampleBufferError.sampleBufferFailed(kCMSampleBufferError_AllocationFailed)
    }
    let sample = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
    func set(_ key: CFString, _ value: Bool) {
        CFDictionarySetValue(
            sample,
            Unmanaged.passUnretained(key).toOpaque(),
            Unmanaged.passUnretained(value ? kCFBooleanTrue : kCFBooleanFalse).toOpaque()
        )
    }
    if !packet.isKeyframe {
        set(kCMSampleAttachmentKey_NotSync, true)
    }
    set(kCMSampleAttachmentKey_DependsOnOthers, !packet.isKeyframe)
    // CoreMedia's own definition: a frame is droppable if and only if this key
    // is present and false. FFmpeg's disposable flag says exactly that.
    if packet.isDisposable {
        set(kCMSampleAttachmentKey_IsDependedOnByOthers, false)
    }
}

/// Tells a picture nothing else predicts from by its first slice's NAL
/// header, in the container's length-prefixed form: what a decoder falling
/// behind the clock can skip at the cost of that one picture and no other.
/// H.264 marks it with a nal_ref_idc of 0; HEVC with a `_N` slice type in
/// the highest temporal sub-layer, since a lower layer's `_N` picture may
/// still be predicted from by a layer above it.
struct NonReferencePictures {
    private let lengthSize: Int
    /// HEVC's highest temporal id, nil for H.264.
    private let topLayer: UInt8?

    init?(stream: MediaStream) {
        guard let config = stream.extradata else { return nil }
        let bytes = [UInt8](config)
        switch stream.codecID {
        case AV_CODEC_ID_H264.rawValue:
            // avcC: lengthSizeMinusOne in the low two bits of byte 4
            guard bytes.count > 4, bytes[0] == 1 else { return nil }
            lengthSize = Int(bytes[4] & 0x03) + 1
            topLayer = nil
        case AV_CODEC_ID_HEVC.rawValue:
            // hvcC byte 21: numTemporalLayers in bits 3 to 5, 0 for unknown,
            // then lengthSizeMinusOne in the low two bits
            guard bytes.count > 22, bytes[0] == 1 else { return nil }
            let layers = (bytes[21] >> 3) & 0x07
            guard layers > 0 else { return nil }
            lengthSize = Int(bytes[21] & 0x03) + 1
            topLayer = layers - 1
        default:
            return nil
        }
    }

    func contains(_ packet: UnsafeRawBufferPointer) -> Bool {
        var offset = 0
        while offset + lengthSize + 2 <= packet.count {
            var length = 0
            for i in 0..<lengthSize { length = length << 8 | Int(packet[offset + i]) }
            let start = offset + lengthSize
            guard length >= 2, start + length <= packet.count else { return false }
            let header = packet[start]
            if let topLayer {
                let type = (header >> 1) & 0x3f
                // VCL types are 0 to 31, and the even ones under 16 are `_N`
                if type < 32 {
                    let temporalId = (packet[start + 1] & 0x07) &- 1
                    return type < 16 && type % 2 == 0 && temporalId == topLayer
                }
            } else {
                let type = header & 0x1f
                // a slice, or an IDR slice, which is always a reference
                if type == 1 || type == 5 { return header & 0x60 == 0 }
            }
            offset = start + length
        }
        return false
    }
}

/// The pixel aspect ratio attachment for a stream whose pixels are not
/// square, nil for one whose are or that does not say.
func pixelAspectRatio(of stream: MediaStream) -> CFDictionary? {
    guard stream.pixelAspectNum > 0, stream.pixelAspectDen > 0, stream.pixelAspectNum != stream.pixelAspectDen
    else { return nil }
    return [
        kCVImageBufferPixelAspectRatioHorizontalSpacingKey: stream.pixelAspectNum,
        kCVImageBufferPixelAspectRatioVerticalSpacingKey: stream.pixelAspectDen,
    ] as CFDictionary
}

/// Core Video's name for an `AVChromaLocation`, nil where the stream says
/// nothing.
func chromaLocationName(_ location: Int32) -> CFString? {
    switch UInt32(bitPattern: location) {
    case AVCHROMA_LOC_LEFT.rawValue: kCVImageBufferChromaLocation_Left
    case AVCHROMA_LOC_CENTER.rawValue: kCVImageBufferChromaLocation_Center
    case AVCHROMA_LOC_TOPLEFT.rawValue: kCVImageBufferChromaLocation_TopLeft
    case AVCHROMA_LOC_TOP.rawValue: kCVImageBufferChromaLocation_Top
    case AVCHROMA_LOC_BOTTOMLEFT.rawValue: kCVImageBufferChromaLocation_BottomLeft
    case AVCHROMA_LOC_BOTTOM.rawValue: kCVImageBufferChromaLocation_Bottom
    default: nil
    }
}

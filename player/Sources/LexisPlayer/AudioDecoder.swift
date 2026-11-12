import CFFmpeg
import CoreMedia
import Foundation

public enum AudioDecodeError: Error, Equatable {
    case decoderUnavailable(String)
    case allocationFailed
    case openFailed(Int32)
    case resamplerFailed(Int32)
    case decodeFailed(Int32)
    case formatDescriptionFailed(OSStatus)
    case sampleBufferFailed(OSStatus)
}

extension AudioDecodeError: LocalizedError {
    /// The library's own words for the failure, which is what the readout
    /// puts on the same line as a refused route's `localizedDescription`.
    public var errorDescription: String? {
        switch self {
        case .decoderUnavailable(let codec): return "no decoder for \(codec)"
        case .allocationFailed: return "out of memory"
        case .openFailed(let code), .decodeFailed(let code), .resamplerFailed(let code):
            return DemuxError.message(for: code)
        case .formatDescriptionFailed(let status), .sampleBufferFailed(let status):
            return NSError(domain: NSOSStatusErrorDomain, code: Int(status)).localizedDescription
        }
    }
}

/// Decodes one audio stream to interleaved 32-bit float PCM, in the sample
/// buffers an AVSampleBufferAudioRenderer takes. Nothing here downmixes: the
/// channel count is the codec's, which is what multichannel playback needs.
public final class AudioDecoder {
    /// avcodec reads past the end of extradata, so the buffer it is given is
    /// oversized by this much.
    private static let extradataPadding = 64
    /// Frames are gathered into sample buffers of at least 1/50 s: TrueHD
    /// decodes 40 samples at a time, and one buffer per frame is over a
    /// thousand allocations, locks and renderer hand-offs a second.
    private static let buffersPerSecond: Int32 = 50

    private let context: UnsafeMutablePointer<AVCodecContext>
    private let frame: UnsafeMutablePointer<AVFrame>
    private let packet: UnsafeMutablePointer<AVPacket>
    private let timeBaseNum: Int32
    private let timeBaseDen: Int32
    /// `decode` runs on the audio decode thread; `flush` is called straight
    /// from the demux thread by a seek, with nothing else serialising the
    /// two. Without this, a flush landing while `decode` is inside
    /// `avcodec_send_packet`/`avcodec_receive_frame` races
    /// `avcodec_flush_buffers` on the same `AVCodecContext` from another
    /// thread - confirmed by a stale AAC decoder throwing "no frame data
    /// found" and going silent for the rest of the file, reliably, before
    /// this lock was added.
    private let lock = NSLock()
    private var resampler: OpaquePointer?
    /// What the resampler was built for; a frame that differs needs a new one.
    private var inputChannels: Int32 = 0
    private var inputSampleRate: Int32 = 0
    private var inputSampleFormat: Int32 = -1

    /// Where the next buffer starts, counted in output samples rather than
    /// read off the container. A container stamps coarser than the audio's
    /// own rate - an .mkv in whole milliseconds against a 21.3333 ms AAC
    /// frame - so a start taken from each stamp overlaps its neighbour or
    /// gaps away from it by a fraction of a millisecond, every frame, which
    /// the renderer plays as a crackle. Anchored on the container at the
    /// first frame and re-anchored whenever it disagrees by more than
    /// rounding could explain, which is a real gap in the stream.
    private var nextPresentation: CMTime?
    /// Set by `drain`: avcodec refuses every packet after one, so the next
    /// `decode` starts the decoder over, whatever thread a flush raced on.
    private var drained = false

    /// The buffer frames are being gathered into: `pendingCount` of its
    /// `pendingCapacity` samples written, the first of them at `pendingStart`.
    /// Always contiguous and always in the current output format: a format
    /// change sends it out first, a gap in the stamps drops it.
    private var pendingBlock: CMBlockBuffer?
    private var pendingCapacity = 0
    private var pendingCount = 0
    private var pendingStart = CMTime.invalid

    /// Read off the first decoded frame rather than the container: a codec can
    /// answer at a different rate or channel count than the container declares
    /// (SBR doubles an AAC rate), and the frames are the truth.
    public private(set) var outputSampleRate: Int32 = 0
    public private(set) var outputChannels: Int32 = 0
    public private(set) var outputFormat: CMAudioFormatDescription?

    public init(stream: MediaStream) throws {
        guard let codec = avcodec_find_decoder(AVCodecID(rawValue: stream.codecID)) else {
            throw AudioDecodeError.decoderUnavailable(stream.codecName)
        }
        var allocatedContext = avcodec_alloc_context3(codec)
        var allocatedFrame = av_frame_alloc()
        var allocatedPacket = av_packet_alloc()
        var kept = false
        // deinit never runs for an init that throws, so every failure below has
        // to give back what was allocated here
        defer {
            if !kept {
                avcodec_free_context(&allocatedContext)
                av_frame_free(&allocatedFrame)
                av_packet_free(&allocatedPacket)
            }
        }
        guard let context = allocatedContext,
              let frame = allocatedFrame,
              let packet = allocatedPacket
        else {
            throw AudioDecodeError.allocationFailed
        }
        context.pointee.sample_rate = stream.sampleRate
        av_channel_layout_default(&context.pointee.ch_layout, stream.channels)
        if let extradata = stream.extradata, !extradata.isEmpty {
            guard let bytes = av_mallocz(extradata.count + AudioDecoder.extradataPadding) else {
                throw AudioDecodeError.allocationFailed
            }
            extradata.withUnsafeBytes { raw in
                _ = memcpy(bytes, raw.baseAddress!, extradata.count)
            }
            // the context owns it from here: avcodec_free_context frees it
            context.pointee.extradata = bytes.assumingMemoryBound(to: UInt8.self)
            context.pointee.extradata_size = Int32(extradata.count)
        }
        let code = avcodec_open2(context, codec, nil)
        guard code >= 0 else {
            throw AudioDecodeError.openFailed(code)
        }
        self.context = context
        self.frame = frame
        self.packet = packet
        timeBaseNum = stream.timeBaseNum
        timeBaseDen = stream.timeBaseDen
        kept = true
    }

    deinit {
        var resampler = self.resampler
        swr_free(&resampler)
        var frame: UnsafeMutablePointer<AVFrame>? = self.frame
        av_frame_free(&frame)
        var packet: UnsafeMutablePointer<AVPacket>? = self.packet
        av_packet_free(&packet)
        var context: UnsafeMutablePointer<AVCodecContext>? = self.context
        avcodec_free_context(&context)
    }

    /// What this packet completed, in stream order. An empty array is normal:
    /// a decoder may take several packets before its first frame, and short
    /// frames are held until they add up to a buffer worth handing out.
    public func decode(_ input: Packet) throws -> [CMSampleBuffer] {
        // a zero-length packet is avcodec's drain signal: sending one puts the
        // decoder in draining state, where every later packet fails with EOF
        guard input.byteCount > 0 else { return [] }
        lock.lock()
        defer { lock.unlock() }
        if drained { flushLocked() }
        var buffers: [CMSampleBuffer] = []
        av_packet_unref(packet)
        // The buffer alone, shared: it already carries avcodec's padding, and the
        // source's side data and flags (skip samples, discard) would move sync.
        guard let source = input.buffer?.packet.pointee else { throw AudioDecodeError.allocationFailed }
        if let shared = source.buf {
            guard let reference = av_buffer_ref(shared) else { throw AudioDecodeError.allocationFailed }
            packet.pointee.buf = reference
        }
        packet.pointee.data = source.data
        packet.pointee.size = source.size
        packet.pointee.duration = source.duration
        packet.pointee.pts = input.pts ?? LexisNoPTS
        packet.pointee.dts = input.dts ?? LexisNoPTS
        let sent = avcodec_send_packet(context, packet)
        av_packet_unref(packet)
        // EAGAIN means the decoder is full of frames we are about to drain
        guard sent >= 0 || sent == LexisErrorAgain else {
            throw AudioDecodeError.decodeFailed(sent)
        }
        while avcodec_receive_frame(context, frame) >= 0 {
            defer { av_frame_unref(frame) }
            try gatherFrame(into: &buffers)
        }
        return buffers
    }

    /// What the decoder and the pending buffer still hold once the stream has
    /// no more packets. A packet decoded after this starts the decoder over.
    public func drain() throws -> [CMSampleBuffer] {
        lock.lock()
        defer { lock.unlock() }
        var buffers: [CMSampleBuffer] = []
        drained = true
        // EOF answers a decoder already drained, which has nothing left either
        let sent = avcodec_send_packet(context, nil)
        if sent >= 0 {
            while avcodec_receive_frame(context, frame) >= 0 {
                defer { av_frame_unref(frame) }
                try gatherFrame(into: &buffers)
            }
        }
        if let sample = try finishPending() { buffers.append(sample) }
        return buffers
    }

    /// Drops what the decoder is holding. A seek must call this before the
    /// packets of the new position arrive, or the first frames out belong to
    /// the old one.
    public func flush() {
        lock.lock()
        defer { lock.unlock() }
        flushLocked()
    }

    private func flushLocked() {
        avcodec_flush_buffers(context)
        drained = false
        // the frames after a seek belong to another moment, and the count
        // that placed the ones before it says nothing about where they land
        nextPresentation = nil
        pendingBlock = nil
        pendingCount = 0
    }

    /// Resamples the frame this decoder is holding into the pending buffer,
    /// appending to `buffers` whatever that completes.
    private func gatherFrame(into buffers: inout [CMSampleBuffer]) throws {
        // A stream can change layout, rate or sample format mid-play. Feeding
        // the old resampler such a frame makes it read planes the frame does
        // not have, and leaves the format description describing the old audio.
        if resampler == nil
            || frame.pointee.ch_layout.nb_channels != inputChannels
            || frame.pointee.sample_rate != inputSampleRate
            || frame.pointee.format != inputSampleFormat
        {
            // what is gathered so far is in the format being left
            if let sample = try finishPending() { buffers.append(sample) }
            try startResampler()
        }
        guard let resampler else { throw AudioDecodeError.resamplerFailed(0) }
        let count = Int(frame.pointee.nb_samples)
        guard count > 0 else { throw AudioDecodeError.resamplerFailed(0) }
        let frameBytes = Int(outputChannels) * 4

        let pts = frame.pointee.pts
        if pts != LexisNoPTS {
            let stamped = CMTimeMultiplyByRatio(
                CMTime(value: pts, timescale: timeBaseDen),
                multiplier: timeBaseNum, divisor: 1
            )
            // Half a frame, or one container tick where the container is the
            // coarser of the two: anything under that is the stamp being
            // rounded, anything over it is the stream itself moving.
            let tolerance = max(
                CMTime(value: CMTimeValue(count), timescale: outputSampleRate * 2),
                CMTime(value: CMTimeValue(timeBaseNum), timescale: timeBaseDen)
            )
            if nextPresentation.map({
                CMTimeAbsoluteValue(CMTimeSubtract(stamped, $0)) > tolerance
            }) ?? true {
                // A run the stamps no longer continue is dropped rather than
                // sent: it is most often what a packet a seek left in flight
                // decoded after the flush, whose buffer would reach the
                // renderer stamped at the position the seek just left.
                if nextPresentation != nil {
                    pendingBlock = nil
                    pendingCount = 0
                } else if let sample = try finishPending() {
                    buffers.append(sample)
                }
                nextPresentation = CMTimeConvertScale(
                    stamped, timescale: outputSampleRate, method: .roundHalfAwayFromZero
                )
            }
        }

        if pendingBlock != nil, pendingCount + count > pendingCapacity,
            let sample = try finishPending()
        {
            buffers.append(sample)
        }
        let target = Int(outputSampleRate / AudioDecoder.buffersPerSecond)
        if pendingBlock == nil {
            // whole frames: a codec's frames are one size, so the buffer
            // fills exactly rather than going out short of the next frame
            let capacity = max(1, (target + count - 1) / count) * count
            var block: CMBlockBuffer?
            let status = CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: capacity * frameBytes,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: capacity * frameBytes,
                // Allocated here and not on first use: the resampler writes
                // through the pointer below, and a block that has not
                // allocated yet has none to give.
                flags: kCMBlockBufferAssureMemoryNowFlag,
                blockBufferOut: &block
            )
            guard status == noErr, let block else {
                throw AudioDecodeError.sampleBufferFailed(status)
            }
            pendingBlock = block
            pendingCapacity = capacity
            pendingCount = 0
            pendingStart = nextPresentation ?? .invalid
        }
        guard let block = pendingBlock else { throw AudioDecodeError.allocationFailed }
        var destination: UnsafeMutablePointer<CChar>?
        let status = CMBlockBufferGetDataPointer(
            block, atOffset: pendingCount * frameBytes, lengthAtOffsetOut: nil,
            totalLengthOut: nil, dataPointerOut: &destination
        )
        guard status == noErr, let destination else {
            throw AudioDecodeError.sampleBufferFailed(status)
        }
        // The resampler writes its interleaved plane straight into the block,
        // so the samples never exist anywhere else. It runs at the frame's
        // own rate and answers with the samples it was given; a shorter
        // answer only leaves room the count below does not claim.
        var plane: UnsafeMutablePointer<UInt8>? =
            UnsafeMutableRawPointer(destination).assumingMemoryBound(to: UInt8.self)
        let converted = withUnsafeMutablePointer(to: &plane) { planes in
            swr_convert(
                resampler, planes, Int32(count),
                UnsafeRawPointer(frame.pointee.extended_data)
                    .assumingMemoryBound(to: UnsafePointer<UInt8>?.self),
                Int32(count)
            )
        }
        guard converted > 0 else { throw AudioDecodeError.resamplerFailed(converted) }
        pendingCount += Int(converted)
        if let start = nextPresentation {
            nextPresentation = CMTimeAdd(
                start, CMTime(value: CMTimeValue(converted), timescale: outputSampleRate))
        }
        if pendingCount >= target, let sample = try finishPending() {
            buffers.append(sample)
        }
    }

    /// The pending buffer as a sample buffer, nil when nothing is pending.
    /// Leaves nothing pending either way.
    private func finishPending() throws -> CMSampleBuffer? {
        guard let block = pendingBlock, pendingCount > 0, let format = outputFormat else {
            pendingBlock = nil
            pendingCount = 0
            return nil
        }
        let count = pendingCount
        pendingBlock = nil
        pendingCount = 0
        var data = block
        let used = count * Int(outputChannels) * 4
        if used < pendingCapacity * Int(outputChannels) * 4 {
            // a sample buffer's data runs exactly as long as the samples it
            // counts; a reference to the filled front costs no copy
            var front: CMBlockBuffer?
            let status = CMBlockBufferCreateWithBufferReference(
                allocator: kCFAllocatorDefault, referenceBuffer: block, offsetToData: 0,
                dataLength: used, flags: 0, blockBufferOut: &front
            )
            guard status == noErr, let front else {
                throw AudioDecodeError.sampleBufferFailed(status)
            }
            data = front
        }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: outputSampleRate),
            presentationTimeStamp: pendingStart,
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        // sampleSizeEntryCount 0: the format description already says how many
        // bytes a frame of constant-size PCM takes
        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: data,
            formatDescription: format,
            sampleCount: CMItemCount(count),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sample
        )
        guard status == noErr, let sample else {
            throw AudioDecodeError.sampleBufferFailed(status)
        }
        return sample
    }

    private func startResampler() throws {
        var previous = self.resampler
        swr_free(&previous)
        self.resampler = nil

        let channels = frame.pointee.ch_layout.nb_channels
        let rate = frame.pointee.sample_rate
        let sampleFormat = frame.pointee.format
        var output = AVChannelLayout()
        av_channel_layout_default(&output, channels)
        var input = frame.pointee.ch_layout
        var resampler: OpaquePointer?
        let code = swr_alloc_set_opts2(
            &resampler,
            &output, AV_SAMPLE_FMT_FLT, rate,
            &input, AVSampleFormat(rawValue: sampleFormat), rate,
            0, nil
        )
        guard code >= 0, let resampler else {
            throw AudioDecodeError.resamplerFailed(code)
        }
        let initCode = swr_init(resampler)
        guard initCode >= 0 else {
            var resampler: OpaquePointer? = resampler
            swr_free(&resampler)
            throw AudioDecodeError.resamplerFailed(initCode)
        }
        self.resampler = resampler
        inputChannels = channels
        inputSampleRate = rate
        inputSampleFormat = sampleFormat
        // the count so far was kept in the old rate's own ticks
        nextPresentation = nil
        outputChannels = channels
        outputSampleRate = rate
        outputFormat = try makeFormatDescription(channels: channels, sampleRate: rate)
    }

    private func makeFormatDescription(
        channels: Int32, sampleRate: Int32
    ) throws -> CMAudioFormatDescription {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Double(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * channels),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(4 * channels),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        let layout = makeAudioChannelLayoutData(channels: channels)
        var description: CMAudioFormatDescription?
        let status = layout.withUnsafeBytes { raw in
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: &asbd,
                layoutSize: raw.count,
                layout: raw.baseAddress!.assumingMemoryBound(to: AudioChannelLayout.self),
                magicCookieSize: 0,
                magicCookie: nil,
                extensions: nil,
                formatDescriptionOut: &description
            )
        }
        guard status == noErr, let description else {
            throw AudioDecodeError.formatDescriptionFailed(status)
        }
        return description
    }
}

/// The CoreAudio name of each channel of FFmpeg's default layout for this
/// count, in the interleave order the resampler writes. nil when any channel
/// has no CoreAudio name, which is what sends the layout back to a discrete
/// tag rather than mislabelling it.
func coreAudioChannelLabels(defaultLayoutFor channels: Int32) -> [AudioChannelLabel]? {
    var layout = AVChannelLayout()
    av_channel_layout_default(&layout, channels)
    defer { av_channel_layout_uninit(&layout) }
    var labels: [AudioChannelLabel] = []
    for index in 0..<channels {
        let channel = av_channel_layout_channel_from_index(&layout, UInt32(index))
        guard let label = coreAudioLabel(channel) else { return nil }
        labels.append(label)
    }
    return labels
}

/// mpv and FFmpeg's own AudioToolbox encoder use this same correspondence:
/// FFmpeg's side pair is CoreAudio's plain surround pair, and its back pair
/// is the rear surround pair.
private func coreAudioLabel(_ channel: AVChannel) -> AudioChannelLabel? {
    switch channel {
    case AV_CHAN_FRONT_LEFT: return kAudioChannelLabel_Left
    case AV_CHAN_FRONT_RIGHT: return kAudioChannelLabel_Right
    case AV_CHAN_FRONT_CENTER: return kAudioChannelLabel_Center
    case AV_CHAN_LOW_FREQUENCY: return kAudioChannelLabel_LFEScreen
    case AV_CHAN_BACK_LEFT: return kAudioChannelLabel_RearSurroundLeft
    case AV_CHAN_BACK_RIGHT: return kAudioChannelLabel_RearSurroundRight
    case AV_CHAN_SIDE_LEFT: return kAudioChannelLabel_LeftSurround
    case AV_CHAN_SIDE_RIGHT: return kAudioChannelLabel_RightSurround
    case AV_CHAN_BACK_CENTER: return kAudioChannelLabel_CenterSurround
    case AV_CHAN_FRONT_LEFT_OF_CENTER: return kAudioChannelLabel_LeftCenter
    case AV_CHAN_FRONT_RIGHT_OF_CENTER: return kAudioChannelLabel_RightCenter
    case AV_CHAN_TOP_CENTER: return kAudioChannelLabel_TopCenterSurround
    case AV_CHAN_TOP_FRONT_LEFT: return kAudioChannelLabel_VerticalHeightLeft
    case AV_CHAN_TOP_FRONT_CENTER: return kAudioChannelLabel_VerticalHeightCenter
    case AV_CHAN_TOP_FRONT_RIGHT: return kAudioChannelLabel_VerticalHeightRight
    case AV_CHAN_TOP_BACK_LEFT: return kAudioChannelLabel_TopBackLeft
    case AV_CHAN_TOP_BACK_CENTER: return kAudioChannelLabel_TopBackCenter
    case AV_CHAN_TOP_BACK_RIGHT: return kAudioChannelLabel_TopBackRight
    case AV_CHAN_WIDE_LEFT: return kAudioChannelLabel_LeftWide
    case AV_CHAN_WIDE_RIGHT: return kAudioChannelLabel_RightWide
    case AV_CHAN_LOW_FREQUENCY_2: return kAudioChannelLabel_LFE2
    default: return nil
    }
}

/// A serialized AudioChannelLayout for the resampler's output order: the well
/// known tags where one exists, per-channel descriptions everywhere CoreAudio
/// can name every channel, and the discrete tag as the last resort.
func makeAudioChannelLayoutData(channels: Int32) -> Data {
    var tagged = AudioChannelLayout()
    switch channels {
    case 1: tagged.mChannelLayoutTag = kAudioChannelLayoutTag_Mono
    case 2: tagged.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
    // swresample's default 5.1 order is L R C LFE Ls Rs, which is what
    // CoreAudio calls MPEG_5_1_A
    case 6: tagged.mChannelLayoutTag = kAudioChannelLayoutTag_MPEG_5_1_A
    default:
        guard let labels = coreAudioChannelLabels(defaultLayoutFor: channels) else {
            tagged.mChannelLayoutTag = kAudioChannelLayoutTag_DiscreteInOrder
                | UInt32(channels)
            break
        }
        let descriptionsOffset = MemoryLayout<AudioChannelLayout>
            .offset(of: \.mChannelDescriptions)!
        var data = Data(
            count: descriptionsOffset
                + labels.count * MemoryLayout<AudioChannelDescription>.stride
        )
        data.withUnsafeMutableBytes { raw in
            let layout = raw.baseAddress!.assumingMemoryBound(to: AudioChannelLayout.self)
            layout.pointee.mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions
            layout.pointee.mNumberChannelDescriptions = UInt32(labels.count)
            let descriptions = raw.baseAddress!.advanced(by: descriptionsOffset)
                .assumingMemoryBound(to: AudioChannelDescription.self)
            for (index, label) in labels.enumerated() {
                descriptions[index] = AudioChannelDescription(
                    mChannelLabel: label, mChannelFlags: AudioChannelFlags(),
                    mCoordinates: (0, 0, 0)
                )
            }
        }
        return data
    }
    return withUnsafeBytes(of: tagged) { Data($0) }
}

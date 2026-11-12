import Accelerate
import CFFmpeg
import CoreMedia
import CoreVideo
import Foundation

public enum SoftwareDecodeError: Error, Equatable {
    case decoderUnavailable(String)
    case allocationFailed
    case openFailed(Int32)
    case decodeFailed(Int32)
    case poolCreationFailed
    case sampleBufferFailed(OSStatus)
    /// The copy-out path was handed a frame its planes cannot be copied from:
    /// a bit depth or chroma layout the pooled buffers do not share. Refused
    /// loudly rather than copied silently into wrong pixels.
    case unsupportedPixelFormat
}

/// FFmpeg software decode straight into IOSurface-backed pixel buffers: the
/// frame the codec writes is the frame the display layer presents.
/// `get_buffer2` hands FFmpeg planes inside a pooled `CVPixelBuffer` whose
/// bytes-per-row satisfy FFmpeg's alignment; a format, dimension or stride
/// this decoder cannot hand out directly falls back to FFmpeg's own allocator
/// and a pool-buffer copy-out, counted rather than silently accepted. Only 8
/// bit 4:2:0 (`AV_PIX_FMT_YUV420P`) is eligible for the zero-copy path: it is
/// the one FFmpeg planar layout with a matching CoreVideo pixel format
/// (`kCVPixelFormatType_420YpCbCr8Planar`) that needs no plane reshuffling.
/// A ten bit track pools `420YpCbCr10BiPlanarVideoRange` instead and always
/// copies: FFmpeg's planar ten bit and CoreVideo's biplanar share no plane
/// layout, so the copy is where the samples shift up and the chroma
/// interleaves. No swscale anywhere, on any path.
///
/// An interlaced 8 bit frame takes neither path: it waits for the frame
/// after it, then is deinterlaced into one picture per field, which is
/// `Deinterlacer`'s own pass over the planes, or woven back into the film
/// frame it carries where `Telecine` finds a 3:2 cadence.
public final class SoftwareVideoDecoder {
    /// `AVCodecContext.get_buffer2` is a plain C function pointer: it cannot
    /// capture Swift state, so everything the callback needs reaches it
    /// through `AVCodecContext.opaque` instead, as this box.
    final class Bridge {
        let pool: PixelBufferPool
        let width: Int32
        let height: Int32
        let supportsDirectRendering: Bool
        /// Only the 8 bit planar pool can back the zero-copy path; checked
        /// before a buffer is ever taken for one.
        let poolPixelFormat: OSType

        private let lock = NSLock()
        private var zeroCopy = 0
        private var copied = 0
        private var deinterlaced = 0
        /// Built from the first pooled buffer and reused for every sample
        /// after it: every buffer in the pool shares attributes, and a fresh
        /// CMVideoFormatDescription per picture is renderer-side validation
        /// work at up to a hundred descriptions a second on the deinterlaced path.
        private var cachedDescription: CMVideoFormatDescription?

        init(
            pool: PixelBufferPool, width: Int32, height: Int32,
            supportsDirectRendering: Bool, poolPixelFormat: OSType
        ) {
            self.pool = pool
            self.width = width
            self.height = height
            self.supportsDirectRendering = supportsDirectRendering
            self.poolPixelFormat = poolPixelFormat
        }

        /// The description for a pooled buffer, created once from the first.
        func formatDescription(for buffer: CVPixelBuffer) -> CMVideoFormatDescription? {
            lock.lock()
            if let cachedDescription {
                lock.unlock()
                return cachedDescription
            }
            lock.unlock()
            var description: CMVideoFormatDescription?
            guard CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault, imageBuffer: buffer,
                formatDescriptionOut: &description
            ) == noErr, let description else { return nil }
            lock.lock()
            cachedDescription = description
            lock.unlock()
            return description
        }

        func countZeroCopy() {
            lock.lock(); zeroCopy += 1; lock.unlock()
        }

        func countCopied() {
            lock.lock(); copied += 1; lock.unlock()
        }

        func countDeinterlaced() {
            lock.lock(); deinterlaced += 1; lock.unlock()
        }

        var counts: (zeroCopy: Int, copied: Int, deinterlaced: Int) {
            lock.lock(); defer { lock.unlock() }
            return (zeroCopy, copied, deinterlaced)
        }
    }

    /// How many buffers the pool keeps warm: the reorder/threading depth a
    /// frame-threaded software decoder can hold at once, plus one in flight
    /// to the sink. Not the ceiling - a paced renderer holds about a second
    /// of pictures and the sample queue another, and a frame this pool
    /// refused is a frame the file loses.
    private static let poolWarmCount = 8

    /// The pictures FFmpeg holds inside the decoder, which the ceiling the
    /// pipeline hands this decoder never described: one per frame thread
    /// decoding at once, plus the reference set the codec predicts from -
    /// 16 slots is the most any codec routed here keeps. Taking them out of
    /// the pipeline's own allowance buys back no memory whatsoever, since a
    /// picture the pool refuses is one FFmpeg allocates for itself and this
    /// decoder then copies out; it only costs the copy.
    private static let pictureSlotsHeldByTheCodec = 16

    private let context: UnsafeMutablePointer<AVCodecContext>
    private let frame: UnsafeMutablePointer<AVFrame>
    /// The interlaced frames the deinterlacer still needs, referenced
    /// rather than copied: the one before the frame whose pictures go out
    /// next, and that frame, which waits for the one after it.
    private let previousFrame: UnsafeMutablePointer<AVFrame>
    private let pendingFrame: UnsafeMutablePointer<AVFrame>
    /// When the pending frame's first field is shown, and for how long a
    /// field is; nil while no frame is pending.
    private var pendingTiming: (time: CMTime, field: CMTime)?
    private var holdsPrevious = false
    private var telecine = Telecine()
    private let packet: UnsafeMutablePointer<AVPacket>
    private let timeBaseNum: Int32
    private let timeBaseDen: Int32
    /// The stream's frame period, for `snappedToFrameGrid`; nil where the
    /// container states no rate.
    private let frameDuration: CMTime?
    /// The first keyframe's time, which the frame grid runs through: kept
    /// across flushes, so a seek does not move the grid.
    private var gridOrigin: CMTime?
    /// The last frame's time, for a frame that arrives with none at all:
    /// it goes one period after it. Cleared by `flush`.
    private var lastPresentationTime: CMTime?
    private let bridge: Bridge
    private let bridgeHandle: Unmanaged<Bridge>
    /// `decode` and `drainAtEndOfStream` both run on the video decode
    /// thread; `flush` is called straight from the demux thread by a seek,
    /// with nothing else serialising it against either. Without this, a
    /// flush landing while the video thread is inside
    /// `avcodec_send_packet`/`avcodec_receive_frame` - whether from `decode`
    /// mid-stream or `drainAtEndOfStream` tearing down - races
    /// `avcodec_flush_buffers` on the same `AVCodecContext` from another
    /// thread - the same shape `AudioDecoder`'s own lock closes.
    private let lock = NSLock()
    /// True from construction and from every flush until a keyframe comes
    /// through: a decoder holding no reference frame cannot decode anything
    /// that refers to one. What this actually turns away is the packet a
    /// seek left in flight - popped before the flush, decoded after it,
    /// against references the flush threw out - which frame threading then
    /// reports as a decode error `thread_count` packets later, long past the
    /// packet that caused it. Nothing is lost either way: those packets
    /// belong to the position the seek left.
    private var needsKeyframe = true

    public var zeroCopyFrames: Int { bridge.counts.zeroCopy }
    public var copiedFrames: Int { bridge.counts.copied }
    /// Interlaced frames that were deinterlaced into two pictures each. 0
    /// for the whole of a progressive film, which is nearly every film.
    public var deinterlacedFrames: Int { bridge.counts.deinterlaced }
    /// What was actually asked of the codec context: `ProcessInfo`'s own
    /// core count, read back rather than assumed, so a test can hold this
    /// decoder to the same number without duplicating that call.
    public let threadCount: Int32

    /// What the pool holds and every picture leaves as; the caller reads it
    /// off `pictureFormat`, which is also what the budget weighed.
    public let pixelFormat: OSType
    /// The tags every picture carries, for the display layer to read it as
    /// more than bare numbers: its colour - a ten bit HDR track above all -
    /// the shape of its pixels and where its chroma sits. Empty for a stream
    /// that tagged nothing.
    private let attachments: [(key: CFString, value: CFTypeRef)]

    /// `poolCeilingBytes` is what the pool may have out at once, from
    /// `PipelineBudget`: everything the pipeline is entitled to hold in
    /// pictures, since every picture in the sample queue came out of this pool
    /// and every one on its way to the renderer is still out of it.
    public init(
        stream: MediaStream,
        pixelFormat: OSType = kCVPixelFormatType_420YpCbCr8Planar,
        threadCount: Int, poolCeilingBytes: Int
    ) throws {
        guard let codec = avcodec_find_decoder(AVCodecID(rawValue: stream.codecID)) else {
            throw SoftwareDecodeError.decoderUnavailable(stream.codecName)
        }
        var allocatedContext = avcodec_alloc_context3(codec)
        var allocatedFrame = av_frame_alloc()
        var allocatedPrevious = av_frame_alloc()
        var allocatedPending = av_frame_alloc()
        var allocatedPacket = av_packet_alloc()
        var kept = false
        // deinit never runs for an init that throws, so every failure below
        // has to give back what was allocated here.
        defer {
            if !kept {
                avcodec_free_context(&allocatedContext)
                av_frame_free(&allocatedFrame)
                av_frame_free(&allocatedPrevious)
                av_frame_free(&allocatedPending)
                av_packet_free(&allocatedPacket)
            }
        }
        guard let context = allocatedContext,
            let frame = allocatedFrame,
            let previousFrame = allocatedPrevious,
            let pendingFrame = allocatedPending,
            let packet = allocatedPacket
        else {
            throw SoftwareDecodeError.allocationFailed
        }
        context.pointee.width = stream.width
        context.pointee.height = stream.height
        let resolvedThreadCount = Int32(max(threadCount, 1))
        context.pointee.thread_count = resolvedThreadCount
        if let extradata = stream.extradata, !extradata.isEmpty {
            // avcodec reads past the end of extradata, so this allocation is
            // oversized by the same padding AudioDecoder gives it.
            guard let bytes = av_mallocz(extradata.count + 64) else {
                throw SoftwareDecodeError.allocationFailed
            }
            extradata.withUnsafeBytes { raw in
                _ = memcpy(bytes, raw.baseAddress!, extradata.count)
            }
            context.pointee.extradata = bytes.assumingMemoryBound(to: UInt8.self)
            context.pointee.extradata_size = Int32(extradata.count)
        }

        // A decoder writing straight into a pool buffer may write up to
        // `avcodec_align_dimensions2`'s size for 4:2:0: width to 16, height to
        // 32 plus 2. The visible picture stays the stream's own.
        let padding: [String: Any] = pixelFormat == kCVPixelFormatType_420YpCbCr8Planar
            ? [
                kCVPixelBufferExtendedPixelsRightKey as String:
                    (Int(stream.width) + 15) / 16 * 16 - Int(stream.width),
                kCVPixelBufferExtendedPixelsBottomKey as String:
                    (Int(stream.height) + 31) / 32 * 32 + 2 - Int(stream.height),
            ]
            : [:]
        guard let pool = try? PixelBufferPool(
            width: stream.width, height: stream.height,
            pixelFormat: pixelFormat,
            warmCount: SoftwareVideoDecoder.poolWarmCount,
            ceilingBytes: poolCeilingBytes,
            reserveBuffers: Int(resolvedThreadCount) + SoftwareVideoDecoder.pictureSlotsHeldByTheCodec,
            rendererAttributes: padding
        ) else {
            throw SoftwareDecodeError.poolCreationFailed
        }
        let bridge = Bridge(
            pool: pool, width: stream.width, height: stream.height,
            supportsDirectRendering: codec.pointee.capabilities & AV_CODEC_CAP_DR1 != 0,
            poolPixelFormat: pixelFormat
        )
        let handle = Unmanaged.passRetained(bridge)
        context.pointee.opaque = handle.toOpaque()
        context.pointee.get_buffer2 = lexisSoftwareGetBuffer2

        let code = avcodec_open2(context, codec, nil)
        guard code >= 0 else {
            handle.release()
            throw SoftwareDecodeError.openFailed(code)
        }

        self.context = context
        self.frame = frame
        self.previousFrame = previousFrame
        self.pendingFrame = pendingFrame
        self.packet = packet
        self.bridge = bridge
        bridgeHandle = handle
        self.threadCount = resolvedThreadCount
        self.pixelFormat = pixelFormat
        var attachments: [(key: CFString, value: CFTypeRef)] = []
        if let primaries = colorPrimariesName(stream.colorPrimaries) {
            attachments.append((kCVImageBufferColorPrimariesKey, primaries))
        }
        if let transfer = transferFunctionName(stream.colorTransfer) {
            attachments.append((kCVImageBufferTransferFunctionKey, transfer))
        }
        if let matrix = yCbCrMatrixName(stream.colorMatrix) {
            attachments.append((kCVImageBufferYCbCrMatrixKey, matrix))
        }
        if let pixelAspect = pixelAspectRatio(of: stream) {
            attachments.append((kCVImageBufferPixelAspectRatioKey, pixelAspect))
        }
        if let location = chromaLocationName(stream.chromaLocation) {
            attachments.append((kCVImageBufferChromaLocationTopFieldKey, location))
            attachments.append((kCVImageBufferChromaLocationBottomFieldKey, location))
        }
        self.attachments = attachments
        timeBaseNum = stream.timeBaseNum
        timeBaseDen = stream.timeBaseDen
        frameDuration = stream.frameRateNum > 0 && stream.frameRateDen > 0
            ? CMTime(value: Int64(stream.frameRateDen), timescale: stream.frameRateNum)
            : nil
        kept = true
    }

    deinit {
        var frame: UnsafeMutablePointer<AVFrame>? = self.frame
        av_frame_free(&frame)
        var previousFrame: UnsafeMutablePointer<AVFrame>? = self.previousFrame
        av_frame_free(&previousFrame)
        var pendingFrame: UnsafeMutablePointer<AVFrame>? = self.pendingFrame
        av_frame_free(&pendingFrame)
        var packet: UnsafeMutablePointer<AVPacket>? = self.packet
        av_packet_free(&packet)
        var context: UnsafeMutablePointer<AVCodecContext>? = self.context
        avcodec_free_context(&context)
        bridgeHandle.release()
    }

    /// What this packet produced, in decode order. An empty array is normal:
    /// a frame-threaded decoder may take several packets before its first
    /// frame comes back.
    public func decode(_ input: Packet) throws -> [CMSampleBuffer] {
        guard input.byteCount > 0 else { return [] }
        lock.lock()
        defer { lock.unlock() }
        if input.isKeyframe { needsKeyframe = false }
        guard !needsKeyframe else { return [] }
        var buffers: [CMSampleBuffer] = []
        av_packet_unref(packet)
        // The buffer alone, shared: it already carries avcodec's padding, and the
        // source's side data and flags (skip samples, discard) would move sync.
        guard let source = input.buffer?.packet.pointee else { throw SoftwareDecodeError.allocationFailed }
        if let shared = source.buf {
            guard let reference = av_buffer_ref(shared) else { throw SoftwareDecodeError.allocationFailed }
            packet.pointee.buf = reference
        }
        packet.pointee.data = source.data
        packet.pointee.size = source.size
        packet.pointee.duration = source.duration
        packet.pointee.pts = input.pts ?? LexisNoPTS
        packet.pointee.dts = input.dts ?? LexisNoPTS
        let sent = avcodec_send_packet(context, packet)
        av_packet_unref(packet)
        guard sent >= 0 || sent == LexisErrorAgain else {
            throw SoftwareDecodeError.decodeFailed(sent)
        }
        while avcodec_receive_frame(context, frame) >= 0 {
            defer { av_frame_unref(frame) }
            try appendPictures(to: &buffers)
        }
        return buffers
    }

    public func flush() {
        lock.lock()
        defer { lock.unlock() }
        avcodec_flush_buffers(context)
        needsKeyframe = true
        lastPresentationTime = nil
        forgetFields()
    }

    /// Hands back the pictures the pool is only keeping for reuse. The
    /// codec's own reference frames are pool buffers that are still out, so
    /// this takes nothing the decoder is using.
    public func releaseSpareBuffers() {
        bridge.pool.releaseSpareBuffers()
    }

    /// The end of the stream, where there is nothing left to feed the
    /// decoder: enters draining mode and takes back every frame a
    /// frame-threaded decode was still holding.
    public func drainAtEndOfStream() throws -> [CMSampleBuffer] {
        lock.lock()
        defer { lock.unlock() }
        let sent = avcodec_send_packet(context, nil)
        guard sent >= 0 || sent == LexisErrorEOF else {
            throw SoftwareDecodeError.decodeFailed(sent)
        }
        var buffers: [CMSampleBuffer] = []
        while avcodec_receive_frame(context, frame) >= 0 {
            defer { av_frame_unref(frame) }
            try appendPictures(to: &buffers)
        }
        try appendPendingFields(to: &buffers)
        return buffers
    }

    /// What the frame this decoder is holding puts on screen: one picture,
    /// or - for an interlaced frame alone, once the frame after it is here -
    /// one per field, half a frame apart, or the film frame it carries.
    /// `inout` rather than a returned array so the ordinary case allocates
    /// nothing it did not already.
    private func appendPictures(to buffers: inout [CMSampleBuffer]) throws {
        // MPEG-2 in TS or VOB leaves `pts` unset on some frames; a sample
        // with no time is shown at once and breaks the runway reading.
        let pts = frame.pointee.pts != LexisNoPTS ? frame.pointee.pts : frame.pointee.best_effort_timestamp
        var presentationTime = CMTime.invalid
        if pts != LexisNoPTS {
            let time = CMTimeMultiplyByRatio(
                CMTime(value: pts, timescale: timeBaseDen), multiplier: timeBaseNum, divisor: 1
            )
            if gridOrigin == nil, frame.pointee.flags & AV_FRAME_FLAG_KEY != 0 {
                gridOrigin = time
            }
            presentationTime = snappedToFrameGrid(
                time, frameDuration: frameDuration,
                tolerance: CMTime(value: Int64(timeBaseNum), timescale: timeBaseDen),
                origin: gridOrigin ?? .zero
            )
        } else if let lastPresentationTime, let frameDuration {
            presentationTime = lastPresentationTime + frameDuration
        }
        if presentationTime.isValid { lastPresentationTime = presentationTime }
        // The deinterlacer walks planes byte-wise, which only reads 8 bit
        // planar correctly; an interlaced frame in any other layout goes up
        // woven, comb and all, rather than through arithmetic that would
        // shear its 16 bit samples.
        guard frame.pointee.flags & AV_FRAME_FLAG_INTERLACED != 0,
            frame.pointee.format == AV_PIX_FMT_YUV420P.rawValue
        else {
            // the run of fields ends here, its last frame first
            try appendPendingFields(to: &buffers)
            let pixelBuffer: CVPixelBuffer
            if let opaque = frame.pointee.opaque {
                // Set by lexisSoftwareGetBuffer2: this frame already IS the
                // pool buffer, zero copy from decode to the screen.
                // Unretained: the frame's own AVBufferRef holds it up to
                // here, and the sample buffer built below takes its own
                // reference before this frame is unreferenced.
                pixelBuffer = Unmanaged<CVPixelBuffer>.fromOpaque(opaque).takeUnretainedValue()
                bridge.countZeroCopy()
            } else {
                pixelBuffer = try copyOutPixelBuffer()
                bridge.countCopied()
            }
            buffers.append(try makeSampleBuffer(pixelBuffer, at: presentationTime))
            return
        }

        if pendingTiming != nil {
            try appendFields(next: frame, to: &buffers)
            av_frame_unref(previousFrame)
            av_frame_move_ref(previousFrame, pendingFrame)
            holdsPrevious = true
        }
        guard av_frame_ref(pendingFrame, frame) >= 0 else { throw SoftwareDecodeError.allocationFailed }
        pendingTiming = (presentationTime, halfFrame())
    }

    /// The pending frame's pictures with no frame after it, the end of a
    /// run of fields, which the next one starts over from.
    private func appendPendingFields(to buffers: inout [CMSampleBuffer]) throws {
        guard pendingTiming != nil else { return }
        defer { forgetFields() }
        try appendFields(next: pendingFrame, to: &buffers)
    }

    private func forgetFields() {
        av_frame_unref(previousFrame)
        av_frame_unref(pendingFrame)
        holdsPrevious = false
        pendingTiming = nil
        telecine.reset()
    }

    /// The pending frame's pictures, `next` the frame shown after it: its
    /// two fields built up half a frame apart, or the film frame it carries.
    /// Displayed first or second is the frame's own business: a container
    /// may carry both orders, and showing them the wrong way round is the
    /// jerk-back on motion that looks worse than the comb did.
    private func appendFields(next: UnsafeMutablePointer<AVFrame>, to buffers: inout [CMSampleBuffer]) throws {
        guard let timing = pendingTiming else { return }
        let current = pendingFrame
        let previous = holdsPrevious ? previousFrame : pendingFrame
        let first: VideoField = current.pointee.flags & AV_FRAME_FLAG_TOP_FIELD_FIRST != 0 ? .top : .bottom
        let width = Int(current.pointee.width), height = Int(current.pointee.height)
        let luma = planeRows(current, 0)
        let picture = telecine.picture(
            ownComb: Deinterlacer.combing(current: luma, other: luma, widthBytes: width, height: height, field: first),
            previousComb: Deinterlacer.combing(
                current: luma, other: planeRows(previous, 0), widthBytes: width, height: height, field: first),
            samples: width * height / 2)
        switch picture {
        case .fields:
            for field in [first, first == .top ? .bottom : .top] {
                let built = try makePicture(of: current) { plane, destination, stride, widthBytes, planeHeight in
                    Deinterlacer.deinterlacePlane(
                        previous: planeRows(previous, plane), current: planeRows(current, plane),
                        next: planeRows(next, plane), destination: destination, destinationStride: stride,
                        widthBytes: widthBytes, height: planeHeight, field: field, second: field != first)
                }
                buffers.append(try makeSampleBuffer(built, at: field == first ? timing.time : timing.time + timing.field))
            }
            bridge.countDeinterlaced()
        case .film(let weavesPrevious, let early):
            let other = weavesPrevious ? previous : current
            let built = try makePicture(of: current) { plane, destination, stride, widthBytes, planeHeight in
                Deinterlacer.weavePlane(
                    current: planeRows(current, plane), other: planeRows(other, plane), destination: destination,
                    destinationStride: stride, widthBytes: widthBytes, height: planeHeight, field: first)
            }
            buffers.append(try makeSampleBuffer(built, at: early ? timing.time - timing.field : timing.time))
        case .repeated:
            break
        }
    }

    /// Half this frame's own duration, in the stream's time base, or half the
    /// stream's frame period where the container gave the frame none. Zero
    /// only when neither is known: the second field then lands on the first
    /// one's time and the renderer never shows it.
    private func halfFrame() -> CMTime {
        let duration = frame.pointee.duration
        guard duration > 0 else {
            return frameDuration.map { CMTimeMultiplyByRatio($0, multiplier: 1, divisor: 2) } ?? .zero
        }
        return CMTimeMultiplyByRatio(
            CMTime(value: duration, timescale: timeBaseDen), multiplier: timeBaseNum, divisor: 2
        )
    }

    /// A pool picture the size of `source`, each plane written by `build`
    /// from its index, where its rows go and how far apart they are, and
    /// its width in bytes and its height.
    private func makePicture(
        of source: UnsafeMutablePointer<AVFrame>,
        _ build: (Int, UnsafeMutablePointer<UInt8>, Int, Int, Int) -> Void
    ) throws -> CVPixelBuffer {
        guard let buffer = bridge.pool.take() ?? bridge.pool.takeBeyondCapacity() else {
            throw SoftwareDecodeError.poolCreationFailed
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let width = Int(source.pointee.width), height = Int(source.pointee.height)
        for plane in 0..<min(CVPixelBufferGetPlaneCount(buffer), 3) {
            guard let destination = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { continue }
            build(
                plane, destination.assumingMemoryBound(to: UInt8.self), CVPixelBufferGetBytesPerRowOfPlane(buffer, plane),
                plane == 0 ? width : (width + 1) / 2, plane == 0 ? height : (height + 1) / 2)
        }
        return buffer
    }

    private func makeSampleBuffer(
        _ pixelBuffer: CVPixelBuffer, at presentationTime: CMTime
    ) throws -> CMSampleBuffer {
        // Set on every picture, whichever route made it: the description is
        // built from the first one's, and a pooled buffer keeps what it last
        // carried.
        for (key, value) in attachments {
            CVBufferSetAttachment(pixelBuffer, key, value, .shouldPropagate)
        }
        guard let description = bridge.formatDescription(for: pixelBuffer) else {
            throw SoftwareDecodeError.sampleBufferFailed(kCMSampleBufferError_AllocationFailed)
        }
        var timing = CMSampleTimingInfo(
            duration: .invalid, presentationTimeStamp: presentationTime, decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: description,
            sampleTiming: &timing, sampleBufferOut: &sample
        ) == noErr, let sample else {
            throw SoftwareDecodeError.sampleBufferFailed(kCMSampleBufferError_AllocationFailed)
        }
        return sample
    }

    /// The frame's planes paired with `buffer`'s, for the planes both have.
    /// `buffer` must already be locked by the caller.
    private func forEachPlane(
        of buffer: CVPixelBuffer,
        _ body: (Int, UnsafePointer<UInt8>, Int, UnsafeMutablePointer<UInt8>, Int) -> Void
    ) {
        let sourcePlanes: [UnsafeMutablePointer<UInt8>?] = [
            frame.pointee.data.0, frame.pointee.data.1, frame.pointee.data.2,
        ]
        let sourceStrides: [Int] = [
            Int(frame.pointee.linesize.0), Int(frame.pointee.linesize.1), Int(frame.pointee.linesize.2),
        ]
        for plane in 0..<min(CVPixelBufferGetPlaneCount(buffer), sourcePlanes.count) {
            guard let source = sourcePlanes[plane],
                let destination = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)
            else { continue }
            body(
                plane, source, sourceStrides[plane],
                destination.assumingMemoryBound(to: UInt8.self),
                CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            )
        }
    }

    /// The exception path for an 8 bit track - a dimension or stride
    /// get_buffer2 could not hand FFmpeg directly - and the only path for a
    /// ten bit one. Anything else would land samples reshaped into wrong
    /// pixels and count as delivered, so it is refused loudly instead.
    private func copyOutPixelBuffer() throws -> CVPixelBuffer {
        let eightBit = frame.pointee.format == AV_PIX_FMT_YUV420P.rawValue
            && pixelFormat == kCVPixelFormatType_420YpCbCr8Planar
        let tenBit = frame.pointee.format == AV_PIX_FMT_YUV420P10LE.rawValue
            && pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        // an eight bit track for a path that maps pictures, which reads ten
        let widened = frame.pointee.format == AV_PIX_FMT_YUV420P.rawValue
            && pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        guard eightBit || tenBit || widened else {
            throw SoftwareDecodeError.unsupportedPixelFormat
        }
        guard let buffer = bridge.pool.take() ?? bridge.pool.takeBeyondCapacity() else {
            throw SoftwareDecodeError.poolCreationFailed
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        if tenBit {
            copyOutTenBit(into: buffer)
            return buffer
        }
        if widened {
            copyOutWidened(into: buffer)
            return buffer
        }
        forEachPlane(of: buffer) { plane, source, sourceStride, destination, destinationStride in
            let rowBytes = min(sourceStride, destinationStride)
            let planeHeight = plane == 0
                ? Int(frame.pointee.height) : (Int(frame.pointee.height) + 1) / 2
            var sourceBuffer = vImage_Buffer(
                data: UnsafeMutableRawPointer(mutating: source),
                height: vImagePixelCount(planeHeight),
                width: vImagePixelCount(rowBytes), rowBytes: sourceStride
            )
            var destinationBuffer = vImage_Buffer(
                data: destination, height: vImagePixelCount(planeHeight),
                width: vImagePixelCount(rowBytes), rowBytes: destinationStride
            )
            vImageCopyBuffer(&sourceBuffer, &destinationBuffer, 1, vImage_Flags(kvImageNoFlags))
        }
        return buffer
    }

    /// Planar ten bit into biplanar: the copy is where each sample shifts
    /// from the low ten bits FFmpeg fills to the high ten CoreVideo reads,
    /// and where Cb and Cr interleave into the one chroma plane. `buffer`
    /// must already be locked by the caller.
    private func copyOutTenBit(into buffer: CVPixelBuffer) {
        let width = Int(frame.pointee.width)
        let height = Int(frame.pointee.height)
        guard let lumaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
            let chromaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1),
            let sourceLuma = frame.pointee.data.0,
            let sourceCb = frame.pointee.data.1,
            let sourceCr = frame.pointee.data.2
        else { return }
        let luma = lumaBase.assumingMemoryBound(to: UInt16.self)
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) / 2
        let sourceLumaStride = Int(frame.pointee.linesize.0) / 2
        // In bands across the cores: at 4K this is 25 MB a picture, and the
        // thread it runs on is the one feeding the codec's own threads.
        let bands = 8
        sourceLuma.withMemoryRebound(to: UInt16.self, capacity: sourceLumaStride * height) { source in
            DispatchQueue.concurrentPerform(iterations: bands) { band in
                for row in stride(from: band * height / bands, to: (band + 1) * height / bands, by: 1) {
                    shiftRowUp(
                        source + row * sourceLumaStride, into: luma + row * lumaStride, count: width
                    )
                }
            }
        }
        let chroma = chromaBase.assumingMemoryBound(to: UInt16.self)
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) / 2
        let chromaWidth = (width + 1) / 2
        let chromaHeight = (height + 1) / 2
        let cbStride = Int(frame.pointee.linesize.1) / 2
        let crStride = Int(frame.pointee.linesize.2) / 2
        sourceCb.withMemoryRebound(to: UInt16.self, capacity: cbStride * chromaHeight) { cb in
            sourceCr.withMemoryRebound(to: UInt16.self, capacity: crStride * chromaHeight) { cr in
                DispatchQueue.concurrentPerform(iterations: bands) { band in
                    for row in stride(from: band * chromaHeight / bands, to: (band + 1) * chromaHeight / bands, by: 1) {
                        interleaveRowShiftedUp(
                            cb + row * cbStride, cr + row * crStride,
                            into: chroma + row * chromaStride, count: chromaWidth
                        )
                    }
                }
            }
        }
    }
}

extension SoftwareVideoDecoder {
    /// Planar eight bit into biplanar ten: each code in the top eight of the
    /// sixteen bits, which is the ten bit code four times it, and Cb and Cr
    /// interleaved. `buffer` must already be locked by the caller.
    fileprivate func copyOutWidened(into buffer: CVPixelBuffer) {
        let width = Int(frame.pointee.width)
        let height = Int(frame.pointee.height)
        guard let lumaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
            let chromaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1),
            let sourceLuma = frame.pointee.data.0,
            let sourceCb = frame.pointee.data.1,
            let sourceCr = frame.pointee.data.2
        else { return }
        let luma = lumaBase.assumingMemoryBound(to: UInt16.self)
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) / 2
        let sourceLumaStride = Int(frame.pointee.linesize.0)
        let bands = 8
        DispatchQueue.concurrentPerform(iterations: bands) { band in
            for row in stride(from: band * height / bands, to: (band + 1) * height / bands, by: 1) {
                widenRow(sourceLuma + row * sourceLumaStride, into: luma + row * lumaStride, count: width)
            }
        }
        let chroma = chromaBase.assumingMemoryBound(to: UInt16.self)
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) / 2
        let chromaWidth = (width + 1) / 2
        let chromaHeight = (height + 1) / 2
        let cbStride = Int(frame.pointee.linesize.1)
        let crStride = Int(frame.pointee.linesize.2)
        DispatchQueue.concurrentPerform(iterations: bands) { band in
            for row in stride(from: band * chromaHeight / bands, to: (band + 1) * chromaHeight / bands, by: 1) {
                interleaveRowWidened(
                    sourceCb + row * cbStride, sourceCr + row * crStride,
                    into: chroma + row * chromaStride, count: chromaWidth)
            }
        }
    }
}

/// One row of eight bit samples widened to the top of sixteen bits, eight at
/// a time.
@inline(__always)
private func widenRow(_ source: UnsafePointer<UInt8>, into out: UnsafeMutablePointer<UInt16>, count: Int) {
    var index = 0
    let vectorEnd = count & ~7
    while index < vectorEnd {
        let samples = UnsafeRawPointer(source + index).loadUnaligned(as: SIMD8<UInt8>.self)
        UnsafeMutableRawPointer(out + index).storeBytes(
            of: SIMD8<UInt16>(truncatingIfNeeded: samples) &<< 8, as: SIMD8<UInt16>.self)
        index += 8
    }
    while index < count {
        out[index] = UInt16(source[index]) &<< 8
        index += 1
    }
}

/// One row of eight bit Cb and one of Cr widened and interleaved into CbCr
/// pairs, as `interleaveRowShiftedUp` does for ten bit ones.
@inline(__always)
private func interleaveRowWidened(
    _ cb: UnsafePointer<UInt8>, _ cr: UnsafePointer<UInt8>,
    into out: UnsafeMutablePointer<UInt16>, count: Int
) {
    var index = 0
    let vectorEnd = count & ~7
    while index < vectorEnd {
        let cbSamples = SIMD8<UInt16>(truncatingIfNeeded: UnsafeRawPointer(cb + index).loadUnaligned(as: SIMD8<UInt8>.self)) &<< 8
        let crSamples = SIMD8<UInt16>(truncatingIfNeeded: UnsafeRawPointer(cr + index).loadUnaligned(as: SIMD8<UInt8>.self)) &<< 8
        let pairs = SIMD8<UInt32>(truncatingIfNeeded: cbSamples)
            | SIMD8<UInt32>(truncatingIfNeeded: crSamples) &<< 16
        UnsafeMutableRawPointer(out + index * 2).storeBytes(of: pairs, as: SIMD8<UInt32>.self)
        index += 8
    }
    while index < count {
        out[index * 2] = UInt16(cb[index]) &<< 8
        out[index * 2 + 1] = UInt16(cr[index]) &<< 8
        index += 1
    }
}

/// One row of ten bit samples moved to the top of their sixteen bits, eight
/// at a time.
@inline(__always)
private func shiftRowUp(
    _ source: UnsafePointer<UInt16>, into out: UnsafeMutablePointer<UInt16>, count: Int
) {
    var index = 0
    let vectorEnd = count & ~7
    while index < vectorEnd {
        let samples = UnsafeRawPointer(source + index).loadUnaligned(as: SIMD8<UInt16>.self)
        UnsafeMutableRawPointer(out + index).storeBytes(of: samples &<< 6, as: SIMD8<UInt16>.self)
        index += 8
    }
    while index < count {
        out[index] = source[index] &<< 6
        index += 1
    }
}

/// One row of Cb and one of Cr shifted up and interleaved into CbCr pairs,
/// eight pairs at a time. Each pair is one little-endian 32 bit lane, Cb in
/// its low half, which is the interleave without a shuffle.
@inline(__always)
private func interleaveRowShiftedUp(
    _ cb: UnsafePointer<UInt16>, _ cr: UnsafePointer<UInt16>,
    into out: UnsafeMutablePointer<UInt16>, count: Int
) {
    var index = 0
    let vectorEnd = count & ~7
    while index < vectorEnd {
        let cbSamples = UnsafeRawPointer(cb + index).loadUnaligned(as: SIMD8<UInt16>.self) &<< 6
        let crSamples = UnsafeRawPointer(cr + index).loadUnaligned(as: SIMD8<UInt16>.self) &<< 6
        let pairs = SIMD8<UInt32>(truncatingIfNeeded: cbSamples)
            | SIMD8<UInt32>(truncatingIfNeeded: crSamples) &<< 16
        UnsafeMutableRawPointer(out + index * 2).storeBytes(of: pairs, as: SIMD8<UInt32>.self)
        index += 8
    }
    while index < count {
        out[index * 2] = cb[index] &<< 6
        out[index * 2 + 1] = cr[index] &<< 6
        index += 1
    }
}

/// `AVCodecContext.get_buffer2` is a plain C function pointer: it cannot
/// capture Swift state, so it reaches this decoder's pool through
/// `context->opaque` instead of a closure. Only an 8 bit 4:2:0 frame at the
/// stream's own dimensions, decoded by a codec that supports direct
/// rendering (`AV_CODEC_CAP_DR1`), is eligible; anything else falls back to
/// FFmpeg's own allocator, which `makeSampleBuffer`'s copy-out path counts.
private func lexisSoftwareGetBuffer2(
    _ context: UnsafeMutablePointer<AVCodecContext>?,
    _ frame: UnsafeMutablePointer<AVFrame>?,
    _ flags: Int32
) -> Int32 {
    guard let context, let frame, let opaque = context.pointee.opaque else {
        return avcodec_default_get_buffer2(context, frame, flags)
    }
    let bridge = Unmanaged<SoftwareVideoDecoder.Bridge>.fromOpaque(opaque).takeUnretainedValue()
    guard bridge.supportsDirectRendering,
        bridge.poolPixelFormat == kCVPixelFormatType_420YpCbCr8Planar,
        frame.pointee.format == AV_PIX_FMT_YUV420P.rawValue,
        frame.pointee.width == bridge.width, frame.pointee.height == bridge.height,
        let buffer = bridge.pool.take()
    else {
        return avcodec_default_get_buffer2(context, frame, flags)
    }
    CVPixelBufferLockBaseAddress(buffer, [])
    guard CVPixelBufferGetPlaneCount(buffer) == 3 else {
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return avcodec_default_get_buffer2(context, frame, flags)
    }
    var alignedWidth = frame.pointee.width
    var alignedHeight = frame.pointee.height
    var linesizeAlign = (Int32(0), Int32(0), Int32(0), Int32(0), Int32(0), Int32(0), Int32(0), Int32(0))
    withUnsafeMutablePointer(to: &linesizeAlign) {
        $0.withMemoryRebound(to: Int32.self, capacity: 8) {
            avcodec_align_dimensions2(context, &alignedWidth, &alignedHeight, $0)
        }
    }
    // FFmpeg's contract for get_buffer2: the planes cover the aligned size, not
    // only the visible one, or the decoder writes past the end of them.
    var extendedLeft = 0, extendedRight = 0, extendedTop = 0, extendedBottom = 0
    CVPixelBufferGetExtendedPixels(buffer, &extendedLeft, &extendedRight, &extendedTop, &extendedBottom)
    guard CVPixelBufferGetHeight(buffer) + extendedBottom >= Int(alignedHeight),
        CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) >= Int(alignedWidth)
    else {
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return avcodec_default_get_buffer2(context, frame, flags)
    }
    let planeAlign = [linesizeAlign.0, linesizeAlign.1, linesizeAlign.2]
    for plane in 0..<3 {
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
        let align = Int(planeAlign[plane])
        guard align == 0 || stride % align == 0,
            let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)
        else {
            CVPixelBufferUnlockBaseAddress(buffer, [])
            return avcodec_default_get_buffer2(context, frame, flags)
        }
        switch plane {
        case 0: frame.pointee.data.0 = base.assumingMemoryBound(to: UInt8.self)
        case 1: frame.pointee.data.1 = base.assumingMemoryBound(to: UInt8.self)
        default: frame.pointee.data.2 = base.assumingMemoryBound(to: UInt8.self)
        }
        switch plane {
        case 0: frame.pointee.linesize.0 = Int32(stride)
        case 1: frame.pointee.linesize.1 = Int32(stride)
        default: frame.pointee.linesize.2 = Int32(stride)
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])

    // extended_data must point to data for a plane count this small - see
    // AVCodecContext.get_buffer2's own doc comment.
    withUnsafeMutablePointer(to: &frame.pointee.data) {
        $0.withMemoryRebound(to: UnsafeMutablePointer<UInt8>?.self, capacity: 8) {
            frame.pointee.extended_data = $0
        }
    }

    guard let dataPointer = frame.pointee.data.0 else {
        return avcodec_default_get_buffer2(context, frame, flags)
    }
    // One retain, and FFmpeg's own AVBufferRef owns it until every internal
    // reference to this picture - this frame's own and any it keeps for
    // prediction - is gone. `frame.opaque` is the same address unretained,
    // a marker saying this picture already lives in a pool buffer; a second
    // retain there would only ever be balanced by a picture that comes back
    // out, and the ones a flush discards never do - each one a pool buffer
    // the film never gets back.
    let bufferRefOpaque = Unmanaged.passRetained(buffer).toOpaque()
    guard let bufferRef = av_buffer_create(
        dataPointer, CVPixelBufferGetDataSize(buffer), lexisReleasePooledPixelBuffer, bufferRefOpaque, 0
    ) else {
        Unmanaged<CVPixelBuffer>.fromOpaque(bufferRefOpaque).release()
        return avcodec_default_get_buffer2(context, frame, flags)
    }
    frame.pointee.buf.0 = bufferRef
    frame.pointee.opaque = bufferRefOpaque
    return 0
}

/// `av_buffer_create`'s free callback: releases the manual retain
/// `lexisSoftwareGetBuffer2` took for FFmpeg's own reference to this buffer.
private func lexisReleasePooledPixelBuffer(
    _ opaque: UnsafeMutableRawPointer?, _ data: UnsafeMutablePointer<UInt8>?
) {
    guard let opaque else { return }
    Unmanaged<CVPixelBuffer>.fromOpaque(opaque).release()
}

/// One of an eight bit planar frame's three planes, wherever FFmpeg put it.
private func planeRows(_ frame: UnsafeMutablePointer<AVFrame>, _ plane: Int) -> PlaneRows {
    let data = plane == 0 ? frame.pointee.data.0 : plane == 1 ? frame.pointee.data.1 : frame.pointee.data.2
    let stride = plane == 0 ? frame.pointee.linesize.0 : plane == 1 ? frame.pointee.linesize.1 : frame.pointee.linesize.2
    return PlaneRows(base: UnsafePointer(data!), stride: Int(stride))
}

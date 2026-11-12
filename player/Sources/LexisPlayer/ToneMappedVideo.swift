import CoreMedia
import CoreVideo
import Foundation
import simd

/// The video path taken when the display cannot show the picture as it is:
/// decode, process the frame onto what the screen has, and hand back a
/// picture instead of a packet. Nothing else in the player changes, because
/// a sink takes a CMSampleBuffer either way.
///
/// Two processors ride this same machinery: the tone map kernel, for a
/// transfer the screen cannot show, and the upscaler, for a small
/// SDR picture on a screen with far more pixels. Everything around them -
/// the decoder, the reorder window, the flush and drain rules - is shared.
public final class ToneMappedVideo {
    /// What one processed picture is stored as, which the screen decides and
    /// the budget has to weigh a picture in.
    public let pixelFormat: OSType
    /// Whether the pictures carry light above SDR white, or are the HDR
    /// picture itself: what the sink is told to show them as.
    public let extendedRange: Bool

    private enum Processor {
        case toneMap(ToneMapper)
        /// A small SDR film, faithfully: the decoder's own picture scaled.
        case upscale(Upscaler)
        /// An interlaced film: its fields built up at its own size.
        case enhance(PictureEnhancer)
        /// A small interlaced film: its fields built up, then scaled.
        case enhanceThenUpscale(PictureEnhancer, Upscaler)
        /// No pass at all: the decoder's own picture is what goes up, with
        /// the stream's HDR metadata attached where the decoder left it off.
        case untouched(hdrAttachments: [(key: CFString, value: CFTypeRef)])
    }

    private let processor: Processor
    /// The shape of the stream's pixels, from its description, set on every
    /// picture handed over: a processed picture carries only what a pass
    /// gave it, and a non-square pixel drawn square squeezes the film.
    private let pixelAspect: CFTypeRef?
    /// What the scaled pictures measure, nil where nothing scales them.
    public let upscaledSize: (width: Int32, height: Int32)?
    /// Set, each frame the decoder hands back is split into its two fields,
    /// two pictures half a frame apart, or folded back into the film frame
    /// a 3:2 pulldown carries. Only the enhancer builds a field up.
    private let fields: FieldOrder?

    /// The GPU passes each picture goes through before it is handed on,
    /// which is how many a submitter has to let be in flight at once.
    public var passesPerPicture: Int {
        switch processor {
        case .untouched: 0
        case .enhance: fields == nil ? 1 : 2
        case .enhanceThenUpscale: fields == nil ? 2 : 4
        case .toneMap, .upscale: 1
        }
    }

    /// How many pictures one decoded frame is counted as: two for its
    /// fields, of which a telecined film frame folds one or both away.
    public var picturesPerFrame: Int { fields == nil ? 1 : 2 }

    /// An interlaced stream's frames waiting for their turn through the
    /// enhancer, in no order. A field is built between the frames either
    /// side of it and a 3:2 cadence read across them, which needs the frames
    /// in the order they are shown, and VideoToolbox hands them back in the
    /// order they were decoded: each frame waits, ahead of its pass, for
    /// `window` later ones to come back, and its pictures leave the pass in
    /// order. Under `lock`.
    private var waiting: [DecodedFrame] = []
    /// The frame the fields went through last, which the next one's are
    /// built against, and the cadence read so far. Under `mapping`.
    private var previousFrame: CVPixelBuffer?
    private var telecine = Telecine()

    private let enqueue: (CMSampleBuffer) -> Void
    /// What a frame no RPU describes is mapped with: the mastering display's
    /// peak and the BT.2020 constants, onto what the screen has.
    private let staticParameters: ToneMapParameters
    private var decoder: VideoDecoder?
    /// How many pictures are held back. VideoToolbox hands frames back in
    /// decode order and a renderer shows a picture at the time it carries, so
    /// the stream's reorder depth is what it takes to put them back in order,
    /// capped at what a picture of this size can afford. An interlaced
    /// stream's frames are held back ahead of the pass instead, `waiting`,
    /// one more for the frame a field is built toward.
    private let window: Int

    /// Guards the reorder window and what each frame in flight is to be
    /// mapped with. Held for that bookkeeping and nothing else: a seek's own
    /// `flush` runs on the caller's thread, which is the main thread, so
    /// anything held across it is held against the interface.
    private let lock = NSLock()
    /// The mapper holds a command queue and a pixel buffer pool and is not
    /// thread safe, while VideoToolbox calls back from several decode threads
    /// at once: this is what makes one frame at a time go through it. Held
    /// for the encode alone - the pass itself runs with nothing held, and the
    /// picture is handed on from its completion.
    private let mapping = NSLock()
    /// The passes committed and not yet landed. `drain` waits on it: the
    /// decoder having handed everything back no longer means every picture
    /// has been mapped, and a tail left on the GPU would never reach the sink.
    private let passes = DispatchGroup()
    /// Serializes the handover alone. The picture is out of `lock` before
    /// `enqueue` is called, so nothing a reader needs is held while a queue
    /// takes it; this is what still keeps two decode threads from handing
    /// over the two pictures the window has just put in order the other way
    /// round.
    private let handover = NSLock()
    /// What one handover evicts from the window, kept for its capacity so a
    /// frame allocates nothing for it. Under `handover`.
    private var due: [CMSampleBuffer] = []
    private var held: [(time: CMTime, sample: CMSampleBuffer)] = []
    /// What each frame the decoder is holding is to be mapped with, and when
    /// it went in, oldest first. A list searched by presentation time rather
    /// than a table: it holds the decoder's few frames in flight, and a
    /// container may leave the pts off every packet, in which case they all
    /// read zero and come out in the order they went in. A flush empties it,
    /// which is what makes a frame missing from it mean "fed before that flush".
    private var inFlight: [(
        time: Int64, parameters: ToneMapParameters, adaptation: ToneMapper.Adaptation,
        dovi: [Float]?, submittedAt: Double
    )] = []
    /// Bumped by every flush, and read across the tone map pass: a frame still
    /// on the GPU when a seek lands belongs to the position it left.
    private var generation = 0
    /// Set by a flush for the next interlaced frame to forget the frame and
    /// the cadence it was built against before the jump. Under `lock`.
    private var forgetsSettled = false
    /// What the last picture was handed over with, reused for as long as the
    /// pictures match it: a new description per picture is validation work
    /// for the renderer on every frame. Under `lock`.
    private var pictureDescription: CMVideoFormatDescription?
    /// One line per open about what the decoder hands back, for the console.
    /// Under `lock`.
    private var pictureDescribed = false

    /// How many pictures the last flush has been followed by, and when it
    /// ran: the first few after a seek are traced with their brightness, so
    /// a black landing can be told from a slow one. Under `lock`.
    private var picturesSinceFlush = 0
    private var flushedAt = hostTimeSeconds()

    /// How long the frames that have come back took to decode.
    public struct DecodeTiming: Sendable, Equatable {
        /// 0 both before the first frame is timed and after a real, instant
        /// one: this is what a caller reads to tell "unmeasured" apart from
        /// "measured at zero", since the two figures below cannot say it
        /// themselves.
        public var sampleCount = 0
        public var meanMilliseconds = 0.0
        public var worstMilliseconds = 0.0
        /// The GPU's share: how many passes the tone map, the enhancer or
        /// the scaler ran, and what one took on average and at worst. 0 on the
        /// path with no pass at all.
        public var gpuPasses = 0
        public var gpuMeanMilliseconds = 0.0
        public var gpuWorstMilliseconds = 0.0
    }

    /// Behind a lock of its own, taken for nothing but the three fields
    /// below. A stats ticker reads this once a second on the main thread,
    /// and the pipeline's own locks are no place for it to end up waiting.
    private let timingLock = NSLock()
    private var timing = DecodeTiming()
    private var decodeMillisecondsTotal = 0.0

    public var decodeTiming: DecodeTiming {
        timingLock.lock()
        var reading = timing
        timingLock.unlock()
        let gpu: GPUTiming.Reading
        switch processor {
        case .toneMap(let mapper):
            gpu = mapper.gpuTiming.current
        case .enhance(let enhancer), .enhanceThenUpscale(let enhancer, _):
            gpu = enhancer.gpuTiming.current
        case .upscale(let upscaler): gpu = upscaler.gpuTiming.current
        case .untouched: gpu = GPUTiming.Reading()
        }
        reading.gpuPasses = gpu.passes
        reading.gpuMeanMilliseconds = gpu.meanMilliseconds
        reading.gpuWorstMilliseconds = gpu.worstMilliseconds
        return reading
    }

    public var isHardwareAccelerated: Bool { decoder?.isHardwareAccelerated ?? false }

    /// Runs, off this object's locks, for every submitted frame that will
    /// never reach `enqueue`: the decoder returned no picture, or the pass
    /// could not be encoded. The submitter counts frames in flight against
    /// a bound, and a frame lost in silence would hold its slot for ever.
    /// A frame fed before a flush is not reported: the flush already gave
    /// every slot back.
    public var onPictureLost: ((Error) -> Void)?
    /// Runs, under the pass lock, for each picture a frame was counted for
    /// that is folded away rather than lost: a film frame shown once where
    /// its frame of fields was counted as two pictures, or a film frame the
    /// frame before already showed. The submitter's slot is given back, and
    /// nothing failed.
    public var onPictureFolded: (() -> Void)?

    /// Hands back the processed pictures the pool is only keeping for reuse.
    /// Under `mapping`, which is what makes it safe while decode threads are
    /// still going through the processor.
    public func releaseSpareBuffers() {
        mapping.lock()
        switch processor {
        case .toneMap(let mapper): mapper.releaseSpareBuffers()
        case .upscale(let upscaler): upscaler.releaseSpareBuffers()
        case .enhance(let enhancer): enhancer.releaseSpareBuffers()
        case .enhanceThenUpscale(let enhancer, let upscaler):
            enhancer.releaseSpareBuffers()
            upscaler.releaseSpareBuffers()
        case .untouched: break
        }
        mapping.unlock()
    }

    /// The deinterlaced path for a picture the screen shows at its own size:
    /// the stream decoded at its own depth, its fields built up and its codes
    /// left as they came. Same window, same enqueue contract.
    public init(
        enhancing formatDescription: CMVideoFormatDescription,
        sourceBitDepth: Int32,
        videoDelay: Int32,
        budgetBytes: Int,
        queueBytes: Int = 0,
        rendererAttributes: [String: Any] = [:],
        fields: FieldOrder? = nil,
        enqueue: @escaping (CMSampleBuffer) -> Void
    ) throws {
        pixelFormat = PictureEnhancer.outputFormat
        extendedRange = false
        self.fields = fields
        pixelAspect = CMFormatDescriptionGetExtension(
            formatDescription, extensionKey: kCMFormatDescriptionExtension_PixelAspectRatio)
        // what the decoder's reorder depth is in pictures: two a frame for fields
        let delay = Int(max(videoDelay, 0)) * (fields == nil ? 1 : 2)
        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
        let bytesPerFrame = max(
            decodedPictureBytes(
                width: Int(dimensions.width), height: Int(dimensions.height), pixelFormat: pixelFormat), 1)
        // fields hold the decoded frames back ahead of the pass, one more for
        // the frame a field is built toward, and nothing after it
        window = fields == nil
            ? min(delay, max(budgetBytes / bytesPerFrame, 1))
            : min(Int(max(videoDelay, 0)), max(budgetBytes / bytesPerFrame, 1)) + 1
        let enhancer = try PictureEnhancer(
            poolCeilingBytes: budgetBytes + queueBytes + (window + delay + 3 + 4) * bytesPerFrame,
            rendererAttributes: rendererAttributes)
        processor = .enhance(enhancer)
        upscaledSize = nil
        self.enqueue = enqueue
        peakStated = false
        staticParameters = ToneMapParameters(sourceMinPQ: 0, sourceMaxPQ: 1, targetMinPQ: 0, targetMaxPQ: 1)
        decoder = try VideoDecoder(
            formatDescription: formatDescription,
            pixelFormat: sourceBitDepth > 8
                ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ) { [weak self] frame in
            self?.present(frame)
        }
        decoder?.onDecodeFailure = { [weak self] time, status in
            self?.lose(at: time, DecodeError.decodeFailed(status))
        }
    }

    /// The decoded path: VideoToolbox decodes here, to ten bit YCbCr, and
    /// the pictures go up as they are. A display layer decoding for itself
    /// throws pictures away on a stream with a deep B pyramid, measured on
    /// tvOS with AVFoundation's own reader feeding it; a session of our own
    /// does not. Same window, same enqueue contract as the other two paths.
    public init(
        decodingOnly formatDescription: CMVideoFormatDescription,
        videoDelay: Int32,
        budgetBytes: Int,
        rendererAttributes: [String: Any] = [:],
        enqueue: @escaping (CMSampleBuffer) -> Void
    ) throws {
        pixelFormat = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        extendedRange = true
        pixelAspect = CMFormatDescriptionGetExtension(
            formatDescription, extensionKey: kCMFormatDescriptionExtension_PixelAspectRatio)
        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
        let bytesPerFrame = max(
            decodedPictureBytes(
                width: Int(dimensions.width), height: Int(dimensions.height),
                pixelFormat: pixelFormat
            ), 1)
        window = min(Int(max(videoDelay, 0)), max(budgetBytes / bytesPerFrame, 1))
        // The decoder tags its pictures with the stream's colour, and not
        // always with its light: what the description carries of the
        // mastering display and the content light rides on each picture.
        var attachments: [(key: CFString, value: CFTypeRef)] = []
        for (extensionKey, bufferKey) in [
            (kCMFormatDescriptionExtension_MasteringDisplayColorVolume,
             kCVImageBufferMasteringDisplayColorVolumeKey),
            (kCMFormatDescriptionExtension_ContentLightLevelInfo,
             kCVImageBufferContentLightLevelInfoKey),
        ] {
            if let value = CMFormatDescriptionGetExtension(formatDescription, extensionKey: extensionKey) {
                attachments.append((bufferKey, value))
            }
        }
        processor = .untouched(hdrAttachments: attachments)
        upscaledSize = nil
        fields = nil
        self.enqueue = enqueue
        peakStated = false
        staticParameters = ToneMapParameters(
            sourceMinPQ: 0, sourceMaxPQ: 1, targetMinPQ: 0, targetMaxPQ: 1
        )
        decoder = try VideoDecoder(
            formatDescription: formatDescription, pixelFormat: pixelFormat,
            bufferAttributes: rendererAttributes
        ) { [weak self] frame in
            self?.present(frame)
        }
        decoder?.onDecodeFailure = { [weak self] time, status in
            self?.lose(at: time, DecodeError.decodeFailed(status))
        }
    }

    /// `enqueue` runs on a VideoToolbox decode thread, and on the caller's own
    /// thread from `drain`; it must do its own synchronization. It is called
    /// with no lock of this object's held, but never by two threads at once,
    /// so it must not call back into `drain`, which serializes against it.
    ///
    /// It must not block, either: a decode thread parked inside it is a
    /// thread VideoToolbox is not decoding on. What bounds the pictures in
    /// flight is the submitting side holding back, not this one waiting.
    public init(
        formatDescription: CMVideoFormatDescription,
        /// What the stream says its brightest light is - MaxCLL where it
        /// carries one, the mastering display's peak otherwise. Nil where it
        /// says neither: the curve then opens at a guess and follows what the
        /// picture is measured to hold.
        sourcePeakPQ: Float?,
        /// The black the master was graded against. Nil where the stream
        /// states none, which is read as absolute black.
        sourceBlackPQ: Float? = nil,
        /// The stream's transfer. HLG decodes through the kernel's own HLG
        /// EOTF; the mastering peak still bounds the curve, and a stream with
        /// no box reads as the 1000 nits an HLG reference display is.
        sourceIsHLG: Bool = false,
        videoDelay: Int32,
        capability: DisplayCapability,
        /// What the reorder window may hold, from `PipelineBudget`: the
        /// pictures the pipeline is entitled to outside the sample queue.
        budgetBytes: Int,
        /// What the sample queue may hold, from `PipelineBudget`: pictures
        /// the output pool has to cover too, since each came out of it.
        queueBytes: Int = 0,
        /// What the sink's renderer would like the pictures allocated with.
        rendererAttributes: [String: Any] = [:],
        /// A profile 5 base layer: every RPU's reshaping is applied before
        /// its matrix, and its LMS taken into BT.2020 after.
        reshapesDolbyVision: Bool = false,
        /// False, no VideoToolbox session is built: the pictures are decoded
        /// elsewhere, in software, and handed to `decode` already made, as
        /// ten bit 4:2:0 in presentation order.
        decodesItself: Bool = true,
        enqueue: @escaping (CMSampleBuffer) -> Void
    ) throws {
        // What building this path costs an open, stage by stage, for the trace.
        var laps: [(String, Double)] = []
        var lapStart = hostTimeSeconds()
        func lap(_ stage: String) {
            let now = hostTimeSeconds()
            laps.append((stage, (now - lapStart) * 1000))
            lapStart = now
        }
        defer {
            traceLine("[lexis.open] mapped path built: "
                + laps.map { String(format: "%@ %.1f ms", $0.0, $0.1) }.joined(separator: ", "))
        }
        self.reshapesDolbyVision = reshapesDolbyVision
        fields = nil
        pixelAspect = CMFormatDescriptionGetExtension(
            formatDescription, extensionKey: kCMFormatDescriptionExtension_PixelAspectRatio)
        // The reorder depth itself, not one more: if evicting the smallest
        // presentation time held were ever wrong, the frames buffered with it
        // would already outnumber the depth the stream declares.
        //
        // A held picture is 63.3 MB at 4K on a display with headroom and 31.6
        // on one without, both measured, and a legal videoDelay of 16 would be
        // a gigabyte of the first, so the depth is capped at what `budgetBytes`
        // affords: a stream that reorders deeper than the device can hold gets
        // an inversion rather than a jetsam.
        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
        // A profile 5 film on an HDR screen leaves as the ten bit PQ the
        // screen is sent, mapped to its peak: half the bytes of the half
        // floats the compositor would only encode as that PQ again.
        pixelFormat = reshapesDolbyVision && capability.isHighDynamicRange
            ? kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange : capability.toneMapPixelFormat
        let bytes = max(
            decodedPictureBytes(width: Int(dimensions.width), height: Int(dimensions.height), pixelFormat: pixelFormat),
            1)
        window = min(Int(max(videoDelay, 0)), max(budgetBytes / bytes, 1))
        // The pool covers everything the pipeline's bounds allow to be alive
        // at once, or the bounds only manufacture one unpooled allocation per
        // frame.
        let mapper = try ToneMapper(
            pixelFormat: pixelFormat,
            poolCeilingBytes: budgetBytes + queueBytes + (window + Int(max(videoDelay, 0)) + 3 + 4) * bytes,
            rendererAttributes: rendererAttributes)
        processor = .toneMap(mapper)
        upscaledSize = nil
        lap("mapper")
        extendedRange = pixelFormat != kCVPixelFormatType_32BGRA
        self.enqueue = enqueue
        peakStated = sourcePeakPQ != nil
        let peak = sourcePeakPQ ?? ToneMappedVideo.assumedGradePQ
        // A black at or above the peak describes no range at all, and the
        // curve would map every code in the picture to the display's peak.
        // Containers do carry that, so it is refused here rather than drawn.
        let black = (sourceBlackPQ ?? 0) < peak ? (sourceBlackPQ ?? 0) : 0
        // BT.2390 as written, onto what the screen has.
        let parameters = ToneMapParameters(
            sourceMinPQ: black, sourceMaxPQ: peak,
            // Every store's display applies its own black, BT.1886's or the
            // panel's under PQ and EDR: a floor drawn here would lift it twice.
            targetMinPQ: 0, targetMaxPQ: capability.targetMaxPQ,
            sourceTransfer: sourceIsHLG ? 1 : 0
        )
        staticParameters = parameters
        // the curve's kernel for this film compiled at the open, not on its
        // first frame. A profile 5 film needs both variants: the frames
        // before its first reshaping RPU map without one.
        for reshapes in reshapesDolbyVision ? [false, true] : [false] {
            _ = try mapper.toneMapPipeline(for: parameters, reshapes: reshapes)
            _ = try mapper.toneMapPipeline(for: parameters, reshapes: reshapes, lookedUp: true)
        }
        lap("kernels")
        if pixelFormat == kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange {
            mapper.staticMetadata = hdr10StaticMetadata(peakNits: capability.peakNits)
        }
        guard decodesItself else { return }
        decoder = try VideoDecoder(
            formatDescription: formatDescription,
            pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        ) { [weak self] frame in
            self?.present(frame)
        }
        decoder?.onDecodeFailure = { [weak self] time, status in
            self?.lose(at: time, DecodeError.decodeFailed(status))
        }
        lap("decoder")
    }

    /// The upscaled path. VideoToolbox decodes to the track's own YCbCr and
    /// the upscaler makes the big picture from it. Same enqueue contract,
    /// same window; the window weighs pictures at the OUTPUT size, which is
    /// what they cost.
    ///
    /// The field builder goes in front of the scaler for an interlaced film.
    /// `sourceBitDepth` is the track's.
    public init(
        formatDescription: CMVideoFormatDescription,
        upscalingTo target: (width: Int32, height: Int32),
        /// The scaler doubles the luma by its network rather than its filters.
        neural: Bool = false,
        /// The pictures a second the scaler is handed, a field each for an
        /// interlaced film, which the network has to keep up with.
        picturesPerSecond: Double? = nil,
        videoDelay: Int32,
        budgetBytes: Int,
        queueBytes: Int = 0,
        sourceBitDepth: Int32 = 0,
        rendererAttributes: [String: Any] = [:],
        /// From `Deband.strength`, for the stream's own bits.
        debandStrength: Float = 1,
        /// Set, the stream is interlaced: its fields are built up by the
        /// enhancer ahead of the scaler.
        fields: FieldOrder? = nil,
        enqueue: @escaping (CMSampleBuffer) -> Void
    ) throws {
        self.fields = fields
        pixelAspect = CMFormatDescriptionGetExtension(
            formatDescription, extensionKey: kCMFormatDescriptionExtension_PixelAspectRatio)
        // what the decoder's reorder depth is in pictures: two a frame for fields
        let delay = Int(max(videoDelay, 0)) * (fields == nil ? 1 : 2)
        let bytesPerFrame = max(
            decodedPictureBytes(
                width: Int(target.width), height: Int(target.height),
                pixelFormat: Upscaler.pixelFormat
            ), 1)
        let held = min(delay, max(budgetBytes / bytesPerFrame, 1))
        // fields hold the decoded frames back ahead of the pass, one more for
        // the frame a field is built toward, and nothing after it
        window = fields == nil ? held : min(Int(max(videoDelay, 0)), max(budgetBytes / bytesPerFrame, 1)) + 1
        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
        // The pool has to cover everything the pipeline's own bounds allow
        // to be alive at once - the reserve (budgetBytes) and the queue
        // (queueBytes), plus the submissions in flight, the reorder window,
        // and a margin for what a renderer flush and the texture cache each
        // give back one beat late. A ceiling under that demand does not
        // bound anything: every picture past it is allocated outside the
        // pool and freed after one use, which is an IOSurface allocation per
        // frame, and under a burst of seeks the allocations outran the frees
        // to jetsam.
        let ceilingBytes = budgetBytes + queueBytes + (held + delay + 3 + 4) * bytesPerFrame
        // Each stage of this path weighed as it is built. The budget weighs a
        // picture and the queue that holds them; nothing weighs the scaler's
        // own working set or the decoder's pool, and a footprint after the
        // fact cannot be divided between them.
        let beforeScaler = footprintBytes()
        // The field builder ahead of a scaler, its pictures at the film's own
        // size and its pool weighed there.
        func enhancer(rendererAttributes: [String: Any]) throws -> PictureEnhancer {
            let bytes = max(
                decodedPictureBytes(
                    width: Int(dimensions.width), height: Int(dimensions.height),
                    pixelFormat: PictureEnhancer.outputFormat), 1)
            return try PictureEnhancer(
                poolCeilingBytes: (held + delay + 3 + 4) * bytes, rendererAttributes: rendererAttributes)
        }
        let upscaler = try Upscaler(
            inputWidth: Int(dimensions.width), inputHeight: Int(dimensions.height),
            ceilingBytes: ceilingBytes,
            // the scaler changes the size and not the colour: what comes out
            // is handed over tagged the way what went in was
            sourceFormat: formatDescription,
            rendererAttributes: rendererAttributes,
            starvation: debandStrength, neural: neural, picturesPerSecond: picturesPerSecond,
            outputSize: (Int(target.width), Int(target.height)))
        upscaledSize = (Int32(upscaler.outputWidth), Int32(upscaler.outputHeight))
        pixelFormat = Upscaler.pixelFormat
        extendedRange = false
        // the decoder's own YCbCr at the track's depth, which the scaler reads as it is
        let decoderFormat = sourceBitDepth > 8
            ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let decoderAttributes: [String: Any]
        let backend: String
        if fields != nil {
            let enhancer = try enhancer(rendererAttributes: upscaler.inputAttributes)
            processor = .enhanceThenUpscale(enhancer, upscaler)
            decoderAttributes = [:]
            backend = upscaler.isNeural ? "enhancer and network" : "enhancer and prisme"
        } else {
            processor = .upscale(upscaler)
            decoderAttributes = upscaler.inputAttributes
            backend = upscaler.isNeural ? "network" : "prisme"
        }
        let afterScaler = footprintBytes()
        self.enqueue = enqueue
        // Unused on this path: the upscaler carries no curve. Kept so the
        // in-flight bookkeeping stays one shape for every processor.
        peakStated = false
        staticParameters = ToneMapParameters(
            sourceMinPQ: 0, sourceMaxPQ: 1, targetMinPQ: 0, targetMaxPQ: 1
        )
        decoder = try VideoDecoder(
            formatDescription: formatDescription, pixelFormat: decoderFormat,
            bufferAttributes: decoderAttributes
        ) { [weak self] frame in
            self?.present(frame)
        }
        decoder?.onDecodeFailure = { [weak self] time, status in
            self?.lose(at: time, DecodeError.decodeFailed(status))
        }
        traceLine(
            "[lexis.mem] upscale built: \(backend) scaler"
                + " \((afterScaler - beforeScaler) / 1_048_576) MiB"
                + ", decoder \((footprintBytes() - afterScaler) / 1_048_576) MiB"
                + ", window \(window) pictures of \(bytesPerFrame / 1_048_576) MiB"
                + ", footprint \(footprintBytes() / 1_048_576) MiB"
        )
    }

    /// On the reader thread, in decode order.
    ///
    /// `stillCurrent` is the caller's own flush discipline, evaluated under
    /// the same lock `flush` takes: the caller's last check happens some
    /// instructions before the frame is registered here, and a flush landing
    /// in that gap would find nothing to clear yet - the registration would
    /// survive it, and the old position's picture would ride the new one's
    /// 1000 nits, what most HDR grades are and what an HLG reference display
    /// is: where the curve opens on a stream that states no grade of its own.
    /// It stands only until the first frame has been measured.
    private static let assumedGradePQ = pqInverseEOTF(0.1)
    /// Whether the stream stated a peak of its own, as opposed to taking the
    /// assumption above.
    private let peakStated: Bool

    /// Whether the stream is a profile 5 base layer, IPT that the RPU's
    /// reshaping turns into a signal, and the last reshaping packed for it:
    /// an RPU may reuse the one before it. On the reader thread alone.
    private var reshapesDolbyVision = false
    private var doviReshaping: [Float]?
    /// What `doviReshaping` was packed from: most RPUs repeat the curves
    /// of the one before, and repacking them is 690 floats a frame.
    private var doviPackedFrom: (curves: [DolbyVisionReshapingCurve], rgbToLMS: [Float], depth: Int)?
    /// queue as though freshly submitted, measured as the frame a seek then
    /// anchors the clock on. Under the lock, the two orders both come out
    /// right: registered before the flush is cleared by it, asked after the
    /// flush is refused by this.
    ///
    /// `picture` is the sample's own picture, decoded elsewhere: it goes
    /// through every pass as a picture VideoToolbox made would, on this
    /// thread, and nothing is decoded here.
    public func decode(
        _ sample: CMSampleBuffer, rpu: DolbyVisionRPU?, picture: CVPixelBuffer? = nil,
        stillCurrent: () -> Bool = { true }
    ) throws {
        var parameters = staticParameters
        var rangeFromRPU = false
        if let rpu {
            // A block whose ends meet describes no range: the curve would map
            // everything above black to the display's peak. The mastering
            // display stands in, as it does for a frame with no block at all.
            if let minPQ = rpu.minPQ, let maxPQ = rpu.maxPQ, maxPQ > minPQ {
                // 12 bit PQ codes, which is what the level 1 block carries
                parameters.sourceMinPQ = Float(minPQ) / 4095
                parameters.sourceMaxPQ = Float(maxPQ) / 4095
                rangeFromRPU = true
            }
            // An RPU with no display management block carries zeros, and a zero
            // matrix maps every picture to black: the constants stand in there.
            if rpu.yccToRGB.count == 9, rpu.yccOffset.count == 3, rpu.yccToRGB[0] != 0 {
                parameters.yccToRGB = simd_float3x3(rows: [
                    SIMD3(rpu.yccToRGB[0], rpu.yccToRGB[1], rpu.yccToRGB[2]),
                    SIMD3(rpu.yccToRGB[3], rpu.yccToRGB[4], rpu.yccToRGB[5]),
                    SIMD3(rpu.yccToRGB[6], rpu.yccToRGB[7], rpu.yccToRGB[8]),
                ])
                parameters.yccOffset = SIMD3(rpu.yccOffset[0], rpu.yccOffset[1], rpu.yccOffset[2])
            }
        }
        // How the frame's own reading may move the curve, applied on the
        // GPU once the frame is decoded and before it is mapped. With no
        // per-shot range from an RPU, what the frame holds is better
        // information than a figure stated once for the whole film; a
        // stated peak may only be narrowed, an assumed one moves either
        // way.
        var adaptation = ToneMapper.Adaptation.none
        if !rangeFromRPU { adaptation.reading = peakStated ? 1 : 2 }
        let duration = CMSampleBufferGetDuration(sample)
        if duration.isNumeric, duration.seconds > 0 {
            adaptation.seconds = Float(duration.seconds)
        }
        if reshapesDolbyVision, let rpu, let curves = rpu.reshaping,
            doviPackedFrom.map({ $0.curves != curves || $0.rgbToLMS != rpu.rgbToLMS || $0.depth != rpu.blBitDepth })
                ?? true
        {
            doviReshaping = ToneMapper.doviReshaping(curves, blBitDepth: rpu.blBitDepth, rgbToLMS: rpu.rgbToLMS)
            doviPackedFrom = (curves, rpu.rgbToLMS, rpu.blBitDepth)
        }
        let dovi = reshapesDolbyVision ? doviReshaping : nil
        let time = CMSampleBufferGetPresentationTimeStamp(sample).value
        lock.lock()
        guard stillCurrent() else {
            lock.unlock()
            return
        }
        inFlight.append((time, parameters, adaptation, dovi, hostTimeSeconds()))
        lock.unlock()
        if let picture {
            present(DecodedFrame(
                imageBuffer: picture, presentationTime: CMSampleBufferGetPresentationTimeStamp(sample)))
            return
        }
        do {
            try decoder?.decode(sample)
        } catch {
            // refused outright: a callback must not report it a second time
            lock.lock()
            inFlight.removeAll { $0.time == time }
            lock.unlock()
            throw error
        }
    }

    /// Waits for the decoder and lets go of what the window still holds: the
    /// end of the stream, where there is nothing left to wait for.
    public func drain() {
        decoder?.waitForPendingFrames()
        if let fields {
            mapping.lock()
            lock.lock()
            let rest = waiting.sorted { $0.presentationTime < $1.presentationTime }
            waiting.removeAll(keepingCapacity: true)
            let generation = self.generation
            lock.unlock()
            for (index, frame) in rest.enumerated() {
                enhanceFields(
                    of: frame, fields, next: index + 1 < rest.count ? rest[index + 1].imageBuffer : nil,
                    generation: generation)
            }
            mapping.unlock()
        }
        passes.wait()
        handover.lock()
        lock.lock()
        let tail = held.sorted { $0.time < $1.time }.map(\.sample)
        held.removeAll(keepingCapacity: true)
        inFlight.removeAll(keepingCapacity: true)
        lock.unlock()
        for sample in tail { enqueue(sample) }
        handover.unlock()
    }

    /// Drops what the decoder is holding and what the RPUs described, so a
    /// seek cannot put a frame from the old position on screen. Must not run
    /// while `decode` does: a sample already read from the old position would
    /// be fed at the new one.
    ///
    /// Never waits on `handover`: an enqueue can be parked on a full queue
    /// for as long as a pause lasts, and this runs on the caller's own
    /// thread - a seek's, a stop's, a close's. A picture already past its
    /// generation check when this lands is the caller's own flush window to
    /// refuse, which the engine's `isSeeking` give-up does.
    public func flush() {
        lock.lock()
        generation += 1
        forgetsSettled = true
        held.removeAll(keepingCapacity: true)
        waiting.removeAll(keepingCapacity: true)
        inFlight.removeAll(keepingCapacity: true)
        picturesSinceFlush = 0
        flushedAt = hostTimeSeconds()
        lock.unlock()
    }

    /// The mean of a few luma samples across the picture's middle row, for
    /// the trace alone.
    private static func meanLuma(of picture: CVPixelBuffer) -> Int {
        // a compressed picture's planes are not samples to read
        guard CVPixelBufferGetPixelFormatType(picture) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            CVPixelBufferLockBaseAddress(picture, .readOnly) == kCVReturnSuccess
        else { return -1 }
        defer { CVPixelBufferUnlockBaseAddress(picture, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(picture, 0) else { return -1 }
        let width = CVPixelBufferGetWidthOfPlane(picture, 0)
        let height = CVPixelBufferGetHeightOfPlane(picture, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(picture, 0)
        let row = base.advanced(by: stride * (height / 2)).assumingMemoryBound(to: UInt16.self)
        var total = 0
        for i in 0..<16 { total += Int(row[width * (i + 1) / 17]) }
        return total / 16
    }

    /// On a VideoToolbox decode thread: the frame at `time` came back with
    /// no picture. Reported only if it was still expected, which is what
    /// tells a real loss from a frame the last flush already let go of.
    private func lose(at time: CMTime, _ error: Error) {
        lock.lock()
        let expected = inFlight.firstIndex { $0.time == time.value }.map { inFlight.remove(at: $0) }
        lock.unlock()
        guard expected != nil else { return }
        onPictureLost?(error)
    }

    /// On a VideoToolbox decode thread, out of presentation order.
    private func present(_ frame: DecodedFrame) {
        let time = frame.presentationTime.value
        lock.lock()
        let generation = self.generation
        let entry = inFlight.firstIndex { $0.time == time }.map { inFlight.remove(at: $0) }
        lock.unlock()
        if let entry {
            let elapsedMs = (hostTimeSeconds() - entry.submittedAt) * 1000
            timingLock.lock()
            timing.sampleCount += 1
            decodeMillisecondsTotal += elapsedMs
            timing.meanMilliseconds = decodeMillisecondsTotal / Double(timing.sampleCount)
            timing.worstMilliseconds = max(timing.worstMilliseconds, elapsedMs)
            timingLock.unlock()
        }
        // VideoToolbox cannot be told to drop what it holds, so a frame whose
        // queue a flush emptied is dropped here: it belongs to a position the
        // player has left, and mapping it would only cost a pass.
        guard let entry else { return }
        switch processor {
        case .enhance, .enhanceThenUpscale:
            enhanceInTurn(frame, generation: generation)
            return
        default: break
        }
        pass(frame, entry, generation: generation)
    }

    /// The pass a decoded frame goes through, or none, and the picture handed
    /// on from its completion.
    private func pass(
        _ frame: DecodedFrame,
        _ entry: (
            time: Int64, parameters: ToneMapParameters, adaptation: ToneMapper.Adaptation,
            dovi: [Float]?, submittedAt: Double
        ),
        generation: Int
    ) {
        passes.enter()
        if case .untouched(let hdrAttachments) = processor {
            // No pass, so nothing to serialize: `mapping` is not taken.
            for (key, value) in hdrAttachments
            where CVBufferCopyAttachment(frame.imageBuffer, key, nil) == nil {
                CVBufferSetAttachment(frame.imageBuffer, key, value, .shouldPropagate)
            }
            // The per-frame HDR10+ payload the decoder propagates is not
            // handed on: a display reading it re-syncs its processing at
            // every discontinuity, and a seek then costs a black screen
            // for the length of an HDMI renegotiation.
            CVBufferRemoveAttachment(frame.imageBuffer, "HDR10PlusData" as CFString)
            lock.lock()
            picturesSinceFlush += 1
            let sinceFlush = (picturesSinceFlush, hostTimeSeconds() - flushedAt)
            let describes = !pictureDescribed
            pictureDescribed = true
            lock.unlock()
            if sinceFlush.0 <= 4 {
                // Off the decode thread: the brightness is a CPU read of the
                // picture, and the trace a formatted write to three channels.
                let picture = frame.imageBuffer
                let seconds = frame.presentationTime.seconds
                DispatchQueue.global(qos: .utility).async {
                    traceLine(String(
                        format: "[lexis.render] picture %d after flush: %.3f s later, pts %.3f, luma %d",
                        sinceFlush.0, sinceFlush.1, seconds, ToneMappedVideo.meanLuma(of: picture)))
                }
            }
            if describes {
                let keys = (CVBufferCopyAttachments(frame.imageBuffer, .shouldPropagate) as? [String: Any])?
                    .keys.sorted().joined(separator: " ") ?? "none"
                traceLine(
                    "[lexis.render] decoded picture \(fourCharCode(CVPixelBufferGetPixelFormatType(frame.imageBuffer)))"
                        + " attachments: \(keys)")
            }
            deliver(frame.imageBuffer, at: frame.presentationTime, generation: generation)
            passes.leave()
            return
        }
        mapping.lock()
        defer { mapping.unlock() }
        do {
            switch processor {
            case .toneMap(let mapper):
                try mapper.map(
                    frame.imageBuffer, parameters: entry.parameters, adaptation: entry.adaptation, dovi: entry.dovi
                ) { [weak self] mapped in
                    self?.deliver(mapped, at: frame.presentationTime, generation: generation)
                    self?.passes.leave()
                }
            case .upscale(let upscaler):
                try upscaler.scale(frame.imageBuffer) { [weak self] scaled in
                    self?.deliver(scaled, at: frame.presentationTime, generation: generation)
                    self?.passes.leave()
                }
            case .enhance, .enhanceThenUpscale:
                // handed on above
                break
            case .untouched:
                // handed on above
                break
            }
        } catch {
            passes.leave()
            onPictureLost?(error)
        }
    }

    /// The enhancer's share of `present`: a progressive frame goes through
    /// at once, an interlaced one waits for its turn, which then goes to the
    /// earliest frame waiting.
    private func enhanceInTurn(_ frame: DecodedFrame, generation: Int) {
        mapping.lock()
        defer { mapping.unlock() }
        guard let fields else {
            enhance(frame.imageBuffer, [(nil, frame.presentationTime)], generation: generation)
            return
        }
        lock.lock()
        // a flush since the frame came back has let it go
        guard generation == self.generation else {
            lock.unlock()
            return
        }
        let forgets = forgetsSettled
        forgetsSettled = false
        waiting.append(frame)
        var due: DecodedFrame?
        if waiting.count > window {
            due = waiting.remove(at: waiting.indices.min { waiting[$0].presentationTime < waiting[$1].presentationTime }!)
        }
        let next = due == nil ? nil : waiting.min { $0.presentationTime < $1.presentationTime }
        lock.unlock()
        if forgets {
            previousFrame = nil
            telecine.reset()
        }
        if let due { enhanceFields(of: due, fields, next: next?.imageBuffer, generation: generation) }
    }

    /// One interlaced frame's pictures, in presentation order, under
    /// `mapping`, with the frame shown after it where there is one: its two
    /// fields built up between its neighbours half a frame apart, or the
    /// film frame it carries. The stream's field order, not the frame's
    /// tags: VideoToolbox marks a woven frame as one field.
    private func enhanceFields(of frame: DecodedFrame, _ fields: FieldOrder, next: CVPixelBuffer?, generation: Int) {
        let current = frame.imageBuffer
        let previous = previousFrame ?? current
        previousFrame = current
        let first: VideoField = fields.topFirst ? .top : .bottom
        var picture = Telecine.Picture.fields
        // the cadence is read off the luma's eight bit codes, where the frames have them
        if CVPixelBufferGetPixelFormatType(current) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            CVPixelBufferLockBaseAddress(current, .readOnly) == kCVReturnSuccess
        {
            if CVPixelBufferLockBaseAddress(previous, .readOnly) == kCVReturnSuccess,
                let own = CVPixelBufferGetBaseAddressOfPlane(current, 0),
                let before = CVPixelBufferGetBaseAddressOfPlane(previous, 0)
            {
                let width = CVPixelBufferGetWidthOfPlane(current, 0), height = CVPixelBufferGetHeightOfPlane(current, 0)
                let rows = PlaneRows(
                    base: own.assumingMemoryBound(to: UInt8.self), stride: CVPixelBufferGetBytesPerRowOfPlane(current, 0))
                let other = PlaneRows(
                    base: before.assumingMemoryBound(to: UInt8.self), stride: CVPixelBufferGetBytesPerRowOfPlane(previous, 0))
                picture = telecine.picture(
                    ownComb: Deinterlacer.combing(current: rows, other: rows, widthBytes: width, height: height, field: first),
                    previousComb: Deinterlacer.combing(
                        current: rows, other: other, widthBytes: width, height: height, field: first),
                    samples: width * height / 2)
                CVPixelBufferUnlockBaseAddress(previous, .readOnly)
            }
            CVPixelBufferUnlockBaseAddress(current, .readOnly)
        }
        switch picture {
        case .fields:
            let after = next ?? current
            enhance(current, [
                (.field(first, second: false, previous: previous, next: after), frame.presentationTime),
                (.field(first == .top ? .bottom : .top, second: true, previous: previous, next: after),
                 frame.presentationTime + fields.duration),
            ], generation: generation)
        case .film(let weavesPrevious, let early):
            // a frame of fields is counted as two pictures
            onPictureFolded?()
            enhance(current, [(
                .film(first, previous: weavesPrevious ? previous : nil),
                early ? frame.presentationTime - fields.duration : frame.presentationTime
            )], generation: generation)
        case .repeated:
            onPictureFolded?()
            onPictureFolded?()
        }
    }

    /// The enhancer's pictures of one decoded frame, each built as `field`
    /// says and shown at its `time`, under `mapping`. A pass is entered per
    /// picture before its own encode, so a throw leaves exactly what it
    /// entered.
    private func enhance(
        _ frame: CVPixelBuffer, _ pictures: [(field: PictureEnhancer.FieldBuild?, time: CMTime)], generation: Int
    ) {
        for picture in pictures {
            passes.enter()
            do {
                switch processor {
                case .enhance(let enhancer):
                    try enhancer.enhance(frame, field: picture.field) { [weak self] enhanced in
                        self?.deliver(enhanced, at: picture.time, generation: generation)
                        self?.passes.leave()
                    }
                case .enhanceThenUpscale(let enhancer, let upscaler) where upscaler.isNeural:
                    try enhancer.enhance(frame, field: picture.field) { [weak self] enhanced in
                        self?.scale(enhanced, with: upscaler, at: picture.time, generation: generation)
                    }
                case .enhanceThenUpscale(let enhancer, let upscaler):
                    // one command buffer for both, as the mapped path has
                    try enhancer.enhance(
                        frame, field: picture.field,
                        appending: { command, enhanced in try upscaler.encode(enhanced, into: command) }
                    ) { [weak self] scaled in
                        self?.deliver(scaled, at: picture.time, generation: generation)
                        self?.passes.leave()
                    }
                default:
                    passes.leave()
                }
            } catch {
                passes.leave()
                onPictureLost?(error)
            }
        }
    }

    /// The scaling pass of a chained path, from the first pass's completion.
    /// Under `mapping`, as `present` encodes: the scaler's textures are set
    /// on it for each encode, so two encodes at once would cross.
    private func scale(_ picture: CVPixelBuffer, with upscaler: Upscaler, at time: CMTime, generation: Int) {
        mapping.lock()
        defer { mapping.unlock() }
        do {
            try upscaler.scale(picture) { [weak self] scaled in
                self?.deliver(scaled, at: time, generation: generation)
                self?.passes.leave()
            }
        } catch {
            onPictureLost?(error)
            passes.leave()
        }
    }

    /// On a Metal callback thread, once one frame's pass has landed.
    private func deliver(_ mapped: CVPixelBuffer, at presentationTime: CMTime, generation: Int) {
        if let pixelAspect {
            CVBufferSetAttachment(mapped, kCVImageBufferPixelAspectRatioKey, pixelAspect, .shouldPropagate)
        }
        lock.lock()
        var description = pictureDescription
        lock.unlock()
        if description.map({ !CMVideoFormatDescriptionMatchesImageBuffer($0, imageBuffer: mapped) })
            ?? true
        {
            description = nil
            guard CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault, imageBuffer: mapped,
                formatDescriptionOut: &description
            ) == noErr else { return }
            lock.lock()
            pictureDescription = description
            lock.unlock()
        }
        guard let description else { return }
        var timingInfo = CMSampleTimingInfo(
            duration: .invalid, presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: mapped, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: description,
            sampleTiming: &timingInfo, sampleBufferOut: &sample
        ) == noErr, let sample else { return }
        // Taken before the reorder lock and held across the handover below,
        // so the order the window evicts in is the order the pictures leave
        // in; `lock` itself is let go of first, and the handover happens
        // with nothing of this object's held.
        handover.lock()
        lock.lock()
        // A flush that landed while this frame was on the GPU
        if self.generation == generation {
            held.append((presentationTime, sample))
            // fields leave their pass in order already
            while held.count > (fields == nil ? window : 0) {
                let next = held.indices.min { held[$0].time < held[$1].time }!
                due.append(held.remove(at: next).sample)
            }
        }
        lock.unlock()
        for sample in due { enqueue(sample) }
        due.removeAll(keepingCapacity: true)
        handover.unlock()
    }
}

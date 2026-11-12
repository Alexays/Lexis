import CoreVideo
import Foundation
import Metal
import simd

/// One frame's worth of what the curve needs. The two source values come from
/// the RPU's level 1 block when there is one and from the mastering display
/// when there is not; the two target values come from the screen.
public struct ToneMapParameters: Equatable {
    /// YCbCr to RGB, with the offsets subtracted from Y, Cb and Cr first. An
    /// RPU carries both; without one these are the BT.2020 constants.
    public var yccToRGB: simd_float3x3
    public var yccOffset: SIMD3<Float>
    public var sourceMinPQ: Float
    public var sourceMaxPQ: Float
    public var targetMinPQ: Float
    public var targetMaxPQ: Float
    /// 0 decodes the picture as ST 2084, 1 as HLG through the 1000 nit
    /// reference OOTF. A UInt32 because these bytes cross to the kernel as
    /// they are.
    public var sourceTransfer: UInt32

    /// BT.2020 non constant luminance, limited range, ten bit: what an HDR10
    /// stream and a Dolby Vision profile 8 base layer both are.
    public static let bt2020Limited = simd_float3x3(rows: [
        SIMD3(1.1678, 0, 1.6836),
        SIMD3(1.1678, -0.1878, -0.6522),
        SIMD3(1.1678, 2.1481, 0),
    ])
    /// A ten-bit code reads back normalized over 1023, which is what the
    /// matrix gains above are scaled for, so black at 64 and neutral chroma at
    /// 512 divide by 1023 too. Over 1024 they would bias every neutral.
    public static let limitedRangeOffset = SIMD3<Float>(64.0 / 1023, 512.0 / 1023, 512.0 / 1023)

    public init(
        yccToRGB: simd_float3x3 = ToneMapParameters.bt2020Limited,
        yccOffset: SIMD3<Float> = ToneMapParameters.limitedRangeOffset,
        sourceMinPQ: Float, sourceMaxPQ: Float, targetMinPQ: Float, targetMaxPQ: Float,
        sourceTransfer: UInt32 = 0
    ) {
        self.yccToRGB = yccToRGB
        self.yccOffset = yccOffset
        self.sourceMinPQ = sourceMinPQ
        self.sourceMaxPQ = sourceMaxPQ
        self.targetMinPQ = targetMinPQ
        self.targetMaxPQ = targetMaxPQ
        self.sourceTransfer = sourceTransfer
    }
}

/// SMPTE ST 2084, from linear light normalized to 10000 cd/m2 to its code.
/// The curve's parameters are all in that space.
/// ST 2084 the other way: a PQ code back to light, 1.0 being 10000 nits.
func pqEOTFLinear(_ code: Float) -> Float {
    let m1: Float = 0.1593017578125, m2: Float = 78.84375
    let c1: Float = 0.8359375, c2: Float = 18.8515625, c3: Float = 18.6875
    let p = pow(max(code, 0), 1 / m2)
    return pow(max(p - c1, 0) / (c2 - c3 * p), 1 / m1)
}

public func pqInverseEOTF(_ value: Double) -> Float {
    let m1 = 0.1593017578125, m2 = 78.84375
    let c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875
    let p = pow(max(value, 0), m1)
    return Float(pow((c1 + c2 * p) / (1 + c3 * p), m2))
}

/// What every pass's plane wrappers are made with: the output planes are
/// written through them, which a texture's usage has to say.
let writableTexture = [
    kCVMetalTextureUsage: NSNumber(value: MTLTextureUsage([.shaderRead, .shaderWrite]).rawValue),
] as CFDictionary

public enum ToneMapError: Error, Equatable {
    case noDevice
    case unsupportedFormat(OSType)
    case textureFailed(CVReturn)
    case bufferFailed(CVReturn)
}

/// Maps a 10-bit PQ picture onto what the display can show, one compute pass a
/// frame.
///
/// Two output formats, because the curve's own destination decides which one
/// carries the result. `64RGBAHalf` is linear light with 1.0 as SDR white, an
/// extended linear colour space: the only one of the two that can hold light
/// above white, and so the one a display with headroom is given. `32BGRA` in
/// ITU-R BT.709 is the same picture in the SDR screen's own primaries, behind
/// that space's transfer function, which is all a display without headroom
/// leaves to store once the curve has landed everything at or below white -
/// and half the bytes.
public final class ToneMapper {
    /// What `map` hands back, and therefore what one held picture costs.
    public let pixelFormat: OSType
    private let queue: MTLCommandQueue
    private let device: MTLDevice
    private let textureCache: CVMetalTextureCache
    private let targetTextureFormat: MTLPixelFormat
    private let colorSpace: CGColorSpace?
    /// The third destination: ten bit PQ YCbCr, the picture an HDR display
    /// is handed as it is, encoded by the curve's own pass; the pictures
    /// carry the static metadata the caller sets for the peak it mapped to.
    /// 4:2:0, or 4:2:2 where the picture goes straight to the display: the
    /// chroma then keeps every row the curve's reconstruction gave it,
    /// rather than the compositor rebuilding them from half.
    public var staticMetadata: (masteringDisplay: Data, contentLight: Data)?
    private let measurePipeline: MTLComputePipelineState
    private let clearPipeline: MTLComputePipelineState
    private let settlePipeline: MTLComputePipelineState
    /// The chroma filter's weights for the last siting a frame had, which a
    /// film keeps throughout.
    private var chromaFilter: (siting: SIMD2<Float>, words: [UInt32])?
    /// The frame's LUT: `lutSize` points each way over the RGB signal,
    /// filtered by the GPU as it is read. Half floats, which every Apple GPU
    /// filters and full floats are not on an A15: a half's rounding is a
    /// fifth of a ten bit code, under the dither the store adds.
    private var lut: MTLTexture?
    static let lutSize = 65
    /// The bins over PQ the picture's shares are read in, from one frame to
    /// the next, to tell a cut the mean does not show. 256 / levelBins of
    /// `lexis_settle`'s threads read each bin.
    static let levelBins = 64
    /// The settled figures a frame's LUT is built from, which the settle
    /// keeps to tell whether the next frame needs one built again.
    static let builtFigures = 4
    private var pool: PixelBufferPool?
    private var poolWidth = 0
    private var poolHeight = 0

    /// How what a frame holds may move the curve it is mapped with. The
    /// frame is measured on the GPU ahead of its own pass, off a histogram
    /// of its PQ codes: the peak at the 99.995th percentile above the black
    /// cutoff, so one specular pixel does not set the curve, and the mean
    /// over the same pixels, which tells a cut. The reading is smoothed
    /// against the frames before it and the curve is built from the result,
    /// all before the pass that reads it, so a cut is mapped for the shot it
    /// opens from its first picture. These bytes cross to the kernel as they
    /// are.
    public struct Adaptation: Equatable {
        /// 0: the source range is what the parameters say. 1: the reading
        /// may narrow the source peak, the file's own being a ceiling. 2:
        /// the reading sets the source peak either way, nothing having
        /// stated one.
        public var reading: UInt32
        /// How long this frame is on screen: the smoothing runs in seconds,
        /// so a 60 frame film settles as fast as a 24 frame one.
        public var seconds: Float
        /// 1 says nothing the LUT is built from but the settled curve has
        /// moved since the last frame built it: it is built again only if
        /// the curve has.
        public var keepsLUT: UInt32 = 0

        public init(reading: UInt32, seconds: Float = 1.0 / 24) {
            self.reading = reading
            self.seconds = seconds
        }

        public static let none = Adaptation(reading: 0)
    }

    /// The histogram's resolution, in bins over the PQ range: a thousandth
    /// of PQ, well under what a peak read off it needs. `lexis_settle` reads
    /// it with 256 threads, so it stays a multiple of that.
    static let histogramBins = 1024
    /// The blocks one thread of `lexis_measure` counts: its threadgroup
    /// clears and merges every bin, which a handful of samples a thread
    /// would not pay for.
    static let measuredPerThread = 8

    /// One of each, not a ring: the queue runs its command buffers in order,
    /// so a frame's clear, count and settle have landed before the next
    /// frame's clear. The histogram and the settled parameters are the GPU's
    /// alone; the state is what the smoothing carries from frame to frame.
    /// What each frame's map costs the GPU, the LUT's pass included, and
    /// outside a trace the analysis that shares its buffer.
    let gpuTiming = GPUTiming(label: "tone map")
    /// Under a trace, the passes before the map in a buffer of their own: the
    /// histogram and the settle. Apart from `gpuTiming` and not added to it:
    /// on a busy GPU this buffer's span also covers the frame before's map it
    /// overlaps.
    let analysisTiming = GPUTiming(label: "tone map analysis")
    /// Each pass of the map's own buffer, under a trace.
    private let passTimer: PassTimer?
    /// The analysis pass itself, where its buffer's span also covers the
    /// frames it overlaps with.
    private let analysisTimer: PassTimer?
    /// The LUT pass's threadgroups, written by the settle.
    private let lutGroups: MTLBuffer
    /// What the last LUT was built from on the CPU's side: the parameters
    /// given, the reshaping, and the variant. Nil where the frame before
    /// built none.
    private var lastLUTInputs: (ToneMapParameters, [Float], Int)?
    private let histogram: MTLBuffer
    /// Two, frames taking turns: a frame's analysis then writes nothing the
    /// frame before's map still reads, and the GPU runs it beside that map
    /// rather than after it.
    private let settledPair: [MTLBuffer]
    /// Which of the two the next frame writes and maps with.
    private var turn = 0
    private let state: MTLBuffer
    /// The curve's kernel for the last variant a frame asked for.
    private var lastVariant: (variant: Int, pipelines: VariantPipelines)?
    /// A variant's map and, where it reads the frame's LUT, the kernel that
    /// builds it with the same constants.
    private struct VariantPipelines {
        let map: MTLComputePipelineState
        let lut: MTLComputePipelineState?
    }
    /// What the pool may keep across its lifetime, in bytes. The capacity in
    /// pictures is derived per size, since a Dolby Vision stream can change
    /// dimensions mid-file and the pool is rebuilt when it does.
    private let poolCeilingBytes: Int
    /// What the renderer the mapped pictures go to would like them allocated
    /// with, folded into the pool's own attributes when it is built.
    private let rendererAttributes: [String: Any]

    /// The one thread a texture cache may be touched from: created here,
    /// textured from here, and every wrapper released back onto here. Core
    /// Video ties a cache's backing list to the thread that owns it, and a
    /// wrapper finalized on a Metal completion thread was walking that list
    /// from somewhere else.
    private let cacheQueue = DispatchQueue(label: "org.lexis.cvmetal")

    /// SwiftPM does not compile .metal files, so the kernels are source and
    /// have to be compiled: about 200 ms. The whole process shares one
    /// library, and a film after the first pays nothing for it. Without this
    /// every HDR open paid the compile before its first frame, and a Dolby
    /// Vision fallback paid it again mid-film.
    private static let kernelLock = NSLock()
    private struct Kernel {
        let device: MTLDevice
        let library: MTLLibrary
        let measure: MTLComputePipelineState
        let clear: MTLComputePipelineState
        let settle: MTLComputePipelineState
    }
    private static var kernel: Kernel?
    /// The curve's kernel per variant, each compiled the first time a film
    /// asks for it and kept for the process. Under `kernelLock`.
    private static var toneMapPipelines: [Int: VariantPipelines] = [:]

    private static func compiledKernel() throws -> Kernel {
        kernelLock.lock()
        defer { kernelLock.unlock() }
        if let kernel { return kernel }
        guard let device = MTLCreateSystemDefaultDevice() else { throw ToneMapError.noDevice }
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: ToneMapper.shader, options: nil)
        } catch {
            // every mapped path falls back on this, and nothing else says why
            traceLine("[lexis.gpu] tone map kernels failed to compile: \(error)")
            throw error
        }
        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else {
                traceLine("[lexis.gpu] tone map kernel \(name) missing")
                throw ToneMapError.noDevice
            }
            return try device.makeComputePipelineState(function: function)
        }
        let built = Kernel(
            device: device, library: library, measure: try pipeline("lexis_measure"),
            clear: try pipeline("lexis_clear_histogram"), settle: try pipeline("lexis_settle"))
        kernel = built
        return built
    }

    /// The curve's kernel with every choice that holds for a whole film
    /// compiled in rather than branched on per pixel: the store, the
    /// transfer, the reshaping and whether the LUT stands in for the map.
    ///
    /// Asked for once as a film opens, so the compile lands there rather
    /// than on its first frame; after that a frame of the same variant
    /// costs a comparison.
    func toneMapPipeline(
        for parameters: ToneMapParameters, reshapes: Bool, lookedUp: Bool = false
    ) throws -> MTLComputePipelineState {
        // bits 0 and 1 the store, then bit n + 1 the kernel's function constant n
        let encodesPQ = pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            || pixelFormat == kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
        var variant = pixelFormat == kCVPixelFormatType_32BGRA ? 1
            : pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ? 2
            : pixelFormat == kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange ? 3 : 0
        if reshapes { variant |= 1 << 2 }
        if parameters.sourceTransfer == 1 { variant |= 1 << 3 }
        // The LUT stands in for the map on the PQ stores it is built for.
        if lookedUp, encodesPQ { variant |= 1 << 4 }
        return try pipelines(variant).map
    }

    private func pipelines(_ variant: Int) throws -> VariantPipelines {
        if let lastVariant, lastVariant.variant == variant { return lastVariant.pipelines }
        ToneMapper.kernelLock.lock()
        defer { ToneMapper.kernelLock.unlock() }
        if let built = ToneMapper.toneMapPipelines[variant] {
            lastVariant = (variant, built)
            return built
        }
        guard let kernel = ToneMapper.kernel else { throw ToneMapError.noDevice }
        let constants = MTLFunctionConstantValues()
        var store = UInt32(variant & 3)
        constants.setConstantValue(&store, type: .uint, index: 0)
        for index in 1...3 {
            var set = variant & (1 << (index + 1)) != 0
            constants.setConstantValue(&set, type: .bool, index: index)
        }
        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            try kernel.device.makeComputePipelineState(
                function: try kernel.library.makeFunction(name: name, constantValues: constants))
        }
        let compiling = ContinuousClock.now
        let built = VariantPipelines(
            map: try pipeline("lexis_tone_map"),
            lut: variant & (1 << 4) != 0 ? try pipeline("lexis_lut") : nil)
        let took = ContinuousClock.now - compiling
        traceLine(String(
            format: "[lexis.gpu] tone map variant %x compiled in %.1f ms", variant,
            Double(took.components.attoseconds) / 1e15 + Double(took.components.seconds) * 1000))
        ToneMapper.toneMapPipelines[variant] = built
        lastVariant = (variant, built)
        return built
    }

    /// - Parameter pixelFormat: `64RGBAHalf`, `32BGRA`, or ten bit PQ YCbCr
    ///   4:2:0 or 4:2:2; anything else is refused here rather than at the
    ///   first frame. Half floats by default, the widest picture this
    ///   pipeline makes: a caller that has not said where the picture is
    ///   going gets the format that can carry any destination.
    public init(
        pixelFormat: OSType = kCVPixelFormatType_64RGBAHalf,
        /// The upscaler's own sizing rule, for the same reason it has one: a
        /// pool with no ceiling keeps whatever its busiest moment needed, for
        /// as long as it lives. Generous by default for the callers that are
        /// not a film - the bench, the tests - where nothing else bounds it.
        poolCeilingBytes: Int = 1024 * 1024 * 1024,
        rendererAttributes: [String: Any] = [:]
    ) throws {
        self.poolCeilingBytes = poolCeilingBytes
        self.rendererAttributes = rendererAttributes
        switch pixelFormat {
        case kCVPixelFormatType_64RGBAHalf:
            targetTextureFormat = .rgba16Float
            colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!
        case kCVPixelFormatType_32BGRA:
            targetTextureFormat = .bgra8Unorm
            // BT.1886 as CoreGraphics reads it, in the SDR screen's own
            // primaries: the compositor has no conversion left to run
            colorSpace = CGColorSpace(name: CGColorSpace.itur_709)!
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange:
            targetTextureFormat = .rgba16Float
            colorSpace = nil
        default:
            throw ToneMapError.unsupportedFormat(pixelFormat)
        }
        self.pixelFormat = pixelFormat
        let kernel = try ToneMapper.compiledKernel()
        let device = kernel.device
        guard let queue = device.makeCommandQueue() else { throw ToneMapError.noDevice }
        self.device = device
        passTimer = PassTimer(
            device: device, label: "tone map, other is what follows it in its buffer", passes: ["lut", "map"])
        analysisTimer = PassTimer(device: device, label: "tone map analysis", passes: ["analysis"])
        measurePipeline = kernel.measure
        clearPipeline = kernel.clear
        settlePipeline = kernel.settle
        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard status == kCVReturnSuccess, let cache else { throw ToneMapError.textureFailed(status) }
        self.queue = queue
        textureCache = cache
        guard let histogram = device.makeBuffer(
                length: MemoryLayout<UInt32>.size * ToneMapper.histogramBins, options: .storageModePrivate),
            let settled = device.makeBuffer(
                length: MemoryLayout<ToneMapParameters>.stride, options: .storageModePrivate),
            let settledOther = device.makeBuffer(length: settled.length, options: .storageModePrivate),
            // the State struct: its four scalars, the built figures and the
            // last shares
            let state = device.makeBuffer(
                length: MemoryLayout<Float>.size * (4 + ToneMapper.builtFigures + ToneMapper.levelBins),
                options: .storageModeShared),
            let lutGroups = device.makeBuffer(
                length: MemoryLayout<MTLDispatchThreadgroupsIndirectArguments>.size, options: .storageModePrivate)
        else { throw ToneMapError.noDevice }
        // Nothing measured yet: the first reading is taken as it is.
        memset(state.contents(), 0, state.length)
        self.histogram = histogram
        settledPair = [settled, settledOther]
        self.state = state
        self.lutGroups = lutGroups
    }

    /// `frame` has to be x420, the uncompressed 10-bit biplanar video-range
    /// format. VideoToolbox hands back a lossless variant unless the
    /// decompression session asks for this one, and a lossless buffer reads as
    /// all ones through a texture cache, so the session `ToneMappedVideo` runs
    /// asks for this format by name.
    ///
    /// Encodes and commits, and never waits: `completion` runs on a Metal
    /// callback thread once the pass has actually landed, and the picture is
    /// only handed on from there. Waiting here instead put the whole GPU pass
    /// in the critical path of every frame, on the decode thread, with no
    /// overlap possible between one frame's pass and the next one's.
    /// Where a profile 5 frame's reshaping sits in the floats `map` hands
    /// the kernels: a flag, the LMS to BT.2020 matrix row by row, then per
    /// component its pivot count, nine pivots, and eight pieces of a method,
    /// three polynomial coefficients, an MMR order, constant and 21 MMR
    /// coefficients.
    static let doviHeader = 12
    static let clearedReshaping: [Float] = [0]
    static let doviPiece = 27
    static let doviComponent = 10 + 8 * doviPiece

    /// A profile 5 frame's reshaping and colour, packed for the kernels,
    /// as libplacebo's pl_map_dovi_metadata normalizes them: pivots over
    /// the base layer's code range, and linear light taken from the RPU's
    /// LMS into BT.2020 by Dolby's fixed lms2rgb times the RPU's rgb_to_lms.
    static func doviReshaping(
        _ curves: [DolbyVisionReshapingCurve], blBitDepth: Int, rgbToLMS: [Float]
    ) -> [Float] {
        var packed = [Float](repeating: 0, count: doviHeader + 3 * doviComponent)
        packed[0] = 1
        let lmsToRGB: [[Double]] = [
            [3.06441879, -2.16597676, 0.10155818],
            [-0.65612108, 1.78554118, -0.12943749],
            [0.01736321, -0.04725154, 1.03004253],
        ]
        // an RPU with no display management block carries a zero matrix,
        // which would turn every picture black: the identity stands in
        let rgbToLMSKnown = rgbToLMS.count == 9 && rgbToLMS[0] != 0
        for row in 0..<3 {
            for column in 0..<3 {
                packed[1 + row * 3 + column] = rgbToLMSKnown
                    ? Float((0..<3).reduce(0.0) { $0 + lmsToRGB[row][$1] * Double(rgbToLMS[$1 * 3 + column]) })
                    : (row == column ? 1 : 0)
            }
        }
        let codeRange = Float((1 << blBitDepth) - 1)
        for (c, curve) in curves.prefix(3).enumerated() {
            let base = doviHeader + c * doviComponent
            packed[base] = Float(curve.pivots.count)
            for (i, pivot) in curve.pivots.prefix(9).enumerated() {
                packed[base + 1 + i] = Float(pivot) / codeRange
            }
            for (i, piece) in curve.pieces.prefix(8).enumerated() {
                let at = base + 10 + i * doviPiece
                switch piece {
                case .polynomial(let coefficients):
                    for (k, value) in coefficients.prefix(3).enumerated() { packed[at + 1 + k] = Float(value) }
                case .mmr(let order, let constant, let coefficients):
                    packed[at] = 1
                    packed[at + 4] = Float(order)
                    packed[at + 5] = Float(constant)
                    for (k, value) in coefficients.prefix(21).enumerated() { packed[at + 6 + k] = Float(value) }
                }
            }
        }
        return packed
    }

    public func map(
        _ frame: CVPixelBuffer, parameters: ToneMapParameters, adaptation: Adaptation = .none,
        dovi: [Float]? = nil, completion: @escaping (CVPixelBuffer) -> Void
    ) throws {
        // Video range only. The only constants that ship are the limited-range
        // ones and both parameters default to them, so a full-range buffer
        // would come out stretched with crushed blacks rather than decoded.
        let format = CVPixelBufferGetPixelFormatType(frame)
        guard format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        else { throw ToneMapError.unsupportedFormat(format) }
        let width = CVPixelBufferGetWidthOfPlane(frame, 0)
        let height = CVPixelBufferGetHeightOfPlane(frame, 0)
        var parameters = parameters
        // While the frames before this one peaked well under the display, the
        // curve lands every pixel as it is, and what a pixel's colour decides
        // is read off a LUT: a curve that compresses bends too sharply
        // between its points. The smoothed peak is the last settle's, read as
        // it stands, which a cut moves by a frame at most.
        let underPeak = adaptation.reading != 0
            && state.contents().load(fromByteOffset: 8, as: UInt32.self) != 0
            && pqEOTFLinear(state.contents().load(as: Float.self)) * ToneMapper.compressionMargin
                < pqEOTFLinear(parameters.targetMaxPQ)
        let toneMap = try toneMapPipeline(for: parameters, reshapes: dovi != nil, lookedUp: underPeak)
        let lutBuild = lastVariant?.pipelines.lut
        // Bound by value, under the 4 KB `setBytes` takes, so a new RPU costs
        // no allocation; a cleared flag is any other stream.
        let reshaping = dovi ?? ToneMapper.clearedReshaping
        let output = try makeOutput(width: width, height: height)
        let encodesPQ = pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            || pixelFormat == kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
        // Every wrapper in one hop onto the owner queue: this runs on a
        // VideoToolbox callback thread for every frame, and each hop is a
        // thread handoff on it.
        var outputChroma: CVMetalTexture?
        // source luma and chroma, the target, and the PQ target's chroma
        let wrapped = try cacheQueue.sync { () -> PassTextures in
            let luma = try texture(frame, plane: 0, format: .r16Unorm,
                                   width: width, height: height)
            // The chroma plane rounds up on an odd size, so it is asked for its
            // own dimensions: width / 2 would leave the last column outside
            // the texture.
            let chroma = try texture(
                frame, plane: 1, format: .rg16Unorm,
                width: CVPixelBufferGetWidthOfPlane(frame, 1),
                height: CVPixelBufferGetHeightOfPlane(frame, 1)
            )
            // The PQ destination's wrapper here is its luma plane.
            let target = try texture(
                output, plane: 0, format: encodesPQ ? .r16Unorm : targetTextureFormat,
                width: width, height: height
            )
            guard encodesPQ else { return PassTextures([luma, chroma, target], cache: textureCache, pool: pool) }
            let targetChroma = try texture(
                output, plane: 1, format: .rg16Unorm,
                width: CVPixelBufferGetWidthOfPlane(output, 1),
                height: CVPixelBufferGetHeightOfPlane(output, 1))
            outputChroma = targetChroma
            return PassTextures([luma, chroma, target, targetChroma], cache: textureCache, pool: pool)
        }
        let settled = settledPair[turn]
        turn ^= 1
        // One command buffer a frame. Under a trace the analysis takes one of
        // its own, so each reports its own GPU time; the queue runs them in
        // order.
        guard let command = queue.makeCommandBuffer(),
            let analysis = passTimer == nil ? command : queue.makeCommandBuffer()
        else { throw ToneMapError.noDevice }
        let analysisSlot = analysisTimer?.slot() ?? 0
        guard let analyzer = analysisTimer?.encoder(0, slot: analysisSlot, on: analysis)
            ?? analysis.makeComputeCommandEncoder()
        else { throw ToneMapError.noDevice }
        analyzer.label = "lexis analysis"
        let luma = CVMetalTextureGetTexture(wrapped.wrappers[0])!
        let chroma = CVMetalTextureGetTexture(wrapped.wrappers[1])!
        var adaptation = adaptation
        // Nothing but the settled curve can have moved the LUT when the
        // frame before built it from the same inputs.
        let lutInputs = lutBuild.map { _ in (parameters, reshaping, lastVariant?.variant ?? -1) }
        if let lutInputs, let lastLUTInputs, lastLUTInputs.0 == lutInputs.0, lastLUTInputs.1 == lutInputs.1,
            lastLUTInputs.2 == lutInputs.2
        {
            adaptation.keepsLUT = 1
        }
        lastLUTInputs = lutInputs
        var siting = chromaSiting(of: frame)
        // Uniform groups, the last partial one bounded by the kernel itself:
        // that check costs less than a non-uniform dispatch does.
        let group = MTLSize(width: 32, height: 8, depth: 1)
        // What the frame holds, counted ahead of everything that reads the
        // curve; a frame mapped as given never.
        if adaptation.reading != 0 {
            analyzer.setComputePipelineState(clearPipeline)
            analyzer.setBuffer(histogram, offset: 0, index: 1)
            analyzer.dispatchThreadgroups(
                MTLSize(width: ToneMapper.histogramBins / 256, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
            analyzer.setComputePipelineState(measurePipeline)
            analyzer.setTexture(luma, index: 0)
            analyzer.setTexture(chroma, index: 1)
            analyzer.setBytes(&parameters, length: MemoryLayout<ToneMapParameters>.size, index: 0)
            analyzer.setBuffer(histogram, offset: 0, index: 1)
            reshaping.withUnsafeBytes { analyzer.setBytes($0.baseAddress!, length: $0.count, index: 2) }
            let columns = (width + 3) / 4
            let threads = (columns + ToneMapper.measuredPerThread - 1) / ToneMapper.measuredPerThread
            analyzer.dispatchThreadgroups(
                MTLSize(width: (threads + group.width - 1) / group.width,
                        height: ((height + 3) / 4 + group.height - 1) / group.height, depth: 1),
                threadsPerThreadgroup: group)
        }
        // The curve this frame is mapped with, from the given parameters and
        // the reading: one threadgroup, and every pass after it reads its
        // result.
        analyzer.setComputePipelineState(settlePipeline)
        analyzer.setBuffer(histogram, offset: 0, index: 0)
        analyzer.setBytes(&parameters, length: MemoryLayout<ToneMapParameters>.size, index: 1)
        analyzer.setBytes(&adaptation, length: MemoryLayout<Adaptation>.size, index: 2)
        analyzer.setBuffer(state, offset: 0, index: 3)
        analyzer.setBuffer(settled, offset: 0, index: 4)
        analyzer.setBuffer(lutGroups, offset: 0, index: 5)
        analyzer.dispatchThreadgroups(
            MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
        analyzer.endEncoding()
        if analysis !== command {
            analysis.addCompletedHandler { [analysisTiming, analysisTimer] buffer in
                analysisTimer?.record(buffer, slot: analysisSlot, encoded: [0])
                analysisTiming.record((buffer.gpuEndTime - buffer.gpuStartTime) * 1000, beyondPool: 0)
            }
            analysis.commit()
        }
        let slot = passTimer?.slot() ?? 0
        let timed = lutBuild == nil ? [1] : [1, 0]
        if let lutBuild {
            // The frame's LUT, from the curve the analysis just settled.
            guard let build = passTimer?.encoder(0, slot: slot, on: command) ?? command.makeComputeCommandEncoder()
            else { throw ToneMapError.noDevice }
            build.label = "lexis lut"
            let table = try lutTexture()
            build.setComputePipelineState(lutBuild)
            build.setTexture(table, index: 0)
            build.setBuffer(settled, offset: 0, index: 0)
            reshaping.withUnsafeBytes { build.setBytes($0.baseAddress!, length: $0.count, index: 1) }
            // sized by the settle: no threadgroup at all where the LUT from
            // the frame before holds what this one would build, since even
            // threads that return at once cost what building it does
            build.dispatchThreadgroups(
                indirectBuffer: lutGroups, indirectBufferOffset: 0,
                threadsPerThreadgroup: MTLSize(width: 4, height: 4, depth: 4))
            build.endEncoding()
        }
        guard let encoder = passTimer?.encoder(1, slot: slot, on: command) ?? command.makeComputeCommandEncoder()
        else { throw ToneMapError.noDevice }
        encoder.label = "lexis map"
        encoder.setComputePipelineState(toneMap)
        encoder.setTexture(luma, index: 0)
        encoder.setTexture(chroma, index: 1)
        encoder.setTexture(CVMetalTextureGetTexture(wrapped.wrappers[2]), index: 2)
        if lutBuild != nil { encoder.setTexture(lut, index: 4) }
        encoder.setBuffer(settled, offset: 0, index: 0)
        encoder.setBytes(&siting, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
        reshaping.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 2) }
        if chromaFilter?.siting != siting {
            chromaFilter = (siting, ToneMapper.chromaFilter(siting: siting))
        }
        chromaFilter!.words.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 3) }
        // One thread per 2x2 block of pixels: the block shares one chroma window.
        if let outputChroma {
            encoder.setTexture(CVMetalTextureGetTexture(outputChroma), index: 3)
            // 31 blocks a threadgroup row: its first thread maps the block
            // to their left for the chroma filter, and stores nothing.
            encoder.dispatchThreadgroups(
                MTLSize(width: ((width + 1) / 2 + 30) / 31, height: ((height + 1) / 2 + 7) / 8, depth: 1),
                threadsPerThreadgroup: group)
        } else {
            encoder.dispatchThreadgroups(
                MTLSize(width: ((width + 1) / 2 + group.width - 1) / group.width,
                        height: ((height + 1) / 2 + group.height - 1) / group.height, depth: 1),
                threadsPerThreadgroup: group)
        }
        encoder.endEncoding()
        // The source picture has to outlive the pass that reads through it,
        // and nothing waits for it here any more: the handler is what holds
        // it until it has landed. The wrappers ride along to this point and
        // no further - their release is handed to the owner queue, which is
        // the thread their teardown must happen on.
        let pool = self.pool
        command.addCompletedHandler { [wrapped, cacheQueue, gpuTiming, passTimer] buffer in
            passTimer?.record(buffer, slot: slot, encoded: timed)
            gpuTiming.record((buffer.gpuEndTime - buffer.gpuStartTime) * 1000, beyondPool: pool?.allocatedBeyond ?? 0)
            completion(output)
            cacheQueue.async { wrapped.release() }
        }
        command.commit()
    }

    /// How far under the display's peak, in light, a scene's smoothed peak
    /// has to sit for its frames to be mapped off the LUT: room for a bright
    /// cut.
    static let compressionMargin: Float = 1.25

    deinit {
        // what the cache still holds goes back to the pool while it is there
        cacheQueue.sync { CVMetalTextureCacheFlush(textureCache, 0) }
    }

    /// Frees the mapped pictures the pool is holding for reuse and nobody is
    /// using. This pool has no allocation threshold, so it keeps one buffer
    /// for every picture that was ever in flight at once - 31.6 MB each at
    /// 4K on a screen without headroom, 63.3 with - and one busy moment
    /// early in a film is paid for until the file closes. The caller
    /// serializes this against `map`.
    func releaseSpareBuffers() {
        pool?.releaseSpareBuffers()
    }

    private func texture(
        _ buffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat, width: Int, height: Int
    ) throws -> CVMetalTexture {
        var texture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, buffer, writableTexture, format, width, height, plane, &texture
        )
        guard status == kCVReturnSuccess, let texture else {
            throw ToneMapError.textureFailed(status)
        }
        return texture
    }

    private func lutTexture() throws -> MTLTexture {
        if let lut { return lut }
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .rgba16Float
        descriptor.width = ToneMapper.lutSize
        descriptor.height = ToneMapper.lutSize
        descriptor.depth = ToneMapper.lutSize
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        guard let made = device.makeTexture(descriptor: descriptor) else { throw ToneMapError.noDevice }
        lut = made
        return made
    }

    private func makeOutput(width: Int, height: Int) throws -> CVPixelBuffer {
        if pool == nil || poolWidth != width || poolHeight != height {
            guard let created = try? PixelBufferPool(
                width: Int32(width), height: Int32(height), pixelFormat: pixelFormat,
                warmCount: 2, ceilingBytes: poolCeilingBytes, rendererAttributes: rendererAttributes
            ) else { throw ToneMapError.bufferFailed(kCVReturnAllocationFailed) }
            pool = created
            poolWidth = width
            poolHeight = height
        }
        var taken = pool!.take()
        if taken == nil {
            // The cache holds every texture it vends and the pixel buffer
            // behind it, so a pool never recycles until the cache lets go.
            // Each landed pass flushes it; a pool still dry here may be
            // waiting on a flush that has not run yet.
            cacheQueue.sync { CVMetalTextureCacheFlush(textureCache, 0) }
            taken = pool!.take()
        }
        // A burst past the ceiling is served from outside the pool - memory
        // that is really given back - rather than costing the picture.
        guard let buffer = taken ?? pool!.takeBeyondCapacity() else {
            throw ToneMapError.bufferFailed(kCVReturnAllocationFailed)
        }
        if let colorSpace {
            CVBufferSetAttachment(
                buffer, kCVImageBufferCGColorSpaceKey, colorSpace, .shouldPropagate
            )
        } else {
            // What the PQ picture is: the tags a decoder would have set, and
            // the light the curve mapped it onto.
            let tags: [(CFString, CFTypeRef)] = [
                (kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020),
                (kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ),
                (kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020),
                (kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_Left),
                (kCVImageBufferChromaLocationBottomFieldKey, kCVImageBufferChromaLocation_Left),
            ]
            for (key, value) in tags {
                CVBufferSetAttachment(buffer, key, value, .shouldPropagate)
            }
            if let staticMetadata {
                CVBufferSetAttachment(
                    buffer, kCVImageBufferMasteringDisplayColorVolumeKey,
                    staticMetadata.masteringDisplay as CFData, .shouldPropagate)
                CVBufferSetAttachment(
                    buffer, kCVImageBufferContentLightLevelInfoKey,
                    staticMetadata.contentLight as CFData, .shouldPropagate)
            }
        }
        return buffer
    }

    static let shader = """
    #include <metal_stdlib>
    using namespace metal;

    \(BlueNoise.shader)

    \(Deband.shader)

    constant float pq_m1 = 0.1593017578125;
    constant float pq_m2 = 78.84375;
    constant float pq_c1 = 0.8359375;
    constant float pq_c2 = 18.8515625;
    constant float pq_c3 = 18.6875;

    struct Parameters {
        float3x3 ycc;
        float3 offset;
        float sourceMinPQ;
        float sourceMaxPQ;
        float targetMinPQ;
        float targetMaxPQ;
        uint sourceTransfer;
    };

    struct Adaptation {
        uint reading;
        float seconds;
        uint keepsLUT;
    };

    // What the smoothing carries from one frame to the next, as PQ codes.
    struct State {
        float peak;
        float average;
        uint valid;
        // 1 once `last` holds a reading
        uint leveled;
        float built[\(ToneMapper.builtFigures)];
        // the last counted frame's share of every pixel in each of the
        // levelBins bins over PQ
        float last[\(ToneMapper.levelBins)];
    };

    constant uint levelBins = \(ToneMapper.levelBins);

    // What lexis_tone_map is specialized on, ToneMapper.toneMapPipeline's
    // variant: the store, 0 half floats, 1 eight bit BT.709, 2 ten bit PQ
    // YCbCr 4:2:0, 3 the same 4:2:2, then the reshaping, the transfer and
    // whether the LUT stands in for the map. Each holds for a whole film.
    constant uint storeKind [[function_constant(0)]];
    constant bool reshapesDovi [[function_constant(1)]];
    constant bool decodesHLG [[function_constant(2)]];
    // The map reads the pixel's own colour work off the frame's LUT.
    constant bool lookedUp [[function_constant(3)]];

    static inline float pq_eotf(float value) {
        float p = pow(max(value, 0.0f), 1.0f / pq_m2);
        return pow(max(p - pq_c1, 0.0f) / (pq_c2 - pq_c3 * p), 1.0f / pq_m1);
    }

    static inline float pq_ieotf(float linear) {
        float p = pow(max(linear, 0.0f), pq_m1);
        return pow((pq_c1 + pq_c2 * p) / (1.0f + pq_c3 * p), pq_m2);
    }

    // ITU-R BT.2100 HLG: inverse OETF back to scene light, then the 1000 nit
    // reference OOTF (system gamma 1.2 on scene luminance), onto the same
    // 10000-nits-is-1.0 axis PQ decodes to.
    static inline float3 hlg_to_linear(float3 signal) {
        const float a = 0.17883277f;
        const float b = 0.28466892f;
        const float c = 0.55991073f;
        float3 scene;
        for (uint i = 0; i < 3; i++) {
            scene[i] = signal[i] <= 0.5f
                ? signal[i] * signal[i] / 3.0f
                : (exp((signal[i] - c) / a) + b) / 12.0f;
        }
        float luminance = dot(scene, float3(0.2627f, 0.6780f, 0.0593f));
        return scene * pow(max(luminance, 1e-6f), 0.2f) * 0.1f;
    }

    // BT.2390's knee over a unit range: the identity up to the knee's start,
    // a Hermite spline from there that lands 1 on maxLum with a flat slope.
    // The spline is only a knee while its start is not below zero, which is
    // a maxLum of a third; under that the knee is a shoulder instead, with
    // unit slope at zero and maxLum as its asymptote, which never lands on
    // maxLum but never crosses zero either.
    static inline float knee(float e1, float maxLum) {
        float ks = 1.5f * maxLum - 0.5f;
        if (ks < 0.0f) return maxLum * (1.0f - exp(-e1 / max(maxLum, 1e-4f)));
        if (e1 <= ks) return e1;
        float t = (e1 - ks) / max(1.0f - ks, 1e-6f);
        float t2 = t * t;
        float t3 = t2 * t;
        return (2.0f * t3 - 3.0f * t2 + 1.0f) * ks
             + (t3 - 2.0f * t2 + t) * (1.0f - ks)
             + (-2.0f * t3 + 3.0f * t2) * maxLum;
    }

    // ITU-R BT.2390 EETF: a Hermite knee in PQ space between what the frame
    // holds and what the display can show. Applied to max(R,G,B), never per
    // channel, so the mapping scales a pixel without turning its hue.
    static inline float eetf(float pq, constant Parameters &p) {
        float span = max(p.sourceMaxPQ - p.sourceMinPQ, 1e-6f);
        float e1 = clamp((pq - p.sourceMinPQ) / span, 0.0f, 1.0f);
        float maxLum = clamp((p.targetMaxPQ - p.sourceMinPQ) / span, 0.0f, 1.0f);
        // negative where the display's black is under the grade's: BT.2390's
        // lift then lowers it, and the grade's black lands on the display's
        float minLum = clamp((p.targetMinPQ - p.sourceMinPQ) / span, -1.0f, 1.0f);
        float e2 = knee(e1, maxLum);
        float d = 1.0f - e2;
        return (e2 + minLum * d * d * d * d) * span + p.sourceMinPQ;
    }

    // Catmull-Rom over the chroma plane for the block's four pixels,
    // separably. Each pixel's footprint is four samples each way, and the
    // four footprints overlap in all but the one row or column the block's
    // second pixel reaches past its first, so the block reads their union
    // once, up to five samples each way. Each row is filtered across for the
    // block's two columns as it is read, and those rows down for its two
    // rows after: only the rows' sums and the nine samples the clamp needs
    // stay live. Bilinear alone smears every colour edge over two luma
    // pixels; nearest stair-steps it. Each result is held within the four
    // samples nearest its pixel: a cubic overshoots either side of a hard
    // edge, and on a saturated edge that overshoot is a fringe of the wrong
    // colour.
    struct BlockChroma {
        float2 values[2][2];
    };

    // The chroma samples come from the group's tile, loaded once by
    // lexis_tone_map: `tileOrigin` is the chroma sample the tile starts at,
    // each entry already clamped to the plane.
    constant int chromaTileWidth = 38;
    constant int chromaTileHeight = 14;
    // The cubic's weights for every block of a frame, x then y, the first
    // pixel's then the second's: a block starts on an even pixel, so each
    // sits the same fraction of a sample from the chroma, and the weights
    // are drawn once, by `ToneMapper.chromaFilter`, rather than per block.
    // `shift` is where the second pixel's footprint starts inside the
    // union, 0 or 1.
    struct ChromaFilter {
        float wx[2][5];
        float wy[2][5];
        int2 shift;
    };

    static inline BlockChroma chroma_block(threadgroup const float2 *chromaTile, int2 tileOrigin,
                                           uint2 block, float2 siting, constant ChromaFilter &filter) {
        int2 shift = filter.shift;
        constant float (&wy)[2][5] = filter.wy;
        int2 base = int2(floor((float2(block) - siting) * 0.5f)) - 1;
        int2 span = 4 + shift;
        // Each row filtered across for the block's two columns as it is read:
        // a weight is zero on the column a footprint leaves out.
        constant float (&wx)[2][5] = filter.wx;
        float2 across[5][2];
        float2 near[3][3];
        int2 inTile = base - tileOrigin;
        for (int j = 0; j < 5; j++) {
            across[j][0] = float2(0.0f);
            across[j][1] = float2(0.0f);
            for (int i = 0; i < 5; i++) {
                int at = (inTile.y + j) * chromaTileWidth + inTile.x + i;
                float2 sample = i < span.x && j < span.y ? chromaTile[at] : float2(0.0f);
                across[j][0] += sample * wx[0][i];
                across[j][1] += sample * wx[1][i];
                if (j >= 1 && j <= 3 && i >= 1 && i <= 3) near[j - 1][i - 1] = sample;
            }
        }
        BlockChroma result;
        for (int y = 0; y < 2; y++) {
            for (int x = 0; x < 2; x++) {
                float2 sum = float2(0.0f);
                for (int j = 0; j < 5; j++) sum += across[j][x] * wy[y][j];
                int right = x * shift.x;
                int down = y * shift.y;
                float2 a = down ? (right ? near[1][1] : near[1][0]) : (right ? near[0][1] : near[0][0]);
                float2 b = down ? (right ? near[1][2] : near[1][1]) : (right ? near[0][2] : near[0][1]);
                float2 c = down ? (right ? near[2][1] : near[2][0]) : (right ? near[1][1] : near[1][0]);
                float2 d = down ? (right ? near[2][2] : near[2][1]) : (right ? near[1][2] : near[1][1]);
                result.values[y][x] = clamp(sum, min(min(a, b), min(c, d)), max(max(a, b), max(c, d)));
            }
        }
        return result;
    }

    // A ten bit YCbCr sample, normalized, to the RGB signal it encodes.
    // Dolby Vision profile 5, whose base layer is IPT and no picture: each
    // component runs through the RPU's reshaping curve, a polynomial in
    // itself or an MMR over all three between pivots, before the RPU's
    // matrix, as libplacebo's pl_shader_dovi_reshape does. `dovi` is laid
    // out as ToneMapper.doviReshaping packs it; a cleared flag is any
    // other stream.
    constant uint doviHeader = \(ToneMapper.doviHeader);
    constant uint doviPiece = \(ToneMapper.doviPiece);
    constant uint doviComponent = \(ToneMapper.doviComponent);
    static inline float3 dovi_reshape(float3 signal, constant float *dovi) {
        float3 sig = clamp(signal, 0.0f, 1.0f);
        float4 cross = float4(sig.x * sig.y, sig.x * sig.z, sig.y * sig.z, sig.x * sig.y * sig.z);
        float3 shaped = sig;
        for (uint c = 0; c < 3; c++) {
            constant float *curve = dovi + doviHeader + c * doviComponent;
            uint pivots = uint(curve[0]);
            if (pivots < 2) continue;
            float s = sig[c];
            uint piece = 0;
            for (uint i = 1; i + 1 < pivots; i++) {
                if (s >= curve[1 + i]) piece = i;
            }
            constant float *k = curve + 10 + piece * doviPiece;
            float value;
            if (k[0] == 0.0f) {
                value = (k[3] * s + k[2]) * s + k[1];
            } else {
                value = k[5];
                float3 power = sig;
                float4 crossPower = cross;
                for (uint order = 0; order < uint(k[4]); order++) {
                    constant float *m = k + 6 + order * 7;
                    value += m[0] * power.x + m[1] * power.y + m[2] * power.z
                        + m[3] * crossPower.x + m[4] * crossPower.y + m[5] * crossPower.z
                        + m[6] * crossPower.w;
                    power *= sig;
                    crossPower *= cross;
                }
            }
            shaped[c] = clamp(value, curve[1], curve[pivots]);
        }
        return shaped;
    }

    // `reshapes` is the flag, passed apart so the curve's specialized
    // kernel can compile the branch away.
    static inline float3 decode_signal(float3 ycc, constant Parameters &p, constant float *dovi,
                                       bool reshapes) {
        // a 10 bit code sits in the top bits of the 16 bit sample
        ycc = ycc * (65535.0f / 65472.0f);
        if (reshapes) ycc = dovi_reshape(ycc, dovi);
        return clamp(p.ycc * (ycc - p.offset), 0.0f, 1.0f);
    }

    // An RGB signal, as decode_signal leaves it, to linear light on the axis
    // where 1.0 is 10000 nits.
    static inline float3 linear_of(float3 rgb, constant float *dovi, bool reshapes, bool hlg) {
        float3 linear = hlg ? hlg_to_linear(rgb) : float3(pq_eotf(rgb.r), pq_eotf(rgb.g), pq_eotf(rgb.b));
        if (reshapes) {
            // the RPU's LMS into BT.2020, the rows packed one after another
            float3x3 toRGB = transpose(float3x3(float3(dovi[1], dovi[2], dovi[3]),
                                                float3(dovi[4], dovi[5], dovi[6]),
                                                float3(dovi[7], dovi[8], dovi[9])));
            linear = max(toRGB * linear, 0.0f);
        }
        return linear;
    }

    // The histogram's resolution, in bins over the PQ range.
    constant uint histogramBins = \(ToneMapper.histogramBins);
    // Codes under this are bars, noise and the floor, and take no part in
    // what the frame is measured to hold: a percent of PQ, about 0.1 nit.
    constant float blackCutoffPQ = 0.01f;
    constant float peakPercentile = 0.99995f;
    // The smoothing's time constant: libplacebo finds flicker gone at 20
    // frames, where 10 still shows it, here 20 frames of a 24 frame film.
    constant float smoothingSeconds = 20.0f / 24.0f;
    // A cut is read on the mean, in PQ: under a percent a change is a drift
    // within the shot, past three it is a new shot, and between the two the
    // reading is taken in proportion.
    constant float cutLowPQ = 0.01f;
    constant float cutHighPQ = 0.03f;
    // The same read on the shares of the picture at each level, from one
    // frame to the next: under three tenths moved a pan or a fade, past half
    // a new shot.
    constant float cutLowShare = 0.3f;
    constant float cutHighShare = 0.5f;

    // The peak of every pixel's brightest channel, in PQ, counted into the
    // frame's histogram. Reduced through the threadgroup rather than one
    // atomic per pixel - eight million of those at 4K - and through shared
    // memory rather than the SIMD-group reductions, which are Apple family 7
    // and later and the A12 of the Apple TV 4K of 2021 is not. One thread
    // per run of measuredPerThread blocks along a row, so a group's clear and
    // merge of every bin is paid over that many; each 2x2 block's pixels
    // share the nearest chroma sample: a bin is a 256th of the range, and
    // the chroma filter moves nothing that far.
    constant uint measuredPerThread = \(ToneMapper.measuredPerThread);
    // Every kernel here is dispatched in groups of 256 at most, and says so:
    // unsaid, the compiler budgets registers for 1024 a group, and a kernel
    // this size then spills to memory on every thread.
    [[max_total_threads_per_threadgroup(256)]]
    kernel void lexis_measure(texture2d<float, access::read> luma [[texture(0)]],
                              texture2d<float, access::read> chroma [[texture(1)]],
                              constant Parameters &p [[buffer(0)]],
                              device atomic_uint *histogram [[buffer(1)]],
                              constant float *dovi [[buffer(2)]],
                              uint2 gid [[thread_position_in_grid]],
                              uint slot [[thread_index_in_threadgroup]]) {
        // 256 threads a group, the dispatch's 32 x 8: each clears and merges
        // every 256th bin.
        threadgroup atomic_uint bins[\(ToneMapper.histogramBins)];
        for (uint bin = slot; bin < histogramBins; bin += 256) {
            atomic_store_explicit(&bins[bin], 0u, memory_order_relaxed);
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        uint2 size = uint2(luma.get_width(), luma.get_height());
        uint2 chromaLimit = uint2(chroma.get_width(), chroma.get_height()) - 1;
        bool reshapes = dovi[0] != 0.0f;
        // Neighbouring pixels land in the same bin far more often than not,
        // and every atomic on one bin waits for the one before it: a run of
        // one bin is counted here and added once, when the bin changes.
        uint heldBin = histogramBins, held = 0;
        for (uint run = 0; run < measuredPerThread; run++) {
            // One 2x2 block in four, every other one each way: a quarter of
            // the picture is two million pixels at 4K, which the percentile
            // reads the same as eight, as libplacebo measures at a reduced
            // size.
            // The 32 threads of a row side by side at each step, a group
            // covering its span in measuredPerThread steps: one step's
            // reads share a few cache lines rather than one line a thread.
            uint2 sample = uint2((gid.x / 32u) * 32u * measuredPerThread + run * 32u + gid.x % 32u, gid.y);
            uint2 block = sample * 4;
            if (block.x >= size.x || block.y >= size.y) break;
            float2 c = chroma.read(min(sample * 2, chromaLimit)).rg;
            for (uint dy = 0; dy < 2; dy++) {
                for (uint dx = 0; dx < 2; dx++) {
                    uint2 pixel = block + uint2(dx, dy);
                    if (pixel.x >= size.x || pixel.y >= size.y) continue;
                    float3 ycc = float3(luma.read(pixel).r, c);
                    float3 rgb = decode_signal(ycc, p, dovi, reshapes);
                    // PQ is its own code: the brightest channel's code is
                    // the peak. HLG and profile 5's LMS go through to linear
                    // light and back onto the PQ axis.
                    float peak = max3(rgb.r, rgb.g, rgb.b);
                    if (p.sourceTransfer != 0 || reshapes) {
                        float3 linear = linear_of(rgb, dovi, reshapes, p.sourceTransfer == 1);
                        peak = pq_ieotf(max3(linear.r, linear.g, linear.b));
                    }
                    uint bin = min(uint(clamp(peak, 0.0f, 1.0f) * float(histogramBins)), histogramBins - 1);
                    if (bin == heldBin) {
                        held++;
                        continue;
                    }
                    if (held > 0) atomic_fetch_add_explicit(&bins[heldBin], held, memory_order_relaxed);
                    heldBin = bin;
                    held = 1;
                }
            }
        }
        if (held > 0) atomic_fetch_add_explicit(&bins[heldBin], held, memory_order_relaxed);
        threadgroup_barrier(mem_flags::mem_threadgroup);
        for (uint bin = slot; bin < histogramBins; bin += 256) {
            uint count = atomic_load_explicit(&bins[bin], memory_order_relaxed);
            if (count > 0) {
                atomic_fetch_add_explicit(&histogram[bin], count, memory_order_relaxed);
            }
        }
    }

    // The frame's histogram cleared ahead of its count, a thread a bin.
    kernel void lexis_clear_histogram(device uint *histogram [[buffer(1)]],
                                      uint bin [[thread_position_in_grid]]) {
        histogram[bin] = 0u;
    }

    // smoothstep that also runs downhill, edge0 above edge1, as libplacebo's
    // own does: Metal leaves that case undefined.
    static inline float ramp(float edge0, float edge1, float x) {
        float t = clamp((x - edge0) / (edge1 - edge0), 0.0f, 1.0f);
        return t * t * (3.0f - 2.0f * t);
    }

    // The bin under which all but `spared` of the lit pixels sit, walked down
    // from the top: a thread's run of bins at a time, then the bins of the run
    // the share ends in.
    static inline uint percentile_bin(device const uint *histogram, threadgroup const uint *runs, uint spared,
                                      uint run, uint cutoff) {
        uint seen = 0;
        for (int at = 255; at >= 0; at--) {
            if (seen + runs[at] <= spared) {
                seen += runs[at];
                continue;
            }
            for (int bin = at * int(run) + int(run) - 1; bin >= max(at * int(run), int(cutoff)); bin--) {
                seen += histogram[bin];
                if (seen > spared) return uint(bin);
            }
            break;
        }
        return cutoff;
    }

    // Once per frame: the frame's own curve, from the given parameters and
    // what the frame was read to hold.
    //
    // What the frame held comes off the counts of its codes per bin: the
    // peak at the percentile and the mean, both above the cutoff, and the
    // part of the frame above the cutoff. 256 threads, the dispatch's, read
    // the bins, each a run of them, and the sums go down a tree; the rest is
    // the first thread's.
    //
    // The reading is smoothed over 20 frames of a 24 frame film, peak and
    // mean alike, in seconds whatever the rate, so a
    // flash or a drift within a shot never makes the screen breathe; a jump
    // of the mean, weighed by the part of the frame it lights, is a cut and
    // is taken at once, so a new shot is mapped for itself from its first
    // picture and a fade on black is not.
    //
    // A stated peak may only be narrowed. It is the file's own ceiling,
    // and a curve built for 4000 nits on a film that never passes 400
    // spends its range on light that is not in the picture; the shadows
    // pay for that. Above it the curve is entitled to clip, because the
    // grade says nothing lives there. A peak nobody stated may move either
    // way, and the upward case is the one that matters: the assumption is
    // 1000 nits, the curve clamps everything above its source peak onto the
    // display's, and a 4000 nit master whose box did not survive the remux
    // would lose every highlight to a flat white.
    [[max_total_threads_per_threadgroup(256)]]
    kernel void lexis_settle(device const uint *histogram [[buffer(0)]],
                             constant Parameters &given [[buffer(1)]],
                             constant Adaptation &adaptation [[buffer(2)]],
                             device State &state [[buffer(3)]],
                             device Parameters &settled [[buffer(4)]],
                             device uint *lutGroups [[buffer(5)]],
                             uint slot [[thread_index_in_threadgroup]]) {
        const uint run = histogramBins / 256;
        const uint cutoff = uint(blackCutoffPQ * float(histogramBins));
        // per thread, then summed down the tree into the first entry: the
        // counts under the cutoff and above it, and the codes above it
        // weighted by their counts
        threadgroup uint darkCounts[256];
        threadgroup uint litCounts[256];
        threadgroup float weighted[256];
        // each thread's own count above the cutoff, kept for the peak's walk
        threadgroup uint runs[256];
        bool counts = adaptation.reading != 0;
        if (counts) {
            uint dark = 0, above = 0;
            float weight = 0.0f;
            for (uint bin = slot * run; bin < (slot + 1) * run; bin++) {
                uint count = histogram[bin];
                if (bin < cutoff) {
                    dark += count;
                } else {
                    above += count;
                    weight += float(count) * (float(bin) + 0.5f) / float(histogramBins);
                }
            }
            darkCounts[slot] = dark;
            litCounts[slot] = above;
            weighted[slot] = weight;
            runs[slot] = above;
            for (uint reach = 128; reach > 0; reach >>= 1) {
                threadgroup_barrier(mem_flags::mem_threadgroup);
                if (slot < reach) {
                    darkCounts[slot] += darkCounts[slot + reach];
                    litCounts[slot] += litCounts[slot + reach];
                    weighted[slot] += weighted[slot + reach];
                }
            }
            threadgroup_barrier(mem_flags::mem_threadgroup);
        }
        if (slot != 0) return;
        Parameters p = given;
        if (counts && litCounts[0] > 0) {
            uint total = litCounts[0];
            float peak = float(percentile_bin(histogram, runs, uint(ceil(float(total) * (1.0f - peakPercentile))),
                                              run, cutoff) + 1) / float(histogramBins);
            float average = weighted[0] / float(total);
            float lit = float(total) / float(total + darkCounts[0]);
            if (state.valid) {
                float rate = 1.0f - exp(-adaptation.seconds / smoothingSeconds);
                state.peak += (peak - state.peak) * rate;
                state.average += (average - state.average) * rate;
                // how far this frame is a cut: 1 takes every reading as it is
                float cut = ramp(cutLowPQ, cutHighPQ, abs(average - state.average) * lit);
                // A cut the mean does not show, a dark room to a lit face at
                // the same average, shows in where the picture's levels sit:
                // half the summed change of the shares since the frame before,
                // which a fade or a pan only moves a little at a time.
                if (state.leveled) {
                    const uint perBin = 256 / levelBins;
                    float everything = float(max(litCounts[0] + darkCounts[0], 1u));
                    float moved = 0.0f;
                    for (uint bin = 0; bin < levelBins; bin++) {
                        uint count = 0;
                        for (uint i = 0; i < perBin; i++) count += runs[bin * perBin + i];
                        moved += abs(float(count) / everything - state.last[bin]);
                    }
                    cut = max(cut, ramp(cutLowShare, cutHighShare, 0.5f * moved));
                }
                state.peak = cut >= 1.0f ? peak : mix(state.peak, peak, cut);
                state.average = cut >= 1.0f ? average : mix(state.average, average, cut);
            } else {
                state.peak = peak;
                state.average = average;
                state.valid = 1;
            }
        }
        // What the frame holds level by level, for the next frame's cut.
        uint whole = counts ? litCounts[0] + darkCounts[0] : 0;
        if (whole > 0) {
            const uint perBin = 256 / levelBins;
            for (uint bin = 0; bin < levelBins; bin++) {
                uint count = 0;
                for (uint i = 0; i < perBin; i++) count += runs[bin * perBin + i];
                state.last[bin] = float(count) / float(whole);
            }
            state.leveled = 1;
        }
        if (state.valid) {
            bool held = state.peak > p.sourceMinPQ + 0.01f;
            if (adaptation.reading == 1 && held) p.sourceMaxPQ = min(p.sourceMaxPQ, state.peak);
            else if (adaptation.reading == 2 && held) p.sourceMaxPQ = state.peak;
        }
        // The LUT is built again only where what it holds would move: the
        // settled figures, within what no screen shows, and whatever the
        // CPU saw change (keepsLUT 0).
        float figures[\(ToneMapper.builtFigures)] = { p.sourceMinPQ, p.sourceMaxPQ, p.targetMinPQ, p.targetMaxPQ };
        bool same = adaptation.keepsLUT != 0;
        for (uint i = 0; i < \(ToneMapper.builtFigures) && same; i++) {
            // within a ten bit code of what the LUT was built from: the
            // curve's drift under a code moves no pixel a screen can show
            same = abs(figures[i] - state.built[i]) <= 1e-3f + 1e-3f * abs(state.built[i]);
        }
        uint side = same ? 0 : (\(ToneMapper.lutSize) + 3) / 4;
        lutGroups[0] = side;
        lutGroups[1] = side;
        lutGroups[2] = side;
        if (!same) {
            for (uint i = 0; i < \(ToneMapper.builtFigures); i++) state.built[i] = figures[i];
        }
        settled = p;
    }

    // The picture's BT.2020 into the BT.709 an SDR screen shows; what falls
    // outside it is clipped by the store.
    static inline float3 to_bt709(float3 rgb2020) {
        float3x3 to709 = float3x3(float3(1.6605f, -0.1246f, -0.0182f),
                                  float3(-0.5876f, 1.1329f, -0.1006f),
                                  float3(-0.0728f, -0.0083f, 1.1187f));
        return to709 * rgb2020;
    }

    /// Two ten bit codes. A gradient bands because neighbouring codes differ
    /// by one and the eye finds the seam; two is enough to catch a step that
    /// has been resampled or lightly compressed, and low enough that grain,
    /// texture and any real edge sit far above it and are left alone.
    constant float debandThreshold = 2.0f * 64.0f / 65535.0f;

    // From where the curve landed a pixel to the light it leaves with: the
    // gain that carries the curve to all three channels. `brightest` is the
    // light the landed PQ's source decodes back to: the round trip through
    // the two transfer functions is two pows a pixel for nothing. Floored
    // rather than cut off: a curve that lifts black would otherwise step
    // from nothing to its floor at a thousandth of a nit. Shared by the map
    // and by the LUT that stands in for it.
    static inline float3 finish(float3 linear, float brightest, float landed) {
        return linear * (pq_eotf(landed) / max(brightest, 1e-7f));
    }

    // The PQ a mapped light is stored as.
    static inline float3 pq_store(float3 mapped) {
        float3 light = clamp(mapped, 0.0f, 1.0f);
        return float3(pq_ieotf(light.r), pq_ieotf(light.g), pq_ieotf(light.b));
    }

    constexpr sampler lutSampler(coord::normalized, address::clamp_to_edge, filter::linear);

    // The frame's LUT: at each grid point an RGB signal, and the PQ the map
    // would store for it with this frame's curve. Rebuilt every frame, as the
    // curve is settled every frame; built by a few hundred thousand threads
    // rather than by every pixel of the picture.
    kernel void lexis_lut(texture3d<float, access::write> lut [[texture(0)]],
                          constant Parameters &parameters [[buffer(0)]],
                          constant float *dovi [[buffer(1)]],
                          uint3 gid [[thread_position_in_grid]]) {
        uint n = lut.get_width();
        if (gid.x >= n || gid.y >= n || gid.z >= n) return;
        float3 linear = linear_of(float3(gid) / float(n - 1), dovi, reshapesDovi, decodesHLG);
        float brightest = max(linear.r, max(linear.g, linear.b));
        float landed = eetf(pq_ieotf(brightest), parameters);
        lut.write(float4(pq_store(finish(linear, brightest, landed)), 1.0f), gid);
    }

    // A PQ store's pixel: its luma written as a ten bit code where `writes`,
    // and what it adds to its block's chroma filter handed back.
    static inline float2 store_pq_luma(float3 pq, uint2 pixel, bool writes, texture2d<float, access::write> output) {
        float y = dot(pq, float3(0.2627f, 0.6780f, 0.0593f));
        if (writes) {
            // One code of dither before the round, as the eight bit store
            // gets: a ramp the curve stretched lands as a mix of two codes
            // rather than as a band edge.
            float noise = dither_offset(pixel);
            output.write(float4(round(64.0f + 876.0f * y + noise) * (64.0f / 65535.0f), 0.0f, 0.0f, 1.0f), pixel);
        }
        return float2((pq.b - y) / 1.8814f, (pq.r - y) / 1.4746f);
    }

    // One thread maps a 2x2 block, whose pixels share one chroma window.
    //
    // The PQ store writes the block's four luma codes and its chroma, BT.2020
    // non constant luminance, limited range, sited left as MPEG-2 has it
    // and as the buffer is tagged: a [1 2 1] filter over the block's first
    // column and the two beside it, one pair per row in 4:2:2, the two rows
    // averaged into one in 4:2:0.
    // The column on its left is the block before's, handed over through
    // threadgroup memory, so a row of 32 threads stores 31 blocks: its first
    // thread maps the right column of the block to their left, and stores
    // nothing.
    //
    // The block's chroma is rebuilt first, by the group over a tile it loads
    // once: written out at full size by a pass of its own and read back, it
    // would be most of a 4K frame's memory traffic.
    [[max_total_threads_per_threadgroup(256)]]
    kernel void lexis_tone_map(texture2d<float, access::read> luma [[texture(0)]],
                               texture2d<float, access::read> chroma [[texture(1)]],
                               texture2d<float, access::write> output [[texture(2)]],
                               texture2d<float, access::write> outputChroma [[texture(3)]],
                               texture3d<float, access::sample> lut [[texture(4)]],
                               constant Parameters &parameters [[buffer(0)]],
                               constant float2 &chromaSiting [[buffer(1)]],
                               constant float *dovi [[buffer(2)]],
                               constant ChromaFilter &filter [[buffer(3)]],
                               uint2 gid [[thread_position_in_grid]],
                               uint2 group [[threadgroup_position_in_grid]],
                               uint2 lane [[thread_position_in_threadgroup]],
                               uint simdIndex [[simdgroup_index_in_threadgroup]]) {
        // The chroma's tile, then once its blocks are rebuilt each thread's
        // right column, what its two rows add to the chroma filter, for the
        // thread after it; the dispatch is 32 x 8. One allocation serves
        // both: the less memory a group takes, the more groups a core holds.
        threadgroup float4 shared[(chromaTileWidth * chromaTileHeight * 2 + 3) / 4];
        threadgroup float4 (*rightColumns)[32] = reinterpret_cast<threadgroup float4 (*)[32]>(shared);
        const bool encodesPQ = storeKind == 2 || storeKind == 3;
        // a 10 bit code sits in the top bits of the 16 bit sample
        const float tenBitCode = 64.0f / 65535.0f;
        uint2 size = uint2(output.get_width(), output.get_height());
        int2 blockIndex = encodesPQ ? int2(int(group.x * 31 + lane.x) - 1, int(gid.y)) : int2(gid);
        int2 block = blockIndex * 2;
        bool inside = block.x >= 0 && block.x < int(size.x) && block.y < int(size.y);
        int2 chromaOrigin = int2(floor((float2((blockIndex - int2(lane)) * 2) - chromaSiting) * 0.5f)) - 1;
        // Every sample a block reads is read by up to 25 of its neighbours:
        // the group's window of chroma is read once here. The chroma is
        // debanded as it is read, at its own resolution and the luma's
        // threshold: a sky's hue steps as its light does.
        threadgroup float2 *chromaTile = reinterpret_cast<threadgroup float2 *>(shared);
        // A block whose luma is at or under video black, in a group whose
        // chroma is neutral, a bar or a fade, lands its pixels as one black
        // pixel lands: nothing round it lifts what it maps, and its per pixel
        // work is skipped.
        const bool skipsBlack = encodesPQ && !reshapesDovi;
        const float codeScale = 65535.0f / 65472.0f;
        bool tinted = false;
        {
            int2 limit = int2(chroma.get_width(), chroma.get_height()) - 1;
            for (int i = int(lane.y * 32 + lane.x); i < chromaTileWidth * chromaTileHeight; i += 256) {
                int2 at = clamp(chromaOrigin + int2(i % chromaTileWidth, i / chromaTileWidth), int2(0), limit);
                chromaTile[i] = deband(chroma, at, limit, 8.0f, debandThreshold);
                if (skipsBlack) tinted = tinted || any(abs(chromaTile[i] * codeScale - parameters.offset.yz) > 2.5f / 1023.0f);
            }
        }
        // one flag a SIMD group, which each writes whole: nothing to clear first
        threadgroup uint tintedGroups[8];
        if (skipsBlack) {
            // every lane takes part in the vote, the first stores it
            bool groupTinted = simd_any(tinted);
            if (simd_is_first()) tintedGroups[simdIndex] = groupTinted ? 1u : 0u;
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        if (!encodesPQ && !inside) return;
        bool dark = skipsBlack;
        if (skipsBlack) {
            for (uint i = 0; i < 8; i++) dark = dark && tintedGroups[i] == 0;
        }
        uint firstColumn = encodesPQ && lane.x == 0 ? 1 : 0;
        // The luma's bands flattened before anything reads it: a ten bit
        // ramp crosses a code along a line, and that line reads as a band.
        float lumaCodes[2][2] = { { 0.0f, 0.0f }, { 0.0f, 0.0f } };
        if (inside) {
            for (uint dy = 0; dy < 2; dy++) {
                for (uint dx = firstColumn; dx < 2; dx++) {
                    uint2 pixel = uint2(block) + uint2(dx, dy);
                    if (pixel.x >= size.x || pixel.y >= size.y) continue;
                    lumaCodes[dy][dx] = deband(luma, int2(pixel), int2(size) - 1, 16.0f, debandThreshold).x;
                    dark = dark && lumaCodes[dy][dx] * codeScale <= parameters.offset.x + 1.0f / 65472.0f;
                }
            }
        }
        // the block's chroma by row then column, each pair packed to sixteen
        // bits a channel: four registers held across the map rather than eight
        uint packedChroma[2][2] = { { 0u, 0u }, { 0u, 0u } };
        if (inside && !dark) {
            BlockChroma rebuilt = chroma_block(chromaTile, chromaOrigin, uint2(block), chromaSiting, filter);
            for (uint dy = 0; dy < 2; dy++) {
                for (uint dx = 0; dx < 2; dx++) packedChroma[dy][dx] = pack_float_to_unorm2x16(rebuilt.values[dy][dx]);
            }
        }
        // the right columns are written over the tile
        if (encodesPQ) threadgroup_barrier(mem_flags::mem_threadgroup);
        // what each pixel adds to the chroma filter, by row then column
        float2 filtered[2][2] = { { float2(0.0f), float2(0.0f) }, { float2(0.0f), float2(0.0f) } };
        if (inside && dark) {
            // the signal of a black pixel, as the per pixel path decodes it
            float3 pq;
            if (lookedUp) {
                float n = float(lut.get_width());
                pq = lut.sample(lutSampler, float3(0.5f / n)).rgb;
            } else {
                float3 linear = linear_of(float3(0.0f), dovi, reshapesDovi, decodesHLG);
                float brightest = max3(linear.r, linear.g, linear.b);
                float peak = decodesHLG ? pq_ieotf(brightest) : 0.0f;
                pq = pq_store(finish(linear, brightest, eetf(peak, parameters)));
            }
            for (uint dy = 0; dy < 2; dy++) {
                for (uint dx = 0; dx < 2; dx++) {
                    uint2 pixel = uint2(block) + uint2(dx, dy);
                    if (pixel.x >= size.x || pixel.y >= size.y) continue;
                    filtered[dy][dx] = store_pq_luma(pq, pixel, lane.x > 0, output);
                }
            }
        } else if (inside) {
            for (uint dy = 0; dy < 2; dy++) {
                for (uint dx = firstColumn; dx < 2; dx++) {
                    uint2 pixel = uint2(block) + uint2(dx, dy);
                    if (pixel.x >= size.x || pixel.y >= size.y) continue;
                    float3 ycc = float3(lumaCodes[dy][dx], unpack_unorm2x16_to_float(packedChroma[dy][dx]));
                    float3 signal = decode_signal(ycc, parameters, dovi, reshapesDovi);
                    float3 pq;
                    if (lookedUp) {
                        // everything this pixel's own colour decides, read off
                        // the frame's LUT: grid point k sits at (k + 0.5) / n
                        float n = float(lut.get_width());
                        pq = lut.sample(lutSampler, signal * ((n - 1.0f) / n) + 0.5f / n).rgb;
                    } else {
                        // The curve runs once, on the brightest channel, and the
                        // other two follow by the same factor. The ratio between
                        // channels is the hue: a curve applied per channel bends
                        // the brightest one alone, which pulls every mapped
                        // highlight toward white.
                        float3 linear = linear_of(signal, dovi, reshapesDovi, decodesHLG);
                        float brightest = max(linear.r, max(linear.g, linear.b));
                        // a PQ signal's brightest channel is already its peak
                        float peak = !decodesHLG && !reshapesDovi ? max3(signal.r, signal.g, signal.b)
                                                                  : pq_ieotf(brightest);
                        float3 mapped = finish(linear, brightest, eetf(peak, parameters));
                        if (storeKind < 2) {
                            // 10000 nits of PQ over the 100 that are SDR white
                            mapped *= 100.0f;
                            if (storeKind == 1) {
                                mapped = to_bt709(mapped);
                                // One eight bit code of dither before the store
                                // quantizes: a flat field between two codes leaves
                                // as a mix of both rather than as a band edge. The
                                // half float store never quantizes and gets none.
                                float noise = dither_offset(pixel);
                                for (uint i = 0; i < 3; i++) {
                                    // Gamma 2.4 with black at zero: BT.1886, the
                                    // reference SDR display EOTF, and measurably the
                                    // one CoreGraphics reads an ITU-R BT.709 picture
                                    // back through. The curve has already landed this
                                    // destination's peak on white: the clamp takes
                                    // what the gamut left outside BT.709, and guards
                                    // the last bit of arithmetic either side of 0 and 1.
                                    mapped[i] = pow(clamp(mapped[i], 0.0f, 1.0f), 1.0f / 2.4f);
                                }
                                mapped += noise / 255.0f;
                            }
                            output.write(float4(mapped, 1.0f), pixel);
                            continue;
                        }
                        pq = pq_store(mapped);
                    }
                    filtered[dy][dx] = store_pq_luma(pq, pixel, lane.x > 0, output);
                }
            }
        }
        if (!encodesPQ) return;
        rightColumns[lane.y][lane.x] = float4(filtered[0][1], filtered[1][1]);
        threadgroup_barrier(mem_flags::mem_threadgroup);
        if (lane.x == 0 || !inside) return;
        // The column left of the block, read again at the picture's left
        // edge, and the one right of its first, read again past its right.
        float4 left = block.x > 0 ? rightColumns[lane.y][lane.x - 1] : float4(filtered[0][0], filtered[1][0]);
        bool right = block.x + 1 < int(size.x);
        float2 rows[2];
        uint rowCount = uint(block.y) + 1 < size.y ? 2 : 1;
        for (uint dy = 0; dy < rowCount; dy++) {
            rows[dy] = 0.25f * ((dy == 0 ? left.xy : left.zw) + 2.0f * filtered[dy][0]
                                + (right ? filtered[dy][1] : filtered[dy][0]));
        }
        if (storeKind == 3) {
            for (uint dy = 0; dy < rowCount; dy++) {
                uint2 sample = uint2(blockIndex.x, block.y + int(dy));
                outputChroma.write(float4(round(512.0f + 896.0f * rows[dy] + dither_offset(sample)) * tenBitCode,
                                          0.0f, 1.0f), sample);
            }
            return;
        }
        float2 cbcr = rowCount == 2 ? 0.5f * (rows[0] + rows[1]) : rows[0];
        float noise = dither_offset(uint2(blockIndex));
        outputChroma.write(float4(round(512.0f + 896.0f * cbcr + noise) * tenBitCode, 0.0f, 1.0f), uint2(blockIndex));
    }
    """
}

extension ToneMapper {
    /// The frame's `ChromaFilter`, as the map reads it: the
    /// Catmull-Rom weights of a block's two pixels over the window's five
    /// samples on each axis, the four of each footprint where it sits and
    /// zero on the one outside it, then the shift, as 32-bit words. Every
    /// siting puts a pixel a multiple of a quarter from its sample, where
    /// the weights are exact, so they are the ones the GPU would draw.
    static func chromaFilter(siting: SIMD2<Float>) -> [UInt32] {
        var weights: [Float] = []
        var shifts: [Int32] = []
        for axis in 0..<2 {
            let first = -siting[axis] * 0.5
            let second = first + 0.5
            let shift = Int32(second.rounded(.down) - first.rounded(.down))
            for (at, offset) in [(first, Int32(0)), (second, shift)] {
                let f = at - at.rounded(.down)
                let w0 = f * (-0.5 + f * (1 - 0.5 * f))
                let w1 = 1 + f * f * (-2.5 + 1.5 * f)
                let w2 = f * (0.5 + f * (2 - 1.5 * f))
                let w3 = f * f * (-0.5 + 0.5 * f)
                weights += offset == 0 ? [w0, w1, w2, w3, 0] : [0, w0, w1, w2, w3]
            }
            shifts.append(shift)
        }
        return weights.map(\.bitPattern) + shifts.map { UInt32(bitPattern: $0) }
    }
}

/// Where the chroma samples sit inside each 2x2 luma block, in luma pixels,
/// as the picture is tagged: what a kernel reading the chroma at a luma
/// pixel samples at.
///
/// Left siting is 4:2:0's near-universal case - MPEG-2, and everything
/// H.264 and HEVC carry unless they say otherwise - so it is what an
/// unmarked buffer is read as, rather than the centred variant that would
/// shift every colour half a pixel to the right on the common case. A UHD
/// Blu-ray's HEVC says top left, sited on the block's first row rather than
/// between its two.
func chromaSiting(of buffer: CVPixelBuffer) -> SIMD2<Float> {
    let attachment = CVBufferCopyAttachment(buffer, kCVImageBufferChromaLocationTopFieldKey, nil) as? String
    return attachment.flatMap { chromaSitings[$0] } ?? SIMD2(0, 0.5)
}

private let chromaSitings: [String: SIMD2<Float>] = [
    kCVImageBufferChromaLocation_Center as String: SIMD2(0.5, 0.5),
    kCVImageBufferChromaLocation_TopLeft as String: SIMD2(0, 0),
    kCVImageBufferChromaLocation_Top as String: SIMD2(0.5, 0),
    kCVImageBufferChromaLocation_BottomLeft as String: SIMD2(0, 1),
    kCVImageBufferChromaLocation_Bottom as String: SIMD2(0.5, 1),
]

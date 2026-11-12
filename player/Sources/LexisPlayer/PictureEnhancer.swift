import CoreVideo
import Foundation
import Metal

/// The field builder an interlaced film goes through: each frame built up a
/// field at a time to a full picture, or as the film frame it carries, woven
/// back, and stored as ten bit YCbCr with the source's own codes and tags, so
/// the display shows it as the SDR picture it was. A frame with no field to
/// build is stored as it came.
public final class PictureEnhancer {
    public static let outputFormat = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange

    /// How a picture is built from an interlaced frame.
    public enum FieldBuild {
        /// One field built up to a full picture by `Deinterlacer`'s rule:
        /// `second` where it is the frame's second field, between the
        /// frames shown before and after, the frame itself standing in for
        /// one missing at either end.
        case field(VideoField, second: Bool, previous: CVPixelBuffer, next: CVPixelBuffer)
        /// A film frame woven back out of 3:2 pulldown: `field`'s rows from
        /// the frame and the others from `previous`, or the frame as it is
        /// where nil.
        case film(VideoField, previous: CVPixelBuffer?)
    }

    /// What each picture's pass costs the GPU.
    let gpuTiming = GPUTiming(label: "enhance")
    private let queue: MTLCommandQueue
    private let storePipeline: MTLComputePipelineState
    private let deinterlacePipeline: MTLComputePipelineState
    /// One field built up to a full picture, the store's input in place of
    /// the frame: private, sized with the frame, kept across frames. The
    /// queue runs its passes in order, so one set serves.
    private var fieldTextures: (luma: MTLTexture, chroma: MTLTexture)?
    private let textureCache: CVMetalTextureCache
    private let cacheQueue = DispatchQueue(label: "org.lexis.cvmetal.enhance")
    private var pool: PixelBufferPool?
    private var poolWidth = 0
    private var poolHeight = 0
    private let poolCeilingBytes: Int
    private let rendererAttributes: [String: Any]

    private struct Kernel {
        let device: MTLDevice
        let store: MTLComputePipelineState
        let deinterlace: MTLComputePipelineState
    }

    private static let kernelLock = NSLock()
    private static var kernel: Kernel?

    private static func compiledKernel() throws -> Kernel {
        kernelLock.lock()
        defer { kernelLock.unlock() }
        if let kernel { return kernel }
        guard let device = MTLCreateSystemDefaultDevice() else { throw ToneMapError.noDevice }
        let library = try device.makeLibrary(source: PictureEnhancer.shader, options: nil)
        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else { throw ToneMapError.noDevice }
            return try device.makeComputePipelineState(function: function)
        }
        let built = Kernel(
            device: device, store: try pipeline("lexis_store"), deinterlace: try pipeline("lexis_deinterlace"))
        kernel = built
        return built
    }

    public init(poolCeilingBytes: Int = 1024 * 1024 * 1024, rendererAttributes: [String: Any] = [:]) throws {
        self.poolCeilingBytes = poolCeilingBytes
        self.rendererAttributes = rendererAttributes
        let kernel = try PictureEnhancer.compiledKernel()
        guard let queue = kernel.device.makeCommandQueue() else { throw ToneMapError.noDevice }
        self.queue = queue
        storePipeline = kernel.store
        deinterlacePipeline = kernel.deinterlace
        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, kernel.device, nil, &cache)
        guard status == kCVReturnSuccess, let cache else { throw ToneMapError.textureFailed(status) }
        textureCache = cache
    }

    /// `frame` is eight or ten bit biplanar YCbCr, video range: what
    /// VideoToolbox hands back for an SDR stream when asked for its own
    /// depth. Encodes and commits without waiting, as the tone mapper does;
    /// `completion` runs on a Metal callback thread with the stored
    /// picture, tagged as the source was. With `field`, the picture is built
    /// from an interlaced frame that way, tagged progressive. `appending`
    /// encodes what follows into the same command buffer and answers the
    /// picture `completion` is handed instead.
    public func enhance(
        _ frame: CVPixelBuffer, field: FieldBuild? = nil,
        appending: ((MTLCommandBuffer, CVPixelBuffer) throws -> CVPixelBuffer)? = nil,
        completion: @escaping (CVPixelBuffer) -> Void
    ) throws {
        let format = CVPixelBufferGetPixelFormatType(frame)
        let tenBit: Bool
        switch format {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: tenBit = false
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange: tenBit = true
        default: throw ToneMapError.unsupportedFormat(format)
        }
        let width = CVPixelBufferGetWidthOfPlane(frame, 0)
        let height = CVPixelBufferGetHeightOfPlane(frame, 0)
        let chromaWidth = CVPixelBufferGetWidthOfPlane(frame, 1)
        let chromaHeight = CVPixelBufferGetHeightOfPlane(frame, 1)
        let output = try makeOutput(width: width, height: height, like: frame)
        if field != nil {
            CVBufferSetAttachment(output, kCVImageBufferFieldCountKey, 1 as CFNumber, .shouldPropagate)
            CVBufferRemoveAttachment(output, kCVImageBufferFieldDetailKey)
        }
        // the frames a field is built between, or a film frame woven with
        let neighbours: [CVPixelBuffer]
        switch field {
        case .field(_, _, let previous, let next): neighbours = [previous, next]
        case .film(_, let previous?): neighbours = [previous]
        default: neighbours = []
        }
        let wrapped = try cacheQueue.sync { () -> PassTextures in
            var planes: [CVMetalTexture] = []
            for picture in [frame] + neighbours {
                planes.append(try texture(picture, plane: 0, format: tenBit ? .r16Unorm : .r8Unorm, width: width, height: height))
                planes.append(try texture(
                    picture, plane: 1, format: tenBit ? .rg16Unorm : .rg8Unorm, width: chromaWidth, height: chromaHeight))
            }
            return PassTextures(
                planes + [
                    try texture(output, plane: 0, format: .r16Unorm, width: width, height: height),
                    try texture(output, plane: 1, format: .rg16Unorm, width: chromaWidth, height: chromaHeight),
                ], cache: textureCache, pool: pool)
        }
        let textures = wrapped.wrappers.map(CVMetalTextureGetTexture)
        guard let command = queue.makeCommandBuffer(),
            let encoder = command.makeComputeCommandEncoder()
        else { throw ToneMapError.noDevice }
        func dispatch(_ width: Int, _ height: Int) {
            encoder.dispatchThreadgroups(
                MTLSize(width: (width + 31) / 32, height: (height + 7) / 8, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 32, height: 8, depth: 1))
        }
        let outputs = (luma: textures[textures.count - 2], chroma: textures[textures.count - 1])
        var input: (luma: MTLTexture?, chroma: MTLTexture?) = (
            textures[0], textures[1])
        var deinterlace: (parity: UInt32, second: UInt32, weaves: UInt32, codes: Float)?
        switch field {
        case .field(let field, let second, _, _):
            deinterlace = (UInt32(field.firstRow), second ? 1 : 0, 0, Float(tenBit ? 65535 : 255))
        case .film(let field, _?):
            deinterlace = (UInt32(field.firstRow), 0, 1, Float(tenBit ? 65535 : 255))
        default: break
        }
        if var deinterlace {
            let built = try privateTextures(
                &fieldTextures, luma: tenBit ? .r16Unorm : .r8Unorm, chroma: tenBit ? .rg16Unorm : .rg8Unorm,
                width: width, height: height, chromaWidth: chromaWidth, chromaHeight: chromaHeight)
            encoder.setComputePipelineState(deinterlacePipeline)
            encoder.setBytes(&deinterlace, length: MemoryLayout.size(ofValue: deinterlace), index: 0)
            // a woven frame reads its previous frame alone: the frame stands in for the next
            let nextPlanes = neighbours.count > 1 ? 4 : 0
            for (plane, to) in [built.luma, built.chroma].enumerated() {
                encoder.setTexture(textures[2 + plane], index: 0)
                encoder.setTexture(textures[plane], index: 1)
                encoder.setTexture(textures[nextPlanes + plane], index: 2)
                encoder.setTexture(to, index: 3)
                dispatch(to.width, to.height)
            }
            input.luma = built.luma
            input.chroma = built.chroma
        }
        // ten bit codes per unit of the normalized input sample
        var codesPerUnit: Float = tenBit ? 65535.0 / 64 : 255 * 4
        encoder.setComputePipelineState(storePipeline)
        encoder.setTexture(input.luma, index: 0)
        encoder.setTexture(input.chroma, index: 1)
        encoder.setTexture(outputs.luma, index: 2)
        encoder.setTexture(outputs.chroma, index: 3)
        encoder.setBytes(&codesPerUnit, length: MemoryLayout<Float>.size, index: 0)
        // one thread per chroma sample
        dispatch(chromaWidth, chromaHeight)
        encoder.endEncoding()
        let delivered = try appending?(command, output) ?? output
        let pool = self.pool
        command.addCompletedHandler { [wrapped, cacheQueue, gpuTiming] buffer in
            gpuTiming.record((buffer.gpuEndTime - buffer.gpuStartTime) * 1000, beyondPool: pool?.allocatedBeyond ?? 0)
            completion(delivered)
            cacheQueue.async { wrapped.release() }
        }
        command.commit()
    }

    deinit {
        // what the cache still holds goes back to the pool while it is there
        cacheQueue.sync { CVMetalTextureCacheFlush(textureCache, 0) }
    }

    func releaseSpareBuffers() {
        pool?.releaseSpareBuffers()
    }

    private func texture(
        _ buffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat, width: Int, height: Int
    ) throws -> CVMetalTexture {
        var texture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, buffer, writableTexture, format, width, height, plane, &texture)
        guard status == kCVReturnSuccess, let texture else { throw ToneMapError.textureFailed(status) }
        return texture
    }

    /// A pair of private planes kept in `kept` across frames, made again
    /// only when the picture's size or depth moves.
    private func privateTextures(
        _ kept: inout (luma: MTLTexture, chroma: MTLTexture)?, luma lumaFormat: MTLPixelFormat,
        chroma chromaFormat: MTLPixelFormat, width: Int, height: Int, chromaWidth: Int, chromaHeight: Int
    ) throws -> (luma: MTLTexture, chroma: MTLTexture) {
        if let kept, kept.luma.pixelFormat == lumaFormat, kept.luma.width == width, kept.luma.height == height {
            return kept
        }
        func make(_ format: MTLPixelFormat, _ width: Int, _ height: Int) throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format, width: width, height: height, mipmapped: false)
            descriptor.usage = [.shaderRead, .shaderWrite]
            descriptor.storageMode = .private
            guard let texture = queue.device.makeTexture(descriptor: descriptor) else { throw ToneMapError.noDevice }
            return texture
        }
        let made = (try make(lumaFormat, width, height), try make(chromaFormat, chromaWidth, chromaHeight))
        kept = made
        return made
    }

    private func makeOutput(width: Int, height: Int, like source: CVPixelBuffer) throws -> CVPixelBuffer {
        if pool == nil || poolWidth != width || poolHeight != height {
            guard let created = try? PixelBufferPool(
                width: Int32(width), height: Int32(height), pixelFormat: PictureEnhancer.outputFormat,
                warmCount: 2, ceilingBytes: poolCeilingBytes, rendererAttributes: rendererAttributes)
            else { throw ToneMapError.bufferFailed(kCVReturnAllocationFailed) }
            pool = created
            poolWidth = width
            poolHeight = height
        }
        var taken = pool!.take()
        if taken == nil {
            // Each landed pass flushes the cache; a pool still dry here may be
            // waiting on a flush that has not run yet.
            cacheQueue.sync { CVMetalTextureCacheFlush(textureCache, 0) }
            taken = pool!.take()
        }
        guard let buffer = taken ?? pool!.takeBeyondCapacity() else {
            throw ToneMapError.bufferFailed(kCVReturnAllocationFailed)
        }
        // The picture is the source's: it keeps the source's own colour
        // tags, mastering data and chroma siting.
        CVBufferPropagateAttachments(source, buffer)
        return buffer
    }

    static let shader = """
    #include <metal_stdlib>
    using namespace metal;

    // a 10 bit code sits in the top bits of the 16 bit sample
    constant float tenBitUnit = 64.0f / 65535.0f;

    // One field of an interlaced plane as a full-height plane, the CPU
    // Deinterlacer's own rule, FFmpeg's bwdif, on whole codes: an eight bit
    // plane comes out as the CPU's does to the code. A 4:2:0 chroma plane's
    // rows alternate between the fields as the luma's do, so both planes run
    // through it, a chroma pair's two codes each on their own. With
    // `weaves`, the rows between are the previous frame's own: a film frame
    // woven back from its two fields.
    struct Deinterlace {
        uint parity;
        uint second;
        uint weaves;
        // codes per unit of the texture's normalized sample
        float codes;
    };

    static inline int2 codes_at(texture2d<float, access::read> plane, uint x, int row, float codes) {
        return int2(rint(plane.read(uint2(x, uint(row))).rg * codes));
    }

    // Row y, missing from the field, from `before` and `after`, the frames
    // holding the other field half a field either side; `previous` and
    // `next` are the frames either side of `current`.
    static inline int2 bwdif(texture2d<float, access::read> previous, texture2d<float, access::read> current,
                             texture2d<float, access::read> next, texture2d<float, access::read> before,
                             texture2d<float, access::read> after, uint x, int y, int height, float codes) {
        int up = y > 0 ? y - 1 : y + 1;
        int down = y + 1 < height ? y + 1 : y - 1;
        int2 c = codes_at(current, x, up, codes);
        int2 e = codes_at(current, x, down, codes);
        int2 early = codes_at(before, x, y, codes);
        int2 late = codes_at(after, x, y, codes);
        int2 d = (early + late) >> 1;
        int2 still = abs(early - late);
        int2 sincePrevious = (abs(codes_at(previous, x, up, codes) - c) + abs(codes_at(previous, x, down, codes) - e)) >> 1;
        int2 untilNext = (abs(codes_at(next, x, up, codes) - c) + abs(codes_at(next, x, down, codes) - e)) >> 1;
        int2 moved = max(still >> 1, max(sincePrevious, untilNext));
        int2 reach = moved;
        if (y >= 2 && y + 3 <= height) {
            int2 b = ((codes_at(before, x, y - 2, codes) + codes_at(after, x, y - 2, codes)) >> 1) - c;
            int2 f = ((codes_at(before, x, y + 2, codes) + codes_at(after, x, y + 2, codes)) >> 1) - e;
            int2 dc = d - c, de = d - e;
            int2 most = max(max(de, dc), min(b, f));
            int2 least = min(min(de, dc), max(b, f));
            reach = max(reach, max(least, -most));
        }
        int2 built;
        if (y >= 4 && y + 5 <= height) {
            int2 far = codes_at(current, x, y - 3, codes) + codes_at(current, x, y + 3, codes);
            int2 spatial = (5077 * (c + e) - 981 * far) >> 13;
            int2 twoAway = codes_at(before, x, y - 2, codes) + codes_at(after, x, y - 2, codes)
                + codes_at(before, x, y + 2, codes) + codes_at(after, x, y + 2, codes);
            int2 fourAway = codes_at(before, x, y - 4, codes) + codes_at(after, x, y - 4, codes)
                + codes_at(before, x, y + 4, codes) + codes_at(after, x, y + 4, codes);
            int2 high = (5570 * (early + late) - 3801 * twoAway + 1016 * fourAway) >> 2;
            int2 blended = (high + 4309 * (c + e) - 213 * far) >> 13;
            built = select(spatial, blended, abs(c - e) > still);
        } else {
            built = (c + e) >> 1;
        }
        built = clamp(min(max(built, d - reach), d + reach), int2(0), int2(int(codes)));
        // nothing moved in time: the other field's own rows, whatever the space says
        return select(built, d, moved == 0);
    }

    kernel void lexis_deinterlace(texture2d<float, access::read> previous [[texture(0)]],
                                  texture2d<float, access::read> current [[texture(1)]],
                                  texture2d<float, access::read> next [[texture(2)]],
                                  texture2d<float, access::write> out [[texture(3)]],
                                  constant Deinterlace &p [[buffer(0)]],
                                  uint2 gid [[thread_position_in_grid]]) {
        int height = int(current.get_height());
        if (gid.x >= current.get_width() || int(gid.y) >= height) return;
        // a plane of one row has no row of the other field to read
        if ((gid.y & 1u) == p.parity || height < 2) {
            out.write(current.read(gid), gid);
            return;
        }
        if (p.weaves != 0u) {
            out.write(previous.read(gid), gid);
            return;
        }
        int2 built = p.second != 0u
            ? bwdif(previous, current, next, current, next, gid.x, int(gid.y), height, p.codes)
            : bwdif(previous, current, next, previous, current, gid.x, int(gid.y), height, p.codes);
        out.write(float4(float2(built) / p.codes, 0.0f, 1.0f), gid);
    }

    // One thread per chroma sample: the four luma codes of its block and its
    // chroma pair, stored as the ten bit codes they are.
    kernel void lexis_store(texture2d<float, access::read> luma [[texture(0)]],
                            texture2d<float, access::read> chroma [[texture(1)]],
                            texture2d<float, access::write> outLuma [[texture(2)]],
                            texture2d<float, access::write> outChroma [[texture(3)]],
                            constant float &codesPerUnit [[buffer(0)]],
                            uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= outChroma.get_width() || gid.y >= outChroma.get_height()) return;
        uint2 size = uint2(outLuma.get_width(), outLuma.get_height());
        for (uint dy = 0; dy < 2; dy++) {
            for (uint dx = 0; dx < 2; dx++) {
                uint2 at = gid * 2 + uint2(dx, dy);
                if (at.x >= size.x || at.y >= size.y) continue;
                float stored = clamp(round(luma.read(at).r * codesPerUnit), 0.0f, 1023.0f);
                outLuma.write(float4(stored * tenBitUnit, 0.0f, 0.0f, 1.0f), at);
            }
        }
        float2 stored = clamp(round(chroma.read(gid).rg * codesPerUnit), 0.0f, 1023.0f);
        outChroma.write(float4(stored * tenBitUnit, 0.0f, 1.0f), gid);
    }
    """
}

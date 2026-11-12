import CoreML
import CoreMedia
import CoreVideo
import Foundation
import Metal
#if canImport(MetalFX)
import MetalFX
#endif

public enum UpscaleError: Error, Equatable {
    case noDevice
    /// A GPU older than the ones measured affording the pass; the caller
    /// keeps the path where the compositor scales.
    case unsupportedDevice
    case unsupportedFormat(OSType)
    case textureFailed(CVReturn)
    case bufferFailed(CVReturn)
    /// The learned filters are missing from the bundle or malformed.
    case filtersMissing
}

/// Prisme, the player's scaler. Doubles an SDR film's YCbCr, as the decoder
/// or the field builder hands it over. Ten bit 4:2:0 out, what the display
/// layer composes natively.
///
/// The luma is doubled by filters learned against true 4K, in the manner of
/// RAISR and BLADE: each pixel's gradients are summed into a structure
/// tensor, whose orientation, strength and coherence pick one of a few
/// dozen filter pairs. The first of the pair estimates the 4K pixel and the
/// second the same pixel blurred; their difference is the detail, which a
/// curve learned per class keeps, shrinks or raises, then the result is held
/// within the four source pixels around it. The filters come in two banks,
/// one learned on clean masters and one on starved encodes, mixed by how
/// starved the stream is. Trained by `Tools/prisme`. Where it keeps up, a
/// network on the Neural Engine doubles the luma in their place
/// (`Network`), trained by `Tools/prisme/network`.
///
/// Where the screen takes more than twice the source, as a 720p or SD
/// film's does, both doubled planes are finished to its size by Lanczos 3,
/// each pixel held within the four doubled ones around it so nothing rings.
///
/// The chroma leaves at the size of the source's luma: read between its
/// samples, then given the luma's own detail there by the local slope of
/// chroma on luma, so a colour's edge follows the luma's.
///
/// Encodes and commits, and never waits: `completion` runs on a Metal
/// callback thread once the pass has landed. The caller serializes calls.
public final class Upscaler {

    /// What comes out.
    static let pixelFormat = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
    /// The source pixels a class is shared across, each way.
    private static let classShare = 2
    /// What the pictures handed to `scale` have to be allocated with: read
    /// by Metal, and backed by an IOSurface for the texture cache to wrap.
    let inputAttributes: [String: Any] = [
        kCVPixelBufferMetalCompatibilityKey as String: true,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
    ]
    let gpuTiming = GPUTiming(label: "prisme")
    let outputWidth: Int
    let outputHeight: Int
    private let inputWidth: Int
    private let inputHeight: Int
    private let queue: MTLCommandQueue
    private let classify: MTLComputePipelineState
    private let learned: MTLComputePipelineState
    private let chroma: MTLComputePipelineState
    /// The two banks mixed for this stream: filters in half precision, a
    /// row of texels a pair, for the texture units to gather, the
    /// sum of each filter's taps, and the detail curves.
    private let filters: MTLTexture
    private let sums: MTLBuffer
    private let curves: MTLBuffer
    /// Each source pixel's class.
    private let kinds: MTLTexture
    /// The chroma's slope on the luma at each of the source's chroma sites,
    /// and that luma.
    private let chromaGuide: MTLTexture
    private let chromaSlope: MTLComputePipelineState
    /// The doubled picture's planes, where the output is larger than twice
    /// the source and `finish` resamples them to its size.
    private let doubled: (luma: MTLTexture, chroma: MTLTexture)?
    private let finish: MTLComputePipelineState
    private var parameters: Parameters
    private let textureAttributes: CFDictionary
    /// The colour the scaled picture is handed over as: the source's own,
    /// BT.709 where the file names nothing, and a matrix by its size. Empty
    /// where no source format was given.
    private let colourTags: [(CFString, CFTypeRef)]
    private let textureCache: CVMetalTextureCache
    private let pool: PixelBufferPool
    /// Each pass's own time under a trace.
    private let passTimer: PassTimer?
    /// The network the luma is doubled by instead of the filters, where it
    /// was asked for and the picture fits its canvas.
    private let network: Network?
    var isNeural: Bool { network != nil }
    /// The network while it keeps up with the film.
    private var activeNetwork: Network? { network?.refused == false ? network : nil }

    /// The luma doubled by a network on the Neural Engine rather than by the
    /// filters on the GPU, trained by `Tools/prisme` against the same true
    /// 4K: the picture handed over in half precision on a canvas of the
    /// network's size, and its output read back into the plane. The GPU keeps
    /// the chroma. The canvases are the network's own, so the pictures go
    /// through them one at a time.
    private final class Network {
        static let width = 1920
        static let height = 1088
        let model: MLModel
        let inputs: MLFeatureProvider
        let options: MLPredictionOptions
        /// The canvases as the GPU sees them, over the same memory.
        let input: MTLTexture
        let output: MTLTexture
        let toNetwork: MTLComputePipelineState
        let fromNetwork: MTLComputePipelineState
        /// How much the network's finest detail is raised: a fifth, and half
        /// again at the widest starvation. More scores higher against
        /// true 4K and scintillates on a still shot.
        let gain: Float
        let queue = DispatchQueue(label: "org.lexis.upscaler.network")
        /// The last picture's read off the output canvas, waited for only
        /// ahead of the next prediction, which overwrites the canvas. On
        /// `queue` alone.
        var reading: MTLCommandBuffer?
        /// The Neural Engine's time a picture, traced every 240.
        private var total = 0.0
        private var count = 0
        /// The first pictures' time, past the ones that warm the engine up:
        /// over `slowest` on average, the filters take the luma back, as on a
        /// Neural Engine too small to keep up with the film.
        private var trial: (total: Double, count: Int) = (0, 0)
        private static let warmUp = 3
        private static let trialLength = 24
        /// 25 ms, or less where the film's pictures come faster: a picture
        /// also waits on its fill pass, so a prediction gets 85% of a period.
        private let slowest: Double
        private let refusal = NSLock()
        private var tooSlow = false
        var refused: Bool {
            refusal.lock()
            defer { refusal.unlock() }
            return tooSlow
        }

        init(device: MTLDevice, library: MTLLibrary, starvation: Float, picturesPerSecond: Double)
            throws
        {
            slowest = min(25, 0.85 * 1000 / picturesPerSecond)
            guard let url = Bundle.module.url(forResource: "PrismeNet", withExtension: "mlmodelc") else {
                throw UpscaleError.filtersMissing
            }
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuAndNeuralEngine
            model = try MLModel(contentsOf: url, configuration: configuration)
            func canvas(_ width: Int, _ height: Int) throws -> (buffer: CVPixelBuffer, texture: MTLTexture) {
                var made: CVPixelBuffer?
                let status = CVPixelBufferCreate(
                    kCFAllocatorDefault, width, height, kCVPixelFormatType_OneComponent16Half,
                    [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary, kCVPixelBufferMetalCompatibilityKey: true]
                        as CFDictionary, &made)
                guard status == kCVReturnSuccess, let made, let surface = CVPixelBufferGetIOSurface(made)?.takeUnretainedValue()
                else { throw UpscaleError.bufferFailed(status) }
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .r16Float, width: width, height: height, mipmapped: false)
                descriptor.usage = [.shaderRead, .shaderWrite]
                guard let texture = device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0) else {
                    throw UpscaleError.noDevice
                }
                return (made, texture)
            }
            let small = try canvas(Network.width, Network.height)
            let large = try canvas(2 * Network.width, 2 * Network.height)
            input = small.texture
            output = large.texture
            let strength = try MLMultiArray(shape: [1, 1, 1, 1], dataType: .float16)
            strength[0] = NSNumber(value: starvation - 1)
            inputs = try MLDictionaryFeatureProvider(dictionary: [
                "luma": MLMultiArray(pixelBuffer: small.buffer, shape: [1, 1, Network.height, Network.width].map { NSNumber(value: $0) }),
                "strength": strength,
            ])
            options = MLPredictionOptions()
            options.outputBackings = [
                "scaled": MLMultiArray(
                    pixelBuffer: large.buffer, shape: [1, 1, 2 * Network.height, 2 * Network.width].map { NSNumber(value: $0) }),
            ]
            func pipeline(_ name: String) throws -> MTLComputePipelineState {
                guard let function = library.makeFunction(name: name) else { throw UpscaleError.noDevice }
                return try device.makeComputePipelineState(function: function)
            }
            toNetwork = try pipeline("lexis_to_network")
            fromNetwork = try pipeline("lexis_from_network")
            // the first prediction readies the Neural Engine for the model,
            // which costs a picture's worth of time and more: spent here,
            // ahead of the film's first picture
            queue.async { [model, inputs, options] in _ = try? model.prediction(from: inputs, options: options) }
            gain = 0.2 + 0.5 * min(max(starvation - 1, 0), 1)
        }

        /// The network over what is on the input canvas, into the output one.
        func predict() throws {
            let started = DispatchTime.now().uptimeNanoseconds
            _ = try model.prediction(from: inputs, options: options)
            let taken = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
            total += taken
            count += 1
            if trial.count < Network.warmUp + Network.trialLength {
                trial.count += 1
                if trial.count > Network.warmUp { trial.total += taken }
                if trial.count == Network.warmUp + Network.trialLength,
                    trial.total / Double(Network.trialLength) > slowest
                {
                    refusal.lock()
                    tooSlow = true
                    refusal.unlock()
                    let mean = trial.total / Double(Network.trialLength)
                    DispatchQueue.global(qos: .utility).async { [slowest] in
                        traceLine(String(
                            format: "[lexis.pass] network too slow at %.1f ms a frame, over %.1f: the filters take over",
                            mean, slowest))
                    }
                }
            }
            guard count == 240 else { return }
            let mean = total / Double(count)
            total = 0
            count = 0
            DispatchQueue.global(qos: .utility).async {
                traceLine(String(format: "[lexis.pass] network, ms a frame on the Neural Engine: %.2f", mean))
            }
        }
    }
    /// The one thread the texture cache is touched from: Core Video ties a
    /// cache's backing list to the thread that owns it.
    private let cacheQueue = DispatchQueue(label: "org.lexis.upscaler.cvmetal")

    /// Laid out as the shader's `Parameters`.
    private struct Parameters {
        /// Source pixels per output pixel, each way.
        var step: SIMD2<Float>
        /// Ten bit codes per unit of the source's samples.
        var codes: Float
        /// Where the source's chroma samples sit in each 2x2 luma block.
        var siting: SIMD2<Float>
    }

    /// The learned filters as the bundle carries them: `Prisme.lxsr`,
    /// written by the training that made them.
    private struct Bank {
        let taps: Int
        let angles: Int
        let strengths: [Float]
        let coherences: [Float]
        let levels: [Float]
        let knots: [Float]
        let classes: Int
        let rho: Float
        /// [level][phase][class][pair][tap]
        let filters: [Float]
        /// [level][class][knot]
        let curves: [Float]

        init(_ data: Data) throws {
            var at = 0
            func take<T>(_ count: Int, _: T.Type) throws -> [T] {
                let size = count * MemoryLayout<T>.size
                guard at + size <= data.count else { throw UpscaleError.filtersMissing }
                defer { at += size }
                return data.subdata(in: at..<at + size).withUnsafeBytes { Array($0.bindMemory(to: T.self)) }
            }
            guard try take(4, UInt8.self) == Array("LXSR".utf8) else { throw UpscaleError.filtersMissing }
            let header = try take(9, UInt32.self).map(Int.init)
            guard header[0] == 1, header[1] == 4 || header[1] == 6 else { throw UpscaleError.filtersMissing }
            taps = header[1]
            angles = header[2]
            classes = header[7]
            rho = try take(1, Float.self)[0]
            strengths = try take(header[3], Float.self)
            coherences = try take(header[4], Float.self)
            levels = try take(header[5], Float.self)
            knots = try take(header[6], Float.self)
            filters = try take(levels.count * 4 * classes * 2 * taps * taps, Float.self)
            curves = try take(levels.count * classes * knots.count, Float.self)
        }

        /// Each level's share of a stream this starved: the two nearest,
        /// linearly between them.
        func weights(_ starvation: Float) -> [Float] {
            let s = min(max(starvation, levels.first!), levels.last!)
            return levels.indices.map { index in
                let spacing = index > 0 ? levels[index] - levels[index - 1] : levels[1] - levels[0]
                return max(0, 1 - abs(s - levels[index]) / spacing)
            }
        }

        func mixed(_ values: [Float], _ starvation: Float) -> [Float] {
            let per = values.count / levels.count
            var out = [Float](repeating: 0, count: per)
            for (level, weight) in weights(starvation).enumerated() where weight > 0 {
                for index in 0..<per { out[index] += weight * values[level * per + index] }
            }
            return out
        }
    }

    /// `Prisme` learned on decoded pictures against true 4K, and its kernels,
    /// each made once for the process: a source compile is a few hundred
    /// milliseconds, which every open would otherwise pay.
    private static let bankLock = NSLock()
    private static var loaded: (bank: Bank, library: MTLLibrary)?

    private static func compiled(on device: MTLDevice) throws -> (bank: Bank, library: MTLLibrary) {
        bankLock.lock()
        defer { bankLock.unlock() }
        if let loaded { return loaded }
        guard let url = Bundle.module.url(forResource: "Prisme", withExtension: "lxsr"),
            let data = try? Data(contentsOf: url)
        else { throw UpscaleError.filtersMissing }
        let bank = try Bank(data)
        let made = (bank, try device.makeLibrary(source: Upscaler.shader(bank), options: nil))
        loaded = made
        return made
    }

    private static func shader(_ bank: Bank) -> String {
        func list(_ values: [Float]) -> String { values.map { "\($0)f" }.joined(separator: ", ") }
        let radius = Int((2 * bank.rho).rounded(.up))
        let gauss = (-radius...radius).map { exp(-Float($0 * $0) / (2 * bank.rho * bank.rho)) }
        let total = gauss.reduce(0, +)
        // the squared strength halfway, on a log scale, between two centres
        let bandEdges = zip(bank.strengths, bank.strengths.dropFirst()).map { pow(2, $0 + $1) }
        return """
        #include <metal_stdlib>
        using namespace metal;

        struct Parameters {
            float2 step;
            float codes;
            float2 siting;
        };

        // a 10 bit code sits in the top bits of the 16 bit sample
        constant float tenBitUnit = 64.0f / 65535.0f;
        constexpr sampler bilinear(coord::normalized, address::clamp_to_edge, filter::linear);

        constant int angles = \(bank.angles);
        constant int strengthCount = \(bank.strengths.count);
        constant int coherenceCount = \(bank.coherences.count);
        constant int classes = \(bank.classes);
        constant int knotCount = \(bank.knots.count);
        // each filter's taps each way, the border they reach past a pixel,
        // and the texels of four taps a filter takes
        constant int taps = \(bank.taps);
        constant int reach = \(bank.taps / 2);
        constant int texels = \(bank.taps * bank.taps / 4);
        constant int tile = 16 + 2 * reach;
        constant float bandEdges[\(max(bank.strengths.count - 1, 1))] = { \(list(bandEdges)) };
        constant float coherences[coherenceCount] = { \(list(bank.coherences)) };
        constant float knots[knotCount] = { \(list(bank.knots)) };
        // the structure tensor's smoothing
        constant int radius = \(radius);
        // the source pixels a class is shared across each way, and what a
        // group of 16x16 classes reads of them
        constant int share = \(Upscaler.classShare);
        constant int spread = 16 * share + 2 * radius;
        constant float gauss[\(gauss.count)] = { \(list(gauss.map { $0 / total })) };

        // The class of every other source pixel each way, which its three
        // neighbours share: the tensor is smoothed over more than that, and
        // a class of its own for each changes nothing measured. From its
        // structure tensor: the products of the gradients, smoothed across
        // then down within the group's tile, across at the columns that are
        // classed and down at the rows that are.
        kernel void lexis_classify(texture2d<float, access::read> source [[texture(0)]],
                                   texture2d<ushort, access::write> kinds [[texture(1)]],
                                   constant Parameters &p [[buffer(0)]],
                                   uint2 gid [[thread_position_in_grid]],
                                   uint2 lid [[thread_position_in_threadgroup]],
                                   uint2 group [[threadgroup_position_in_grid]]) {
            // the smoothing's reach, the gradients' one more; once the
            // gradients are taken, the same memory holds the products
            // smoothed across, which take less of it
            threadgroup half4 shared[((spread + 2) * (spread + 2) + 1) / 2];
            threadgroup float (*luma)[spread + 2] = reinterpret_cast<threadgroup float (*)[spread + 2]>(shared);
            threadgroup half4 (*across)[16] = reinterpret_cast<threadgroup half4 (*)[16]>(shared);
            // squares of gradients over 256: in range for half precision,
            // and precise enough to pick a class
            threadgroup half4 products[spread][spread];
            int2 size = int2(source.get_width(), source.get_height());
            int2 origin = int2(group) * 16 * share - radius - 1;
            uint slot = lid.y * 16 + lid.x;
            for (uint i = slot; i < uint((spread + 2) * (spread + 2)); i += 256) {
                int2 at = clamp(origin + int2(i % (spread + 2), i / (spread + 2)), int2(0), size - 1);
                luma[i / (spread + 2)][i % (spread + 2)] = source.read(uint2(at)).r * p.codes;
            }
            threadgroup_barrier(mem_flags::mem_threadgroup);
            // past the picture's edge, the products of its edge pixels
            for (uint i = slot; i < uint(spread * spread); i += 256) {
                int2 at = clamp(origin + 1 + int2(i % spread, i / spread), int2(0), size - 1) - origin;
                float gx = (luma[at.y][at.x + 1] - luma[at.y][at.x - 1]) * 0.5f;
                float gy = (luma[at.y + 1][at.x] - luma[at.y - 1][at.x]) * 0.5f;
                products[i / spread][i % spread] = half4(half(gx * gx / 256.0f), half(gx * gy / 256.0f), half(gy * gy / 256.0f), 0.0h);
            }
            threadgroup_barrier(mem_flags::mem_threadgroup);
            for (uint i = slot; i < uint(spread * 16); i += 256) {
                float4 sum = 0.0f;
                for (int j = 0; j <= 2 * radius; j++) sum += gauss[j] * float4(products[i / 16][(i % 16) * share + j]);
                across[i / 16][i % 16] = half4(sum);
            }
            threadgroup_barrier(mem_flags::mem_threadgroup);
            if (gid.x >= kinds.get_width() || gid.y >= kinds.get_height()) return;
            float4 t = 0.0f;
            for (int j = 0; j <= 2 * radius; j++) t += gauss[j] * float4(across[lid.y * share + j][lid.x]);
            float a = t.x * 256.0f, b = t.y * 256.0f, c = t.z * 256.0f;
            float d = sqrt((a - c) * (a - c) + 4.0f * b * b);
            float l1 = (a + c + d) * 0.5f, l2 = max((a + c - d) * 0.5f, 0.0f);
            float orientation = fract(0.5f * atan2(2.0f * b, a - c) / M_PI_F + 1.0f) * float(angles);
            int angle = int(floor(orientation + 0.5f)) % angles;
            // the nearest strength centre, on a log scale: past each midpoint,
            // compared on the squared eigenvalue
            int band = 0;
            for (int i = 0; i < strengthCount - 1; i++) band += l1 >= bandEdges[i] ? 1 : 0;
            // coherence (sqrt(l1) - sqrt(l2)) / (sqrt(l1) + sqrt(l2)) past an
            // edge e, squared: (1 - e)^2 l1 > (1 + e)^2 l2
            int shape = 0;
            for (int i = 0; i < coherenceCount; i++) {
                float e = coherences[i];
                shape += (1.0f - e) * (1.0f - e) * l1 > (1.0f + e) * (1.0f + e) * l2 ? 1 : 0;
            }
            kinds.write(ushort((angle * strengthCount + band) * (coherenceCount + 1) + shape), gid);
        }

        // One thread per source pixel, writing the four it becomes: each of
        // the pair of its class's filters over the square around each, taken on
        // the pixels' departures from the centre so half precision taps
        // carry no error worth a code.
        kernel void lexis_learned(texture2d<float, access::read> source [[texture(0)]],
                                  texture2d<float, access::write> output [[texture(1)]],
                                  texture2d<ushort, access::read> kinds [[texture(2)]],
                                  texture2d<half, access::read> filters [[texture(3)]],
                                  constant Parameters &p [[buffer(0)]],
                                  device const float *curves [[buffer(2)]],
                                  device const float2 *sums [[buffer(3)]],
                                  uint2 gid [[thread_position_in_grid]],
                                  uint2 lid [[thread_position_in_threadgroup]],
                                  uint2 group [[threadgroup_position_in_grid]]) {
            threadgroup float luma[tile][tile];
            // every pair's taps, staged once a group: each source pixel
            // reads 32 texels of them
            threadgroup half4 table[4 * classes][2 * texels];
            int2 size = int2(source.get_width(), source.get_height());
            int2 origin = int2(group) * 16 - reach;
            uint slot = lid.y * 16 + lid.x;
            for (uint i = slot; i < uint(tile * tile); i += 256) {
                int2 at = clamp(origin + int2(i % tile, i / tile), int2(0), size - 1);
                luma[i / tile][i % tile] = source.read(uint2(at)).r * p.codes;
            }
            for (uint i = slot; i < uint(4 * classes * 2 * texels); i += 256) {
                table[i / (2 * texels)][i % (2 * texels)] = filters.read(uint2(i % (2 * texels), i / (2 * texels)));
            }
            threadgroup_barrier(mem_flags::mem_threadgroup);
            if (int(gid.x) >= size.x || int(gid.y) >= size.y) return;
            int kind = kinds.read(gid / share).r;
            int2 centre = int2(lid) + reach;
            float middle = luma[centre.y][centre.x];
            device const float *curve = curves + kind * knotCount;
            #pragma unroll
            for (int py = 0; py < 2; py++) {
                #pragma unroll
                for (int px = 0; px < 2; px++) {
                    int pair = (py * 2 + px) * classes + kind;
                    // even phase: the taps from reach before to one short of reach after
                    int top = centre.y - reach + py, left = centre.x - reach + px;
                    half4 around[texels];
                    #pragma unroll
                    for (int q = 0; q < texels; q++) {
                        #pragma unroll
                        for (int r = 0; r < 4; r++) {
                            around[q][r] = half(luma[top + (q * 4 + r) / taps][left + (q * 4 + r) % taps] - middle);
                        }
                    }
                    half4 e4 = 0.0h, b4 = 0.0h;
                    #pragma unroll
                    for (int q = 0; q < texels; q++) {
                        e4 = fma(table[pair][q], around[q], e4);
                        b4 = fma(table[pair][texels + q], around[q], b4);
                    }
                    float estimate = float(e4.x) + float(e4.y) + float(e4.z) + float(e4.w);
                    float blurred = float(b4.x) + float(b4.y) + float(b4.z) + float(b4.w);
                    float2 total = sums[pair];
                    estimate += middle * total.x;
                    blurred += middle * total.y;
                    float detail = estimate - blurred;
                    float x = min(abs(detail), knots[knotCount - 1]);
                    float kept = curve[knotCount - 1];
                    #pragma unroll
                    for (int k = 0; k < knotCount - 1; k++) {
                        if (x >= knots[k] && x < knots[k + 1]) {
                            kept = mix(curve[k], curve[k + 1], (x - knots[k]) / (knots[k + 1] - knots[k]));
                        }
                    }
                    float value = blurred + sign(detail) * kept;
                    // held within the four source pixels around it
                    int2 a0 = centre + int2(px - 1, py - 1);
                    float low = min(min(luma[a0.y][a0.x], luma[a0.y][a0.x + 1]),
                                    min(luma[a0.y + 1][a0.x], luma[a0.y + 1][a0.x + 1]));
                    float high = max(max(luma[a0.y][a0.x], luma[a0.y][a0.x + 1]),
                                     max(luma[a0.y + 1][a0.x], luma[a0.y + 1][a0.x + 1]));
                    value = clamp(value, low, high);
                    output.write(float4(clamp(round(value), 4.0f, 1019.0f) * tenBitUnit), gid * 2 + uint2(px, py));
                }
            }
        }

        // How the chroma moves with the luma around each of the source's
        // chroma samples. The luma is first brought to the chroma's sites,
        // left: on each block's first column, its neighbours at half weight,
        // between its two rows. The slope of the chroma on it over the 3x3,
        // held down where the luma barely moves, then goes out beside that
        // luma, which is what a pixel's own is later read against.
        kernel void lexis_chroma_slope(texture2d<float, access::sample> luma [[texture(0)]],
                                       texture2d<float, access::read> chroma [[texture(1)]],
                                       texture2d<float, access::write> guide [[texture(2)]],
                                       constant Parameters &p [[buffer(0)]],
                                       uint2 gid [[thread_position_in_grid]],
                                       uint2 lid [[thread_position_in_threadgroup]],
                                       uint2 group [[threadgroup_position_in_grid]]) {
            threadgroup float sites[18][18];
            threadgroup float2 colours[18][18];
            int2 size = int2(chroma.get_width(), chroma.get_height());
            float2 lumaSize = float2(luma.get_width(), luma.get_height());
            int2 origin = int2(group) * 16 - 1;
            for (uint i = lid.y * 16 + lid.x; i < 324; i += 256) {
                int2 at = clamp(origin + int2(i % 18, i / 18), int2(0), size - 1);
                // two bilinear taps, each between two columns and the two rows:
                // the six pixels at 1 2 1 over both rows
                float2 between = float2(at) * 2.0f + float2(0.0f, 1.0f);
                float sum = luma.sample(bilinear, between / lumaSize).r
                    + luma.sample(bilinear, (between + float2(1.0f, 0.0f)) / lumaSize).r;
                sites[i / 18][i % 18] = sum * p.codes / 2.0f;
                colours[i / 18][i % 18] = chroma.read(uint2(at)).rg * p.codes;
            }
            threadgroup_barrier(mem_flags::mem_threadgroup);
            if (int(gid.x) >= size.x || int(gid.y) >= size.y) return;
            float sy = 0.0f, syy = 0.0f;
            float2 sc = 0.0f, syc = 0.0f;
            for (uint dy = 0; dy < 3; dy++) {
                for (uint dx = 0; dx < 3; dx++) {
                    float y = sites[lid.y + dy][lid.x + dx];
                    float2 c = colours[lid.y + dy][lid.x + dx];
                    sy += y; syy += y * y; sc += c; syc += y * c;
                }
            }
            float my = sy / 9.0f;
            float variance = syy / 9.0f - my * my;
            float2 covariance = syc / 9.0f - my * sc / 9.0f;
            // the luma over its range, for a half float to hold it to a quarter code
            guide.write(float4(covariance / (variance + 256.0f), sites[lid.y + 1][lid.x + 1] / 1023.0f, 0.0f), gid);
        }

        // One thread per chroma sample of the output, sited left as 4:2:0 is:
        // on its block's first column, between its two rows: the chroma
        // between its samples plus the luma's own detail there by the local
        // slope, so a colour's edge follows the luma's.
        kernel void lexis_upscale_chroma(texture2d<float, access::sample> source [[texture(0)]],
                                         texture2d<float, access::write> output [[texture(1)]],
                                         texture2d<float, access::sample> luma [[texture(2)]],
                                         texture2d<float, access::sample> guide [[texture(3)]],
                                         constant Parameters &p [[buffer(0)]],
                                         uint2 gid [[thread_position_in_grid]]) {
            if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
            float2 at = float2(gid) * 2.0f + float2(0.0f, 0.5f);
            float2 inLuma = (at + 0.5f) * p.step - 0.5f;
            float2 site = (inLuma - p.siting) * 0.5f;
            float2 size = float2(source.get_width(), source.get_height());
            float2 there = (site + 0.5f) / size;
            float y = luma.sample(bilinear, (inLuma + 0.5f) / float2(luma.get_width(), luma.get_height())).r * p.codes;
            float3 guided = guide.sample(bilinear, there).rgb;
            float2 cbcr = source.sample(bilinear, there).rg * p.codes + guided.rg * (y - guided.b * 1023.0f);
            output.write(float4(clamp(round(cbcr), 4.0f, 1019.0f) * tenBitUnit, 0.0f, 1.0f), gid);
        }

        // What the finish takes for a plane: source pixels per output pixel,
        // and where the first output pixel's centre falls in the source.
        struct Finish {
            float2 scale;
            float2 start;
        };

        // Lanczos 3 over the six source pixels around each output pixel.
        static inline void lanczos_taps(float at, thread int &first, thread float weights[6]) {
            first = int(floor(at)) - 2;
            float sum = 0.0f;
            for (int k = 0; k < 6; k++) {
                float x = (at - float(first + k)) * M_PI_F;
                float w = abs(x) < 1e-4f ? 1.0f : 3.0f * sin(x) * sin(x / 3.0f) / (x * x);
                weights[k] = w;
                sum += w;
            }
            for (int k = 0; k < 6; k++) weights[k] /= sum;
        }

        // The doubled plane, luma or chroma, resampled to the output's size
        // by Lanczos 3, across then down within the group's tile, each pixel
        // held within the 2x2 source pixels around it so an edge does not
        // ring. For a factor of one or more: a group's 16 pixels each way read at most 22 source ones.
        kernel void lexis_finish(texture2d<float, access::read> source [[texture(0)]],
                                 texture2d<float, access::write> output [[texture(1)]],
                                 constant Finish &f [[buffer(0)]],
                                 uint2 gid [[thread_position_in_grid]],
                                 uint2 lid [[thread_position_in_threadgroup]],
                                 uint2 group [[threadgroup_position_in_grid]]) {
            threadgroup float2 tile[22][22];
            threadgroup float2 across[22][16];
            threadgroup float columnWeights[16][6];
            threadgroup float rowWeights[16][6];
            threadgroup int columnFirst[16];
            threadgroup int rowFirst[16];
            int2 size = int2(source.get_width(), source.get_height());
            float2 at0 = float2(group * 16) * f.scale + f.start;
            int2 origin = int2(floor(at0)) - 2;
            uint slot = lid.y * 16 + lid.x;
            for (uint i = slot; i < 22 * 22; i += 256) {
                int2 at = clamp(origin + int2(i % 22, i / 22), int2(0), size - 1);
                tile[i / 22][i % 22] = source.read(uint2(at)).rg * (65535.0f / 64.0f);
            }
            if (lid.y < 2) {
                float at = float(group[lid.y] * 16 + lid.x) * f.scale[lid.y] + f.start[lid.y];
                int first;
                float weights[6];
                lanczos_taps(at, first, weights);
                for (int k = 0; k < 6; k++) {
                    if (lid.y == 0) columnWeights[lid.x][k] = weights[k];
                    else rowWeights[lid.x][k] = weights[k];
                }
                if (lid.y == 0) columnFirst[lid.x] = first - origin.x;
                else rowFirst[lid.x] = first - origin.y;
            }
            threadgroup_barrier(mem_flags::mem_threadgroup);
            for (uint i = slot; i < 22 * 16; i += 256) {
                uint row = i / 16, column = i % 16;
                float2 sum = 0.0f;
                for (int k = 0; k < 6; k++) sum += columnWeights[column][k] * tile[row][columnFirst[column] + k];
                across[row][column] = sum;
            }
            threadgroup_barrier(mem_flags::mem_threadgroup);
            if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
            float2 value = 0.0f;
            for (int k = 0; k < 6; k++) value += rowWeights[lid.y][k] * across[rowFirst[lid.y] + k][lid.x];
            int2 near = int2(columnFirst[lid.x], rowFirst[lid.y]) + 2;
            float2 low = min(min(tile[near.y][near.x], tile[near.y][near.x + 1]),
                             min(tile[near.y + 1][near.x], tile[near.y + 1][near.x + 1]));
            float2 high = max(max(tile[near.y][near.x], tile[near.y][near.x + 1]),
                              max(tile[near.y + 1][near.x], tile[near.y + 1][near.x + 1]));
            value = clamp(value, low, high);
            output.write(float4(clamp(round(value), 4.0f, 1019.0f) * tenBitUnit, 0.0f, 1.0f), gid);
        }

        // The luma as the network takes it, ten bit codes over 1023 in half
        // precision, on its canvas: past the picture, its last row and column.
        kernel void lexis_to_network(texture2d<float, access::read> luma [[texture(0)]],
                                     texture2d<half, access::write> canvas [[texture(1)]],
                                     constant Parameters &p [[buffer(0)]],
                                     uint2 gid [[thread_position_in_grid]]) {
            if (gid.x >= canvas.get_width() || gid.y >= canvas.get_height()) return;
            uint2 at = min(gid, uint2(luma.get_width(), luma.get_height()) - 1);
            canvas.write(half4(luma.read(at).r * p.codes / 1023.0f), gid);
        }

        // The network's doubled luma, from the top left of its canvas, into the
        // picture's plane, its finest detail, over its 3x3, raised by `gain`.
        kernel void lexis_from_network(texture2d<half, access::read> canvas [[texture(0)]],
                                       texture2d<float, access::write> output [[texture(1)]],
                                       constant float &gain [[buffer(0)]],
                                       uint2 gid [[thread_position_in_grid]]) {
            if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
            float code = float(canvas.read(gid).r) * 1023.0f;
            if (gain > 0.0f) {
                int2 limit = int2(output.get_width(), output.get_height()) - 1;
                float sum = 0.0f;
                for (int dy = -1; dy <= 1; dy++) {
                    for (int dx = -1; dx <= 1; dx++) {
                        sum += float(canvas.read(uint2(clamp(int2(gid) + int2(dx, dy), int2(0), limit))).r);
                    }
                }
                code += gain * (code - sum * (1023.0f / 9.0f));
            }
            output.write(float4(clamp(round(code), 4.0f, 1019.0f) * tenBitUnit), gid);
        }
        """
    }

    /// `starvation` is `Deband.strength` for the stream, 1 for a clean
    /// master to 2 for a starved encode: how the two banks are mixed.
    /// `sourceFormat` names the picture's colour. `neural`
    /// asks for the network over the filters, which `isNeural` says was had;
    /// `picturesPerSecond`, the film's, nil read as 24, is what it has to keep up with.
    /// `outputSize`, twice the source where nil, may be larger, never
    /// smaller: the doubled picture is then finished to it here, by a sharper
    /// filter than a compositor's bilinear (QualityBench).
    public init(
        inputWidth: Int, inputHeight: Int, ceilingBytes: Int, sourceFormat: CMVideoFormatDescription? = nil,
        rendererAttributes: [String: Any] = [:], starvation: Float = 1, neural: Bool = false,
        picturesPerSecond: Double? = nil, outputSize: (width: Int, height: Int)? = nil
    ) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw UpscaleError.noDevice }
        #if canImport(MetalFX)
        // the GPUs MetalFX's own scaler takes, a 4K pass within a frame
        guard MTLFXSpatialScalerDescriptor.supportsDevice(device) else { throw UpscaleError.unsupportedDevice }
        #endif
        guard let queue = device.makeCommandQueue() else { throw UpscaleError.noDevice }
        let (bank, library) = try Upscaler.compiled(on: device)
        self.inputWidth = inputWidth
        self.inputHeight = inputHeight
        outputWidth = outputSize?.width ?? inputWidth * 2
        outputHeight = outputSize?.height ?? inputHeight * 2
        // the finish's tile holds a factor of one or more
        precondition(outputWidth >= inputWidth * 2 && outputHeight >= inputHeight * 2, "an output under twice the source")
        self.queue = queue
        parameters = Parameters(step: SIMD2(0.5, 0.5), codes: 0, siting: .zero)
        colourTags = sourceFormat.map { Upscaler.colourTags(of: $0, height: inputHeight) } ?? []
        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else { throw UpscaleError.noDevice }
            return try device.makeComputePipelineState(function: function)
        }
        classify = try pipeline("lexis_classify")
        learned = try pipeline("lexis_learned")
        chroma = try pipeline("lexis_upscale_chroma")
        chromaSlope = try pipeline("lexis_chroma_slope")
        finish = try pipeline("lexis_finish")
        func buffer<T>(_ values: [T]) throws -> MTLBuffer {
            guard let made = device.makeBuffer(
                bytes: values, length: values.count * MemoryLayout<T>.stride, options: .storageModeShared)
            else { throw UpscaleError.noDevice }
            return made
        }
        let mixed = bank.mixed(bank.filters, starvation)
        let texels = bank.taps * bank.taps / 2
        let pairs = mixed.count / (4 * texels)
        let texture = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: texels, height: pairs, mipmapped: false)
        texture.usage = .shaderRead
        guard let filters = device.makeTexture(descriptor: texture) else { throw UpscaleError.noDevice }
        let halves = mixed.map { Float16($0) }
        halves.withUnsafeBytes {
            filters.replace(
                region: MTLRegionMake2D(0, 0, texels, pairs), mipmapLevel: 0, withBytes: $0.baseAddress!,
                bytesPerRow: texels * 8)
        }
        self.filters = filters
        let taps = bank.taps * bank.taps
        sums = try buffer((0..<mixed.count / (2 * taps)).map { pair in
            SIMD2((0..<taps).reduce(Float(0)) { $0 + Float(Float16(mixed[pair * 2 * taps + $1])) },
                  (0..<taps).reduce(Float(0)) { $0 + Float(Float16(mixed[pair * 2 * taps + taps + $1])) })
        })
        curves = try buffer(bank.mixed(bank.curves, starvation))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r16Uint, width: (inputWidth + Upscaler.classShare - 1) / Upscaler.classShare,
            height: (inputHeight + Upscaler.classShare - 1) / Upscaler.classShare, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        guard let kinds = device.makeTexture(descriptor: descriptor) else { throw UpscaleError.noDevice }
        self.kinds = kinds
        descriptor.width = (inputWidth + 1) / 2
        descriptor.height = (inputHeight + 1) / 2
        descriptor.pixelFormat = .rgba16Float
        guard let chromaGuide = device.makeTexture(descriptor: descriptor) else { throw UpscaleError.noDevice }
        self.chromaGuide = chromaGuide
        if outputWidth != inputWidth * 2 || outputHeight != inputHeight * 2 {
            descriptor.width = inputWidth * 2
            descriptor.height = inputHeight * 2
            descriptor.pixelFormat = .r16Unorm
            let luma = device.makeTexture(descriptor: descriptor)
            descriptor.width = inputWidth
            descriptor.height = inputHeight
            descriptor.pixelFormat = .rg16Unorm
            guard let luma, let chroma = device.makeTexture(descriptor: descriptor) else { throw UpscaleError.noDevice }
            doubled = (luma, chroma)
        } else {
            doubled = nil
        }
        let usage: MTLTextureUsage = [.shaderRead, .shaderWrite]
        textureAttributes = [kCVMetalTextureUsage: NSNumber(value: usage.rawValue)] as CFDictionary
        passTimer = PassTimer(device: device, label: "prisme", passes: ["classify", "learned", "slope", "chroma", "to network", "finish"])
        // the filters stay where the network is missing or refused
        network = neural && inputWidth <= Network.width && inputHeight <= Network.height
            ? try? Network(
                device: device, library: library, starvation: starvation,
                picturesPerSecond: picturesPerSecond ?? 24)
            : nil

        var cache: CVMetalTextureCache?
        let cacheStatus = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard cacheStatus == kCVReturnSuccess, let cache else {
            throw UpscaleError.textureFailed(cacheStatus)
        }
        textureCache = cache
        pool = try PixelBufferPool(
            width: Int32(outputWidth), height: Int32(outputHeight),
            pixelFormat: Upscaler.pixelFormat, warmCount: 2, ceilingBytes: ceilingBytes,
            rendererAttributes: rendererAttributes.merging(inputAttributes) { own, _ in own }
        )
    }

    /// The source's primaries, transfer and matrix, each BT.709 where the
    /// file names none, but for the matrix of a picture under 720 lines,
    /// which every SD format was made with 601. Left to guess, VideoToolbox
    /// guesses SDR 601 whatever the size.
    private static func colourTags(of format: CMVideoFormatDescription, height: Int) -> [(CFString, CFTypeRef)] {
        let extensions = CMFormatDescriptionGetExtensions(format) as? [CFString: Any]
        return [
            (kCVImageBufferColorPrimariesKey,
             (extensions?[kCMFormatDescriptionExtension_ColorPrimaries] as CFTypeRef?)
                ?? kCVImageBufferColorPrimaries_ITU_R_709_2),
            (kCVImageBufferTransferFunctionKey,
             (extensions?[kCMFormatDescriptionExtension_TransferFunction] as CFTypeRef?)
                ?? kCVImageBufferTransferFunction_ITU_R_709_2),
            (kCVImageBufferYCbCrMatrixKey,
             (extensions?[kCMFormatDescriptionExtension_YCbCrMatrix] as CFTypeRef?)
                ?? (height < 720 ? kCVImageBufferYCbCrMatrix_ITU_R_601_4 : kCVImageBufferYCbCrMatrix_ITU_R_709_2)),
            (kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_Left),
            (kCVImageBufferChromaLocationBottomFieldKey, kCVImageBufferChromaLocation_Left),
        ]
    }

    deinit {
        // what the cache still holds goes back to the pool while it is there
        cacheQueue.sync { CVMetalTextureCacheFlush(textureCache, 0) }
    }

    /// Frees the pictures the pool is holding for reuse and nobody is using.
    func releaseSpareBuffers() {
        pool.releaseSpareBuffers()
    }

    /// Scales `frame` in a command buffer of its own, and hands the picture
    /// to `completion` once it has landed.
    func scale(_ frame: CVPixelBuffer, completion: @escaping (CVPixelBuffer) -> Void) throws {
        guard let command = queue.makeCommandBuffer() else { throw UpscaleError.noDevice }
        guard let network = activeNetwork else {
            let output = try encode(frame, into: command)
            command.addCompletedHandler { [gpuTiming, pool] buffer in
                gpuTiming.record((buffer.gpuEndTime - buffer.gpuStartTime) * 1000, beyondPool: pool.allocatedBeyond)
                completion(output)
            }
            command.commit()
            return
        }
        let staged = try stage(frame, into: command, network: network)
        let parameters = parameters
        // One picture at a time through the canvases, in order, without
        // holding up the caller: the pass that fills the input canvas is only
        // committed once the prediction before has read it, and a prediction
        // only runs once the picture before has been read off the output.
        network.queue.async { [self] in
            command.commit()
            command.waitUntilCompleted()
            var second = queue.makeCommandBuffer()
            do {
                network.reading?.waitUntilCompleted()
                try network.predict()
                let encoder = second?.makeComputeCommandEncoder()
                encoder?.setComputePipelineState(network.fromNetwork)
                encoder?.setTexture(network.output, index: 0)
                encoder?.setTexture(staged.outLuma, index: 1)
                var gain = network.gain
                encoder?.setBytes(&gain, length: MemoryLayout<Float>.size, index: 0)
                encoder?.dispatchThreadgroups(
                    MTLSize(width: (staged.outLuma.width + 15) / 16, height: (staged.outLuma.height + 15) / 16, depth: 1),
                    threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
                encoder?.endEncoding()
            } catch {
                // a prediction refused leaves the luma to the filters
                traceLine("[lexis.pass] network refused a picture: \(error)")
                if let second { doubleByFilters(staged.luma, into: staged.outLuma, on: second, parameters) }
            }
            if second == nil { second = queue.makeCommandBuffer() }
            if let doubled, let encoder = second?.makeComputeCommandEncoder() {
                encodeFinish(doubled, into: staged.planes, on: encoder)
            }
            second?.addCompletedHandler { [gpuTiming, pool, cacheQueue] buffer in
                gpuTiming.record(
                    (command.gpuEndTime - command.gpuStartTime + buffer.gpuEndTime - buffer.gpuStartTime) * 1000,
                    beyondPool: pool.allocatedBeyond)
                cacheQueue.async { staged.wrapped.release() }
                completion(staged.output)
            }
            second?.commit()
            network.reading = second
        }
    }

    /// The filters' two passes on the luma, untimed, for a picture the
    /// network refused.
    private func doubleByFilters(_ luma: MTLTexture, into outLuma: MTLTexture, on command: MTLCommandBuffer,
                                 _ parameters: Parameters) {
        var parameters = parameters
        for (pipeline, target, grid) in [(classify, kinds, kinds), (learned, outLuma, luma)] {
            guard let encoder = command.makeComputeCommandEncoder() else { return }
            encoder.setComputePipelineState(pipeline)
            encoder.setBytes(&parameters, length: MemoryLayout<Parameters>.size, index: 0)
            encoder.setBuffer(curves, offset: 0, index: 2)
            encoder.setBuffer(sums, offset: 0, index: 3)
            encoder.setTexture(luma, index: 0)
            encoder.setTexture(target, index: 1)
            encoder.setTexture(kinds, index: 2)
            encoder.setTexture(filters, index: 3)
            encoder.dispatchThreadgroups(
                MTLSize(width: (grid.width + 15) / 16, height: (grid.height + 15) / 16, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            encoder.endEncoding()
        }
    }

    /// Encodes the scale of `frame` into `command`, behind whatever the
    /// caller encoded there first and committed by the caller, and hands back
    /// the picture it lands in, whole once `command` has completed: a built
    /// field is scaled with no trip back to the CPU between the two.
    ///
    /// `frame` is eight or ten bit 4:2:0 YCbCr, video range. Not for a scaler
    /// with a network, whose luma is doubled off the GPU: `scale` hands its
    /// picture over.
    func encode(_ frame: CVPixelBuffer, into command: MTLCommandBuffer) throws -> CVPixelBuffer {
        precondition(activeNetwork == nil, "a scaler with a network scales through scale(_:completion:)")
        let staged = try stage(frame, into: command)
        command.addCompletedHandler { [cacheQueue] _ in
            cacheQueue.async { staged.wrapped.release() }
        }
        return staged.output
    }

    /// What `stage` encoded for a picture: the picture it lands in, the
    /// textures over the planes, let go once it has, the luma read and the
    /// doubled one written, for the network's pass after, and the picture's
    /// planes, for the finish after that.
    private struct Staged {
        let output: CVPixelBuffer
        let wrapped: PassTextures
        let luma: MTLTexture
        let outLuma: MTLTexture
        let planes: (luma: MTLTexture, chroma: MTLTexture)
    }

    /// The doubled planes resampled into the picture's own.
    private func encodeFinish(
        _ doubled: (luma: MTLTexture, chroma: MTLTexture), into planes: (luma: MTLTexture, chroma: MTLTexture),
        on encoder: MTLComputeCommandEncoder
    ) {
        struct Finish {
            var scale: SIMD2<Float>
            var start: SIMD2<Float>
        }
        encoder.setComputePipelineState(finish)
        let scale = SIMD2(Float(doubled.luma.width) / Float(outputWidth), Float(doubled.luma.height) / Float(outputHeight))
        // a chroma sample sits on its block's first column, between its two
        // rows: in luma pixels, (0, 0.5) past the block's first
        let siting = SIMD2<Float>(0, 0.5)
        for (from, to, start) in [
            (doubled.luma, planes.luma, 0.5 * scale - 0.5),
            (doubled.chroma, planes.chroma, ((siting + 0.5) * scale - 0.5 - siting) / 2),
        ] {
            var parameters = Finish(scale: scale, start: start)
            encoder.setBytes(&parameters, length: MemoryLayout<Finish>.stride, index: 0)
            encoder.setTexture(from, index: 0)
            encoder.setTexture(to, index: 1)
            encoder.dispatchThreadgroups(
                MTLSize(width: (to.width + 15) / 16, height: (to.height + 15) / 16, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        }
        encoder.endEncoding()
    }

    /// Every pass of the scale into `command`, but that with `network` the
    /// luma is only set on its canvas.
    private func stage(_ frame: CVPixelBuffer, into command: MTLCommandBuffer, network: Network? = nil) throws -> Staged {
        let format = CVPixelBufferGetPixelFormatType(frame)
        let planes: [MTLPixelFormat]
        switch format {
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
            planes = [.r16Unorm, .rg16Unorm]
            parameters.codes = 65535.0 / 64
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            planes = [.r8Unorm, .rg8Unorm]
            parameters.codes = 255 * 4
        default:
            throw UpscaleError.unsupportedFormat(format)
        }
        guard CVPixelBufferGetWidth(frame) == inputWidth, CVPixelBufferGetHeight(frame) == inputHeight else {
            throw UpscaleError.unsupportedFormat(format)
        }
        parameters.siting = chromaSiting(of: frame)
        var taken = pool.take()
        if taken == nil {
            cacheQueue.sync { CVMetalTextureCacheFlush(textureCache, 0) }
            taken = pool.take()
        }
        guard let output = taken ?? pool.takeBeyondCapacity() else {
            throw UpscaleError.bufferFailed(kCVReturnAllocationFailed)
        }
        for (key, value) in colourTags {
            CVBufferSetAttachment(output, key, value, .shouldPropagate)
        }
        let wrapped = try cacheQueue.sync {
            PassTextures(
                try planes.enumerated().map { try plane(frame, $0.offset, $0.element) }
                    + [try plane(output, 0, .r16Unorm), try plane(output, 1, .rg16Unorm)],
                cache: textureCache, pool: pool)
        }
        let textures = wrapped.wrappers.compactMap(CVMetalTextureGetTexture)
        guard textures.count == wrapped.wrappers.count else { throw UpscaleError.noDevice }
        let own = (luma: textures[textures.count - 2], chroma: textures[textures.count - 1])
        let (outLuma, outChroma) = doubled ?? own
        let slot = passTimer?.slot() ?? 0
        var timed: [Int] = []
        let group = MTLSize(width: 16, height: 16, depth: 1)
        // each pass its own encoder, timed under a trace
        func run(_ pass: Int, _ pipeline: MTLComputePipelineState, _ from: MTLTexture, _ to: MTLTexture,
                 over grid: MTLTexture) throws {
            timed.append(pass)
            guard let encoder = passTimer?.encoder(pass, slot: slot, on: command) ?? command.makeComputeCommandEncoder()
            else { throw UpscaleError.noDevice }
            encoder.setComputePipelineState(pipeline)
            encoder.setBytes(&parameters, length: MemoryLayout<Parameters>.size, index: 0)
            encoder.setBuffer(curves, offset: 0, index: 2)
            encoder.setBuffer(sums, offset: 0, index: 3)
            encoder.setTexture(from, index: 0)
            encoder.setTexture(to, index: 1)
            encoder.setTexture(kinds, index: 2)
            encoder.setTexture(filters, index: 3)
            encoder.dispatchThreadgroups(
                MTLSize(width: (grid.width + 15) / 16, height: (grid.height + 15) / 16, depth: 1),
                threadsPerThreadgroup: group)
            encoder.endEncoding()
        }
        func pass(_ index: Int, _ pipeline: MTLComputePipelineState, _ bound: [MTLTexture], over grid: MTLTexture) throws {
            timed.append(index)
            guard let encoder = passTimer?.encoder(index, slot: slot, on: command) ?? command.makeComputeCommandEncoder()
            else { throw UpscaleError.noDevice }
            encoder.setComputePipelineState(pipeline)
            encoder.setBytes(&parameters, length: MemoryLayout<Parameters>.size, index: 0)
            for (index, texture) in bound.enumerated() { encoder.setTexture(texture, index: index) }
            encoder.dispatchThreadgroups(
                MTLSize(width: (grid.width + 15) / 16, height: (grid.height + 15) / 16, depth: 1),
                threadsPerThreadgroup: group)
            encoder.endEncoding()
        }
        let luma = textures[0]
        if let network {
            try pass(4, network.toNetwork, [luma, network.input], over: network.input)
        } else {
            try run(0, classify, luma, kinds, over: kinds)
            try run(1, learned, luma, outLuma, over: luma)
        }
        let chromaIn = textures[1]
        try pass(2, chromaSlope, [luma, chromaIn, chromaGuide], over: chromaGuide)
        try pass(3, chroma, [chromaIn, outChroma, luma, chromaGuide], over: outChroma)
        if network == nil, let doubled {
            timed.append(5)
            guard let encoder = passTimer?.encoder(5, slot: slot, on: command) ?? command.makeComputeCommandEncoder()
            else { throw UpscaleError.noDevice }
            encodeFinish(doubled, into: own, on: encoder)
        }
        command.addCompletedHandler { [passTimer] buffer in
            passTimer?.record(buffer, slot: slot, encoded: timed)
        }
        return Staged(output: output, wrapped: wrapped, luma: luma, outLuma: outLuma, planes: own)
    }

    private func plane(_ buffer: CVPixelBuffer, _ index: Int, _ format: MTLPixelFormat) throws -> CVMetalTexture {
        var texture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, buffer, textureAttributes, format,
            CVPixelBufferGetWidthOfPlane(buffer, index), CVPixelBufferGetHeightOfPlane(buffer, index), index, &texture)
        guard status == kCVReturnSuccess, let texture else { throw UpscaleError.textureFailed(status) }
        return texture
    }
}

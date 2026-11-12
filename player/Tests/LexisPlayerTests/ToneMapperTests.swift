import AVFoundation
import CoreMedia
import CoreVideo
import simd
import XCTest
@testable import LexisPlayer

extension ToneMapper {
    /// The mapper hands its picture back from the pass's own completion; the
    /// tests read pixels out of it, so they wait where playback does not.
    func mapped(
        _ frame: CVPixelBuffer, parameters: ToneMapParameters,
        adaptation: ToneMapper.Adaptation = .none, dovi: [Float]? = nil
    ) throws -> CVPixelBuffer {
        var mapped: CVPixelBuffer?
        let landed = DispatchSemaphore(value: 0)
        try map(frame, parameters: parameters, adaptation: adaptation, dovi: dovi) { mapped = $0; landed.signal() }
        landed.wait()
        return mapped!
    }
}

/// SMPTE ST 2084 the other way round, on the CPU.
func pqEOTF(_ value: Float) -> Float {
    let m1: Float = 0.1593017578125, m2: Float = 78.84375
    let c1: Float = 0.8359375, c2: Float = 18.8515625, c3: Float = 18.6875
    let p = powf(max(value, 0), 1 / m2)
    return powf(max(p - c1, 0) / (c2 - c3 * p), 1 / m1)
}

/// ITU-R BT.2390 EETF, written from the recommendation.
func referenceEETF(_ pq: Float, _ p: ToneMapParameters) -> Float {
    let span = max(p.sourceMaxPQ - p.sourceMinPQ, 1e-6)
    let e1 = min(max((pq - p.sourceMinPQ) / span, 0), 1)
    let maxLum = min(max((p.targetMaxPQ - p.sourceMinPQ) / span, 0), 1)
    let minLum = min(max((p.targetMinPQ - p.sourceMinPQ) / span, -1), 1)
    let ks = 1.5 * maxLum - 0.5
    var e2 = e1
    if e1 > ks {
        let t = (e1 - ks) / max(1 - ks, 1e-6)
        let t2 = t * t, t3 = t2 * t
        e2 = (2 * t3 - 3 * t2 + 1) * ks
            + (t3 - 2 * t2 + t) * (1 - ks)
            + (-2 * t3 + 3 * t2) * maxLum
    }
    let d = 1 - e2
    return (e2 + minLum * d * d * d * d) * span + p.sourceMinPQ
}

/// Dolby Vision profile 5 decoded on the CPU, from libplacebo's own chain:
/// each component through its reshaping curve, the RPU's matrix, PQ to
/// light, and the RPU's LMS into BT.2020 by lms2rgb times rgb_to_lms.
func referenceProfile5(
    luma: Int, cb: Int, cr: Int, curves: [DolbyVisionReshapingCurve],
    parameters p: ToneMapParameters, rgbToLMS: [Float]
) -> SIMD3<Float> {
    let sig = simd_clamp(SIMD3(Float(luma), Float(cb), Float(cr)) / 1023, SIMD3(repeating: 0), SIMD3(repeating: 1))
    let cross = SIMD4(sig.x * sig.y, sig.x * sig.z, sig.y * sig.z, sig.x * sig.y * sig.z)
    var shaped = sig
    for (c, curve) in curves.enumerated() {
        let pivots = curve.pivots.map { Float($0) / 1023 }
        let s = sig[c]
        let piece = (1..<(pivots.count - 1)).last { s >= pivots[$0] } ?? 0
        var value: Float
        switch curve.pieces[piece] {
        case .polynomial(let k):
            value = k.enumerated().reduce(0) { $0 + Float($1.element) * powf(s, Float($1.offset)) }
        case .mmr(let order, let constant, let m):
            value = Float(constant)
            for o in 0..<order {
                let e = Float(o + 1)
                let terms: [Float] = [
                    powf(sig.x, e), powf(sig.y, e), powf(sig.z, e),
                    powf(cross.x, e), powf(cross.y, e), powf(cross.z, e), powf(cross.w, e),
                ]
                for t in 0..<7 { value += Float(m[o * 7 + t]) * terms[t] }
            }
        }
        shaped[c] = min(max(value, pivots.first!), pivots.last!)
    }
    let signal = simd_clamp(p.yccToRGB * (shaped - p.yccOffset), SIMD3(repeating: 0), SIMD3(repeating: 1))
    let light = SIMD3(pqEOTF(signal.x), pqEOTF(signal.y), pqEOTF(signal.z))
    let lmsToRGB = simd_float3x3(rows: [
        SIMD3(3.06441879, -2.16597676, 0.10155818),
        SIMD3(-0.65612108, 1.78554118, -0.12943749),
        SIMD3(0.01736321, -0.04725154, 1.03004253),
    ])
    let toLMS = simd_float3x3(rows: [
        SIMD3(rgbToLMS[0], rgbToLMS[1], rgbToLMS[2]),
        SIMD3(rgbToLMS[3], rgbToLMS[4], rgbToLMS[5]),
        SIMD3(rgbToLMS[6], rgbToLMS[7], rgbToLMS[8]),
    ])
    return simd_max(lmsToRGB * toLMS * light, SIMD3(repeating: 0))
}

/// What the red channel of a neutral sample must come out as.
func referenceRed(luma: Int, chroma: Int, parameters: ToneMapParameters) -> Float {
    // a 10 bit code sits in the top bits of a 16 bit sample
    let y = Float(luma << 6) / 65535 * (65535.0 / 65472.0)
    let c = Float(chroma << 6) / 65535 * (65535.0 / 65472.0)
    let row = parameters.yccToRGB.transpose.columns.0
    let value = row.x * (y - parameters.yccOffset.x)
        + row.y * (c - parameters.yccOffset.y)
        + row.z * (c - parameters.yccOffset.z)
    return pqEOTF(referenceEETF(min(max(value, 0), 1), parameters)) * 100
}

/// Every row carries the same codes, so any pixel can be checked against
/// the reference by its column alone.
func makeSource(
    codes: [Int], rows: Int = 2,
    chroma: (cb: Int, cr: Int) = (512, 512),
    format: OSType = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
) throws -> CVPixelBuffer {
    var created: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(
        kCFAllocatorDefault, codes.count, rows, format,
        [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ] as CFDictionary, &created
    ), kCVReturnSuccess)
    let buffer = try XCTUnwrap(created)
    CVPixelBufferLockBaseAddress(buffer, [])
    let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!
        .assumingMemoryBound(to: UInt16.self)
    let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) / 2
    for row in 0..<rows {
        for (x, code) in codes.enumerated() { luma[row * lumaStride + x] = UInt16(code << 6) }
    }
    // Cb and Cr interleave, and the plane rounds up on an odd size, so both
    // components of every column are written or the last Cr is zero.
    let chromaPlane = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!
        .assumingMemoryBound(to: UInt16.self)
    let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) / 2
    for row in 0..<CVPixelBufferGetHeightOfPlane(buffer, 1) {
        for x in 0..<(2 * CVPixelBufferGetWidthOfPlane(buffer, 1)) {
            chromaPlane[row * chromaStride + x] =
                UInt16((x % 2 == 0 ? chroma.cb : chroma.cr) << 6)
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    return buffer
}

/// A picture drawn pixel by pixel: the luma code of each pixel and the
/// chroma pair of each chroma sample, both by their own coordinates.
func makePicture(
    width: Int, height: Int, luma: (Int, Int) -> Int, chroma: (Int, Int) -> (cb: Int, cr: Int)
) throws -> CVPixelBuffer {
    var created: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(
        kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
        [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ] as CFDictionary, &created
    ), kCVReturnSuccess)
    let buffer = try XCTUnwrap(created)
    CVPixelBufferLockBaseAddress(buffer, [])
    let lumaPlane = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt16.self)
    let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) / 2
    for y in 0..<height {
        for x in 0..<width { lumaPlane[y * lumaStride + x] = UInt16(luma(x, y) << 6) }
    }
    let chromaPlane = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt16.self)
    let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) / 2
    for y in 0..<CVPixelBufferGetHeightOfPlane(buffer, 1) {
        for x in 0..<CVPixelBufferGetWidthOfPlane(buffer, 1) {
            let pair = chroma(x, y)
            chromaPlane[y * chromaStride + 2 * x] = UInt16(pair.cb << 6)
            chromaPlane[y * chromaStride + 2 * x + 1] = UInt16(pair.cr << 6)
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    return buffer
}

/// The red channel of a half float picture, at a pixel.
func red(_ buffer: CVPixelBuffer, x: Int, y: Int = 0) -> Float {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let pixels = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt16.self)
    let stride = CVPixelBufferGetBytesPerRow(buffer) / 2
    return Float(Float16(bitPattern: pixels[y * stride + x * 4]))
}

/// BT.2100 ICtCp of a linear BT.2020 colour on the axis where 1.0 is
/// 10000 nits: intensity, and the two chroma axes the hue is read from.
func ictcp(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
    let lms = SIMD3(
        (1688 * rgb.x + 2146 * rgb.y + 262 * rgb.z) / 4096,
        (683 * rgb.x + 2951 * rgb.y + 462 * rgb.z) / 4096,
        (99 * rgb.x + 309 * rgb.y + 3688 * rgb.z) / 4096)
    let l = pqInverseEOTF(Double(lms.x)), m = pqInverseEOTF(Double(lms.y)), s = pqInverseEOTF(Double(lms.z))
    return SIMD3(
        0.5 * l + 0.5 * m,
        (6610 * l - 13613 * m + 7003 * s) / 4096,
        (17933 * l - 17390 * m - 543 * s) / 4096)
}

/// The three channels of a half float picture at its first pixel, on the
/// 10000 nit axis the curve works on.
func linearRGB(_ buffer: CVPixelBuffer) -> SIMD3<Float> {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let p = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt16.self)
    return SIMD3(Float(Float16(bitPattern: p[0])), Float(Float16(bitPattern: p[1])), Float(Float16(bitPattern: p[2]))) / 100
}

final class ToneMapperTests: XCTestCase {
    func testGoldenValuesForA1000NitMasterOnA203NitDisplay() throws {
        let mapper = try ToneMapper()
        let codes = [64, 200, 400, 512, 700, 800, 900, 940]
        let source = try makeSource(codes: codes)
        let parameters = ToneMapParameters(
            sourceMinPQ: 0, sourceMaxPQ: pqInverseEOTF(0.1),
            targetMinPQ: 0, targetMaxPQ: pqInverseEOTF(0.0203)
        )
        let output = try mapper.mapped(source, parameters: parameters)
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(output), kCVPixelFormatType_64RGBAHalf)
        CVPixelBufferLockBaseAddress(output, .readOnly)
        let pixels = CVPixelBufferGetBaseAddress(output)!.assumingMemoryBound(to: UInt16.self)
        for (x, code) in codes.enumerated() {
            let gpu = Float(Float16(bitPattern: pixels[x * 4]))
            let cpu = referenceRed(luma: code, chroma: 512, parameters: parameters)
            // half floats: one unit in the last place at 2.0 is about 0.001
            XCTAssertEqual(gpu, cpu, accuracy: 0.002, "code \(code)")
        }
        // and the peak lands on the display's peak, 203 nits over the 100 that
        // are SDR white
        XCTAssertEqual(Float(Float16(bitPattern: pixels[7 * 4])), 2.03, accuracy: 0.01)
        CVPixelBufferUnlockBaseAddress(output, .readOnly)
    }

    /// Every pass reports what it cost the GPU.
    func testEveryPassIsTimedOnTheGPU() throws {
        let mapper = try ToneMapper()
        _ = try mapper.mapped(
            try makeSource(codes: [300, 600]),
            parameters: ToneMapParameters(sourceMinPQ: 0, sourceMaxPQ: 0.75, targetMinPQ: 0, targetMaxPQ: 0.6))
        let reading = mapper.gpuTiming.current
        XCTAssertEqual(reading.passes, 1)
        XCTAssertGreaterThan(reading.meanMilliseconds, 0)
        XCTAssertGreaterThanOrEqual(reading.worstMilliseconds, reading.meanMilliseconds)
    }

    /// The PQ destination: the same light as the half float picture, stored
    /// as the ten bit codes a decoder would have produced for it, tagged as
    /// the BT.2020 PQ picture it is, with the peak's own static metadata.
    func testThePQPictureCarriesTheMappedLightAsCodes() throws {
        let mapper = try ToneMapper(pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        mapper.staticMetadata = hdr10StaticMetadata(peakNits: 300)
        let codes = [64, 300, 512, 700, 940]
        let source = try makeSource(codes: codes)
        let parameters = ToneMapParameters(
            sourceMinPQ: 0, sourceMaxPQ: pqInverseEOTF(0.4),
            targetMinPQ: 0, targetMaxPQ: pqInverseEOTF(0.03)
        )
        let output = try mapper.mapped(source, parameters: parameters)
        XCTAssertEqual(
            CVPixelBufferGetPixelFormatType(output), kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        XCTAssertEqual(
            CVBufferCopyAttachment(output, kCVImageBufferTransferFunctionKey, nil) as? String,
            kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String)
        XCTAssertEqual(
            CVBufferCopyAttachment(output, kCVImageBufferMasteringDisplayColorVolumeKey, nil) as? Data,
            hdr10StaticMetadata(peakNits: 300).masteringDisplay)
        CVPixelBufferLockBaseAddress(output, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(output, .readOnly) }
        let luma = CVPixelBufferGetBaseAddressOfPlane(output, 0)!.assumingMemoryBound(to: UInt16.self)
        for (x, code) in codes.enumerated() {
            // grey in, so the red the reference maps is the luminance, and
            // its PQ code is the luma code of a limited range grey
            let light = referenceRed(luma: code, chroma: 512, parameters: parameters) / 100
            let expected = 64 + 876 * pqInverseEOTF(Double(light))
            XCTAssertEqual(Float(luma[x] >> 6), expected, accuracy: 2, "code \(code)")
        }
        // and the peak lands on the 300 nit target, as a code
        XCTAssertEqual(Float(luma[4] >> 6), 64 + 876 * pqInverseEOTF(0.03), accuracy: 2)
        let chroma = CVPixelBufferGetBaseAddressOfPlane(output, 1)!.assumingMemoryBound(to: UInt16.self)
        XCTAssertEqual(Int(chroma[0] >> 6), 512, "a grey has neutral chroma")
        XCTAssertEqual(Int(chroma[1] >> 6), 512)
    }

    func testAnSDRTargetClampsToWhite() throws {
        let mapper = try ToneMapper()
        let source = try makeSource(codes: [64, 512, 940])
        let parameters = ToneMapParameters(
            sourceMinPQ: 0, sourceMaxPQ: pqInverseEOTF(0.1),
            targetMinPQ: 0, targetMaxPQ: pqInverseEOTF(0.01)
        )
        let output = try mapper.mapped(source, parameters: parameters)
        CVPixelBufferLockBaseAddress(output, .readOnly)
        let pixels = CVPixelBufferGetBaseAddress(output)!.assumingMemoryBound(to: UInt16.self)
        XCTAssertEqual(Float(Float16(bitPattern: pixels[0])), 0, accuracy: 0.001)
        XCTAssertEqual(Float(Float16(bitPattern: pixels[2 * 4])), 1.0, accuracy: 0.01)
        CVPixelBufferUnlockBaseAddress(output, .readOnly)
    }

    func testTheRPUsOwnMatrixGivesTheSameAnswerAsTheConstants() throws {
        let mapper = try ToneMapper()
        let codes = [64, 400, 700, 940]
        let source = try makeSource(codes: codes)
        let base = ToneMapParameters(
            sourceMinPQ: 0, sourceMaxPQ: pqInverseEOTF(0.1),
            targetMinPQ: 0, targetMaxPQ: pqInverseEOTF(0.0203)
        )
        // what the fixture's RPU actually carries, to four decimals the same
        // matrix as the BT.2020 constants
        let fromRPU = ToneMapParameters(
            yccToRGB: simd_float3x3(rows: [
                SIMD3(9574.0 / 8192, 0, 13802.0 / 8192),
                SIMD3(9574.0 / 8192, -1540.0 / 8192, -5348.0 / 8192),
                SIMD3(9574.0 / 8192, 17610.0 / 8192, 0),
            ]),
            yccOffset: SIMD3(64.0 / 1023, 512.0 / 1023, 512.0 / 1023),
            sourceMinPQ: base.sourceMinPQ, sourceMaxPQ: base.sourceMaxPQ,
            targetMinPQ: base.targetMinPQ, targetMaxPQ: base.targetMaxPQ
        )
        let one = try mapper.mapped(source, parameters: base)
        let other = try mapper.mapped(source, parameters: fromRPU)
        CVPixelBufferLockBaseAddress(one, .readOnly)
        CVPixelBufferLockBaseAddress(other, .readOnly)
        let a = CVPixelBufferGetBaseAddress(one)!.assumingMemoryBound(to: UInt16.self)
        let b = CVPixelBufferGetBaseAddress(other)!.assumingMemoryBound(to: UInt16.self)
        for x in 0..<codes.count {
            XCTAssertEqual(
                Float(Float16(bitPattern: a[x * 4])), Float(Float16(bitPattern: b[x * 4])),
                accuracy: 0.003, "code \(codes[x])"
            )
        }
        CVPixelBufferUnlockBaseAddress(other, .readOnly)
        CVPixelBufferUnlockBaseAddress(one, .readOnly)
    }

    func testTheRendererTakesWhatComesBack() throws {
        let mapper = try ToneMapper()
        let output = try mapper.mapped(
            try makeSource(codes: [64, 512, 940]),
            parameters: ToneMapParameters(
                sourceMinPQ: 0, sourceMaxPQ: 0.75, targetMinPQ: 0, targetMaxPQ: 0.51
            )
        )
        var format: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: output, formatDescriptionOut: &format
        ), noErr)
        var timing = CMSampleTimingInfo(
            duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: output, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: try XCTUnwrap(format),
            sampleTiming: &timing, sampleBufferOut: &sample
        ), noErr)
        let layer = AVSampleBufferDisplayLayer()
        let synchronizer = AVSampleBufferRenderSynchronizer()
        synchronizer.addRenderer(layer.sampleBufferRenderer)
        layer.sampleBufferRenderer.enqueue(try XCTUnwrap(sample))
        synchronizer.setRate(1, time: .zero)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        // nothing on screen is observable headless: what is, is that the
        // renderer took it and did not fail
        XCTAssertNil(layer.error)
        XCTAssertEqual(layer.status, .rendering)
    }

    /// Neutral chroma has to come out neutral. The reference above cannot see
    /// this, because it reads the same offsets the kernel does; a grey staying
    /// grey is a property of the colorimetry rather than of either
    /// implementation, so it catches an offset that normalises over the wrong
    /// range even though both sides agree with each other.
    func testAGreyStaysGrey() throws {
        // black at code 64, neutral chroma at 512, over the 1023 the read
        // normalises a ten bit code by
        XCTAssertEqual(ToneMapParameters.limitedRangeOffset.x, 64.0 / 1023, accuracy: 1e-7)
        XCTAssertEqual(ToneMapParameters.limitedRangeOffset.y, 512.0 / 1023, accuracy: 1e-7)
        XCTAssertEqual(ToneMapParameters.limitedRangeOffset.z, 512.0 / 1023, accuracy: 1e-7)

        let mapper = try ToneMapper()
        let codes = [200, 400, 512, 700, 940]
        let output = try mapper.mapped(
            try makeSource(codes: codes),
            parameters: ToneMapParameters(
                sourceMinPQ: 0, sourceMaxPQ: pqInverseEOTF(0.1),
                targetMinPQ: 0, targetMaxPQ: pqInverseEOTF(0.0203)
            )
        )
        CVPixelBufferLockBaseAddress(output, .readOnly)
        let pixels = CVPixelBufferGetBaseAddress(output)!.assumingMemoryBound(to: UInt16.self)
        for (x, code) in codes.enumerated() {
            let red = Float(Float16(bitPattern: pixels[x * 4]))
            let green = Float(Float16(bitPattern: pixels[x * 4 + 1]))
            let blue = Float(Float16(bitPattern: pixels[x * 4 + 2]))
            XCTAssertEqual(red, green, accuracy: 0.002, "red against green, code \(code)")
            XCTAssertEqual(blue, green, accuracy: 0.002, "blue against green, code \(code)")
        }
        CVPixelBufferUnlockBaseAddress(output, .readOnly)
    }

    /// BT.2100 HLG on the CPU: inverse OETF to scene light, then the 1000 nit
    /// reference OOTF, onto the same 10000-nits-is-1.0 axis PQ decodes to.
    /// Neutral only, which is all the reference needs: luminance equals the
    /// channel value when the three are equal.
    func referenceHLGRed(luma: Int, parameters: ToneMapParameters) -> Float {
        let y = Float(luma << 6) / 65535 * (65535.0 / 65472.0)
        let signal = min(max(1.1678 * (y - parameters.yccOffset.x), 0), 1)
        let a: Float = 0.17883277, b: Float = 0.28466892, c: Float = 0.55991073
        let scene = signal <= 0.5 ? signal * signal / 3 : (expf((signal - c) / a) + b) / 12
        let display = scene * powf(max(scene, 1e-6), 0.2) * 0.1
        let peak = pqInverseEOTF(Double(display))
        return pqEOTF(referenceEETF(peak, parameters)) * 100
    }

    /// The same kernel, told the picture is HLG: decoded through the HLG
    /// EOTF and mapped by the same curve, checked against the CPU reference.
    func testHLGDecodesThroughItsOwnEOTF() throws {
        let mapper = try ToneMapper()
        let codes = [64, 200, 400, 512, 700, 940]
        let source = try makeSource(codes: codes)
        // a 1000 nit HLG source on a 203 nit screen
        let parameters = ToneMapParameters(
            sourceMinPQ: 0, sourceMaxPQ: pqInverseEOTF(0.1),
            targetMinPQ: 0, targetMaxPQ: pqInverseEOTF(0.0203),
            sourceTransfer: 1
        )
        let output = try mapper.mapped(source, parameters: parameters)
        CVPixelBufferLockBaseAddress(output, .readOnly)
        let pixels = CVPixelBufferGetBaseAddress(output)!.assumingMemoryBound(to: UInt16.self)
        for (x, code) in codes.enumerated() {
            XCTAssertEqual(
                Float(Float16(bitPattern: pixels[x * 4])),
                referenceHLGRed(luma: code, parameters: parameters),
                accuracy: 0.004, "code \(code)"
            )
        }
        // and HLG's own peak white lands on the display's peak, like PQ's does
        XCTAssertEqual(
            Float(Float16(bitPattern: pixels[5 * 4])), 2.03, accuracy: 0.02
        )
        CVPixelBufferUnlockBaseAddress(output, .readOnly)
    }

    /// The black a display is told of is a mastering monitor's whatever the
    /// peak: a share of a bright peak is a grey the display lifts to.
    func testTheStatedBlackIsAMonitorsWhateverThePeak() {
        for peak in [245.0, 6700.0] {
            let bytes = [UInt8](hdr10StaticMetadata(peakNits: peak).masteringDisplay)
            let black = bytes[20...23].reduce(0) { $0 << 8 | UInt32($1) }
            XCTAssertEqual(black, 50, "0.005 nits in units of 0.0001, under a \(peak) nit peak")
        }
    }

    /// The ratio between channels is the hue. A curve applied per channel
    /// bends the brightest channel alone and leaves the others, which pulls
    /// every mapped highlight toward white; run on max(R,G,B) with the other
    /// two following by the same factor, the ratio survives the mapping
    /// exactly. The reference run maps onto the source's own peak, where the
    /// curve moves nothing it does not clip, so its ratio is the source's.
    func testAHotColorKeepsItsHue() throws {
        let mapper = try ToneMapper()
        let source = try makeSource(codes: [700], chroma: (cb: 450, cr: 650))
        let squeezed = try mapper.mapped(
            source,
            parameters: ToneMapParameters(
                sourceMinPQ: 0, sourceMaxPQ: pqInverseEOTF(0.1),
                targetMinPQ: 0, targetMaxPQ: pqInverseEOTF(0.0203)
            )
        )
        let roomy = try mapper.mapped(
            source,
            parameters: ToneMapParameters(
                sourceMinPQ: 0, sourceMaxPQ: pqInverseEOTF(0.1),
                targetMinPQ: 0, targetMaxPQ: pqInverseEOTF(0.1)
            )
        )
        func redOverGreen(_ buffer: CVPixelBuffer) -> Float {
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            let pixels = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt16.self)
            return Float(Float16(bitPattern: pixels[0])) / Float(Float16(bitPattern: pixels[1]))
        }
        let mapped = redOverGreen(squeezed)
        let reference = redOverGreen(roomy)
        XCTAssertGreaterThan(reference, 1.5, "the fixture must actually be a hot color")
        XCTAssertEqual(mapped, reference, accuracy: reference * 0.05)
    }

    /// The dispatch covers the picture in whole 32x8 threadgroups, so a frame
    /// bigger than one group is the only thing that proves every group runs and
    /// that the kernel's bounds check drops the ragged edge rather than the
    /// picture. Every other test here fits inside group (0, 0).
    func testEveryThreadgroupRuns() throws {
        let mapper = try ToneMapper()
        // 70 x 19 is neither a multiple of 32 nor of 8: three groups across,
        // three down, both edges partial
        let codes = (0..<70).map { 64 + $0 * 12 }
        let parameters = ToneMapParameters(
            sourceMinPQ: 0, sourceMaxPQ: pqInverseEOTF(0.1),
            targetMinPQ: 0, targetMaxPQ: pqInverseEOTF(0.0203)
        )
        let output = try mapper.mapped(try makeSource(codes: codes, rows: 19), parameters: parameters)
        CVPixelBufferLockBaseAddress(output, .readOnly)
        let pixels = CVPixelBufferGetBaseAddress(output)!.assumingMemoryBound(to: UInt16.self)
        let stride = CVPixelBufferGetBytesPerRow(output) / 2
        for row in [0, 8, 16, 18] {
            for (x, code) in codes.enumerated() {
                XCTAssertEqual(
                    Float(Float16(bitPattern: pixels[row * stride + x * 4])),
                    referenceRed(luma: code, chroma: 512, parameters: parameters),
                    accuracy: 0.002, "row \(row), code \(code)"
                )
            }
        }
        CVPixelBufferUnlockBaseAddress(output, .readOnly)
    }

    /// Full range carries different constants and none ship, so it is refused
    /// rather than decoded as if it were video range.
    func testAFullRangeBufferIsRefused() throws {
        let mapper = try ToneMapper()
        let source = try makeSource(
            codes: [64, 512, 940], format: kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        )
        XCTAssertThrowsError(try mapper.mapped(
            source,
            parameters: ToneMapParameters(
                sourceMinPQ: 0, sourceMaxPQ: 1, targetMinPQ: 0, targetMaxPQ: 0.5
            )
        )) { error in
            XCTAssertEqual(
                error as? ToneMapError,
                .unsupportedFormat(kCVPixelFormatType_420YpCbCr10BiPlanarFullRange)
            )
        }
    }

    /// The format is the destination's, not the mapper's: half floats are the
    /// only one of the two that can hold light above SDR white, and only a
    /// display with headroom has anywhere to put it.
    func testTheOutputFormatFollowsTheDisplay() throws {
        let source = try makeSource(codes: [64, 512, 940])
        let parameters = ToneMapParameters(
            sourceMinPQ: 0, sourceMaxPQ: pqInverseEOTF(0.1),
            targetMinPQ: 0, targetMaxPQ: DisplayCapability(headroom: 1).targetMaxPQ
        )
        let sdr = try ToneMapper(pixelFormat: DisplayCapability(headroom: 1).toneMapPixelFormat)
        XCTAssertEqual(sdr.pixelFormat, kCVPixelFormatType_32BGRA)
        XCTAssertEqual(
            CVPixelBufferGetPixelFormatType(try sdr.mapped(source, parameters: parameters)),
            kCVPixelFormatType_32BGRA
        )
        let hdr = try ToneMapper(pixelFormat: DisplayCapability(headroom: 4).toneMapPixelFormat)
        XCTAssertEqual(hdr.pixelFormat, kCVPixelFormatType_64RGBAHalf)
        XCTAssertEqual(
            CVPixelBufferGetPixelFormatType(try hdr.mapped(source, parameters: parameters)),
            kCVPixelFormatType_64RGBAHalf
        )
    }

    func testAFormatItCannotStoreIsRefusedAtInit() {
        XCTAssertThrowsError(try ToneMapper(pixelFormat: kCVPixelFormatType_420YpCbCr8Planar)) {
            XCTAssertEqual(
                $0 as? ToneMapError, .unsupportedFormat(kCVPixelFormatType_420YpCbCr8Planar)
            )
        }
    }

    /// The half float picture, bit for bit. A display with headroom keeps
    /// every bit of precision the curve produced, so the proof that nothing
    /// was traded away for the SDR path's memory is that these words did not
    /// move at all.
    func testTheHalfFloatPictureIsUnchangedToTheBit() throws {
        let codes = [64, 200, 400, 512, 700, 800, 900, 940]
        let output = try ToneMapper(pixelFormat: kCVPixelFormatType_64RGBAHalf).mapped(
            try makeSource(codes: codes),
            parameters: ToneMapParameters(
                sourceMinPQ: 0, sourceMaxPQ: pqInverseEOTF(0.1),
                targetMinPQ: 0, targetMaxPQ: pqInverseEOTF(0.0203)
            )
        )
        CVPixelBufferLockBaseAddress(output, .readOnly)
        let pixels = CVPixelBufferGetBaseAddress(output)!.assumingMemoryBound(to: UInt16.self)
        let words = (0..<(codes.count * 4)).map { pixels[$0] }
        CVPixelBufferUnlockBaseAddress(output, .readOnly)
        XCTAssertEqual(words, [
            0x0000, 0x0000, 0x0000, 0x3c00, 0x21ac, 0x21ac, 0x21ac, 0x3c00,
            0x3453, 0x3453, 0x3453, 0x3c00, 0x3c17, 0x3c17, 0x3c17, 0x3c00,
            0x400e, 0x400e, 0x400e, 0x3c00, 0x400f, 0x400f, 0x400f, 0x3c00,
            0x400f, 0x400f, 0x400f, 0x3c00, 0x400f, 0x400f, 0x400f, 0x3c00,
        ])
    }

    /// The two formats are two containers for one picture: on an SDR
    /// destination the half float one holds linear light at or below white and
    /// the eight bit one holds the same light behind the BT.2020 transfer
    /// function, so decoding one has to give back the other.
    func testTheSDRPictureCarriesTheSameLightAsTheHalfFloatOne() throws {
        let codes = [64, 200, 300, 400, 512, 600, 700, 800, 900, 940]
        let source = try makeSource(codes: codes)
        // an SDR screen: the curve lands the source's peak on 100 nits, which
        // is where 1.0 is
        let parameters = ToneMapParameters(
            sourceMinPQ: 0, sourceMaxPQ: pqInverseEOTF(0.1),
            targetMinPQ: 0, targetMaxPQ: DisplayCapability(headroom: 1).targetMaxPQ
        )
        let wide = try ToneMapper(pixelFormat: kCVPixelFormatType_64RGBAHalf)
            .mapped(source, parameters: parameters)
        let narrow = try ToneMapper(pixelFormat: kCVPixelFormatType_32BGRA)
            .mapped(source, parameters: parameters)
        CVPixelBufferLockBaseAddress(wide, .readOnly)
        CVPixelBufferLockBaseAddress(narrow, .readOnly)
        let linear = CVPixelBufferGetBaseAddress(wide)!.assumingMemoryBound(to: UInt16.self)
        let encoded = CVPixelBufferGetBaseAddress(narrow)!.assumingMemoryBound(to: UInt8.self)
        for (x, code) in codes.enumerated() {
            for (channel, name) in [(0, "red"), (1, "green"), (2, "blue")] {
                let light = Float(Float16(bitPattern: linear[x * 4 + channel]))
                XCTAssertLessThanOrEqual(light, 1.0, "\(name) above white, code \(code)")
                // BGRA: blue first, and the wide picture is RGBA
                let stored = Float(encoded[x * 4 + (2 - channel)]) / 255
                // BT.1886 with black at zero, which is what CoreGraphics reads
                // an ITU-R BT.709 picture back through; one eight bit code of
                // tolerance, which is what the store rounds to
                XCTAssertEqual(
                    stored, powf(light, 1 / 2.4), accuracy: 1.0 / 255, "\(name), code \(code)"
                )
            }
            XCTAssertEqual(encoded[x * 4 + 3], 255, "alpha, code \(code)")
        }
        CVPixelBufferUnlockBaseAddress(narrow, .readOnly)
        CVPixelBufferUnlockBaseAddress(wide, .readOnly)
    }

    /// The eight bit picture is tagged BT.709, so what the system reads back
    /// out of it has to be the light that went in - the transfer function the
    /// kernel writes and the one the colour space names must be the same one.
    func testTheSystemReadsBackTheLightTheSDRPictureWasGiven() throws {
        let codes = [64, 300, 512, 700, 940]
        let source = try makeSource(codes: codes)
        let parameters = ToneMapParameters(
            sourceMinPQ: 0, sourceMaxPQ: pqInverseEOTF(0.1),
            targetMinPQ: 0, targetMaxPQ: DisplayCapability(headroom: 1).targetMaxPQ
        )
        let wide = try ToneMapper(pixelFormat: kCVPixelFormatType_64RGBAHalf)
            .mapped(source, parameters: parameters)
        let narrow = try ToneMapper(pixelFormat: kCVPixelFormatType_32BGRA)
            .mapped(source, parameters: parameters)
        // Both through CoreImage into the same extended linear space, which is
        // the system applying each buffer's own attached colour space.
        let context = CIContext()
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020))
        var fromWide = [Float](repeating: 0, count: codes.count * 2 * 4)
        var fromNarrow = fromWide
        for (buffer, output) in [(wide, 0), (narrow, 1)] {
            let image = CIImage(cvPixelBuffer: buffer)
            let rows = CVPixelBufferGetWidth(buffer) * 4 * MemoryLayout<Float>.size
            let render = { (bytes: UnsafeMutableRawPointer) in
                context.render(
                    image, toBitmap: bytes, rowBytes: rows, bounds: image.extent,
                    format: .RGBAf, colorSpace: space
                )
            }
            if output == 0 { fromWide.withUnsafeMutableBytes { render($0.baseAddress!) } }
            else { fromNarrow.withUnsafeMutableBytes { render($0.baseAddress!) } }
        }
        for (x, code) in codes.enumerated() {
            // one eight bit step of the transfer function, at its steepest
            XCTAssertEqual(fromNarrow[x * 4], fromWide[x * 4], accuracy: 0.006, "code \(code)")
        }
    }

    /// A curve that lifts black still rises from it smoothly: the codes just
    /// over black climb a few eight bit codes at a time rather than stepping
    /// from nothing to the lifted floor.
    func testTheEightBitStoreRisesFromBlackWithNoStep() throws {
        let parameters = ToneMapParameters(
            sourceMinPQ: 0, sourceMaxPQ: pqInverseEOTF(0.1),
            targetMinPQ: pqInverseEOTF(0.00001), targetMaxPQ: DisplayCapability(headroom: 1).targetMaxPQ
        )
        let rows = 8
        let output = try ToneMapper(pixelFormat: kCVPixelFormatType_32BGRA).mapped(
            try makeSource(codes: Array(64..<96), rows: rows), parameters: parameters)
        CVPixelBufferLockBaseAddress(output, .readOnly)
        let pixels = CVPixelBufferGetBaseAddress(output)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(output)
        // each code's red over its rows, the dither averaged out
        let means = (0..<32).map { x in
            (0..<rows).reduce(0.0) { $0 + Double(pixels[$1 * stride + x * 4 + 2]) } / Double(rows)
        }
        CVPixelBufferUnlockBaseAddress(output, .readOnly)
        XCTAssertEqual(means[0], 0, "black itself")
        for x in 1..<32 {
            XCTAssertGreaterThanOrEqual(means[x], means[x - 1] - 0.5, "code \(64 + x)")
            XCTAssertLessThan(means[x] - means[x - 1], 6, "code \(64 + x) steps from \(means[x - 1]) to \(means[x])")
        }
    }

    /// A value between two eight bit codes must come out as a mix of the two,
    /// in the proportion that reads back as the value: that is what dither
    /// is, and a flat field stored as one single code is the banding this
    /// test forbids. The half float store is untouched - it never quantizes.
    func testTheEightBitStoreDithersWhatItCannotHold() throws {
        let parameters = ToneMapParameters(
            sourceMinPQ: 0, sourceMaxPQ: pqInverseEOTF(0.1),
            targetMinPQ: 0, targetMaxPQ: DisplayCapability(headroom: 1).targetMaxPQ
        )
        func encoded(_ code: Int) -> Float {
            powf(min(referenceRed(luma: code, chroma: 512, parameters: parameters), 1), 1 / 2.4)
                * 255
        }
        // a grey whose encoded value lands squarely between two codes, found
        // from the CPU reference rather than pinned by hand
        let code = try XCTUnwrap((300...700).first {
            let fraction = encoded($0) - encoded($0).rounded(.down)
            return fraction > 0.35 && fraction < 0.65
        })
        let output = try ToneMapper(pixelFormat: kCVPixelFormatType_32BGRA).mapped(
            try makeSource(codes: Array(repeating: code, count: 64), rows: 8),
            parameters: parameters
        )
        CVPixelBufferLockBaseAddress(output, .readOnly)
        let pixels = CVPixelBufferGetBaseAddress(output)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(output)
        var values: [UInt8] = []
        for row in 0..<8 {
            for x in 0..<64 { values.append(pixels[row * stride + x * 4]) }
        }
        CVPixelBufferUnlockBaseAddress(output, .readOnly)
        let distinct = Set(values).sorted()
        XCTAssertEqual(distinct.count, 2, "a flat field between two codes must store both")
        XCTAssertEqual(Int(distinct[1]) - Int(distinct[0]), 1)
        let mean = values.reduce(0.0) { $0 + Double($1) } / Double(values.count)
        XCTAssertEqual(mean, Double(encoded(code)), accuracy: 0.25)
        // blue noise has no period of four: the tile a pixel sits in does
        // not decide its code
        var aperiodic = 0
        for row in 0..<8 {
            for x in 0..<60 where values[row * 64 + x] != values[row * 64 + x + 4] { aperiodic += 1 }
        }
        XCTAssertGreaterThan(aperiodic, 0)
    }

    /// The ten bit store dithers as the eight bit one does: a grey the
    /// curve lands between two codes leaves as a mix of both.
    func testThePQStoreDithersWhatItCannotHold() throws {
        let parameters = ToneMapParameters(
            sourceMinPQ: 0, sourceMaxPQ: pqInverseEOTF(0.4),
            targetMinPQ: 0, targetMaxPQ: pqInverseEOTF(0.03)
        )
        func encoded(_ code: Int) -> Float {
            let light = referenceRed(luma: code, chroma: 512, parameters: parameters) / 100
            return 64 + 876 * pqInverseEOTF(Double(light))
        }
        let code = try XCTUnwrap((300...900).first {
            let fraction = encoded($0) - encoded($0).rounded(.down)
            return fraction > 0.4 && fraction < 0.6
        })
        let output = try ToneMapper(pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
            .mapped(try makeSource(codes: Array(repeating: code, count: 64), rows: 8), parameters: parameters)
        CVPixelBufferLockBaseAddress(output, .readOnly)
        let luma = CVPixelBufferGetBaseAddressOfPlane(output, 0)!.assumingMemoryBound(to: UInt16.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(output, 0) / 2
        var values: [Int] = []
        for row in 0..<8 {
            for x in 0..<64 { values.append(Int(luma[row * stride + x] >> 6)) }
        }
        CVPixelBufferUnlockBaseAddress(output, .readOnly)
        let distinct = Set(values).sorted()
        XCTAssertEqual(distinct.count, 2, "a flat field between two codes must store both")
        XCTAssertEqual(distinct[1] - distinct[0], 1)
        let mean = values.reduce(0.0) { $0 + Double($1) } / Double(values.count)
        XCTAssertEqual(mean, Double(encoded(code)), accuracy: 0.3)
        // blue noise has no period of four: the tile a pixel sits in does
        // not decide its code
        var aperiodic = 0
        for row in 0..<8 {
            for x in 0..<60 where values[row * 64 + x] != values[row * 64 + x + 4] { aperiodic += 1 }
        }
        XCTAssertGreaterThan(aperiodic, 0)
    }

    /// Dither never lifts black: a black picture leaves both quantized
    /// stores on black, pixel for pixel.
    func testBlackStaysBlackInBothStores() throws {
        let black = try makeSource(codes: Array(repeating: 64, count: 64), rows: 64)
        let sdr = try ToneMapper(pixelFormat: kCVPixelFormatType_32BGRA).mapped(
            black,
            parameters: ToneMapParameters(
                sourceMinPQ: 0, sourceMaxPQ: pqInverseEOTF(0.1),
                targetMinPQ: 0, targetMaxPQ: DisplayCapability(headroom: 1).targetMaxPQ))
        CVPixelBufferLockBaseAddress(sdr, .readOnly)
        let pixels = CVPixelBufferGetBaseAddress(sdr)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(sdr)
        for y in 0..<64 {
            for x in 0..<64 {
                for channel in 0..<3 { XCTAssertEqual(pixels[y * stride + x * 4 + channel], 0, "(\(x), \(y))") }
            }
        }
        CVPixelBufferUnlockBaseAddress(sdr, .readOnly)
        let pq = try ToneMapper(pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange).mapped(
            black,
            parameters: ToneMapParameters(
                sourceMinPQ: 0, sourceMaxPQ: pqInverseEOTF(0.4),
                targetMinPQ: 0, targetMaxPQ: pqInverseEOTF(0.03)))
        CVPixelBufferLockBaseAddress(pq, .readOnly)
        let luma = CVPixelBufferGetBaseAddressOfPlane(pq, 0)!.assumingMemoryBound(to: UInt16.self)
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(pq, 0) / 2
        for y in 0..<64 {
            for x in 0..<64 { XCTAssertEqual(luma[y * lumaStride + x] >> 6, 64, "(\(x), \(y))") }
        }
        let chroma = CVPixelBufferGetBaseAddressOfPlane(pq, 1)!.assumingMemoryBound(to: UInt16.self)
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(pq, 1) / 2
        for y in 0..<32 {
            for x in 0..<64 { XCTAssertEqual(chroma[y * chromaStride + x] >> 6, 512, "(\(x), \(y))") }
        }
        CVPixelBufferUnlockBaseAddress(pq, .readOnly)
    }

    /// A one code step in the ten bit luma leaves as a ramp: the deband
    /// reaches up to 16 pixels out, drawn per pixel, so a column ten away
    /// from the step already moves toward it, and the plateaus past its
    /// reach keep their level.
    /// A one code step in the chroma over a flat field is a hue band, and
    /// the chroma is debanded as the luma is.
    func testAChromaBandBecomesARamp() throws {
        let parameters = ToneMapParameters(
            sourceMinPQ: 0, sourceMaxPQ: pqInverseEOTF(0.1), targetMinPQ: 0, targetMaxPQ: pqInverseEOTF(0.1))
        let output = try ToneMapper().mapped(
            try makePicture(width: 64, height: 64, luma: { _, _ in 500 }) { x, _ in (512, x < 16 ? 600 : 601) },
            parameters: parameters)
        let means = (0..<64).map { x in (0..<64).reduce(Float(0)) { $0 + red(output, x: x, y: $1) } / 64 }
        let left = red(try ToneMapper().mapped(try makeSource(codes: [500], chroma: (512, 600)), parameters: parameters), x: 0)
        let right = red(try ToneMapper().mapped(try makeSource(codes: [500], chroma: (512, 601)), parameters: parameters), x: 0)
        XCTAssertEqual(means[0], left, accuracy: 1e-4)
        XCTAssertEqual(means[63], right, accuracy: 1e-4)
        // past the reach of the chroma filter either side of the step, the
        // red is already part way between the two
        XCTAssertGreaterThan(means[24], left + (right - left) * 0.01, "\(means)")
        XCTAssertLessThan(means[40], right - (right - left) * 0.01, "\(means)")
    }

    func testALumaBandBecomesARamp() throws {
        let parameters = ToneMapParameters(
            sourceMinPQ: 0, sourceMaxPQ: pqInverseEOTF(0.1), targetMinPQ: 0, targetMaxPQ: pqInverseEOTF(0.1))
        let output = try ToneMapper().mapped(
            try makePicture(width: 64, height: 64, luma: { x, _ in x < 32 ? 500 : 501 }) { _, _ in (512, 512) },
            parameters: parameters)
        let means = (0..<64).map { x in (0..<64).reduce(Float(0)) { $0 + red(output, x: x, y: $1) } / 64 }
        let left = red(try ToneMapper().mapped(try makeSource(codes: [500]), parameters: parameters), x: 0)
        let right = red(try ToneMapper().mapped(try makeSource(codes: [501]), parameters: parameters), x: 0)
        for x in 0..<8 { XCTAssertEqual(means[x], left, accuracy: 1e-4, "column \(x)") }
        for x in 56..<64 { XCTAssertEqual(means[x], right, accuracy: 1e-4, "column \(x)") }
        XCTAssertGreaterThan(means[22], left + (right - left) * 0.01, "\(means)")
        XCTAssertGreaterThan(means[31], left + (right - left) * 0.2, "\(means)")
        XCTAssertLessThan(means[32], right - (right - left) * 0.2, "\(means)")
    }

    /// The first pixel of a PQ picture: its luma code and its chroma pair.
    private func coded(_ buffer: CVPixelBuffer) -> (y: Int, cb: Int, cr: Int) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt16.self)
        let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt16.self)
        return (Int(luma[0] >> 6), Int(chroma[0] >> 6), Int(chroma[1] >> 6))
    }

    /// A colour edge is reconstructed through the samples around it: each
    /// plateau reads exactly as a flat field of its colour up to its last
    /// sample, with no ring past the edge, and the edge itself is crossed
    /// in the one luma pixel between the two chroma samples.
    func testAColourEdgeIsReconstructedThroughItsNeighbours() throws {
        let mapper = try ToneMapper()
        let parameters = ToneMapParameters(
            sourceMinPQ: 0, sourceMaxPQ: pqInverseEOTF(0.1),
            targetMinPQ: 0, targetMaxPQ: pqInverseEOTF(0.1)
        )
        let edge = try mapper.mapped(
            try makePicture(width: 16, height: 2, luma: { _, _ in 500 }) { x, _ in (512, x < 4 ? 450 : 600) },
            parameters: parameters)
        let left = red(try mapper.mapped(try makeSource(codes: [500], chroma: (512, 450)), parameters: parameters), x: 0)
        let right = red(try mapper.mapped(try makeSource(codes: [500], chroma: (512, 600)), parameters: parameters), x: 0)
        XCTAssertLessThan(left, right, "the fixture must be an edge in red")
        for x in 0...6 { XCTAssertEqual(red(edge, x: x), left, accuracy: 0.002, "column \(x)") }
        for x in 8...15 { XCTAssertEqual(red(edge, x: x), right, accuracy: 0.002, "column \(x)") }
        XCTAssertGreaterThan(red(edge, x: 7), left)
        XCTAssertLessThan(red(edge, x: 7), right)
    }

    /// Centred siting puts each chroma sample half a luma pixel to the right,
    /// so the edge between two samples falls between two luma pixels: both
    /// read between the plateaus, and each plateau still reads exactly up to
    /// the pixel before. The block's two pixels then read five chroma columns
    /// between them rather than four.
    func testACentredChromaEdgeIsCrossedBetweenItsTwoSamples() throws {
        let mapper = try ToneMapper()
        let parameters = ToneMapParameters(
            sourceMinPQ: 0, sourceMaxPQ: pqInverseEOTF(0.1),
            targetMinPQ: 0, targetMaxPQ: pqInverseEOTF(0.1)
        )
        let picture = try makePicture(width: 16, height: 2, luma: { _, _ in 500 }) { x, _ in (512, x < 4 ? 450 : 600) }
        CVBufferSetAttachment(
            picture, kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_Center,
            .shouldPropagate)
        let edge = try mapper.mapped(picture, parameters: parameters)
        let left = red(try mapper.mapped(try makeSource(codes: [500], chroma: (512, 450)), parameters: parameters), x: 0)
        let right = red(try mapper.mapped(try makeSource(codes: [500], chroma: (512, 600)), parameters: parameters), x: 0)
        for x in 0...6 { XCTAssertEqual(red(edge, x: x), left, accuracy: 0.002, "column \(x)") }
        for x in 9...15 { XCTAssertEqual(red(edge, x: x), right, accuracy: 0.002, "column \(x)") }
        for x in 7...8 {
            XCTAssertGreaterThan(red(edge, x: x), left, "column \(x)")
            XCTAssertLessThan(red(edge, x: x), right, "column \(x)")
        }
    }

    /// Top left siting, a UHD Blu-ray's, puts each chroma sample on the
    /// first row of its block rather than between its two: a luma row on a
    /// sample reads it exactly, and only the row between two samples is
    /// crossed. Read as left siting, the row on the sample would be crossed
    /// too.
    func testATopLeftChromaEdgeIsCrossedOnTheRowBetweenItsSamples() throws {
        let mapper = try ToneMapper()
        let parameters = ToneMapParameters(
            sourceMinPQ: 0, sourceMaxPQ: pqInverseEOTF(0.1),
            targetMinPQ: 0, targetMaxPQ: pqInverseEOTF(0.1)
        )
        func edge(sitedAt location: CFString?) throws -> CVPixelBuffer {
            let picture = try makePicture(width: 2, height: 16, luma: { _, _ in 500 }) { _, y in (512, y < 4 ? 450 : 600) }
            if let location {
                CVBufferSetAttachment(picture, kCVImageBufferChromaLocationTopFieldKey, location, .shouldPropagate)
            }
            return try mapper.mapped(picture, parameters: parameters)
        }
        let left = red(try mapper.mapped(try makeSource(codes: [500], chroma: (512, 450)), parameters: parameters), x: 0)
        let right = red(try mapper.mapped(try makeSource(codes: [500], chroma: (512, 600)), parameters: parameters), x: 0)
        let topLeft = try edge(sitedAt: kCVImageBufferChromaLocation_TopLeft)
        for y in 0...6 { XCTAssertEqual(red(topLeft, x: 0, y: y), left, accuracy: 0.002, "row \(y)") }
        for y in 8...15 { XCTAssertEqual(red(topLeft, x: 0, y: y), right, accuracy: 0.002, "row \(y)") }
        XCTAssertGreaterThan(red(topLeft, x: 0, y: 7), left)
        XCTAssertLessThan(red(topLeft, x: 0, y: 7), right)
        XCTAssertLessThan(red(try edge(sitedAt: nil), x: 0, y: 8), right - 0.002, "left siting crosses row 8 too")
    }

    /// The PQ picture's chroma is the linear picture's, sited left as
    /// MPEG-2 has it and says so: each sample is the [1 2 1] filter over its
    /// own column and the two beside it, the two rows averaged. A centred
    /// average of the block lands every colour half a pixel to the right of
    /// where a display reading left siting draws it.
    func testThePQChromaIsSitedLeft() throws {
        let parameters = ToneMapParameters(
            sourceMinPQ: 0, sourceMaxPQ: pqInverseEOTF(0.1),
            targetMinPQ: 0, targetMaxPQ: pqInverseEOTF(0.1)
        )
        let picture = try makePicture(width: 16, height: 2, luma: { _, _ in 500 }) { x, _ in (512, x < 4 ? 450 : 600) }
        // the scratch the PQ store encodes from holds exactly what the half
        // float store is handed
        let linear = try ToneMapper().mapped(picture, parameters: parameters)
        let output = try ToneMapper(pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
            .mapped(picture, parameters: parameters)
        XCTAssertEqual(
            CVBufferCopyAttachment(output, kCVImageBufferChromaLocationTopFieldKey, nil) as? String,
            kCVImageBufferChromaLocation_Left as String)
        XCTAssertEqual(
            CVBufferCopyAttachment(output, kCVImageBufferChromaLocationBottomFieldKey, nil) as? String,
            kCVImageBufferChromaLocation_Left as String)
        CVPixelBufferLockBaseAddress(linear, .readOnly)
        let pixels = CVPixelBufferGetBaseAddress(linear)!.assumingMemoryBound(to: UInt16.self)
        let stride = CVPixelBufferGetBytesPerRow(linear) / 2
        var sums = [SIMD2<Float>](repeating: .zero, count: 8)
        for sample in 0..<8 {
            for row in 0..<2 {
                for (dx, weight) in [(-1, Float(1)), (0, 2), (1, 1)] {
                    let x = min(max(2 * sample + dx, 0), 15)
                    let rgb = (0..<3).map { channel in
                        let light = Float(Float16(bitPattern: pixels[row * stride + x * 4 + channel])) * 0.01
                        return pqInverseEOTF(Double(min(max(light, 0), 1)))
                    }
                    let y = 0.2627 * rgb[0] + 0.6780 * rgb[1] + 0.0593 * rgb[2]
                    sums[sample] += weight * SIMD2((rgb[2] - y) / 1.8814, (rgb[0] - y) / 1.4746)
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(linear, .readOnly)
        CVPixelBufferLockBaseAddress(output, .readOnly)
        let chroma = CVPixelBufferGetBaseAddressOfPlane(output, 1)!.assumingMemoryBound(to: UInt16.self)
        for sample in 0..<8 {
            let expected = 512 + 896 * sums[sample] / 8
            XCTAssertEqual(Float(chroma[2 * sample] >> 6), expected.x, accuracy: 1, "Cb of sample \(sample)")
            XCTAssertEqual(Float(chroma[2 * sample + 1] >> 6), expected.y, accuracy: 1, "Cr of sample \(sample)")
        }
        CVPixelBufferUnlockBaseAddress(output, .readOnly)
    }

    /// The PQ store's chroma filter reads the column left of each block,
    /// which the block before maps: across threadgroups, and on an odd width
    /// and height, every sample is the filter over what the half float store
    /// is handed, and every luma code is that pixel's own.
    func testThePQStoreFiltersAcrossThreadgroupsAndOddEdges() throws {
        let parameters = ToneMapParameters(
            sourceMinPQ: 0, sourceMaxPQ: pqInverseEOTF(0.1),
            targetMinPQ: 0, targetMaxPQ: pqInverseEOTF(0.1)
        )
        let width = 131, height = 5
        let picture = try makePicture(
            width: width, height: height, luma: { x, y in 300 + (x * 13 + y * 29) % 400 }
        ) { x, y in (412 + (x * 7) % 200, 480 + y * 10) }
        let linear = try ToneMapper().mapped(picture, parameters: parameters)
        let output = try ToneMapper(pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
            .mapped(picture, parameters: parameters)
        CVPixelBufferLockBaseAddress(linear, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(linear, .readOnly) }
        let pixels = CVPixelBufferGetBaseAddress(linear)!.assumingMemoryBound(to: UInt16.self)
        let stride = CVPixelBufferGetBytesPerRow(linear) / 2
        func coded(_ x: Int, _ y: Int) -> (y: Float, cbcr: SIMD2<Float>) {
            let rgb = (0..<3).map { channel in
                let light = Float(Float16(bitPattern: pixels[y * stride + x * 4 + channel])) * 0.01
                return pqInverseEOTF(Double(min(max(light, 0), 1)))
            }
            let luma = 0.2627 * rgb[0] + 0.6780 * rgb[1] + 0.0593 * rgb[2]
            return (luma, SIMD2((rgb[2] - luma) / 1.8814, (rgb[0] - luma) / 1.4746))
        }
        CVPixelBufferLockBaseAddress(output, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(output, .readOnly) }
        let luma = CVPixelBufferGetBaseAddressOfPlane(output, 0)!.assumingMemoryBound(to: UInt16.self)
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(output, 0) / 2
        // a tenth of a code past the dither's own: the half floats the
        // reference reads are rounded where the store's light is not
        for y in 0..<height {
            for x in 0..<width {
                XCTAssertEqual(
                    Float(luma[y * lumaStride + x] >> 6), 64 + 876 * coded(x, y).y, accuracy: 1.1, "luma (\(x), \(y))")
            }
        }
        let chroma = CVPixelBufferGetBaseAddressOfPlane(output, 1)!.assumingMemoryBound(to: UInt16.self)
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(output, 1) / 2
        for sy in 0..<(height + 1) / 2 {
            for sx in 0..<(width + 1) / 2 {
                var sum = SIMD2<Float>.zero
                var weight: Float = 0
                for row in [2 * sy, 2 * sy + 1] where row < height {
                    for (dx, w) in [(-1, Float(1)), (0, 2), (1, 1)] {
                        sum += w * coded(min(max(2 * sx + dx, 0), width - 1), row).cbcr
                        weight += w
                    }
                }
                let expected = 512 + 896 * sum / weight
                let at = sy * chromaStride + 2 * sx
                XCTAssertEqual(Float(chroma[at] >> 6), expected.x, accuracy: 1.1, "Cb of sample (\(sx), \(sy))")
                XCTAssertEqual(Float(chroma[at + 1] >> 6), expected.y, accuracy: 1.1, "Cr of sample (\(sx), \(sy))")
            }
        }
    }

    /// The 4:2:2 store keeps a chroma pair per row where the 4:2:0 one
    /// averages each two into one: the same luma, and the 4:2:0 chroma is
    /// the mean of the 4:2:2 rows it covers, within the two dithers.
    func testTheFourTwoTwoStoreKeepsEveryChromaRow() throws {
        let parameters = ToneMapParameters(
            sourceMinPQ: 0, sourceMaxPQ: pqInverseEOTF(0.1), targetMinPQ: 0, targetMaxPQ: pqInverseEOTF(0.1))
        let width = 131, height = 9
        // a colour that changes down the picture, which the two stores keep apart
        let picture = try makePicture(
            width: width, height: height, luma: { x, y in 300 + (x * 13 + y * 29) % 400 }
        ) { x, y in (412 + (x * 7) % 200, 380 + y * 60) }
        let wide = try ToneMapper(pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
            .mapped(picture, parameters: parameters)
        let tall = try ToneMapper(pixelFormat: kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange)
            .mapped(picture, parameters: parameters)
        XCTAssertEqual(CVPixelBufferGetHeightOfPlane(tall, 1), height)
        CVPixelBufferLockBaseAddress(wide, .readOnly)
        CVPixelBufferLockBaseAddress(tall, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(wide, .readOnly)
            CVPixelBufferUnlockBaseAddress(tall, .readOnly)
        }
        func plane(_ buffer: CVPixelBuffer, _ index: Int) -> (UnsafeMutablePointer<UInt16>, Int) {
            (CVPixelBufferGetBaseAddressOfPlane(buffer, index)!.assumingMemoryBound(to: UInt16.self),
             CVPixelBufferGetBytesPerRowOfPlane(buffer, index) / 2)
        }
        let (wideLuma, wideLumaStride) = plane(wide, 0)
        let (tallLuma, tallLumaStride) = plane(tall, 0)
        for y in 0..<height {
            for x in 0..<width {
                XCTAssertEqual(wideLuma[y * wideLumaStride + x], tallLuma[y * tallLumaStride + x], "luma (\(x), \(y))")
            }
        }
        let (wideChroma, wideStride) = plane(wide, 1)
        let (tallChroma, tallStride) = plane(tall, 1)
        var rowsApart = false
        for sy in 0..<(height + 1) / 2 {
            for sx in 0..<(width + 1) / 2 {
                for component in 0..<2 {
                    let rows = [2 * sy, 2 * sy + 1].filter { $0 < height }
                        .map { Float(tallChroma[$0 * tallStride + 2 * sx + component] >> 6) }
                    let mean = rows.reduce(0, +) / Float(rows.count)
                    XCTAssertEqual(
                        Float(wideChroma[sy * wideStride + 2 * sx + component] >> 6), mean, accuracy: 1.5,
                        "sample (\(sx), \(sy)), component \(component)")
                    if rows.count == 2, abs(rows[0] - rows[1]) >= 4 { rowsApart = true }
                }
            }
        }
        XCTAssertTrue(rowsApart, "the 4:2:2 rows keep the vertical change apart")
    }

    /// A thread maps a 2x2 block, so an odd width or height leaves the last
    /// block half outside the picture: every column and row still lands,
    /// and none is written past the edge.
    func testAnOddSizeMapsItsLastColumnAndRow() throws {
        let mapper = try ToneMapper()
        let codes = (0..<71).map { 64 + $0 * 12 }
        let parameters = ToneMapParameters(
            sourceMinPQ: 0, sourceMaxPQ: pqInverseEOTF(0.1),
            targetMinPQ: 0, targetMaxPQ: pqInverseEOTF(0.0203)
        )
        let output = try mapper.mapped(try makeSource(codes: codes, rows: 19), parameters: parameters)
        CVPixelBufferLockBaseAddress(output, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(output, .readOnly) }
        let pixels = CVPixelBufferGetBaseAddress(output)!.assumingMemoryBound(to: UInt16.self)
        let stride = CVPixelBufferGetBytesPerRow(output) / 2
        for row in [0, 17, 18] {
            for (x, code) in codes.enumerated() {
                XCTAssertEqual(
                    Float(Float16(bitPattern: pixels[row * stride + x * 4])),
                    referenceRed(luma: code, chroma: 512, parameters: parameters),
                    accuracy: 0.002, "row \(row), code \(code)"
                )
            }
        }
    }

    /// Frames in flight together take turns with what the map reads off the
    /// analysis, and each is mapped with its own: the same pictures as each
    /// mapped alone by a mapper of its own.
    func testFramesInFlightAreEachMappedWithTheirOwnAnalysis() throws {
        let parameters = ToneMapParameters(
            sourceMinPQ: 0, sourceMaxPQ: 1, targetMinPQ: 0, targetMaxPQ: pqInverseEOTF(0.03))
        let dark = try makePicture(
            width: 512, height: 64, luma: { x, y in (x / 32 + y / 16) % 2 == 0 ? 250 : 420 }
        ) { _, _ in (500, 530) }
        let bright = try makePicture(
            width: 512, height: 64, luma: { x, _ in x < 256 ? 880 : 640 + x % 7 }
        ) { x, _ in (520 + x % 5, 490) }
        let frames = [dark, bright, dark, bright, bright, dark]
        let expected = try frames.map {
            try ToneMapper(pixelFormat: kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange).mapped($0, parameters: parameters)
        }
        let overlapped = try ToneMapper(pixelFormat: kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange)
        let lock = NSLock()
        var landed = [CVPixelBuffer?](repeating: nil, count: frames.count)
        let group = DispatchGroup()
        for (index, frame) in frames.enumerated() {
            group.enter()
            try overlapped.map(frame, parameters: parameters) { picture in
                lock.lock()
                landed[index] = picture
                lock.unlock()
                group.leave()
            }
        }
        group.wait()
        func planes(_ buffer: CVPixelBuffer) -> [UInt16] {
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            var codes: [UInt16] = []
            for plane in 0..<2 {
                let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!
                let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
                let width = CVPixelBufferGetWidthOfPlane(buffer, plane) * (plane == 0 ? 1 : 2)
                for y in 0..<CVPixelBufferGetHeightOfPlane(buffer, plane) {
                    let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt16.self)
                    codes.append(contentsOf: UnsafeBufferPointer(start: row, count: width))
                }
            }
            return codes
        }
        for index in frames.indices {
            XCTAssertEqual(planes(try XCTUnwrap(landed[index])), planes(expected[index]), "frame \(index)")
        }
    }

    /// A bar a code off neutral leaves as black itself, every group of it,
    /// while a lit pixel in a bar keeps its group mapped.
    func testABlackBarLeavesAsBlack() throws {
        let width = 256, height = 128
        let lit = (x: 200, y: 8)
        let picture = try makePicture(
            width: width, height: height,
            luma: { x, y in
                if (x, y) == lit { return 300 }
                return y < 48 || y >= 80 ? 64 : 200 + (x * 7 + y * 13) % 500
            }
        ) { x, y in y < 24 || y >= 40 ? (513, 511) : (600, 450) }
        let parameters = ToneMapParameters(
            sourceMinPQ: 0, sourceMaxPQ: pqInverseEOTF(0.1), targetMinPQ: 0, targetMaxPQ: pqInverseEOTF(0.03))
        let output = try ToneMapper(pixelFormat: kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange)
            .mapped(picture, parameters: parameters)
        CVPixelBufferLockBaseAddress(output, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(output, .readOnly) }
        let luma = CVPixelBufferGetBaseAddressOfPlane(output, 0)!.assumingMemoryBound(to: UInt16.self)
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(output, 0) / 2
        let chroma = CVPixelBufferGetBaseAddressOfPlane(output, 1)!.assumingMemoryBound(to: UInt16.self)
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(output, 1) / 2
        // the bars past the picture's reach: the bottom one, and the top
        // one left of the lit pixel's group
        for y in Array(0..<16) + Array(112..<128) {
            for x in 0..<(y < 16 ? 120 : width) {
                XCTAssertEqual(luma[y * lumaStride + x] >> 6, 64, "luma at \(x), \(y)")
                XCTAssertEqual(chroma[y * chromaStride + 2 * (x / 2)] >> 6, 512, "cb at \(x), \(y)")
                XCTAssertEqual(chroma[y * chromaStride + 2 * (x / 2) + 1] >> 6, 512, "cr at \(x), \(y)")
            }
        }
        XCTAssertGreaterThan(luma[lit.y * lumaStride + lit.x] >> 6, 64)
    }

    /// Profile 5: each component runs through its reshaping curve before
    /// the RPU's matrix, and the light is taken from the RPU's LMS into
    /// BT.2020 after, as libplacebo decodes it. A polynomial, an order 2 MMR
    /// and a two piece curve land where the CPU reference of the same chain
    /// puts them.
    func testAProfile5PictureIsReshapedAndTakenOutOfLMS() throws {
        let curves = [
            DolbyVisionReshapingCurve(pivots: [0, 1023], pieces: [.polynomial([0.1, 0.8])]),
            DolbyVisionReshapingCurve(pivots: [0, 1023], pieces: [.mmr(
                order: 2, constant: 0.05,
                coefficients: [0.2, 0.5, 0.1, 0.3, 0, 0, 0.1, 0.05, 0, 0.02, 0, 0.1, 0, 0])]),
            DolbyVisionReshapingCurve(
                pivots: [0, 512, 1023], pieces: [.polynomial([0, 1, 0]), .polynomial([0.02, 0.9, 0.05])]),
        ]
        let rgbToLMS: [Float] = [0.40, 0.55, 0.05, 0.18, 0.72, 0.10, 0.02, 0.08, 0.90]
        let dovi = ToneMapper.doviReshaping(curves, blBitDepth: 10, rgbToLMS: rgbToLMS)
        var parameters = ToneMapParameters(sourceMinPQ: 0, sourceMaxPQ: 1, targetMinPQ: 0, targetMaxPQ: 1)
        parameters.yccToRGB = simd_float3x3(rows: [
            SIMD3(1, 0.1, 0.2), SIMD3(1, -0.1, 0.05), SIMD3(1, 0.15, -0.1),
        ])
        parameters.yccOffset = SIMD3(0.05, 0.5, 0.5)
        for (luma, cb, cr) in [(300, 480, 560), (600, 520, 500), (800, 600, 420)] {
            let shown = linearRGB(try ToneMapper().mapped(
                try makeSource(codes: [luma, luma], chroma: (cb, cr)), parameters: parameters, dovi: dovi))
            let expected = referenceProfile5(
                luma: luma, cb: cb, cr: cr, curves: curves, parameters: parameters, rgbToLMS: rgbToLMS)
            for channel in 0..<3 {
                XCTAssertEqual(
                    shown[channel], expected[channel], accuracy: expected[channel] * 0.01 + 2e-5,
                    "sample \((luma, cb, cr)), channel \(channel)")
            }
        }
    }

    func testTheRendererTakesTheSDRPictureToo() throws {
        let output = try ToneMapper(pixelFormat: kCVPixelFormatType_32BGRA).mapped(
            try makeSource(codes: [64, 512, 940]),
            parameters: ToneMapParameters(
                sourceMinPQ: 0, sourceMaxPQ: 0.75, targetMinPQ: 0,
                targetMaxPQ: DisplayCapability(headroom: 1).targetMaxPQ
            )
        )
        var format: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: output, formatDescriptionOut: &format
        ), noErr)
        var timing = CMSampleTimingInfo(
            duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: output, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: try XCTUnwrap(format),
            sampleTiming: &timing, sampleBufferOut: &sample
        ), noErr)
        let layer = AVSampleBufferDisplayLayer()
        let synchronizer = AVSampleBufferRenderSynchronizer()
        synchronizer.addRenderer(layer.sampleBufferRenderer)
        layer.sampleBufferRenderer.enqueue(try XCTUnwrap(sample))
        synchronizer.setRate(1, time: .zero)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertNil(layer.error)
        XCTAssertEqual(layer.status, .rendering)
    }

    func testABufferItCannotReadIsRefused() throws {
        let mapper = try ToneMapper()
        var created: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault, 8, 8, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &created
        )
        XCTAssertThrowsError(try mapper.mapped(
            try XCTUnwrap(created),
            parameters: ToneMapParameters(
                sourceMinPQ: 0, sourceMaxPQ: 1, targetMinPQ: 0, targetMaxPQ: 0.5
            )
        )) { error in
            XCTAssertEqual(error as? ToneMapError, .unsupportedFormat(kCVPixelFormatType_32BGRA))
        }
    }
}

import CoreVideo
import XCTest
@testable import LexisPlayer

final class PictureEnhancerTests: XCTestCase {
    /// A biplanar picture at eight or ten bits, every luma code by its
    /// column and row, one chroma pair throughout.
    func makePicture(
        width: Int, height: Int, tenBit: Bool, chroma: (cb: Int, cr: Int) = (128, 128),
        chromaAt: ((Int, Int) -> (cb: Int, cr: Int))? = nil,
        luma: (Int, Int) -> Int
    ) throws -> CVPixelBuffer {
        var created: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            tenBit ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                kCVPixelBufferMetalCompatibilityKey: true,
            ] as CFDictionary, &created
        ), kCVReturnSuccess)
        let buffer = try XCTUnwrap(created)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let lumaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let chromaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        for y in 0..<height {
            for x in 0..<width {
                if tenBit {
                    lumaBase.advanced(by: y * lumaStride + x * 2).assumingMemoryBound(to: UInt16.self)
                        .pointee = UInt16(luma(x, y) << 6)
                } else {
                    lumaBase.advanced(by: y * lumaStride + x).assumingMemoryBound(to: UInt8.self)
                        .pointee = UInt8(luma(x, y))
                }
            }
        }
        for y in 0..<CVPixelBufferGetHeightOfPlane(buffer, 1) {
            for x in 0..<CVPixelBufferGetWidthOfPlane(buffer, 1) {
                let pair = chromaAt?(x, y) ?? chroma
                for (i, value) in [pair.cb, pair.cr].enumerated() {
                    if tenBit {
                        chromaBase.advanced(by: y * chromaStride + (2 * x + i) * 2)
                            .assumingMemoryBound(to: UInt16.self).pointee = UInt16(value << 6)
                    } else {
                        chromaBase.advanced(by: y * chromaStride + 2 * x + i)
                            .assumingMemoryBound(to: UInt8.self).pointee = UInt8(value)
                    }
                }
            }
        }
        CVBufferSetAttachment(
            buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        return buffer
    }

    func enhanced(_ frame: CVPixelBuffer) throws -> CVPixelBuffer {
        let enhancer = try PictureEnhancer()
        var result: CVPixelBuffer?
        let landed = DispatchSemaphore(value: 0)
        try enhancer.enhance(frame) { result = $0; landed.signal() }
        landed.wait()
        return result!
    }

    /// The ten bit luma codes of a row.
    func lumaRow(_ buffer: CVPixelBuffer, y: Int) -> [Int] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt16.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) / 2
        return (0..<CVPixelBufferGetWidth(buffer)).map { Int(base[y * stride + $0] >> 6) }
    }

    /// The mean ten bit code of each column of a plane, one component of
    /// its samples.
    func columnMeans(_ buffer: CVPixelBuffer, plane: Int, components: Int = 1, component: Int = 0) -> [Double] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!.assumingMemoryBound(to: UInt16.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) / 2
        let width = CVPixelBufferGetWidthOfPlane(buffer, plane)
        let height = CVPixelBufferGetHeightOfPlane(buffer, plane)
        return (0..<width).map { x in
            (0..<height).reduce(0.0) { $0 + Double(base[$1 * stride + x * components + component] >> 6) } / Double(height)
        }
    }

    /// An eight bit source leaves as ten bit, its codes times four, its
    /// chroma copied, its tags kept.
    func testAnEightBitPictureLeavesAsTenBitWithItsTags() throws {
        let source = try makePicture(width: 64, height: 64, tenBit: false, chroma: (100, 160)) { _, _ in 120 }
        let output = try enhanced(source)
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(output), PictureEnhancer.outputFormat)
        XCTAssertEqual(
            CVBufferCopyAttachment(output, kCVImageBufferColorPrimariesKey, nil) as? String,
            kCVImageBufferColorPrimaries_ITU_R_709_2 as String)
        let codes = (0..<64).flatMap { lumaRow(output, y: $0) }
        XCTAssertEqual(Set(codes), [480])
        CVPixelBufferLockBaseAddress(output, .readOnly)
        let chroma = CVPixelBufferGetBaseAddressOfPlane(output, 1)!.assumingMemoryBound(to: UInt16.self)
        XCTAssertEqual(Int(chroma[0] >> 6), 400)
        XCTAssertEqual(Int(chroma[1] >> 6), 640)
        CVPixelBufferUnlockBaseAddress(output, .readOnly)
    }

    /// The ten bit codes of one plane, a component of its samples, row by row.
    func planeCodes(_ buffer: CVPixelBuffer, plane: Int, components: Int = 1, component: Int = 0) -> [Int] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!.assumingMemoryBound(to: UInt16.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) / 2
        let width = CVPixelBufferGetWidthOfPlane(buffer, plane), height = CVPixelBufferGetHeightOfPlane(buffer, plane)
        return (0..<height).flatMap { y in (0..<width).map { Int(base[y * stride + $0 * components + component] >> 6) } }
    }

    /// Three moving frames of an interlaced stream, eight bit, and each
    /// one's planes as `Deinterlacer` reads them: luma, Cb and Cr.
    private func movingFrames(width: Int, height: Int) throws -> (frames: [CVPixelBuffer], planes: [[[UInt8]]]) {
        func luma(_ frame: Int, _ x: Int, _ y: Int) -> Int { 20 + (x * 37 + y * 91 + (y % 2) * 60 + frame * 45) % 200 }
        func chroma(_ frame: Int, _ x: Int, _ y: Int) -> (cb: Int, cr: Int) {
            (40 + (x * 13 + y * 29 + frame * 17) % 170, 50 + (x * 7 + y * 41 + frame * 23) % 160)
        }
        let frames = try (0..<3).map { frame in
            try makePicture(
                width: width, height: height, tenBit: false, chromaAt: { chroma(frame, $0, $1) }, luma: { luma(frame, $0, $1) })
        }
        let chromaWidth = (width + 1) / 2, chromaHeight = (height + 1) / 2
        let planes = (0..<3).map { frame in
            [
                (0..<height).flatMap { y in (0..<width).map { UInt8(luma(frame, $0, y)) } },
                (0..<chromaHeight).flatMap { y in (0..<chromaWidth).map { UInt8(chroma(frame, $0, y).cb) } },
                (0..<chromaHeight).flatMap { y in (0..<chromaWidth).map { UInt8(chroma(frame, $0, y).cr) } },
            ]
        }
        return (frames, planes)
    }

    /// A field is built up on the GPU by the CPU deinterlacer's own rule,
    /// between the frames either side of it: every code of both planes
    /// lands where `Deinterlacer` puts it, and the picture leaves tagged as
    /// one field.
    func testAFieldIsBuiltUpAsTheCPUDeinterlacerBuildsIt() throws {
        let width = 64, height = 23
        let (frames, planes) = try movingFrames(width: width, height: height)
        let enhancer = try PictureEnhancer()
        for (field, second) in [(VideoField.top, false), (.bottom, true), (.bottom, false), (.top, true)] {
            var result: CVPixelBuffer?
            let landed = DispatchSemaphore(value: 0)
            try enhancer.enhance(frames[1], field: .field(field, second: second, previous: frames[0], next: frames[2])) {
                result = $0
                landed.signal()
            }
            landed.wait()
            let output = try XCTUnwrap(result)
            XCTAssertEqual(
                (CVBufferCopyAttachment(output, kCVImageBufferFieldCountKey, nil) as? NSNumber)?.intValue, 1)
            for plane in 0..<3 {
                let planeWidth = plane == 0 ? width : (width + 1) / 2
                let planeHeight = plane == 0 ? height : (height + 1) / 2
                var expected = [UInt8](repeating: 0, count: planeWidth * planeHeight)
                planes[0][plane].withUnsafeBufferPointer { before in
                    planes[1][plane].withUnsafeBufferPointer { current in
                        planes[2][plane].withUnsafeBufferPointer { after in
                            expected.withUnsafeMutableBufferPointer { destination in
                                Deinterlacer.deinterlacePlane(
                                    previous: PlaneRows(base: before.baseAddress!, stride: planeWidth),
                                    current: PlaneRows(base: current.baseAddress!, stride: planeWidth),
                                    next: PlaneRows(base: after.baseAddress!, stride: planeWidth),
                                    destination: destination.baseAddress!, destinationStride: planeWidth,
                                    widthBytes: planeWidth, height: planeHeight, field: field, second: second)
                            }
                        }
                    }
                }
                let stored = plane == 0
                    ? planeCodes(output, plane: 0) : planeCodes(output, plane: 1, components: 2, component: plane - 1)
                XCTAssertEqual(stored, expected.map { 4 * Int($0) }, "\(field) second \(second) plane \(plane)")
            }
        }
    }

    /// A film frame woven back: the field's rows from the frame, the others
    /// from the frame before, both planes, to the code.
    func testAFilmFrameIsWovenFromTheFrameBefore() throws {
        let width = 64, height = 24
        let (frames, planes) = try movingFrames(width: width, height: height)
        let enhancer = try PictureEnhancer()
        var result: CVPixelBuffer?
        let landed = DispatchSemaphore(value: 0)
        try enhancer.enhance(frames[1], field: .film(.bottom, previous: frames[0])) {
            result = $0
            landed.signal()
        }
        landed.wait()
        let output = try XCTUnwrap(result)
        let luma = planeCodes(output, plane: 0)
        let cr = planeCodes(output, plane: 1, components: 2, component: 1)
        for y in 0..<height {
            let source = planes[y % 2 == 1 ? 1 : 0][0]
            XCTAssertEqual(Array(luma[y * width..<(y + 1) * width]), source[y * width..<(y + 1) * width].map { 4 * Int($0) })
        }
        for y in 0..<height / 2 {
            let source = planes[y % 2 == 1 ? 1 : 0][2]
            XCTAssertEqual(
                Array(cr[y * width / 2..<(y + 1) * width / 2]),
                source[y * width / 2..<(y + 1) * width / 2].map { 4 * Int($0) })
        }
    }

    /// Black stays black.
    func testBlackStaysBlack() throws {
        let source = try makePicture(width: 64, height: 64, tenBit: false) { _, _ in 16 }
        let output = try enhanced(source)
        XCTAssertEqual(Set((0..<64).flatMap { lumaRow(output, y: $0) }), [64])
    }

    /// Every picture reports what its pass costs the GPU.
    func testEveryPictureIsTimedOnTheGPU() throws {
        let enhancer = try PictureEnhancer()
        let landed = DispatchSemaphore(value: 0)
        try enhancer.enhance(try makePicture(width: 32, height: 8, tenBit: false) { _, _ in 120 }) { _ in landed.signal() }
        landed.wait()
        XCTAssertEqual(enhancer.gpuTiming.current.passes, 1)
        XCTAssertGreaterThan(enhancer.gpuTiming.current.meanMilliseconds, 0)
    }

    /// The picture leaves with its own codes: an eight bit source at four
    /// times each, its steps and its texture alike, its chroma as it came.
    func testAPlainPictureLeavesWithItsOwnCodes() throws {
        func code(_ x: Int, _ y: Int) -> Int { 70 + x / 8 + (x * 7 + y * 13) % 5 }
        let source = try makePicture(width: 64, height: 32, tenBit: false, chroma: (100, 160), luma: code)
        let enhancer = try PictureEnhancer()
        var result: CVPixelBuffer?
        let landed = DispatchSemaphore(value: 0)
        try enhancer.enhance(source) { result = $0; landed.signal() }
        landed.wait()
        let output = try XCTUnwrap(result)
        for y in 0..<32 {
            XCTAssertEqual(lumaRow(output, y: y), (0..<64).map { 4 * code($0, y) }, "row \(y)")
        }
        XCTAssertEqual(columnMeans(output, plane: 1, components: 2, component: 0), Array(repeating: 400, count: 32))
        XCTAssertEqual(columnMeans(output, plane: 1, components: 2, component: 1), Array(repeating: 640, count: 32))
    }

    func testAFullRangeOrPackedPictureIsRefused() throws {
        var created: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 16, 8, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &created)
        XCTAssertThrowsError(try enhanced(try XCTUnwrap(created)))
    }
}

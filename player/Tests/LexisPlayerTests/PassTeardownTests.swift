import CoreVideo
import XCTest
@testable import LexisPlayer

/// Every pass owner torn down while its passes are still on the GPU.
final class PassTeardownTests: XCTestCase {
    /// A mapper let go with passes still in flight: each pass's wrappers are
    /// released after it, and the pictures they hold go back to a pool that
    /// has to still be there.
    func testAMapperLetGoWithPassesInFlightTakesItsPoolWithTheLastOfThem() throws {
        let parameters = ToneMapParameters(
            sourceMinPQ: 0, sourceMaxPQ: pqInverseEOTF(0.1), targetMinPQ: 0, targetMaxPQ: pqInverseEOTF(0.03))
        let source = try makeSource(codes: Array(repeating: 500, count: 64), rows: 64)
        let landed = DispatchGroup()
        for _ in 0..<400 {
            let mapper = try ToneMapper(pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
            for _ in 0..<3 {
                landed.enter()
                try mapper.map(source, parameters: parameters) { _ in landed.leave() }
            }
        }
        XCTAssertEqual(landed.wait(timeout: .now() + 60), .success)
    }

    func testAnEnhancerLetGoWithPassesInFlightTakesItsPoolWithTheLastOfThem() throws {
        let source = try makeSource(codes: Array(repeating: 500, count: 64), rows: 64)
        let landed = DispatchGroup()
        for _ in 0..<400 {
            let enhancer = try PictureEnhancer()
            for _ in 0..<3 {
                landed.enter()
                try enhancer.enhance(source) { _ in landed.leave() }
            }
        }
        XCTAssertEqual(landed.wait(timeout: .now() + 60), .success)
    }

    func testAnUpscalerLetGoWithPassesInFlightTakesItsPoolWithTheLastOfThem() throws {
        try skipUnlessUpscaler()
        let source = try makeSource(codes: Array(repeating: 500, count: 64), rows: 64)
        let landed = DispatchGroup()
        for _ in 0..<400 {
            let upscaler = try Upscaler(inputWidth: 64, inputHeight: 64, ceilingBytes: 1 << 24)
            for _ in 0..<3 {
                landed.enter()
                try upscaler.scale(source) { _ in landed.leave() }
            }
        }
        XCTAssertEqual(landed.wait(timeout: .now() + 60), .success)
    }
}

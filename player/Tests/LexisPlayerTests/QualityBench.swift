import CoreMedia
import CoreGraphics
import CoreVideo
import ImageIO
import Metal
import LexisTestSupport
import XCTest
@testable import LexisPlayer

/// What the scaler does to a picture, measured rather than looked at:
/// the upscale against the 4K picture its 1080p was made from, and the
/// finish past 2x. Prints a
/// report and asserts nothing; runs only under LEXIS_BENCH=1, and reads a
/// picture of its own from LEXIS_BENCH_IMAGE where one is given.
final class QualityBench: XCTestCase {
    private var enabled: Bool { ProcessInfo.processInfo.environment["LEXIS_BENCH"] == "1" }

    func testHDRUpscaleAgainstItsSource() throws {
        try XCTSkipUnless(enabled, "LEXIS_BENCH=1 runs the bench")
        let path = ProcessInfo.processInfo.environment["LEXIS_BENCH_IMAGE"]
            ?? "/System/Library/Desktop Pictures/Sonoma.heic"
        let width = 3840, height = 2160
        let reference = try luma(of: path, width: width, height: height)
        // the 1080p a 4K master is delivered as: each 2x2 block averaged, or
        // the one LEXIS_BENCH_SMALL names, raw ten bit grey, such as that
        // same picture through an encoder
        var small = [Float](repeating: 0, count: width * height / 4)
        if let given = ProcessInfo.processInfo.environment["LEXIS_BENCH_SMALL"] {
            let data = try Data(contentsOf: URL(fileURLWithPath: given))
            data.withUnsafeBytes { raw in
                for (index, code) in raw.bindMemory(to: UInt16.self).prefix(small.count).enumerated() {
                    small[index] = min(max((Float(code) - 64) / 876, 0), 1)
                }
            }
        } else {
            for y in 0..<height / 2 {
                for x in 0..<width / 2 {
                    let at = 2 * y * width + 2 * x
                    small[y * width / 2 + x] =
                        (reference[at] + reference[at + 1] + reference[at + width] + reference[at + width + 1]) / 4
                }
            }
        }
        var report = ["HDR upscale 1920x1080 to 3840x2160 of \((path as NSString).lastPathComponent)",
                      "scaler           PSNR dB   detail kept   GPU ms (mean)"]
        let bilinear = upsampledBilinear(small, width: width / 2, height: height / 2)
        report.append(line("bilinear", bilinear, reference, width: width, milliseconds: nil))
        report.append(line(
            "catmull-rom", upsampledSeparable(small, width: width / 2, height: height / 2, radius: 2) { x in
                let a = abs(x)
                return a < 1 ? 1.5 * a * a * a - 2.5 * a * a + 1 : a < 2 ? -0.5 * a * a * a + 2.5 * a * a - 4 * a + 2 : 0
            }, reference, width: width, milliseconds: nil))
        report.append(line(
            "lanczos3", upsampledSeparable(small, width: width / 2, height: height / 2, radius: 3) { x in
                x == 0 ? 1 : abs(x) >= 3 ? 0 : 3 * sin(.pi * x) * sin(.pi * x / 3) / (.pi * .pi * x * x)
            }, reference, width: width, milliseconds: nil))
        let source = try makePicture(
            width: width / 2, height: height / 2,
            luma: { x, y in Int((64 + 876 * small[y * width / 2 + x]).rounded()) }, chroma: { _, _ in (512, 512) })
        // LEXIS_BENCH_OUT set, each picture is written there as raw ten bit
        // grey for ffmpeg's perceptual metrics
        let out = ProcessInfo.processInfo.environment["LEXIS_BENCH_OUT"]
        func export(_ name: String, _ values: [Float]) throws {
            guard let out else { return }
            let codes = values.map { UInt16(max(0, min(1023, (64 + 876 * $0).rounded()))) }
            try codes.withUnsafeBytes { try Data($0).write(to: URL(fileURLWithPath: out).appendingPathComponent(name + ".gray10")) }
        }
        try export("reference", reference)
        try export("small", small)
        try export("bilinear", bilinear)
        do {
            let upscaler: Upscaler
            do {
                upscaler = try Upscaler(
                    inputWidth: width / 2, inputHeight: height / 2, ceilingBytes: 512 * 1024 * 1024)
            } catch UpscaleError.noDevice {
                throw XCTSkip("no Metal device")
            }
            var scaled: CVPixelBuffer?
            // the first passes build the scaler's own state; the timing is a mean
            for _ in 0..<12 {
                let landed = DispatchSemaphore(value: 0)
                try upscaler.scale(source) { scaled = $0; landed.signal() }
                landed.wait()
            }
            let values = try lumaValues(of: XCTUnwrap(scaled))
            try export("hdr-upscale", values)
            report.append(line("hdr upscale", values, reference, width: width,
                               milliseconds: upscaler.gpuTiming.current.meanMilliseconds))
        }
        print(report.joined(separator: "\n"))
    }

    /// The factor past Prisme's 2x, which a 720p or SD film needs to fill
    /// the screen: each `<name>-small-WxH.yuv` in LEXIS_BENCH_FRAMES doubled
    /// by the filters, then finished to the size of its `<name>-ref-WxH.yuv`
    /// by bilinear, standing in for a compositor whose filter is unknown, and
    /// by the sharper kernels, against that reference: PSNR on the luma and
    /// the share of its detail kept.
    func testFinishingTheScale() throws {
        try XCTSkipUnless(enabled, "LEXIS_BENCH=1 runs the bench")
        let frames = try XCTUnwrap(ProcessInfo.processInfo.environment["LEXIS_BENCH_FRAMES"])
        func size(_ name: String) -> (Int, Int) {
            let wh = name.dropLast(4).split(separator: "-").last!.split(separator: "x").map { Int($0)! }
            return (wh[0], wh[1])
        }
        func luma(_ name: String) throws -> [Float] {
            let (width, height) = size(name)
            let data = try Data(contentsOf: URL(fileURLWithPath: frames).appendingPathComponent(name))
            return data.withUnsafeBytes { raw in
                raw.bindMemory(to: UInt16.self).prefix(width * height).map { (Float($0) - 64) / 876 }
            }
        }
        let catmullRom: (Float) -> Float = { x in
            let a = abs(x)
            return a < 1 ? 1.5 * a * a * a - 2.5 * a * a + 1 : a < 2 ? -0.5 * a * a * a + 2.5 * a * a - 4 * a + 2 : 0
        }
        let lanczos3: (Float) -> Float = { x in
            x == 0 ? 1 : abs(x) >= 3 ? 0 : 3 * sin(.pi * x) * sin(.pi * x / 3) / (.pi * .pi * x * x)
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: frames).filter { $0.contains("-small-") }.sorted()
        var report = ["finishing past 2x, against the reference", "picture                  finish            PSNR dB   detail kept"]
        for name in names {
            let (width, height) = size(name)
            let referenceName = try XCTUnwrap(
                try FileManager.default.contentsOfDirectory(atPath: frames).first {
                    $0.hasPrefix(name.components(separatedBy: "-small-")[0] + "-ref-")
                })
            let (outWidth, outHeight) = size(referenceName)
            let reference = try luma(referenceName)
            let small = try luma(name)
            let upscaler: Upscaler
            do {
                upscaler = try Upscaler(inputWidth: width, inputHeight: height, ceilingBytes: 512 * 1024 * 1024)
            } catch UpscaleError.noDevice {
                throw XCTSkip("no Metal device")
            }
            let doubled = try lumaValues(of: upscaler.scaled(try makePicture(
                width: width, height: height,
                luma: { x, y in Int((64 + 876 * small[y * width + x]).rounded()) }, chroma: { _, _ in (512, 512) })))
            let label = name.components(separatedBy: "-small-")[0] + " \(height) to \(outHeight)"
            // LEXIS_BENCH_OUT set, each picture is written there as raw ten bit
            // grey for ffmpeg's perceptual metrics
            func export(_ suffix: String, _ values: [Float]) throws {
                guard let out = ProcessInfo.processInfo.environment["LEXIS_BENCH_OUT"] else { return }
                let codes = values.map { UInt16(max(0, min(1023, (64 + 876 * $0).rounded()))) }
                let file = name.components(separatedBy: "-small-")[0] + "." + suffix.replacingOccurrences(of: " ", with: "_")
                try codes.withUnsafeBytes {
                    try Data($0).write(to: URL(fileURLWithPath: out).appendingPathComponent(file + "-\(outWidth)x\(outHeight).gray10"))
                }
            }
            try export("reference", reference)
            func add(_ finish: String, _ values: [Float]) throws {
                try export(finish, values)
                report.append(label.padding(toLength: 25, withPad: " ", startingAt: 0)
                    + line(finish, values, reference, width: outWidth, milliseconds: nil).dropLast(9))
            }
            try add("bilinear alone", resampled(small, width, height, outWidth, outHeight, radius: 1) { max(0, 1 - abs($0)) })
            try add("2x, bilinear", resampled(doubled, 2 * width, 2 * height, outWidth, outHeight, radius: 1) { max(0, 1 - abs($0)) })
            try add("2x, catmull-rom", resampled(doubled, 2 * width, 2 * height, outWidth, outHeight, radius: 2, kernel: catmullRom))
            try add("2x, cr antiring", resampled(
                doubled, 2 * width, 2 * height, outWidth, outHeight, radius: 2, antiRing: true, kernel: catmullRom))
            try add("2x, lanczos3", resampled(doubled, 2 * width, 2 * height, outWidth, outHeight, radius: 3, kernel: lanczos3))
            try add("2x, l3 antiring", resampled(
                doubled, 2 * width, 2 * height, outWidth, outHeight, radius: 3, antiRing: true, kernel: lanczos3))
            // the scaler's own finish, on the GPU
            let finishing = try Upscaler(
                inputWidth: width, inputHeight: height, ceilingBytes: 512 * 1024 * 1024,
                outputSize: (outWidth, outHeight))
            try add("prisme finish", lumaValues(of: finishing.scaled(try makePicture(
                width: width, height: height,
                luma: { x, y in Int((64 + 876 * small[y * width + x]).rounded()) }, chroma: { _, _ in (512, 512) }))))
        }
        print(report.joined(separator: "\n"))
    }

    /// A separable resample to any larger size, centres aligned, taps
    /// normalized to one; `antiRing` holds each pixel within the 2x2 source
    /// pixels around it.
    private func resampled(
        _ input: [Float], _ width: Int, _ height: Int, _ outWidth: Int, _ outHeight: Int, radius: Int,
        antiRing: Bool = false, kernel: (Float) -> Float
    ) -> [Float] {
        func axis(_ inSize: Int, _ outSize: Int) -> [(first: Int, weights: [Float])] {
            (0..<outSize).map { o in
                let at = (Float(o) + 0.5) * Float(inSize) / Float(outSize) - 0.5
                let first = Int(at.rounded(.down)) - radius + 1
                let weights = (0..<2 * radius).map { kernel(at - Float(first + $0)) }
                let sum = weights.reduce(0, +)
                return (first, weights.map { $0 / sum })
            }
        }
        let columns = axis(width, outWidth), rows = axis(height, outHeight)
        var across = [Float](repeating: 0, count: outWidth * height)
        for y in 0..<height {
            for x in 0..<outWidth {
                var sum: Float = 0
                for (k, weight) in columns[x].weights.enumerated() {
                    sum += weight * input[y * width + min(max(columns[x].first + k, 0), width - 1)]
                }
                across[y * outWidth + x] = sum
            }
        }
        var out = [Float](repeating: 0, count: outWidth * outHeight)
        for y in 0..<outHeight {
            for x in 0..<outWidth {
                var sum: Float = 0
                for (k, weight) in rows[y].weights.enumerated() {
                    sum += weight * across[min(max(rows[y].first + k, 0), height - 1) * outWidth + x]
                }
                if antiRing {
                    let x0 = min(max(columns[x].first + radius - 1, 0), width - 1), x1 = min(x0 + 1, width - 1)
                    let y0 = min(max(rows[y].first + radius - 1, 0), height - 1), y1 = min(y0 + 1, height - 1)
                    let around = [input[y0 * width + x0], input[y0 * width + x1], input[y1 * width + x0], input[y1 * width + x1]]
                    sum = min(max(sum, around.min()!), around.max()!)
                }
                out[y * outWidth + x] = sum
            }
        }
        return out
    }

    /// The luma of an eight or ten bit video range picture, zero to one.
    private func lumaValues(of buffer: CVPixelBuffer) throws -> [Float] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let eightBit = CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        var values = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                values[y * width + x] = eightBit
                    ? (Float(base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)[x]) - 16) / 219
                    : (Float(base.advanced(by: y * stride).assumingMemoryBound(to: UInt16.self)[x] >> 6) - 64) / 876
            }
        }
        return values
    }

    /// PSNR over the luma, and the share of the reference's gradient energy
    /// the picture has: under 100% is softer than the source, over it is
    /// sharper than the source ever was, which is ringing or noise.
    private func line(_ name: String, _ values: [Float], _ reference: [Float], width: Int, milliseconds: Double?) -> String {
        var error: Double = 0, energy: Double = 0, referenceEnergy: Double = 0
        for index in 0..<(values.count - width - 1) {
            let difference = Double(values[index] - reference[index])
            error += difference * difference
            let gx = values[index + 1] - values[index], gy = values[index + width] - values[index]
            let rx = reference[index + 1] - reference[index], ry = reference[index + width] - reference[index]
            energy += Double(gx * gx + gy * gy)
            referenceEnergy += Double(rx * rx + ry * ry)
        }
        let psnr = 10 * log10(1 / max(error / Double(values.count), 1e-12))
        let time = milliseconds.map { String(format: "%8.2f", $0) } ?? "       -"
        return name.padding(toLength: 17, withPad: " ", startingAt: 0)
            + String(format: "%7.2f %12.0f%% ", psnr, 100 * energy / max(referenceEnergy, 1e-12)) + time
    }

    /// The image's luma at the size asked, zero to one.
    private func luma(of path: String, width: Int, height: Int) throws -> [Float] {
        let url = URL(fileURLWithPath: path)
        let image = try XCTUnwrap(
            CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) },
            "no picture at \(path)")
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.interpolationQuality = .high
        // filled and centred, never squeezed
        let scale = max(Double(width) / Double(image.width), Double(height) / Double(image.height))
        let drawn = CGSize(width: Double(image.width) * scale, height: Double(image.height) * scale)
        context.draw(image, in: CGRect(
            x: (Double(width) - drawn.width) / 2, y: (Double(height) - drawn.height) / 2,
            width: drawn.width, height: drawn.height))
        return (0..<width * height).map { index in
            (0.2627 * Float(bytes[index * 4]) + 0.6780 * Float(bytes[index * 4 + 1])
                + 0.0593 * Float(bytes[index * 4 + 2])) / 255
        }
    }

    private func upsampledBilinear(_ small: [Float], width: Int, height: Int, factor: Float = 2) -> [Float] {
        let outWidth = Int(Float(width) * factor), outHeight = Int(Float(height) * factor)
        var out = [Float](repeating: 0, count: outWidth * outHeight)
        for y in 0..<outHeight {
            let sy = max(0, min(Float(height - 1), (Float(y) + 0.5) / factor - 0.5))
            let y0 = Int(sy), y1 = min(y0 + 1, height - 1), fy = sy - Float(y0)
            for x in 0..<outWidth {
                let sx = max(0, min(Float(width - 1), (Float(x) + 0.5) / factor - 0.5))
                let x0 = Int(sx), x1 = min(x0 + 1, width - 1), fx = sx - Float(x0)
                let top = small[y0 * width + x0] * (1 - fx) + small[y0 * width + x1] * fx
                let bottom = small[y1 * width + x0] * (1 - fx) + small[y1 * width + x1] * fx
                out[y * outWidth + x] = top * (1 - fy) + bottom * fy
            }
        }
        return out
    }

    /// A 2x separable resample with the given kernel, rows then columns,
    /// taps normalized to one.
    private func upsampledSeparable(
        _ small: [Float], width: Int, height: Int, radius: Int, kernel: (Float) -> Float
    ) -> [Float] {
        // at 2x only two phases exist: a quarter and three quarters of a pixel
        func taps(_ phase: Float) -> [Float] {
            let weights = (-radius + 1...radius).map { kernel(Float($0) - phase) }
            let sum = weights.reduce(0, +)
            return weights.map { $0 / sum }
        }
        let phases = [taps(0.75), taps(0.25)]
        func pass(_ input: [Float], _ w: Int, _ h: Int, horizontal: Bool) -> [Float] {
            let outW = horizontal ? w * 2 : w, outH = horizontal ? h : h * 2
            var out = [Float](repeating: 0, count: outW * outH)
            for y in 0..<outH {
                for x in 0..<outW {
                    let o = horizontal ? x : y
                    let centre = o % 2 == 0 ? (o / 2) - 1 : o / 2
                    let weights = phases[o % 2]
                    var sum: Float = 0
                    for (k, weight) in weights.enumerated() {
                        let i = min(max(centre - radius + 1 + k, 0), (horizontal ? w : h) - 1)
                        sum += weight * (horizontal ? input[y * w + i] : input[i * w + x])
                    }
                    out[y * outW + x] = sum
                }
            }
            return out
        }
        return pass(pass(small, width, height, horizontal: true), width * 2, height, horizontal: false)
    }
}

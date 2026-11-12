import CoreMedia
import CoreVideo
import Foundation
import XCTest
@testable import LexisPlayer

/// An interlaced file through the path its codec takes, every picture
/// written out to be measured against the progressive frames it was made
/// from: MPEG-2 through the software decoder, H.264 through VideoToolbox and
/// the enhancer's field builder. Runs only under LEXIS_BENCH=1, on the file
/// LEXIS_BENCH_INTERLACED names; LEXIS_BENCH_OUT receives `pictures.yuv`,
/// eight bit planar 4:2:0 pictures back to back, and `times.txt`, each
/// picture's time in seconds.
final class InterlacedBench: XCTestCase {
    func testInterlacedFileToPictures() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["LEXIS_BENCH"] == "1", "LEXIS_BENCH=1 runs the bench")
        let file = try XCTUnwrap(environment["LEXIS_BENCH_INTERLACED"])
        let out = URL(fileURLWithPath: try XCTUnwrap(environment["LEXIS_BENCH_OUT"]))
        let demuxer = try Demuxer(url: URL(fileURLWithPath: file))
        let stream = try XCTUnwrap(demuxer.streams.first { $0.kind == .video })
        var pictures: [(time: Double, picture: CVPixelBuffer)] = []
        let lock = NSLock()
        let started = Date()
        if stream.codecName == "mpeg2video" {
            let decoder = try SoftwareVideoDecoder(stream: stream, threadCount: 2, poolCeilingBytes: 1 << 30)
            func take(_ samples: [CMSampleBuffer]) {
                for sample in samples {
                    pictures.append((
                        CMSampleBufferGetPresentationTimeStamp(sample).seconds, CMSampleBufferGetImageBuffer(sample)!))
                }
            }
            while let packet = try demuxer.readPacket() {
                guard packet.streamIndex == stream.index else { continue }
                take(try decoder.decode(packet))
            }
            take(try decoder.drainAtEndOfStream())
        } else {
            let format = try makeFormatDescription(for: stream)
            let path = try ToneMappedVideo(
                enhancing: format, sourceBitDepth: stream.bitDepth, videoDelay: stream.videoDelay,
                budgetBytes: 1 << 28, fields: FieldOrder(of: stream)
            ) { sample in
                lock.lock()
                pictures.append((
                    CMSampleBufferGetPresentationTimeStamp(sample).seconds, CMSampleBufferGetImageBuffer(sample)!))
                lock.unlock()
            }
            while let packet = try demuxer.readPacket() {
                guard packet.streamIndex == stream.index else { continue }
                try path.decode(
                    try makeSampleBuffer(
                        packet: packet, formatDescription: format,
                        timeBaseNum: stream.timeBaseNum, timeBaseDen: stream.timeBaseDen),
                    rpu: nil)
            }
            path.drain()
        }
        let elapsed = Date().timeIntervalSince(started)
        var bytes = Data()
        for (_, picture) in pictures {
            CVPixelBufferLockBaseAddress(picture, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(picture, .readOnly) }
            let width = CVPixelBufferGetWidth(picture), height = CVPixelBufferGetHeight(picture)
            let format = CVPixelBufferGetPixelFormatType(picture)
            let deep = format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            func sample(_ plane: Int, _ x: Int, _ y: Int, _ component: Int) -> UInt8 {
                let base = CVPixelBufferGetBaseAddressOfPlane(picture, plane)!
                let stride = CVPixelBufferGetBytesPerRowOfPlane(picture, plane)
                if deep {
                    let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt16.self)
                    return UInt8(row[plane == 0 ? x : 2 * x + component] >> 8)
                }
                let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
                // planar: Cb and Cr each a plane of their own
                return row[x]
            }
            for y in 0..<height { for x in 0..<width { bytes.append(sample(0, x, y, 0)) } }
            for component in 0..<2 {
                for y in 0..<height / 2 {
                    for x in 0..<width / 2 { bytes.append(deep ? sample(1, x, y, component) : sample(1 + component, x, y, 0)) }
                }
            }
        }
        try bytes.write(to: out.appendingPathComponent("pictures.yuv"))
        try pictures.map { String(format: "%.6f", $0.time) }.joined(separator: "\n")
            .write(to: out.appendingPathComponent("times.txt"), atomically: true, encoding: .utf8)
        print(String(format: "interlaced bench: %d pictures, %.1f ms", pictures.count, elapsed * 1000))
    }
}

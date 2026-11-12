import AVFoundation
import CoreText
import LexisCoreStream
import XCTest
@testable import LexisPlayer

final class CreditsDetectorTests: XCTestCase {
    /// A minute at 2 fps, a keyframe every second: forty seconds of a bright
    /// scene under a burnt-in subtitle, then twenty of a roll on black.
    private static let creditsAt = 40.0
    private static let fps: Int32 = 2

    private func fixture(credits: Bool) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("credits-\(credits)-\(UUID().uuidString).mp4")
        let width = 1280, height = 720
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoMaxKeyFrameIntervalKey: Int(Self.fps), AVVideoAllowFrameReorderingKey: false,
                ],
            ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<(60 * Int(Self.fps)) {
            let second = Double(frame) / Double(Self.fps)
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
            let pixels = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            let context = try XCTUnwrap(
                CGContext(
                    data: CVPixelBufferGetBaseAddress(pixels), width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: CVPixelBufferGetBytesPerRow(pixels), space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
                ))
            if credits, second >= Self.creditsAt {
                context.setFillColor(gray: 0, alpha: 1)
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                let names = ["Directed by Ada Marsh", "Written by Paul Verne", "Music by Lena Ortiz",
                    "Edited by Sam Kowalski", "Produced by Iris Holm", "Camera Tom Reyes"]
                for (row, name) in names.enumerated() {
                    draw(name, in: context, at: CGPoint(x: 460, y: 560 - row * 70 + Int(second - Self.creditsAt) * 6))
                }
            } else {
                let shade = 0.45 + 0.4 * sin(second / 3)
                context.setFillColor(red: shade, green: 0.6, blue: 1 - shade, alpha: 1)
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                draw("I told you we would never come back here.", in: context, at: CGPoint(x: 340, y: 60))
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
            XCTAssertTrue(adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(frame), timescale: Self.fps)))
        }
        input.markAsFinished()
        let finished = expectation(description: "written")
        writer.finishWriting { finished.fulfill() }
        wait(for: [finished], timeout: 60)
        XCTAssertEqual(writer.status, .completed, String(describing: writer.error))
        return url
    }

    private func draw(_ text: String, in context: CGContext, at point: CGPoint) {
        let font = CTFontCreateWithName("Helvetica" as CFString, 40, nil)
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
            ]))
        context.textPosition = point
        CTLineDraw(line, context)
    }

    private func detector(_ url: URL) throws -> CreditsDetector {
        let handle = try XCTUnwrap(lexis_stream_open_file(url.path, nil))
        return try CreditsDetector(stream: coreStream(handle: handle), analysis: nil)
    }

    func testTheRollIsFoundWhereItStartsAndTheSubtitlesAreNot() async throws {
        let url = try fixture(credits: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let start = try await detector(url).start(within: 0...59)
        let found = try XCTUnwrap(start)
        XCTAssertEqual(found, Self.creditsAt, accuracy: 1.5)
    }

    func testAFileWithoutCreditsHasNone() async throws {
        let url = try fixture(credits: false)
        defer { try? FileManager.default.removeItem(at: url) }
        let start = try await detector(url).start(within: 0...59)
        XCTAssertNil(start)
    }
}

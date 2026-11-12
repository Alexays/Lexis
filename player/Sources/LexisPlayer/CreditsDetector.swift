import CoreGraphics
import Foundation
import Vision

/// Finds where a file's end credits begin from its own pictures, for a file
/// nothing has timed: keyframes of its last stretch read by Vision's text
/// recognizer, which runs on the Neural Engine.
///
/// Its own stream and strip decoder, so a scrub never drops one of its
/// frames, and one picture held at a time.
public final class CreditsDetector: @unchecked Sendable {
    /// Tall enough for the small lines of a roll to still read as text.
    private static let height = 540
    private let strip: ThumbnailStripDecoder

    /// Probes the stream, which is network I/O for a remote source.
    public init(stream: MediaStreamIO, analysis: MediaAnalysis?) throws {
        strip = try ThumbnailStripDecoder(stream: stream, analysis: analysis, height: CreditsDetector.height)
    }

    /// Holds the reads between two pictures while the film next door rebuffers.
    public func setSuspended(_ value: Bool) { strip.setSuspended(value) }

    /// Stops at the next picture; `start(within:)` then answers nil.
    public func cancel() { strip.cancel() }

    /// The second the credits start within `window`, nil when it holds none.
    /// A coarse pass finds the first stretch of credit pictures, a fine one
    /// the picture before it where they begin.
    public func start(within window: ClosedRange<Double>) async -> Double? {
        let coarse = max((window.upperBound - window.lowerBound) / 45, 1)
        let seconds = Array(stride(from: window.lowerBound, through: window.upperBound, by: coarse))
        var credits: [Bool] = []
        credits.reserveCapacity(seconds.count)
        for second in seconds {
            guard let found = await isCredits(at: second) else { return nil }
            credits.append(found)
        }
        // two credit pictures of three: one sign in a dark scene is not a roll,
        // and a roll over a scene can miss one
        guard let first = credits.indices.first(where: { index in
            credits[index] && credits[(index + 1)..<min(index + 3, credits.count)].contains(true)
        }) else { return nil }
        guard first > 0 else { return seconds[0] }
        let fine = max(coarse / 8, 1)
        for second in stride(from: seconds[first - 1] + fine, to: seconds[first], by: fine) {
            guard let found = await isCredits(at: second) else { return nil }
            if found { return second }
        }
        return seconds[first]
    }

    /// Nil once cancelled. A burnt-in subtitle sits in the bottom band, so
    /// only words above it count: three lines are a roll, one over a dark
    /// picture is a card.
    private func isCredits(at second: Double) async -> Bool? {
        let image = await withCheckedContinuation { (done: CheckedContinuation<CGImage?, Never>) in
            strip.strip(at: [second]) { done.resume(returning: $0[second]) }
        }
        guard !Task.isCancelled else { return nil }
        guard let image else { return false }
        var request = RecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        guard let lines = try? await request.perform(on: image) else { return false }
        let raised = lines.count { $0.boundingBox.cgRect.midY > 0.25 }
        return raised >= 3 || (raised >= 1 && CreditsDetector.isDark(image))
    }

    private static func isDark(_ image: CGImage) -> Bool {
        let width = 16, height = 9
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn && pixels.reduce(0) { $0 + Int($1) } < width * height * 30
    }
}

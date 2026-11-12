import LexisCore
import SwiftUI
import UIKit

/// The colour a screen borrows from the picture on it.
@MainActor @Observable
final class ToneSlot {
    fileprivate(set) var color: Color?
}

/// One tone per title, averaged from its poster and held for the session.
///
/// The average is taken from a thumbnail of a couple of dozen pixels, which
/// is both cheap and better than a larger one: at that size a poster is
/// already its own palette, and the letters and the black bars have stopped
/// counting.
@MainActor
final class Tone {
    static let shared = Tone()

    private var slots: [Int64: ToneSlot] = [:]
    private var asked: Set<Int64> = []

    func slot(_ titleId: Int64) -> ToneSlot {
        if let slot = slots[titleId] { return slot }
        let slot = ToneSlot()
        slots[titleId] = slot
        ask(titleId, slot)
        return slot
    }

    private func ask(_ titleId: Int64, _ slot: ToneSlot) {
        guard asked.insert(titleId).inserted else { return }
        Task {
            // Never the blocking fetch: a poster not cached yet is asked for
            // again the next time the title is shown.
            let (state, color) = await CoreClient.run(on: CoreClient.slow) { () -> (ArtworkState, Color?) in
                let state = CoreClient.shared.posterNow(titleId: titleId)
                guard case .ready(let path) = state else { return (state, nil) }
                return (state, Artwork.decode(path, maxPixels: Tone.sample).flatMap(Tone.average))
            }
            guard case .ready = state else {
                if case .missing = state { return }
                slots[titleId] = nil
                asked.remove(titleId)
                return
            }
            if let color { slot.color = color }
        }
    }

    nonisolated private static let sample = 24

    /// The mean of the thumbnail, then bent into the band a backdrop can
    /// carry: too grey and every screen looks the same, too bright and the
    /// words on top stop being readable.
    private static let floorSaturation = 0.34
    private static let ceilingSaturation = 0.72
    private static let floorBrightness = 0.20
    private static let ceilingBrightness = 0.44

    nonisolated static func average(_ image: CGImage) -> Color? {
        var pixel: [UInt8] = [0, 0, 0, 0]
        guard
            let context = CGContext(
                data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))

        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        let mean = UIColor(
            red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255,
            blue: CGFloat(pixel[2]) / 255, alpha: 1)
        guard mean.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        else { return nil }
        return Color(
            hue: hue,
            saturation: min(max(saturation, floorSaturation), ceilingSaturation),
            brightness: min(max(brightness, floorBrightness), ceilingBrightness))
    }
}

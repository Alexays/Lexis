import SwiftUI
import UIKit

/// Achromatic noise, tiled over the whole screen in `overlay`.
///
/// It is not decoration. A screen made almost entirely of dark gradients
/// bands visibly on an eight-bit panel, and a per-pixel dither is the only
/// thing that breaks the steps. It costs one tiled draw.
struct Grain: View {
    var body: some View {
        Image(decorative: Grain.tile, scale: 1)
            .resizable(resizingMode: .tile)
            .blendMode(.overlay)
            .opacity(Theme.Depth.grain)
            .allowsHitTesting(false)
    }
}

extension Grain {
    private static let side = 128

    /// Grey noise, built once. Achromatic on purpose: coloured noise tints
    /// the flats it is laid over, and the flats here are the whole screen.
    fileprivate static let tile: CGImage = {
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        var seed: UInt64 = 0x2545_F491_4F6C_DD1D
        for pixel in 0..<(side * side) {
            seed ^= seed << 13
            seed ^= seed >> 7
            seed ^= seed << 17
            let grey = UInt8(truncatingIfNeeded: seed >> 33)
            let at = pixel * 4
            bytes[at] = grey
            bytes[at + 1] = grey
            bytes[at + 2] = grey
            bytes[at + 3] = 255
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(
            width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }()
}

/// What sits behind a whole screen: the title's own picture, two halos in
/// the colour averaged from its poster, the scrim, and the grain.
///
/// The halos are what keep two screens from looking alike when the grid
/// under them never moves. They are drawn even before the picture lands, so
/// the screen is already the right colour while it loads.
struct Backdrop: View {
    /// Nil before the remote has landed anywhere: the screen is then its
    /// own colour, and nothing is fetched.
    let titleId: Int64?
    /// False where the picture would fight the words: a list of rows wants
    /// the colour without the photograph.
    var picture = true

    var body: some View {
        let tone: Color = titleId.flatMap { Tone.shared.slot($0).color } ?? Theme.Colors.bg1

        ZStack {
            Theme.Colors.bg0

            // only the halos and the photograph change from one title to the
            // next, so they are the only ones that cross-fade: the scrim and
            // the grain are the same on every screen, and animating them
            // re-composites a full-screen overlay blend for nothing
            ZStack {
                RadialGradient(
                    colors: [tone.opacity(0.55), tone.opacity(0)], center: .init(x: 0.66, y: 0.3),
                    startRadius: 0, endRadius: Theme.Layout.screenWidth * 0.62)
                RadialGradient(
                    colors: [tone.opacity(0.3), tone.opacity(0)], center: .init(x: 0.14, y: 0.78),
                    startRadius: 0, endRadius: Theme.Layout.screenWidth * 0.4)

                // one view per title rather than one whose image is swapped:
                // the outgoing picture fades out under the incoming one
                // instead of being replaced in a single frame
                if picture, let titleId {
                    // no poster in the meantime: stretched over the screen it is
                    // another picture, and the backdrop then lands on top of it
                    ArtworkImage(kind: .backdrop(titleId: titleId)) { Color.clear }
                    .frame(width: Theme.Layout.screenWidth, height: Theme.Layout.screenHeight)
                    .clipped()
                    .opacity(0.86)
                    .id(titleId)
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: Theme.Motion.backdrop), value: titleId)

            Scrim(direction: .backdrop)
            Grain()
        }
        .frame(width: Theme.Layout.screenWidth, height: Theme.Layout.screenHeight)
        .clipped()
    }
}

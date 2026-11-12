import SwiftUI

/// The gradient every scrim in the app is: the canvas colour at a tuned
/// opacity, dark toward the bottom or toward the left, drawn with sixty
/// stops so no band shows on a large screen.
struct Scrim: View {
    enum Direction { case vertical, horizontal, backdrop, hero }
    let direction: Direction

    private static let vertical: [Double] = [0, 0.02, 0.06, 0.12, 0.2, 0.32, 0.46, 0.62, 0.8, 0.94]
    private static let horizontal: [Double] = [0.97, 0.96, 0.94, 0.92, 0.88, 0.62, 0.4, 0.22, 0.08, 0]
    /// A picture held behind a whole screen, not a veil at the foot of a
    /// card: the top half is left alone and the darkening is spent in the
    /// last third. A ramp that starts at the top turns a backdrop into an
    /// enlarged thumbnail.
    private static let backdrop: [Double] = [0, 0, 0, 0, 0, 0.03, 0.28, 0.47, 0.65, 0.86]
    /// The home's words sit on the left of a picture that is otherwise left
    /// whole: a lighter version of the detail's ramp, spent under the column
    /// of text and gone by the middle of the screen.
    private static let hero: [Double] = [0.78, 0.7, 0.58, 0.42, 0.26, 0.12, 0.04, 0, 0, 0]
    private static let steps = 60

    /// Each control point held over six steps, then every step averaged
    /// with its two neighbours either side: a ramp without a seam.
    static func resampled(_ curve: [Double]) -> [Double] {
        let held = (0..<steps).map { curve[min(curve.count - 1, $0 * curve.count / steps)] }
        return (0..<steps).map { index in
            let low = max(0, index - 2), high = min(steps - 1, index + 2)
            return held[low...high].reduce(0, +) / Double(high - low + 1)
        }
    }

    private static let verticalStops = resampled(vertical).enumerated().map { index, alpha in
        Gradient.Stop(color: Theme.Colors.bg0.opacity(alpha), location: Double(index) / Double(steps - 1))
    }
    private static let horizontalStops = resampled(horizontal).enumerated().map { index, alpha in
        Gradient.Stop(color: Theme.Colors.bg0.opacity(alpha), location: Double(index) / Double(steps - 1))
    }
    private static let backdropStops = resampled(backdrop).enumerated().map { index, alpha in
        Gradient.Stop(color: Theme.Colors.bg0.opacity(alpha), location: Double(index) / Double(steps - 1))
    }

    private static let heroStops = resampled(hero).enumerated().map { index, alpha in
        Gradient.Stop(color: Theme.Colors.bg0.opacity(alpha), location: Double(index) / Double(steps - 1))
    }

    var body: some View {
        switch direction {
        case .vertical:
            LinearGradient(stops: Scrim.verticalStops, startPoint: .top, endPoint: .bottom)
        case .horizontal:
            LinearGradient(stops: Scrim.horizontalStops, startPoint: .leading, endPoint: .trailing)
        case .backdrop:
            LinearGradient(stops: Scrim.backdropStops, startPoint: .top, endPoint: .bottom)
        case .hero:
            LinearGradient(stops: Scrim.heroStops, startPoint: .leading, endPoint: .trailing)
        }
    }
}

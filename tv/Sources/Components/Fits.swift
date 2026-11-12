import SwiftUI

extension View {
    /// Sets text on the lines it is given, shrinking it rather than cutting
    /// it. Never an ellipsis: a title the viewer cannot read whole is a title
    /// they cannot choose, and on a shelf of two hundred names the truncated
    /// ones are exactly the long, distinctive ones worth reading.
    ///
    /// The floor is what keeps the shrink honest. Past it the text would be
    /// smaller than this app's smallest readable size at three metres, so the
    /// line wraps to the next one instead. `size` is the font's own size:
    /// a line already at the floor does not shrink at all.
    func fits(_ lines: Int = 1, size: CGFloat = Theme.Typography.captionSize) -> some View {
        lineLimit(lines).minimumScaleFactor(min(1, Theme.Typography.shrinkFloor / size))
    }
}

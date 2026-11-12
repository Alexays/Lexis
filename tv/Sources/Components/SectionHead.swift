import SwiftUI

/// A screen's own name, in the display face, with a figure to its right and
/// a rule under both. It is what makes a screen read as a page rather than
/// as a panel, and it costs one line.
struct SectionHead: View {
    let title: String
    var trailing = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s16) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(Theme.Typography.display)
                    .tracking(Theme.Typography.displayTracking)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.Colors.white)
                    .fits(1)
                Spacer(minLength: Theme.Space.s24)
                if !trailing.isEmpty {
                    Text(trailing)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textMuted)
                        .fits(1)
                }
            }
            Rectangle()
                .fill(Theme.Colors.hairline)
                .frame(height: 1)
        }
        .padding(.horizontal, Theme.Layout.gutter)
    }
}

/// A row's name, and the precision it leaves out in grey beside it. One look
/// for every row of titles or people in the app.
struct RowHeading: View {
    let title: String
    var subtitle = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s16) {
            Text(title)
                .font(Theme.Typography.rowTitle)
                .foregroundStyle(Theme.Colors.text)
                .layoutPriority(1)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textMuted)
            }
        }
        .fits(1, size: Theme.Typography.bodySize)
        .headingOverPicture()
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

extension View {
    /// A heading laid straight on a title's own photograph.
    ///
    /// The backdrop's scrim spends its darkening at the foot of the screen,
    /// so a row scrolled to the top sits on the picture undimmed, and a
    /// bright frame swallows the word. A halo of the canvas colour under the
    /// letters is what makes the heading hold on any picture: it disappears
    /// against the near-black the screen usually is, and carries the word
    /// where the picture is white.
    func headingOverPicture() -> some View {
        shadow(color: Theme.Colors.bg0.opacity(0.9), radius: 4)
            .shadow(color: Theme.Colors.bg0.opacity(0.65), radius: 16, y: 3)
    }
}

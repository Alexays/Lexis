import SwiftUI

/// Where rails of posters will stand while their titles load. Never
/// focusable: the remote must not land on something that is about to go.
struct PlaceholderRails: View {
    var rows = 2

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s40) {
            ForEach(0..<rows, id: \.self) { _ in
                VStack(alignment: .leading, spacing: Theme.Space.s24) {
                    Capsule()
                        .fill(Theme.Colors.bg2)
                        .frame(width: 280, height: 20)
                    HStack(spacing: Theme.Poster.gap) {
                        ForEach(0..<6, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: Theme.Radius.poster, style: .continuous)
                                .fill(Theme.Colors.bg1)
                                .frame(width: Theme.Poster.width, height: Theme.Poster.height)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, Theme.Layout.gutter)
        .frame(width: Theme.Layout.screenWidth, alignment: .leading)
        .clipped()
        .accessibilityElement()
        .accessibilityLabel(t("library.loading"))
    }
}

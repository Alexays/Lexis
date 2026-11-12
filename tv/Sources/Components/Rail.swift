import LexisCore
import SwiftUI

/// A row of titles under a heading, scrolling sideways, with room around
/// the cards for a focused one to grow into.
struct Rail: View {
    let title: String
    var subtitle = ""
    let items: [TitleItem]
    var wide = false
    var horizontalPadding: CGFloat = Theme.Layout.gutter
    var resume: ((TitleItem) -> Resume?)? = nil
    var onFocus: ((TitleItem) -> Void)? = nil
    var onMore: (() -> Void)? = nil
    /// Where each of `items` stands in its saga, on the sagas' row alone.
    var places: [SagaPlace] = []
    /// What proposed these titles, for a launch made from the hold menu.
    var surface = LaunchSurface.other
    let onPress: (TitleItem) -> Void
    @Environment(Navigator.self) private var navigator
    @Environment(HomeModel.self) private var home

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RowHeading(title: title, subtitle: subtitle)
                .padding(.horizontal, horizontalPadding)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: Theme.Poster.gap) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { slot, item in
                        PosterCard(
                            item: item, wide: wide, resume: resume?(item),
                            place: places.indices.contains(slot) ? places[slot] : nil,
                            onFocus: { onFocus?(item) }
                        ) { onPress(item) }
                        .titleActions(
                            for: item, passesLeft: home.evening.passesLeft,
                            onOpenRow: { navigator.openRow($0) },
                            onPlay: { navigator.resume($0, from: surface) })
                        .onPlayPauseCommand { navigator.resume(item, from: surface) }
                    }
                    if let onMore { MoreCard(onPress: onMore) }
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, wide ? Theme.wideInset : Theme.focusInset)
            }
            .scrollClipDisabled()
            // across the whole width: down from a card past the end of a
            // short rail lands in it rather than on the rail after it
            .focusSection()
        }
        // the air between two rails, under a focused card's caption
        .padding(.bottom, Theme.Space.s24)
    }
}

/// A row of people, all mounted at once: a cast is a few faces.
struct CastRail: View {
    let title: String
    let people: [CastCredit]
    let onPress: (CastCredit) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RowHeading(title: title)
                .padding(.horizontal, Theme.Layout.gutter)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: Theme.Face.gap) {
                    ForEach(Array(people.prefix(20).enumerated()), id: \.offset) { _, person in
                        FaceCard(person: person) { onPress(person) }
                    }
                }
                .padding(.horizontal, Theme.Layout.gutter)
                .padding(.vertical, Theme.faceInset)
            }
            .scrollClipDisabled()
            .focusSection()
        }
        .padding(.bottom, Theme.Space.s24)
    }
}

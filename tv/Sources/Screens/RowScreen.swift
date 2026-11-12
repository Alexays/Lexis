import LexisCore
import SwiftUI

/// One row of a shelf, opened as a screen of its own.
///
/// A rail draws six of the twenty it holds and the rest are reachable only by
/// holding right until the end of it. Here the row is a place: it says its own
/// name, explains itself, counts what it holds, and lays it out as a grid.
struct RowScreen: View {
    let reason: HomeReason
    /// The row is a tab of the bar rather than a level pushed over one.
    var tab = false
    @Environment(Navigator.self) private var navigator
    @State private var items: [TitleItem] = []
    @State private var loaded = false
    @State private var error: String?
    @State private var passesLeft: UInt32 = 0
    /// Only the first card is bound: the remote moving over the grid changes
    /// no state the screen reads; the title under it is published instead.
    @FocusState private var firstFocused: Bool

    /// A measure a sentence can be read across at three metres.
    private static let prose: CGFloat = 1180

    var body: some View {
        ZStack(alignment: .top) {
            RowBackdrop()
            // the heading scrolls away with the grid rather than standing over it
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    if tab { BarBand() }
                    ShelfHead(title: reason.railTitle, count: count)
                        .padding(.top, tab ? 0 : Theme.Space.s64)
                    Text(reasonNote)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .fits(2)
                        .frame(maxWidth: RowScreen.prose, alignment: .leading)
                        .padding(.horizontal, Theme.Layout.gutter)
                        .padding(.top, Theme.Space.s16)
                    if tasteDerived { RowWhy() }
                    grid
                }
            }
            .scrollClipDisabled()
        }
        .task { await load() }
    }

    private var count: String {
        guard loaded, !items.isEmpty else { return "" }
        return t("settings.titlesCount", ["n": items.count.formatted(.number.locale(Locale(identifier: I18n.shared.current.rawValue)))])
    }

    /// A sentence under the heading for the rows the heading does not already
    /// explain. Silence for the others: the core writes no prose, and an
    /// invented line would say less than the title above it.
    /// What the row's name does not already say. The title names the rule;
    /// this says what the rule is for, which is the whole reason a row is a
    /// place rather than a shelf.
    private var reasonNote: String {
        switch reason {
        case .becauseYouWatched(let seed, _): t("why.becauseYouWatched", ["title": seed])
        case .tasteFacet: t("why.tasteFacet")
        case .sagas: t("why.sagas")
        case .withActor: t("why.withActor")
        case .byDirector: t("why.byDirector")
        case .genreEra: t("why.genreEra")
        case .recentlyAdded: t("why.recentlyAdded")
        case .longAgo: t("why.longAgo")
        case .rediscovery: t("why.rediscovery")
        case .stepAside: t("why.stepAside")
        case .season: t("why.season")
        case .forgottenGem(let seed): t("why.forgottenGem", ["title": seed])
        case .thread: t("why.thread")
        case .mood: t("why.mood")
        case .onThisDay: t("why.onThisDay")
        case .retrospective: t("why.retrospective")
        case .thisMonth: t("why.thisMonth")
        case .cineClub: t("why.cineClub")
        case .upNext: t("why.upNext")
        case .tonight: t("why.tonight")
        case .stageShows: t("why.stageShows")
        case .watchlist: t("why.watchlist")
        case .popular: t("why.popular")
        }
    }

    /// `title_taste` is global to the title, not to the row: in a row about an
    /// actor or a saga it would answer with a taste facet, which reads as a
    /// contradiction. Only a row drawn from taste can carry it.
    private var tasteDerived: Bool {
        switch reason {
        case .tasteFacet, .becauseYouWatched, .stepAside, .forgottenGem, .thisMonth, .cineClub:
            true
        default: false
        }
    }

    @ViewBuilder private var grid: some View {
        if let error {
            VStack(alignment: .leading, spacing: Theme.Space.s24) {
                Text(error)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.error)
                ActionButton(label: t("common.retry")) {
                    Task {
                        loaded = false
                        await load()
                    }
                }
            }
            .padding(.horizontal, Theme.Layout.gutter)
            .padding(.top, Theme.Space.s40)
        } else if loaded, items.isEmpty {
            // the grid's own footprint, empty, under what would fill it
            HStack(spacing: Theme.Reason.gap) {
                ForEach(0..<Theme.Reason.columns, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: Theme.Radius.poster, style: .continuous)
                        .fill(Theme.Colors.bg1)
                        .frame(width: Theme.Reason.width, height: Theme.Reason.height)
                }
            }
            .padding(.horizontal, Theme.Layout.gutter)
            .padding(.top, Theme.Space.s40)
            .overlay {
                VStack(spacing: Theme.Space.s16) {
                    GlyphView(glyph: .bookmark, size: Theme.Typography.titleSize)
                        .foregroundStyle(Theme.Colors.accent)
                    Text(t(reason == .watchlist ? "row.emptyWatchlistTitle" : "row.empty"))
                        .font(Theme.Typography.title)
                        .tracking(Theme.Typography.titleTracking)
                        .foregroundStyle(Theme.Colors.white)
                    if reason == .watchlist {
                        Text(t("row.emptyWatchlist"))
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Colors.textSecondary)
                    }
                }
                .padding(.top, Theme.Space.s40)
            }
            .accessibilityElement(children: .combine)
        } else {
            let columns = Theme.Reason.columns
            // room for a focused card to grow into without reaching the next row
            LazyVStack(alignment: .leading, spacing: Theme.Reason.inset + Theme.Space.s16) {
                ForEach(0..<(items.count + columns - 1) / columns, id: \.self) { row in
                    HStack(alignment: .top, spacing: Theme.Reason.gap) {
                        ForEach(row * columns..<min(row * columns + columns, items.count), id: \.self) { slot in
                            let item = items[slot]
                            Group {
                                if slot == 0 {
                                    card(item).focused($firstFocused)
                                } else {
                                    card(item)
                                }
                            }
                                .focusedValue(\.rowItem, item)
                                // no row is handed to the menu: "more like this"
                                // is the screen the remote is already on
                                .titleActions(
                                    for: item, passesLeft: passesLeft,
                                    onOpenRow: { navigator.openRow($0) },
                                    onPlay: { navigator.resume($0, from: .homeRow(reason: reason)) })
                                .onPlayPauseCommand { navigator.resume(item, from: .homeRow(reason: reason)) }
                        }
                    }
                    // a short last row is reached from any column above it
                    .focusSection()
                }
            }
            .padding(.horizontal, Theme.Layout.gutter)
            .padding(.top, Theme.Space.s40)
            .padding(.bottom, Theme.Layout.gridRunOut)
        }
    }

    private func card(_ item: TitleItem) -> some View {
        ReasonCard(item: item) { navigator.open(item, from: .homeRow(reason: reason)) }
    }

    private func load() async {
        guard !loaded else { return }
        let tz = Format.tzOffsetSecs
        let reason = reason
        let fetched = await CoreClient.run {
            (
                Result { try CoreClient.shared.rowItems(reason: reason, tzOffsetSecs: tz) },
                try? CoreClient.shared.evening(tzOffsetSecs: tz)
            )
        }
        switch fetched.0 {
        case .success(let found):
            items = found
            error = nil
        case .failure(let failure):
            items = []
            error = Format.describe(failure)
        }
        passesLeft = fetched.1?.passesLeft ?? 0
        loaded = true
        // a tab picked from the bar leaves the remote on the bar
        firstFocused = !items.isEmpty && navigator.browsing
    }
}

private struct RowItemKey: FocusedValueKey {
    typealias Value = TitleItem
}

extension FocusedValues {
    /// The card under the remote in a row screen, published by the card itself.
    fileprivate var rowItem: TitleItem? {
        get { self[RowItemKey.self] }
        set { self[RowItemKey.self] = newValue }
    }
}

/// The backdrop, following the remote from beside the grid so that a press
/// redraws it alone, and only once the thumb has rested on a card.
private struct RowBackdrop: View {
    @Environment(Navigator.self) private var navigator
    @FocusedValue(\.rowItem) private var item
    @State private var shown: Int64?

    var body: some View {
        Backdrop(titleId: shown, picture: false)
            .task(id: item?.id) {
                guard let id = item?.id else { return }
                if !navigator.browsing { navigator.browsing = true }
                guard id != shown else { return }
                // a sweep along the grid cross-fades once, on the card it ends on
                try? await Task.sleep(for: .seconds(Theme.Motion.heroSettle))
                guard !Task.isCancelled else { return }
                shown = id
            }
    }
}

/// Why the title under the remote is here, read beside the grid like the
/// backdrop. The band is reserved whatever the title, so a title the core
/// has nothing on does not shift the grid up.
private struct RowWhy: View {
    @FocusedValue(\.rowItem) private var item
    /// A title with no taste is kept as a present key with no value, so the
    /// core is asked once per title and never again.
    @State private var tastes: [Int64: TitleTasteInfo?] = [:]

    var body: some View {
        let taste = item.flatMap { tastes[$0.id] ?? nil }
        HStack(spacing: Theme.Space.s24) {
            if let taste {
                Text(t("title.tasteAffinity", ["title": taste.leader]))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .fits(1)
            }
        }
        .frame(height: Theme.Space.s40, alignment: .leading)
        .padding(.horizontal, Theme.Layout.gutter)
        .padding(.top, Theme.Space.s16)
        .animation(.easeOut(duration: Theme.Motion.dim), value: taste)
        .task(id: item?.id) {
            guard let id = item?.id, tastes.index(forKey: id) == nil else { return }
            let found = await CoreClient.run { try? CoreClient.shared.titleTaste(titleId: id) }
            tastes[id] = .some(found)
        }
    }
}


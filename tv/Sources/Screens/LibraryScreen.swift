import LexisCore
import SwiftUI

/// One shelf of the library, films or series: the whole of it as a grid of
/// posters read a page at a time, narrowed by a row of pills, and in title
/// order an index of initials beside it that jumps the grid.
struct LibraryScreen: View {
    let kind: ApiMediaKind
    @Environment(Navigator.self) private var navigator
    @State private var model = LibraryModel()
    @State private var unwatched = false
    @State private var uhd = false
    @FocusState private var focus: LibraryFocus?

    fileprivate static let columns = 8
    /// The index's column, and the air between it and the grid.
    private static let indexWidth: CGFloat = Theme.Space.s40
    fileprivate static let cardWidth =
        (Theme.Layout.screenWidth - 2 * Theme.Layout.gutter - indexWidth - Theme.Space.s16
            - CGFloat(columns - 1) * Theme.Poster.gap) / CGFloat(columns)
    fileprivate static let cardHeight = (cardWidth * 3 / 2).rounded()
    /// A poster and the air under it, which holds a focused one's growth.
    private static let rowHeight = cardHeight + Theme.Space.s40

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                // Eager above the grid: the bar stays mounted however far the
                // grid is scrolled, so Menu can always hand it the remote.
                VStack(alignment: .leading, spacing: 0) {
                    BarBand().id("bar")
                    ShelfHead(title: t(kind == .movie ? "nav.movies" : "nav.series"), count: countLine)
                    pills
                        .padding(.horizontal, Theme.Layout.gutter)
                        .padding(.top, Theme.Space.s24)
                        .padding(.bottom, Theme.Space.s40)
                    shelf
                }
            }
            .scrollClipDisabled()
            // Menu hands the remote to the bar: the bar has to be on the screen
            .onChange(of: navigator.browsing) { _, now in
                if !now { withAnimation { proxy.scrollTo("bar", anchor: .top) } }
            }
            .overlay(alignment: .bottomTrailing) {
                if navigator.filters.sort == .name, model.letters.count > 1 {
                    LetterIndex(letters: model.letters) { offset in
                        if !navigator.browsing { navigator.browsing = true }
                        // a fifth down rather than flush: the row lands clear of the overscan
                        proxy.scrollTo(Int(offset) / LibraryScreen.columns, anchor: UnitPoint(x: 0, y: 0.2))
                    }
                    .frame(width: LibraryScreen.indexWidth)
                    .padding(.trailing, Theme.Layout.gutter)
                    .padding(.bottom, Theme.Layout.pillTop)
                }
            }
        }
        .background(Theme.Colors.bg0)
        .onAppear {
            // a return from a title finds the grid where it was left
            if model.count == nil { model.landOnArrival = navigator.browsing }
            // a tab chosen from the bar keeps the remote on its pill
            if !navigator.browsing { navigator.focusToken += 1 }
        }
        .task(id: LibraryQuery(filters: navigator.filters, unwatched: unwatched, uhd: uhd)) {
            model.reload(kind: kind, filters: navigator.filters, unwatched: unwatched, uhd: uhd)
        }
        .task { await model.loadGenres(kind: kind) }
        .onChange(of: focus) { _, now in
            if now != nil, !navigator.browsing { navigator.browsing = true }
        }
        .onChange(of: model.landed) { _, _ in
            if model.landOnArrival {
                model.landOnArrival = false
                focus = .firstCard
            }
        }
    }

    private var countLine: String {
        guard let count = model.count else { return "" }
        let number = count.formatted(.number.locale(Locale(identifier: I18n.shared.current.rawValue)))
        return t(kind == .movie ? "library.count.movie" : "library.count.show", ["n": number])
    }

    /// What narrows the shelf: all of it, or what is left to watch, or what
    /// is in 4K, then a genre and an order, each a menu of its own.
    private var pills: some View {
        HStack(spacing: Theme.Space.s16) {
            pill(t("library.filterAll"), selected: !unwatched && !uhd, focus: .all) {
                unwatched = false
                uhd = false
            }
            pill(t("library.unwatched"), selected: unwatched, focus: .unwatched) { unwatched.toggle() }
            pill(t("library.uhd"), selected: uhd, focus: .uhd) { uhd.toggle() }
            Menu {
                Picker(t("library.genre"), selection: Bindable(navigator).filters.genre) {
                    Text(t("library.allGenres")).tag("")
                    ForEach(model.genres, id: \.self) { genre in
                        Text(Format.genre(genre)).tag(genre)
                    }
                }
            } label: {
                menuLabel(navigator.filters.genre.isEmpty ? t("library.genre") : Format.genre(navigator.filters.genre))
            }
            .buttonStyle(FilledControlStyle(selected: !navigator.filters.genre.isEmpty))
            .focused($focus, equals: .genre)
            .accessibilityLabel(t("library.genre"))
            Menu {
                Picker(t("library.sort"), selection: Bindable(navigator).filters.sort) {
                    ForEach([LibrarySort.recentlyAdded, .name, .year], id: \.self) { sort in
                        Text(t(LibraryScreen.orderKey(sort))).tag(sort)
                    }
                }
            } label: {
                menuLabel(t("library.sortBy", ["order": t(LibraryScreen.orderKey(navigator.filters.sort) + ".inline")]))
            }
            .buttonStyle(FilledControlStyle())
            .focused($focus, equals: .sort)
            .accessibilityLabel(t("library.sort"))
        }
        // across the whole width, so down from any tab of the bar enters the row
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
        // down from the bar starts the row at its head, wherever the pill above
        // stood: the user-initiated priority is what applies it on every entry
        .defaultFocus($focus, .all, priority: .userInitiated)
    }

    private static func orderKey(_ sort: LibrarySort) -> String {
        switch sort {
        case .name: "library.order.name"
        case .year: "library.order.year"
        case .recentlyAdded: "library.order.recent"
        }
    }

    private func pill(_ label: String, selected: Bool, focus: LibraryFocus, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(Theme.Typography.caption.weight(.semibold))
        }
        .buttonStyle(FilledControlStyle(selected: selected))
        .focused($focus, equals: focus)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func menuLabel(_ text: String) -> some View {
        HStack(spacing: Theme.Space.s8) {
            Text(text).font(Theme.Typography.caption.weight(.semibold))
            Image(systemName: "chevron.down").font(Theme.Typography.captionCompact.weight(.bold))
        }
    }

    @ViewBuilder private var shelf: some View {
        if let error = model.error {
            Text(error)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.error)
                .padding(.horizontal, Theme.Layout.gutter)
        }
        if let count = model.count {
            if count > 0 {
                grid(count)
            } else if navigator.filters.active || unwatched || uhd {
                Text(t("library.filterEmpty"))
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .padding(.horizontal, Theme.Layout.gutter)
            } else {
                ghosts.overlay {
                    VStack(spacing: Theme.Space.s16) {
                        Text(t("library.emptyTitle"))
                            .font(Theme.Typography.title)
                            .tracking(Theme.Typography.titleTracking)
                            .foregroundStyle(Theme.Colors.white)
                        Text(t("library.emptyBody"))
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Colors.textSecondary)
                    }
                }
            }
        } else if model.error == nil {
            ghosts.accessibilityElement().accessibilityLabel(t("library.loading"))
        }
    }

    private func grid(_ count: Int) -> some View {
        let rows = (count + LibraryScreen.columns - 1) / LibraryScreen.columns
        return LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(0..<rows, id: \.self) { row in
                // The count and the pages change in one turn, but a row's
                // closure can run against the new pages before the grid drops it.
                if row / LibraryModel.pageRows < model.pages.count {
                    LibraryRow(page: model.pages[row / LibraryModel.pageRows], row: row, count: count, focus: $focus)
                        .frame(height: LibraryScreen.rowHeight, alignment: .top)
                        .onAppear { model.ensure(row: row) }
                }
            }
        }
        .padding(.leading, Theme.Layout.gutter)
        .padding(.bottom, Theme.Layout.gridRunOut)
        .id(model.shelf)
    }

    /// Two rows of the grid's own footprint, never focusable: what stands
    /// in for the shelf while it is counted, and under an empty library.
    private var ghosts: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s40) {
            ForEach(0..<2, id: \.self) { _ in
                HStack(spacing: Theme.Poster.gap) {
                    ForEach(0..<LibraryScreen.columns, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: Theme.Radius.poster, style: .continuous)
                            .fill(Theme.Colors.bg1)
                            .frame(width: LibraryScreen.cardWidth, height: LibraryScreen.cardHeight)
                    }
                }
            }
        }
        .padding(.leading, Theme.Layout.gutter)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A shelf's name in the display face, and how much it holds beside it.
struct ShelfHead: View {
    let title: String
    var count = ""

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: Theme.Space.s24) {
            Text(title)
                .font(Theme.Typography.display)
                .tracking(Theme.Typography.displayTracking)
                .foregroundStyle(Theme.Colors.white)
                .fits(1, size: Theme.Typography.displaySize)
            Spacer(minLength: 0)
            Text(count)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.textSecondary)
                .monospacedDigit()
                .fits(1, size: Theme.Typography.bodySize)
        }
        .padding(.horizontal, Theme.Layout.gutter)
    }
}

/// Only the first card is bound: the remote moving over the grid changes
/// no state the screen reads, and the screen can still send it to the top.
private enum LibraryFocus: Hashable {
    case all, unwatched, uhd, genre, sort, firstCard
}

/// Everything the shelf on screen depends on: a change to any of it reads
/// the shelf again, and nothing else does.
private struct LibraryQuery: Equatable {
    let filters: LibraryFilters
    let unwatched: Bool
    let uhd: Bool
}

/// The initials the shelf holds, down the right edge: the remote landing on
/// one brings its first titles to the top of the grid.
private struct LetterIndex: View {
    let letters: [LibraryLetter]
    let onLand: (UInt32) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(letters, id: \.letter) { entry in
                Button { onLand(entry.offset) } label: {
                    FocusReader { focused in
                        Text(entry.letter)
                            .font(Theme.Typography.label)
                            .frame(width: LetterIndex.cell, height: LetterIndex.cell)
                            .onChange(of: focused) { _, now in if now { onLand(entry.offset) } }
                    }
                }
                .buttonStyle(FilledControlStyle(horizontal: 0, vertical: 0, glass: false))
                .accessibilityLabel(entry.letter)
            }
        }
        .focusSection()
    }

    /// Twenty-seven of them fit between the pills and the foot of the screen.
    private static let cell: CGFloat = 26
}

/// One row of the grid, reading only its own page: a page landing or
/// leaving redraws its rows and no other.
private struct LibraryRow: View {
    let page: LibraryPage
    let row: Int
    let count: Int
    let focus: FocusState<LibraryFocus?>.Binding
    @Environment(Navigator.self) private var navigator
    @Environment(HomeModel.self) private var home

    var body: some View {
        let start = row * LibraryScreen.columns
        let end = min(start + LibraryScreen.columns, count)
        let base = row / LibraryModel.pageRows * LibraryModel.pageSize
        let items = page.items
        HStack(alignment: .top, spacing: Theme.Poster.gap) {
            ForEach(start..<end, id: \.self) { index in
                if let items, index - base < items.count {
                    let item = items[index - base]
                    if index == 0 {
                        card(item).focused(focus, equals: .firstCard)
                    } else {
                        card(item)
                    }
                } else {
                    GridCard(item: nil) {}
                }
            }
        }
        // a short last row is reached from any column above it
        .focusSection()
    }

    private func card(_ item: TitleItem) -> some View {
        GridCard(item: item) { navigator.open(item, from: .library) }
            .titleActions(
                for: item, passesLeft: home.evening.passesLeft, onOpenRow: { navigator.openRow($0) },
                onPlay: { navigator.resume($0, from: .library) })
            .onPlayPauseCommand { navigator.resume(item, from: .library) }
    }
}

/// A poster at the grid's size, with the system's lift under the remote.
/// Nil is a page not read yet: focusable, so the grid scrolls past it.
private struct GridCard: View {
    let item: TitleItem?
    let onPress: () -> Void

    var body: some View {
        Button(action: onPress) {
            ZStack {
                Theme.Colors.bg1
                if let item {
                    ArtworkImage(kind: .poster(titleId: item.id)) {
                        VStack(spacing: Theme.Space.s8) {
                            Text(Format.monogram(item.name))
                                .font(Theme.Typography.headline)
                                .foregroundStyle(Theme.Colors.textMuted)
                            Text(item.name)
                                .font(Theme.Typography.captionCompact)
                                .foregroundStyle(Theme.Colors.textMuted)
                                .multilineTextAlignment(.center)
                                .fits(3, size: Theme.Typography.captionCompactSize)
                        }
                        .padding(.horizontal, Theme.Space.s16)
                    }
                }
            }
            .frame(width: LibraryScreen.cardWidth, height: LibraryScreen.cardHeight)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.poster, style: .continuous))
            .hoverEffect(.highlight)
        }
        .buttonStyle(CardButtonStyle(shadow: false))
        .accessibilityLabel(item.map { item in item.year.map { "\(item.name) \($0)" } ?? item.name } ?? t("library.loading"))
    }
}

/// One page of the grid, observed on its own. Nil while unread, and once
/// dropped for being far from the rows on screen.
@MainActor
@Observable
private final class LibraryPage {
    var items: [TitleItem]?
}

@MainActor
@Observable
private final class LibraryModel {
    nonisolated static let pageRows = 10
    nonisolated static let pageSize = pageRows * LibraryScreen.columns
    private static let leadRows = 5
    private static let keptPages = 4

    var count: Int?
    /// One slot per page of the shelf, laid out when the count lands.
    private(set) var pages: [LibraryPage] = []
    /// Where each initial starts, in title order only.
    private(set) var letters: [LibraryLetter] = []
    private(set) var genres: [String] = []
    var error: String?
    private(set) var shelf = ""
    /// Bumped when the first page lands, for the screen that arrived with
    /// the remote already meant for the grid.
    private(set) var landed = 0
    var landOnArrival = false
    private var generation = 0
    private var loading: Set<Int> = []
    private var kind = ApiMediaKind.movie
    private var filter = LibraryFilter(genre: nil, minYear: nil, maxYear: nil, unwatched: false, uhd: false)
    private var sort = LibrarySort.name

    func loadGenres(kind: ApiMediaKind) async {
        guard genres.isEmpty else { return }
        genres = await CoreClient.run { try? CoreClient.shared.libraryFacets(kind: kind) }?.genres ?? []
    }

    func reload(kind: ApiMediaKind, filters: LibraryFilters, unwatched: Bool, uhd: Bool) {
        let shelf = "\(kind)-\(filters.sort)-\(filters.genre)-\(filters.decade)-\(unwatched)-\(uhd)"
        // the screen coming back from a title asks for the shelf it still holds
        guard shelf != self.shelf || error != nil else { return }
        self.shelf = shelf
        self.kind = kind
        sort = filters.sort
        filter = LibraryFilter(
            genre: filters.genre.isEmpty ? nil : filters.genre,
            minYear: filters.decade == 0 ? nil : filters.decade,
            maxYear: filters.decade == 0 ? nil : filters.decade + 9,
            unwatched: unwatched, uhd: uhd)
        generation += 1
        pages = []
        loading = []
        count = nil
        error = nil
        let generation = generation
        let (filter, sort) = (filter, sort)
        Task { @MainActor [self] in
            let counted = await CoreClient.run {
                Result {
                    (
                        try CoreClient.shared.countTitles(kind: kind, filter: filter),
                        sort == .name ? try CoreClient.shared.libraryLetters(kind: kind, filter: filter) : []
                    )
                }
            }
            guard generation == self.generation else { return }
            switch counted {
            case .success(let (n, letters)):
                let count = Int(n)
                pages = (0..<(count + LibraryModel.pageSize - 1) / LibraryModel.pageSize).map { _ in LibraryPage() }
                self.letters = letters
                self.count = count
                if n > 0 { load(page: 0) }
            case .failure(let failure):
                error = Format.describe(failure)
            }
        }
    }

    /// The pages a row coming on screen and a few rows either side need, and
    /// no page far from it: a long scroll keeps a bounded window.
    func ensure(row: Int) {
        guard let count, count > 0 else { return }
        let lastPage = (count - 1) / LibraryModel.pageSize
        let anchor = row / LibraryModel.pageRows
        for (index, page) in pages.enumerated() where page.items != nil && abs(index - anchor) > LibraryModel.keptPages {
            page.items = nil
        }
        let from = max(0, row - LibraryModel.leadRows) / LibraryModel.pageRows
        let to = min(lastPage, (row + LibraryModel.leadRows) / LibraryModel.pageRows)
        guard from <= to else { return }
        for page in from...to where pages[page].items == nil { load(page: page) }
    }

    private func load(page: Int) {
        guard !loading.contains(page) else { return }
        loading.insert(page)
        let generation = generation
        let (kind, filter, sort) = (kind, filter, sort)
        Task { @MainActor [self] in
            let fetched = await CoreClient.run {
                Result {
                    try CoreClient.shared.browseTitles(
                        kind: kind, filter: filter, sort: sort,
                        offset: UInt32(page * LibraryModel.pageSize), limit: UInt32(LibraryModel.pageSize))
                }
            }
            guard generation == self.generation else { return }
            loading.remove(page)
            switch fetched {
            case .success(let items):
                // through the page alone: the array's own observers stay quiet
                pages[page].items = items
                if page == 0 { landed += 1 }
            case .failure(let failure):
                error = Format.describe(failure)
            }
        }
    }
}

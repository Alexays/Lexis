import LexisCore
import SwiftUI

/// What a keystroke waits out before it costs a query.
private let debounce = Duration.milliseconds(250)
/// One letter matches most of a library and narrows nothing.
private let minQuery = 2
private let limit: UInt32 = 60
private let columns = Theme.Reason.columns
/// The title-safe margin a television keeps under the last line.
private let bottomMargin: CGFloat = 60
private let recentKey = "search.recent.v1"
private let recentLimit = 6

/// The search tab: the system's own field and keyboard over the results,
/// grouped by why each title is a hit. Before anything is typed, the
/// queries that found something and the film the viewer was in the middle
/// of, since that is what most people open this screen for.
struct SearchScreen: View {
    /// The home tab's model, kept by the shell: its resume rail is the one
    /// offered here.
    let home: HomeModel
    @Environment(Navigator.self) private var navigator
    @State private var model = SearchModel()
    /// The same words read as a wish rather than as names: typed or spoken
    /// into the remote's microphone, read by the core's rules.
    @State private var asker = AskModel()
    @State private var query = ""
    /// A chip was pressed: the remote goes to the first card its query lands.
    @State private var picked = false
    @FocusState private var focusedCard: Int64?
    @FocusState private var focusedChip: String?

    var body: some View {
        VStack(spacing: 0) {
            // A section, so a move up from any key lands on the bar: the bar
            // is centred and the keyboard spans the screen.
            // Opaque and in front: the keyboard and the results scroll up
            // under it rather than over the pills.
            BarBand()
                .background(Theme.Colors.bg0)
                .zIndex(1)
            // The shell's navigation stack is the container the field needs.
            // A stack of its own here would sit inside that one, whose path
            // SwiftUI then compares against this one's and traps on.
            surface.searchable(text: $query, prompt: Text(t("search.placeholder")))
        }
        // The text is read only by views of its own, through the binding:
        // read here, a keystroke would redraw every card of the results.
        .background { QueryFollower(query: $query, model: model, asker: asker) }
        .onChange(of: model.ran) { _, _ in
            guard picked else { return }
            picked = false
            if let first = model.hits.first { focusedCard = first.item.id }
        }
        .onChange(of: focusedCard) { _, now in if now != nil, !navigator.browsing { navigator.browsing = true } }
        .onChange(of: focusedChip) { _, now in if now != nil { navigator.browsing = true } }
        // leaving the screen settles the query the viewer stopped on
        .onDisappear { model.remember() }
        .task {
            if !home.loaded { home.load() }
        }
    }

    private var surface: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                found
                ideas
            }
            .padding(.horizontal, Theme.Layout.gutter)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollClipDisabled()
    }

    /// What the same words were understood to ask for, under the names they
    /// match: the rules' reading as chips a press takes off, and the first
    /// titles it leads to. Nothing while it has understood nothing.
    @ViewBuilder private var ideas: some View {
        if let result = asker.result, !result.items.isEmpty {
            heading(t("search.ideas"))
                .padding(.top, model.hits.isEmpty ? 0 : Theme.Space.s24)
                .padding(.bottom, Theme.Space.s16)
            let chips = AskChip.of(result.filters)
            if !chips.isEmpty {
                WrapLayout(spacing: Theme.Space.s16, rowSpacing: 16) {
                    ForEach(chips, id: \.self) { chip in
                        Button { asker.remove(chip) } label: {
                            Text(chip.label).font(Theme.Typography.caption)
                        }
                        .buttonStyle(FilledControlStyle(selected: true, horizontal: Theme.Control.chip.width, vertical: Theme.Control.chip.height))
                        .accessibilityLabel(t("search.askRemove", ["filter": chip.label]))
                    }
                }
                .focusSection()
                .padding(.bottom, Theme.Space.s24)
            }
            // two rows: the names typed come first, and the ideas are a lead
            let shown = result.items.prefix(2 * columns)
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(stride(from: 0, to: shown.count, by: columns)), id: \.self) { start in
                    titles(shown[start..<min(start + columns, shown.count)])
                }
            }
            .padding(.top, Theme.Reason.inset)
            .padding(.bottom, bottomMargin)
            .id(asker.ran)
        }
    }

    private func titles(_ items: ArraySlice<TitleItem>) -> some View {
        HStack(alignment: .top, spacing: Theme.Reason.gap) {
            ForEach(items, id: \.id) { item in
                ReasonCard(item: item) {
                    navigator.open(item, from: .ask)
                }
                .titleActions(
                    for: item, passesLeft: home.evening.passesLeft, onOpenRow: { navigator.openRow($0) },
                    onPlay: { navigator.resume($0, from: .ask) })
                .onPlayPauseCommand { navigator.resume(item, from: .ask) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
        .padding(.bottom, Theme.Reason.inset + Theme.Space.s16)
    }

    @ViewBuilder private var found: some View {
        if model.pending, model.hits.isEmpty { pendingLine }
        if let error = model.error {
            VStack(alignment: .leading, spacing: Theme.Space.s24) {
                Text(error)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.error)
                ActionButton(label: t("common.retry")) { model.typed(query) }
                    .focusSection()
            }
        } else if !model.hits.isEmpty || asker.result?.items.isEmpty == false {
            if model.relaxed {
                Text(t("search.relaxed", ["query": model.ran]))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textMuted)
            }
            // a new query is a new page: the scroll position of the
            // results the viewer has left goes with them
            results.id(model.ran)
            if model.pending { pendingLine }
        } else {
            empty
        }
    }

    private var pendingLine: some View {
        Text(t("search.pending"))
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.Colors.textMuted)
            .padding(.bottom, Theme.Space.s16)
    }

    private var results: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(model.groups.enumerated()), id: \.element.kind) { index, group in
                heading(group.heading)
                    .padding(.top, index == 0 ? 0 : Theme.Space.s24)
                    .padding(.bottom, Theme.Reason.inset + Theme.Space.s16)
                // ids carry the group: two groups' first rows are both at 0
                ForEach(Array(stride(from: 0, to: group.hits.count, by: columns)), id: \.self) { start in
                    row(group.hits[start..<min(start + columns, group.hits.count)])
                        .id("\(group.kind)-\(start)")
                }
            }
        }
        .padding(.bottom, bottomMargin)
    }

    /// A group's name, set the way a rail names itself.
    private func heading(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typography.label)
            .tracking(Theme.Typography.labelTracking)
            .textCase(.uppercase)
            .foregroundStyle(Theme.Colors.text)
            .fits(1, size: Theme.Typography.labelSize)
    }

    /// One row of the grid, a section of its own: a press down from a
    /// column the row below lacks still lands on that row.
    private func row(_ cards: ArraySlice<SearchHit>) -> some View {
        HStack(alignment: .top, spacing: Theme.Reason.gap) {
            ForEach(cards, id: \.item.id) { hit in
                ReasonCard(item: hit.item) {
                    model.remember()
                    navigator.open(hit.item, from: .search)
                }
                .focused($focusedCard, equals: hit.item.id)
                .titleActions(
                    for: hit.item, passesLeft: home.evening.passesLeft, onOpenRow: { navigator.openRow($0) },
                    onPlay: {
                        model.remember()
                        navigator.resume($0, from: .search)
                    })
                .onPlayPauseCommand {
                    model.remember()
                    navigator.resume(hit.item, from: .search)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
        .padding(.bottom, Theme.Reason.inset + Theme.Space.s16)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.asked, !asker.pending {
                VStack(alignment: .leading, spacing: Theme.Space.s8) {
                    Text(t("search.empty", ["query": model.ran]))
                        .font(Theme.Typography.title)
                        .tracking(Theme.Typography.titleTracking)
                        .foregroundStyle(Theme.Colors.white)
                        .fits(2, size: Theme.Typography.titleSize)
                    Text(t("search.hint"))
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
                .accessibilityElement(children: .combine)
            }
            if !model.recent.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Space.s24) {
                    heading(t("search.recent"))
                    WrapLayout(spacing: Theme.Space.s16, rowSpacing: 16) {
                        ForEach(model.recent, id: \.self) { recent in
                            Button {
                                picked = true
                                query = recent
                            } label: {
                                Text(recent).font(Theme.Typography.body)
                            }
                            .buttonStyle(FilledControlStyle(horizontal: Theme.Control.chip.width, vertical: Theme.Control.chip.height))
                            .focused($focusedChip, equals: recent)
                        }
                        Button { model.clearRecent() } label: {
                            Text(t("search.clearRecent")).font(Theme.Typography.body)
                        }
                        .buttonStyle(FilledControlStyle(horizontal: Theme.Control.chip.width, vertical: Theme.Control.chip.height))
                    }
                    .focusSection()
                }
                .padding(.top, Theme.Space.s40)
            }
            let resume = home.resuming
            if !model.asked, !resume.isEmpty {
                Rail(
                    title: t("row.upNext"), items: resume, wide: true, horizontalPadding: 0,
                    onFocus: { _ in navigator.browsing = true }, surface: .queue,
                    onPress: { navigator.open($0, from: .queue) }
                )
                .padding(.top, Theme.Space.s40)
            }
        }
    }
}

/// Hands each keystroke to the two readers of the words typed.
private struct QueryFollower: View {
    @Binding var query: String
    let model: SearchModel
    let asker: AskModel
    @Environment(Navigator.self) private var navigator

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .onChange(of: query) { _, typed in
                // the field reports no focus of its own: a letter typed is the
                // one sure sign the remote is in the keyboard
                if !typed.isEmpty { navigator.browsing = true }
                model.typed(typed)
                asker.typed(typed)
            }
    }
}

/// The query flow: one search per pause in the typing, off the main actor
/// since every core call blocks, and the answer kept apart from the text
/// still being typed.
@MainActor
@Observable
final class SearchModel {
    private(set) var hits: [SearchHit] = []
    /// The hits under their headings, grouped once when they land.
    fileprivate private(set) var groups: [SearchGroup] = []
    /// Nothing carried every word typed and these carry some of them.
    private(set) var relaxed = false
    private(set) var asked = false
    /// The query the hits on screen belong to, not the one being typed.
    private(set) var ran = ""
    private(set) var error: String?
    /// From the keystroke that queues a query to the moment it settles.
    private(set) var pending = false
    private(set) var recent = SearchModel.loadRecent()
    @ObservationIgnored private var inFlight: Task<Void, Never>?
    /// The query on screen matched whole and found something: worth offering
    /// again once the viewer acts on it, not at every pause in the typing.
    @ObservationIgnored private var keepable = false

    func typed(_ raw: String) {
        let typed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        inFlight?.cancel()
        keepable = false
        guard typed.count >= minQuery else {
            hits = []
            groups = []
            relaxed = false
            asked = false
            error = nil
            pending = false
            ran = ""
            return
        }
        pending = true
        inFlight = Task { [weak self] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            let found = await CoreClient.run {
                Result { try CoreClient.shared.search(query: typed, limit: limit) }
            }
            guard !Task.isCancelled, let self else { return }
            self.landed(typed, found)
        }
    }

    private func landed(_ typed: String, _ found: Result<SearchResults, any Error>) {
        switch found {
        case .success(let results):
            hits = results.hits
            groups = SearchGroup.group(results.hits)
            relaxed = results.relaxed
            error = nil
            // Only a query that matched whole is worth offering again: a
            // half-matched one is a typo, and a chip promises a result.
            keepable = !results.hits.isEmpty && !results.relaxed
        case .failure(let failure):
            // an error is not an empty library: the two must not read alike
            hits = []
            groups = []
            relaxed = false
            error = Format.describe(failure)
        }
        ran = typed
        asked = true
        pending = false
    }

    /// Keeps the query on screen among the recent ones, in place of any it
    /// extends: the words typed on the way to it are not searches of their own.
    func remember() {
        guard keepable else { return }
        keepable = false
        let kept = recent.filter { !ran.lowercased().hasPrefix($0.lowercased()) }
        recent = Array(([ran] + kept).prefix(recentLimit))
        Prefs.set(recentKey, SearchModel.encode(recent))
    }

    func clearRecent() {
        recent = []
        Prefs.set(recentKey, "")
    }

    // The queries are stored the way the previous app wrote them, so they
    // carry over: joined by newline and percent-encoded the way
    // encodeURIComponent does, as the bytes of that ASCII text.
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")

    private static func loadRecent() -> [String] {
        guard let stored = Prefs.string(recentKey)?.removingPercentEncoding else { return [] }
        return stored.split(separator: "\n").map(String.init)
    }

    private static func encode(_ queries: [String]) -> String {
        queries.joined(separator: "\n").addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }
}

/// The hits under one heading: why they are hits at all, and who or what
/// they share. The groups come out in the ranking's own order, so a query
/// the names answer is a page of names first.
private struct SearchGroup {
    enum Kind { case name, cast, director, crew, genre, episode }
    let kind: Kind
    var values: Set<String> = []
    var hits: [SearchHit] = []

    /// One actor or one genre names itself; a query that landed on several
    /// falls back to the plain word, since a list of names is no heading.
    var heading: String {
        let only = values.count == 1 ? values.first : nil
        switch kind {
        case .name: return t("search.titles")
        case .cast: return only.map { t("search.withActor", ["name": $0]) } ?? t("search.inCast")
        case .director: return only.map { t("search.byDirector", ["name": $0]) } ?? t("search.inDirection")
        case .crew: return only.map { t("search.byCrew", ["name": $0]) } ?? t("search.inCrew")
        case .genre: return only.map { t("search.inGenre", ["genre": Format.genre($0)]) } ?? t("search.byGenre")
        case .episode: return only.map { t("search.inEpisode", ["episode": $0]) } ?? t("search.inEpisodes")
        }
    }

    static func group(_ hits: [SearchHit]) -> [SearchGroup] {
        var groups: [SearchGroup] = []
        for hit in hits {
            let (kind, value): (Kind, String) = switch hit.reason {
            case .name: (.name, "")
            case .cast(let who): (.cast, who)
            case .director(let who): (.director, who)
            case .crew(let who): (.crew, who)
            case .genre(let what): (.genre, what)
            case .episode(let name, let season, let episode):
                (.episode, [Format.episodeCode(season: season, episode: episode), name]
                    .filter { !$0.isEmpty }.joined(separator: " · "))
            }
            let at = groups.firstIndex { $0.kind == kind } ?? {
                groups.append(SearchGroup(kind: kind))
                return groups.count - 1
            }()
            groups[at].values.insert(value)
            groups[at].hits.append(hit)
        }
        return groups
    }
}

/// Asking in words: one question per pause, longer than a search's since a
/// question is a sentence, off the main actor, and a chip taken off sent
/// back as the filters without it.
@MainActor
@Observable
final class AskModel {
    private(set) var result: AskResult?
    private(set) var pending = false
    private(set) var error: String?
    /// Counts the answers, so each new one is a new page.
    private(set) var ran = 0
    @ObservationIgnored private var inFlight: Task<Void, Never>?

    private static let pause = Duration.milliseconds(700)

    func typed(_ raw: String) {
        let typed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        inFlight?.cancel()
        guard typed.count >= minQuery else {
            result = nil
            error = nil
            pending = false
            return
        }
        let tz = Format.tzOffsetSecs
        run(after: Self.pause) { try CoreClient.shared.ask(query: typed, tzOffsetSecs: tz) }
    }

    func remove(_ chip: AskChip) {
        guard var filters = result?.filters else { return }
        chip.clear(&filters)
        let tz = Format.tzOffsetSecs
        let asked = filters
        inFlight?.cancel()
        run(after: .zero) { try CoreClient.shared.askWith(filters: asked, tzOffsetSecs: tz) }
    }

    private func run(after wait: Duration, _ call: @escaping @Sendable () throws -> AskResult) {
        pending = true
        inFlight = Task { [weak self] in
            if wait > .zero { try? await Task.sleep(for: wait) }
            guard !Task.isCancelled else { return }
            let answered = await CoreClient.run { Result { try call() } }
            guard !Task.isCancelled, let self else { return }
            switch answered {
            case .success(let answer):
                self.result = answer
                self.error = nil
            case .failure(let failure):
                self.result = nil
                self.error = Format.describe(failure)
            }
            self.ran += 1
            self.pending = false
        }
    }
}

/// One thing a question was understood to ask, drawn as a chip.
enum AskChip: Hashable {
    case length(UInt32)
    case movies, shows, unseen, rewatch, tonight
    case decade(UInt16)
    case person(String)
    case mood(String)
    case words(String)

    static func of(_ f: AskFilters) -> [AskChip] {
        var chips: [AskChip] = []
        if let kind = f.kind { chips.append(kind == .show ? .shows : .movies) }
        if f.unseen { chips.append(.unseen) }
        if f.rewatch { chips.append(.rewatch) }
        if let minutes = f.maxMinutes { chips.append(.length(minutes)) }
        if f.tonight { chips.append(.tonight) }
        if let decade = f.decade { chips.append(.decade(decade)) }
        chips += f.people.map(AskChip.person)
        if let mood = f.mood { chips.append(.mood(mood)) }
        if !f.text.isEmpty { chips.append(.words(f.text)) }
        return chips
    }

    var label: String {
        switch self {
        case .length(let minutes): t("ask.length", ["time": Format.runtime(Double(minutes) * 60)])
        case .movies: t("ask.movies")
        case .shows: t("ask.shows")
        case .unseen: t("ask.unseen")
        case .rewatch: t("ask.rewatch")
        case .tonight: t("ask.tonight")
        case .decade(let first): t("ask.decade", ["decade": Format.decadeName(first)])
        case .person(let name): t("ask.person", ["name": name])
        case .mood(let key): t("mood.\(key)")
        case .words(let text): t("ask.words", ["text": text])
        }
    }

    func clear(_ f: inout AskFilters) {
        switch self {
        case .length: f.maxMinutes = nil
        case .movies, .shows: f.kind = nil
        case .unseen: f.unseen = false
        case .rewatch: f.rewatch = false
        case .tonight: f.tonight = false
        case .decade: f.decade = nil
        case .person(let name): f.people.removeAll { $0 == name }
        case .mood: f.mood = nil
        case .words: f.text = ""
        }
    }
}

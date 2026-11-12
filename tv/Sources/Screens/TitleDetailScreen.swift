import LexisCore
import SwiftUI
import UIKit

/// A title's page: its picture across the whole screen, its lettering, facts,
/// synopsis and actions in the column over the scrim, and under the fold the
/// sections that lead elsewhere, one at a time under a row of tabs.
struct TitleDetailScreen: View {
    let item: TitleItem
    @Environment(Navigator.self) private var navigator
    @State private var model: TitleDetailModel
    @FocusState private var belowFocused: Bool
    @State private var wasBelow = false
    /// The summary opened whole, over the page.
    @State private var readingOverview = false
    @FocusState private var retryFocused: Bool

    init(item: TitleItem) {
        self.item = item
        _model = State(initialValue: TitleDetailModel(item: item))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            hero
            // the name is known before the page is read: it stands at once
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        column(proxy)
                        Color.clear.frame(height: Theme.Layout.pillTop)
                        if model.detail != nil {
                            // apart from the column, so a mark or a verdict redraws
                            // the head and not every row under it
                            DetailSections(item: item, model: model)
                                .focused($belowFocused)
                        }
                    }
                    .padding(.top, Theme.Space.s104)
                    .padding(.bottom, Theme.Space.s64)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id("top")
                }
            }
        }
        .frame(width: Theme.Layout.screenWidth, height: Theme.Layout.screenHeight)
        .ignoresSafeArea()
        // read beside the page, so the remote crossing into the sections does
        // not redraw it
        .background { BelowFollower(below: $belowFocused, wasBelow: $wasBelow) }
        .onAppear { model.load() }
        .onDisappear { model.stop() }
        // the page stays alive under the film and comes back to what it moved
        .onChange(of: navigator.playing == nil) { _, idle in if idle { model.reload(episodesToo: true) } }
        .onExitCommand { navigator.back() }
    }

    /// The picture across the whole screen, the backdrop's own ramp at its
    /// foot and a light one on the left under the column. Past the actions the
    /// picture steps back behind the sections scrolled over it.
    private var hero: some View {
        Backdrop(titleId: item.id)
            .overlay(Scrim(direction: .hero))
            .overlay(Theme.Colors.bg0.opacity(wasBelow ? 0.6 : 0))
            .animation(.easeOut(duration: Theme.Motion.backdrop), value: wasBelow)
    }

    // MARK: - The column

    private func column(_ proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // the lettering's box is fixed whatever fills it, the title's logo
            // or its name, so the facts under it never move
            TitleTreatment(
                titleId: item.id, name: item.name, maxWidth: Theme.Home.heroLogoWidth,
                maxHeight: Theme.Home.heroTitle, wrapped: Theme.Typography.displayWrapped)
                .frame(width: Theme.Layout.measure, height: Theme.Home.heroTitle, alignment: .bottomLeading)
            if let detail = model.detail {
                head(detail)
                TitleActions(item: item, model: model, detail: detail) {
                    guard wasBelow else { return }
                    wasBelow = false
                    withAnimation { proxy.scrollTo("top", anchor: .top) }
                }
            }
            if let error = model.error {
                Text(error)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.error)
                    .frame(maxWidth: Theme.Layout.measure, alignment: .leading)
                    .padding(.top, Theme.Space.s24)
                if model.detail == nil {
                    ActionButton(label: t("common.retry"), primary: true) {
                        model.error = nil
                        model.load()
                    }
                    .focused($retryFocused)
                    .onAppear { retryFocused = true }
                    .padding(.top, Theme.Space.s24)
                }
            } else if model.detail == nil {
                // the head and the actions' places, so the page does not jump when they land
                VStack(alignment: .leading, spacing: Theme.Space.s16) {
                    Capsule().fill(Theme.Colors.bg2).frame(width: 520, height: 24)
                    Capsule().fill(Theme.Colors.bg2).frame(width: Theme.Layout.measure, height: 24)
                        .padding(.top, Theme.Space.s24)
                    Capsule().fill(Theme.Colors.bg2).frame(width: 640, height: 24)
                    HStack(spacing: Theme.Space.s24) {
                        Capsule().fill(Theme.Colors.bg2).frame(width: 3 * RoundFace.size, height: RoundFace.size)
                        ForEach(0..<3, id: \.self) { _ in
                            Circle().fill(Theme.Colors.bg2).frame(width: RoundFace.size, height: RoundFace.size)
                        }
                    }
                    .padding(.top, Theme.Space.s24)
                }
                .padding(.top, Theme.Space.s24)
                .accessibilityElement()
                .accessibilityLabel(t("library.loading"))
            }
            if let note = model.note {
                Text(note)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .frame(maxWidth: Theme.Layout.measure, alignment: .leading)
            }
        }
        .padding(.horizontal, Theme.Layout.gutter)
        .frame(maxWidth: 1200, alignment: .leading)
    }

    /// What the title is, in the order the eye reads a programme: one line of
    /// facts, the marks of the copy that would play, then the synopsis.
    @ViewBuilder private func head(_ detail: TitleDetail) -> some View {
        let meta = model.metaLine
        if !meta.isEmpty {
            Text(meta)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.textSecondary)
                .fits(1, size: Theme.Typography.bodySize)
                .headingOverPicture()
                .frame(maxWidth: Theme.Layout.measure, alignment: .leading)
                .padding(.top, Theme.Space.s24)
        }
        let badges = model.badges
        if !badges.isEmpty {
            HStack(spacing: Theme.Space.s8) {
                ForEach(badges, id: \.self) { badge in
                    Text(badge)
                        .font(Theme.Typography.label)
                        .foregroundStyle(Theme.Colors.text)
                        .padding(.horizontal, Theme.Space.s8)
                        .padding(.vertical, Theme.Layout.badgeInset)
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous)
                                .strokeBorder(Theme.Colors.textSecondary, lineWidth: 1.5))
                        .fixedSize()
                }
            }
            .padding(.top, Theme.Space.s16)
            .accessibilityElement(children: .combine)
        }
        if let overview = detail.overview, !overview.isEmpty {
            // three lines and a press for the rest: the page only scrolls to
            // what the remote can land on, and a long summary is not one
            Button { readingOverview = true } label: {
                Text(overview)
                    .font(Theme.Typography.body)
                    .lineSpacing(40 - 34)
                    .fits(3, size: Theme.Typography.bodySize)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: Theme.Layout.measure, alignment: .leading)
            }
            .buttonStyle(FilledControlStyle(scale: 1, radius: Theme.Radius.card, horizontal: 16, vertical: 12, glass: false))
            // the fill's inset taken back, so the words line up with the title's
            .padding(.leading, -16)
            .padding(.top, Theme.Space.s16)
            .fullScreenCover(isPresented: $readingOverview) {
                OverviewReader(title: item.name, overview: overview)
            }
        }
    }
}

/// The sections under the fold, one shown at a time under a row of tabs the
/// way the system's own product pages are: the remote on a tab shows its
/// section, and down goes into it.
private struct DetailSections: View {
    let item: TitleItem
    let model: TitleDetailModel
    @State private var chosen: DetailSection?
    @FocusState private var tab: DetailSection?

    var body: some View {
        let sections = model.sections
        let shown = chosen.flatMap { sections.contains($0) ? $0 : nil } ?? sections[0]
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Space.s8) {
                ForEach(sections, id: \.self) { section in
                    Button { chosen = section } label: {
                        FocusReader { focused in
                            Text(t(section.labelKey))
                                .font(Theme.Typography.body.weight(.semibold))
                                .foregroundStyle(
                                    focused ? Theme.Colors.onWhite
                                        : section == shown ? Theme.Colors.white : Theme.Colors.textMuted)
                                .headingOverPicture()
                        }
                    }
                    .buttonStyle(FilledControlStyle(horizontal: Theme.Space.s24, vertical: Theme.Space.s8, glass: false))
                    .accessibilityAddTraits(section == shown ? .isSelected : [])
                    .focused($tab, equals: section)
                }
            }
            // the tabs' fill taken back, so the first word lines up with the column
            .padding(.leading, Theme.Layout.gutter - Theme.Space.s24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .focusSection()
            .onChange(of: tab) { before, now in
                guard let now else { return }
                // coming into the row lands on the section shown; moving along it shows each
                if before == nil, now != shown { tab = shown } else { chosen = now }
            }
            Group {
                switch shown {
                case .episodes: DetailSeasons(item: item, model: model)
                case .cast: CastRow(people: model.people)
                case .saga: PosterRow(items: model.saga)
                case .similar: PosterRow(items: model.related)
                case .info: DetailInfo(model: model)
                }
            }
            .padding(.top, Theme.Space.s24)
            .focusSection()
        }
        .animation(.easeOut(duration: Theme.Motion.dim), value: shown)
    }
}

enum DetailSection: Hashable {
    case episodes, cast, saga, similar, info

    var labelKey: String {
        switch self {
        case .episodes: "title.sectionEpisodes"
        case .cast: "title.sectionCast"
        case .saga: "title.sectionSaga"
        case .similar: "title.sectionSimilar"
        case .info: "title.sectionInfo"
        }
    }
}

/// The people credited, round, each a door to their page.
private struct CastRow: View {
    let people: [CastCredit]
    @Environment(Navigator.self) private var navigator

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: Theme.Face.gap) {
                ForEach(Array(people.prefix(20).enumerated()), id: \.offset) { _, person in
                    FaceCard(person: person) { navigator.openPerson(person.name) }
                }
            }
            .padding(.vertical, Theme.faceInset)
        }
        .contentMargins(.horizontal, Theme.Layout.gutter, for: .scrollContent)
        .scrollClipDisabled()
    }
}

/// Titles as posters, each opening its own page and holding the usual menu.
private struct PosterRow: View {
    let items: [TitleItem]
    @Environment(Navigator.self) private var navigator
    @Environment(HomeModel.self) private var home

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: Theme.Poster.gap) {
                ForEach(items, id: \.id) { item in
                    PosterCard(item: item) { navigator.open(item, from: .detail) }
                        .titleActions(
                            for: item, passesLeft: home.evening.passesLeft,
                            onOpenRow: { navigator.openRow($0) },
                            onPlay: { navigator.resume($0, from: .detail) })
                        .onPlayPauseCommand { navigator.resume(item, from: .detail) }
                }
            }
            .padding(.vertical, Theme.focusInset)
        }
        .contentMargins(.horizontal, Theme.Layout.gutter, for: .scrollContent)
        .scrollClipDisabled()
    }
}

/// The details: who made it, how it was received, what the file holds. Each
/// fact is a heading over its value, set in three columns; why the title is
/// here leads, as a door to the row it names.
private struct DetailInfo: View {
    let model: TitleDetailModel
    @Environment(Navigator.self) private var navigator

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s40) {
            if let taste = model.taste {
                VStack(alignment: .leading, spacing: Theme.Space.s8) {
                    heading(t("title.why"))
                    Button {
                        navigator.openRow(.tasteFacet(leader: taste.leader, leaderId: taste.leaderId))
                    } label: {
                        TasteReason(leader: taste.leader, font: Theme.Typography.caption, lines: 1)
                    }
                    .buttonStyle(FilledControlStyle(horizontal: Theme.Space.s16, vertical: Theme.Space.s8, glass: false))
                    // the fill's inset taken back, so the words line up with the heading
                    .padding(.leading, -Theme.Space.s16)
                    if !taste.rejected.isEmpty {
                        Text(t("why.shared", ["title": taste.rejected]))
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.text)
                        Text(t("why.sharedNote"))
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.textMuted)
                    }
                }
            }
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: Theme.Space.s40, alignment: .topLeading), count: 3),
                alignment: .leading, spacing: Theme.Space.s40
            ) {
                ForEach(model.facts, id: \.label) { fact in
                    VStack(alignment: .leading, spacing: Theme.Space.s8) {
                        heading(fact.label)
                        (Text(fact.value).foregroundStyle(Theme.Colors.text)
                            + Text(fact.source.isEmpty ? "" : " \(fact.source)").foregroundStyle(Theme.Colors.textMuted))
                            .font(Theme.Typography.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .padding(.horizontal, Theme.Layout.gutter)
        .padding(.top, Theme.Space.s16)
        .frame(maxWidth: Theme.Layout.screenWidth, alignment: .leading)
    }

    private func heading(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typography.label)
            .tracking(Theme.Typography.labelTracking)
            .textCase(.uppercase)
            .foregroundStyle(Theme.Colors.textMuted)
    }
}

/// A show's seasons and the episodes of the one shown, reading the model
/// itself so that only a change to them redraws the list. The seasons are a
/// row of pills over a row of episodes, both across the whole screen.
private struct DetailSeasons: View {
    let item: TitleItem
    let model: TitleDetailModel
    @Environment(Navigator.self) private var navigator
    @FocusState private var pill: String?

    var body: some View {
        if let shown = model.shownSeason { seasons(shown) }
    }

    private func play(_ episode: EpisodeRef, from start: Double) {
        navigator.play(
            titleId: item.id, fileId: episode.fileId, title: item.name,
            startAt: start, landOn: item, from: navigator.proposer(of: item.id))
    }

    @ViewBuilder private func seasons(_ shown: SeasonGroup) -> some View {
        let groups = model.seasons
        VStack(alignment: .leading, spacing: 0) {
            if groups.count > 1 {
                ScrollView(.horizontal) {
                    HStack(spacing: Theme.Space.s16) {
                        ForEach(groups, id: \.key) { group in
                            ActionButton(label: group.name, primary: group.key == shown.key) {
                                model.picked = group.key
                            }
                            .accessibilityAddTraits(group.key == shown.key ? .isSelected : [])
                            .focused($pill, equals: group.key)
                        }
                    }
                    .padding(.vertical, Theme.Space.s8)
                }
                .contentMargins(.horizontal, Theme.Layout.gutter, for: .scrollContent)
                .scrollClipDisabled()
                .focusSection()
                // the remote coming in from above or below lands on the season
                // shown, not on whichever pill is nearest; moving along shows each,
                // so down always goes into the season the remote is on
                .onChange(of: pill) { before, now in
                    guard let now else { return }
                    if before == nil, now != shown.key { pill = shown.key } else { model.picked = now }
                }
            }
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    // lazy: a long season builds the episodes near the screen
                    LazyHStack(alignment: .top, spacing: Theme.Space.s40) {
                        ForEach(shown.episodes, id: \.fileId) { episode in
                            EpisodeCard(episode: episode, upNext: episode.fileId == model.upNext?.fileId) {
                                play(episode, from: episode.resumePositionSecs)
                            }
                            .id(episode.fileId)
                            // a press plays the episode; a press held opens what else
                            // can be done with it
                            .contextMenu { menu(episode) }
                        }
                    }
                    .padding(.vertical, Theme.wideInset)
                }
                .contentMargins(.horizontal, Theme.Layout.gutter, for: .scrollContent)
                .scrollClipDisabled()
                .focusSection()
                // the season opens on the episode up next, at the row's start
                .onAppear { scrollToUpNext(proxy, in: shown) }
                .onChange(of: shown.key) { scrollToUpNext(proxy, in: shown) }
            }
        }
    }

    private func scrollToUpNext(_ proxy: ScrollViewProxy, in season: SeasonGroup) {
        let upNext = season.episodes.first { $0.fileId == model.upNext?.fileId } ?? season.episodes.first
        if let upNext { proxy.scrollTo(upNext.fileId, anchor: .leading) }
    }

    @ViewBuilder private func menu(_ episode: EpisodeRef) -> some View {
        if episode.resumePositionSecs > 0 {
            Button(t("hold.resume")) { play(episode, from: episode.resumePositionSecs) }
            Button(t("hold.playFromStart")) { play(episode, from: 0) }
        } else {
            Button(t("hold.play")) { play(episode, from: 0) }
        }
        Button(t(episode.watched ? "hold.unwatched" : "hold.watched")) {
            model.markEpisodes([episode.fileId], watched: !episode.watched)
        }
        let before = model.unwatched(upTo: episode)
        if before.count > 1 {
            Button(t("hold.watchedUpTo", ["count": String(before.count)])) {
                model.markEpisodes(before, watched: true)
            }
        }
    }
}

/// Notes the remote reaching the sections, for the page to scroll to them,
/// and for the actions to scroll it back to its top when it comes up again.
private struct BelowFollower: View {
    let below: FocusState<Bool>.Binding
    @Binding var wasBelow: Bool

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .onChange(of: below.wrappedValue) { _, now in if now { wasBelow = true } }
    }
}

/// The title's actions, owning the focus that moves between them: a move
/// from one button to the next redraws this block and not the page. One
/// white pill plays, the only bright thing on the page; the rest are round
/// buttons beside it, each named under itself while the remote is on it,
/// the last opening everything else.
private struct TitleActions: View {
    let item: TitleItem
    let model: TitleDetailModel
    let detail: TitleDetail
    /// The remote came into the actions, from below or from nowhere.
    let onArrive: () -> Void
    @Environment(Navigator.self) private var navigator
    @FocusState private var action: TitleAction?
    @State private var placed = false
    /// Set aside for tonight from this page, which the core does not say back.
    @State private var deferred = false

    var body: some View {
        HStack(spacing: Theme.Space.s24) {
            if let fileId = model.startFileId { primary(fileId: fileId) }
            if model.trailer != nil {
                RoundAction(symbol: "play.rectangle", label: t("title.trailer")) { model.openTrailer() }
                    .focused($action, equals: .trailer)
            }
            RoundAction(
                symbol: detail.inWatchlist ? "checkmark" : "plus",
                label: t(detail.inWatchlist ? "title.inList" : "title.addToList"), on: detail.inWatchlist
            ) { model.toggleWatchlist() }
                .focused($action, equals: .watchlist)
            RoundAction(
                symbol: detail.watched ? "eye.fill" : "eye",
                label: t(detail.watched ? "title.seen" : "title.markWatched"), on: detail.watched
            ) { model.toggleWatched() }
                .focused($action, equals: .watched)
            more
        }
        .padding(.top, Theme.Space.s40)
        // the name a round button shows under itself while focused
        .padding(.bottom, Theme.Space.s16 + ceil(Theme.Typography.captionSize * 1.2))
        // across the column: up or down from anywhere along it lands in the row
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
        .defaultFocus($action, model.firstFocus)
        .onChange(of: action) { _, now in if now != nil { onArrive() } }
        .onAppear {
            // once: a return from a level above keeps the button it left
            guard !placed else { return }
            placed = true
            action = model.firstFocus
        }
    }

    /// The one large button: where the title is left off, with how far in
    /// and what is left, or its start.
    private func primary(fileId: Int64) -> some View {
        let code = Format.episodeCode(season: model.upNext?.season, episode: model.upNext?.episode)
        let resuming = model.canResume
        let resumeAt = model.resumeAt
        let time = Format.clock(resumeAt, withHours: resumeAt >= 3600)
        let label: String
        let spoken: String
        if resuming {
            label = code.isEmpty ? t("hold.resume") : t("title.resumeEpisodeShort", ["episode": code])
            spoken = code.isEmpty
                ? t("title.resume", ["time": time])
                : t("title.resumeEpisode", ["episode": code, "time": time])
        } else {
            label = code.isEmpty ? t("title.play") : t("title.playEpisode", ["episode": code])
            spoken = label
        }
        let left = (model.upNext?.resumeDurationSecs ?? 0) - resumeAt
        return Button { play(fileId, at: resuming ? resumeAt : 0) } label: {
            HStack(spacing: Theme.Space.s16) {
                Image(systemName: "play.fill").font(.system(size: 26, weight: .semibold))
                Text(label).font(Theme.Typography.headline).fits(1, size: Theme.Typography.headlineSize)
                if resuming, let played = model.played {
                    ZStack(alignment: .leading) {
                        Capsule().fill(.tertiary)
                        Capsule().fill(.primary).frame(width: 96 * played)
                    }
                    .frame(width: 96, height: 6)
                    if left > 0 {
                        Text(t("title.remaining", ["time": Format.runtime(left)]))
                            .font(Theme.Typography.caption)
                            .fixedSize()
                    }
                }
            }
            // never narrower than three of the round buttons: the eye finds it first
            .frame(minWidth: 3 * RoundFace.size, minHeight: RoundFace.size)
        }
        .buttonStyle(PlayButtonStyle())
        .accessibilityLabel(spoken)
        .focused($action, equals: resuming ? .resume : .play)
    }

    /// Everything that is not done every time: the start of a title left
    /// off, the copy to play, the verdict, and setting it aside for tonight.
    private var more: some View {
        Menu {
            if let fileId = model.startFileId, model.canResume {
                Button(t("hold.playFromStart"), systemImage: "arrow.counterclockwise") { play(fileId, at: 0) }
            }
            if detail.versions.count > 1, let start = model.startFileId {
                Picker(selection: Binding(get: { start }, set: { model.chosenFileId = $0 })) {
                    ForEach(detail.versions, id: \.fileId) { version in
                        Text(Format.version(version)).tag(version.fileId)
                    }
                } label: {
                    Label(t("title.versions"), systemImage: "square.stack")
                }
                .pickerStyle(.menu)
            }
            Section(t("title.groupVerdict")) {
                verdict(.loved, label: "title.loveVerb", symbol: "heart")
                verdict(.up, label: "title.likeVerb", symbol: "hand.thumbsup")
                verdict(.down, label: "title.dislikeVerb", symbol: "hand.thumbsdown")
            }
            Button(t(deferred ? "title.deferred" : "tonight.notTonight"), systemImage: deferred ? "moon.fill" : "moon") {
                setAside()
            }
            .disabled(deferred)
        } label: {
            RoundFace(symbol: "ellipsis", label: t("title.more"))
        }
        .buttonStyle(CardButtonStyle(shadow: false))
        .accessibilityLabel(t("title.more"))
        .focused($action, equals: .more)
    }

    /// A verdict ticked once given; a second press takes it back.
    private func verdict(_ value: ApiVerdict, label: String, symbol: String) -> some View {
        Toggle(isOn: Binding(
            get: { detail.verdict == value },
            set: { model.setVerdict($0 ? value : nil) }
        )) {
            Label(t(label), systemImage: symbol)
        }
    }

    private func setAside() {
        guard !deferred else { return }
        let id = item.id, tz = Format.tzOffsetSecs
        Task {
            let done = await CoreClient.run {
                Result { try CoreClient.shared.tonightDefer(titleId: id, tzOffsetSecs: tz) }
            }
            switch done {
            case .success:
                deferred = true
                NotificationCenter.default.post(name: .watchStateChanged, object: nil)
            case .failure:
                model.note = t("hold.notTonightNone")
            }
        }
    }

    private func play(_ fileId: Int64, at start: Double) {
        navigator.play(
            titleId: item.id, fileId: fileId, title: item.name, startAt: start, landOn: item,
            from: navigator.proposer(of: item.id))
    }
}

/// The play pill: white at rest, the one bright thing on the page, and
/// lifted with its shadow under the remote.
private struct PlayButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PlayButtonBody(configuration: configuration)
    }
}

private struct PlayButtonBody: View {
    let configuration: ButtonStyle.Configuration
    @Environment(\.isFocused) private var focused

    var body: some View {
        configuration.label
            .foregroundStyle(Theme.Colors.onWhite)
            .padding(.horizontal, Theme.Space.s40)
            .background(Capsule().fill(Theme.Colors.white))
            .shadow(
                color: .black.opacity(focused ? Theme.Depth.focusOpacity : Theme.Depth.restOpacity),
                radius: focused ? Theme.Depth.focusRadius : Theme.Depth.restRadius,
                y: focused ? Theme.Depth.focusY : Theme.Depth.restY)
            .scaleEffect(focused ? Theme.Focus.poster : 1)
            .animation(.easeOut(duration: Theme.Motion.focus), value: focused)
    }
}

enum TitleAction: Hashable {
    case resume, play, trailer, watched, watchlist, more
}

/// A line of the facts table: the quantity, and who measured it.
struct Fact {
    let label: String
    let value: String
    var source = ""
}

struct SeasonGroup {
    let season: UInt16?
    let episodes: [EpisodeRef]

    /// The specials have no number and are still one of the choices.
    var key: String { season.map(String.init) ?? "specials" }
    var name: String { season.map { t("title.season", ["number": String($0)]) } ?? t("title.specials") }
}

/// What the page holds and how it changes: every core call runs off the
/// main actor and lands here.
@MainActor
@Observable
final class TitleDetailModel {
    let item: TitleItem
    var detail: TitleDetail?
    var upNext: EpisodeRef?
    /// The copy the viewer picked on this page; nil plays the one the core leads with.
    var chosenFileId: Int64?
    var taste: TitleTasteInfo?
    var error: String?
    var note: String?
    var trailer: String?
    var similar: [TitleItem] = []
    /// The episodes by season, grouped off the main actor as they land.
    private(set) var seasons: [SeasonGroup] = []
    var genre: [TitleItem] = []
    var cast: [TitleItem] = []
    var saga: [TitleItem] = []
    var picked: String?
    /// Whether the credits' faces are all the page will get: a face asked
    /// for while its server is still being asked would stay missing.
    private var facesLearned = false
    private var loaded = false
    private var trailerPoll: Task<Void, Never>?
    /// Eight seconds on the page is read as interest in the title, once per page.
    private var dwell: Task<Void, Never>?
    private var dwelt = false

    private let core: LexisCore

    init(item: TitleItem, core: LexisCore = CoreClient.shared) {
        self.item = item
        self.core = core
    }

    // MARK: Derived

    var resumeAt: Double { upNext?.resumePositionSecs ?? 0 }
    /// Only the copy that was left off resumes: another cut has no such moment.
    var canResume: Bool { upNext != nil && upNext?.fileId == startFileId && resumeAt > 0 }
    var startFileId: Int64? { chosenFileId ?? upNext?.fileId ?? item.firstFileId }

    /// The picture and sound of the copy that would play.
    var shownMedia: TitleMedia? {
        detail?.versions.first { $0.fileId == startFileId }?.media ?? detail?.media
    }

    var firstFocus: TitleAction {
        guard startFileId != nil else { return .watched }
        return canResume ? .resume : .play
    }

    /// How far in the viewer is, from the up-next episode alone.
    var played: Double? {
        guard let upNext, upNext.resumePositionSecs > 0, upNext.resumeDurationSecs > 0 else { return nil }
        return min(1, upNext.resumePositionSecs / upNext.resumeDurationSecs)
    }

    /// Genre, year, length and who directed it: one line, the way a
    /// programme sets it. A show counts its seasons instead of a length.
    var metaLine: String {
        guard let detail else { return "" }
        var parts: [String] = []
        if !detail.genres.isEmpty { parts.append(detail.genres.prefix(2).map(Format.genre).joined(separator: ", ")) }
        if let year = item.year { parts.append(String(year)) }
        // a show's runtime is one file's, which says nothing of the show
        if item.kind == .movie, detail.runtimeSecs > 0 { parts.append(Format.runtime(detail.runtimeSecs)) }
        if item.kind == .show, seasons.count > 1 {
            parts.append(t("title.seasonCount", ["n": String(seasons.count)]))
        }
        if let director = detail.directors.first { parts.append(director.name) }
        return parts.joined(separator: "  ·  ")
    }

    /// The marks of the copy that would play: its definition, its range, its
    /// sound, and whether it speaks and is subtitled in the viewer's language.
    var badges: [String] {
        guard let media = shownMedia else { return [] }
        var out: [String] = []
        switch media.videoResolution {
        case "": break
        case "4k": out.append("4K")
        case "sd": out.append("SD")
        default: out.append("HD")
        }
        if media.dynamicRange == "dolby_vision" { out.append("DOLBY VISION") }
        else if !media.dynamicRange.isEmpty { out.append("HDR") }
        if media.atmos { out.append("ATMOS") }
        else if media.audioChannels > 2 { out.append("\(media.audioChannels - 1).1") }
        let own = I18n.shared.current.rawValue
        if media.audioLanguages.contains(own) { out.append(t("title.badgeOwnAudio")) }
        if media.subtitleLanguages.contains(own) { out.append(t("title.badgeSubtitles")) }
        return out
    }

    /// The details section, in reading order: the people, the reception,
    /// then what the file holds.
    var facts: [Fact] {
        guard let detail else { return [] }
        var out: [Fact] = []
        let names = { (people: [CastCredit]) in people.map(\.name).joined(separator: ", ") }
        if !detail.directors.isEmpty { out.append(Fact(label: t("title.directedBy"), value: names(detail.directors))) }
        if !detail.writers.isEmpty { out.append(Fact(label: t("title.writing"), value: names(detail.writers))) }
        if !detail.composers.isEmpty { out.append(Fact(label: t("title.music"), value: names(detail.composers))) }
        if !detail.tones.isEmpty {
            out.append(Fact(label: t("title.tone"), value: detail.tones.map { t("tone.\($0)").localizedCapitalized }.joined(separator: ", ")))
        }
        if let critics = Format.score(detail.critics) {
            out.append(Fact(label: t("title.critics"), value: critics.value, source: critics.source))
        }
        if let audience = Format.score(detail.audience) {
            out.append(Fact(label: t("title.audience"), value: audience.value, source: audience.source))
        }
        if detail.watched, detail.plays > 1 {
            out.append(Fact(label: t("title.seen"), value: t("title.seenCount", ["count": String(detail.plays)])))
        }
        let media = shownMedia
        if let media {
            let codec: String? = switch media.videoCodec {
            case "": nil
            case "h264": "H.264"
            case "hevc", "h265": "HEVC"
            default: media.videoCodec.uppercased()
            }
            let video = (Format.badges(media).filter { $0 != "ATMOS" } + [codec].compactMap { $0 }).joined(separator: ", ")
            if !video.isEmpty { out.append(Fact(label: t("title.video"), value: video)) }
        }
        if let sound = Format.audioLine(media) { out.append(Fact(label: t("title.sound"), value: sound)) }
        let languages = { (codes: [String]) in
            codes.filter { $0 != "mul" }.map(I18n.shared.languageName).joined(separator: ", ")
        }
        if let media, !languages(media.audioLanguages).isEmpty {
            out.append(Fact(label: t("title.languages"), value: languages(media.audioLanguages)))
        }
        if let media, !languages(media.subtitleLanguages).isEmpty {
            out.append(Fact(label: t("title.subtitles"), value: languages(media.subtitleLanguages)))
        }
        if detail.versions.count > 1 {
            out.append(Fact(label: t("title.versions"), value: detail.versions.map(Format.version).joined(separator: "\n")))
        } else if let size = detail.versions.first?.sizeBytes, size > 0 {
            let locale = Locale(identifier: I18n.shared.current.rawValue)
            out.append(Fact(label: t("title.size"), value: Int64(size).formatted(.byteCount(style: .file).locale(locale))))
        }
        return out
    }

    /// The sections under the fold that have something to show, a show's
    /// episodes first and the details always.
    var sections: [DetailSection] {
        var out: [DetailSection] = item.kind == .show && !seasons.isEmpty ? [.episodes] : []
        if !people.isEmpty { out.append(.cast) }
        if !saga.isEmpty { out.append(.saga) }
        if !related.isEmpty { out.append(.similar) }
        out.append(.info)
        return out
    }

    /// The closest in kind first, then the same genre, then the same people,
    /// each title once.
    var related: [TitleItem] {
        var seen = Set(saga.map(\.id))
        return (similar + genre + cast).filter { seen.insert($0.id).inserted }
    }

    /// Everyone credited, each once, the crew named by their job.
    var people: [CastCredit] {
        guard let detail, facesLearned else { return [] }
        var seen: Set<String> = []
        var out: [CastCredit] = []
        let credited =
            detail.directors.map { CastCredit(personId: $0.personId, name: $0.name, character: t("title.roleDirector")) }
            + detail.cast
            + detail.writers.map { CastCredit(personId: $0.personId, name: $0.name, character: t("title.roleWriter")) }
            + detail.composers.map { CastCredit(personId: $0.personId, name: $0.name, character: t("title.roleComposer")) }
        for person in credited where seen.insert(person.name).inserted { out.append(person) }
        return out
    }

    /// Seasons in order, the specials last.
    nonisolated static func seasons(of episodes: [EpisodeRef]) -> [SeasonGroup] {
        var order: [UInt16?] = []
        var grouped: [String: [EpisodeRef]] = [:]
        for episode in episodes {
            let key = episode.season.map(String.init) ?? "specials"
            if grouped[key] == nil { order.append(episode.season) }
            grouped[key, default: []].append(episode)
        }
        order.sort { a, b in
            switch (a, b) {
            case (nil, _): false
            case (_, nil): true
            case (let a?, let b?): a < b
            }
        }
        return order.map { season in
            SeasonGroup(season: season, episodes: grouped[season.map(String.init) ?? "specials"]!)
        }
    }

    var shownSeason: SeasonGroup? {
        let groups = seasons
        if let picked, let group = groups.first(where: { $0.key == picked }) { return group }
        if let upNext, let group = groups.first(where: { $0.season == upNext.season }) { return group }
        return groups.first
    }

    // MARK: Loading

    /// Once per page: a return from a level above finds it as it was, and
    /// what a film or a mark moves is read again by `reload`.
    func load() {
        let id = item.id, kind = item.kind, core = core
        if !dwelt, dwell == nil {
            dwell = Task {
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { return }
                await CoreClient.run(on: CoreClient.slow) {
                    _ = try? core.recordInterest(titleId: id, kind: .detailDwell)
                }
                dwelt = true
            }
        }
        if !loaded {
            loaded = true
            Task {
                _ = await CoreClient.run { core.learnFaces(titleId: id) }
                facesLearned = true
            }
            Task {
                let first = await CoreClient.run {
                    Result { (try core.titleDetail(titleId: id), try core.upNext(titleId: id), try core.titleTaste(titleId: id)) }
                }
                switch first {
                case .success(let first): (detail, upNext, taste) = first
                case .failure(let failure):
                    error = Format.describe(failure)
                    loaded = false
                    return
                }
                if kind == .show {
                    let (similar, seasons) = await CoreClient.run {
                        (
                            (try? core.similarTitles(titleId: id)) ?? [],
                            TitleDetailModel.seasons(of: (try? core.episodes(titleId: id)) ?? [])
                        )
                    }
                    self.similar = similar
                    self.seasons = seasons
                } else {
                    let (similar, genre, cast, saga) = await CoreClient.run {
                        (
                            (try? core.similarTitles(titleId: id)) ?? [],
                            (try? core.sameGenre(titleId: id, kind: kind)) ?? [],
                            (try? core.sameCast(titleId: id, kind: kind)) ?? [],
                            (try? core.sameSaga(titleId: id, kind: kind)) ?? []
                        )
                    }
                    self.similar = similar
                    self.genre = genre
                    self.cast = cast
                    self.saga = saga
                }
            }
        }
        // The trailer is TMDB's answer rather than the index's: the first
        // open of a title finds the core still asking, and comes back for it.
        guard trailer == nil, trailerPoll == nil else { return }
        trailerPoll = Task {
            while !Task.isCancelled {
                guard let state = await CoreClient.run(on: CoreClient.slow, { try? core.trailerNow(titleId: id) })
                else { return }
                switch state {
                case .ready(let key):
                    trailer = key
                    return
                case .fetching:
                    try? await Task.sleep(for: .milliseconds(400))
                case .missing, .failed:
                    return
                }
            }
        }
    }

    func stop() {
        trailerPoll?.cancel()
        trailerPoll = nil
        dwell?.cancel()
        dwell = nil
    }

    /// The title's own state: all a verdict or a mark can change.
    func reload(episodesToo: Bool) {
        let id = item.id, core = core
        Task {
            let fetched = await CoreClient.run { () -> (TitleDetail, EpisodeRef?, [SeasonGroup]?)? in
                guard let detail = try? core.titleDetail(titleId: id) else { return nil }
                let upNext = try? core.upNext(titleId: id)
                var seasons: [SeasonGroup]?
                if episodesToo, let episodes = try? core.episodes(titleId: id) {
                    seasons = TitleDetailModel.seasons(of: episodes)
                }
                return (detail, upNext, seasons)
            }
            guard let fetched else { return }
            detail = fetched.0
            upNext = fetched.1
            if let seasons = fetched.2 { self.seasons = seasons }
        }
    }

    // MARK: Writes

    func toggleWatched() {
        guard detail != nil else { return }
        let id = item.id, core = core
        let watched = !detail!.watched
        detail!.watched = watched
        Task {
            do {
                try await CoreClient.run { try core.markWatched(titleId: id, watched: watched) }
            } catch {
                note = t("title.notSyncing", ["message": Format.describe(error)])
            }
            // A failed source writeback can still leave the local state saved.
            NotificationCenter.default.post(name: .watchStateChanged, object: nil)
            reload(episodesToo: true)
        }
    }

    /// Episodes marked watched, or unwatched, from a row held: the local state
    /// is saved even where the source refuses the write, which the note says.
    func markEpisodes(_ fileIds: [Int64], watched: Bool) {
        let core = core
        Task {
            do {
                try await CoreClient.run { try core.markEpisodesWatched(fileIds: fileIds, watched: watched) }
            } catch {
                note = t("title.notSyncing", ["message": Format.describe(error)])
            }
            NotificationCenter.default.post(name: .watchStateChanged, object: nil)
            reload(episodesToo: true)
        }
    }

    /// The episodes not yet watched from the show's first to `episode`, it
    /// included, in the order the seasons run.
    func unwatched(upTo episode: EpisodeRef) -> [Int64] {
        var ids: [Int64] = []
        for season in seasons {
            for each in season.episodes {
                if !each.watched { ids.append(each.fileId) }
                if each.fileId == episode.fileId { return ids }
            }
        }
        return ids
    }

    func toggleWatchlist() {
        guard detail != nil else { return }
        let id = item.id, core = core
        let on = !detail!.inWatchlist
        detail!.inWatchlist = on
        Task {
            do {
                try await CoreClient.run { try core.setWatchlist(titleId: id, on: on) }
                NotificationCenter.default.post(name: .watchStateChanged, object: nil)
            } catch {
                detail?.inWatchlist = !on
            }
        }
    }

    func setVerdict(_ next: ApiVerdict?) {
        guard detail != nil else { return }
        let id = item.id, core = core
        detail!.verdict = next
        Task {
            await CoreClient.run { _ = try? core.setVerdict(titleId: id, verdict: next) }
            reload(episodesToo: false)
        }
    }

    func openTrailer() {
        guard let trailer else { return }
        let app = UIApplication.shared
        app.open(URL(string: "youtube://www.youtube.com/watch?v=\(trailer)")!) { opened in
            guard !opened else { return }
            app.open(URL(string: "https://www.youtube.com/watch?v=\(trailer)")!) { opened in
                guard !opened else { return }
                Task { @MainActor in self.error = t("title.trailerUnavailable") }
            }
        }
    }
}

/// One episode as a card: its frame, veiled until someone has started it so
/// the row spoils nothing, and its words under it, which move down as the
/// frame lifts.
struct EpisodeCard: View {
    let episode: EpisodeRef
    let upNext: Bool
    let onPress: () -> Void

    private var veiled: Bool { !(episode.watched || episode.resumePositionSecs > 0) }
    private static let size = CGSize(width: Theme.Landscape.width, height: Theme.Landscape.height)

    var body: some View {
        Button(action: onPress) {
            FocusReader { focused in
                VStack(alignment: .leading, spacing: 0) {
                    still
                    words
                        .offset(y: focused ? Self.size.height * (Theme.Focus.lift - 1) / 2 : 0)
                        .animation(.easeOut(duration: Theme.Motion.focus), value: focused)
                }
                .frame(width: Self.size.width, alignment: .leading)
            }
        }
        .buttonStyle(CardButtonStyle(shadow: false))
        .accessibilityLabel(heading)
    }

    private var heading: String {
        let number = episode.episode.map(String.init) ?? ""
        guard !episode.title.isEmpty else { return number }
        return number.isEmpty ? episode.title : "\(number). \(episode.title)"
    }

    private var still: some View {
        ZStack {
            Theme.Colors.bg2
            ArtworkImage(kind: veiled ? .veiledStill(fileId: episode.fileId) : .still(fileId: episode.fileId)) {
                Text(episode.episode.map(String.init) ?? "")
                    .font(.system(size: Theme.Episode.plate, weight: .heavy))
                    .tracking(-1)
                    .foregroundStyle(Theme.Colors.textMuted)
            }
            if episode.resumePositionSecs > 0, episode.resumeDurationSecs > 0 {
                ResumeBar(progress: episode.resumePositionSecs / episode.resumeDurationSecs, size: Self.size)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .hoverEffect(.highlight)
    }

    private var words: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s8) {
            HStack(spacing: Theme.Space.s16) {
                if upNext {
                    Text(t("title.upNext")).fontWeight(.semibold).foregroundStyle(Theme.Colors.accent)
                } else if episode.watched {
                    Text(t("title.seen"))
                }
                if episode.runtimeSecs > 0 { Text(Format.runtime(episode.runtimeSecs)) }
            }
            .font(Theme.Typography.captionCompact)
            .textCase(.uppercase)
            .foregroundStyle(Theme.Colors.textMuted)
            Text(heading)
                .font(Theme.Typography.caption.weight(.semibold))
                .foregroundStyle(Theme.Colors.text)
                .fits(2)
            if !episode.summary.isEmpty {
                Text(episode.summary)
                    .font(Theme.Typography.captionCompact)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .fits(3, size: Theme.Typography.captionCompactSize)
                    // bars in place of the words: nothing to read, no blur pass
                    .redacted(reason: veiled ? .placeholder : [])
            }
        }
        .padding(.top, Theme.Space.s16)
        .frame(width: Self.size.width, alignment: .leading)
    }
}

/// A row that wraps: buttons of the width of their words, as many per line
/// as fit.
struct WrapLayout: Layout {
    var spacing: CGFloat
    var rowSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += rowHeight + rowSpacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: width == .infinity ? widest : width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += rowHeight + rowSpacing
                x = bounds.minX
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// A summary read whole: the remote scrolls it, Menu closes it.
private struct OverviewReader: View {
    let title: String
    let overview: String

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: Theme.Space.s24) {
                Text(title)
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.Colors.white)
                Text(overview)
                    .font(Theme.Typography.body)
                    .lineSpacing(40 - 34)
                    .foregroundStyle(Theme.Colors.text)
            }
            .frame(maxWidth: 1200, alignment: .leading)
            .padding(.vertical, Theme.Space.s64)
            .frame(maxWidth: .infinity)
        }
        // focusable, so a swipe scrolls text that holds no control
        .focusable()
        .background(Theme.Colors.bg0.opacity(0.94))
    }
}

/// A round glyph beside the play button, lit in the accent once it is in
/// effect. Its name shows under it while the remote is on it, drawn over the
/// row's foot so that no name moves the row.
private struct RoundFace: View {
    static let size: CGFloat = 76
    let symbol: String
    let label: String
    var on = false

    var body: some View {
        FocusReader { focused in
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(focused ? Theme.Colors.onWhite : on ? Theme.Colors.accent : Theme.Colors.text)
                .frame(width: Self.size, height: Self.size)
                .background {
                    ZStack {
                        GlassSurface(capsule: true, interactive: true, tint: on ? Theme.Glass.accented : Theme.Glass.control)
                        if focused { LitGlass(shape: Circle(), color: Theme.Colors.white) }
                    }
                }
                .scaleEffect(focused ? Theme.Focus.poster : 1)
                .overlay(alignment: .top) {
                    Text(label)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.white)
                        .fixedSize()
                        .headingOverPicture()
                        .offset(y: Self.size + Theme.Space.s16)
                        .opacity(focused ? 1 : 0)
                }
                .animation(.easeOut(duration: Theme.Motion.focus), value: focused)
        }
    }
}

private struct RoundAction: View {
    let symbol: String
    let label: String
    var on = false
    let action: () -> Void

    var body: some View {
        Button(action: action) { RoundFace(symbol: symbol, label: label, on: on) }
            .buttonStyle(CardButtonStyle(shadow: false))
            .accessibilityLabel(label)
    }
}

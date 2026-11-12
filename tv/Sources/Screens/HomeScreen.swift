import LexisCore
import SwiftUI
import UIKit

/// The tab the app opens on: the title under the remote, filling the screen
/// behind its own words, and under it a list of reasons.
///
/// The reason is the row's title, and the row says why it exists before it
/// says what is in it. The name itself is not a control: the cross should
/// only ever meet cards, so the rest of a reason is reached by carrying on
/// to the end of the row, where a last card opens it whole.
struct HomeScreen: View {
    let model: HomeModel
    @Environment(Navigator.self) private var navigator
    /// The one way forward an empty or failed home offers.
    @FocusState private var actionFocused: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            LitBackdrop(lit: model.lit)
            if let error = model.error {
                failure(error)
            } else if !model.loaded {
                VStack(alignment: .leading, spacing: 0) {
                    BarBand()
                    Spacer()
                    PlaceholderRails()
                        .padding(.bottom, Theme.Space.s64)
                }
            } else if model.lanes.isEmpty {
                empty
            } else {
                screen
            }
        }
        .onAppear {
            CoreClient.calls.async { _ = try? CoreClient.shared.recordHomeOpen() }
        }
        .task {
            if !model.loaded { model.load() }
            await model.tick()
        }
    }

    private var screen: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                // Eager, every reason in place: under a lazy stack the reason
                // below the screen is a filler the focus lands on, and the
                // remote's move then carries on past it. A reason far from the
                // one open is drawn empty, so nothing it holds is built.
                VStack(alignment: .leading, spacing: 0) {
                    BarBand()
                        .frame(width: Theme.Layout.screenWidth)
                        .id(LaneTop.bar)

                    ForEach(model.lanes) { lane in
                        VStack(alignment: .leading, spacing: 0) {
                            HeroRoom(lane: lane.index, lit: model.lit) {
                                // on the picture's side of the hero, clear of a title on
                                // two lines, so the first screen keeps its heights
                                if lane.index == 0, let item = model.review.first {
                                    ReviewLine(item: item, model: model)
                                }
                            }
                            Near(lane: lane.index, lit: model.lit) {
                                ReasonRow(
                                    lane: lane, passesLeft: model.evening.passesLeft,
                                    resume: model.resume, episodes: model.episodes, model: model)
                            }
                            .frame(height: Theme.Home.row, alignment: .bottom)
                        }

                        // ideas right under the head of the screen, for when
                        // none of it calls
                        if lane.index == model.moodLane, !model.moods.isEmpty {
                            MoodLane(
                                moods: model.moods, randomIds: model.hasTrio ? model.randomIds : [],
                                model: model)
                            // held close to the evening it offers another way into
                            .padding(.top, Theme.Space.s8)
                        }
                    }

                    Text(t("home.end"))
                        .font(Theme.Typography.label)
                        .tracking(Theme.Typography.labelTracking)
                        .textCase(.uppercase)
                        .foregroundStyle(Theme.Colors.textMuted)
                        .padding(.horizontal, Theme.Layout.gutter)
                        .padding(.top, Theme.Space.s64)
                }
                .padding(.bottom, Theme.Space.s64)
            }
            .scrollClipDisabled()
            .background { FocusFollower(model: model, proxy: proxy) }
        }
    }

    /// A library with nothing in it says why: no source yet, the first scan
    /// still running, or sources that hold nothing playable.
    private var empty: some View {
        let scan = BackgroundWork.shared.scan
        return VStack(spacing: 0) {
            BarBand()
            Spacer()
            VStack(spacing: Theme.Space.s16) {
                if !model.hasSources {
                    heading(t("home.welcomeTitle"), t("home.welcomeBody"))
                    ActionButton(label: t("settings.addSource"), glyph: .plus, primary: true) {
                        navigator.addSource()
                    }
                    .focused($actionFocused)
                    .padding(.top, Theme.Space.s24)
                } else if scan.running {
                    heading(t("home.scanningTitle"), t("home.scanningBody"))
                    HStack(spacing: Theme.Space.s16) {
                        ProgressView()
                        if scan.sourcesTotal > 0 {
                            Text(t("settings.scanProgress", [
                                "done": String(scan.sourcesDone), "total": String(scan.sourcesTotal),
                            ]) + (scan.currentSource.isEmpty ? "" : "  ·  \(scan.currentSource)"))
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.textSecondary)
                        }
                    }
                    .padding(.top, Theme.Space.s24)
                } else {
                    heading(t("home.emptyTitle"), t("home.emptyBody"))
                    ActionButton(label: t("settings.scanAll"), primary: true) {
                        BackgroundWork.shared.rescanIfStale(force: true)
                    }
                    .focused($actionFocused)
                    .padding(.top, Theme.Space.s24)
                }
            }
            .padding(.horizontal, Theme.Layout.gutter)
            Spacer()
        }
        .onAppear { actionFocused = true }
    }

    private func heading(_ title: String, _ body: String) -> some View {
        VStack(spacing: Theme.Space.s16) {
            Text(title)
                .font(Theme.Typography.title)
                .tracking(Theme.Typography.titleTracking)
                .foregroundStyle(Theme.Colors.white)
            Text(body)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.textMuted)
                .multilineTextAlignment(.center)
        }
    }

    private func failure(_ text: String) -> some View {
        VStack(spacing: 0) {
            BarBand()
            Spacer()
            VStack(spacing: Theme.Space.s16) {
                heading(t("home.failedTitle"), text)
                ActionButton(label: t("common.retry"), primary: true) { model.load() }
                    .focused($actionFocused)
                    .padding(.top, Theme.Space.s24)
            }
            .padding(.horizontal, Theme.Layout.gutter)
            Spacer()
        }
        .onAppear { actionFocused = true }
    }
}

/// Which card the remote is on. The row is part of it because two rows can
/// hold the same title and the hero must follow the card, not the title.
private struct Slot: Hashable {
    let row: Int
    let card: Int
}

private struct SlotKey: FocusedValueKey {
    typealias Value = Slot
}

extension FocusedValues {
    /// The card under the remote, published by the card itself.
    fileprivate var homeSlot: Slot? {
        get { self[SlotKey.self] }
        set { self[SlotKey.self] = newValue }
    }
}

/// Follows the remote from beside the list rather than from inside it.
///
/// A focus state held by the screen redraws the screen at every press of
/// the cross: the stack, every reason built and every card in them, which is
/// what made a step along a row stutter. Read here, a press redraws an empty
/// view and nothing else; the cards publish where they are as a focused
/// value, which is nil while the remote is on anything that is not a card.
private struct FocusFollower: View {
    let model: HomeModel
    let proxy: ScrollViewProxy
    @Environment(Navigator.self) private var navigator
    @FocusedValue(\.homeSlot) private var slot

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .onChange(of: slot) { old, now in
                guard let now else { return }
                if !navigator.browsing { navigator.browsing = true }
                guard let items = model.lanes.first(where: { $0.index == now.row })?.items,
                    items.indices.contains(now.card)
                else { return }
                let item = items[now.card]
                // Along a row the screen stays put, and a scroll per card would
                // fight the row's own: the title lands, a sweep's once.
                guard now.row != old?.row else { return model.lit.light(item) }
                // The title before the room: the room opening reads it once.
                model.lit.show(item)
                let row = now.row
                model.lit.move(to: row) { proxy.scrollTo(LaneTop(lane: row), anchor: LaneTop.anchor) }
            }
            // Back at the bar, the screen is its first one again: scrolled to
            // the top, which the open reason's own place is not.
            .onChange(of: navigator.browsing) { _, now in
                guard !now else { return }
                // with a title of its own, not the one the remote left further down
                if model.lit.lane != 0, let first = model.lanes.first?.items.first { model.lit.show(first) }
                model.lit.move(to: 0) { proxy.scrollTo(LaneTop.bar, anchor: .top) }
            }
    }
}

/// Where the screen scrolls to for a reason: the top of its hero.
private struct LaneTop: Hashable {
    let lane: Int

    /// The open reason's room starts this far under the top of the screen:
    /// the bar is scrolled off, and its posters' foot stays above the band
    /// tvOS keeps a focused view within, 180 points short of the screen's
    /// foot, so a step along a reason never moves the screen.
    static let top: CGFloat = 24
    static let anchor = UnitPoint(x: 0, y: top / Theme.Layout.screenHeight)

    /// The top of the screen, where the bar is.
    static let bar = LaneTop(lane: -1)
}

/// The room above a reason for the hero, open over the reason the remote is
/// on and shut over the others, so the hero follows the remote down the
/// screen. Only the open one draws a hero: one is alive at a time.
///
/// It reads the lane off `lit` itself, and the title only while open: read
/// from the screen's body, a move between reasons would rebuild every reason,
/// and a shut room is not redrawn by a move along a row. The title is handed
/// to the hero rather than observed by it: a hero observing `lit` itself,
/// inserted by the move that also changes the title, keeps the one it was
/// built with.
private struct HeroRoom<Extra: View>: View {
    let lane: Int
    let lit: Lit
    @ViewBuilder let extra: Extra

    var body: some View {
        let open = lit.lane == lane
        ZStack(alignment: .bottom) {
            if open {
                Hero(item: lit.item, door: lane == 0)
                    .frame(height: Theme.Home.hero, alignment: .bottom)
                    .overlay(alignment: .topTrailing) { extra }
                    .padding(.bottom, Theme.Home.heroGap)
                    // revealed by the room opening, never faded: a fade redraws
                    // its shadowed words on the CPU at every frame of the move
                    .transition(.identity)
            }
        }
        // shut, the slot is the gap between two reasons
        .frame(
            width: Theme.Layout.screenWidth,
            height: open ? Theme.Home.hero + Theme.Home.heroGap : Theme.Home.gap, alignment: .bottom
        )
        .clipped()
        .overlay(alignment: .top) { Color.clear.frame(height: 0).id(LaneTop(lane: lane)) }
    }
}

/// A reason built only within `reach` of the one open, and nothing but its
/// room elsewhere: the reason the remote reaches next is always a real one,
/// and no far reason's cards or pictures are made. It reads the lane itself,
/// as the hero's room does.
///
/// The reach follows the lane once the screen has stopped moving, not with
/// the move: a reason built or torn down in the frame the scroll starts
/// costs that frame. The ones either side of the open one are
/// always there, so the next press never waits on it.
private struct Near<Content: View>: View {
    let lane: Int
    let lit: Lit
    @ViewBuilder let content: Content

    /// Two each way, so a remote held down finds the next one already built.
    private static var reach: Int { 2 }

    var body: some View {
        if abs(lit.lane - lane) <= 1 || abs(lit.settled - lane) <= Near.reach {
            content
        } else {
            Color.clear
        }
    }
}

/// One reason: its name, what it holds, and the screen it opens into from
/// the card at its end.
struct HomeLane: Identifiable, Equatable {
    let index: Int
    let title: String
    let items: [TitleItem]
    /// What proposed each of `items`, in the same order.
    let surfaces: [LaunchSurface]
    let reason: HomeReason
    /// Where each of `items` stands in its saga, on the sagas' row alone.
    var places: [SagaPlace] = []
    /// The evening's roles nothing could fill, said after its cards, which
    /// are the first `cards` of `items`.
    var gaps: [TonightGap] = []
    var cards = 0

    var id: Int { index }
}

/// A reason drawn: its name, and seven posters of which the seventh hangs
/// off the right edge.
///
/// Equatable on what it draws, its actions reached through the model and the
/// navigator: a closure never compares equal, and would redraw it with the screen.
private struct ReasonRow: View, Equatable {
    let lane: HomeLane
    let passesLeft: UInt32
    let resume: [Int64: Resume]
    let episodes: [Int64: String]
    let model: HomeModel
    @Environment(Navigator.self) private var navigator
    /// Bound on the first card alone, so only a move onto or off it redraws
    /// the row.
    @FocusState private var firstFocused: Bool

    nonisolated static func == (a: ReasonRow, b: ReasonRow) -> Bool {
        a.lane == b.lane && a.passesLeft == b.passesLeft && a.resume == b.resume && a.episodes == b.episodes
            && a.model === b.model
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            name
            .padding(.horizontal, Theme.Layout.gutter)
            .frame(height: Theme.Home.rowLabel, alignment: .bottom)
            .padding(.bottom, Theme.Home.labelGap)

            ScrollView(.horizontal) {
                LazyHStack(spacing: Theme.Reason.gap) {
                    ForEach(Array(lane.items.enumerated()), id: \.offset) { slot, item in
                        let surface = lane.surfaces[slot]
                        let card = ReasonCard(
                            item: item, resume: resume[item.id], episode: episodes[item.id],
                            place: lane.places.indices.contains(slot) ? lane.places[slot] : nil
                        ) { navigator.open(item, from: surface) }
                        Group {
                            if slot == 0 { card.focused($firstFocused) } else { card }
                        }
                        .focusedValue(\.homeSlot, Slot(row: lane.index, card: slot))
                        .titleActions(
                            for: item, reason: lane.reason, count: lane.items.count,
                            passesLeft: passesLeft, onOpenRow: { navigator.openRow($0) },
                            onPlay: { navigator.resume($0, from: surface) })
                        .onPlayPauseCommand { navigator.resume(item, from: surface) }
                        if slot == lane.cards - 1 {
                            ForEach(lane.gaps, id: \.self) { GapTile(gap: $0) }
                        }
                    }
                    ReasonMoreCard { navigator.openRow(lane.reason) }
                }
                // both sides: scrolled to its end, the last card stops a
                // gutter short of the edge instead of growing past it
                .padding(.horizontal, Theme.Layout.gutter)
                .padding(.vertical, Theme.Reason.inset)
            }
            .scrollClipDisabled()
        }
        .focusSection()
        // Down from the bar starts the first reason at its start, on the
        // title the hero already shows; between reasons the cross keeps its
        // column.
        .defaultFocus(
            $firstFocused, true,
            priority: lane.index == 0 && !navigator.browsing ? .userInitiated : .automatic)
    }

    /// The name of the reason. It is not a control: the cross meets cards and
    /// nothing else, and a reason is opened from the card at the end of its row.
    private var name: some View {
        RowHeading(title: lane.title, subtitle: lane.reason.railSubtitle)
    }
}

/// A role of the evening nothing could fill, standing where its card would,
/// saying why. Not focusable: there is nothing to do with it.
private struct GapTile: View {
    let gap: TonightGap

    var body: some View {
        VStack(spacing: Theme.Space.s16) {
            Text(role)
                .font(Theme.Typography.label)
                .tracking(Theme.Typography.labelTracking)
                .textCase(.uppercase)
                .foregroundStyle(Theme.Colors.textSecondary)
                .fits(1, size: Theme.Typography.labelSize)
            Text(t(gap.reason == .noTime ? "tonight.gapNoTime" : "tonight.gapExhausted"))
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.text)
                .multilineTextAlignment(.center)
                .fits(3)
        }
        .padding(.horizontal, Theme.Space.s24)
        .frame(width: Theme.Reason.width, height: Theme.Reason.height)
        // the regular glass: over a bright backdrop the clear one lets the
        // picture through the words
        .background(GlassSurface(radius: Theme.Radius.poster, tint: Theme.Glass.panel))
        .padding(.bottom, Theme.Reason.caption)
        .accessibilityElement(children: .combine)
    }

    private var role: String {
        switch gap.role {
        case .safeBet: t("tonight.safeBet")
        case .gamble: t("tonight.gamble")
        case .familiar: t("tonight.familiar")
        }
    }
}

/// The morning after: one title finished last night and not yet judged,
/// asked about once, discreetly. Its name opens it; "later" puts the evening
/// aside.
private struct ReviewLine: View, Equatable {
    let item: TitleItem
    let model: HomeModel
    @Environment(Navigator.self) private var navigator

    nonisolated static func == (a: ReviewLine, b: ReviewLine) -> Bool { a.item == b.item && a.model === b.model }

    /// What the hero's column leaves of the screen's width.
    private static let width = Theme.Layout.screenWidth - Hero.column - 2 * Theme.Layout.gutter

    var body: some View {
        VStack(alignment: .trailing, spacing: Theme.Space.s8) {
            Button { navigator.open(item, from: .review) } label: {
                // the glass buttons carry their own ground; only these words lie on the picture
                Text(t("review.line", ["title": item.name])).fits(1).headingOverPicture()
            }
            .buttonStyle(ReviewLine.compact(glass: false))
            HStack(spacing: Theme.Space.s8) {
                Button(t("review.down")) { model.judge(item, .down) }
                Button(t("review.up")) { model.judge(item, .up) }
                Button(t("review.loved")) { model.judge(item, .loved) }
                Button(t("review.later")) { model.later() }
            }
            .buttonStyle(ReviewLine.compact(glass: true))
        }
        .font(Theme.Typography.caption)
        .frame(maxWidth: ReviewLine.width, alignment: .trailing)
        .padding(.horizontal, Theme.Layout.gutter)
        .padding(.top, Theme.Space.s16)
        .focusSection()
    }

    private static func compact(glass: Bool) -> FilledControlStyle {
        FilledControlStyle(horizontal: Theme.Space.s16, vertical: Theme.Space.s8, glass: glass)
    }
}

/// Ideas when nothing on the screen calls: one tile a mood, its posters
/// fanned out of the films it holds, and one last tile that plays a card of
/// the evening at random.
private struct MoodLane: View, Equatable {
    let moods: [MoodShelf]
    let randomIds: [Int64]
    let model: HomeModel
    @Environment(Navigator.self) private var navigator

    nonisolated static func == (a: MoodLane, b: MoodLane) -> Bool {
        a.moods == b.moods && a.randomIds == b.randomIds && a.model === b.model
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RowHeading(title: t("mood.title"))
                .padding(.horizontal, Theme.Layout.gutter)
                .frame(height: Theme.Home.rowLabel, alignment: .bottom)
            ScrollView(.horizontal) {
                LazyHStack(spacing: Theme.Reason.gap) {
                    ForEach(moods, id: \.key) { mood in
                        MoodTile(key: mood.key, titleIds: mood.titleIds) { navigator.openRow(.mood(key: mood.key)) }
                    }
                    if !randomIds.isEmpty {
                        MoodTile(key: nil, titleIds: randomIds) { model.playSomething(navigator) }
                    }
                }
                .padding(.horizontal, Theme.Layout.gutter)
                // what a focused tile grows by, and no more
                .padding(.vertical, ceil(MoodTile.size.height * (Theme.Focus.lift - 1) / 2) + Theme.Space.s16)
            }
            .scrollClipDisabled()
        }
        .focusSection()
    }
}

/// A mood as a card in its own colour: its name, what it is for, and three
/// of its posters whole along the foot. Under the remote the posters rise
/// and drift, each on its own beat; a shuffling one deals them round, each
/// sliding to the next place while the new one grows in.
private struct MoodTile: View {
    let key: String?
    let titleIds: [Int64]
    let action: () -> Void
    /// How many turns the shuffle has dealt: the posters start that far along.
    @State private var turn = 0
    /// Follows the focus a beat behind it, so the sway starts from where the
    /// rise left the posters.
    @State private var drifting = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    fileprivate static let size = CGSize(width: 340, height: 290)
    private static let poster = CGSize(width: 88, height: 132)
    /// The colour each mood's card is drawn in, as a hue; the shuffle's is its own.
    private static let hues: [String: Double] = [
        "light": 42, "gripping": 4, "moving": 330, "chills": 205, "escape": 150, "mind": 265, "cosy": 24,
    ]

    var body: some View {
        Button(action: action) {
            FocusReader { focused in
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                        .fill(colour(focused: focused))
                    VStack(alignment: .leading, spacing: Theme.Space.s8) {
                        HStack(spacing: Theme.Space.s16) {
                            if key == nil { Image(systemName: "shuffle") }
                            Text(key.map { t("mood.\($0)") } ?? t("home.random")).fits(1)
                        }
                        .font(Theme.Typography.headline)
                        .foregroundStyle(Theme.Colors.white)
                        Text(t("moodLine.\(key ?? "random")"))
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.white.opacity(0.75))
                            .fits(1)
                    }
                    .padding(Theme.Space.s24)
                    posters(focused: focused)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .padding(Theme.Space.s24)
                }
                .frame(width: MoodTile.size.width, height: MoodTile.size.height)
                .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                .hoverEffect(.highlight)
                .animation(.easeOut(duration: Theme.Motion.focus), value: focused)
                .onChange(of: focused) { _, now in drifting = now && !reduceMotion }
                .task(id: focused) {
                    guard key == nil, focused, !reduceMotion, titleIds.count > 3 else { return }
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(1400))
                        withAnimation(.spring(response: 0.7, dampingFraction: 0.65)) { turn += 1 }
                    }
                }
            }
        }
        .buttonStyle(CardButtonStyle(shadow: false))
        .accessibilityLabel(key.map { t("mood.\($0)") } ?? t("home.random"))
    }

    private func colour(focused: Bool) -> Color {
        guard let key, let hue = MoodTile.hues[key] else {
            return Color(hue: 0.71, saturation: 0.45, brightness: focused ? 0.36 : 0.26)
        }
        return Color(hue: hue / 360, saturation: 0.45, brightness: focused ? 0.42 : 0.3)
    }

    /// Three posters from where the shuffle stands. Focused, they sway on a
    /// repeating animation each of its own tilt and pace, which is what keeps
    /// them from moving as one block; at rest they hold still and cost nothing.
    private func posters(focused: Bool) -> some View {
        let start = titleIds.isEmpty ? 0 : turn % titleIds.count
        let shown = titleIds.isEmpty ? [] : Array((titleIds[start...] + titleIds[..<start]).prefix(3))
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.poster / 2, style: .continuous)
        return HStack(spacing: Theme.Space.s8 + 2) {
            ForEach(Array(shown.enumerated()), id: \.element) { index, id in
                let tilt = index.isMultiple(of: 2) ? 2.5 : -2.5
                ArtworkImage(kind: .smallPoster(titleId: id)) { Theme.Colors.bg2 }
                    .frame(width: MoodTile.poster.width, height: MoodTile.poster.height)
                    .clipShape(shape)
                    // cast by the plain shape: a shadow of the clipped picture is an offscreen pass
                    .background { shape.fill(Theme.Colors.bg2).shadow(color: .black.opacity(0.5), radius: 10, y: 6) }
                    .rotationEffect(.degrees(focused ? (drifting ? tilt : -tilt) : 0))
                    .offset(y: focused ? (drifting ? -17 : -7) : 0)
                    .animation(
                        drifting
                            ? .easeInOut(duration: 3.2 + Double(index) * 0.7).repeatForever()
                            : .easeOut(duration: Theme.Motion.focus),
                        value: drifting)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
    }
}

/// The title under the remote, said in full over its own picture.
///
/// Handed its title by the one open room: read from the screen's body, the
/// title under the remote would invalidate the whole list of reasons at
/// every press of the cross.
private struct Hero: View {
    let item: TitleItem?
    /// Whether the taste is a door to the tastes. Only over the first reason:
    /// lower down it stands between two reasons and takes the press up.
    let door: Bool
    @Environment(Navigator.self) private var navigator
    @Environment(HomeModel.self) private var home

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let item {
                let facts = HeroFacts.shared.slot(item.id)
                TitleTreatment(
                    titleId: item.id, name: item.name, maxWidth: Theme.Home.heroLogoWidth,
                    maxHeight: Theme.Home.heroTitle, wrapped: Theme.Typography.displayWrapped
                )
                .frame(height: Theme.Home.heroTitle, alignment: .bottomLeading)

                Text(Hero.meta(item, facts.detail, at: home.now))
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .fits(1)
                    .frame(height: Theme.Home.heroMeta, alignment: .bottomLeading)
                    .padding(.top, Theme.Space.s16)

                Text(facts.detail?.overview ?? "")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.text)
                    .fits(2)
                    .frame(height: Theme.Home.heroOverview, alignment: .topLeading)
                    .padding(.top, Theme.Space.s16)

                // with the title it explains rather than with the row below
                band(facts)
                    .frame(height: Theme.Home.heroBand, alignment: .bottomLeading)
                    .padding(.top, Theme.Space.s16)
            }
        }
        .frame(maxWidth: Hero.column, alignment: .bottomLeading)
        // flattened first: a shadow on a plain stack is cast by every child
        .compositingGroup()
        .headingOverPicture()
        .padding(.horizontal, Theme.Layout.gutter)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Wide enough for two lines of a long title, narrow enough that the
    /// picture behind it is still a picture on the right.
    static let column: CGFloat = 1120

    /// Why this title, in one sentence: the strongest evidence the index has.
    /// A kinship with a taste is a door too, and opens the four tastes and
    /// what has been moving them; any other evidence is said plainly.
    @ViewBuilder private func band(_ facts: HeroSlot) -> some View {
        switch facts.evidence {
        case .vein(let leader)?:
            tasteDoor(leader)
        case let evidence?:
            Text(Hero.say(evidence))
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.text)
                .fits(1)
        case nil:
            if let taste = facts.taste { tasteDoor(taste.leader) }
        }
    }

    @ViewBuilder private func tasteDoor(_ leader: String) -> some View {
        if door {
            Button { navigator.openTaste() } label: {
                TasteReason(leader: leader, font: Theme.Typography.caption, lines: 1)
            }
            .buttonStyle(
                FilledControlStyle(
                    horizontal: Theme.Space.s16, vertical: Theme.Space.s8, glass: false))
            // the fill's inset taken back, so the words line up with the title's
            .padding(.leading, -Theme.Space.s16)
        } else {
            TasteReason(leader: leader, font: Theme.Typography.caption, lines: 1)
        }
    }

    static func say(_ evidence: TitleEvidence) -> String {
        switch evidence {
        case .saga(let name, let done): t("evidence.saga", ["name": name, "done": String(done)])
        case .director(let name, let seen):
            t("evidence.director", ["name": name, "seen": String(seen)])
        case .streak(let leader, let count):
            t("evidence.streak", ["leader": leader, "count": String(count)])
        case .crew(let role, let name, let loved):
            t(role == .composer ? "evidence.crewComposer" : "evidence.crewWriter", ["name": name, "loved": loved])
        case .actor(let name, let seen): t("evidence.actor", ["name": name, "seen": String(seen)])
        case .vein(let leader): t("why.vein", ["leader": leader])
        case .newArrival: t("evidence.newArrival")
        case .acclaimed(let score):
            t("evidence.acclaimed", ["score": score.formatted(.number.precision(.fractionLength(1)))])
        case .rewatch(let plays, let last):
            t(
                plays > 1 ? "evidence.rewatch" : "evidence.rewatchOnce",
                [
                    "plays": String(plays),
                    "year": String(
                        Calendar.current.component(.year, from: Date(timeIntervalSince1970: TimeInterval(last)))),
                ])
        }
    }

    /// Director, genre, tone, year, runtime, set the way a programme sets it:
    /// no labels, no separators between them, spaces doing the work.
    private static func meta(_ item: TitleItem, _ detail: TitleDetail?, at now: Date) -> String {
        var parts: [String] = []
        if let who = detail?.directors.first?.name { parts.append(who) }
        if let genre = detail?.genres.first { parts.append(Format.genre(genre)) }
        // the tones are one fact, said as a list inside the line's own dots
        if let tones = detail?.tones, !tones.isEmpty {
            let said = tones.map { t("tone.\($0)") }.joined(separator: ", ")
            parts.append(said.prefix(1).uppercased() + said.dropFirst())
        }
        if let year = item.year { parts.append(String(year)) }
        if let runtime = detail?.runtimeSecs, runtime > 0 {
            parts.append(Format.runtime(runtime))
            // a film is one sitting, so when it would end is the fact that
            // decides it; a show's runtime is not one evening
            if item.kind == .movie {
                let end = Calendar.current.dateComponents(
                    [.hour, .minute], from: now.addingTimeInterval(runtime))
                let time = Format.wallClock(minutes: (end.hour ?? 0) * 60 + (end.minute ?? 0))
                parts.append(t("tonight.endsAt", ["time": time]))
            }
        }
        return parts.joined(separator: "  ·  ")
    }
}

/// The title under the remote, held apart from the model.
///
/// Focus moves at the speed of a thumb and this changes with every move. Read
/// from `HomeScreen.body` it would invalidate the screen each time: the
/// scroll view, the stack, and the closure building every reason under it.
/// Only the backdrop and the hero read it, and only they are redrawn.
///
/// Lighting a title is what starts everything the screen shows for it: the
/// backdrop decoded at the size of the panel, the tone, the facts, the
/// lettering. A thumb swept across a reason passes a dozen cards in under a
/// second, and starting all that for each one leaves the television busy
/// loading titles the viewer left two cards ago.
@MainActor @Observable
final class Lit {
    private(set) var item: TitleItem?
    /// The title the backdrop shows: `item` once the thumb has rested on it,
    /// whether it got there along a reason or across them.
    private(set) var backdrop: Int64?
    /// The reason the remote is on, which holds the hero.
    private(set) var lane = 0
    /// The lane the reasons around it are built for: `lane` once the move to
    /// it has finished.
    private(set) var settled = 0
    // Not observed: nothing draws them, and observed, a write to either
    // redraws the room a move opens before its title has changed.
    @ObservationIgnored private var settling: Task<Void, Never>?
    @ObservationIgnored private var moved = ContinuousClock.now - Lit.rest

    /// How long the thumb rests before a card counts as the one being
    /// looked at. A step taken on its own is never this close to the one
    /// before it; every step of a sweep is.
    private static let rest = Duration.milliseconds(180)

    /// Opens `next`'s room and scrolls with it, and builds the reasons
    /// around it once the screen is still.
    func move(to next: Int, scroll: () -> Void) {
        Health.signposter.emitEvent("lane", "\(next)")
        withAnimation(UIAccessibility.isReduceMotionEnabled ? nil : .smooth(duration: Theme.Motion.heroLane)) {
            lane = next
            scroll()
        } completion: { [weak self] in
            // a later move may have started meanwhile: build for where it is now
            guard let self, settled != lane else { return }
            settled = lane
        }
    }

    /// Lands `next` at once, whatever the thumb is doing: a move to another
    /// reason opens a room that has to be drawn with it.
    func show(_ next: TitleItem) {
        Health.signposter.emitEvent("light", "\(next.id)")
        settling?.cancel()
        moved = .now
        if item?.id != next.id { item = next }
        // the backdrop's decode and cross-fade wait for the rest: a held
        // remote passes reasons as fast as it passes cards
        settling = Task { [weak self] in
            try? await Task.sleep(for: Lit.rest)
            guard !Task.isCancelled, let self, backdrop != next.id else { return }
            backdrop = next.id
        }
    }

    /// A step lands at once, a sweep lands once, on the card it ends on.
    func light(_ next: TitleItem) {
        guard item?.id != next.id else { return }
        Health.signposter.emitEvent("light", "\(next.id)")
        settling?.cancel()
        let sweeping = .now - moved < Lit.rest
        moved = .now
        guard sweeping else {
            item = next
            backdrop = next.id
            return
        }
        settling = Task { [weak self] in
            try? await Task.sleep(for: Lit.rest)
            guard !Task.isCancelled else { return }
            self?.item = next
            self?.backdrop = next.id
        }
    }
}

/// The backdrop, reading the title under the remote inside its own body so
/// that a focus move stops there.
private struct LitBackdrop: View {
    let lit: Lit

    var body: some View {
        Backdrop(titleId: lit.backdrop)
            .overlay(Scrim(direction: .hero))
    }
}

@MainActor
@Observable
final class HomeModel {
    private(set) var loaded = false
    private(set) var queue: [QueueItem] = []
    /// How far into each title someone got, by title. Read by every row and
    /// not by the queue's own alone: a title part way through carries its bar
    /// wherever it is shown, and the same film is often in two reasons.
    fileprivate private(set) var resume: [Int64: Resume] = [:]
    /// The episode a show in the queue carries on with, by title, said under
    /// its card wherever the show is shown.
    fileprivate private(set) var episodes: [Int64: String] = [:]
    fileprivate var lanes: [HomeLane] = []
    private(set) var evening = EveningState(
        together: false, windowMinutes: nil, passesLeft: 0, mood: nil, guestId: nil)
    /// The people the viewer watches with, for the evening's company menu.
    /// Each mood worth a press and the films its tile is drawn with.
    fileprivate private(set) var moods: [MoodShelf] = []
    /// What the random tile is drawn with: the evening's own cards, then the
    /// moods' fronts, so the shuffle has more than three to deal.
    fileprivate var randomIds: [Int64] {
        var ids = trio?.cards.map(\.item.id) ?? []
        for id in moods.compactMap(\.titleIds.first) where !ids.contains(id) { ids.append(id) }
        return ids
    }
    fileprivate var error: String?
    /// Whether any source is set up: an empty home without one is a first run.
    fileprivate private(set) var hasSources = true
    /// The title under the remote. The whole screen is coloured by it, so it
    /// starts on the first card of the first reason rather than empty.
    fileprivate let lit = Lit()

    /// The last lane of the head of the screen (the queue, the evening, the
    /// list), which the moods are drawn under.
    fileprivate private(set) var moodLane = 0
    /// Last evening's finished titles nobody has judged, while the morning
    /// after still asks about them.
    fileprivate private(set) var review: [TitleItem] = []
    private var trio: TonightTrio?
    fileprivate var hasTrio: Bool { trio?.cards.isEmpty == false }
    private var rows: [HomeRow] = []
    /// The minute the screen is drawn at, moved on by `tick`: the hero's
    /// end time follows it.
    fileprivate private(set) var now = Date()
    private var loading: Task<Void, Never>?

    /// What the queue holds that can be carried on with, for the search
    /// screen, which offers it before anything has been typed.
    var resuming: [TitleItem] {
        queue.filter { $0.resumeFileId != nil }.map(\.item)
    }

    /// `trio` is one the core already answered with; the fetch skips it.
    func load(trio known: TonightTrio?? = nil) {
        loading?.cancel()
        AmbientReader.shared.refresh()
        let tz = Format.tzOffsetSecs
        loading = Task { @MainActor [self] in
            async let tonight = CoreClient.run {
                known.map { Result<TonightTrio?, Error>.success($0) }
                    ?? Result { try CoreClient.shared.tonight(tzOffsetSecs: tz) }
            }
            async let shelves = CoreClient.run {
                Result { try CoreClient.shared.browseRows(kind: nil, tzOffsetSecs: tz) }
            }
            async let rest = CoreClient.run {
                (
                    try? CoreClient.shared.evening(tzOffsetSecs: tz),
                    Result { try CoreClient.shared.queue(limit: 20) },
                    try? CoreClient.shared.moods(),
                    try? CoreClient.shared.eveningReview(tzOffsetSecs: tz),
                    CoreClient.shared.listSources()
                )
            }
            let fetched = await (tonight, shelves, rest)
            guard !Task.isCancelled else { return }
            let (planResult, rowsResult, (state, queueResult, fetchedMoods, fetchedReview, sources)) = fetched
            let plan = try? planResult.get(), fetchedRows = try? rowsResult.get()
            let fetchedQueue = try? queueResult.get()
            if sources.isEmpty == hasSources { hasSources = !sources.isEmpty }
            Format.sourceNames = Dictionary(
                sources.compactMap { source in source.name.map { (source.id, $0) } }, uniquingKeysWith: { first, _ in first })
            // A reload mostly finds what is already drawn: only what moved is
            // written, so an unchanged screen is not redrawn.
            let nextMoods = fetchedMoods ?? []
            if nextMoods != moods { moods = nextMoods }
            let nextReview = fetchedReview ?? []
            if nextReview != review { review = nextReview }
            if let state, state != evening { evening = state }
            let nextQueue = fetchedQueue ?? []
            let nextRows = fetchedRows ?? []
            let relay = plan != trio || nextQueue != queue || nextRows != rows
            if plan != trio { trio = plan }
            if nextRows != rows { rows = nextRows }
            if nextQueue != queue {
                queue = nextQueue
                resume = Dictionary(
                    queue.compactMap { entry in
                        Resume(position: entry.positionSecs, duration: entry.durationSecs)
                            .map { (entry.item.id, $0) }
                    },
                    uniquingKeysWith: { first, _ in first })
                episodes = Dictionary(
                    queue.compactMap { entry in
                        let code = Format.episodeCode(season: entry.season, episode: entry.episode)
                        return code.isEmpty ? nil : (entry.item.id, code)
                    },
                    uniquingKeysWith: { first, _ in first })
            }
            if relay || !loaded { lay() }
            // A failure with nothing to show is said as one, never as an
            // empty library; with lanes on screen they stay.
            var failed: Error?
            for result in [planResult.map { _ in () }, rowsResult.map { _ in () }, queueResult.map { _ in () }] {
                if case .failure(let failure) = result { failed = failure }
            }
            let shown = lanes.isEmpty ? failed.map(Format.describe) : nil
            if shown != error { error = shown }
            if !loaded { loaded = true }
        }
    }

    /// The evening moves on without the viewer: the clock and the plan follow
    /// it once a minute, at once on a return after a longer absence.
    fileprivate func tick() async {
        while !Task.isCancelled {
            let wait = 60 - Date().timeIntervalSince(now)
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !Task.isCancelled else { return }
            let hour = Calendar.current.component(.hour, from: now)
            now = Date()
            AmbientReader.shared.refresh()
            let tz = Format.tzOffsetSecs
            let (plan, state) = await CoreClient.run {
                (try? CoreClient.shared.tonight(tzOffsetSecs: tz), try? CoreClient.shared.evening(tzOffsetSecs: tz))
            }
            // the session changes under the screen at 18:00, and its answers
            // with it
            if let state, state != evening { evening = state }
            // the review opens and closes on the hour an evening ends or
            // starts, so an hourly look is enough
            if Calendar.current.component(.hour, from: now) != hour {
                let next = await CoreClient.run { (try? CoreClient.shared.eveningReview(tzOffsetSecs: tz)) ?? [] }
                if next != review { review = next }
            }
            if plan != trio {
                trio = plan
                lay()
            }
        }
    }

    /// A verdict on the review's title: it leaves the line at once.
    fileprivate func judge(_ item: TitleItem, _ verdict: ApiVerdict) {
        review.removeAll { $0.id == item.id }
        CoreClient.calls.async { _ = try? CoreClient.shared.setVerdict(titleId: item.id, verdict: verdict) }
    }

    /// "Later": the whole evening goes, for good.
    fileprivate func later() {
        review = []
        CoreClient.calls.async { _ = try? CoreClient.shared.dismissReview() }
    }

    /// Plays one of the evening's cards at random, with the reason it was
    /// chosen said over the first seconds of the film.
    fileprivate func playSomething(_ navigator: Navigator) {
        guard let card = trio?.cards.filter({ $0.item.firstFileId != nil }).randomElement(),
            let fileId = card.item.firstFileId
        else { return }
        navigator.play(
            titleId: card.item.id, fileId: fileId, title: card.item.name, startAt: 0,
            landOn: card.item, note: Self.reason(card), from: .surprise)
    }

    private static func reason(_ card: TonightCard) -> String {
        switch card.role {
        case .safeBet:
            return card.seed.isEmpty
                ? t("tonight.safeBet") : t("tonight.reasonSeed", ["title": card.seed])
        case .gamble:
            return t("tonight.reasonGamble")
        case .familiar:
            let year = String(
                Calendar.current.component(
                    .year, from: Date(timeIntervalSince1970: TimeInterval(card.lastWatchedAt))))
            return card.plays > 1
                ? t("tonight.reasonFamiliar", ["count": String(card.plays), "year": year])
                : t("tonight.reasonFamiliarOnce", ["year": year])
        }
    }

    /// What was already started first, then the evening, then every reason
    /// the engine dealt. The three picks and their runners-up are one row:
    /// they are a reason like the others, and giving them a band of their own
    /// is what pushed everything else off the screen.
    private func lay() {
        var laid: [HomeLane] = []
        if !queue.isEmpty {
            laid.append(
                HomeLane(
                    index: laid.count, title: t("row.upNext"), items: queue.map(\.item),
                    surfaces: Array(repeating: .queue, count: queue.count), reason: .upNext))
        }
        if let trio, !trio.cards.isEmpty {
            let cards: [LaunchSurface] = trio.cards.map { card in
                switch card.role {
                case .safeBet: .tonightSafe
                case .gamble: .tonightGamble
                case .familiar: .tonightFamiliar
                }
            }
            laid.append(
                HomeLane(
                    index: laid.count, title: t(trio.afternoon ? "tonight.afternoon" : "tonight.title"),
                    items: trio.cards.map(\.item) + trio.more,
                    surfaces: cards + Array(repeating: .tonightMore, count: trio.more.count),
                    reason: .tonight, gaps: trio.gaps, cards: trio.cards.count))
        }
        // the list leads the core's rows, and closes the head of the screen
        var head = laid.count - 1
        for row in rows where !row.items.isEmpty {
            if case .watchlist = row.reason { head = laid.count }
            laid.append(
                HomeLane(
                    index: laid.count, title: row.reason.railTitle, items: row.items,
                    surfaces: Array(repeating: .homeRow(reason: row.reason), count: row.items.count),
                    reason: row.reason, places: row.places))
        }
        moodLane = max(head, 0)
        lanes = laid
        // Only where nothing is lit yet: the plan is laid again on a reload
        // and once a minute by the clock, and the remote is usually already
        // somewhere else by then.
        if lit.item == nil, let first = laid.first?.items.first { lit.light(first) }
    }
}

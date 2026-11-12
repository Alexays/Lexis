import LexisCore
import SwiftUI

/// The tabs the pill bar offers, in its order.
enum Tab: String, CaseIterable, Identifiable {
    case search, home, movies, series, watchlist, settings
    var id: String { rawValue }
    var titleKey: String { "nav.\(rawValue)" }
    var round: Bool { self == .search || self == .settings }
}

/// A screen pushed over the tab shell: a title, or a person by the name a
/// credit carries, since the index joins credits on names.
enum Level: Hashable, Identifiable {
    case title(TitleItem)
    case person(String)
    /// One row of a shelf, opened as a screen of its own.
    case row(HomeReason)
    /// The four tastes, what moved them, and the log of what did it.
    case taste
    /// How the propositions fare: what was launched from where.
    case stats

    var id: String {
        switch self {
        case .title(let item): "title:\(item.id)"
        case .person(let name): "person:\(name)"
        case .row(let reason): "row:\(reason.railTitle)"
        case .taste: "taste"
        case .stats: "stats"
        }
    }
}

/// What the player is asked to play.
struct Playing: Equatable {
    let fileId: Int64
    let title: String
    var startAt: Double
    var context = ""
    /// The title the film ends on, where the verdict buttons are.
    var landOn: TitleItem?
    /// Why this was played, said over its first seconds: set when the app
    /// chose the title for the viewer.
    var note = ""
    /// Bumped by a retry, so the same file opens on a fresh screen.
    var attempt = 0
}

/// The library shelf a tab shows: an order, a genre and a decade; the
/// defaults leave nothing narrowed.
struct LibraryFilters: Equatable {
    var sort = LibrarySort.name
    var genre = ""
    var decade: UInt16 = 0
    var active: Bool { !genre.isEmpty || decade != 0 }
}

/// Where the viewer is, and every move between screens. One instance for
/// the app, in the environment, so a card anywhere can open what it names.
@MainActor
@Observable
final class Navigator {
    var tab = Tab.home
    /// The remote is below the pill bar, in the screen.
    var browsing = false
    var stack: [Level] = []
    var playing: Playing?
    var filters = LibraryFilters()
    /// Bumped to hand the bar the remote back.
    var focusToken = 0
    /// The settings open on the add-source flow, taken by the settings
    /// screen once its modules are read.
    var addingSource = false
    /// The surface each title's page was last opened from: a launch from the
    /// page counts for what proposed the title, not for the page.
    @ObservationIgnored private var openedFrom: [Int64: LaunchSurface] = [:]

    func select(_ next: Tab) {
        tab = next
        browsing = false
        filters = LibraryFilters()
    }

    func open(_ item: TitleItem, from surface: LaunchSurface) {
        openedFrom[item.id] = surface
        stack.append(.title(item))
    }

    /// What proposed a title whose page is open: the surface it was opened
    /// from, or the page itself when it was reached some other way.
    func proposer(of titleId: Int64) -> LaunchSurface { openedFrom[titleId] ?? .detail }
    func openRow(_ reason: HomeReason) {
        stack.append(.row(reason))
        browsing = true
    }

    func openPerson(_ name: String) { stack.append(.person(name)) }

    func openTaste() {
        stack.append(.taste)
        browsing = true
    }
    func openStats() {
        stack.append(.stats)
        browsing = true
    }
    func back() { _ = stack.popLast() }

    func addSource() {
        select(.settings)
        addingSource = true
    }

    /// Plays a title where it stands: where it was left, its next episode,
    /// or its start; a title with no file opens its page instead.
    func resume(_ item: TitleItem, from surface: LaunchSurface) {
        Task {
            let left = await CoreClient.run { try? CoreClient.shared.upNext(titleId: item.id) }
            if let left {
                play(
                    titleId: item.id, fileId: left.fileId, title: item.name, startAt: left.resumePositionSecs,
                    landOn: item, from: surface)
            } else if let fileId = item.firstFileId {
                play(titleId: item.id, fileId: fileId, title: item.name, startAt: 0, landOn: item, from: surface)
            } else {
                open(item, from: surface)
            }
        }
    }

    /// A rail's "see all": the library, newest first, remote in the grid.
    func openRecent(_ kind: ApiMediaKind) {
        tab = kind == .show ? .series : .movies
        filters = LibraryFilters(sort: .recentlyAdded)
        browsing = true
    }

    /// Plays a file of `titleId`, and journals the launch under the surface
    /// that proposed the title.
    func play(
        titleId: Int64, fileId: Int64, title: String, startAt: Double, context: String = "",
        landOn: TitleItem? = nil, note: String = "", from surface: LaunchSurface
    ) {
        playing = Playing(
            fileId: fileId, title: title, startAt: startAt, context: context,
            landOn: landOn ?? playing?.landOn, note: note)
        CoreClient.calls.async { _ = try? CoreClient.shared.recordLaunch(titleId: titleId, surface: surface) }
    }

    /// A film always ends on its own page.
    func leavePlayer() {
        let landOn = playing?.landOn
        playing = nil
        if let landOn, stack.last != .title(landOn) { stack.append(.title(landOn)) }
    }
}

/// The app: one pill bar over whichever screen the tab names, the levels
/// pushed over it, and the player over everything.
struct AppShell: View {
    @State private var navigator = Navigator()
    @State private var i18n = I18n.shared
    /// Kept here rather than by the home screen, which a tab switch
    /// unmounts: coming back finds the rails as they were.
    @State private var home = HomeModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var navigator = navigator
        ZStack {
            Theme.Colors.bg0.ignoresSafeArea()
            // A navigation stack keeps the screens under a level alive and
            // hands the remote back to the card it left when the level goes,
            // which is what brings the scroll back with it. Every screen lays
            // itself out on the full 1920x1080 frame with its own gutters, the
            // way the design measures it: the system's overscan insets would
            // shift all of it.
            NavigationStack(path: $navigator.stack) {
                tabScreen
                    .ignoresSafeArea()
                    .toolbar(.hidden, for: .navigationBar)
                    // Menu while the remote is down in a tab screen goes back
                    // to the bar; at the bar it is left to the system, which
                    // leaves the app.
                    .onExitCommand(perform: navigator.browsing ? {
                        navigator.browsing = false
                        navigator.focusToken += 1
                    } : nil)
                    .navigationDestination(for: Level.self) { level in
                        levelScreen(level)
                            .ignoresSafeArea()
                            .toolbar(.hidden, for: .navigationBar)
                    }
            }
            // Disabled rather than unmounted under a film, so the page it was
            // started from survives, and nothing under the cover answers the
            // remote.
            .opacity(navigator.playing == nil ? 1 : 0)
            .disabled(navigator.playing != nil)
            if let playing = navigator.playing {
                PlayerScreen(playing: playing).id("\(playing.fileId)/\(playing.attempt)").ignoresSafeArea()
            }
        }
        .environment(navigator)
        .environment(i18n)
        // every title card reads the evening's passes for its hold menu
        .environment(home)
        .task {
            #if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            if let at = arguments.firstIndex(of: "-lexis-play-local") {
                // `-lexis-play-local <path> [seconds]`: where to start, Heat's own scene by default
                let startAt = at + 2 < arguments.count ? Double(arguments[at + 2]) ?? 1830 : 1830
                navigator.playing = Playing(fileId: 0, title: "Heat", startAt: startAt, context: "Michael Mann, 1995")
            }
            #endif
            Health.shared.place = { [navigator] in
                "\(navigator.stack.last?.id ?? navigator.tab.rawValue)"
                    + (navigator.playing.map { " playing \($0.fileId)" } ?? "")
                    + " bg \(BackgroundWork.shared.phase)"
            }
            Health.shared.start()
            BackgroundWork.shared.startPass()
            // a launch is a wake the phase change never reports, and the one
            // moment a viewer surely expects what they just added
            BackgroundWork.shared.rescanIfStale(force: true)
            try? await Task.sleep(for: .seconds(5))
            Lifecycle.writeShelf()
            // an app left open on a screen still notices what arrives
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(BackgroundWork.rescanAfter))
                if navigator.playing == nil, scenePhase == .active { BackgroundWork.shared.rescanIfStale() }
            }
        }
        .onChange(of: navigator.playing == nil) { _, idle in
            CoreClient.calls.async { CoreClient.shared.pauseArtwork(paused: !idle) }
            // through the follower, which also stops polling the pass under the film
            BackgroundWork.shared.pausePass(!idle)
            // A film that ended is a library that may have moved, and a
            // resume point that did.
            if idle {
                BackgroundWork.shared.rescanIfStale()
                home.load()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .watchStateChanged)) { _ in home.load() }
        .onReceive(NotificationCenter.default.publisher(for: .tonightChanged)) { note in
            home.load(trio: note.object as? TonightTrio)
        }
        .onReceive(NotificationCenter.default.publisher(for: .libraryScanned)) { _ in
            if navigator.playing == nil { home.load() }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: Lifecycle.writeShelf()
            case .active:
                if navigator.playing == nil { BackgroundWork.shared.rescanIfStale() }
                // the app wakes on the screen it slept on, where no onAppear fires
                if navigator.playing == nil, navigator.tab == .home, navigator.stack.isEmpty {
                    CoreClient.calls.async { _ = try? CoreClient.shared.recordHomeOpen() }
                }
            default: break
            }
        }
        .onOpenURL { url in
            guard let link = Lifecycle.shelfLink(url) else { return }
            Task {
                guard let item = await CoreClient.run({ Lifecycle.title(for: link) }) else { return }
                navigator.playing = nil
                navigator.stack = [.title(item)]
                navigator.browsing = true
                if link.resume {
                    navigator.resume(item, from: .other)
                } else if link.play, let fileId = item.firstFileId {
                    navigator.play(
                        titleId: item.id, fileId: fileId, title: item.name, startAt: 0, landOn: item,
                        from: .other)
                }
            }
        }
    }

    @ViewBuilder private var tabScreen: some View {
        switch navigator.tab {
        case .home: HomeScreen(model: home)
        case .movies: LibraryScreen(kind: .movie).id("movies")
        case .series: LibraryScreen(kind: .show).id("series")
        case .watchlist: RowScreen(reason: .watchlist, tab: true).id("watchlist")
        case .search: SearchScreen(home: home)
        case .settings: SettingsScreen()
        }
    }

    @ViewBuilder private func levelScreen(_ level: Level) -> some View {
        switch level {
        case .title(let item): TitleDetailScreen(item: item)
        case .person(let name): PersonScreen(name: name)
        case .row(let reason): RowScreen(reason: reason)
        case .taste: TasteScreen()
        case .stats: StatsScreen()
        }
    }
}

/// The bar: one capsule of glass holding search and settings as round marks
/// and the shelves as words. The tab shown wears a lighter fill, the one
/// under the remote turns white and lifts. It scrolls away with the screen
/// rather than fading: a view at zero opacity takes no focus, which left
/// neither up nor Menu a way back to it.
struct PillNav: View {
    @Environment(Navigator.self) private var navigator
    @FocusState private var focusedTab: Tab?

    /// A tab inside the capsule, which leaves this much glass around it.
    private static let tab = Theme.Layout.pillHeight - 2 * Theme.Space.s8

    var body: some View {
        HStack(spacing: Theme.Space.s8) {
            ForEach(Tab.allCases) { tab in
                Button {
                    navigator.select(tab)
                } label: {
                    if tab.round {
                        GlyphView(glyph: tab == .search ? .magnifier : .sliders, size: 26)
                            .frame(width: PillNav.tab, height: PillNav.tab)
                    } else {
                        Text(t(tab.titleKey))
                            .font(Theme.Typography.body.weight(.medium))
                            .padding(.horizontal, Theme.Layout.pillPadding)
                            .frame(height: PillNav.tab)
                    }
                }
                .buttonStyle(TabStyle(selected: tab == navigator.tab))
                .focused($focusedTab, equals: tab)
                .accessibilityLabel(t(tab.titleKey))
                .accessibilityAddTraits(tab == navigator.tab ? .isSelected : [])
            }
        }
        .padding(Theme.Space.s8)
        // Clear rather than regular: the bar sits on the top of a backdrop,
        // the one band the scrim leaves undimmed, and that is the one place
        // in the app where glass has a picture to refract instead of the
        // near-black canvas, which flattens the regular style into grey.
        .glassCapsule(style: .clear, tint: Theme.Glass.raised)
        .frame(height: Theme.Layout.pillHeight)
        .defaultFocus($focusedTab, navigator.tab)
        .onChange(of: focusedTab) { old, now in
            // the remote leaving the bar is down in the screen, whatever it
            // landed on: Menu then brings it back rather than leaving the app
            if now != nil { navigator.browsing = false } else if old != nil { navigator.browsing = true }
            // Up from the screen lands on the tab it shows, as the system's
            // own bar does: the tab straight above is only where the remote
            // happened to be.
            if old == nil, let now, now != navigator.tab { focusedTab = navigator.tab }
        }
        .onChange(of: navigator.focusToken) { _, _ in focusedTab = navigator.tab }
    }
}

/// A tab of the bar: bare at rest, a light fill where it is the tab shown,
/// and white, dark ink and lifted where the remote is.
private struct TabStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        TabBody(configuration: configuration, selected: selected)
    }
}

private struct TabBody: View {
    let configuration: ButtonStyle.Configuration
    let selected: Bool
    @Environment(\.isFocused) private var focused

    var body: some View {
        configuration.label
            .foregroundStyle(
                focused ? Theme.Colors.onWhite : selected ? Theme.Colors.white : Theme.Colors.textSecondary)
            .background {
                Capsule()
                    .fill(focused ? Theme.Colors.white : Theme.Colors.white.opacity(selected ? 0.2 : 0))
                    .shadow(color: .black.opacity(focused ? 0.4 : 0), radius: 13, y: 12)
            }
            .scaleEffect(focused ? Theme.Focus.tab : 1)
            .animation(.easeOut(duration: Theme.Motion.focus), value: focused)
    }
}

/// The band every tab screen leaves for the bar, and the bar in it.
struct BarBand: View {
    var body: some View {
        PillNav()
            .frame(maxWidth: .infinity)
            .padding(.top, Theme.Layout.pillTop)
            .frame(height: Theme.Layout.bar, alignment: .top)
            // A section across the whole width: up from a card at either
            // edge lands on the nearest pill rather than nowhere.
            .focusSection()
    }
}

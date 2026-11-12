import LexisCore
import SwiftUI

enum SettingsCategory: String, CaseIterable, Identifiable {
    case sources, room, language, recommendations, diagnostics
    var id: String { rawValue }
    var labelKey: String { "settings.\(rawValue)" }

    var glyph: Glyph {
        switch self {
        case .sources: .server
        case .room: .display
        case .language: .globe
        case .recommendations: .sparkles
        case .diagnostics: .activity
        }
    }
}

/// What the settings screen holds while it is on screen: the sources and
/// what the core says of them, the scan it started, the last action's
/// failure, and how deep the sources pane is. Every core call runs off the
/// main actor and lands back here.
@MainActor
@Observable
final class SettingsStore {
    var category = SettingsCategory.sources
    var sources: [SourceInfo] = []
    var modules: [SourceModuleInfo] = []
    var tmdbStored = false
    var queued: UInt32 = 0
    var report: ScanReport?
    /// Whether this screen is waiting on a scan it asked for.
    var scanning = false
    /// What the last action failed with, under the pane it was pressed in.
    var message: String?
    /// The source whose detail is open, and whether the add flow is.
    var open: String?
    var adding = false
    /// Set by a move the remote made inside the pane - adding, opening a
    /// source, backing out of either - and taken by the view it lands on,
    /// which puts the remote on its own first control: the one the remote
    /// was on is gone, and the system would otherwise put it back on the
    /// column. A category chosen from the column leaves it alone.
    var focusesPane = false
    var upscaling = Prefs.flag(Prefs.upscalingKey, default: true)
    var passthrough = Prefs.flag(Prefs.audioPassthroughKey, default: true)
    var reach = "default"
    var passes: UInt32 = 3

    private let core = CoreClient.shared

    func select(_ next: SettingsCategory) {
        category = next
        message = nil
        adding = false
        open = nil
    }

    func closeDepth(open next: String? = nil) {
        adding = false
        open = next
        message = nil
        focusesPane = true
    }

    func load() async {
        let core = core
        let (modules, reach, passes) = await CoreClient.run {
            (
                core.sourceModules(),
                (try? core.stepAsideReach()) ?? "default",
                (try? core.tonightPasses()) ?? 3
            )
        }
        self.modules = modules
        self.reach = reach
        self.passes = passes
        await refresh()
    }

    func refresh() async {
        let core = core
        let (sources, stored, queued) = await CoreClient.run {
            (core.listSources(), core.hasTmdbKey(), core.queuedWrites())
        }
        self.sources = sources
        Format.sourceNames = Dictionary(
            sources.compactMap { source in source.name.map { (source.id, $0) } }, uniquingKeysWith: { first, _ in first })
        tmdbStored = stored
        self.queued = queued
    }

    /// Runs one core action and refreshes after it either way; a failure
    /// replaces the scan report with its message.
    @discardableResult
    func run(_ action: @escaping @Sendable (LexisCore) throws -> Void) async -> Bool {
        let core = core
        do {
            try await CoreClient.run { try action(core) }
            message = nil
            await refresh()
            return true
        } catch {
            report = nil
            message = Format.describe(error)
            await refresh()
            return false
        }
    }

    func addSource(module: String, values: [String: String]) async -> String? {
        let core = core
        do {
            let id = try await CoreClient.run { try core.addSource(module: module, values: values) }
            message = nil
            await refresh()
            return id
        } catch {
            report = nil
            message = Format.describe(error)
            await refresh()
            return nil
        }
    }

    func linkStart(module: String) async -> CoreLink? {
        let core = core
        do {
            return try await CoreClient.run { try core.linkStart(module: module) }
        } catch {
            message = Format.describe(error)
            return nil
        }
    }

    func linkCancel(handle: String) {
        let core = core
        CoreClient.calls.async { core.linkCancel(handle: handle) }
    }

    func addFromChoice(handle: String, choice: Choice) async -> String? {
        let core = core
        do {
            let id = try await CoreClient.run {
                try core.addFromChoice(handle: handle, choiceId: choice.id, name: choice.name)
            }
            message = nil
            await refresh()
            return id
        } catch {
            report = nil
            message = Format.describe(error)
            await refresh()
            return nil
        }
    }

    func forget(_ id: String) async {
        open = nil
        await run { core in
            _ = try core.removeSource(id: id)
        }
        report = nil
    }

    func saveToken(_ key: String) async -> Bool {
        let saved = await run { core in try core.setTmdbKey(key: key) }
        if saved { BackgroundWork.shared.startPass() }
        return saved
    }

    func removeToken() async {
        await run { core in core.clearTmdbKey() }
    }

    func setReach(_ value: String) async {
        let before = reach
        reach = value
        if await !run({ core in try core.setStepAsideReach(reach: value) }) { reach = before }
    }

    func setPasses(_ value: UInt32) async {
        let before = passes
        passes = value
        if await !run({ core in try core.setTonightPasses(passes: value) }) { passes = before }
    }

    /// How far the scan this screen asked for has got; nil while it waits
    /// on none.
    var scanProgress: ScanStatus? {
        let running = BackgroundWork.shared.scan
        return scanning && running.running ? running : nil
    }

    /// A viewer's Scan: every source, everything it holds. A scan this
    /// screen already waits on is left to finish.
    func scan() {
        guard !scanning else { return }
        scanning = true
        message = nil
        Task {
            do {
                report = try await BackgroundWork.shared.scan(full: true)
            } catch {
                report = nil
                message = Format.describe(error)
            }
            scanning = false
            await refresh()
        }
    }
}

/// The settings: a column of categories, and the pane of the selected one.
struct SettingsScreen: View {
    @Environment(Navigator.self) private var navigator
    @Environment(I18n.self) private var i18n
    @State private var store = SettingsStore()
    @FocusState private var focusedRow: SettingsCategory?
    @FocusState private var paneFocused: Bool
    private var work: BackgroundWork { .shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                BarBand()
                HStack(alignment: .top, spacing: Theme.Layout.gutter) {
                    column
                    VStack(alignment: .leading, spacing: 0) {
                        pane
                        if let message = store.message {
                            Text(message)
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Colors.error)
                                .padding(.top, Theme.Space.s24)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .focusSection()
                    .focused($paneFocused)
                }
                .padding(.top, Theme.Space.s16)
            }
            .padding(.horizontal, Theme.Layout.gutter)
            .padding(.bottom, Theme.Space.s64)
        }
        .task {
            await store.load()
            // the home's first-run button: the flow opens on its first kind
            if navigator.addingSource {
                navigator.addingSource = false
                store.select(.sources)
                store.adding = true
                store.focusesPane = true
            }
            if !work.passStarted { work.startPass() }
        }
        .onChange(of: focusedRow) { _, now in
            guard let now else { return }
            navigator.browsing = true
            // the pane follows the row under the remote, as the system's own
            // settings do; coming back to its own row leaves a depth be
            if now != store.category { store.select(now) }
        }
        .onChange(of: paneFocused) { _, now in if now { navigator.browsing = true } }
        .onExitCommand(perform: exitAction)
    }

    /// The Menu ladder: a depth closes first; the remote in the pane goes
    /// back to its row; on a row, nothing here answers and the shell takes it.
    private var exitAction: (() -> Void)? {
        if store.adding || store.open != nil { return { store.closeDepth() } }
        if navigator.browsing && focusedRow == nil { return { focusedRow = store.category } }
        return nil
    }

    private var column: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(t("settings.title"))
                .font(Theme.Typography.title)
                .tracking(Theme.Typography.titleTracking)
                .foregroundStyle(Theme.Colors.white)
                .padding(.leading, Theme.Space.s16)
                .padding(.bottom, Theme.Space.s24)
            ForEach(SettingsCategory.allCases) { category in
                CategoryRow(
                    label: t(category.labelKey), sublabel: sublabel(category), glyph: category.glyph,
                    selected: category == store.category
                ) {
                    store.select(category)
                }
                .focused($focusedRow, equals: category)
                .padding(.bottom, Theme.Space.s8)
            }
            CategoryRow(
                label: t("settings.recoStats"), sublabel: t("settings.recoStatsSummary"), glyph: .list,
                selected: false
            ) {
                navigator.openStats()
            }
            .padding(.top, Theme.Space.s24)
        }
        .frame(width: Theme.Layout.settingsColumn, alignment: .topLeading)
        .focusSection()
        // into the column, the remote lands on the category shown
        .defaultFocus($focusedRow, store.category)
    }

    @ViewBuilder private var pane: some View {
        switch store.category {
        case .sources: SourcesPane(store: store)
        case .room: RoomPane(store: store)
        case .language: LanguagePane()
        case .recommendations: RecommendationsPane(store: store)
        case .diagnostics: DiagnosticsPane(store: store)
        }
    }

    private func sublabel(_ category: SettingsCategory) -> String {
        switch category {
        case .sources:
            if store.sources.isEmpty { return t("settings.noSourcesSummary") }
            let failing = store.sources.filter { $0.lastError != nil }.count
            let n = String(store.sources.count)
            if failing > 0 { return t("settings.sourcesSummaryFailing", ["n": n, "failed": String(failing)]) }
            return store.sources.contains { $0.lastScan == nil }
                ? t("settings.sourcesSummaryPending", ["n": n])
                : t("settings.sourcesSummary", ["n": n])
        case .room:
            return t(store.passthrough ? "settings.audioBitstream" : "settings.audioDecoded")
        case .language:
            switch i18n.choice {
            case .pinned(.fr): return t("settings.languageFrench")
            case .pinned(.en): return t("settings.languageEnglish")
            case .system: return t("settings.languageSystem")
            }
        case .recommendations:
            switch store.reach {
            case "close": return t("settings.stepAsideClose")
            case "far": return t("settings.stepAsideFar")
            default: return t("settings.stepAsideDefault")
            }
        case .diagnostics:
            switch work.phase {
            case .idle: return t("settings.passIdle")
            case .done: return work.passMessage ?? t("settings.passDone")
            default: return t("settings.passRunning")
            }
        }
    }
}

/// One category in the column: a mark in a well, the name and a line on
/// its state. Selection wears the accent; the remote makes it white.
struct CategoryRow: View {
    let label: String
    let sublabel: String
    let glyph: Glyph
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            FocusReader { focused in
                HStack(spacing: Theme.Space.s16) {
                    GlyphView(glyph: glyph, size: 24)
                        .foregroundStyle(
                            focused
                                ? (selected ? Theme.Colors.onAccent : Theme.Colors.onWhite)
                                : Theme.Colors.textSecondary
                        )
                        .frame(width: 44, height: 44)
                        .background(
                            selected
                                ? Theme.Colors.onAccent.opacity(0.16)
                                : Theme.Colors.white.opacity(focused ? 0.1 : 0.06),
                            in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                    VStack(alignment: .leading, spacing: Theme.Space.s8) {
                        Text(label)
                            .font(Theme.Typography.body)
                            .fits(1, size: Theme.Typography.bodySize)
                            .frame(height: 34)
                        Text(sublabel)
                            .font(Theme.Typography.captionCompact)
                            .fits(1, size: Theme.Typography.captionCompactSize)
                            .foregroundStyle(
                                selected || focused
                                    ? AnyShapeStyle(HierarchicalShapeStyle.secondary)
                                    : AnyShapeStyle(Theme.Colors.textMuted))
                    }
                    Spacer(minLength: 0)
                }
                .padding(Theme.Space.s16)
                .frame(width: Theme.Layout.settingsColumn, alignment: .leading)
            }
        }
        .buttonStyle(FilledControlStyle(selected: selected, radius: Theme.Radius.row, horizontal: 0, vertical: 0))
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The card the smaller panes share, and one labelled row in it.
struct SettingCard<Content: View>: View {
    var maxWidth: CGFloat = 1100
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .padding(Theme.Space.s24)
            .frame(maxWidth: maxWidth, alignment: .leading)
            .glassSurface(radius: Theme.Radius.panel, tint: Theme.Glass.panel)
    }
}

struct SettingRow<Trailing: View>: View {
    let label: String
    let caption: String
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.s40) {
            VStack(alignment: .leading, spacing: Theme.Space.s8) {
                Text(label).font(Theme.Typography.body).foregroundStyle(Theme.Colors.text)
                Text(caption).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.textMuted)
            }
            Spacer(minLength: 0)
            trailing()
        }
    }
}

/// The line between two rows of a settings card.
struct CardDivider: View {
    var body: some View {
        Rectangle().fill(Theme.Glass.rule).frame(height: 1).padding(.vertical, Theme.Space.s24)
    }
}

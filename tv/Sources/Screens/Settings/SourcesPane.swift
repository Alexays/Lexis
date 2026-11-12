import CoreImage.CIFilterBuiltins
import LexisCore
import SwiftUI

/// The sources the library is built from: the list, one source's detail,
/// or the flow that adds one.
struct SourcesPane: View {
    let store: SettingsStore

    var body: some View {
        if store.adding {
            AddSourceStep(store: store) { id in store.closeDepth(open: id) } onCancel: { store.closeDepth() }
        } else if let id = store.open, let source = store.sources.first(where: { $0.id == id }) {
            SourceDetail(store: store, source: source).id(id)
        } else {
            SourceList(store: store)
        }
    }
}

private enum ListFocus: Hashable {
    case add, source(String), scan
}

private struct SourceList: View {
    let store: SettingsStore
    @FocusState private var focus: ListFocus?

    private var landing: ListFocus {
        store.sources.first.map { .source($0.id) } ?? .add
    }

    private var newestScan: Int64? {
        store.sources.compactMap(\.lastScan).max()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: Theme.Space.s24) {
                VStack(alignment: .leading, spacing: Theme.Space.s8) {
                    Text(t("settings.sources"))
                        .font(Theme.Typography.title)
                        .tracking(Theme.Typography.titleTracking)
                        .foregroundStyle(Theme.Colors.white)
                    if !store.sources.isEmpty {
                        Text(t("settings.headerCounts", [
                            "titles": String(store.sources.reduce(0) { $0 + $1.titles }),
                            "sources": String(store.sources.count),
                        ]))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textMuted)
                    }
                }
                Spacer(minLength: 0)
                ActionButton(label: t("settings.addSource"), glyph: .plus) {
                    store.adding = true
                    store.focusesPane = true
                }
                .focused($focus, equals: .add)
            }
            .frame(maxWidth: 1240)
            .padding(.bottom, Theme.Space.s24)
            if store.sources.isEmpty {
                Text(t("settings.noSources"))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textMuted)
            }
            if store.queued > 0 {
                Text(t("settings.owedWrites", ["n": String(store.queued)]))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.error)
                    .padding(.bottom, Theme.Space.s16)
            }
            ForEach(store.sources, id: \.id) { source in
                SourceCard(source: source, glyph: glyph(for: source)) {
                    store.open = source.id
                    store.focusesPane = true
                }
                    .focused($focus, equals: .source(source.id))
                    .padding(.bottom, Theme.Space.s16)
            }
            // nothing to update without a source, and a lone button under the
            // column would take the remote the add button is waiting for
            if !store.sources.isEmpty {
                HStack(alignment: .center, spacing: Theme.Space.s24) {
                    ActionButton(label: t(store.scanning ? "settings.scanning" : "settings.scanAll")) {
                        store.scan()
                    }
                    .focused($focus, equals: .scan)
                    if let newestScan {
                        Text(t("settings.lastFullScan", ["when": Format.relativeTime(newestScan)]))
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.textMuted)
                    }
                }
                .padding(.top, Theme.Space.s24)
            }
        }
        .defaultFocus($focus, landing)
        .task { if store.focusesPane { store.focusesPane = false; focus = landing } }
    }

    private func glyph(for source: SourceInfo) -> Glyph {
        store.modules.first { $0.id == source.module }.map { Glyph.forModule($0.glyph) } ?? .server
    }
}

/// One source in the list: its mark, its name and kind, and when it was
/// last scanned, with what it holds in chips.
private struct SourceCard: View {
    let source: SourceInfo
    let glyph: Glyph
    let onPress: () -> Void

    private var failed: Bool { source.lastError != nil }

    var body: some View {
        Button(action: onPress) {
            FocusReader { focused in
                HStack(alignment: .top, spacing: Theme.Space.s24) {
                    GlyphView(glyph: glyph, size: 26)
                        .foregroundStyle(failed ? Theme.Colors.error : Theme.Colors.textSecondary)
                        .frame(width: 56, height: 56)
                        .background(
                            failed ? Theme.Colors.error.opacity(0.12) : Theme.Glass.rule,
                            in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
                    VStack(alignment: .leading, spacing: 0) {
                        Text(source.name ?? source.id)
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Colors.text)
                        Text("\(I18n.shared.moduleText(source.module, "label"))  ·  \(source.detail)")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.textMuted)
                            .padding(.top, Theme.Space.s8)
                        if let error = source.lastError {
                            Text(error)
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Colors.error)
                                .frame(maxWidth: 520, alignment: .leading)
                                .padding(.top, Theme.Space.s8)
                        }
                        if source.lastScan != nil {
                            HStack(spacing: Theme.Space.s16) {
                                Chip(text: t("settings.titlesCount", ["n": String(source.titles)]))
                                Chip(text: t("settings.filesCount", ["n": String(source.files)]))
                            }
                            .padding(.top, Theme.Space.s16)
                        }
                    }
                    Spacer(minLength: 24)
                    HStack(spacing: Theme.Space.s16) {
                        Circle()
                            .fill(failed ? Theme.Colors.error : Theme.Colors.textSecondary)
                            .frame(width: 8, height: 8)
                        Text(scanState(source))
                            .font(Theme.Typography.caption)
                            .foregroundStyle(failed ? Theme.Colors.error : Theme.Colors.textSecondary)
                    }
                    .padding(.top, Theme.Space.s16)
                }
                .padding(Theme.Space.s24)
                .frame(maxWidth: 1240, alignment: .leading)
                .background(GlassSurface(interactive: true, tint: Theme.Glass.panel))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                        .strokeBorder(Theme.Colors.white, lineWidth: Theme.Focus.ring)
                        .opacity(focused ? 1 : 0))
                .scaleEffect(focused ? Theme.Focus.wide : 1)
                .animation(.easeOut(duration: Theme.Motion.focus), value: focused)
            }
        }
        .buttonStyle(CardButtonStyle())
        .accessibilityLabel(source.name ?? source.id)
    }
}

private func scanState(_ source: SourceInfo) -> String {
    source.lastScan.map { t("settings.lastScan", ["when": Format.relativeTime($0)]) }
        ?? t("settings.neverScanned")
}

private struct Chip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.Typography.captionCompact)
            .foregroundStyle(Theme.Colors.textSecondary)
            .padding(.horizontal, Theme.Space.s16)
            .padding(.vertical, Theme.Space.s8)
            .glassCapsule(tint: Theme.Glass.panel)
    }
}

private enum DetailFocus: Hashable {
    case scan, remove
}

/// One source, opened: what it holds, when it was scanned, and the two
/// things to do with it. Remove asks twice.
private struct SourceDetail: View {
    let store: SettingsStore
    let source: SourceInfo
    @State private var removeArmed = false
    @FocusState private var focus: DetailFocus?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s8) {
            Text(source.name ?? source.id)
                .font(Theme.Typography.title)
                .tracking(Theme.Typography.titleTracking)
                .foregroundStyle(Theme.Colors.white)
                .padding(.bottom, Theme.Space.s24)
            Text(source.detail)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textMuted)
            Text(t("settings.holds", ["titles": String(source.titles), "files": String(source.files)]))
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textMuted)
            Text(scanState(source))
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textMuted)
            if let error = source.lastError {
                Text(t("error.lastScan", ["detail": error]))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.error)
            }
            VStack(alignment: .leading, spacing: Theme.Space.s16) {
                ActionButton(label: t(store.scanning ? "settings.scanning" : "settings.scanAll")) {
                    store.scan()
                }
                .focused($focus, equals: .scan)
                ActionButton(label: t(removeArmed ? "settings.removeArmed" : "settings.remove")) {
                    if removeArmed {
                        removeArmed = false
                        Task { await store.forget(source.id) }
                    } else {
                        removeArmed = true
                    }
                }
                .focused($focus, equals: .remove)
            }
            .padding(.top, Theme.Space.s24)
        }
        .defaultFocus($focus, .scan)
        .task { if store.focusesPane { store.focusesPane = false; focus = .scan } }
    }
}

private enum LinkFailure {
    case refused, unreachable

    init(_ error: Error) {
        if case CoreError.Unauthorized = error { self = .refused } else { self = .unreachable }
    }

    var key: String {
        switch self {
        case .refused: "settings.linkRefused"
        case .unreachable: "settings.linkUnreachable"
        }
    }
}

private enum AddFocus: Hashable {
    case module(String), field(String), add, cancel, choice(String)
}

/// Adding a source: pick a kind, then either fill its fields or link an
/// account and choose a server from what it answers.
private struct AddSourceStep: View {
    let store: SettingsStore
    let onDone: (String) -> Void
    let onCancel: () -> Void
    @State private var picked: SourceModuleInfo?
    @State private var values: [String: String] = [:]
    @State private var link: CoreLink?
    /// Nil while the code is still waiting to be used.
    @State private var linkState: LinkState?
    @State private var choices: [Choice]?
    @State private var failure: LinkFailure?
    /// The link page as a code a phone camera reads, for a kind that names one.
    @State private var qr: CGImage?
    @FocusState private var focus: AddFocus?

    var body: some View {
        Group {
            if let picked, case .link = picked.setup {
                linkFlow(picked)
            } else {
                kindPicker
            }
        }
        .task(id: link?.handle) { await followLink() }
        // each step's own first control, once it is drawn: the control the
        // remote pressed to get here is gone with the step before
        .task(id: stage) {
            if stage == .kinds, !store.focusesPane { return }
            store.focusesPane = false
            focus = landing
        }
        .onDisappear {
            if let link { store.linkCancel(handle: link.handle) }
        }
    }

    private enum Stage: Hashable {
        case kinds, waiting, choosing, stopped
    }

    private var stage: Stage {
        guard let picked, case .link = picked.setup else { return .kinds }
        if failure != nil || choices?.isEmpty == true || linkState == .expired { return .stopped }
        return choices == nil ? .waiting : .choosing
    }

    /// Where the remote lands on a step: the first kind, the first server,
    /// or the one way out a waiting or stopped step offers.
    private var landing: AddFocus {
        switch stage {
        case .kinds: store.modules.first.map { .module($0.id) } ?? .cancel
        case .choosing: choices?.first.map { .choice($0.id) } ?? .cancel
        case .waiting: .cancel
        case .stopped: .add
        }
    }

    private var kindPicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(t("settings.addSourceKind"))
                .font(Theme.Typography.title)
                .tracking(Theme.Typography.titleTracking)
                .foregroundStyle(Theme.Colors.white)
                .padding(.bottom, Theme.Space.s24)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 480, maximum: 480), spacing: Theme.Space.s24, alignment: .topLeading)],
                alignment: .leading, spacing: Theme.Space.s24
            ) {
                ForEach(store.modules, id: \.id) { module in
                    ModuleCard(module: module, picked: picked?.id == module.id) { pick(module) }
                        .focused($focus, equals: .module(module.id))
                }
            }
            .padding(.bottom, Theme.Space.s16)
            if let picked, case .fields(let fields) = picked.setup {
                ForEach(fields, id: \.key) { field in
                    Field(
                        label: I18n.shared.moduleText("\(picked.id).\(field.key)", "label", fallback: field.key),
                        value: Binding(get: { values[field.key] ?? "" }, set: { values[field.key] = $0 }),
                        secure: field.kind == .secret
                    )
                    .focused($focus, equals: .field(field.key))
                }
                ActionButton(label: t("settings.add")) {
                    Task {
                        if let id = await store.addSource(module: picked.id, values: values) { onDone(id) }
                    }
                }
                .focused($focus, equals: .add)
                .padding(.bottom, Theme.Space.s16)
            }
            ActionButton(label: t("settings.cancel"), action: onCancel)
                .focused($focus, equals: .cancel)
        }
        .defaultFocus($focus, store.modules.first.map { .module($0.id) } ?? .cancel)
    }

    private func pick(_ module: SourceModuleInfo) {
        picked = module
        values = [:]
        if case .link = module.setup {
            let page = I18n.shared.moduleText(module.id, "linkUrl", fallback: "")
            let filter = CIFilter.qrCodeGenerator()
            filter.message = Data(page.utf8)
            filter.correctionLevel = "M"
            qr = page.isEmpty ? nil : filter.outputImage.flatMap { CIContext().createCGImage($0, from: $0.extent) }
            if let link { store.linkCancel(handle: link.handle) }
            link = nil
            linkState = nil
            choices = nil
            failure = nil
            Task {
                link = await store.linkStart(module: module.id)
                if link == nil { failure = .unreachable }
            }
        }
    }

    @ViewBuilder private func linkFlow(_ module: SourceModuleInfo) -> some View {
        if let failure {
            stopped(t(failure.key), module)
        } else if let choices, choices.isEmpty {
            stopped(t("settings.linkNoServer"), module)
        } else if let choices {
            VStack(alignment: .leading, spacing: Theme.Space.s16) {
                Text(I18n.shared.moduleText(module.id, "choiceTitle"))
                    .font(Theme.Typography.title)
                    .tracking(Theme.Typography.titleTracking)
                    .foregroundStyle(Theme.Colors.white)
                    .padding(.bottom, Theme.Space.s16)
                ForEach(choices, id: \.id) { choice in
                    ActionButton(label: "\(choice.name) - \(t(choice.nearby ? "settings.nearby" : "settings.remote"))") {
                        guard let link else { return }
                        Task {
                            if let id = await store.addFromChoice(handle: link.handle, choice: choice) { onDone(id) }
                        }
                    }
                    .focused($focus, equals: .choice(choice.id))
                }
            }
            .defaultFocus($focus, choices.first.map { .choice($0.id) } ?? .cancel)
        } else if linkState == .expired {
            stopped(t("settings.linkExpired"), module)
        } else if linkState == .linked {
            VStack(alignment: .leading, spacing: Theme.Space.s24) {
                Text(t("settings.findingServers"))
                    .font(Theme.Typography.title)
                    .tracking(Theme.Typography.titleTracking)
                    .foregroundStyle(Theme.Colors.white)
                ActionButton(label: t("settings.cancel"), action: onCancel).focused($focus, equals: .cancel)
            }
            .defaultFocus($focus, .cancel)
        } else {
            codeShown(module)
        }
    }

    /// The flow ended on something the viewer can only retry: a new code
    /// for the same kind, or back out.
    private func stopped(_ heading: String, _ module: SourceModuleInfo) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s24) {
            Text(heading)
                .font(Theme.Typography.title)
                .tracking(Theme.Typography.titleTracking)
                .foregroundStyle(Theme.Colors.white)
            HStack(spacing: Theme.Space.s24) {
                ActionButton(label: t("settings.tryAgain"), primary: true) { pick(module) }
                    .focused($focus, equals: .add)
                ActionButton(label: t("settings.cancel"), action: onCancel).focused($focus, equals: .cancel)
            }
        }
        .defaultFocus($focus, .add)
    }

    private func codeShown(_ module: SourceModuleInfo) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(I18n.shared.moduleText(module.id, "instruction"))
                .font(Theme.Typography.title)
                .tracking(Theme.Typography.titleTracking)
                .foregroundStyle(Theme.Colors.white)
                .padding(.bottom, Theme.Space.s24)
            HStack(alignment: .top, spacing: Theme.Space.s40) {
                VStack(alignment: .leading, spacing: 0) {
                    Group {
                        if let code = link?.code {
                            Text(code)
                                .font(Theme.Typography.title)
                                .tracking(8)
                                .foregroundStyle(Theme.Colors.accent)
                        } else {
                            ProgressView()
                        }
                    }
                        .padding(.horizontal, Theme.Space.s40)
                        .padding(.vertical, Theme.Space.s16)
                        .background(Theme.Glass.well, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                                .strokeBorder(Theme.Glass.rule, lineWidth: 1))
                        .padding(.bottom, Theme.Space.s16)
                    Text(t("settings.waitingForCode"))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textMuted)
                }
                VStack(alignment: .leading, spacing: Theme.Space.s16) {
                    step(1, t("settings.linkStepCode"))
                    step(2, t("settings.linkStepChoose"))
                }
                if let qr {
                    VStack(spacing: Theme.Space.s16) {
                        Image(decorative: qr, scale: 1)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 200, height: 200)
                            .padding(Theme.Space.s16)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        Text(t("settings.linkScan"))
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.textMuted)
                    }
                }
            }
            .padding(Theme.Space.s40)
            .glassSurface(radius: Theme.Radius.panel, tint: Theme.Glass.panel)
            .padding(.bottom, Theme.Space.s16)
            ActionButton(label: t("settings.cancel"), action: onCancel).focused($focus, equals: .cancel)
        }
        .defaultFocus($focus, .cancel)
    }

    private func step(_ number: Int, _ label: String) -> some View {
        HStack(spacing: Theme.Space.s16) {
            Text(String(number))
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.text)
                .frame(width: 40, height: 40)
                .background(Theme.Glass.rule, in: Circle())
            Text(label).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.textSecondary)
        }
    }

    /// Waits for the code to be used, then for the account's servers. Ends
    /// on the first failure. A cancelled wait ends in the core once
    /// `linkCancel` drops the session, and its answer is ignored here.
    private func followLink() async {
        guard let link else { return }
        let core = CoreClient.shared
        do {
            let state = try await core.linkWait(handle: link.handle)
            if Task.isCancelled { return }
            linkState = state
            guard state == .linked else { return }
            let found = try await core.linkChoices(handle: link.handle)
            if Task.isCancelled { return }
            choices = found
        } catch {
            if !Task.isCancelled { failure = LinkFailure(error) }
        }
    }
}

/// One kind of source to add: its mark, its name, what it does and whether
/// it reaches out or stays nearby. The picked one wears the accent.
private struct ModuleCard: View {
    let module: SourceModuleInfo
    let picked: Bool
    let onPress: () -> Void

    var body: some View {
        let description = I18n.shared.moduleText(module.id, "description", fallback: "")
        let remote = if case .link = module.setup { true } else { false }
        Button(action: onPress) {
            FocusReader { focused in
                VStack(alignment: .leading, spacing: 0) {
                    GlyphView(glyph: Glyph.forModule(module.glyph), size: 30)
                        .foregroundStyle(picked ? Theme.Colors.onAccent : Theme.Colors.textSecondary)
                        .frame(width: 64, height: 64)
                        .background(
                            picked ? Theme.Colors.accent : Theme.Glass.rule,
                            in: RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
                    Text(I18n.shared.moduleText(module.id, "label"))
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.text)
                        .padding(.top, Theme.Space.s24)
                    if !description.isEmpty {
                        Text(description)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.textMuted)
                            .lineSpacing(32 - 23)
                            .padding(.top, Theme.Space.s8)
                    }
                    Chip(text: t(remote ? "settings.remote" : "settings.nearby"))
                        .padding(.top, Theme.Space.s24)
                }
                .padding(Theme.Space.s24)
                .frame(width: 480, alignment: .leading)
                .background(GlassSurface(radius: Theme.Radius.panel, interactive: true, tint: Theme.Glass.panel))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous)
                        .strokeBorder(
                            focused ? Theme.Colors.white : Theme.Colors.accent,
                            lineWidth: focused ? Theme.Focus.ring : (picked ? 2 : 0)))
                .scaleEffect(focused ? Theme.Focus.wide : 1)
                .animation(.easeOut(duration: Theme.Motion.focus), value: focused)
            }
        }
        .buttonStyle(CardButtonStyle())
        .accessibilityLabel(I18n.shared.moduleText(module.id, "label"))
    }
}

import LexisCore
import SwiftUI

/// How the propositions fare over a week, a month and a season: what was
/// launched, from where, what of it was finished, and how often the evening's
/// trio was taken up. A table and nothing else: it is read to tune the engine.
struct StatsScreen: View {
    @Environment(Navigator.self) private var navigator
    @State private var windows: [RecoStats] = []
    /// The encoder key the core runs, a setting kept off the settings screen:
    /// the larger one is a 1.1 GB download and a re-embedding of the library.
    @State private var encoder: String?

    private static let days: [UInt32] = [7, 30, 90]
    private static let cell: CGFloat = 260

    var body: some View {
        ZStack(alignment: .top) {
            Backdrop(titleId: nil, picture: false)
            VStack(alignment: .leading, spacing: 0) {
                SectionHead(title: t("stats.title"), trailing: t("stats.head"))
                    .padding(.top, Theme.Space.s64)
                if windows.count == StatsScreen.days.count {
                    table
                }
            }
        }
        .onExitCommand { navigator.back() }
        .task { await load() }
    }

    private var table: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                StatsLine(
                    label: "", cells: StatsScreen.days.map { t("stats.days", ["n": String($0)]) },
                    head: true)
                StatsLine(label: t("stats.launches"), cells: windows.map { String($0.launches) })
                StatsLine(
                    label: t("stats.finished"),
                    cells: windows.map { "\($0.finished) / \($0.launches)" })
                StatsLine(
                    label: t("stats.trio"),
                    cells: windows.map { "\($0.trioAccepted) / \($0.trioEvenings)" })
                StatsLine(
                    label: t("stats.decision"),
                    cells: windows.map { stats in
                        stats.medianDecisionSecs.map { Format.clock(Double($0), withHours: false) } ?? "-"
                    })
                StatsLine(
                    label: t("stats.deferrals"),
                    cells: windows.map {
                        $0.deferralsPerEvening.formatted(.number.precision(.fractionLength(1)))
                    })
                // the longest window holds every surface the shorter ones do
                let surfaces = windows[windows.count - 1].surfaces
                if !surfaces.isEmpty {
                    StatsLine(
                        label: t("stats.bySurface"), cells: StatsScreen.days.map { _ in "" }, head: true
                    )
                    .padding(.top, Theme.Space.s40)
                }
                ForEach(Array(surfaces.enumerated()), id: \.offset) { _, row in
                    StatsLine(
                        label: StatsScreen.name(row),
                        cells: windows.map { stats in
                            let found = stats.surfaces.first {
                                $0.surface == row.surface && $0.detail == row.detail
                            }
                            return "\(found?.finished ?? 0) / \(found?.launched ?? 0)"
                        })
                }
                if let encoder {
                    Button { switchEncoder(from: encoder) } label: {
                        HStack(spacing: 0) {
                            Text(t("stats.encoder"))
                                .fits(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(t("stats.encoder.\(encoder)"))
                                .fits(1)
                        }
                        .font(Theme.Typography.body)
                    }
                    .buttonStyle(FilledControlStyle())
                    .padding(.top, Theme.Space.s40)
                    Text(t("stats.encoder.note"))
                        .fits(2)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textMuted)
                        .padding(.top, Theme.Space.s16)
                }
            }
            .padding(.horizontal, Theme.Layout.gutter)
            .padding(.top, Theme.Space.s40)
            .padding(.bottom, Theme.Space.s64)
        }
    }

    /// A home row is named by the kind of its reason, never by a title.
    private static func name(_ row: SurfaceStat) -> String {
        let surface = t("stats.surface.\(row.surface)")
        return row.detail.isEmpty ? surface : "\(surface), \(t("stats.reason.\(row.detail)"))"
    }

    private func load() async {
        let tz = Format.tzOffsetSecs, days = StatsScreen.days
        let fetched = await CoreClient.run {
            (
                days.compactMap { try? CoreClient.shared.recoStats(days: $0, tzOffsetSecs: tz) },
                try? CoreClient.shared.encoder()
            )
        }
        windows = fetched.0
        encoder = fetched.1
    }

    /// The other encoder, and the pass that re-embeds the library with it.
    private func switchEncoder(from current: String) {
        let next = current == "base" ? "small" : "base"
        Task {
            let switched = await CoreClient.run {
                guard (try? CoreClient.shared.setEncoder(model: next)) != nil else { return false }
                CoreClient.shared.startPass()
                return true
            }
            if switched { encoder = next }
        }
    }

    /// One line of the table: a label, and one cell per window. Focusable so
    /// the remote can scroll a table longer than the screen.
    private struct StatsLine: View {
        let label: String
        let cells: [String]
        var head = false
        @FocusState private var focused: Bool

        var body: some View {
            HStack(spacing: 0) {
                Text(label)
                    .fits(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                    Text(cell)
                        .fits(1)
                        .frame(width: StatsScreen.cell, alignment: .trailing)
                }
            }
            .font(head ? Theme.Typography.label : Theme.Typography.body)
            .foregroundStyle(head ? Theme.Colors.textMuted : Theme.Colors.text)
            .padding(.vertical, Theme.Space.s16)
            .padding(.horizontal, Theme.Space.s16)
            .background(
                Theme.Colors.white.opacity(focused ? 0.1 : 0),
                in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.Glass.rule).frame(height: Theme.Focus.seam)
            }
            .focusable(!head)
            .focused($focused)
        }
    }
}

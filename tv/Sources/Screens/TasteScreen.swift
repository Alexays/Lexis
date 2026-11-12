import LexisCore
import SwiftUI

/// The four tastes that decide what the app offers, how far each has moved
/// this month, and the log of what moved it.
///
/// A taste drawn once and never again is looked at once: the research on
/// every taste artefact that has shipped says the same thing. What holds
/// anyone is a number that changes and a record that accumulates, which is
/// why the shift and the log are the screen and the four names are only its
/// heading.
struct TasteScreen: View {
    @Environment(Navigator.self) private var navigator
    @State private var facets: [ApiTasteFacet] = []
    @State private var ledger: [ApiTasteEvent] = []
    @State private var profile: TasteProfile?
    @State private var loaded = false

    /// How far back the shift compares. A month is long enough that an
    /// evening does not swing it and short enough that it is still this
    /// month's number.
    private static let window: Int64 = 30 * 86_400
    private static let depth: UInt32 = 12

    var body: some View {
        ZStack(alignment: .top) {
            Backdrop(titleId: nil, picture: false)
            VStack(alignment: .leading, spacing: 0) {
                SectionHead(title: t("taste.title"), trailing: t("taste.head"))
                    .padding(.top, Theme.Space.s64)
                if loaded && facets.isEmpty {
                    empty
                } else {
                    columns
                }
                Spacer(minLength: 0)
                Text(t("taste.note"))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textMuted)
                    .fits(3)
                    .frame(maxWidth: TasteScreen.prose, alignment: .leading)
                    .padding(.horizontal, Theme.Layout.gutter)
                    .padding(.bottom, Theme.Space.s40)
            }
        }
        .onExitCommand { navigator.back() }
        .task { await load() }
    }

    private static let prose: CGFloat = 1180
    private static let ledgerColumn: CGFloat = 640

    private var columns: some View {
        HStack(alignment: .top, spacing: Theme.Space.s104) {
            VStack(alignment: .leading, spacing: Theme.Space.s40) {
                ForEach(Array(facets.enumerated()), id: \.offset) { _, facet in
                    Facet(
                        facet: facet, profile: profile?.facets.first { $0.leaderId == facet.leaderId },
                        onMute: { contest(facet.leaderId, muted: $0) })
                }
                if let avoid = profile?.avoid, !avoid.isEmpty {
                    Text(t("taste.avoid", ["genres": avoid.map(Format.genre).joined(separator: ", ")]))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textMuted)
                        .fits(1)
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(t("taste.ledger"))
                    .font(Theme.Typography.label)
                    .tracking(Theme.Typography.labelTracking)
                    .foregroundStyle(Theme.Colors.textMuted)
                    .padding(.bottom, Theme.Space.s24)
                ForEach(Array(ledger.enumerated()), id: \.offset) { _, event in
                    Entry(event: event)
                }
                if loaded && ledger.isEmpty {
                    Text(t("taste.empty"))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textMuted)
                }
            }
            .frame(width: TasteScreen.ledgerColumn, alignment: .leading)
        }
        .padding(.horizontal, Theme.Layout.gutter)
        .padding(.top, Theme.Space.s64)
    }

    private var empty: some View {
        Text(t("taste.empty"))
            .font(Theme.Typography.body)
            .foregroundStyle(Theme.Colors.textMuted)
            .padding(.horizontal, Theme.Layout.gutter)
            .padding(.top, Theme.Space.s64)
    }

    /// "Less of this", or taking it back. The mark is read back at once; the
    /// share follows the taste pass the core runs behind the press.
    private func contest(_ leader: Int64, muted: Bool) {
        Task {
            await CoreClient.run {
                try? muted
                    ? CoreClient.shared.muteTaste(leaderTitleId: leader)
                    : CoreClient.shared.unmuteTaste(leaderTitleId: leader)
            }
            await load()
        }
    }

    private func load() async {
        let (window, depth) = (TasteScreen.window, TasteScreen.depth)
        let fetched = await CoreClient.run {
            (
                try? CoreClient.shared.tasteFacets(sinceSecs: window),
                try? CoreClient.shared.tasteLedger(limit: depth),
                try? CoreClient.shared.tasteProfile()
            )
        }
        facets = fetched.0 ?? []
        ledger = fetched.1 ?? []
        profile = fetched.2
        loaded = true
    }
}

/// One taste: the title that names it, the share of the history behind it,
/// where it has moved, and what sets it apart from the library, in words.
private struct Facet: View {
    let facet: ApiTasteFacet
    let profile: ProfileFacet?
    let onMute: (Bool) -> Void

    private static let rule: CGFloat = 1080

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s24) {
                Text(t("taste.ledBy", ["title": facet.leader]))
                    .font(Theme.Typography.title)
                    .tracking(Theme.Typography.titleTracking)
                    .foregroundStyle(Theme.Colors.text)
                    .fits(1)
                Spacer(minLength: 0)
                if facet.muted {
                    Text(t("taste.muted"))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textMuted)
                        .fits(1)
                } else if let shift = Facet.shift(facet.shift) {
                    Text(shift.text)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(shift.tone)
                        .fits(1)
                }
                Button(t(facet.muted ? "taste.unmute" : "taste.less")) { onMute(!facet.muted) }
                    .buttonStyle(FilledControlStyle())
                    .font(Theme.Typography.caption)
            }
            Capsule()
                .fill(Theme.Colors.white.opacity(0.1))
                .frame(width: Facet.rule, height: Theme.Resume.height)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(Theme.Colors.accent)
                        .frame(
                            width: Facet.rule * Double(min(max(facet.weight, 0), 1)),
                            height: Theme.Resume.height)
                }
                .padding(.top, Theme.Space.s16)
            if let profile {
                ForEach(Facet.lines(profile), id: \.self) { line in
                    Text(line)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .fits(1)
                        .frame(maxWidth: Facet.rule, alignment: .leading)
                        .padding(.top, Theme.Space.s8)
                }
            }
        }
    }

    /// What the taste is, then who makes it and what it is about: each line
    /// only when the core had something to say for it.
    private static func lines(_ p: ProfileFacet) -> [String] {
        var what: [String] = []
        if !p.genres.isEmpty { what.append(p.genres.map(Format.genre).joined(separator: ", ")) }
        if p.decadeFrom > 0 {
            what.append(
                p.decadeFrom == p.decadeTo
                    ? t("taste.decade", ["decade": Format.decadeName(p.decadeFrom)])
                    : t("taste.decades", [
                        "from": Format.decadeName(p.decadeFrom), "to": Format.decadeName(p.decadeTo),
                    ]))
        }
        if !p.tones.isEmpty { what.append(p.tones.map { t("tone.\($0)") }.joined(separator: ", ")) }
        var who: [String] = []
        if !p.directors.isEmpty {
            who.append(t("taste.by", ["names": p.directors.joined(separator: ", ")]))
        }
        if !p.keywords.isEmpty {
            who.append(t("taste.about", ["words": p.keywords.joined(separator: ", ")]))
        }
        return [what, who].filter { !$0.isEmpty }.map { $0.joined(separator: "  ·  ") }
    }

    /// Nil where the core has no snapshot old enough to compare against:
    /// that is "not known yet", which is not the same as "unchanged", and
    /// drawing it as nought would be a claim the data does not make.
    private static func shift(_ shift: Float?) -> (text: String, tone: Color)? {
        guard let shift else { return nil }
        let points = Int((shift * 100).rounded())
        if points == 0 { return (t("taste.unchanged"), Theme.Colors.textMuted) }
        return points > 0
            ? (t("taste.shiftUp", ["n": String(points)]), Theme.Colors.accent)
            : (t("taste.shiftDown", ["n": String(-points)]), Theme.Colors.error)
    }
}

/// One thing that moved the taste, and when.
private struct Entry: View {
    let event: ApiTasteEvent

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.s24) {
            Text(Format.relativeTime(event.at).uppercased())
                .font(Theme.Typography.label)
                .tracking(Theme.Typography.labelTracking)
                .foregroundStyle(Theme.Colors.textMuted)
                .frame(width: Entry.when, alignment: .leading)
            Text(t(Entry.key(event.kind), ["title": event.title]))
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textSecondary)
                .fits(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, Theme.Space.s16)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.Glass.rule).frame(height: Theme.Focus.seam)
        }
    }

    /// Wide enough for "IL Y A 12 MINUTES" in capitals and tracking.
    private static let when: CGFloat = 280

    private static func key(_ kind: ApiTasteEventKind) -> String {
        switch kind {
        case .finished: "taste.eventFinished"
        case .verdict: "taste.eventVerdict"
        case .deferred: "taste.eventDeferred"
        case .queued: "taste.eventQueued"
        }
    }
}

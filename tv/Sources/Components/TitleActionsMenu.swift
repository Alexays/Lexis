import LexisCore
import SwiftUI

/// The actions a title carries wherever it is drawn. A press opens the
/// title; a press held opens this. Nothing is ever drawn on the card, so the
/// remote only meets titles as it walks a row.
///
/// It was the other way round once: the actions lived in an overlay inside
/// the card button's own label, where the focus engine could never reach
/// them. A focusable inside another focusable's label is drawn and never
/// visited.
struct TitleActionsMenu: ViewModifier {
    let item: TitleItem
    /// The row the title was drawn in, so "more like this" has somewhere to
    /// go. Absent where the title stands on its own.
    var reason: HomeReason?
    /// How many titles that row holds, named in the entry itself: a door is
    /// worth opening when you know what is behind it.
    var count: Int?
    /// The evening's remaining passes, shown in the entry because a budget
    /// nobody sees is a budget nobody spends.
    var passesLeft: UInt32
    let onOpenRow: (HomeReason) -> Void
    let onPlay: (TitleItem) -> Void

    func body(content: Content) -> some View {
        // The entries are a view of their own: their labels and the title's
        // state are read when the menu is drawn, not each time the card is.
        content.contextMenu {
            TitleActionsEntries(
                item: item, reason: reason, count: count, passesLeft: passesLeft,
                onOpenRow: onOpenRow, onPlay: onPlay)
        }
    }
}

private struct TitleActionsEntries: View {
    let item: TitleItem
    let reason: HomeReason?
    let count: Int?
    let passesLeft: UInt32
    let onOpenRow: (HomeReason) -> Void
    let onPlay: (TitleItem) -> Void

    var body: some View {
        // The hero has usually read the title under the remote already; until
        // the facts land, a title on My List is taken as on it.
        let detail = HeroFacts.shared.slot(item.id).detail
        let listed = detail?.inWatchlist ?? onMyList
        let watched = detail?.watched ?? false
        let id = item.id
        if item.firstFileId != nil {
            Button(t("hold.play")) { onPlay(item) }
        }
        if let reason {
            Button(count.map { t("hold.moreCount", ["count": String($0)]) } ?? t("hold.more")) {
                onOpenRow(reason)
            }
        }
        Button(t(listed ? "hold.unqueue" : "hold.queue")) {
            write { try $0.setWatchlist(titleId: id, on: !listed) }
        }
        Button(t(watched ? "hold.unwatched" : "hold.watched")) {
            write { try $0.markWatched(titleId: id, watched: !watched) }
        }
        Button(
            passesLeft == 0 ? t("hold.notTonightNone") : t("hold.notTonight", ["count": String(passesLeft)])
        ) { deferTonight() }
        .disabled(passesLeft == 0)
        if let contested {
            Button(t("hold.notBecause", ["title": contested.name])) {
                write { try $0.muteTaste(leaderTitleId: contested.id) }
            }
        }
        Button(t("hold.never"), role: .destructive) {
            write { try $0.setVerdict(titleId: id, verdict: .down) }
        }
    }

    private var onMyList: Bool {
        if case .watchlist? = reason { true } else { false }
    }

    /// The title a taste row names, which "not because of" contests.
    private var contested: (name: String, id: Int64)? {
        switch reason {
        case .tasteFacet(let leader, let id)?: (leader, id)
        case .becauseYouWatched(let seed, let id)?: (seed, id)
        default: nil
        }
    }

    /// The core answers a deferral with the trio that replaces it, so the
    /// home takes that one rather than asking for it again.
    private func deferTonight() {
        let id = item.id, tz = Format.tzOffsetSecs
        Task {
            guard case .success(let trio) = await CoreClient.run({
                Result { try CoreClient.shared.tonightDefer(titleId: id, tzOffsetSecs: tz) }
            }) else { return }
            NotificationCenter.default.post(name: .tonightChanged, object: trio)
        }
    }

    /// The core says nothing of a write, so the screens are told here, and reload.
    private func write(_ body: @escaping @Sendable (LexisCore) throws -> Void) {
        Task {
            await CoreClient.run { _ = try? body(CoreClient.shared) }
            NotificationCenter.default.post(name: .watchStateChanged, object: nil)
        }
    }
}

extension View {
    func titleActions(
        for item: TitleItem, reason: HomeReason? = nil, count: Int? = nil, passesLeft: UInt32,
        onOpenRow: @escaping (HomeReason) -> Void, onPlay: @escaping (TitleItem) -> Void
    ) -> some View {
        modifier(
            TitleActionsMenu(
                item: item, reason: reason, count: count, passesLeft: passesLeft,
                onOpenRow: onOpenRow, onPlay: onPlay))
    }
}

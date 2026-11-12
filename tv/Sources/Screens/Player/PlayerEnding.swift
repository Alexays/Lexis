import LexisCore
import SwiftUI

/// The countdown to the next episode. It owns the remote: "Play now" takes
/// focus, and the row of round buttons is gone while it runs.
struct UpNextCard: View {
    let model: PlayerModel
    let next: EpisodeRef
    let focus: FocusState<PlayerFocus?>.Binding
    let move: (PlayerFocus) -> Void

    /// The episode's number and its own name, where it has one.
    static func label(_ next: EpisodeRef) -> String {
        let code = Format.episodeCode(season: next.season, episode: next.episode)
        guard !code.isEmpty else { return next.title.isEmpty ? next.name : next.title }
        return next.title.isEmpty ? code : "\(code) · \(next.title)"
    }

    /// The show, over the label.
    static func context(_ next: EpisodeRef) -> String {
        Format.episodeCode(season: next.season, episode: next.episode).isEmpty && next.title.isEmpty ? "" : next.name
    }

    var body: some View {
        let context = Self.context(next), label = Self.label(next)
        // an episode not yet begun is veiled, as on the title's page
        let veiled = !(next.watched || next.resumePositionSecs > 0)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 24) {
                ArtworkImage(kind: veiled ? .veiledStill(fileId: next.fileId) : .still(fileId: next.fileId)) {
                    Theme.Colors.bg2
                }
                .frame(width: 240, height: 135)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.countdown > 0
                        ? t("player.advanceLabel", ["seconds": String(model.countdown)])
                        : t("player.stillWatching"))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textMuted)
                    Text(context.isEmpty ? label : "\(context) \(label)")
                        .font(Theme.Typography.title)
                        .tracking(Theme.Typography.titleTracking)
                        .foregroundStyle(Theme.Colors.text)
                        .lineLimit(2)
                        .padding(.top, 8)
                }
            }
            HStack(spacing: 20) {
                ActionButton(label: t("player.advanceNow"), primary: true, font: Theme.Typography.body) {
                    model.wake()
                    model.advanceNow()
                }
                .focused(focus, equals: .advanceNow)
                .onMoveCommand { direction in
                    model.wake()
                    if direction == .right { move(.advanceCancel) }
                }
                ActionButton(label: t("player.advanceCancel"), font: Theme.Typography.body) {
                    model.wake()
                    model.cancelAdvance()
                }
                .focused(focus, equals: .advanceCancel)
                .onMoveCommand { direction in
                    model.wake()
                    if direction == .left { move(.advanceNow) }
                }
            }
            .padding(.top, 24)
        }
        .padding(32)
        .frame(maxWidth: 900, alignment: .leading)
        .glassSurface(radius: Theme.Player.panelRadius, tint: Theme.Glass.panel)
    }
}

/// The credits question, in the title row's own anatomy: what the viewer
/// made of the film, or whether tomorrow night's proposal sounds good.
struct AskRow: View {
    let model: PlayerModel
    let asking: PlayerModel.Asking
    let focus: FocusState<PlayerFocus?>.Binding
    let move: (PlayerFocus) -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(t(asking == .verdict ? "player.verdictAsk" : "player.afterThis"))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(PlayerInk.context)
                Text(name)
                    .font(.system(size: Theme.Player.title, weight: .bold))
                    .foregroundStyle(Theme.Colors.white)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 40)
            HStack(spacing: 20) {
                switch asking {
                case .verdict:
                    action(0, glyph: .thumbLove, spoken: t("title.love")) { model.answerVerdict(.loved) }
                    action(1, glyph: .thumbUp, spoken: t("title.like")) { model.answerVerdict(.up) }
                    action(2, glyph: .thumbDown, spoken: t("title.dislike")) { model.answerVerdict(.down) }
                case .after:
                    action(0, label: t("player.afterThisYes"), primary: true) { model.acceptProposal() }
                    action(1, label: t("player.afterThisNo")) { model.declineProposal() }
                }
            }
        }
        .padding(.horizontal, Theme.Player.margin)
        .padding(.bottom, Theme.Player.bottom)
    }

    private var name: String {
        switch asking {
        case .verdict: model.playing.title
        case .after(let proposal): proposal.name
        }
    }

    private var count: Int { asking == .verdict ? 3 : 2 }

    private func action(
        _ at: Int, glyph: Glyph? = nil, label: String = "", spoken: String? = nil, primary: Bool = false,
        _ press: @escaping () -> Void
    ) -> some View {
        ActionButton(
            label: label, glyph: glyph, spoken: spoken, primary: primary, compact: label.isEmpty,
            font: Theme.Typography.body) {
            model.wake()
            press()
        }
        .focused(focus, equals: .ask(at))
        .onMoveCommand { direction in
            model.wake()
            switch direction {
            case .left: if at > 0 { move(.ask(at - 1)) }
            case .right: if at + 1 < count { move(.ask(at + 1)) }
            default: break
            }
        }
    }
}

import LexisPlayer
import SwiftUI
import UIKit

/// What is composited over the film while the overlay is up, laid out on
/// the native player's measures: the gradient, the title row and its round
/// buttons, the bar, the pills, and whichever tab or popover is open.
struct PlayerOverlay: View {
    let model: PlayerModel
    let focus: FocusState<PlayerFocus?>.Binding
    let move: (PlayerFocus) -> Void

    private var shift: CGFloat {
        if case .tab = model.shown { return Theme.Player.tabShift }
        return 0
    }

    /// The title row, the round buttons and the pills: a skip, a hold or a
    /// scrub draws the bar alone.
    private var chrome: Bool { model.shown != .barOnly && model.shown != .scrubbing }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Scrim(direction: .vertical)
                .frame(width: Theme.Layout.screenWidth, height: Theme.Player.gradientHeight)
                .offset(y: Theme.Layout.screenHeight - Theme.Player.gradientHeight)
            if model.waiting {
                notice.frame(width: Theme.Layout.screenWidth, height: Theme.Layout.screenHeight)
            }
            ZStack(alignment: .topLeading) {
                if chrome {
                    fallback
                    titleRow
                    roundButtons
                    if model.next == nil, model.asking == nil { pills }
                }
                if model.shown == .scrubbing, model.scrubCard { ScrubCard(model: model) }
                TransportControl(model: model, focus: focus, move: move)
                    .offset(x: Theme.Player.rowInset, y: Theme.Player.barTop)
            }
            // The screen's frame, so the group's glass is laid out where its
            // offset members are; inside the shift, so it moves with them.
            .frame(width: Theme.Layout.screenWidth, height: Theme.Layout.screenHeight, alignment: .topLeading)
            // one container effect for the pills and the round buttons over the film
            .glassGroup(spacing: 0, tint: Theme.Glass.control)
            .offset(y: -shift)
            if case .tab(let tab) = model.shown {
                TabContent(model: model, tab: tab, focus: focus, move: move)
                    .offset(x: Theme.Player.rowInset, y: Theme.Player.tabContentTop)
                    .id(tab)
                    .transition(.opacity.combined(with: .offset(y: Theme.Space.s24)))
            }
            if case .menu(let menu) = model.shown {
                TrackMenu(model: model, menu: menu, focus: focus, move: move)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            }
        }
        .frame(width: Theme.Layout.screenWidth, height: Theme.Layout.screenHeight, alignment: .topLeading)
        // one motion for every change of state, so what slides and what
        // appears with it move together rather than one popping in
        .animation(.spring(response: 0.35, dampingFraction: 0.9), value: model.shown)
        .overlay {
            if model.status == .buffering { RebufferCard(seconds: Int(model.bufferedSeconds.rounded(.down))) }
        }
    }

    /// A spinner and no words while a film is on its way; a failure is the
    /// screen's own card.
    private var notice: some View {
        ProgressView()
            .tint(PlayerInk.time)
            .scaleEffect(1.6)
            .frame(width: 52, height: 52)
            .accessibilityLabel(t("player.connecting"))
            .playerNotice()
    }

    @ViewBuilder private var fallback: some View {
        if model.audioFallback || model.subtitleFallback {
            HStack(spacing: 16) {
                if model.audioFallback { Text(t("player.audioFallback")) }
                if model.subtitleFallback { Text(t("player.subtitleFallback")) }
            }
            .font(.system(size: Theme.Player.context))
            .foregroundStyle(PlayerInk.context)
            .offset(x: Theme.Player.margin, y: Theme.Player.contextTop - Theme.Player.contextHeight - Theme.Space.s16)
        }
    }

    @ViewBuilder private var titleRow: some View {
        let width = Theme.Player.rowInset + Theme.Player.rowWidth
            - CGFloat(model.glyphRow.count) * (Theme.Player.roundButton + Theme.Player.roundButtonGap)
            - Theme.Player.margin - Theme.Space.s40
        if !model.heading.context.isEmpty {
            Text(model.heading.context)
                .font(.system(size: Theme.Player.context, weight: .medium))
                .foregroundStyle(Theme.Colors.white)
                .lineLimit(1)
                .frame(maxWidth: width, minHeight: Theme.Player.contextHeight, alignment: .leading)
                .accessibilityIdentifier("player.context")
                .offset(x: Theme.Player.margin, y: Theme.Player.contextTop)
        }
        Text(model.heading.title)
            .font(.system(size: Theme.Player.title, weight: .bold))
            .foregroundStyle(Theme.Colors.white)
            .lineLimit(1)
            .frame(maxWidth: width, minHeight: Theme.Player.titleHeight, alignment: .leading)
            .accessibilityIdentifier("player.title")
            .offset(x: Theme.Player.margin, y: Theme.Player.titleTop)
    }

    private var roundButtons: some View {
        HStack(spacing: Theme.Player.roundButtonGap) {
            ForEach(model.glyphRow, id: \.self) { control in
                roundButton(control)
            }
        }
        .frame(width: Theme.Player.rowWidth, alignment: .trailing)
        .offset(x: Theme.Player.rowInset, y: Theme.Player.roundButtonTop)
    }

    private func roundButton(_ control: PlayerControl) -> some View {
        let menu: PlayerMenu = control == .audio ? .audio : .subtitles
        var open = false
        if case .menu(let shown) = model.shown { open = shown.button == control }
        return RoundGlyphButton(
            glyph: control == .audio ? .audioTracks : .subtitles, open: open,
            spoken: t(control == .audio ? "player.audio" : "player.subtitles")
        ) {
            model.wake()
            model.openMenu(menu)
        }
        .focused(focus, equals: .control(control))
        .accessibilityIdentifier(control == .audio ? "player.audio" : "player.subtitles")
        .onMoveCommand { direction in
            model.wake()
            let row = model.glyphRow
            guard let at = row.firstIndex(of: control) else { return }
            switch direction {
            case .left: if at > 0 { move(.control(row[at - 1])) }
            case .right: if at + 1 < row.count { move(.control(row[at + 1])) }
            case .down: move(.control(.bar))
            case .up: if model.skipping != nil { move(.skip) }
            default: break
            }
        }
    }

    private var pills: some View {
        HStack(spacing: Theme.Player.pillGap) {
            ForEach(model.tabs, id: \.self) { tab in
                TabPill(model: model, tab: tab, focus: focus, move: move)
            }
        }
        .offset(x: Theme.Player.pillsLeft, y: Theme.Player.pillTop)
    }
}

/// The bar and its button: the one part of the overlay that moves with the
/// film, its own view so a tick or a gesture step re-renders it alone.
private struct TransportControl: View {
    let model: PlayerModel
    let focus: FocusState<PlayerFocus?>.Binding
    let move: (PlayerFocus) -> Void

    var body: some View {
        Button {
            model.wake()
            model.select()
        } label: {
            TransportBar(
                position: model.scrub ?? model.position, duration: model.duration,
                bufferedSeconds: model.bufferedSeconds, scrubbing: model.shown == .scrubbing,
                chapters: model.chapters,
                indicator: model.indicator ?? (model.status == .paused ? .paused : nil))
        }
        .buttonStyle(CardButtonStyle(shadow: false))
        .focused(focus, equals: .control(.bar))
        .onMoveCommand { direction in
            switch direction {
            case .left: model.tap(back: true)
            case .right: model.tap(back: false)
            case .down:
                model.wake()
                guard let first = model.tabs.first else { return }
                model.openTab(first)
                move(.tab(first))
            case .up:
                model.wake()
                if let first = model.glyphRow.first {
                    move(.control(first))
                } else if model.skipping != nil {
                    move(.skip)
                }
            @unknown default: break
            }
        }
    }
}

/// A pill under the bar. The open tab's pill stays lit while the remote is
/// down in its content.
private struct TabPill: View {
    let model: PlayerModel
    let tab: PlayerTab
    let focus: FocusState<PlayerFocus?>.Binding
    let move: (PlayerFocus) -> Void

    private static let vertical: CGFloat = 16

    private var label: String {
        switch tab {
        case .info: t("player.info")
        case .chapters: t("player.tabChapters")
        case .picture: t("player.tabPicture")
        case .stats: t("player.tabStats")
        }
    }

    var body: some View {
        let lit = model.overlay == .tab(tab) && focus.wrappedValue != .tab(tab)
        Button {
            model.wake()
            model.openTab(tab)
        } label: {
            Text(label)
                .font(.system(size: Theme.Player.pillLabel, weight: .medium))
                .frame(height: Theme.Player.pillHeight - 2 * Self.vertical)
        }
        .buttonStyle(FilledControlStyle(horizontal: Theme.Player.pillPadding, vertical: Self.vertical, glass: false))
        .glassMember()
        .background {
            if lit { Capsule().fill(Theme.Glass.raised) }
        }
        .focused(focus, equals: .tab(tab))
        .accessibilityIdentifier("player.tab.\(tab)")
        .accessibilityAddTraits(model.overlay == .tab(tab) ? .isSelected : [])
        .onMoveCommand { direction in
            model.wake()
            let tabs = model.tabs
            guard let at = tabs.firstIndex(of: tab) else { return }
            switch direction {
            case .left:
                guard at > 0 else { return }
                model.openTab(tabs[at - 1])
                move(.tab(tabs[at - 1]))
            case .right:
                guard at + 1 < tabs.count else { return }
                model.openTab(tabs[at + 1])
                move(.tab(tabs[at + 1]))
            case .up:
                model.closeLayer()
                move(.control(.bar))
            case .down:
                if let entry = TabContent.entry(tab, model: model) { move(entry) }
            @unknown default: break
            }
        }
    }
}

/// A round glass button over the film, lit while its popover is open. A
/// member of the overlay's glass group, which draws its glass.
struct RoundGlyphButton: View {
    let glyph: Glyph
    let open: Bool
    let spoken: String
    let action: () -> Void

    var body: some View {
        let inset = (Theme.Player.roundButton - Theme.Player.roundGlyph - 4) / 2
        Button(action: action) {
            GlyphView(glyph: glyph, size: Theme.Player.roundGlyph)
        }
        .buttonStyle(FilledControlStyle(horizontal: inset, vertical: inset, glass: false))
        .glassMember()
        .background {
            if open { Circle().fill(Theme.Glass.raised) }
        }
        .accessibilityLabel(spoken)
    }
}

/// The frame a scrub aims at, centred on the needle and resting on its tip.
private struct ScrubCard: View {
    let model: PlayerModel

    private var left: CGFloat {
        let player = Theme.Player.self
        guard model.duration > 0 else { return player.rowInset }
        let fraction = min(max((model.scrub ?? model.position) / model.duration, 0), 1)
        let centred = player.rowInset + (fraction * player.rowWidth).rounded() - player.thumbnail.width / 2
        return min(max(centred, player.rowInset), player.rowInset + player.rowWidth - player.thumbnail.width)
    }

    var body: some View {
        ThumbnailCard(frame: model.scrubFrame)
            .accessibilityElement()
            .accessibilityIdentifier("player.thumbnail")
            .offset(x: left, y: Theme.Player.barTop - Theme.Player.thumbnailGap - Theme.Player.thumbnail.height)
            .animation(.interactiveSpring, value: left)
    }
}

struct ThumbnailCard: View {
    let frame: ScrubFrame?

    var body: some View {
        // A flat well rather than glass: the frame covers all of it, and glass
        // under an opaque picture samples the film behind for nothing.
        ZStack {
            Theme.Glass.well
            if let frame {
                Image(uiImage: frame.image)
                    .resizable()
                    .scaledToFill()
                    .id(frame.second)
                    .transition(.opacity)
            }
        }
        .frame(width: Theme.Player.thumbnail.width, height: Theme.Player.thumbnail.height)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .animation(.easeOut(duration: Theme.Motion.scrubSlide), value: frame?.second)
    }
}

/// The stall indicator, over the middle of the dimmed film.
struct RebufferCard: View {
    let seconds: Int

    var body: some View {
        HStack(spacing: 16) {
            ProgressView().tint(PlayerInk.time)
            Text(t("player.buffering", ["seconds": String(seconds)]))
                .font(.system(size: Theme.Player.time))
                .foregroundStyle(PlayerInk.time)
        }
        .playerNotice()
    }
}

extension View {
    /// A line said over the film on a glass panel, which the remote passes through.
    func playerNotice() -> some View {
        padding(.horizontal, Theme.Player.noticeInset.width)
            .padding(.vertical, Theme.Player.noticeInset.height)
            .glassSurface(radius: Theme.Player.panelRadius, tint: Theme.Glass.panel)
            .allowsHitTesting(false)
    }
}

import SwiftUI

/// The film, and everything the remote does over it. Keyed on the file by
/// the shell, so an auto-advance is a fresh screen over the same frame.
struct PlayerScreen: View {
    @Environment(Navigator.self) private var navigator
    @State private var model: PlayerModel
    @FocusState private var focus: PlayerFocus?
    /// The note a chosen title opens with, up for its first seconds.
    @State private var noting = true

    init(playing: Playing) {
        _model = State(initialValue: PlayerModel(playing: playing))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RemoteGestures(model: model).allowsHitTesting(false)
            Color.black
            if let host = model.host { PlayerHost(host: host) }
            if model.status == .buffering { Color.black.opacity(0.3).allowsHitTesting(false) }
            if !model.line.isEmpty {
                PlayerFailure(message: model.line, detail: model.failureDetail, retry: retry) {
                    navigator.leavePlayer()
                }
            } else if model.overlayDrawn {
                PlayerOverlay(model: model, focus: $focus, move: move)
                    .opacity(model.overlayOpacity)
            } else {
                // The remote has to sit somewhere while the overlay is away. A
                // click pauses and brings the overlay; a sideways press skips
                // with the bar alone.
                Button {
                    model.wake()
                    model.togglePlayback()
                } label: { Color.clear }
                    .buttonStyle(CardButtonStyle(shadow: false))
                    .focused($focus, equals: .idle)
                    .onMoveCommand { direction in
                        switch direction {
                        case .left: model.tap(back: true)
                        case .right: model.tap(back: false)
                        default: model.wake()
                        }
                    }
            }
            if let next = model.next {
                UpNextCard(model: model, next: next, focus: $focus, move: move)
                    .padding(.bottom, Theme.Player.bottom)
                    .padding(.trailing, Theme.Player.margin)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
            // Over the bar too, above the round buttons, as the system player
            // keeps it: a press during an intro must not take the skip away.
            if let skipping = model.skipping, model.next == nil, model.asking == nil,
                !model.overlayDrawn || model.shown == .full || model.shown == .barOnly
            {
                ActionButton(
                    label: t(skipping.kind == .recap ? "player.skipRecap" : "player.skipIntro"), primary: true,
                    font: Theme.Typography.body) {
                    model.skipStretch()
                }
                .focused($focus, equals: .skip)
                .onMoveCommand { direction in
                    let drawn = model.overlayDrawn
                    model.wake()
                    if drawn, direction == .down { move(.control(model.glyphRow.first ?? .bar)) }
                }
                .padding(.bottom, model.overlayDrawn
                    ? Theme.Layout.screenHeight - Theme.Player.roundButtonTop + Theme.Player.roundButtonGap
                    : Theme.Player.bottom)
                .padding(.trailing, Theme.Player.margin)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
            if let asking = model.asking {
                AskRow(model: model, asking: asking, focus: $focus, move: move)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
            if noting, !model.playing.note.isEmpty {
                Text(model.playing.note)
                    .font(.system(size: Theme.Player.rowLabel))
                    .foregroundStyle(Theme.Colors.white)
                    .playerNotice()
                    .padding(.top, Theme.Player.bottom)
                    .padding(.leading, Theme.Player.margin)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .transition(.opacity)
            }
        }
        .frame(width: Theme.Layout.screenWidth, height: Theme.Layout.screenHeight, alignment: .topLeading)
        .ignoresSafeArea()
        .onExitCommand {
            if !model.line.isEmpty || !model.menu() { navigator.leavePlayer() }
        }
        .onPlayPauseCommand {
            model.wake()
            model.playPause()
        }
        .onAppear {
            model.start()
            focus = .control(.bar)
        }
        .onDisappear { model.leave() }
        .task {
            guard !model.playing.note.isEmpty else { return }
            try? await Task.sleep(for: .seconds(5))
            withAnimation(.easeOut(duration: Theme.Motion.overlayOut)) { noting = false }
        }
        .onChange(of: focus) { _, now in model.focusChanged(now) }
        .onChange(of: model.overlayDrawn) { _, drawn in
            if drawn { land() } else { move(model.skipping != nil && model.next == nil ? .skip : .idle) }
        }
        // the button takes the remote as it comes, where the overlay is away
        .onChange(of: model.skipping) { _, skipping in
            guard model.next == nil else { return }
            if skipping != nil {
                if !model.overlayDrawn { move(.skip) }
            } else if focus == .skip {
                if model.overlayDrawn { land() } else { move(.idle) }
            }
        }
        .onChange(of: model.subtitleLift) { _, lift in
            model.host?.bridge.setSubtitleLift(points: lift)
        }
        .onChange(of: model.overlay) { was, now in route(from: was, to: now) }
        .onChange(of: model.next?.fileId) { _, next in
            if next != nil { move(.advanceNow) } else { land() }
        }
        .onChange(of: model.asking) { _, asking in
            if asking != nil { move(.ask(0)) } else { land() }
        }
        .onChange(of: model.advanceTo?.fileId) { _, _ in
            guard let next = model.advanceTo else { return }
            navigator.play(
                titleId: next.titleId, fileId: next.fileId, title: UpNextCard.label(next),
                startAt: next.resumePositionSecs, context: UpNextCard.context(next), from: .other)
        }
    }

    /// Focus follows the overlay: into a popover as it opens, back to the
    /// row that opened a level as it closes, back to the button a popover
    /// stood on, back to the bar when a tab or a scrub ends.
    private func route(from was: OverlayState, to now: OverlayState) {
        switch now {
        case .menu(let menu):
            if case .menu(let deeper) = was, deeper.button == menu.button, let row = TrackMenu.opener(deeper, model: model) {
                move(.menuRow(row))
            } else {
                move(.menuRow(TrackMenu.entry(menu, model: model)))
            }
        case .full:
            if case .control = focus { return }
            switch was {
            case .menu(let menu):
                move(.control(model.drawn(menu.button) ? menu.button : .bar))
            case .tab, .scrubbing:
                // the end of a film owns the remote while its card is up
                if model.next == nil, model.asking == nil { move(.control(.bar)) }
            default: break
            }
        default: break
        }
    }

    /// The same file again on a fresh screen, from where it stopped.
    private func retry() {
        var again = model.playing
        again.startAt = max(again.startAt, model.positionRef)
        again.attempt += 1
        navigator.playing = again
    }

    /// The bar takes the remote whenever the overlay is up and nothing
    /// at the end of the film owns it.
    private func land() {
        guard model.overlayDrawn, model.next == nil, model.asking == nil else { return }
        move(.control(.bar))
    }

    /// A focus request deferred one turn: the target may be entering the
    /// tree in this same update.
    private func move(_ target: PlayerFocus) {
        Task { @MainActor in focus = target }
    }
}

/// A film that could not start or went on failing: what happened, what lies
/// under it, and the two ways on. It owns the remote while it is up.
private struct PlayerFailure: View {
    let message: String
    let detail: String
    let retry: () -> Void
    let leave: () -> Void
    @FocusState private var retryFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s16) {
            Text(message)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.white)
            if !detail.isEmpty {
                Text(detail)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textMuted)
                    .fits(3)
            }
            HStack(spacing: 20) {
                ActionButton(label: t("settings.tryAgain"), primary: true, font: Theme.Typography.body, action: retry)
                    .focused($retryFocused)
                ActionButton(label: t("common.back"), font: Theme.Typography.body, action: leave)
            }
            .padding(.top, Theme.Space.s16)
        }
        .padding(40)
        .frame(maxWidth: 1000, alignment: .leading)
        .glassSurface(radius: Theme.Player.panelRadius, tint: Theme.Glass.panel)
        .frame(width: Theme.Layout.screenWidth, height: Theme.Layout.screenHeight)
        .onAppear { retryFocused = true }
    }
}

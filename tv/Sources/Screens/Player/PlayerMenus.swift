import SwiftUI

/// A popover over a round button, as the native player draws its subtitles
/// and audio menus: sections under a small header, rows of 66 points, a
/// check on the choice in use, a white pill under the remote.
struct TrackMenu: View {
    let model: PlayerModel
    let menu: PlayerMenu
    let focus: FocusState<PlayerFocus?>.Binding
    let move: (PlayerFocus) -> Void

    struct Row {
        let label: String
        var detail = ""
        var note = ""
        var checked = false
        var chevron = false
        let action: () -> Void
    }

    struct Section {
        var header = ""
        let rows: [Row]
    }

    private var sections: [Section] {
        switch menu {
        case .subtitles:
            let current = model.subtitleTracks.first(where: \.selected)
            let preferred = model.preferredSubtitle
            return [
                Section(header: t("player.subtitles"), rows: [
                    Row(label: t("player.subtitlesAuto"), checked: preferred.isEmpty) {
                        model.selectSubtitlesAuto()
                        model.closeLayer()
                    },
                    Row(label: t("player.subtitlesOn"), checked: !preferred.isEmpty && preferred != "off") {
                        model.turnSubtitlesOn()
                        model.closeLayer()
                    },
                    Row(label: t("player.subtitlesOff"), checked: preferred == "off") {
                        model.selectSubtitle(nil)
                        model.closeLayer()
                    },
                ]),
                Section(rows: [
                    Row(label: t("player.subtitleLanguage"), detail: current?.label ?? t("player.subtitlesOff"), chevron: true) {
                        model.openMenu(.subtitleLanguage)
                    },
                    Row(
                        label: t("player.subtitleOffset"), detail: Self.seconds(model.subtitleOffset), chevron: true
                    ) {
                        model.openMenu(.subtitleOffset)
                    },
                ]),
            ]
        case .subtitleOffset:
            return [Section(header: t("player.subtitleOffset"), rows: PlayerModel.subtitleOffsetChoices.map { offset in
                Row(label: Self.seconds(offset), checked: model.subtitleOffset == offset) {
                    model.setSubtitleOffset(offset)
                    model.openMenu(.subtitles)
                }
            })]
        case .subtitleLanguage:
            return [Section(header: t("player.subtitleLanguage"), rows: model.subtitleTracks.map { track in
                Row(label: track.label, note: track.graphic ? t("player.graphic") : "", checked: track.selected) {
                    model.selectSubtitle(track)
                    model.closeLayer()
                }
            })]
        case .audio:
            return [
                Section(header: t("player.audioTrack"), rows: model.audioTracks.map { track in
                    Row(label: track.label, checked: track.selected) {
                        model.selectAudio(track)
                        model.closeLayer()
                    }
                }),
                Section(rows: [
                    Row(label: t("player.audioDelay"), detail: Self.milliseconds(model.audioDelayMs), chevron: true) {
                        model.openMenu(.audioDelay)
                    },
                ]),
            ]
        case .audioDelay:
            return [Section(header: t("player.audioDelay"), rows: PlayerModel.audioDelayChoicesMs.map { ms in
                Row(label: Self.milliseconds(ms), note: ms == 0 ? "" : t(ms > 0 ? "player.audioLater" : "player.audioEarlier"),
                    checked: model.audioDelayMs == ms) {
                    model.setAudioDelay(ms: ms)
                    model.openMenu(.audio)
                }
            })]
        }
    }

    /// The row a level down opened from, for the remote to land back on.
    static func opener(_ menu: PlayerMenu, model: PlayerModel) -> Int? {
        switch menu {
        case .subtitleLanguage: 3
        case .subtitleOffset: 4
        case .audioDelay: model.audioTracks.count
        default: nil
        }
    }

    /// "+0.5 s", the sign written so a shift reads as one.
    static func seconds(_ value: Double) -> String {
        guard value != 0 else { return t("player.seconds", ["value": "0"]) }
        var number = String(format: "%+.2f", value)
        while number.hasSuffix("0") { number.removeLast() }
        if number.hasSuffix(".") { number.removeLast() }
        return t("player.seconds", ["value": number.replacingOccurrences(of: ".", with: t("fmt.decimal"))])
    }

    static func milliseconds(_ value: Int) -> String {
        t("player.milliseconds", ["value": value == 0 ? "0" : String(format: "%+d", value)])
    }

    /// The row the remote lands on as the popover opens: the choice in use.
    static func entry(_ menu: PlayerMenu, model: PlayerModel) -> Int {
        switch menu {
        case .subtitles: model.preferredSubtitle.isEmpty ? 0 : model.preferredSubtitle == "off" ? 2 : 1
        case .subtitleLanguage: model.subtitleTracks.firstIndex(where: \.selected) ?? 0
        case .subtitleOffset: PlayerModel.subtitleOffsetChoices.firstIndex(of: model.subtitleOffset) ?? 0
        case .audio: model.audioTracks.firstIndex(where: \.selected) ?? 0
        case .audioDelay: PlayerModel.audioDelayChoicesMs.firstIndex(of: model.audioDelayMs) ?? 0
        }
    }

    static func height(_ sections: [Section]) -> CGFloat {
        let p = Theme.Player.self
        let rows = sections.reduce(0) { sum, section in
            sum + section.rows.reduce(0) { $0 + ($1.detail.isEmpty ? p.menuRow : p.menuRowTall) }
        }
        let headers = CGFloat(sections.filter { !$0.header.isEmpty }.count) * p.menuHeader
        let rules = CGFloat(max(0, sections.count - 1)) * p.menuRule
        return rows + headers + rules + 2 * p.menuInset
    }

    /// Its foot above the round buttons, its right edge on its button's, and
    /// never higher than the top of the screen allows; a longer list scrolls.
    static func frame(right: CGFloat, height: CGFloat) -> CGRect {
        let p = Theme.Player.self
        let bottom = p.roundButtonTop - p.menuGap
        let clamped = min(height, bottom - p.menuTopLimit)
        return CGRect(x: right - p.menuWidth, y: bottom - clamped, width: p.menuWidth, height: clamped)
    }

    /// The right edge of a round button: the row ends where the bar ends.
    static func buttonRight(_ control: PlayerControl, row: [PlayerControl]) -> CGFloat {
        let p = Theme.Player.self
        let after = row.count - 1 - (row.firstIndex(of: control) ?? row.count - 1)
        return p.rowInset + p.rowWidth - CGFloat(after) * (p.roundButton + p.roundButtonGap)
    }

    var body: some View {
        let sections = sections, p = Theme.Player.self
        let starts = sections.indices.map { at in sections[..<at].reduce(0) { $0 + $1.rows.count } }
        let count = sections.reduce(0) { $0 + $1.rows.count }
        let button = menu.button
        let frame = Self.frame(right: Self.buttonRight(button, row: model.glyphRow), height: Self.height(sections))
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(sections.indices, id: \.self) { at in
                        if at > 0 {
                            PlayerInk.rule
                                .frame(height: 1)
                                .padding(.horizontal, p.menuTextInset)
                                .frame(height: p.menuRule)
                        }
                        if !sections[at].header.isEmpty {
                            Text(sections[at].header)
                                .font(.system(size: p.menuHeaderLabel))
                                .foregroundStyle(PlayerInk.context)
                                .padding(.horizontal, p.menuTextInset)
                                .frame(height: p.menuHeader, alignment: .topLeading)
                        }
                        ForEach(sections[at].rows.indices, id: \.self) { index in
                            let id = starts[at] + index
                            MenuRow(row: sections[at].rows[index], id: id, focused: focus.wrappedValue == .menuRow(id))
                                .focused(focus, equals: .menuRow(id))
                                .id(id)
                                .onMoveCommand { direction in
                                    model.wake()
                                    switch direction {
                                    case .up: if id > 0 { move(.menuRow(id - 1)) }
                                    case .down: move(id + 1 < count ? .menuRow(id + 1) : .control(button))
                                    default: break
                                    }
                                }
                        }
                    }
                }
                .padding(.horizontal, (p.menuWidth - p.menuRowWidth) / 2)
                .padding(.vertical, p.menuInset)
            }
            .onChange(of: focus.wrappedValue) { _, now in
                if case .menuRow(let id) = now { proxy.scrollTo(id) }
            }
        }
        .frame(width: frame.width, height: frame.height)
        .glassSurface(radius: p.menuRadius, tint: Theme.Glass.panel)
        .offset(x: frame.minX, y: frame.minY)
    }
}

/// One row of a popover: the check column, the label with its note and its
/// value under it, and a chevron where the row opens a level down.
private struct MenuRow: View {
    let row: TrackMenu.Row
    let id: Int
    let focused: Bool

    var body: some View {
        let p = Theme.Player.self
        let ink = focused ? Theme.Colors.onWhite : Theme.Colors.text
        Button(action: row.action) {
            HStack(spacing: 0) {
                ZStack {
                    if row.checked { Image(systemName: "checkmark").font(.system(size: p.menuLabel, weight: .semibold)) }
                }
                .frame(width: p.menuCheckColumn)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(row.label)\(Text(row.note).foregroundStyle(ink.opacity(0.5)))")
                        .font(.system(size: p.menuLabel))
                        .lineLimit(1)
                    if !row.detail.isEmpty {
                        Text(row.detail)
                            .font(.system(size: p.menuLabel - 2))
                            .foregroundStyle(ink.opacity(0.6))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if row.chevron {
                    Image(systemName: "chevron.forward")
                        .font(.system(size: p.menuLabel - 3, weight: .semibold))
                        .padding(.trailing, p.menuTextInset)
                }
            }
            .foregroundStyle(ink)
            .frame(width: p.menuRowWidth, height: row.detail.isEmpty ? p.menuRow : p.menuRowTall)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("player.menuRow.\(id)")
            .background(focused ? Theme.Colors.white : .clear, in: Capsule())
            .scaleEffect(focused ? Theme.Focus.wide : 1)
            .animation(.easeOut(duration: Theme.Motion.focus), value: focused)
        }
        .buttonStyle(CardButtonStyle(shadow: false))
        .accessibilityLabel(row.label + row.note)
        .accessibilityAddTraits(row.checked ? .isSelected : [])
    }
}

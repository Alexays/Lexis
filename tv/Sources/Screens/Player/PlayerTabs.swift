import LexisCore
import LexisPlayer
import SwiftUI
import UIKit

/// The content under the pills for the open tab, in the native player's
/// 250-point band.
struct TabContent: View {
    let model: PlayerModel
    let tab: PlayerTab
    let focus: FocusState<PlayerFocus?>.Binding
    let move: (PlayerFocus) -> Void

    /// Where down from a pill lands; nil for a tab nothing in can take the
    /// remote.
    static func entry(_ tab: PlayerTab, model: PlayerModel) -> PlayerFocus? {
        switch tab {
        case .info: .content(.info, 0)
        case .chapters: .content(.chapters, model.currentChapter ?? 0)
        case .picture: .content(.picture, model.upscaling ? 2 : 3)
        case .stats: nil
        }
    }

    var body: some View {
        switch tab {
        case .info: InfoTab(model: model, focus: focus, move: move)
        case .chapters: ChaptersTab(model: model, focus: focus, move: move)
        case .picture: PictureTab(model: model, focus: focus, move: move)
        case .stats: StatsTab(model: model)
        }
    }
}

/// What the film is: its poster, the line above its title, its summary, the
/// marks of its picture, and a way back to its first frame.
private struct InfoTab: View {
    let model: PlayerModel
    let focus: FocusState<PlayerFocus?>.Binding
    let move: (PlayerFocus) -> Void

    private var heading: String { model.playing.context.isEmpty ? model.playing.title : model.playing.context }

    /// The genre and the length.
    private var facts: String {
        var parts: [String] = []
        if let genre = model.detail?.genres.first { parts.append(Format.genre(genre)) }
        if model.duration >= 30 { parts.append(Format.runtime(model.duration)) }
        return parts.joined(separator: " · ")
    }

    private var badges: [String] {
        var marks: [String] = []
        let width = model.picture.width
        if width >= 3000 {
            marks.append("4K")
        } else if width >= 1200 {
            marks.append("HD")
        }
        switch model.stats?.dynamicRange {
        case "dolbyVision": marks.append("Dolby Vision")
        case "hdr10": marks.append("HDR10")
        case "hlg": marks.append("HLG")
        default: break
        }
        return marks
    }

    /// The timer's choice, with what is left of a timed one.
    private var sleepLabel: String {
        switch model.sleepChoice {
        case nil: t("player.sleepOff")
        case 0: t("player.sleepAtEnd")
        default:
            t("player.sleepIn", ["minutes": String(
                max(1, Int(((PlayerModel.sleepDeadline?.timeIntervalSinceNow ?? 0) / 60).rounded(.up))))])
        }
    }

    var body: some View {
        let player = Theme.Player.self
        HStack(alignment: .top, spacing: 0) {
            if let titleId = model.titleId {
                ArtworkImage(kind: .poster(titleId: titleId)) { Theme.Glass.well }
                    .frame(width: player.poster.width, height: player.poster.height)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.poster, style: .continuous))
                    .padding(player.posterInset)
            }
            VStack(alignment: .leading, spacing: Theme.Space.s8) {
                Text(heading)
                    .font(.system(size: player.infoHeading, weight: .bold))
                    .foregroundStyle(Theme.Colors.white)
                    .lineLimit(1)
                if let overview = model.detail?.overview, !overview.isEmpty {
                    Text(overview)
                        .font(.system(size: player.infoBody))
                        .foregroundStyle(PlayerInk.context)
                        .lineLimit(2)
                        .frame(maxWidth: player.summaryWidth, alignment: .leading)
                }
                Spacer(minLength: 0)
                HStack(spacing: Theme.Space.s16) {
                    if !facts.isEmpty {
                        Text(facts)
                            .font(.system(size: player.infoBody, weight: .medium))
                            .foregroundStyle(Theme.Colors.white)
                    }
                    ForEach(badges, id: \.self) { mark in
                        Text(mark)
                            .font(.system(size: player.badge, weight: .bold))
                            .foregroundStyle(Theme.Colors.onWhite)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Theme.Colors.white.opacity(0.85), in: RoundedRectangle(cornerRadius: 4))
                    }
                }
            }
            .padding(.vertical, player.infoTextInset)
            .padding(.leading, model.titleId == nil ? player.infoTextGap : player.infoTextGap - player.posterInset)
            Spacer(minLength: Theme.Space.s40)
            VStack(spacing: Theme.Space.s16) {
                Button {
                    model.wake()
                    model.playFromStart()
                } label: {
                    HStack(spacing: Theme.Space.s16) {
                        Image(systemName: "play.fill")
                        Text(t("player.fromBeginning"))
                    }
                    .font(.system(size: player.infoBody + 4, weight: .medium))
                    .frame(width: player.fromBeginning.width - 64, height: player.fromBeginning.height - 32)
                }
                .buttonStyle(FilledControlStyle())
                .focused(focus, equals: .content(.info, 0))
                .accessibilityIdentifier("player.fromBeginning")
                .onMoveCommand { direction in
                    model.wake()
                    if direction == .up { move(.tab(.info)) }
                    if direction == .down { move(.content(.info, 1)) }
                }
                // each press moves the timer on to its next choice
                Button {
                    model.wake()
                    let choices = PlayerModel.sleepChoices
                    let at = choices.firstIndex { $0 == model.sleepChoice } ?? 0
                    model.setSleep(minutes: choices[(at + 1) % choices.count])
                } label: {
                    HStack(spacing: Theme.Space.s16) {
                        Image(systemName: "moon.zzz.fill")
                        Text(sleepLabel)
                    }
                    .font(.system(size: player.infoBody + 4, weight: .medium))
                    .frame(width: player.fromBeginning.width - 64, height: player.fromBeginning.height - 32)
                }
                .buttonStyle(FilledControlStyle())
                .focused(focus, equals: .content(.info, 1))
                .accessibilityIdentifier("player.sleepTimer")
                .onMoveCommand { direction in
                    model.wake()
                    if direction == .up { move(.content(.info, 0)) }
                }
            }
            .padding(.top, player.fromBeginningTop)
            .padding(.trailing, player.fromBeginningTrailing)
        }
        .frame(width: player.rowWidth, height: player.tabContentHeight, alignment: .topLeading)
        .glassSurface(radius: player.tabContentRadius, tint: Theme.Glass.panel)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player.infoCard")
    }
}

/// A card per chapter, the one being watched marked and taking the remote.
private struct ChaptersTab: View {
    let model: PlayerModel
    let focus: FocusState<PlayerFocus?>.Binding
    let move: (PlayerFocus) -> Void

    var body: some View {
        // read once here: the cards take plain values, so a tick redraws only
        // the cards whose mark moved
        let chapters = model.chapters, frames = model.chapterFrames, current = model.currentChapter
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                // not lazy: down from the pill lands on the current card, which
                // may be far off to the right and must already exist
                HStack(spacing: Theme.Player.chapterGap) {
                    ForEach(chapters.indices, id: \.self) { index in
                        ChapterCard(
                            model: model, index: index, title: chapters[index].title, image: frames[index],
                            isCurrent: index == current, focused: focus.wrappedValue == .content(.chapters, index))
                            .focused(focus, equals: .content(.chapters, index))
                            .id(index)
                            .onMoveCommand { direction in
                                model.wake()
                                switch direction {
                                case .left: if index > 0 { move(.content(.chapters, index - 1)) }
                                case .right: if index + 1 < chapters.count { move(.content(.chapters, index + 1)) }
                                case .up: move(.tab(.chapters))
                                default: break
                                }
                            }
                    }
                }
                .padding(.trailing, Theme.Player.rowInset)
            }
            .scrollClipDisabled()
            .onChange(of: focus.wrappedValue) { _, now in
                if case .content(.chapters, let index) = now { withAnimation { proxy.scrollTo(index) } }
            }
        }
        .frame(width: Theme.Layout.screenWidth - Theme.Player.rowInset, height: Theme.Player.chapterCard.height)
    }
}

private struct ChapterCard: View {
    let model: PlayerModel
    let index: Int
    let title: String
    let image: UIImage?
    let isCurrent: Bool
    let focused: Bool

    var body: some View {
        let player = Theme.Player.self
        Button {
            model.wake()
            model.playChapter(index)
        } label: {
            ZStack(alignment: .bottomLeading) {
                Theme.Glass.well
                if let image {
                    // held to the card: filled at its own size it widens the
                    // stack, and the title laid at its corner is cut off
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: player.chapterCard.width, height: player.chapterCard.height)
                        .clipped()
                }
                LinearGradient(colors: [.clear, Theme.Colors.bg0.opacity(0.7)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 2) {
                    if isCurrent {
                        Text(t("player.chapterNow").uppercased())
                            .font(.system(size: player.chapterNow, weight: .semibold))
                            .foregroundStyle(PlayerInk.context)
                    }
                    Text(title.isEmpty ? t("player.chapterNumber", ["number": String(index + 1)]) : title)
                        .font(.system(size: player.infoBody))
                        .foregroundStyle(Theme.Colors.white)
                        .fits(1)
                }
                .padding(player.chapterTextInset)
            }
            .frame(width: player.chapterCard.width, height: player.chapterCard.height)
            .clipShape(RoundedRectangle(cornerRadius: player.chapterRadius, style: .continuous))
            .scaleEffect(focused ? Theme.Focus.wide : 1)
            .animation(.easeOut(duration: Theme.Motion.focus), value: focused)
        }
        .buttonStyle(CardButtonStyle(shadow: false))
        .accessibilityIdentifier("player.chapter.\(index)")
    }
}

/// The choices worth making while watching: upscaling and what does it, to
/// be judged on and off on the same frames.
private struct PictureTab: View {
    let model: PlayerModel
    let focus: FocusState<PlayerFocus?>.Binding
    let move: (PlayerFocus) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s16) {
            choiceRow(t("settings.videoUpscaling")) {
                ForEach([true, false], id: \.self) { on in
                    pill(
                        t(on ? "settings.videoUpscalingOn" : "settings.videoUpscalingOff"),
                        id: on ? 2 : 3, selected: model.upscaling == on,
                        action: { model.setUpscaling(on) }
                    ) { direction in
                        switch direction {
                        case .left: on ? nil : .content(.picture, 2)
                        case .right: on ? .content(.picture, 3) : nil
                        case .up: .tab(.picture)
                        case .down: .content(.picture, model.neuralUpscaling ? 4 : 5)
                        default: nil
                        }
                    }
                }
            }
            choiceRow(t("settings.videoNeuralUpscaling")) {
                ForEach([true, false], id: \.self) { on in
                    pill(
                        t(on ? "settings.videoUpscalingOn" : "settings.videoUpscalingOff"),
                        id: on ? 4 : 5, selected: model.neuralUpscaling == on,
                        action: { model.setNeuralUpscaling(on) }
                    ) { direction in
                        switch direction {
                        case .left: on ? nil : .content(.picture, 4)
                        case .right: on ? .content(.picture, 5) : nil
                        case .up: .content(.picture, model.upscaling ? 2 : 3)
                        default: nil
                        }
                    }
                }
            }
        }
        .padding(.horizontal, Theme.Space.s40)
        .frame(width: Theme.Player.rowWidth, height: Theme.Player.tabContentHeight)
        .glassSurface(radius: Theme.Player.tabContentRadius, tint: Theme.Glass.panel)
    }

    private func choiceRow<Pills: View>(_ label: String, @ViewBuilder pills: () -> Pills) -> some View {
        HStack(spacing: 0) {
            Text(label)
                .font(.system(size: Theme.Player.infoBody))
                .foregroundStyle(PlayerInk.context)
                .frame(width: Theme.Player.choiceLabel, alignment: .leading)
            HStack(spacing: Theme.Space.s8, content: pills)
            Spacer(minLength: 0)
        }
    }

    /// One pill of a row: the one in use wears the accent, the one under the
    /// remote grows white and keeps the accent's ink if it is both.
    private func pill(
        _ label: String, id: Int, selected: Bool, action: @escaping () -> Void,
        moves: @escaping (MoveCommandDirection) -> PlayerFocus?
    ) -> some View {
        let focused = focus.wrappedValue == .content(.picture, id)
        return Button {
            model.wake()
            action()
        } label: {
            Text(label)
                .font(.system(size: Theme.Player.infoBody, weight: selected || focused ? .semibold : .regular))
                .foregroundStyle(selected ? Theme.Colors.onAccent : focused ? Theme.Colors.onWhite : Theme.Colors.text)
                .fixedSize()
                .padding(.horizontal, 20)
                .frame(height: 48)
                .background(
                    focused ? Theme.Colors.white : selected ? Theme.Colors.accent : Theme.Glass.control,
                    in: Capsule())
                .scaleEffect(focused ? Theme.Focus.wide : 1)
                .animation(.easeOut(duration: Theme.Motion.focus), value: focused)
        }
        .buttonStyle(CardButtonStyle(shadow: false))
        .focused(focus, equals: .content(.picture, id))
        .onMoveCommand { direction in
            model.wake()
            if let next = moves(direction) { move(next) }
        }
        .accessibilityLabel(label)
    }
}

/// The live diagnostics of this playback, three columns of four, so every
/// line is in view at once. Nothing here takes the remote.
private struct StatsTab: View {
    let model: PlayerModel

    private static let perColumn = 4

    private var unknown: String { t("player.infoUnknown") }
    private var live: PlayerStats? { model.stats?.fileOpen == true ? model.stats : nil }

    private var rows: [(label: String, value: String)] {
        var rows: [(label: String, value: String)] = [
            (t("player.infoResolution"), resolution),
            (t("player.infoVideo"), video),
            (t("player.infoPath"), path),
            (t("player.infoDisplay"), display),
            (t("player.infoTrack"), model.selectedAudio?.label ?? t("player.infoNoTrack")),
            (t("player.infoFormat"), format),
            (t("player.infoFrames"), live.map {
                t("player.infoFramesValue", ["shown": String($0.rendererFramesDisplayed), "dropped": String($0.rendererFramesDropped)])
            } ?? unknown),
            (t("player.infoStalls"), live.map {
                t("player.infoStallsValue", ["rebuffers": String($0.rebufferCount), "starved": String($0.pictureStarvations)])
            } ?? unknown),
            (t("player.infoNetwork"), network),
            (t("player.infoBuffered"), live.map { seconds($0.bufferedSeconds, decimals: 1) } ?? unknown),
            (t("player.infoFirstFrame"), model.firstFrameSeconds < 0 ? unknown : seconds(model.firstFrameSeconds, decimals: 2)),
        ]
        if let live, live.rendererLastDropSeconds > 0 {
            rows.insert((t("player.infoLastDrop"), seconds(live.rendererLastDropSeconds, decimals: 1)), at: 7)
        }
        return rows
    }

    var body: some View {
        let rows = rows
        let columns = (rows.count + Self.perColumn - 1) / Self.perColumn
        HStack(alignment: .top, spacing: Theme.Space.s40) {
            ForEach(0..<columns, id: \.self) { column in
                VStack(spacing: 0) {
                    ForEach(column * Self.perColumn ..< min(rows.count, (column + 1) * Self.perColumn), id: \.self) { at in
                        detail(rows[at].label, rows[at].value)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .padding(.horizontal, Theme.Space.s40)
        .padding(.top, Theme.Player.statsTop)
        .frame(width: Theme.Player.rowWidth, height: Theme.Player.tabContentHeight, alignment: .top)
        .glassSurface(radius: Theme.Player.tabContentRadius, tint: Theme.Glass.panel)
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s16) {
            Text(label)
                .font(.system(size: Theme.Player.infoBody - 2))
                .foregroundStyle(PlayerInk.context)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text(value)
                .font(.system(size: Theme.Player.infoBody))
                .foregroundStyle(Theme.Colors.white)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .frame(height: Theme.Player.statRow)
    }

    private func seconds(_ value: Double, decimals: Int) -> String {
        t("player.infoSeconds", ["seconds": String(format: "%.\(decimals)f", value)])
    }

    private var resolution: String {
        let picture = model.picture
        guard picture.width > 0 else { return unknown }
        if let live, live.upscaleWidth > 0 {
            return t("player.infoResolutionUpscaled", [
                "width": String(picture.width), "height": String(picture.height),
                "target": "\(live.upscaleWidth) x \(live.upscaleHeight)",
            ])
        }
        return "\(picture.width) x \(picture.height)"
    }

    private var video: String {
        let codec = model.picture.codec
        guard !codec.isEmpty, let live else { return unknown }
        let range: String
        if live.dynamicRange == "dolbyVision" {
            range = t("player.infoVideoDolby", ["profile": String(live.dolbyVisionProfile)])
        } else if live.dolbyVisionProfile > 0 {
            range = t("player.infoVideoDolbyAsHDR", [
                "profile": String(live.dolbyVisionProfile), "range": live.dynamicRange.uppercased(),
            ])
        } else {
            range = live.dynamicRange.uppercased()
        }
        return [codec.uppercased(), range, live.videoDescription].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    private var path: String {
        guard let live else { return unknown }
        if live.videoPassthrough { return t("player.infoPathDirect") }
        if live.videoPath == .decoded || live.videoPath == .deinterlaced { return t("player.infoPathDecoded") }
        return t(live.displaySupportsDolbyVision || live.displayEligibleForHDR ? "player.infoPathMapped" : "player.infoPathMappedSdr")
    }

    private var display: String {
        guard let live else { return unknown }
        if live.displayModeNegotiated { return String(format: "%.3f Hz", live.displayRefreshRate) }
        return live.displayCriteriaMatchingEnabled ? unknown : t("player.infoDisplayOff")
    }

    private var format: String {
        guard let live else { return unknown }
        if live.audioFormat == "none" || live.audioFormat == "unsupported" { return t("player.infoSilent") }
        return t(live.audioPassthrough ? "player.infoPassthrough" : "player.infoDecoded",
            ["format": live.audioFormat.uppercased()])
    }

    private var network: String {
        guard let live, live.ioSustainedBitsPerSecond > 0 else { return unknown }
        return t("player.infoNetworkValue", [
            "mbps": String(format: "%.1f", live.ioSustainedBitsPerSecond / 1e6)
                .replacingOccurrences(of: ".", with: t("fmt.decimal")),
            "milliseconds": String(Int((live.ioFetchLatencySeconds * 1000).rounded())),
        ])
    }
}

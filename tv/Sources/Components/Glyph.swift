import SwiftUI

/// The marks the app draws, by the names the core and the screens use.
enum Glyph: String {
    case info, cross, plus, check, bookmark, play, pause, magnifier, sliders, server, display,
        audioTracks, globe, sparkles, activity, subtitles, list, thumbLove, thumbUp, thumbDown, folder, plex

    var symbol: String {
        switch self {
        case .info: "info"
        case .cross: "xmark"
        case .plus: "plus"
        case .check: "checkmark"
        case .bookmark: "bookmark.fill"
        case .play: "play.fill"
        case .pause: "pause.fill"
        case .magnifier: "magnifyingglass"
        case .sliders: "slider.horizontal.3"
        case .server: "server.rack"
        case .display: "display"
        case .audioTracks: "waveform"
        case .globe: "globe"
        case .sparkles: "sparkles"
        case .activity: "waveform.path.ecg"
        case .subtitles: "captions.bubble"
        case .list: "list.bullet"
        case .thumbLove: "heart.fill"
        case .thumbUp: "hand.thumbsup.fill"
        case .thumbDown: "hand.thumbsdown.fill"
        case .folder: "folder"
        case .plex: "play.rectangle"
        }
    }

    /// A module names its glyph in the core's own vocabulary.
    static func forModule(_ name: String) -> Glyph {
        switch name {
        case "plex": .plex
        case "local", "folder": .folder
        default: .server
        }
    }
}

struct GlyphView: View {
    let glyph: Glyph
    var size: CGFloat = 24

    var body: some View {
        Image(systemName: glyph.symbol)
            .font(.system(size: size, weight: .semibold))
            .frame(width: size + 4, height: size + 4)
    }
}

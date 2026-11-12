import AVFoundation
import Foundation
import LexisPlayer
import SwiftUI
import UIKit

/// The bridge's own status words, plus `connecting`, the screen's word for
/// the wait between asking the core for a stream and the bridge's first event.
enum PlayerStatus: String {
    case opening, connecting, opened, playing, paused, buffering, stopped, ended, failed, unauthorized,
        tooLarge

    var terminal: Bool { self == .failed || self == .tooLarge || self == .unauthorized || self == .stopped }
}

/// What the remote can sit on outside a tab or a popover.
enum PlayerControl: Hashable {
    case bar, subtitle, audio
}

/// The pills under the bar.
enum PlayerTab: Hashable {
    case info, chapters, picture, stats
}

/// The popovers over the round buttons; the lists after the first are a
/// level down from the popover of their button.
enum PlayerMenu: Hashable {
    case subtitles, subtitleLanguage, subtitleOffset, audio, audioDelay

    var button: PlayerControl { self == .audio || self == .audioDelay ? .audio : .subtitle }
}

/// What the overlay draws. One state at a time, so Menu always knows which
/// level it closes.
enum OverlayState: Equatable {
    case hidden
    /// The bar and the times alone: a skip or a hold while the overlay was away.
    case barOnly
    case full
    /// The bar and the frame the scrub aims at; the title row steps aside.
    case scrubbing
    case tab(PlayerTab)
    case menu(PlayerMenu)
}

/// The mark beside the elapsed time: what the remote is doing to the film.
enum TransportIndicator: Equatable {
    case paused, skipBack, skipForward
    case scanBack(Int), scanForward(Int)

    /// Backwards marks stand before the time, the rest after it.
    var leads: Bool {
        switch self {
        case .skipBack, .scanBack: true
        default: false
        }
    }

    var symbol: String {
        switch self {
        case .paused: "pause.circle"
        case .skipBack: "gobackward.10"
        case .skipForward: "goforward.10"
        case .scanBack: "backward.circle"
        case .scanForward: "forward.circle"
        }
    }

    /// A scan's speed, written beside its mark.
    var speed: Int? {
        switch self {
        case .scanBack(let speed), .scanForward(let speed): speed
        default: nil
        }
    }
}

/// Where the remote is on the player screen.
enum PlayerFocus: Hashable {
    /// The overlay is away: an invisible catcher holds the remote so a press
    /// still reaches the screen.
    case idle
    case control(PlayerControl)
    case tab(PlayerTab)
    /// Something inside the open tab, numbered by the tab.
    case content(PlayerTab, Int)
    /// A row of the open popover, top to bottom.
    case menuRow(Int)
    case advanceNow, advanceCancel
    /// The button over an intro or a recap.
    case skip
    case ask(Int)
}

/// The inks the overlay draws in, over a film rather than over the canvas.
enum PlayerInk {
    static let played = Theme.Colors.white
    static let buffered = Theme.Colors.white.opacity(0.55)
    static let remaining = Theme.Colors.white.opacity(0.30)
    static let chapter = Theme.Colors.white.opacity(0.45)
    static let time = Theme.Colors.white
    static let context = Theme.Colors.white.opacity(0.60)
    static let header = Theme.Colors.white.opacity(0.55)
    static let rule = Theme.Colors.white.opacity(0.08)
}

/// A decoded scrub frame, keyed by the second it shows so the card can
/// cross-fade from the one before it.
struct ScrubFrame: Equatable {
    let second: Int
    let image: UIImage

    static func == (a: ScrubFrame, b: ScrubFrame) -> Bool { a.second == b.second && a.image === b.image }
}

struct Picture: Equatable {
    var width: Int32 = 0
    var height: Int32 = 0
    var codec = ""
}

struct MediaTrack: Equatable {
    let index: Int32
    let codec: String
    let language: String
    let title: String
    let graphic: Bool
    let channels: Int
    /// What the container says to play when nobody has chosen.
    let isDefault: Bool
    let selected: Bool
    /// A subtitle meant to be shown even with subtitles off: signs, or the
    /// one alien language in a film. Flagged, or only named so.
    let forced: Bool
    /// Commentary or audio description: never what a film opens on.
    let aside: Bool
    /// Subtitles for the deaf and hard of hearing, sounds described.
    let sdh: Bool
    /// The language as a short tag, "fr": what the track's name says, else
    /// the container's. The name first, since an untagged Matroska track
    /// reads "eng" whatever it is, and "VFF" is then all it says of itself.
    let spoken: String
    /// French from Quebec, which a French viewer takes after France's.
    let quebec: Bool

    init(_ dict: NSDictionary) {
        index = Int32(dict.int("index"))
        codec = dict.string("codec")
        language = dict.string("language")
        title = dict.string("title")
        graphic = dict.bool("graphic")
        channels = dict.int("channels")
        isDefault = dict.bool("default")
        selected = dict.bool("selected")
        let name = title.lowercased()
        forced = dict.bool("forced") || name.contains("forc")
        aside = ["comment", "descri", "malvoyant", "visually impaired"].contains { name.contains($0) }
        sdh = ["sdh", "sourd", "malentendant", "hearing impaired"].contains { name.contains($0) }
        quebec = ["vfq", "québec", "quebec", "canad"].contains { name.contains($0) }
            || language.lowercased().hasSuffix("-ca")
        let words = Set(name.split { !$0.isLetter }.map(String.init))
        spoken = !words.isDisjoint(with: ["vf", "vff", "vfq", "vfi", "truefrench", "français", "francais", "french"])
            ? "fr" : !words.isDisjoint(with: ["english", "anglais"]) ? "en" : LanguageTag.normalize(language)
    }

    /// The audio a film opens on: in `language` when the file has it, else
    /// in the container's default track's; within it, never an aside, the
    /// track the player opened on when it is one (its format rule already
    /// ran), else the flagged default, else the most channels.
    static func bestAudio(_ tracks: [MediaTrack], language: String) -> MediaTrack? {
        let main = tracks.filter { !$0.aside }
        let pool = main.isEmpty ? tracks : main
        let wanted = pool.contains { $0.spoken == language }
            ? language : (pool.first(where: \.isDefault) ?? pool.first).map { $0.spoken }
        let spoken = pool.filter { $0.spoken == wanted }
        let france = spoken.filter { !$0.quebec }
        let same = france.isEmpty ? spoken : france
        if let open = same.first(where: \.selected) { return open }
        let pick = same.first(where: \.isDefault) ?? same.max { $0.channels < $1.channels }
        // TrueHD and DTS become PCM here while their AC-3 twin leaves as the
        // bitstream the receiver decodes, Atmos included: the player's own rule,
        // which never trades surround for a stereo downmix
        guard let pick, pick.codec == "truehd" || pick.codec == "dts" else { return pick }
        return same.filter {
            ($0.codec == "eac3" || $0.codec == "ac3") && $0.channels >= min(pick.channels, 6)
        }.max { $0.channels < $1.channels } ?? pick
    }

    /// Full subtitles in `language`: a text track over a picture one, plain
    /// over SDH, the flagged default first.
    static func bestSubtitle(_ tracks: [MediaTrack], language: String) -> MediaTrack? {
        tracks.filter { !$0.forced && $0.spoken == language }.min {
            $0.subtitleRank < $1.subtitleRank
        }
    }

    private var subtitleRank: Int { (sdh ? 4 : 0) + (graphic ? 2 : 0) + (isDefault ? 0 : 1) }

    /// The container's title, else the language's name, else the codec:
    /// never the three letters a container tags a language with.
    var label: String {
        if !title.isEmpty { return title }
        if !language.isEmpty { return I18n.shared.languageName(LanguageTag.normalize(language)) }
        return codec
    }
}

struct ChapterMark: Equatable {
    let start: Double
    let title: String
}

enum LanguageTag {
    private static let aliases: [String: String] = [
        "eng": "en", "fre": "fr", "fra": "fr", "ger": "de", "deu": "de", "spa": "es", "ita": "it",
        "por": "pt", "dut": "nl", "nld": "nl", "jpn": "ja", "chi": "zh", "zho": "zh", "kor": "ko",
        "rus": "ru", "ara": "ar", "swe": "sv", "nor": "no", "dan": "da", "fin": "fi", "pol": "pl",
        "tur": "tr", "gre": "el", "ell": "el", "heb": "he", "hin": "hi", "tha": "th", "vie": "vi",
        "cze": "cs", "ces": "cs", "hun": "hu", "rum": "ro", "ron": "ro", "ukr": "uk", "ind": "id",
        "cat": "ca",
    ]

    /// "fre-CA" and "fra" both read as "fr"; a tag with no alias stays as it is.
    static func normalize(_ raw: String) -> String {
        let base = raw.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
        return aliases[base] ?? base
    }
}

/// One stats tick, as the info panel reads it. Equatable so a tick that
/// changes nothing leaves the tabs that read it alone.
struct PlayerStats: Equatable {
    let fileOpen: Bool
    let videoPassthrough: Bool
    let videoPath: VideoPath
    let videoDescription: String
    let dolbyVisionProfile: Int
    let displayEligibleForHDR: Bool
    let displaySupportsDolbyVision: Bool
    let upscaleWidth: Int
    let upscaleHeight: Int
    let dynamicRange: String
    let displayRefreshRate: Double
    let displayModeNegotiated: Bool
    let displayCriteriaMatchingEnabled: Bool
    let rendererFramesDisplayed: Int
    let rendererFramesDropped: Int
    let rendererLastDropSeconds: Double
    let audioFormat: String
    let audioPassthrough: Bool
    let audioChannels: Int
    let audioRouteLimited: Bool
    let audioRendering: AVAudioSession.RenderingMode
    let ioSustainedBitsPerSecond: Double
    let ioFetchLatencySeconds: Double
    let rebufferCount: Int
    let pictureStarvations: Int
    let bufferedSeconds: Double

    /// The engine's reading, with what only the bridge knows of the display
    /// and the renderer.
    init(
        _ stats: PlaybackStats, fileOpen: Bool, dynamicRange: String, displayRefreshRate: Double,
        displayModeNegotiated: Bool, displayCriteriaMatchingEnabled: Bool, rendererFramesDisplayed: Int,
        rendererFramesDropped: Int, rendererLastDropSeconds: Double, audioRendering: AVAudioSession.RenderingMode
    ) {
        self.fileOpen = fileOpen
        videoPassthrough = stats.videoPassthrough
        videoPath = stats.videoPath
        videoDescription = stats.videoDescription
        dolbyVisionProfile = Int(stats.dolbyVisionProfile)
        displayEligibleForHDR = stats.displayEligibleForHDR
        displaySupportsDolbyVision = stats.displaySupportsDolbyVision
        upscaleWidth = Int(stats.upscaleWidth)
        upscaleHeight = Int(stats.upscaleHeight)
        self.dynamicRange = dynamicRange
        self.displayRefreshRate = displayRefreshRate
        self.displayModeNegotiated = displayModeNegotiated
        self.displayCriteriaMatchingEnabled = displayCriteriaMatchingEnabled
        self.rendererFramesDisplayed = rendererFramesDisplayed
        self.rendererFramesDropped = rendererFramesDropped
        self.rendererLastDropSeconds = rendererLastDropSeconds
        audioFormat = stats.audioFormat
        audioPassthrough = stats.audioPassthrough
        audioChannels = Int(stats.audioChannels)
        audioRouteLimited = stats.audioRouteLimited
        self.audioRendering = audioRendering
        ioSustainedBitsPerSecond = stats.ioSustainedBitsPerSecond
        ioFetchLatencySeconds = stats.ioFetchLatencySeconds
        rebufferCount = stats.rebufferCount
        pictureStarvations = stats.pictureStarvations
        bufferedSeconds = stats.bufferedSeconds
    }
}

extension NSDictionary {
    func double(_ key: String) -> Double { (self[key] as? NSNumber)?.doubleValue ?? 0 }
    func int(_ key: String) -> Int { (self[key] as? NSNumber)?.intValue ?? 0 }
    func bool(_ key: String) -> Bool { (self[key] as? NSNumber)?.boolValue ?? false }
    func string(_ key: String) -> String { self[key] as? String ?? "" }
}

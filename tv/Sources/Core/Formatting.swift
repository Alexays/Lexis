import Foundation
import LexisCore

/// The words the screens derive from what the core says.
enum Format {
    /// "1h 52m" or "48 min", the way a runtime reads on a card.
    static func runtime(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        let hours = minutes / 60
        let rest = minutes % 60
        if hours == 0 { return t("fmt.minutes", ["m": String(rest)]) }
        return t("fmt.hoursMinutes", ["h": String(hours), "m": rest < 10 ? "0\(rest)" : String(rest)])
    }

    /// "4:03" or "1:02:15": a position, with hours only where they are asked.
    static func clock(_ seconds: Double, withHours: Bool) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        if !withHours || hours == 0 {
            return String(format: "%d:%02d", total / 60, secs)
        }
        return String(format: "%d:%02d:%02d", hours, minutes, secs)
    }

    /// A wall clock from minutes of the day: "22:30" or "22h30", in the
    /// register the runtimes beside it are written in.
    static func wallClock(minutes: Int) -> String {
        let hours = (minutes / 60) % 24, rest = minutes % 60
        return I18n.shared.current == .fr
            ? String(format: "%dh%02d", hours, rest)
            : String(format: "%d:%02d", hours, rest)
    }

    /// A genre as the language on screen names it. Plex hands genres over in
    /// its agent's language, and older matches in English, so one library
    /// holds both "Aventure" and "Adventure"; a name not known is kept.
    static func genre(_ name: String) -> String {
        genreKeys[name.lowercased()].map { t("genre.\($0)") } ?? name
    }

    private static let genreKeys: [String: String] = {
        let names: [String: [String]] = [
            "action": ["action"],
            "actionAdventure": ["action/aventure", "action & adventure", "action/adventure"],
            "adventure": ["adventure", "aventure"],
            "animation": ["animation"],
            "anime": ["anime"],
            "biography": ["biography", "biographie"],
            "children": ["children", "kids", "enfants"],
            "comedy": ["comedy", "comédie"],
            "crime": ["crime"],
            "documentary": ["documentary", "documentaire"],
            "drama": ["drama", "drame"],
            "family": ["family", "familial"],
            "fantasy": ["fantasy", "fantastique"],
            "gameShow": ["game show", "jeu télévisé"],
            "history": ["history", "histoire"],
            "horror": ["horror", "horreur"],
            "miniSeries": ["mini-series", "mini-série"],
            "music": ["music", "musique"],
            "musical": ["musical", "comédie musicale"],
            "mystery": ["mystery", "mystère"],
            "news": ["news", "actualités"],
            "reality": ["reality", "téléréalité"],
            "romance": ["romance"],
            "sciFi": ["science fiction", "science-fiction", "sci-fi"],
            "sciFiFantasy": ["sci-fi & fantasy", "science-fiction & fantastique"],
            "short": ["short", "court métrage"],
            "soap": ["soap", "feuilleton"],
            "sport": ["sport"],
            "suspense": ["suspense"],
            "talkShow": ["talk show", "talk-show"],
            "thriller": ["thriller"],
            "tvMovie": ["tv movie", "téléfilm"],
            "war": ["war", "guerre"],
            "warPolitics": ["war & politics", "guerre & politique"],
            "western": ["western"],
        ]
        var keys: [String: String] = [:]
        for (key, spellings) in names {
            for spelling in spellings { keys[spelling] = key }
        }
        return keys
    }()

    /// "S1, E6" or "S1, É6", the way the system's own apps write it.
    static func episodeCode(season: UInt16?, episode: UInt16?) -> String {
        guard let season, let episode else { return "" }
        return t("fmt.episodeCode", ["s": String(season), "e": String(episode)])
    }

    private static let articles: Set<String> = ["le", "la", "les", "un", "une", "des", "du", "de", "the", "a", "an"]

    /// The first letters of a title's first two significant words.
    static func monogram(_ name: String) -> String {
        let words = name.split(whereSeparator: \.isWhitespace).map(String.init)
        var significant = words.filter { !articles.contains($0.lowercased()) }
        if significant.isEmpty { significant = words }
        return significant.prefix(2).compactMap { $0.first.map(String.init) }.joined().uppercased()
    }

    /// The first letters of a person's first and last names.
    static func initials(_ name: String) -> String {
        let parts = name.split(whereSeparator: \.isWhitespace)
        guard let first = parts.first?.first else { return "" }
        if parts.count == 1 { return String(first).uppercased() }
        let last = parts.last!.first!
        return (String(first) + String(last)).uppercased()
    }

    /// What the file promises of its picture, and only that.
    static func badges(_ media: TitleMedia?) -> [String] {
        guard let media else { return [] }
        var out: [String] = []
        switch media.videoResolution {
        case "": break
        case "4k": out.append("4K")
        case "sd": out.append("SD")
        default: out.append(media.videoResolution.uppercased() + "P")
        }
        if media.dynamicRange == "dolby_vision" { out.append("DOLBY VISION") }
        else if !media.dynamicRange.isEmpty { out.append("HDR") }
        if media.atmos { out.append("ATMOS") }
        return out
    }

    /// "Extended Edition  ·  1080P  ·  14.1 GB  ·  2h 39m": what tells one copy from another.
    static func version(_ version: TitleVersion) -> String {
        var parts = version.edition.isEmpty ? [] : [version.edition]
        parts += badges(version.media)
        if version.sizeBytes > 0 {
            // in the app's language, not the device's: "14.1 GB", "14,1 Go"
            let locale = Locale(identifier: I18n.shared.current.rawValue)
            parts.append(Int64(version.sizeBytes).formatted(.byteCount(style: .file).locale(locale)))
        }
        if version.runtimeSecs > 0 { parts.append(runtime(version.runtimeSecs)) }
        return parts.joined(separator: "  ·  ")
    }

    /// "French, English  ·  subtitles French", or nil where the file names none.
    static func languagesLine(_ media: TitleMedia?) -> String? {
        guard let media else { return nil }
        let names = { (codes: [String]) in
            codes.filter { $0 != "mul" }.map(I18n.shared.languageName).joined(separator: ", ")
        }
        let audio = names(media.audioLanguages), subtitles = names(media.subtitleLanguages)
        let parts = [
            audio.isEmpty ? nil : audio,
            subtitles.isEmpty ? nil : t("title.subtitlesIn", ["list": subtitles]),
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    private static let audioCodecs: [String: String] = [
        "truehd": "Dolby TrueHD", "eac3": "Dolby Digital+", "ac3": "Dolby Digital", "dca": "DTS",
        "dca-ma": "DTS-HD MA", "aac": "AAC", "flac": "FLAC", "opus": "Opus", "mp3": "MP3", "pcm": "PCM",
    ]

    /// "Dolby Atmos  ·  Dolby TrueHD 7.1", or nil where the file says nothing.
    static func audioLine(_ media: TitleMedia?) -> String? {
        guard let media else { return nil }
        let codec = audioCodecs[media.audioCodec]
            ?? (media.audioCodec.isEmpty ? nil : media.audioCodec.uppercased())
        let layout: String? = switch media.audioChannels {
        case 0: nil
        case 1: t("media.mono")
        case 2: t("media.stereo")
        default: "\(media.audioChannels - 1).1"
        }
        let track = [codec, layout].compactMap { $0 }.joined(separator: " ")
        let parts = [media.atmos ? "Dolby Atmos" : nil, track.isEmpty ? nil : track].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    /// A score and where it came from; nil for a provider nobody names.
    static func score(_ score: TitleScore?) -> (value: String, source: String)? {
        guard let score else { return nil }
        switch score.source {
        case "imdb", "themoviedb":
            let n = String(format: "%.1f", score.value).replacingOccurrences(of: ".", with: t("fmt.decimal"))
            return (t("fmt.score", ["n": n]), score.source == "imdb" ? "IMDb" : "TMDB")
        case "rottentomatoes":
            return (t("fmt.scorePercent", ["n": String(Int((score.value * 10).rounded()))]), "Rotten Tomatoes")
        default:
            return nil
        }
    }

    /// "3 minutes ago", from a unix time.
    static func relativeTime(_ unixSeconds: Int64) -> String {
        let ago = max(0, Date().timeIntervalSince1970 - Double(unixSeconds))
        if ago < 3600 { return t("settings.minutesAgo", ["n": String(max(1, Int(ago / 60)))]) }
        if ago < 86400 { return t("settings.hoursAgo", ["n": String(Int(ago / 3600))]) }
        return t("settings.daysAgo", ["n": String(Int(ago / 86400))])
    }

    /// The core's error, in the viewer's language, its own words kept.
    /// The names the sources answered with, by id, for an error that names
    /// one: an id is a server's machine identifier, not a word.
    /// Written on the main actor whenever the sources are listed.
    static var sourceNames: [String: String] = [:]

    static func describe(_ error: Error) -> String {
        guard let core = error as? CoreError else {
            return t("error.unexpected", ["detail": String(describing: error)])
        }
        switch core {
        case .Storage(let msg): return t("error.storage", ["detail": msg])
        case .InvalidConfig(let msg): return t("error.invalidConfig", ["detail": msg])
        case .EmbedModelUnusable(let msg): return t("error.embedModel", ["detail": msg])
        case .SourceUnavailable(let sourceId, let msg):
            return t("error.source", ["source": sourceNames[sourceId] ?? sourceId, "detail": msg])
        case .Unauthorized(let sourceId): return t("error.unauthorized", ["source": sourceNames[sourceId] ?? sourceId])
        case .NotFound: return t("error.notFound")
        case .SchemaTooNew: return t("error.schemaTooNew")
        }
    }

    /// Seconds east of UTC, what the core's evening logic is told.
    static var tzOffsetSecs: Int32 { Int32(TimeZone.current.secondsFromGMT()) }

    /// A month's name, 1 to 12, in the language on screen, as it stands in
    /// the middle of a sentence: "November", "novembre".
    static func monthName(_ month: UInt8) -> String {
        let names = monthNames[I18n.shared.current] ?? []
        let index = Int(month) - 1
        guard names.indices.contains(index) else { return String(month) }
        return names[index]
    }

    /// Both languages' month names, read off one formatter once.
    private static let monthNames: [Language: [String]] = {
        let formatter = DateFormatter()
        var names: [Language: [String]] = [:]
        for language in Language.allCases {
            formatter.locale = Locale(identifier: language.rawValue)
            let symbols = formatter.standaloneMonthSymbols ?? []
            names[language] = language == .fr ? symbols.map { $0.lowercased() } : symbols
        }
        return names
    }()

    /// French shortens a twentieth century decade to two digits.
    static func decadeName(_ first: UInt16) -> String {
        if I18n.shared.current == .fr, first >= 1920, first < 2000 {
            return String(format: "%02d", Int(first) % 100)
        }
        return String(first)
    }
}

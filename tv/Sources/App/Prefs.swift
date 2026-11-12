import Foundation

/// The viewer's choices, in UserDefaults: the one store that survives a
/// tvOS cache purge. Every value is stored as the bytes of a short string,
/// the shape the previous app wrote them in, so a viewer's settings carry
/// over: "1" and "0" for a switch, a word for a choice.
enum Prefs {
    private static let store = UserDefaults.standard

    static func string(_ key: String) -> String? {
        guard let data = store.data(forKey: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ key: String, _ value: String) {
        store.set(Data(value.utf8), forKey: key)
    }

    static func flag(_ key: String, default fallback: Bool) -> Bool {
        switch string(key) {
        case "1": return true
        case "0": return false
        default: return fallback
        }
    }

    static func set(_ key: String, _ value: Bool) {
        set(key, value ? "1" : "0")
    }

    // The keys, as the settings screens and the player bridge both read them.
    static let upscalingKey = "video.upscaling.v1"
    static let neuralUpscalingKey = "video.neuralUpscaling.v1"
    static let dolbyVisionKey = "video.dolbyVision.v1"
    static let audioPassthroughKey = "audio.passthrough.v1"
    static let languageKey = "ui.language.v1"

    static var languageChoice: LanguageChoice {
        get {
            switch string(languageKey) {
            case "en": return .pinned(.en)
            case "fr": return .pinned(.fr)
            default: return .system
            }
        }
        set {
            switch newValue {
            case .system: set(languageKey, "system")
            case .pinned(let language): set(languageKey, language.rawValue)
            }
        }
    }
}

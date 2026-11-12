import Foundation
import Observation

enum Language: String, CaseIterable {
    case en, fr
}

/// What the settings screen offers: follow the system, or pin a language.
enum LanguageChoice: Equatable {
    case system
    case pinned(Language)
}

/// The words on screen, in the language the viewer chose or the system's.
/// One instance for the app; a change re-renders every view reading it.
@Observable
final class I18n {
    static let shared = I18n()

    private(set) var choice = LanguageChoice.system
    private(set) var current = Language.en

    private init() {
        choice = Prefs.languageChoice
        current = I18n.resolve(choice)
    }

    func choose(_ next: LanguageChoice) {
        choice = next
        current = I18n.resolve(next)
        Prefs.languageChoice = next
    }

    private static func resolve(_ choice: LanguageChoice) -> Language {
        switch choice {
        case .pinned(let language): return language
        case .system:
            let preferred = Locale.preferredLanguages.first ?? "en"
            return preferred.hasPrefix("fr") ? .fr : .en
        }
    }

    private var catalog: [String: String] {
        current == .fr ? Catalog.fr : Catalog.en
    }

    /// The message for `key`, with `{name}` placeholders filled from `params`,
    /// and `{name|one|other}` read as the form the count in `name` takes: in
    /// French one and zero are singular, in English only one.
    /// A key the catalog lacks reads as the key itself: never a blank line.
    func t(_ key: String, _ params: [String: String] = [:]) -> String {
        guard var message = catalog[key] else { return key }
        if let pieces = I18n.plurals[message] {
            message = ""
            for piece in pieces {
                switch piece {
                case .text(let text): message += text
                case .plural(let name, let one, let other):
                    let count = params[name].flatMap { Int($0) }
                    let singular = count.map { current == .fr ? $0 <= 1 : $0 == 1 } ?? false
                    message += singular ? one : other
                }
            }
        }
        for (name, value) in params {
            // French elides "de" before a vowel: "d'Amélie", never "de Amélie".
            // Not before "y" or "h", where it depends on the word.
            if current == .fr, let first = value.first, I18n.vowels.contains(first) {
                // padded so a message that opens on "de" is matched as a word too
                message = String(
                    (" " + message)
                        .replacingOccurrences(of: " de {\(name)}", with: " d'\(value)")
                        .replacingOccurrences(of: " De {\(name)}", with: " D'\(value)")
                        .dropFirst())
            }
            message = message.replacingOccurrences(of: "{\(name)}", with: value)
        }
        return message
    }

    private static let vowels = Set("aeiouàâäéèêëîïôöùûüœæAEIOUÀÂÄÉÈÊËÎÏÔÖÙÛÜŒÆ")

    private enum Piece {
        case text(String)
        case plural(name: String, one: String, other: String)
    }

    /// Every catalog message with a `{name|one|other}` form, split around
    /// those forms once, so a label drawn in a list costs no regex.
    private static let plurals: [String: [Piece]] = {
        let regex = try! NSRegularExpression(pattern: "\\{(\\w+)\\|([^|}]*)\\|([^}]*)\\}")
        var parsed: [String: [Piece]] = [:]
        for message in [Catalog.en, Catalog.fr].joined().map(\.value) where message.contains("|") {
            var pieces: [Piece] = []
            var rest = message.startIndex
            for match in regex.matches(in: message, range: NSRange(message.startIndex..., in: message)) {
                guard let whole = Range(match.range, in: message),
                    let name = Range(match.range(at: 1), in: message),
                    let one = Range(match.range(at: 2), in: message),
                    let other = Range(match.range(at: 3), in: message)
                else { continue }
                pieces.append(.text(String(message[rest..<whole.lowerBound])))
                pieces.append(.plural(name: String(message[name]), one: String(message[one]), other: String(message[other])))
                rest = whole.upperBound
            }
            guard !pieces.isEmpty else { continue }
            pieces.append(.text(String(message[rest...])))
            parsed[message] = pieces
        }
        return parsed
    }()

    /// A module names its own keys as `sourceModule.<id>.<part>`; a key the
    /// catalogue does not carry falls back to `fallback`.
    func moduleText(_ id: String, _ part: String, fallback: String? = nil) -> String {
        catalog["sourceModule.\(id).\(part)"] ?? fallback ?? id
    }

    /// What a language tag is called, in the language on screen; a tag no
    /// catalog names is drawn as it is.
    func languageName(_ tag: String) -> String {
        catalog["lang.\(tag)"] ?? tag
    }
}

/// The message for `key` in the current language, for views.
func t(_ key: String, _ params: [String: String] = [:]) -> String {
    I18n.shared.t(key, params)
}

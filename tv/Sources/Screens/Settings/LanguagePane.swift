import SwiftUI

/// The interface language: the system's, or one pinned.
struct LanguagePane: View {
    @Environment(I18n.self) private var i18n

    private var selected: String {
        switch i18n.choice {
        case .system: "system"
        case .pinned(let language): language.rawValue
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(t("settings.language"))
                .font(Theme.Typography.title)
                .tracking(Theme.Typography.titleTracking)
                .foregroundStyle(Theme.Colors.white)
                .padding(.bottom, Theme.Space.s24)
            SettingCard {
                SettingRow(label: t("settings.languageInterface"), caption: t("settings.languageCaption")) {
                    Segmented(
                        options: [
                            (value: "system", label: t("settings.languageSystem")),
                            (value: "fr", label: t("settings.languageFrench")),
                            (value: "en", label: t("settings.languageEnglish")),
                        ],
                        selected: selected
                    ) { value in
                        i18n.choose(Language(rawValue: value).map { .pinned($0) } ?? .system)
                    }
                }
            }
        }
    }
}

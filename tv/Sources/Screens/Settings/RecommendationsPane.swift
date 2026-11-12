import SwiftUI

/// How far the gamble reaches from the viewer's tastes, and how many times
/// an evening may be refused. Every value
/// lives in the core, which holds the budget itself rather than trusting a
/// screen to stop offering the gesture.
struct RecommendationsPane: View {
    let store: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(t("settings.recommendations"))
                .font(Theme.Typography.title)
                .tracking(Theme.Typography.titleTracking)
                .foregroundStyle(Theme.Colors.white)
                .padding(.bottom, Theme.Space.s24)
            SettingCard {
                SettingRow(label: t("settings.stepAside"), caption: t("settings.stepAsideCaption")) {
                    Segmented(
                        options: [
                            (value: "close", label: t("settings.stepAsideClose")),
                            (value: "default", label: t("settings.stepAsideDefault")),
                            (value: "far", label: t("settings.stepAsideFar")),
                        ],
                        selected: store.reach
                    ) { value in
                        Task { await store.setReach(value) }
                    }
                }
                CardDivider()
                SettingRow(label: t("settings.passes"), caption: t("settings.passesCaption")) {
                    Segmented(
                        options: [
                            (value: "1", label: "1"),
                            (value: "3", label: "3"),
                            (value: "5", label: "5"),
                        ],
                        selected: String(store.passes)
                    ) { value in
                        Task { await store.setPasses(UInt32(value) ?? 3) }
                    }
                }
            }
            if let message = store.message {
                Text(message)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.error)
                    .fits(2)
                    .padding(.top, Theme.Space.s16)
            }
        }
    }
}

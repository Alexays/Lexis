import AVFoundation
import LexisPlayer
import SwiftUI

/// Video and audio: every switch at once, then what the sound output takes,
/// in plain words.
struct RoomPane: View {
    let store: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(t("settings.room"))
                .font(Theme.Typography.title)
                .tracking(Theme.Typography.titleTracking)
                .foregroundStyle(Theme.Colors.white)
                .padding(.bottom, Theme.Space.s24)
            OptionsCard(store: store)
                .padding(.bottom, Theme.Space.s24)
            SettingCard {
                Text(t("settings.roomSound")).font(Theme.Typography.body).foregroundStyle(Theme.Colors.text)
                    .padding(.bottom, Theme.Space.s8)
                RoomSound(passthrough: store.passthrough)
            }
        }
    }
}

/// What Lexis reads of the sound output, in plain words, the last film's
/// sound as it left, and, only where the output holds the sound back, what
/// to change outside Lexis.
struct RoomSound: View {
    let passthrough: Bool
    @State private var route: AudioRoute?
    private var diagnostics: PlaybackDiagnostics { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s16) {
            if let route {
                line(t(
                    !route.takesDolby ? "settings.roomSoundOther"
                        : route.channels >= 6 ? "settings.roomSoundSurround" : "settings.roomSoundARC",
                    ["channels": String(route.channels)]))
                if !passthrough && route.takesDolby { line(t("settings.roomSoundConverted")) }
            }
            if let last = diagnostics.last, last.fileOpen, ["ac3", "eac3", "pcm"].contains(last.audioFormat) {
                line(t(
                    last.audioRouteLimited ? "settings.roomSoundLastLimited" : "settings.roomSoundLast",
                    [
                        "format": t("settings.roomSoundFormat.\(last.audioFormat)"),
                        "channels": String(last.audioChannels),
                    ]))
                if let rendering = RoomSound.renderingKey(last.audioRendering) {
                    line(t("settings.playbackAudioRendering", ["rendering": t(rendering)]))
                }
            }
            if let route, (route.takesDolby && route.channels < 6) || diagnostics.last?.audioRouteLimited == true {
                Text(t("settings.roomSoundFix"))
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.text)
                    .padding(.top, Theme.Space.s8)
                line(t("settings.roomSoundFixFormat"))
                line(t("settings.roomSoundFixSonos"))
            }
        }
        // The session is asked off the main thread, where its reads can block.
        .task {
            route = await Task.detached {
                try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
                return AudioRoute.current
            }.value
        }
    }

    private func line(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.Colors.textSecondary)
            .frame(maxWidth: 900, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The words for what the system renders the sound as, nil while it
    /// renders nothing.
    static func renderingKey(_ mode: AVAudioSession.RenderingMode) -> String? {
        switch mode {
        case .dolbyAudio: "settings.audioRendering.dolby"
        case .dolbyAtmos: "settings.audioRendering.atmos"
        case .surround: "settings.audioRendering.surround"
        case .monoStereo: "settings.audioRendering.stereo"
        case .spatialAudio: "settings.audioRendering.spatial"
        default: nil
        }
    }
}

/// The switches. Their defaults are what Lexis would choose; each caption
/// says when to change it.
private struct OptionsCard: View {
    let store: SettingsStore
    @State private var neural = Prefs.flag(Prefs.neuralUpscalingKey, default: true)
    @State private var dolbyVision = Prefs.flag(Prefs.dolbyVisionKey, default: true)

    var body: some View {
        SettingCard {
            SettingRow(label: t("settings.videoUpscaling"), caption: t("settings.videoCaption")) {
                Segmented(
                    options: [
                        (value: true, label: t("settings.videoUpscalingOn")),
                        (value: false, label: t("settings.videoUpscalingOff")),
                    ],
                    selected: store.upscaling
                ) { value in
                    store.upscaling = value
                    Prefs.set(Prefs.upscalingKey, value)
                }
            }
            CardDivider()
            SettingRow(
                label: t("settings.videoNeuralUpscaling"), caption: t("settings.videoNeuralUpscalingCaption")
            ) {
                Segmented(
                    options: [
                        (value: true, label: t("settings.videoUpscalingOn")),
                        (value: false, label: t("settings.videoUpscalingOff")),
                    ],
                    selected: neural
                ) { value in
                    neural = value
                    Prefs.set(Prefs.neuralUpscalingKey, value)
                }
            }
            CardDivider()
            SettingRow(label: t("settings.videoDolbyVision"), caption: t("settings.videoDolbyVisionCaption")) {
                Segmented(
                    options: [
                        (value: true, label: t("settings.videoDolbyVisionOn")),
                        (value: false, label: t("settings.videoDolbyVisionOff")),
                    ],
                    selected: dolbyVision
                ) { value in
                    dolbyVision = value
                    Prefs.set(Prefs.dolbyVisionKey, value)
                }
            }
            CardDivider()
            SettingRow(label: t("settings.audioOutput"), caption: t("settings.audioCaption")) {
                Segmented(
                    options: [
                        (value: true, label: t("settings.audioBitstream")),
                        (value: false, label: t("settings.audioDecoded")),
                    ],
                    selected: store.passthrough
                ) { value in
                    store.passthrough = value
                    Prefs.set(Prefs.audioPassthroughKey, value)
                }
            }
        }
    }
}

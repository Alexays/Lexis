import AVFoundation
import LexisCore
import SwiftUI

/// The counters a playing file reports, once a second while one plays.
/// Every field reads its plain default until `fileOpen` is true; the
/// unmeasured readings (a sample count, a rate, a latency) read as zero.
struct PlaybackReading: Equatable {
    var packetsRead: UInt64 = 0
    var framesDisplayed: UInt64 = 0
    var framesDropped: UInt64 = 0
    var decodeFailures: UInt64 = 0
    var decodeMillisecondsMean: Double = 0
    var decodeMillisecondsWorst: Double = 0
    var decodeSampleCount: UInt64 = 0
    /// The display layer decodes this file, not the player: decode timing
    /// and hardware can never be read back for it.
    var videoPassthrough = false
    var hardwareAccelerated = false
    var hardwareAccelerationKnown = false
    var fileOpen = false
    var dynamicRange = "sdr"
    var displayRefreshRate: Double = 0
    var displayModeNegotiated = false
    var displayCriteriaMatchingEnabled = false
    var rendererFramesDisplayed: UInt64 = 0
    var rendererFramesDropped: UInt64 = 0
    var audioFormat = "pcm"
    var audioPassthrough = false
    var audioChannels = 0
    /// The route folded the decoded sound to fewer channels than the track has.
    var audioRouteLimited = false
    var audioRendering = AVAudioSession.RenderingMode.notApplicable
    var audioFallbackReason = ""
    var ioSustainedBitsPerSecond: Double = 0
    var ioFetchLatencySeconds: Double = 0
}

/// What the last stats tick reported; nil until a file has played this
/// launch. The player screen writes it, the diagnostics pane reads it.
@MainActor
@Observable
final class PlaybackDiagnostics {
    static let shared = PlaybackDiagnostics()
    var last: PlaybackReading?
    private init() {}
}

/// The technical pane: the TMDB token, what the last scan and the pass
/// did, and what the player reported of the last file.
struct DiagnosticsPane: View {
    let store: SettingsStore
    @State private var key = ""
    @State private var progress: PassProgress?
    private var work: BackgroundWork { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(t("settings.diagnostics"))
                .font(Theme.Typography.title)
                .tracking(Theme.Typography.titleTracking)
                .foregroundStyle(Theme.Colors.white)
                .padding(.bottom, Theme.Space.s24)
            HStack(alignment: .top, spacing: Theme.Space.s24) {
                DiagnosticCard { tmdbCard }
                DiagnosticCard { libraryCard }
            }
            .padding(.bottom, Theme.Space.s24)
            PlaybackReadout()
            Text(tmdbAttribution())
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textMuted)
                .padding(.top, Theme.Space.s40)
        }
        // Keyed on the phase alone: the counters move at the poll rate, and
        // the progress is read again at a pace a reader can follow.
        .task(id: work.phase) {
            while !Task.isCancelled {
                let fresh = await CoreClient.run { try? CoreClient.shared.passProgress() }
                if let fresh, fresh != progress { progress = fresh }
                guard work.passRunning else { return }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    @ViewBuilder private var tmdbCard: some View {
        HStack(alignment: .center, spacing: Theme.Space.s16) {
            Text(t("settings.tmdb"))
                .font(Theme.Typography.body.weight(.semibold))
                .foregroundStyle(Theme.Colors.text)
            Spacer(minLength: 0)
            if store.tmdbStored {
                HStack(spacing: Theme.Space.s16) {
                    Circle().fill(Theme.Colors.accent).frame(width: 8, height: 8)
                    Text(t("settings.tokenStoredShort"))
                        .font(Theme.Typography.captionCompact)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
                .padding(.horizontal, Theme.Space.s16)
                .padding(.vertical, Theme.Space.s8)
                .glassCapsule(tint: Theme.Glass.panel)
            }
        }
        .padding(.bottom, Theme.Space.s16)
        if store.tmdbStored {
            Meta(t("settings.tmdbStored"))
        } else if let progress {
            let undescribed = progress.total - min(progress.total, progress.described)
            Meta(undescribed == 0
                ? t("settings.tmdbNotMissing")
                : t("settings.tmdbMissing", ["undescribed": String(undescribed), "total": String(progress.total)]))
        }
        Meta(t("settings.tmdbHint")).padding(.bottom, Theme.Space.s16)
        Field(label: t("settings.tmdbField"), value: $key, secure: true)
        HStack(spacing: Theme.Space.s24) {
            ActionButton(label: t("settings.saveTmdb")) {
                let token = key
                Task { if await store.saveToken(token) { key = "" } }
            }
            if store.tmdbStored {
                ActionButton(label: t("settings.removeTmdb")) { Task { await store.removeToken() } }
            }
        }
        .padding(.vertical, Theme.Space.s16)
        Meta(t("settings.tmdbRemoveHint"))
    }

    @ViewBuilder private var libraryCard: some View {
        Text(t("settings.library"))
            .font(Theme.Typography.body.weight(.semibold))
            .foregroundStyle(Theme.Colors.text)
            .padding(.bottom, Theme.Space.s16)
        if let scanning = store.scanProgress {
            Meta(t("settings.scanProgress", [
                "done": String(scanning.sourcesDone), "total": String(scanning.sourcesTotal),
            ]))
        }
        if let report = store.report {
            Meta(t("settings.scanCounts", [
                "seen": String(report.filesSeen), "indexed": String(report.filesUpserted),
                "removed": String(report.filesRemoved), "failed": String(report.sourcesFailed),
            ]))
            ForEach(report.perSource, id: \.id) { result in
                if let error = result.error {
                    Meta(
                        result.unauthorized
                            ? t("error.unauthorized", ["source": result.id])
                            : t("error.source", ["source": result.id, "detail": error]),
                        color: Theme.Colors.error)
                    if result.unauthorized {
                        Meta(t("settings.tokenRejected"), color: Theme.Colors.error)
                    }
                } else {
                    Meta("\(result.id): " + t("settings.sourceCounts", [
                        "seen": String(result.filesSeen), "indexed": String(result.filesUpserted),
                        "removed": String(result.filesRemoved),
                    ]))
                }
            }
        }
        if store.queued > 0 {
            Meta(t("settings.queuedWrites", ["n": String(store.queued)]), color: Theme.Colors.error)
        }
        if let progress {
            let stuck = work.phase == .done && work.passMessage != nil
            Meta(
                t("settings.metadataProgress", [
                    "described": String(progress.described), "total": String(progress.total),
                    "linked": String(progress.linked), "embedded": String(progress.embedded),
                    "status": passStatus,
                ]),
                color: stuck ? Theme.Colors.error : Theme.Colors.textMuted)
        }
    }

    private var passStatus: String {
        switch work.phase {
        case .idle: t("settings.passIdle")
        case .done: work.passMessage.map { t("settings.passStuck", ["message": $0]) } ?? t("settings.passDone")
        default: t("settings.passRunning")
        }
    }
}

/// One of the two cards side by side: half the pane, and no wider than a
/// paragraph reads.
private struct DiagnosticCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s8, content: content)
            .padding(Theme.Space.s24)
            .frame(minWidth: 520, maxWidth: 660, alignment: .topLeading)
            .glassSurface(radius: Theme.Radius.panel, tint: Theme.Glass.panel)
    }
}

private struct Meta: View {
    let text: String
    var color = Theme.Colors.textMuted

    init(_ text: String, color: Color = Theme.Colors.textMuted) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text).font(Theme.Typography.caption).foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// What the player reported of the last file; nothing until one played.
private struct PlaybackReadout: View {
    private var diagnostics: PlaybackDiagnostics { .shared }

    var body: some View {
        if let d = diagnostics.last {
            DiagnosticCard {
                Text(t("settings.playback"))
                    .font(Theme.Typography.body.weight(.semibold))
                    .foregroundStyle(Theme.Colors.text)
                    .padding(.bottom, Theme.Space.s16)
                Meta(t("settings.playbackFrames", [
                    "packets": String(d.packetsRead), "shown": String(d.framesDisplayed),
                ]))
                Meta(t("settings.playbackFramesDropped", ["dropped": String(d.framesDropped)]))
                Meta(t("settings.playbackRendererDropped", [
                    "dropped": String(d.rendererFramesDropped), "shown": String(d.rendererFramesDisplayed),
                ]))
                Meta(t("settings.playbackDecodeFailures", ["count": String(d.decodeFailures)]))
                Meta(decodeLine(d))
                Meta(hardwareLine(d))
                Meta(displayLine(d))
                Meta(audioLine(d))
                if d.fileOpen && d.audioRouteLimited {
                    Meta(t("settings.playbackAudioLimited", ["channels": String(d.audioChannels)]), color: Theme.Colors.error)
                }
                if d.fileOpen, let rendering = RoomSound.renderingKey(d.audioRendering) {
                    Meta(t("settings.playbackAudioRendering", ["rendering": t(rendering)]))
                }
                if d.fileOpen && d.audioFormat == "unsupported" {
                    Meta(t("settings.playbackAudioNoDecoder"), color: Theme.Colors.error)
                }
                if !d.audioFallbackReason.isEmpty {
                    Meta(t("settings.playbackFallback", ["reason": d.audioFallbackReason]), color: Theme.Colors.error)
                }
                Meta(
                    d.ioSustainedBitsPerSecond == 0
                        ? t("settings.playbackIoThroughputUnknown")
                        : t("settings.playbackIoThroughputKnown", [
                            "mbps": String(format: "%.1f", d.ioSustainedBitsPerSecond / 1_000_000)
                                .replacingOccurrences(of: ".", with: t("fmt.decimal")),
                        ]))
                Meta(
                    d.ioFetchLatencySeconds == 0
                        ? t("settings.playbackIoLatencyUnknown")
                        : t("settings.playbackIoLatencyKnown", [
                            "milliseconds": String(format: "%.0f", d.ioFetchLatencySeconds * 1000),
                        ]))
            }
        }
    }

    /// The passthrough path never resolves: nothing here decodes its frames.
    private func decodeLine(_ d: PlaybackReading) -> String {
        if d.fileOpen && d.videoPassthrough { return t("settings.playbackDecodeSystemDecoded") }
        guard d.decodeSampleCount > 0 else { return t("settings.playbackDecodeUnknown") }
        return t("settings.playbackDecodeKnown", [
            "mean": String(format: "%.1f", d.decodeMillisecondsMean)
                .replacingOccurrences(of: ".", with: t("fmt.decimal")),
            "worst": String(format: "%.1f", d.decodeMillisecondsWorst)
                .replacingOccurrences(of: ".", with: t("fmt.decimal")),
        ])
    }

    private func hardwareLine(_ d: PlaybackReading) -> String {
        if d.fileOpen && d.videoPassthrough { return t("settings.playbackHardwareSystemDecoded") }
        guard d.fileOpen && d.hardwareAccelerationKnown else { return t("settings.playbackHardwareUnknown") }
        return t(d.hardwareAccelerated ? "settings.playbackHardwareYes" : "settings.playbackHardwareNo")
    }

    private func displayLine(_ d: PlaybackReading) -> String {
        guard d.fileOpen else { return t("settings.playbackDisplayNotOpen") }
        if d.displayModeNegotiated {
            return t("settings.playbackDisplayKnown", [
                "range": d.dynamicRange,
                "rate": String(format: "%.3f", d.displayRefreshRate)
                    .replacingOccurrences(of: ".", with: t("fmt.decimal")),
            ])
        }
        return t(
            d.displayCriteriaMatchingEnabled
                ? "settings.playbackDisplayUnknown" : "settings.playbackDisplayMatchOff",
            ["range": d.dynamicRange])
    }

    private func audioLine(_ d: PlaybackReading) -> String {
        guard d.fileOpen else { return t("settings.playbackAudioNotOpen") }
        if d.audioFormat == "none" || d.audioFormat == "unsupported" { return t("settings.playbackAudioSilent") }
        return t(
            d.audioPassthrough ? "settings.playbackAudioPassthrough" : "settings.playbackAudioDecoded",
            ["format": d.audioFormat, "channels": String(d.audioChannels)])
    }
}

import AVFoundation
import Foundation
import LexisCore
import LexisCoreStream
import LexisPlayer
import SwiftUI
import UIKit

/// A one-shot timer on the main actor; cancelling the task disarms it.
@MainActor
func after(milliseconds: Int, _ body: @escaping @MainActor () -> Void) -> Task<Void, Never> {
    Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(milliseconds))
        guard !Task.isCancelled else { return }
        body()
    }
}

/// One file's playback: the view the film is drawn in, the bridge's events
/// turned into state, and everything the remote does to it. Built per file:
/// the shell keys the screen on the file, so an auto-advance starts a fresh
/// model and the languages carry over through `handover`.
@MainActor
@Observable
final class PlayerModel {
    enum Asking: Equatable {
        case verdict
        case after(TitleItem)
    }

    enum PanPhase { case began, changed, ended }

    static let seekStep = 10.0
    static let holdSteps = [15.0, 30.0, 60.0]
    static let holdTickMs = 250
    static let holdTicksPerStep = 8
    static let panSpanShare = 6.0
    static let panSpanMin = 120.0
    static let panSurfacePoints = 1920.0
    static let panDeadbandPoints = 40.0
    static let panIdleMs = 1000
    static let panSettleMs = 500
    static let seekTapSettleMs = 300
    static let thumbnailImageLimit = 64
    static let overlayIdleMs = 3500
    static let silenceTimeoutMs = 45_000
    static let fallbackNoticeMs = 8000
    static let reportIntervalSeconds = 15
    static let advanceSeconds = 10
    /// Episodes in a row the countdown may start with nobody touching the
    /// remote; the next one waits for a press, the way a night is not left
    /// playing to an empty room.
    static let unattendedLimit = 3
    /// The sleep timer's choices in minutes, nil off and 0 the end of the film.
    static let sleepChoices: [Int?] = [nil, 15, 30, 45, 60, 90, 0]
    static let audioDelayChoicesMs = [-500, -400, -300, -200, -150, -100, -50, 0, 50, 100, 150, 200, 300, 400, 500]
    static let subtitleOffsetChoices: [Double] = [-5, -3, -2, -1.5, -1, -0.5, -0.25, 0, 0.25, 0.5, 1, 1.5, 2, 3, 5]

    let playing: Playing
    var fileId: Int64 { playing.fileId }
    var titleId: Int64? { playing.landOn?.id }

    /// Built by `start()`, not the init: the shell rebuilds the screen's
    /// value on every pass, and a display layer per pass would be waste.
    private(set) var host: PlayerHostView?

    var status = PlayerStatus.opening
    var failure = ""
    /// What the failure was underneath, in the core's or the decoder's words.
    var failureDetail = ""
    var bufferedSeconds = 0.0
    var audioTracks: [MediaTrack] = []
    var subtitleTracks: [MediaTrack] = []
    var chapters: [ChapterMark] = []
    var overlay = OverlayState.full {
        didSet { if overlay != .hidden { shown = overlay } }
    }
    /// The last state drawn, so a fade to nothing draws what it fades.
    private(set) var shown = OverlayState.full
    var indicator: TransportIndicator?
    /// What the Info tab says of the title, read once per file.
    var detail: TitleDetail?
    /// The chapter cards' pictures, by chapter, filled one at a time.
    var chapterFrames: [Int: UIImage] = [:]
    var picture = Picture()
    var firstFrameSeconds = -1.0
    var audioFallback = false
    var subtitleFallback = false
    /// The file whose end this is, not a flag: the status of a file being
    /// replaced still reads `ended` through the update that swaps it.
    var ended: Int64?
    var next: EpisodeRef?
    var countdown = 0
    var asking: Asking?
    /// The card is up from the first gesture step; a frame lands in it once
    /// decoded, and the last one stays while the next is on its way.
    var scrubCard = false
    var scrubFrame: ScrubFrame?
    var scrub: Double?
    var position: Double
    var duration = 0.0
    var stats: PlayerStats?
    var overlayDrawn = true
    var overlayOpacity = 1.0
    var focusedControl: PlayerControl?
    /// The episode the countdown reached zero for; the screen hands it on.
    var advanceTo: EpisodeRef?
    /// What the overlay's two lines say: the show over the episode's number
    /// and name for an episode, whatever the launch said otherwise.
    var heading: (context: String, title: String)
    /// The intro or recap a "Skip" button stands over now, nil outside one.
    var skipping: SkipMark?

    // Read by the reporter and the gesture arithmetic on every tick; the
    // drawn `position`/`duration` only move while the overlay is up.
    @ObservationIgnored private(set) var positionRef: Double
    @ObservationIgnored private(set) var durationRef = 0.0
    @ObservationIgnored private var openedAt = Date()
    @ObservationIgnored private var left = false
    @ObservationIgnored private var applied = false
    @ObservationIgnored private var preferredAudio = ""
    /// A language, "off", or empty for the automatic choice.
    @ObservationIgnored private(set) var preferredSubtitle = ""
    /// While a skip back replays a stretch with subtitles: where it ends, and
    /// the track to go back to then.
    @ObservationIgnored private var replay: (until: Double, restore: Int32)?
    /// Milliseconds the sound plays after the picture on this output.
    private(set) var audioDelayMs = 0
    @ObservationIgnored private var audioDelayKey = ""
    /// Seconds every subtitle shows late, for this film alone.
    private(set) var subtitleOffset = 0.0
    @ObservationIgnored private var sleepTask: Task<Void, Never>?
    private(set) var sleepChoice: Int?
    /// Where TheIntroDB has this file's intro, recap and credits timed.
    @ObservationIgnored private var marks: [SkipMark] = []
    /// `marks` with the chapters' own where TheIntroDB timed none of a kind;
    /// nil once the chapters, the marks or the duration move.
    @ObservationIgnored private var mergedMarks: [SkipMark]?
    /// Where the credits start, read off the file's own pictures when
    /// nothing above times them.
    @ObservationIgnored private var detectedCredits: Double?
    @ObservationIgnored private var creditsDetector: CreditsDetector?
    @ObservationIgnored private var creditsTask: Task<Void, Never>?
    /// What a scan found per file, nothing included, so a reopen scans nothing.
    private static var creditsFound: [Int64: Double?] = [:]
    @ObservationIgnored private var isEpisode = false
    /// The next episode, or a film's verdict, was offered as the credits
    /// began, and the viewer waved it away: not offered again until they
    /// come back before them.
    @ObservationIgnored private var creditsOffered = false
    @ObservationIgnored private var creditsDismissed = false
    /// The film's verdict was asked over its credits: its end asks nothing
    /// more, and the question outlives a pause.
    @ObservationIgnored private var creditsAsked = false

    @ObservationIgnored private var openTask: Task<Void, Never>?
    @ObservationIgnored private var silenceTask: Task<Void, Never>?
    @ObservationIgnored private var idleTask: Task<Void, Never>?
    @ObservationIgnored private var overlayHideTask: Task<Void, Never>?
    @ObservationIgnored private var fallbackTask: Task<Void, Never>?
    @ObservationIgnored private var reportTask: Task<Void, Never>?
    @ObservationIgnored private var countdownTask: Task<Void, Never>?
    @ObservationIgnored private var endTask: Task<Void, Never>?
    @ObservationIgnored private var nowPlaying: NowPlaying?

    @ObservationIgnored private var holdTask: Task<Void, Never>?
    @ObservationIgnored private var holdTicks = 0
    @ObservationIgnored private var tapSettleTask: Task<Void, Never>?
    @ObservationIgnored private var panSettleTask: Task<Void, Never>?
    @ObservationIgnored private var panIdleTask: Task<Void, Never>?
    @ObservationIgnored private var pan: (from: Double, origin: Double)?

    /// The bridge owns a thumbnail stream: it says when it lets it go.
    @ObservationIgnored private var thumbnailStreamAttached = false
    @ObservationIgnored private var thumbnailOpenTask: Task<Void, Never>?
    @ObservationIgnored private var thumbnailWanted = 0
    /// The second asked of the strip decoder that has not landed yet; asking
    /// it again would decode the same keyframe twice. A seek drops it.
    @ObservationIgnored private var thumbnailInFlight: Int?
    @ObservationIgnored private var thumbnailCache: [Int: UIImage] = [:]
    @ObservationIgnored private var detailAsked = false
    @ObservationIgnored private var chapterWanted: Int?

    /// The languages the finished episode was watched in, for the one file
    /// the countdown hands over to.
    private static var handover: (fileId: Int64, audio: String, subtitle: String)?
    /// Episodes the countdown has started on its own since the last press,
    /// across the files of one sitting.
    private static var unattended = 0
    /// The sleep timer, as `sleepChoices` words it, and when it pauses the
    /// film. A timed one runs on across the episodes the countdown starts;
    /// the end of the film is this film's alone.
    private static var sleepSet: Int?
    private(set) static var sleepDeadline: Date?

    init(playing: Playing) {
        self.playing = playing
        heading = (playing.context, playing.title)
        position = playing.startAt
        positionRef = 0
        if let carried = PlayerModel.handover, carried.fileId == playing.fileId {
            preferredAudio = carried.audio
            preferredSubtitle = carried.subtitle
        }
        PlayerModel.handover = nil
        if PlayerModel.sleepSet == 0 { PlayerModel.sleepSet = nil }
        sleepChoice = PlayerModel.sleepSet
    }

    // MARK: Derived readings

    var waiting: Bool { status == .opening || status == .connecting }

    var line: String {
        switch status {
        case .unauthorized: t("player.unauthorized")
        case .failed, .tooLarge: failure
        default: ""
        }
    }

    func drawn(_ control: PlayerControl) -> Bool {
        switch control {
        case .bar: next == nil
        case .subtitle: next == nil && asking == nil && !subtitleTracks.isEmpty
        case .audio: next == nil && asking == nil && !audioTracks.isEmpty
        }
    }

    /// The round buttons in drawn order, left to right.
    var glyphRow: [PlayerControl] { [.subtitle, .audio].filter(drawn) }

    /// The pills under the bar, in drawn order.
    var tabs: [PlayerTab] { chapters.isEmpty ? [.info, .picture, .stats] : [.info, .chapters, .picture, .stats] }

    var holder: PlayerControl? {
        guard overlayDrawn, let control = focusedControl, drawn(control) else { return nil }
        return control
    }

    /// How far above the bottom of the screen the subtitles stand, so no
    /// state of the overlay covers a line.
    var subtitleLift: CGFloat {
        let screen = Theme.Layout.screenHeight, player = Theme.Player.self
        switch overlay {
        case .hidden: return 0
        case .barOnly: return screen - player.barTop + Theme.Space.s24
        case .scrubbing: return screen - player.barTop + player.thumbnailGap + player.thumbnail.height + Theme.Space.s24
        case .full, .menu: return screen - player.contextTop + Theme.Space.s24
        case .tab: return screen - player.contextTop + player.tabShift + Theme.Space.s24
        }
    }

    /// The chapter the film is in.
    var currentChapter: Int? { chapters.lastIndex { $0.start <= position } }

    private var scrubbable: Bool {
        switch overlay {
        case .tab, .menu: return false
        default:
            return next == nil && asking == nil && !(holder != nil && holder != .bar) && durationRef > 0
                && !status.terminal
        }
    }

    private var overlayHeld: Bool {
        switch overlay {
        case .tab, .menu, .scrubbing: return true
        default: return status != .playing || next != nil || asking != nil || scrub != nil || scrubCard
        }
    }

    var selectedAudio: MediaTrack? { audioTracks.first { $0.selected } }

    // MARK: Lifecycle

    func start() {
        let host = PlayerHostView(frame: CGRect(origin: .zero, size: CGSize(
            width: Theme.Layout.screenWidth, height: Theme.Layout.screenHeight)))
        self.host = host
        host.bridge.setSubtitleLift(points: subtitleLift)
        audioDelayKey = "audio.delay.v1." + (AVAudioSession.sharedInstance().currentRoute.outputs.first?.portName ?? "")
        audioDelayMs = Prefs.string(audioDelayKey).flatMap { Int($0) } ?? 0
        if audioDelayMs != 0 { host.bridge.setAudioDelay(seconds: Double(audioDelayMs) / 1000) }
        armSleep()
        let nowPlaying = NowPlaying(model: self)
        nowPlaying.attach()
        self.nowPlaying = nowPlaying
        let bridge = host.bridge!
        bridge.onStatus = { [weak self] status, detail, width, height, codec, buffered in
            MainActor.assumeIsolated {
                self?.statusChanged(status, detail: detail, width: width, height: height, codec: codec, buffered: buffered)
            }
        }
        bridge.onStats = { [weak self] playback, tick in
            MainActor.assumeIsolated { self?.statsTick(playback, tick) }
        }
        bridge.onFirstFrame = { [weak self] _ in
            MainActor.assumeIsolated { self?.firstFrame() }
        }
        bridge.onTracks = { [weak self] audio, subtitle, chapters in
            MainActor.assumeIsolated { self?.tracksChanged(audio: audio, subtitle: subtitle, chapters: chapters) }
        }
        bridge.onThumbnails = { [weak self] second, image in
            MainActor.assumeIsolated { self?.thumbnailArrived(second, image) }
        }
        bridge.onThumbnailStreamClosed = { [weak self] in
            MainActor.assumeIsolated {
                self?.thumbnailStreamAttached = false
                self?.thumbnailInFlight = nil
            }
        }

        #if DEBUG
        // LexisShots measures the player on a file the simulator holds: its
        // library is empty, so the core has nothing to open.
        let arguments = ProcessInfo.processInfo.arguments
        if let at = arguments.firstIndex(of: "-lexis-play-local"), at + 1 < arguments.count {
            // a relative path is the app's own caches, where a device copy lands
            let given = arguments[at + 1]
            let path = given.hasPrefix("/") ? given
                : FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent(given).path
            bridge.openLocalFile(path: path, title: playing.title)
            if playing.startAt > 0 { bridge.seek(seconds: playing.startAt) }
            armIdle()
            return
        }
        #endif

        // Settled off the main thread while the core opens the stream; the
        // bridge's open waits for it.
        bridge.activateAudioSession()
        loadEpisode()
        CoreClient.calls.async { CoreClient.shared.pauseScan(value: true) }
        status = .connecting
        openedAt = Date()
        let fileId = self.fileId, title = playing.title, startAt = playing.startAt
        // The core's open cannot be interrupted: a task cancelled by leave()
        // still gets the handle, and closes it since the screen is gone.
        openTask = Task { [weak self] in
            do {
                let handle = try await CoreClient.shared.openStream(fileId: fileId)
                guard let self, self.accept(handle, title: title, startAt: startAt) else {
                    let stream = coreStream(handle: OpaquePointer(bitPattern: UInt(handle))!)
                    stream.close(stream.handle)
                    return
                }
            } catch {
                self?.openFailed(error)
            }
        }
        reportTask = Task { @MainActor [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(PlayerModel.reportIntervalSeconds))
                guard !Task.isCancelled, let self else { return }
                report(status == .playing ? .playing : .paused)
            }
        }
        armIdle()
    }

    /// Hands the stream to the bridge; false when the screen has gone and
    /// the caller must close the stream itself.
    private func accept(_ handle: UInt64, title: String, startAt: Double) -> Bool {
        guard !left, let bridge = host?.bridge else { return false }
        bridge.open(handle: handle, title: title)
        // The bridge runs its commands in order and its open ends in play():
        // queued here, the seek lands before the first packet is fed.
        if startAt > 0 { bridge.seek(seconds: startAt) }
        silenceTask = after(milliseconds: PlayerModel.silenceTimeoutMs) { [weak self] in
            guard let self else { return }
            status = .failed
            failure = t("player.noAnswer")
            showOverlay()
        }
        return true
    }

    private func openFailed(_ error: Error) {
        guard !left else { return }
        status = .failed
        failure = t("player.failed")
        failureDetail = Format.describe(error)
        showOverlay()
    }

    func leave() {
        left = true
        openTask?.cancel()
        thumbnailOpenTask?.cancel()
        creditsDetector?.cancel()
        for task in [creditsTask, silenceTask, idleTask, overlayHideTask, fallbackTask, reportTask, countdownTask, endTask,
            holdTask, tapSettleTask, panSettleTask, panIdleTask, sleepTask] { task?.cancel() }
        thumbnailCache.removeAll()
        report(.stopped)
        nowPlaying?.detach()
        nowPlaying = nil
        // An auto-advance keeps the display's mode for the next file.
        host?.bridge.close(keepDisplay: advanceTo != nil)
        CoreClient.calls.async { CoreClient.shared.pauseScan(value: false) }
    }

    /// A file that never played reports nothing: a zero would erase the
    /// resume point it should have started from. A refused writeback is
    /// swallowed; the position is in the index either way.
    private func report(_ state: PlaybackState) {
        let fileId = self.fileId, position = positionRef, duration = durationRef
        guard position > 0 else { return }
        CoreClient.calls.async {
            _ = try? CoreClient.shared.reportPlayback(
                fileId: fileId, positionSecs: position, durationSecs: duration, state: state)
        }
    }

    // MARK: Bridge events

    private func statusChanged(_ raw: String, detail: String, width: Int32, height: Int32, codec: String, buffered: Double) {
        silenceTask?.cancel()
        guard let now = PlayerStatus(rawValue: raw) else { return }
        status = now
        if holdTask == nil { indicator = nil }
        if width > 0 { picture = Picture(width: width, height: height, codec: codec) }
        switch now {
        case .failed:
            failure = t("player.failed")
            failureDetail = detail
            NSLog("[lexis.player] failed: %@", detail)
        case .tooLarge: failure = t("player.tooLarge")
        case .buffering: bufferedSeconds = buffered
        default: break
        }
        creditsDetector?.setSuspended(now == .buffering)
        ended = now == .ended ? fileId : nil
        endedChanged()
        if now != .playing { showOverlay() }
        armIdle()
        nowPlaying?.publish(playing: now == .playing, position: positionRef, duration: durationRef)
    }

    private func statsTick(_ playback: PlaybackStats, _ tick: PlayerStats) {
        positionRef = playback.position
        if let replay, positionRef >= replay.until {
            self.replay = nil
            host?.bridge.selectSubtitleTrack(index: replay.restore)
        }
        if playback.duration != durationRef {
            durationRef = playback.duration
            mergedMarks = nil
            nowPlaying?.publish(playing: status == .playing, position: positionRef, duration: durationRef)
        }
        checkMarks()
        guard overlayDrawn else { return }
        // Every write invalidates whatever reads it, equal or not: only what
        // moved is written, and the whole reading only for the tab drawing it.
        position = playback.position
        if duration != playback.duration { duration = playback.duration }
        if bufferedSeconds != tick.bufferedSeconds { bufferedSeconds = tick.bufferedSeconds }
        if stats == nil || stats?.dynamicRange != tick.dynamicRange || (overlay == .tab(.stats) && stats != tick) {
            stats = tick
        }
        var reading = PlaybackReading()
        reading.packetsRead = UInt64(max(0, playback.packetsRead))
        reading.framesDisplayed = UInt64(max(0, playback.framesDisplayed))
        reading.framesDropped = UInt64(max(0, playback.framesDropped))
        reading.decodeFailures = UInt64(max(0, playback.decodeFailures))
        reading.decodeMillisecondsMean = playback.decodeMillisecondsMean
        reading.decodeMillisecondsWorst = playback.decodeMillisecondsWorst
        reading.decodeSampleCount = UInt64(max(0, playback.decodeSampleCount))
        reading.videoPassthrough = tick.videoPassthrough
        reading.hardwareAccelerated = playback.hardwareAccelerated
        reading.hardwareAccelerationKnown = playback.hardwareAccelerationKnown
        reading.fileOpen = tick.fileOpen
        reading.dynamicRange = tick.dynamicRange
        reading.displayRefreshRate = tick.displayRefreshRate
        reading.displayModeNegotiated = tick.displayModeNegotiated
        reading.displayCriteriaMatchingEnabled = tick.displayCriteriaMatchingEnabled
        reading.rendererFramesDisplayed = UInt64(tick.rendererFramesDisplayed)
        reading.rendererFramesDropped = UInt64(tick.rendererFramesDropped)
        reading.audioFormat = tick.audioFormat
        reading.audioPassthrough = tick.audioPassthrough
        reading.audioChannels = tick.audioChannels
        reading.audioRouteLimited = tick.audioRouteLimited
        reading.audioRendering = tick.audioRendering
        reading.audioFallbackReason = playback.audioFallbackReason
        reading.ioSustainedBitsPerSecond = tick.ioSustainedBitsPerSecond
        reading.ioFetchLatencySeconds = tick.ioFetchLatencySeconds
        PlaybackDiagnostics.shared.last = reading
    }

    private func firstFrame() {
        guard firstFrameSeconds < 0 else { return }
        firstFrameSeconds = Date().timeIntervalSince(openedAt)
        findCredits()
    }

    private func tracksChanged(audio: [NSDictionary], subtitle: [NSDictionary], chapters marks: [NSDictionary]) {
        audioTracks = audio.map(MediaTrack.init)
        subtitleTracks = subtitle.map(MediaTrack.init)
        chapters = marks.map { ChapterMark(start: $0.double("start"), title: $0.string("title")) }
        mergedMarks = nil
        nowPlaying?.publishLanguages(audio: audioTracks, subtitle: subtitleTracks)
        guard !applied, let bridge = host?.bridge else { return }
        // Set before commanding: a selection makes the player answer with a
        // new list right back here.
        applied = true
        let language = I18n.shared.current.rawValue
        let audioMissed = !preferredAudio.isEmpty
            && !audioTracks.contains { $0.spoken == preferredAudio }
        let audio = MediaTrack.bestAudio(audioTracks, language: preferredAudio.isEmpty ? language : preferredAudio)
        if let audio, !audio.selected { bridge.selectAudioTrack(index: audio.index) }
        let subtitleMissed = applySubtitleRule(heard: audio.map { $0.spoken } ?? "")
        audioFallback = audioMissed
        subtitleFallback = subtitleMissed
        fallbackTask?.cancel()
        if audioMissed || subtitleMissed {
            fallbackTask = after(milliseconds: PlayerModel.fallbackNoticeMs) { [weak self] in
                self?.audioFallback = false
                self?.subtitleFallback = false
            }
        }
    }

    /// Shows the track the preference asks for with `heard` as the sound's
    /// language; true when a preferred language has no track. The automatic
    /// choice still shows the forced track of the language heard, the one
    /// alien language a film means to be read; Off shows nothing at all.
    @discardableResult
    private func applySubtitleRule(heard: String) -> Bool {
        let language = I18n.shared.current.rawValue
        let forced = subtitleTracks.first { $0.forced && $0.spoken == (heard.isEmpty ? language : heard) }
        let subtitle: MediaTrack?
        var missed = false
        if preferredSubtitle == "off" {
            subtitle = nil
        } else if !preferredSubtitle.isEmpty {
            subtitle = MediaTrack.bestSubtitle(subtitleTracks, language: preferredSubtitle)
            missed = subtitle == nil
        } else if heard == language || heard.isEmpty {
            // understood, or untagged: only what the film means to be read
            subtitle = forced
        } else {
            subtitle = MediaTrack.bestSubtitle(subtitleTracks, language: language) ?? forced
        }
        replay = nil
        if let subtitle {
            if !subtitle.selected { host?.bridge.selectSubtitleTrack(index: subtitle.index) }
        } else if subtitleTracks.contains(where: \.selected) {
            host?.bridge.selectSubtitleTrack(index: -1)
        }
        return missed
    }

    // MARK: Transport

    func togglePlayback() {
        guard let bridge = host?.bridge else { return }
        // the player refuses a play at the end of the stream: an ended film starts over
        if status == .ended { seek(to: 0) }
        if status == .paused || status == .ended { bridge.play() } else { bridge.pause() }
    }

    func selectAudio(_ track: MediaTrack) {
        preferredAudio = track.spoken
        host?.bridge.selectAudioTrack(index: track.index)
        // what is forced, or wanted at all, depends on the language heard
        if preferredSubtitle.isEmpty { applySubtitleRule(heard: track.spoken) }
    }

    /// Kept per sound output: a sound bar adds its own latency, the TV's
    /// speakers none.
    func setAudioDelay(ms: Int) {
        guard ms != audioDelayMs else { return }
        audioDelayMs = ms
        Prefs.set(audioDelayKey, String(ms))
        host?.bridge.setAudioDelay(seconds: Double(ms) / 1000)
    }

    func setSubtitleOffset(_ seconds: Double) {
        guard seconds != subtitleOffset else { return }
        subtitleOffset = seconds
        host?.bridge.setSubtitleOffset(seconds: seconds)
    }

    /// nil turns the timer off, 0 stops at the end of the film.
    func setSleep(minutes: Int?) {
        sleepChoice = minutes
        PlayerModel.sleepSet = minutes
        PlayerModel.sleepDeadline = minutes.flatMap { $0 > 0 ? Date(timeIntervalSinceNow: Double($0) * 60) : nil }
        armSleep()
        // an end already counting down to the next episode stops there
        if minutes == 0, countdownTask != nil {
            countdownTask?.cancel()
            countdown = 0
        }
    }

    private func armSleep() {
        sleepTask?.cancel()
        guard let deadline = PlayerModel.sleepDeadline else { return }
        sleepTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self else { return }
            PlayerModel.sleepDeadline = nil
            PlayerModel.sleepSet = nil
            sleepChoice = nil
            host?.bridge.pause()
        }
    }

    /// Upscaling, as the video settings store it, switched from the Picture
    /// tab onto the film playing.
    private(set) var upscaling = Prefs.flag(Prefs.upscalingKey, default: true)

    func setUpscaling(_ on: Bool) {
        guard on != upscaling else { return }
        upscaling = on
        Prefs.set(Prefs.upscalingKey, on)
        host?.bridge.applyUpscaling()
    }

    /// Whether the upscaling is done by the network on the Neural Engine,
    /// switched from the Picture tab onto the film playing. On unless refused.
    private(set) var neuralUpscaling = Prefs.flag(Prefs.neuralUpscalingKey, default: true)

    func setNeuralUpscaling(_ on: Bool) {
        guard on != neuralUpscaling else { return }
        neuralUpscaling = on
        Prefs.set(Prefs.neuralUpscalingKey, on)
        host?.bridge.applyUpscaling()
    }

    /// nil is Off.
    func selectSubtitle(_ track: MediaTrack?) {
        preferredSubtitle = track.map { $0.spoken } ?? "off"
        if let track {
            replay = nil
            host?.bridge.selectSubtitleTrack(index: track.index)
        } else {
            applySubtitleRule(heard: selectedAudio?.spoken ?? "")
        }
    }

    /// Subtitles when the sound is in another language than the app's,
    /// forced ones only otherwise.
    func selectSubtitlesAuto() {
        preferredSubtitle = ""
        applySubtitleRule(heard: selectedAudio?.spoken ?? "")
    }

    /// A skip back with no dialogue on screen replays the stretch with it, as
    /// the native player does, until the film is back where the skip left.
    /// Never once the viewer has turned subtitles off.
    func replayWithSubtitles(until position: Double) {
        guard replay == nil, preferredSubtitle != "off", !subtitleTracks.contains(where: { $0.selected && !$0.forced }),
            let track = MediaTrack.bestSubtitle(subtitleTracks, language: I18n.shared.current.rawValue)
                ?? subtitleTracks.first(where: { !$0.forced })
        else { return }
        replay = (position, subtitleTracks.first(where: \.selected)?.index ?? -1)
        host?.bridge.selectSubtitleTrack(index: track.index)
    }

    /// One level at a time, innermost first; false when nothing is left to
    /// close and the screen itself should go. Never a wake of its own.
    func menu() -> Bool {
        // the next episode offered over the credits: the credits go on
        if next != nil, ended == nil {
            cancelAdvance()
            return true
        }
        // the film's question over its credits: the credits go on
        if asking != nil, ended == nil {
            creditsDismissed = true
            asking = nil
            armIdle()
            return true
        }
        switch overlay {
        case .menu(.subtitleLanguage), .menu(.subtitleOffset): overlay = .menu(.subtitles)
        case .menu(.audioDelay): overlay = .menu(.audio)
        case .menu, .tab: overlay = .full
        case .scrubbing: cancelScrub()
        case .full, .barOnly: hideOverlay()
        case .hidden: return false
        }
        armIdle()
        return true
    }

    /// Down from the bar, or sideways along the pills: the tab's content
    /// comes up under them.
    func openTab(_ tab: PlayerTab) {
        if scrub != nil { cancelScrub() }
        overlay = .tab(tab)
        switch tab {
        case .info: loadDetail()
        case .chapters: requestNextChapterFrame()
        case .picture, .stats: break
        }
        armIdle()
    }

    func openMenu(_ menu: PlayerMenu) {
        if scrub != nil { cancelScrub() }
        overlay = .menu(menu)
        armIdle()
    }

    /// Back to the bar from a tab or a popover.
    func closeLayer() {
        overlay = .full
        armIdle()
    }

    /// The remote moved: landing on a control is leaving whatever tab or
    /// popover was open.
    func focusChanged(_ focus: PlayerFocus?) {
        if case .control(let control) = focus {
            focusedControl = control
            switch overlay {
            case .tab, .menu: overlay = .full
            default: break
            }
        } else {
            focusedControl = nil
        }
        armIdle()
    }

    // MARK: Overlay

    private var reduceMotion: Bool { UIAccessibility.isReduceMotionEnabled }

    /// Any press but Menu and the sideways ones: the full overlay comes up,
    /// and a countdown already running restarts in place.
    func wake() {
        PlayerModel.unattended = 0
        showOverlay()
        armIdle()
    }

    /// The full overlay, unless a deeper state is already drawn.
    private func showOverlay() {
        if overlay == .hidden || overlay == .barOnly { present(.full) }
    }

    /// Draws `state`, fading the overlay in if it was away or going.
    private func present(_ state: OverlayState) {
        overlay = state
        overlayHideTask?.cancel()
        guard !overlayDrawn || overlayOpacity < 1 else { return }
        if !overlayDrawn {
            // the ticks stop writing these while the overlay is away
            position = positionRef
            duration = durationRef
        }
        overlayDrawn = true
        if reduceMotion {
            overlayOpacity = 1
        } else {
            withAnimation(.easeOut(duration: Theme.Motion.overlayIn)) { overlayOpacity = 1 }
        }
    }

    private func hideOverlay() {
        overlay = .hidden
        indicator = nil
        idleTask?.cancel()
        if reduceMotion {
            overlayOpacity = 0
            overlayDrawn = false
            return
        }
        withAnimation(.easeOut(duration: Theme.Motion.overlayOut)) { overlayOpacity = 0 }
        overlayHideTask = after(milliseconds: Int(Theme.Motion.overlayOut * 1000)) { [weak self] in
            self?.overlayDrawn = false
        }
    }

    private func armIdle() {
        idleTask?.cancel()
        guard overlay != .hidden, !overlayHeld else { return }
        idleTask = after(milliseconds: PlayerModel.overlayIdleMs) { [weak self] in self?.hideOverlay() }
    }

    // MARK: Scrub

    /// The target moves; only a scrub drawn with its card asks for the frame.
    private func moveScrub(_ target: Double) {
        let at = min(max(target, 0), durationRef)
        scrub = at
        if overlay == .scrubbing {
            scrubCard = true
            requestThumbnail(Int(at.rounded()))
        }
        armIdle()
    }

    /// One gesture costs exactly one seek.
    private func commitScrub() {
        guard let target = scrub else { return }
        scrub = nil
        scrubCard = false
        scrubFrame = nil
        if overlay == .scrubbing { overlay = .full }
        seek(to: target)
        armIdle()
    }

    /// Menu during a scrub: nothing was sought, so the film is where it was.
    private func cancelScrub() {
        for task in [tapSettleTask, panSettleTask, panIdleTask] { task?.cancel() }
        tapSettleTask = nil
        pan = nil
        scrub = nil
        scrubCard = false
        scrubFrame = nil
        overlay = .full
    }

    /// Every seek lands here, the remote's and the system's; the bar stands
    /// on the target at once, before the player gets there.
    func seek(to target: Double) {
        let at = min(max(target, 0), durationRef)
        positionRef = at
        position = at
        thumbnailInFlight = nil
        host?.bridge.seek(seconds: at)
        nowPlaying?.publish(playing: status == .playing, position: at, duration: durationRef)
    }

    /// The clickpad pressed on the bar: lands a scrub, or plays and pauses.
    func select() {
        if scrub != nil { commitScrub() } else { togglePlayback() }
    }

    /// The remote's play/pause: a scrub is landed and the film plays from there.
    func playPause() {
        guard scrub != nil else { return togglePlayback() }
        commitScrub()
        if status != .playing { host?.bridge.play() }
    }

    /// One press of left or right. Playing, it is a ten-second skip and a
    /// run of presses lands as one seek; paused, it moves the scrub and the
    /// clickpad lands it.
    func tap(back: Bool) {
        PlayerModel.unattended = 0
        guard scrubbable, holdTask == nil, pan == nil else { return }
        let step = back ? -PlayerModel.seekStep : PlayerModel.seekStep
        guard status == .playing else {
            present(.scrubbing)
            moveScrub((scrub ?? positionRef) + step)
            return
        }
        guard scrub == nil || tapSettleTask != nil else { return }
        if overlay == .hidden { present(.barOnly) }
        if back, scrub == nil { replayWithSubtitles(until: positionRef) }
        indicator = back ? .skipBack : .skipForward
        moveScrub((scrub ?? positionRef) + step)
        tapSettleTask?.cancel()
        tapSettleTask = after(milliseconds: PlayerModel.seekTapSettleMs) { [weak self] in
            guard let self else { return }
            tapSettleTask = nil
            if holdTask == nil, pan == nil { commitScrub() }
        }
    }

    /// The hold ladder: a tick at once, then every 250 ms, climbing a rung
    /// every eight ticks, drawn as the native scan's speed. The release
    /// ends it whatever the film has become.
    func hold(back: Bool, began: Bool) {
        if began {
            guard scrubbable, holdTask == nil else { return }
            holdTicks = 0
            tapSettleTask?.cancel()
            tapSettleTask = nil
            if overlay == .hidden { present(.barOnly) }
            holdTask = Task { @MainActor [weak self] in
                while let self, !Task.isCancelled {
                    let rung = min(holdTicks / PlayerModel.holdTicksPerStep, PlayerModel.holdSteps.count - 1)
                    holdTicks += 1
                    let step = PlayerModel.holdSteps[rung]
                    indicator = back ? .scanBack(rung + 2) : .scanForward(rung + 2)
                    moveScrub((scrub ?? positionRef) + (back ? -step : step))
                    try? await Task.sleep(for: .milliseconds(PlayerModel.holdTickMs))
                }
            }
        } else if let running = holdTask {
            running.cancel()
            holdTask = nil
            indicator = nil
            commitScrub()
        }
    }

    /// A stroke on the touch surface, as a translation in points. A swipe is
    /// several strokes; the seek waits for the settle after the last one.
    func pan(_ phase: PanPhase, x: Double) {
        guard scrubbable else { return }
        switch phase {
        case .ended:
            panIdleTask?.cancel()
            pan = nil
            if scrub != nil, status == .playing {
                panSettleTask?.cancel()
                panSettleTask = after(milliseconds: PlayerModel.panSettleMs) { [weak self] in self?.commitScrub() }
            }
        case .began:
            pan = nil
        case .changed:
            if pan == nil {
                guard abs(x) >= PlayerModel.panDeadbandPoints else { return }
                pan = (from: scrub ?? positionRef, origin: x)
                panIdleTask?.cancel()
                panSettleTask?.cancel()
                present(.scrubbing)
            }
            let engaged = pan!
            let span = max(PlayerModel.panSpanMin, durationRef / PlayerModel.panSpanShare)
            moveScrub(engaged.from + (x - engaged.origin) / PlayerModel.panSurfacePoints * span)
            panIdleTask?.cancel()
            panIdleTask = after(milliseconds: PlayerModel.panIdleMs) { [weak self] in
                guard let self else { return }
                pan = nil
                if status == .playing { commitScrub() }
            }
        }
    }

    // MARK: Tabs

    private func loadDetail() {
        guard !detailAsked, let titleId else { return }
        detailAsked = true
        Task { @MainActor [weak self] in
            let detail = await CoreClient.run { try? CoreClient.shared.titleDetail(titleId: titleId) }
            self?.detail = detail
        }
    }

    /// Info's "From Beginning": the film starts over, and plays.
    func playFromStart() {
        seek(to: 0)
        if status == .paused || status == .ended { host?.bridge.play() }
        closeLayer()
    }

    func playChapter(_ index: Int) {
        seek(to: chapters[index].start)
        closeLayer()
    }

    /// "On" in the subtitles popover: the full track in use, else the app
    /// language's, else the first.
    func turnSubtitlesOn() {
        let track = subtitleTracks.first { $0.selected && !$0.forced }
            ?? MediaTrack.bestSubtitle(subtitleTracks, language: I18n.shared.current.rawValue)
            ?? subtitleTracks.first { !$0.forced } ?? subtitleTracks.first
        if let track { selectSubtitle(track) }
    }

    // MARK: Thumbnails

    /// A second stream, opened lazily the first time a scrub asks for a
    /// picture; while the open is in flight only the wanted second moves.
    /// Every step asks: the strip decoder serves only the newest request.
    private func requestThumbnail(_ second: Int) {
        thumbnailWanted = second
        if let image = thumbnailCache[second] {
            showThumbnail(second, image)
            return
        }
        if thumbnailStreamAttached {
            guard thumbnailInFlight != second else { return }
            thumbnailInFlight = second
            host?.bridge.requestThumbnails(seconds: [Double(second)])
            return
        }
        guard thumbnailOpenTask == nil else { return }
        let fileId = self.fileId
        thumbnailOpenTask = Task { [weak self] in
            do {
                let handle = try await CoreClient.shared.openStream(fileId: fileId)
                guard let self, self.thumbnailStreamReady(handle) else {
                    let stream = coreStream(handle: OpaquePointer(bitPattern: UInt(handle))!)
                    stream.close(stream.handle)
                    return
                }
            } catch {
                self?.thumbnailStreamFailed()
            }
        }
    }

    private func thumbnailStreamReady(_ handle: UInt64) -> Bool {
        guard !left, let bridge = host?.bridge else { return false }
        thumbnailOpenTask = nil
        thumbnailStreamAttached = true
        thumbnailInFlight = thumbnailWanted
        bridge.attachThumbnailStream(handle: handle)
        bridge.requestThumbnails(seconds: [Double(thumbnailWanted)])
        return true
    }

    private func thumbnailStreamFailed() {
        thumbnailOpenTask = nil
    }

    /// Cached, then handed to the chapter card that asked for it, or shown
    /// unless the scrub card already holds the frame the scrub is on: a
    /// frame from a step behind beats no frame while the hand moves. The
    /// cache is a window of frames, not a film: full, it starts over.
    private func thumbnailArrived(_ at: Double, _ image: UIImage) {
        let second = Int(at.rounded())
        if thumbnailInFlight == second { thumbnailInFlight = nil }
        if thumbnailCache.count >= PlayerModel.thumbnailImageLimit { thumbnailCache.removeAll(keepingCapacity: true) }
        thumbnailCache[second] = image
        if let wanted = chapterWanted, wanted < chapters.count, Int(chapters[wanted].start.rounded()) == second {
            chapterFrames[wanted] = image
            requestNextChapterFrame()
        }
        // A reply landing after the viewer let go must not bring a picture back.
        guard scrubCard, scrubFrame?.second != thumbnailWanted else { return }
        showThumbnail(second, image)
    }

    private func showThumbnail(_ second: Int, _ image: UIImage) {
        guard scrubFrame?.second != second else { return }
        scrubFrame = ScrubFrame(second: second, image: image)
    }

    /// The next chapter card without a picture asks for one; the strip
    /// decoder serves only the newest request, so the cards fill in turn.
    private func requestNextChapterFrame() {
        guard overlay == .tab(.chapters), let index = chapters.indices.first(where: { chapterFrames[$0] == nil }) else {
            chapterWanted = nil
            return
        }
        let second = Int(chapters[index].start.rounded())
        if let image = thumbnailCache[second] {
            chapterFrames[index] = image
            requestNextChapterFrame()
            return
        }
        chapterWanted = index
        requestThumbnail(second)
    }

    // MARK: End of a file

    private func endedChanged() {
        guard ended == fileId else {
            // Playing again: what the end offered goes. What the credits
            // offered stays, and its countdown runs on.
            if !creditsOffered {
                endTask?.cancel()
                countdownTask?.cancel()
                next = nil
                countdown = 0
            }
            if !creditsAsked { asking = nil }
            return
        }
        // the credits already offered it
        guard next == nil, !creditsAsked else { return }
        endTask?.cancel()
        countdownTask?.cancel()
        let fileId = self.fileId, titleId = self.titleId
        endTask = Task { @MainActor [weak self] in
            let core = CoreClient.shared
            let episode = await CoreClient.run { try? core.nextEpisode(fileId: fileId) }
            guard let self, !Task.isCancelled else { return }
            if let episode {
                next = episode
                countdown = PlayerModel.advanceSeconds
                armIdle()
                runCountdown()
                return
            }
            guard let titleId else { return }
            // An index error asks nothing; the credits roll.
            let detail = await CoreClient.run { try? core.titleDetail(titleId: titleId) }
            guard !Task.isCancelled, let detail else { return }
            if detail.verdict == nil {
                asking = .verdict
            } else {
                await askAfter(titleId)
            }
        }
    }

    private func runCountdown() {
        guard PlayerModel.unattended < PlayerModel.unattendedLimit, sleepChoice != 0 else {
            countdown = 0
            return
        }
        countdownTask = Task { @MainActor [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, let next else { return }
                // a pause over the credits holds the count
                if status == .paused { continue }
                countdown -= 1
                if countdown <= 0 {
                    PlayerModel.unattended += 1
                    PlayerModel.handover = (next.fileId, preferredAudio, preferredSubtitle)
                    advanceTo = next
                    return
                }
            }
        }
    }

    func advanceNow() {
        guard let next else { return }
        countdownTask?.cancel()
        countdown = 0
        PlayerModel.handover = (next.fileId, preferredAudio, preferredSubtitle)
        advanceTo = next
    }

    /// The film stays where it stopped, or its credits go on; the screen is
    /// handed back.
    func cancelAdvance() {
        if creditsOffered { creditsDismissed = true }
        withdrawNext()
        ended = nil
        endedChanged()
        armIdle()
    }

    /// The intro or the recap under the button, passed.
    func skipStretch() {
        guard let skipping else { return }
        seek(to: skipping.endSecs)
        self.skipping = nil
    }

    // MARK: Intro, recap, credits

    /// The episode this file is, for the heading, and its marks: both from
    /// the core, the marks off the network the first time.
    private func loadEpisode() {
        let fileId = self.fileId, titleId = self.titleId
        Task { @MainActor [weak self] in
            let core = CoreClient.shared
            let found = await CoreClient.run {
                (
                    titleId.flatMap { try? core.episodes(titleId: $0) }?.first { $0.fileId == fileId },
                    (try? core.skipMarks(fileId: fileId)) ?? []
                )
            }
            guard let self else { return }
            if let episode = found.0 {
                isEpisode = true
                heading = (UpNextCard.context(episode), UpNextCard.label(episode))
            }
            marks = found.1
            mergedMarks = nil
        }
    }

    /// The file's own chapters, where their names say what they are: what a
    /// stretch TheIntroDB has not timed falls back on.
    private var chapterMarks: [SkipMark] {
        chapters.indices.compactMap { index in
            let words = Set(
                chapters[index].title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                    .split { !$0.isLetter }.map(String.init))
            let kind: SkipKind? =
                !words.isDisjoint(with: ["recap", "previously", "precedemment"]) ? .recap
                : !words.isDisjoint(with: ["intro", "opening", "op", "debut", "ouverture"]) ? .intro
                : !words.isDisjoint(with: ["credits", "credit", "ending", "outro", "ed", "generique", "fin"]) ? .credits
                : nil
            guard let kind else { return nil }
            let start = chapters[index].start
            let end = index + 1 < chapters.count ? chapters[index + 1].start : durationRef
            // An intro or a recap opens the file and is short, and the credits
            // close it: a chapter named the same elsewhere is the story's own,
            // as "L'Ouverture" of the Games an hour into the film.
            if kind == .credits {
                guard start >= durationRef * 0.5 else { return nil }
            } else {
                guard start < min(600, durationRef * 0.25), end - start <= 300 else { return nil }
            }
            return SkipMark(kind: kind, startSecs: start, endSecs: end)
        }
    }

    /// Every tick: the button over an intro or a recap, and the next episode
    /// or the film's verdict offered as the credits begin - where TheIntroDB,
    /// the server or a chapter says, else where the pictures show them, else
    /// in the last forty seconds, or the last twentieth of a short file.
    private func checkMarks() {
        let position = positionRef
        let all: [SkipMark]
        if let mergedMarks {
            all = mergedMarks
        } else {
            let timed = Set(marks.map(\.kind))
            all = marks + chapterMarks.filter { !timed.contains($0.kind) }
            mergedMarks = all
        }
        let stretch = all.first {
            ($0.kind == .intro || $0.kind == .recap) && position >= $0.startSecs && position < $0.endSecs - 1
        }
        if stretch != skipping { skipping = stretch }
        guard ended == nil, durationRef > 0, isEpisode || playing.landOn?.kind == .movie else { return }
        let creditsAt =
            all.first { $0.kind == .credits }?.startSecs ?? detectedCredits ?? durationRef - min(40, durationRef * 0.05)
        if position >= creditsAt {
            if !creditsDismissed, !creditsOffered, next == nil {
                if isEpisode { offerNext() } else { askVerdict() }
            }
        } else if position < creditsAt - 5 {
            creditsDismissed = false
            if creditsOffered { withdrawNext() }
            if creditsAsked {
                creditsAsked = false
                asking = nil
            }
        }
    }

    /// The credits of a file nothing times, read off its last pictures on a
    /// stream of its own. It starts once the film has filled its buffer, since
    /// its reads share the link: a few dozen keyframes, never the whole end.
    private func findCredits() {
        let fileId = self.fileId
        if let known = PlayerModel.creditsFound[fileId] {
            detectedCredits = known
            return
        }
        creditsTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard let self, !Task.isCancelled, durationRef > 120, isEpisode || playing.landOn?.kind == .movie,
                !(marks + chapterMarks).contains(where: { $0.kind == .credits }),
                let handle = try? await CoreClient.shared.openStream(fileId: fileId)
            else { return }
            let stream = coreStream(handle: OpaquePointer(bitPattern: UInt(handle))!)
            guard !left else { return stream.close(stream.handle) }
            // a failed build has closed the stream, and a detector let go closes it
            guard let detector = await CoreClient.run(on: CoreClient.slow, {
                try? CreditsDetector(stream: stream, analysis: stream.cachedAnalysis())
            }), !left else { return }
            creditsDetector = detector
            let duration = durationRef
            // a film's roll runs minutes, an episode's rarely more than one
            let span = isEpisode ? min(duration * 0.2, 360) : min(duration * 0.25, 900)
            let start = await detector.start(within: (duration - span)...(duration - 1))
            creditsDetector = nil
            guard !Task.isCancelled, !left else { return }
            PlayerModel.creditsFound.updateValue(start, forKey: fileId)
            detectedCredits = start
        }
    }

    /// A film nobody has judged yet is asked about as its credits begin,
    /// while the viewer is still there to answer.
    private func askVerdict() {
        creditsOffered = true
        guard let titleId else { return }
        endTask?.cancel()
        endTask = Task { @MainActor [weak self] in
            let detail = await CoreClient.run { try? CoreClient.shared.titleDetail(titleId: titleId) }
            guard let self, !Task.isCancelled, creditsOffered, asking == nil, let detail, detail.verdict == nil else {
                return
            }
            creditsAsked = true
            asking = .verdict
            wake()
        }
    }

    private func offerNext() {
        creditsOffered = true
        let fileId = self.fileId
        endTask?.cancel()
        endTask = Task { @MainActor [weak self] in
            let episode = await CoreClient.run { try? CoreClient.shared.nextEpisode(fileId: fileId) }
            guard let self, !Task.isCancelled, creditsOffered, let episode else { return }
            next = episode
            countdown = PlayerModel.advanceSeconds
            runCountdown()
        }
    }

    private func withdrawNext() {
        endTask?.cancel()
        countdownTask?.cancel()
        creditsOffered = false
        next = nil
        countdown = 0
    }

    func answerVerdict(_ verdict: ApiVerdict) {
        guard let titleId else { return }
        Task { @MainActor [weak self] in
            let landed = await CoreClient.run { (try? CoreClient.shared.setVerdict(titleId: titleId, verdict: verdict)) != nil }
            guard let self else { return }
            if landed { await askAfter(titleId) } else { asking = nil }
        }
    }

    private func askAfter(_ titleId: Int64) async {
        let proposal = await CoreClient.run { try? CoreClient.shared.afterThis(titleId: titleId) }
        guard !left else { return }
        asking = proposal.map { .after($0) }
    }

    func acceptProposal() {
        guard case .after(let proposal) = asking else { return }
        let id = proposal.id
        CoreClient.calls.async { _ = try? CoreClient.shared.queueTonight(titleId: id) }
        asking = nil
    }

    func declineProposal() {
        asking = nil
    }
}

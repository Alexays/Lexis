import AVFoundation
import AVKit
import Foundation
import LexisCoreStream
import LexisPlayer
import QuartzCore

/// The app's one link between the SwiftUI screens and the player. Everything
/// that can block runs on `queue`: opening probes the container through the
/// stream, which is network I/O for a Plex source, and stopping waits for the
/// reader. The main thread must never wait for either.
@objc(LexisPlayerBridge)
public final class LexisPlayerBridge: NSObject {
    /// status, detail, width, height, codec, bufferedSeconds. The last is
    /// only ever filled in for status "buffering", 0 otherwise. Called on
    /// the main queue.
    @objc public var onStatus: ((String, String, Int32, Int32, String, Double) -> Void)?
    /// The engine's reading and the panel's, once a tick. Called on the main
    /// queue.
    var onStats: ((PlaybackStats, PlayerStats) -> Void)?
    /// Once, the instant the first frame after an open or a seek reaches
    /// the sink. Carries that frame's own presentation time. Called on the
    /// main queue.
    @objc public var onFirstFrame: ((Double) -> Void)?
    /// The audio and the subtitle tracks, each one index, codec, language,
    /// title, graphic and selected, and the container's own chapter marks,
    /// each one start and title. Called on the main queue.
    @objc public var onTracks: (([NSDictionary], [NSDictionary], [NSDictionary]) -> Void)?
    /// One thumbnail the strip decoder landed, with the second it was asked
    /// for, already decoded for display. Called on the main queue.
    public var onThumbnails: ((Double, UIImage) -> Void)?
    /// The strip decoder was let go, and the stream it owned closed with it:
    /// the next scrub hands over a new one. Called on the main queue.
    public var onThumbnailStreamClosed: (() -> Void)?

    private let player: LexisPlayer
    private let sink: DisplayLayerSink
    /// Task 7.1's own parallel decode path for scrub thumbnails, built from
    /// the stream `attachThumbnailStream` hands over. Touched only from `queue`.
    private var thumbnailDecoder: ThumbnailStripDecoder?
    /// Bumped whenever the strip decoder is let go, so a build still probing
    /// at that moment lands nowhere. Touched only from `queue`.
    private var thumbnailGeneration = 0
    private var thumbnailBuilding = false
    /// The newest seconds asked for while the decoder was still being built.
    private var thumbnailWaiting: [Double]?
    /// Where `AVDisplayCriteria` is asked from: the display manager belongs
    /// to the window, not to the layer, and a CALayer has no path back to
    /// one. Weak: the view outlives the bridge in the recycle pool only
    /// briefly, and nothing here must keep it alive.
    private weak var hostView: UIView?
    /// The settle wait of the write this bridge last made, while it runs.
    /// Main thread only.
    private var displaySwitch: DisplaySwitchWatch?
    /// What the display is currently held in, by whichever bridge put it
    /// there. Process-wide, because the mode outlives one playback: a film
    /// that wants the mode the last one left renegotiates nothing at all,
    /// and a display that rebuilds its picture processing on every
    /// renegotiation - a projector's motion interpolation is the one that
    /// showed this - is asked once a session rather than twice a film.
    /// Main thread only.
    struct HeldMode: Equatable {
        let refreshRate: Float
        let range: VideoDynamicRange
    }

    /// The room light measure writes the display too, and clears this when it does.
    static var heldMode: HeldMode?

    /// Whether this bridge currently holds the display in a film's mode.
    /// Every write to `preferredDisplayCriteria` renegotiates HDMI, and the
    /// terminal paths overlap - an end of stream, then the stop and the
    /// close that follow it - so the display is given back once, by whoever
    /// gets there first. Main thread only.
    private var displayCriteriaHeld = false
    /// Whether the screen actually answered the last request with the film's
    /// cadence, as opposed to merely having been asked. A request the display
    /// never took is the judder a viewer sees with a panel claiming the
    /// opposite, so this is what the panel reads. Main thread only.
    private var displayModeSettled = false
    /// What the renderer had already counted when this film opened, so the
    /// figures reported are this film's: one renderer plays every film this
    /// view shows. Main thread only.
    private var rendererBaseline: (displayed: Int, dropped: Int, delaySeconds: Double, optimized: Int)?
    /// The renderer's latest count, read one tick behind: the load answers
    /// on AVFoundation's own thread. Main thread only.
    private var rendererMetrics: (displayed: Int, dropped: Int, delaySeconds: Double, optimized: Int)?
    /// What the panel last showed for this film, so a seek's own flush - the
    /// renderer counts every sample it throws away as dropped, dozens at a
    /// time - is taken out of the count when the landed frame is up, and the
    /// film's figure carries on from where it stood. Main thread only.
    private var rendererPublished: (displayed: Int, dropped: Int, delaySeconds: Double) = (0, 0, 0)
    /// The last drop count published, so a rise is written down once with
    /// the position it happened at: whether the count climbs at a steady
    /// pace or in bursts is what tells a drifting clock from a late
    /// pipeline, and only a trace over time can say. Main thread only.
    private var rendererDroppedTraced = 0
    /// The clock's last reading, so a tick can say how fast it ran since.
    private var clockTraced: (stream: Double, host: Double)?
    /// The process's CPU seconds at the last tick, for the load the heartbeat
    /// reports.
    private var cpuTraced: (cpu: Double, host: Double)?

    /// User plus system CPU seconds this process has burnt, every thread.
    private static var processCPUSeconds: Double {
        var info = task_thread_times_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_thread_times_info_data_t>.size / MemoryLayout<natural_t>.size)
        let live = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_THREAD_TIMES_INFO), $0, &count)
            }
        }
        var basic = task_basic_info_data_t()
        var basicCount = mach_msg_type_number_t(
            MemoryLayout<task_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
        let past = withUnsafeMutablePointer(to: &basic) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(basicCount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_BASIC_INFO), $0, &basicCount)
            }
        }
        guard live == KERN_SUCCESS, past == KERN_SUCCESS else { return 0 }
        func seconds(_ t: time_value_t) -> Double { Double(t.seconds) + Double(t.microseconds) / 1e6 }
        return seconds(info.user_time) + seconds(info.system_time)
            + seconds(basic.user_time) + seconds(basic.system_time)
    }
    /// Where the clock stood when the drop count last rose. Main thread only.
    private var rendererLastDropSeconds = 0.0
    /// Ticks since the open, for the heartbeat line. Main thread only.
    private var heartbeatTicks = 0
    /// The cadence the screen was measured running at once it took the
    /// film's mode, read off the display link that watched the switch.
    /// Process-wide like `heldMode`, since a film that finds the mode
    /// already held measures nothing of its own. Main thread only.
    static var measuredRefreshHz: Double?
    /// The viewer's own Match Content setting, as the last open read it. False
    /// before any film has opened, which is why only a reader that knows a
    /// file is open may word it.
    private var displayMatchingEnabled = false
    private let queue = DispatchQueue(label: "org.lexis.player.control")
    private var events: Task<Void, Never>?
    private var ticker: Timer?
    /// The only thing in this process that answers a memory warning. Removed
    /// in deinit, so a bridge the recycle pool drops stops listening with it.
    private var memoryWarning: NSObjectProtocol?
    /// Gives the display back when the app leaves the front, since the mode
    /// is otherwise held from one film to the next. Removed in deinit.
    private var background: NSObjectProtocol?
    /// Asks for the film's mode again on the way back, since leaving gave
    /// it back. Removed in deinit.
    private var foreground: NSObjectProtocol?
    /// Pauses the film while another audio session holds the device, and plays
    /// it again when the system says to. Removed in deinit.
    private var interruption: NSObjectProtocol?
    /// Follows what the system renders the sound as. Removed in deinit.
    private var renderingModeChange: NSObjectProtocol?
    /// Main thread only. The one reading tvOS gives of what reaches the
    /// receiver: Dolby as it is, or sound it decoded, in surround or stereo.
    private var renderingMode = AVAudioSession.RenderingMode.notApplicable
    /// Main thread only: whether the last word from the player was playing,
    /// and whether an interruption is what paused it.
    private var reportedPlaying = false
    private var pausedByInterruption = false

    /// Raised on the main thread by stop() and close(), lowered by an open
    /// before it queues itself, read on `queue` by the queued open. A close
    /// that lands while an open is still queued would otherwise be undone by
    /// that open, which lowers the interrupt the close raised and then feeds a
    /// view nobody is looking at for as long as the container takes to probe.
    private let teardown = InterruptFlag()

    /// Main thread only. Bumped by every open, and carried by a stop or a
    /// close so report(_:) can tell whose `.stopped` it is holding: the one a
    /// 35 s stop finally yields belongs to the view that asked for it, not to
    /// whatever is mounted by then.
    private var session: UInt64 = 0
    private var closedSession: UInt64 = 0

    @objc public init(layer: AVSampleBufferDisplayLayer, hostView: UIView) {
        sink = DisplayLayerSink(layer: layer)
        player = LexisPlayer(sink: sink)
        self.hostView = hostView
        super.init()

        // read out of the player before the task, so the task captures a
        // sendable stream rather than the player itself
        let stream = player.events
        events = Task { [weak self] in
            for await event in stream {
                DispatchQueue.main.async { self?.report(event) }
            }
        }
        memoryWarning = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.dropWhatIsOnlyCached()
        }
        #if os(tvOS)
        // The mode is held across films, so something has to give it back
        // when there is no next film: leaving the app is that moment, and
        // the viewer's own interface is not this app's to keep at a film's
        // cadence once it is not on screen.
        //
        // The film pauses too, which is what every player on the platform
        // does behind the home screen and what the viewer expects to find
        // on coming back. Left running, the sound played on over the
        // system's own interface while tvOS took the video decoder away, and
        // the picture came back through a flush mid-stream: a resume that
        // is not a resume, which a display processing the signal (a
        // projector's motion interpolation, measured) does not recover from.
        background = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.clearDisplayCriteria()
            self?.pause()
        }
        interruption = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let info = note.userInfo,
                let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                let type = AVAudioSession.InterruptionType(rawValue: raw)
            else { return }
            switch type {
            case .began:
                // the clock stops with the sound, and the transport must say so
                guard self.reportedPlaying else { return }
                self.pausedByInterruption = true
                self.pause()
            case .ended:
                let options = AVAudioSession.InterruptionOptions(
                    rawValue: info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
                if self.pausedByInterruption, options.contains(.shouldResume) { self.play() }
                self.pausedByInterruption = false
            @unknown default:
                break
            }
        }
        renderingModeChange = NotificationCenter.default.addObserver(
            forName: AVAudioSession.renderingModeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionRenderingModeNewRenderingModeKey] as? Int,
                let mode = AVAudioSession.RenderingMode(rawValue: raw)
            else { return }
            self?.renderingMode = mode
        }
        foreground = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.queue.async {
                guard let self, self.player.isOpen, !self.teardown.isRaised else { return }
                self.applyDisplayCriteria()
            }
        }
        #endif
    }

    deinit {
        if let memoryWarning { NotificationCenter.default.removeObserver(memoryWarning) }
        if let background { NotificationCenter.default.removeObserver(background) }
        if let foreground { NotificationCenter.default.removeObserver(foreground) }
        if let interruption { NotificationCenter.default.removeObserver(interruption) }
        if let renderingModeChange { NotificationCenter.default.removeObserver(renderingModeChange) }
        events?.cancel()
        ticker?.invalidate()
        // belt and braces: a bridge released without a close() would leave the
        // reader running on a stream nothing will ever read again
        player.cancel()
        thumbnailDecoder?.cancel()
    }

    /// Main thread only: a Timer needs a run loop to be scheduled on. Started
    /// only by open(), not by init(): before anything is open there is
    /// nothing to report, and a tick that ran anyway would publish Now
    /// Playing for a title that is still empty and a position that is still
    /// zero, which is Now Playing lying about a film that never opened.
    /// Called again on every open, because an invalidated Timer never fires
    /// again and stop() is what invalidates it.

    /// The stored passthrough refusal, as the settings pane wrote it: base64
    /// of "0" under one key. Read at every open, so a toggle takes effect at
    /// the next film without any live command surface.
    private var passthroughDisabled: Bool {
        guard let data = UserDefaults.standard.data(forKey: "audio.passthrough.v1"),
              let raw = String(data: data, encoding: .utf8)
        else { return false }
        return raw == "0"
    }

    /// The stored upscaling refusal, read the same way and at the same moment:
    /// an unset key is a viewer who has never been to the pane, and the path
    /// is on by default.
    private var upscalingDisabled: Bool {
        guard let data = UserDefaults.standard.data(forKey: "video.upscaling.v1"),
              let raw = String(data: data, encoding: .utf8)
        else { return false }
        return raw == "0"
    }

    /// The stored refusal of the network for the upscaling, read as the
    /// upscaling's own: unset is on.
    private var neuralUpscaling: Bool {
        guard let data = UserDefaults.standard.data(forKey: "video.neuralUpscaling.v1"),
              let raw = String(data: data, encoding: .utf8)
        else { return true }
        return raw != "0"
    }

    /// The stored Dolby Vision refusal, same shape: unset is on.
    private var dolbyVisionDisabled: Bool {
        guard let data = UserDefaults.standard.data(forKey: "video.dolbyVision.v1"),
              let raw = String(data: data, encoding: .utf8)
        else { return false }
        return raw == "0"
    }

    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            // deliberately no Now Playing here: mediaserverd extrapolates
            // elapsed time from the playback rate between writes, so a per-
            // tick dict push was an XPC serialization every second for a
            // number the system already had. The transitions write it.
            self.publishStats()
            self.sampleFootprint()
            // Asked after the publish and read by the next one: the renderer
            // answers on its own thread, and a tick must not wait on it.
            self.sink.loadRendererMetrics { metrics in
                DispatchQueue.main.async { self.rendererMetrics = metrics }
            }
        }
    }

    /// What this bridge gives back when the system asks for memory, which is
    /// everything it is holding only to avoid doing the work again: the
    /// scrub thumbnails and the decoder that makes them, and the pictures
    /// the decode pools are keeping for reuse. Nothing here is what is being
    /// played, so a film in progress does not notice; the next scrub pays
    /// for its own decoder again, which is what a cache is for.
    ///
    /// Deliberately not the queues. Read-ahead is what absorbs a network
    /// stall and the picture queue is what the renderer is about to show:
    /// dropping either buys memory at the price of the film stuttering,
    /// which is the one thing a viewer would rather the app had not done.
    private func dropWhatIsOnlyCached() {
        queue.async { [weak self] in
            guard let self else { return }
            let before = footprintBytes()
            self.dropThumbnailDecoder()
            self.player.releaseSpareBuffers()
            let now = footprintBytes()
            traceLine("[lexis.mem] memory warning: gave back"
                + " \(max(before - now, 0) / 1_048_576) MiB, footprint \(now / 1_048_576) MiB,"
                + " headroom \(availableMemoryBytes() / 1_048_576) MiB")
        }
    }

    /// The high-water mark of this process while a film plays, printed only
    /// when it moves: jetsam weighs the footprint, and a reading taken once
    /// at the open would miss the pool filling behind the first frames.
    /// How many rebuffers of this playback have been written down. Reset by
    /// every open, so the count in the trace is this film's and not the
    /// session's.
    private var rebuffersTraced = 0
    /// Every stall, as it happens: the buffer the engine gave up at and what
    /// the source was sustaining while it did. Printed only when the count
    /// moves, like the footprint below - the viewer sees these as the
    /// buffering notice, and nothing else in this process writes them down.
    private func sampleRebuffers(_ stats: PlaybackStats) {
        guard stats.rebufferCount > rebuffersTraced else { return }
        rebuffersTraced = stats.rebufferCount
        // Formatted, never Int(): a Double that came back NaN - an invalid
        // CMTime reads as one - traps the conversion, and this runs on the
        // ticker of every playback.
        traceLine(String(
            format: "[lexis.buf] rebuffer %d at %.0f s, buffered %.2f s,"
                + " source %.1f Mb/s, footprint %d MiB",
            stats.rebufferCount, stats.position, stats.bufferedSeconds,
            stats.ioSustainedBitsPerSecond / 1_000_000,
            footprintBytes() / 1_048_576))
    }

    private var footprintHighWater = 0
    private func sampleFootprint() {
        let now = footprintBytes()
        guard now > footprintHighWater + 8 * 1_048_576 else { return }
        footprintHighWater = now
        traceLine("[lexis.mem] footprint \(now / 1_048_576) MiB,"
            + " headroom \(availableMemoryBytes() / 1_048_576) MiB")
    }

    /// One reading of everything the player can be asked, out to the screen.
    /// Main thread only, like the ticker that drives it - and like the end of
    /// stream that publishes the last one: a counter that stops at whichever
    /// tick happened to land before the film ended describes part of a
    /// playback, and dropped frames are counted over the whole of one.
    private func publishStats() {
        let stats = player.stats
        sampleRebuffers(stats)
        // Ticks are on a Timer started synchronously by open(), and the
        // adopt() that actually commits a stream runs on queue, after a
        // network probe for a Plex source: a tick landing in that window
        // must not report dynamicRange or the audio fields as read when
        // they are still the struct's defaults.
        let fileOpen = player.isOpen
        let criteria = player.displayCriteria
        // AVDisplayManager has no getter for what it actually settled on:
        // what is reportable is whether this bridge asked at all, which it
        // does only when the display matches criteria. A display that
        // cannot be asked - the simulator's - must not be reported as
        // having agreed to 0 Hz, which no real display ever reports either.
        let negotiated = displayModeSettled
        // The renderer's own count, since this film opened. Both 0 until the
        // first reading lands, and on a platform that cannot say.
        let baseline = rendererBaseline ?? (displayed: 0, dropped: 0, delaySeconds: 0, optimized: 0)
        // Whether the frames take the display's own video plane or the
        // general compositor: only the first is paced frame by frame, and a
        // display processing the signal can only lock onto that.
        let optimized = max((rendererMetrics?.optimized ?? 0) - baseline.optimized, 0)
        let rendererDisplayed = max((rendererMetrics?.displayed ?? 0) - baseline.displayed, 0)
        let rendererDropped = max((rendererMetrics?.dropped ?? 0) - baseline.dropped, 0)
        rendererPublished = (
            rendererDisplayed, rendererDropped,
            max((rendererMetrics?.delaySeconds ?? 0) - baseline.delaySeconds, 0)
        )
        let clock = sink.clockReading
        var clockSpeed = 1.0
        if let clockTraced, clock.host > clockTraced.host + 0.1 {
            clockSpeed = (clock.stream - clockTraced.stream) / (clock.host - clockTraced.host)
        }
        clockTraced = (clock.stream, clock.host)
        let cpu = LexisPlayerBridge.processCPUSeconds
        var cpuLoad = 0.0
        if let cpuTraced, clock.host > cpuTraced.host + 0.1 {
            cpuLoad = (cpu - cpuTraced.cpu) / (clock.host - cpuTraced.host)
        }
        cpuTraced = (cpu, clock.host)
        if rendererDropped > rendererDroppedTraced {
            let grid = FrameGridTally.reading
            traceLine(String(
                format: "[lexis.render] screen dropped +%d (%d of %d) at %.1f s, delay %.3f s,"
                    + " starvations %d, screen %.3f Hz, grid %d snapped %d off,"
                    + " runway %.2f s, audio %.2f s, clock x%.4f rate %.1f, buffered %.1f s, stalls %d, cpu %.0f%%",
                rendererDropped - rendererDroppedTraced, rendererDropped, rendererDisplayed,
                stats.position, (rendererMetrics?.delaySeconds ?? 0) - baseline.delaySeconds,
                stats.pictureStarvations, LexisPlayerBridge.measuredRefreshHz ?? 0,
                grid.snapped, grid.offGrid, sink.videoRunwaySeconds, sink.audioRunwaySeconds,
                clockSpeed, clock.rate, stats.bufferedSeconds, stats.rebufferCount, cpuLoad * 100))
            rendererDroppedTraced = rendererDropped
            rendererLastDropSeconds = stats.position
        }
        // A line every ten ticks whatever the counters do, so a playback with
        // no drop still says where its frames sit against the refresh.
        heartbeatTicks += 1
        if heartbeatTicks % 10 == 0 {
            traceLine(String(
                format: "[lexis.render] at %.1f s: dropped %d of %d, optimized %d, runway %.2f s,"
                    + " audio %.2f s, clock x%.4f rate %.1f, buffered %.1f s, stalls %d, cpu %.0f%%",
                stats.position, rendererDropped, rendererDisplayed, optimized, sink.videoRunwaySeconds,
                sink.audioRunwaySeconds, clockSpeed, clock.rate, stats.bufferedSeconds,
                stats.rebufferCount, cpuLoad * 100))
        }
        onStats?(stats, PlayerStats(
            stats, fileOpen: fileOpen, dynamicRange: player.dynamicRange.rawValue,
            // What the screen was measured running at, where the switch was
            // watched; what was asked for otherwise. The two differ by the
            // whole story when a screen offers 24 and not 23.976.
            displayRefreshRate: LexisPlayerBridge.measuredRefreshHz ?? Double(criteria?.refreshRate ?? 0),
            displayModeNegotiated: negotiated, displayCriteriaMatchingEnabled: displayMatchingEnabled,
            rendererFramesDisplayed: rendererDisplayed, rendererFramesDropped: rendererDropped,
            rendererLastDropSeconds: rendererLastDropSeconds, audioRendering: renderingMode))
    }

    /// How long a mode switch is allowed to hold up the first frame. The
    /// spec asks for the switch to settle before playback starts; a switch
    /// that never settles must not hang the reader forever.
    /// The whole wait's ceiling: the cadence change, then the cable's own
    /// renegotiation after it, and a margin. Reached only by a display that
    /// answers neither.
    private static let displaySwitchDeadline = 8.0

    /// Called off `queue` before `play()`, so the switch (which blanks the
    /// screen briefly) happens before the first frame and playback waits for
    /// it to settle, never mid-playback. The write itself is the main
    /// thread's; this waits for it and for the screen, bounded by
    /// `displaySwitchDeadline` for the two together.
    /// One write, for the film about to play: `preferredDisplayCriteria` is
    /// what the display is asked for, so asking for the system's own mode
    /// first only buys a second renegotiation back to back with this one.
    private func applyDisplayCriteria() {
        // Two stages, not one: the write is ours and the settle is the
        // screen's, and a projector that takes a second to renegotiate must
        // not read as a second of our own code.
        OpenTrace.shared.enter(.displayWrite)
        settleDisplay(startDisplayCriteria(player.displayCriteria, range: player.dynamicRange))
    }

    /// Opens a file with `open`, the display asked for its mode as soon as the
    /// player knows it, mid-open: the screen switches while the pipeline is
    /// built, and only what is left of its switch is waited for after. A
    /// mode the open ended up changing is asked for again, as before.
    private func openMatchingDisplay(_ open: () throws -> Void) throws {
        #if os(tvOS)
        final class Early: @unchecked Sendable { var pending: PendingDisplay? }
        let early = Early()
        player.onDisplayKnown = { [weak self] request, range in
            guard let self, !self.teardown.isRaised else { return }
            OpenTrace.shared.mark("display asked mid-open")
            early.pending = self.startDisplayCriteria(request, range: range)
        }
        defer { player.onDisplayKnown = nil }
        try open()
        // A stop or a close can land on the main thread while the open was
        // still probing; the teardown it raised must not be undone by a
        // switch this same open queues moments later.
        guard !teardown.isRaised else { return }
        if let pending = early.pending, pending.request?.refreshRate == player.displayCriteria?.refreshRate,
            pending.range == player.dynamicRange
        {
            OpenTrace.shared.enter(.displaySettle)
            settleDisplay(pending, traced: false)
        } else {
            applyDisplayCriteria()
        }
        #else
        try open()
        #endif
    }

    /// A display write under way: what was asked, and how to wait for it.
    private struct PendingDisplay {
        let request: DisplayCriteriaRequest?
        let range: VideoDynamicRange
        let write: DisplayWrite
        let written: DispatchSemaphore
        let startedAt: CFTimeInterval
    }

    /// Asks the display for `request` on the main thread, and returns at once.
    private func startDisplayCriteria(_ request: DisplayCriteriaRequest?, range: VideoDynamicRange) -> PendingDisplay {
        let startedAt = CACurrentMediaTime()
        let write = DisplayWrite()
        let written = DispatchSemaphore(value: 0)
        // async and a semaphore, never main.sync: this runs on the one
        // control queue, and the main thread at the moment a film opens is
        // the interface mounting the player screen. Blocking on it parks
        // play, pause and seek behind whatever the interface is doing, for
        // however long that takes; waiting here puts the hop under the same
        // deadline the settle itself answers to.
        DispatchQueue.main.async { [weak self] in
            defer { written.signal() }
            guard let self, let manager = self.hostView?.window?.avDisplayManager else { return }
            // The viewer's own Match Content setting. tvOS honours the
            // criteria only while it is on, so with it off the display is
            // left alone entirely rather than written to for no effect. It is
            // recorded either way: a film left at the screen's own refresh
            // rate judders, and nothing else on the panel can say why.
            self.displayMatchingEnabled = manager.isDisplayCriteriaMatchingEnabled
            guard manager.isDisplayCriteriaMatchingEnabled else { return }
            guard let request else {
                // A film whose frame rate could not be read asks for
                // nothing, and must not inherit the mode the last one left.
                self.clearDisplayCriteria()
                write.note = "display given back"
                return
            }
            let wanted = HeldMode(refreshRate: request.refreshRate, range: range)
            // Nothing is written for a mode the display is already in. The
            // write itself is what renegotiates HDMI, so repeating it for an
            // identical mode costs a renegotiation and buys nothing.
            guard LexisPlayerBridge.heldMode != wanted else {
                self.displayCriteriaHeld = true
                self.displayModeSettled = true
                write.note = "display kept in mode"
                return
            }
            // Armed before the main thread is given back, so no refresh
            // between the write and the first tick goes unseen. At most one
            // watch runs at a time: its display link owns it, and one left
            // ticking would outlive the open that started it.
            self.displaySwitch?.release()
            let started = DisplaySwitchWatch(manager: manager, refreshRate: request.refreshRate)
            self.displaySwitch = started
            manager.preferredDisplayCriteria = AVDisplayCriteria(
                refreshRate: request.refreshRate, formatDescription: request.formatDescription
            )
            self.displayCriteriaHeld = true
            LexisPlayerBridge.heldMode = wanted
            write.watch = started
        }
        return PendingDisplay(request: request, range: range, write: write, written: written, startedAt: startedAt)
    }

    /// Waits for a display write and for the screen to take it, both within
    /// `displaySwitchDeadline` of the write. `traced` false leaves the stage
    /// to the caller, which entered it already.
    private func settleDisplay(_ pending: PendingDisplay, traced: Bool = true) {
        let (write, written, startedAt) = (pending.write, pending.written, pending.startedAt)
        let deadline = LexisPlayerBridge.displaySwitchDeadline
        guard written.wait(timeout: .now() + max(deadline - (CACurrentMediaTime() - startedAt), 0)) == .success else {
            if traced { OpenTrace.shared.enter(.displaySettle) }
            OpenTrace.shared.mark("display never answered")
            return
        }
        if traced { OpenTrace.shared.enter(.displaySettle) }
        guard let watch = write.watch else {
            OpenTrace.shared.mark(write.note)
            return
        }
        let outcome = watch.wait(seconds: max(deadline - (CACurrentMediaTime() - startedAt), 0))
        // Only once the watch has stopped: a wait that timed out leaves the
        // link ticking, and its state is not this thread's to read.
        let cadence = outcome == .neverSettled ? nil : watch.cadenceDelayMilliseconds
        DispatchQueue.main.async { [weak self] in
            guard let self, self.displaySwitch === watch else { return }
            self.displaySwitch = nil
            // A mode the screen never took is not a mode held: the next film
            // asking for the same one has to ask again, or it inherits a
            // request that already failed and the panel calls it negotiated.
            switch outcome {
            case .switched, .alreadyInMode:
                self.displayModeSettled = true
                LexisPlayerBridge.measuredRefreshHz = watch.measuredRefreshHz
            case .neverTook, .neverSettled, .givenBack:
                self.displayModeSettled = false
                LexisPlayerBridge.heldMode = nil
                LexisPlayerBridge.measuredRefreshHz = nil
            }
        }
        if let cadence {
            OpenTrace.shared.mark(String(format: "%@, cadence at %.0f ms", outcome.rawValue, cadence))
        } else {
            OpenTrace.shared.mark(outcome.rawValue)
        }
    }

    /// So the rest of the interface returns to the viewer's own mode. Main
    /// thread only, like every other UIKit touch `stop()`/`close()` make.
    /// Only when a mode was actually taken: nil is itself a request the
    /// display renegotiates for, not a neutral reset, and the end of stream,
    /// the stop and the close all pass through here for one playback.
    private func clearDisplayCriteria() {
        releaseDisplaySwitch()
        displayModeSettled = false
        // `heldMode` set with nothing held here is a mode a closing bridge
        // handed over to this one: it is this bridge's to give back.
        guard displayCriteriaHeld || LexisPlayerBridge.heldMode != nil else { return }
        displayCriteriaHeld = false
        LexisPlayerBridge.heldMode = nil
        LexisPlayerBridge.measuredRefreshHz = nil
        hostView?.window?.avDisplayManager.preferredDisplayCriteria = nil
    }

    /// What the end of a playback does: the mode stays, because the next
    /// film usually wants the same one and giving it back costs the same
    /// renegotiation as taking it. Only an open still waiting on its switch
    /// is let go, since nothing is going to play in the mode it waits for.
    /// Main thread only.
    private func releaseDisplaySwitch() {
        displaySwitch?.release()
        displaySwitch = nil
    }

    /// Playback holds off tvOS's own screen saver and releases it the
    /// moment playback ends, on every exit including failure: `report(_:)`
    /// covers every terminal event, and `stop()`/`close()` cover the two
    /// that do not raise one.
    private func setIdleTimerDisabled(_ disabled: Bool) {
        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = disabled
        }
    }

    /// The activation `activateAudioSession` started, until the next open
    /// waits for it. Main thread only.
    private var audioActivation: AudioActivation?

    /// Starts setting the audio session up for playback off the main thread,
    /// where its activation blocks: called ahead of an open, the two overlap.
    /// Main thread only.
    public func activateAudioSession() {
        #if os(tvOS)
        guard audioActivation == nil else { return }
        let activation = AudioActivation()
        audioActivation = activation
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .moviePlayback)
                try session.setSupportsMultichannelContent(true)
                try session.setActive(true)
                // Until asked, the route can stay at two channels and fold the
                // decoder's 5.1 and 7.1 PCM down to stereo.
                try? session.setPreferredOutputNumberOfChannels(session.maximumOutputNumberOfChannels)
                activation.renderingMode = session.renderingMode
            } catch {
                activation.refusal = error
            }
            activation.done.signal()
        }
        #endif
    }

    /// Shared by both open entry points: the audio session, the session
    /// bump, the ticker and the "opening" status every open reports before
    /// its own probe/adopt runs. Returns false when the audio session
    /// refused, in which case the caller must not proceed.
    private func beginOpen() -> Bool {
        #if os(tvOS)
        // Without a playback category the audio renderer is silent, and it is
        // the clock the video follows: a session the system refuses is not a
        // quiet playback but a frozen one, so it ends the open rather than
        // leaving a stall nothing accounts for.
        activateAudioSession()
        if let activation = audioActivation {
            audioActivation = nil
            activation.done.wait()
            if let refusal = activation.refusal {
                onStatus?("failed", "the system refused the audio session: \(refusal)", 0, 0, "", 0)
                return false
            }
            renderingMode = activation.renderingMode
        }
        #endif
        session &+= 1
        teardown.lower()
        // Read here, on main, so the open queued next decides its path on
        // this reading rather than waiting on main while the screen mounts.
        _ = DisplayCapability.current()
        rebuffersTraced = 0
        // The renderer counts across films: what it holds now is the last
        // one's, and this film's reading starts from here. Nothing of this
        // film reaches the renderer before the probe and the mode switch
        // are done, well after this answers.
        rendererBaseline = nil
        rendererMetrics = nil
        rendererDroppedTraced = 0
        rendererLastDropSeconds = 0
        rendererPublished = (0, 0, 0)
        heartbeatTicks = 0
        sink.loadRendererMetrics { [weak self] metrics in
            DispatchQueue.main.async { self?.rendererBaseline = metrics }
        }
        startTicker()
        onStatus?("opening", "", 0, 0, "", 0)
        setIdleTimerDisabled(true)
        return true
    }

    /// Takes ownership of `handle`, a `LexisStream *` the core returned as an
    /// integer, and plays it. Opening is what decides when playback can start,
    /// so a play() from JavaScript would arrive too early to be of use.
    @objc(openStreamHandle:title:) public func open(handle: UInt64, title: String) {
        guard let pointer = OpaquePointer(bitPattern: UInt(handle)) else {
            onStatus?("failed", "the core returned no stream", 0, 0, "", 0)
            return
        }
        // `--fetch <url>` on the process plays that file in place of whatever
        // the viewer picked: a measurement switch, for running a known clip
        // through this screen and nothing but this screen.
        let arguments = ProcessInfo.processInfo.arguments
        if let at = arguments.firstIndex(of: "--fetch"), at + 1 < arguments.count,
           let remote = URL(string: arguments[at + 1]) {
            let stream = coreStream(handle: pointer)
            stream.close(stream.handle)
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            let local = caches.appendingPathComponent("fetched-" + remote.lastPathComponent)
            if FileManager.default.fileExists(atPath: local.path) {
                traceLine("[lexis.open] fetched already: \(local.lastPathComponent)")
                openLocalFile(path: local.path, title: title)
                return
            }
            URLSession.shared.downloadTask(with: remote) { [weak self] location, _, error in
                guard let location else {
                    traceLine("[lexis.open] fetch failed: \(error.map { "\($0)" } ?? "no file")")
                    return
                }
                try? FileManager.default.moveItem(at: location, to: local)
                traceLine("[lexis.open] fetched \(local.lastPathComponent)")
                DispatchQueue.main.async { self?.openLocalFile(path: local.path, title: title) }
            }.resume()
            return
        }
        OpenTrace.shared.begin(title: title)
        OpenTrace.shared.enter(.handoff)
        let stream = coreStream(handle: pointer)
        guard beginOpen() else {
            stream.close(stream.handle)
            OpenTrace.shared.finish("refused")
            return
        }
        queue.async { [weak self] in
            guard let self, !self.teardown.isRaised else {
                // nothing will ever read it, and it holds a socket
                stream.close(stream.handle)
                return
            }
            // A new file's own thumbnails, not the one this session is
            // leaving: the strip decoder is built from the leaving file's
            // stream and must not go on answering scrub requests with it.
            self.dropThumbnailDecoder()
            self.player.setPassthroughAllowed(!self.passthroughDisabled)
            self.player.setAudioRoute(.current)
            self.player.setUpscalingAllowed(!self.upscalingDisabled)
            self.player.setNeuralUpscaling(self.neuralUpscaling)
            self.player.setDolbyVisionAllowed(!self.dolbyVisionDisabled)
            do {
                try self.openMatchingDisplay { try self.player.open(stream: stream) }
                // Same race as the display's, one line later: a stop or close's cancel() must not
                // be undone by a play() this same open queues after it.
                guard !self.teardown.isRaised else {
                    OpenTrace.shared.finish("stopped")
                    return
                }
                OpenTrace.shared.enter(.firstFrame)
                self.player.play()
            } catch {
                OpenTrace.shared.finish("failed (\(error))")
                let cancelled = self.player.isCancelled
                DispatchQueue.main.async {
                    if cancelled {
                        // a stop raises the interrupt before it queues itself,
                        // so an open it cut short ended because it was told to
                        self.onStatus?("stopped", "", 0, 0, "", 0)
                    } else if case DemuxError.unauthorized = error {
                        // an expired token is refused at probe time as often as
                        // mid-playback, and the app must see one status for both
                        self.report(.unauthorized)
                    } else if case PlaybackMemoryError.tooLargeForMemory(
                        let required, let allowed) = error
                    {
                        self.report(
                            .tooLargeForMemory(requiredBytes: required, allowedBytes: allowed))
                    } else {
                        // Routed through report(_:), not onStatus? directly, so a
                        // probe failure releases the idle timer, Now Playing and
                        // the remote commands the same way any other .failed does.
                        self.report(.failed(String(describing: error)))
                    }
                }
            }
        }
    }

    /// Plays a local file directly, bypassing the core's index entirely -
    /// what the benchmark runner (Task 4 of the benchmark chantier) opens
    /// the generated corpus with, since those clips are never scanned.
    @objc(openLocalFilePath:title:) public func openLocalFile(path: String, title: String) {
        guard beginOpen() else { return }
        let url = URL(fileURLWithPath: path)
        queue.async { [weak self] in
            guard let self, !self.teardown.isRaised else { return }
            // the leaving file's strip decoder must not go on answering scrub
            // requests once this one replaces it
            self.dropThumbnailDecoder()
            self.player.setPassthroughAllowed(!self.passthroughDisabled)
            self.player.setAudioRoute(.current)
            self.player.setUpscalingAllowed(!self.upscalingDisabled)
            self.player.setNeuralUpscaling(self.neuralUpscaling)
            self.player.setDolbyVisionAllowed(!self.dolbyVisionDisabled)
            do {
                try self.openMatchingDisplay { try self.player.open(url: url) }
                guard !self.teardown.isRaised else { return }
                self.player.play()
            } catch {
                let cancelled = self.player.isCancelled
                DispatchQueue.main.async {
                    if cancelled {
                        self.onStatus?("stopped", "", 0, 0, "", 0)
                    } else {
                        self.report(.failed(String(describing: error)))
                    }
                }
            }
        }
    }

    /// Takes ownership of `handle`, a second `LexisStream *` over the playing
    /// file, and builds the strip decoder from it. The build probes the
    /// network, so it runs off `queue`: play, pause and seek never wait on it.
    /// Once `onThumbnailStreamClosed` fires the handle is gone for good.
    public func attachThumbnailStream(handle: UInt64) {
        guard let pointer = OpaquePointer(bitPattern: UInt(handle)) else { return }
        let stream = coreStream(handle: pointer)
        queue.async { [weak self] in
            guard let self, !self.teardown.isRaised,
                self.thumbnailDecoder == nil, !self.thumbnailBuilding
            else {
                stream.close(stream.handle)
                return
            }
            self.thumbnailBuilding = true
            let generation = self.thumbnailGeneration
            DispatchQueue.global(qos: .utility).async { [weak self] in
                // a failed build has already closed the stream: the demuxer
                // owns it from the first byte it reads
                let built = try? ThumbnailStripDecoder(
                    stream: stream, analysis: stream.cachedAnalysis())
                guard let self else {
                    built?.cancel()
                    return
                }
                self.queue.async {
                    guard generation == self.thumbnailGeneration, let built else {
                        built?.cancel()
                        if generation == self.thumbnailGeneration { self.dropThumbnailDecoder() }
                        return
                    }
                    self.thumbnailBuilding = false
                    self.thumbnailDecoder = built
                    if let waiting = self.thumbnailWaiting {
                        self.thumbnailWaiting = nil
                        self.strip(built, at: waiting)
                    }
                }
            }
        }
    }

    /// Decodes a keyframe thumbnail for each of `seconds` through the strip
    /// decoder's own session - never through `player`/`sink`, and never gated
    /// by PlaybackActivityGate, so this works whether or not a film is
    /// already playing. Replies once per thumbnail landed; a request a newer
    /// one replaced, or a seek dropped, replies nothing.
    public func requestThumbnails(seconds: [Double]) {
        queue.async { [weak self] in
            guard let self else { return }
            if let decoder = self.thumbnailDecoder {
                self.strip(decoder, at: seconds)
            } else if self.thumbnailBuilding {
                self.thumbnailWaiting = seconds
            }
        }
    }

    /// On `queue`. The picture is prepared on the decoder's own queue: it is a
    /// copy play, pause and seek must not wait on.
    private func strip(_ decoder: ThumbnailStripDecoder, at seconds: [Double]) {
        decoder.strip(at: seconds) { [weak self] images in
            guard let self else { return }
            for (second, image) in images {
                // neighbouring seconds land on one keyframe: one prepared copy serves them all
                self.preparedThumbnailLock.lock()
                let last = self.lastPreparedThumbnail
                self.preparedThumbnailLock.unlock()
                let prepared: UIImage
                if let last, last.source === image {
                    prepared = last.image
                } else {
                    prepared = UIImage(cgImage: image).preparingForDisplay() ?? UIImage(cgImage: image)
                    self.preparedThumbnailLock.lock()
                    self.lastPreparedThumbnail = (image, prepared)
                    self.preparedThumbnailLock.unlock()
                }
                DispatchQueue.main.async { [weak self] in self?.onThumbnails?(second, prepared) }
            }
        }
    }

    /// The strip's last image and its prepared copy, under the lock: a strip
    /// decoder being replaced can still answer from its own queue.
    private let preparedThumbnailLock = NSLock()
    private var lastPreparedThumbnail: (source: CGImage, image: UIImage)?

    /// On `queue`. Lets the strip decoder go, or a build still in flight, and
    /// tells the owner of the handle that the stream behind it is closed.
    private func dropThumbnailDecoder() {
        thumbnailGeneration += 1
        thumbnailWaiting = nil
        guard thumbnailDecoder != nil || thumbnailBuilding else { return }
        thumbnailDecoder?.cancel()
        thumbnailDecoder = nil
        thumbnailBuilding = false
        DispatchQueue.main.async { [weak self] in self?.onThumbnailStreamClosed?() }
    }

    @objc public func play() {
        queue.async { [weak self] in self?.player.play() }
    }

    @objc public func pause() {
        queue.async { [weak self] in self?.player.pause() }
    }

    /// Returns at once: the player hands the seek to its reader thread.
    @objc(seekSeconds:) public func seek(seconds: Double) {
        queue.async { [weak self] in
            // the refill a seek starts has first claim on the link; the frame
            // it lands on hands the strip its turn back, and whatever a scrub
            // was still waiting for is over with the seek that ends it
            self?.thumbnailDecoder?.setSuspended(true)
            self?.thumbnailDecoder?.dropPending()
            self?.player.seek(to: seconds)
        }
    }

    @objc(selectAudioTrack:) public func selectAudioTrack(index: Int32) {
        queue.async { [weak self] in self?.player.selectAudioTrack(index: index) }
    }

    /// The stored upscaling, onto the film playing: turning it off or on
    /// turns the film round at once, for the scaler to be judged against the
    /// compositor on the same frames.
    @objc public func applyUpscaling() {
        queue.async { [weak self] in
            guard let self else { return }
            self.player.setUpscalingAllowed(!self.upscalingDisabled)
            self.player.setNeuralUpscaling(self.neuralUpscaling)
        }
    }

    /// -1 turns subtitles off.
    @objc(selectSubtitleTrack:) public func selectSubtitleTrack(index: Int32) {
        queue.async { [weak self] in self?.player.selectSubtitleTrack(index: index) }
    }

    /// How much room the JavaScript overlay is taking at the bottom of the
    /// view right now, in points. Straight to the layer tree on the main
    /// thread rather than through the control queue: this moves a sublayer
    /// and touches nothing the reader owns.
    @objc(setSubtitleLiftPoints:) public func setSubtitleLift(points: Double) {
        let lift = CGFloat(points)
        if Thread.isMainThread {
            sink.subtitleLift = lift
        } else {
            DispatchQueue.main.async { [weak self] in self?.sink.subtitleLift = lift }
        }
    }

    @objc(setAudioDelaySeconds:) public func setAudioDelay(seconds: Double) {
        queue.async { [weak self] in self?.player.setAudioDelay(seconds) }
    }

    /// Read by the cue clocks on their own queues, so set from anywhere.
    @objc(setSubtitleOffsetSeconds:) public func setSubtitleOffset(seconds: Double) {
        sink.subtitleOffset = seconds
    }

    /// Returns at once. The cancel is synchronous because it is what lets the
    /// queued stop finish quickly; the stop itself waits for the reader, and
    /// holds the bridge alive until it has.
    @objc public func stop() {
        ticker?.invalidate()
        reportedPlaying = false
        pausedByInterruption = false
        #if os(tvOS)
        // The display goes back to the viewer's own mode, not just the watch.
        // Keeping the film's mode is right BETWEEN films - an auto-advance
        // wants the same one and a renegotiation costs a black screen - but a
        // viewer who left playback is looking at the interface, and leaving
        // their Apple TV pinned in an SDR 24 Hz mode takes Dolby Vision away
        // from tvOS itself until something else asks for it back.
        clearDisplayCriteria()
        #endif
        setIdleTimerDisabled(false)
        teardown.raise()
        closedSession = session
        player.cancel()
        queue.async { self.player.stop() }
    }

    /// Stops, and lets go of the stream and the container with it: a view that
    /// is parked in the recycle pool must not keep a socket open. Returns at
    /// once, like stop(); only a later open plays anything again.
    ///
    /// `keepDisplay` is for a close the next file's open follows at once: the
    /// mode stays in `heldMode` for that open to find, and this bridge no
    /// longer answers for it.
    @objc public func close(keepDisplay: Bool = false) {
        ticker?.invalidate()
        reportedPlaying = false
        pausedByInterruption = false
        #if os(tvOS)
        if keepDisplay {
            releaseDisplaySwitch()
            displayModeSettled = false
            displayCriteriaHeld = false
        } else {
            // Same as stop(): whoever is closing the player is on their way
            // back to the interface, which is the system's own mode to draw.
            clearDisplayCriteria()
        }
        #endif
        setIdleTimerDisabled(false)
        teardown.raise()
        closedSession = session
        player.cancel()
        queue.async {
            // first, so a strip still decoding stops before the close waits
            self.dropThumbnailDecoder()
            self.player.close()
        }
    }

    private func report(_ event: PlayerEvent) {
        switch event {
        case .opened(let width, let height, let codec):
            // A close moves the view on before the queued work that produced
            // this ever runs, so what it describes is already being torn down.
            guard closedSession != session else { return }
            onStatus?("opened", "", width, height, codec, 0)
        case .tracks(let list):
            // Stale for the same reason, and worse: a re-mounted view's pickers
            // would then command in the closed file's stream index space.
            guard closedSession != session else { return }
            onTracks?(
                list.audio.map {
                    LexisPlayerBridge.describe($0, selected: $0.index == list.selectedAudio)
                },
                list.subtitle.map {
                    LexisPlayerBridge.describe($0, selected: $0.index == list.selectedSubtitle)
                },
                list.chapters.map { LexisPlayerBridge.describe($0) }
            )
        case .firstFrame(let seconds):
            guard closedSession != session else { return }
            // a seek suspended the strip; the frame it landed on is up, and a
            // paused film sends nothing after this to give the link back
            queue.async { [weak self] in self?.thumbnailDecoder?.setSuspended(false) }
            // The samples a seek's flush threw away were counted as dropped
            // by the renderer; the landed frame is where the film's own
            // count picks up again, from the figure it stood at.
            sink.loadRendererMetrics { [weak self] metrics in
                guard let metrics else { return }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.rendererBaseline = (
                        metrics.displayed - self.rendererPublished.displayed,
                        metrics.dropped - self.rendererPublished.dropped,
                        metrics.delaySeconds - self.rendererPublished.delaySeconds,
                        self.rendererBaseline?.optimized ?? metrics.optimized
                    )
                    self.rendererMetrics = metrics
                }
            }
            onFirstFrame?(seconds)
        case .playing:
            // the film has the link back for good: a scrub's sparse seeks may run again
            queue.async { [weak self] in self?.thumbnailDecoder?.setSuspended(false) }
            reportedPlaying = true
            onStatus?("playing", "", 0, 0, "", 0)
        case .paused:
            queue.async { [weak self] in self?.thumbnailDecoder?.setSuspended(false) }
            reportedPlaying = false
            onStatus?("paused", "", 0, 0, "", 0)
        case .buffering(let bufferedSeconds):
            // first claim on the link goes to the film; the strip waits
            queue.async { [weak self] in self?.thumbnailDecoder?.setSuspended(true) }
            onStatus?("buffering", "", 0, 0, "", bufferedSeconds)
        case .stopped:
            // The only event a teardown produces, and the only one that can
            // arrive after the view has moved on: a stop waits out the reader,
            // and the open that took its place is already showing "opening".
            guard closedSession == session else { return }
            onStatus?("stopped", "", 0, 0, "", 0)
        case .endOfStream:
            reportedPlaying = false
            // Nothing is playing once the stream ends, so the holdoff's reason is
            // gone; tvOS's own timer is the right owner of when the screen sleeps
            // from here, credits overlay or not. A later open takes it again.
            setIdleTimerDisabled(false)
            // The last reading of the playback, and the only one that covers
            // all of it: the player has already frozen the engine's final
            // counters by the time this event arrives, and the frames that
            // crossed the sink since the previous tick - the closing frames of
            // the film - are counted nowhere else. Before the invalidate, or
            // the ticker that would have carried it is already gone.
            publishStats()
            // The ticker's job was reporting a moving position; nothing moves once
            // the stream ends, so it stops.
            ticker?.invalidate()
            // Everything taken for playback is given back together: PlayerScreen
            // calls neither stop() nor close() on end of stream, so nothing else
            // would return the display to the viewer's own mode, and the ended
            // screen would otherwise stay drawn at the film's cadence until Back.
            #if os(tvOS)
            releaseDisplaySwitch()
            #endif
            onStatus?("ended", "", 0, 0, "", 0)
        case .failed(let reason):
            reportedPlaying = false
            // The reading that says how much of the playback happened before
            // it broke, and the only one that carries `decodeFailures` at
            // all: the player freezes the engine's final counters before it
            // yields this, and a failure that arrives between two ticks is
            // counted nowhere else. Before the invalidate, like the end of
            // stream's own last reading.
            publishStats()
            // Terminal, like .stopped: a mid-playback failure leaves the
            // criteria this open applied pinned to the display forever
            // unless it is cleared here too. The ticker stops too.
            ticker?.invalidate()
            #if os(tvOS)
            releaseDisplaySwitch()
            #endif
            setIdleTimerDisabled(false)
            onStatus?("failed", reason, 0, 0, "", 0)
        case .unauthorized:
            reportedPlaying = false
            ticker?.invalidate()
            #if os(tvOS)
            releaseDisplaySwitch()
            #endif
            setIdleTimerDisabled(false)
            onStatus?("unauthorized", "the server refused the credential", 0, 0, "", 0)
        case .tooLargeForMemory(let required, let allowed):
            // The same terminal teardown a .failed gets: the film never
            // started, so nothing here is scoped to a playback any more.
            ticker?.invalidate()
            #if os(tvOS)
            releaseDisplaySwitch()
            #endif
            setIdleTimerDisabled(false)
            // The numbers go in the detail, where the log already carries the
            // engine's own words; the viewer gets a sentence from the catalog.
            onStatus?(
                "tooLarge",
                "the pipeline needs \(required / 1_048_576) MB and this device has "
                    + "\(allowed / 1_048_576) MB to give",
                0, 0, "", 0
            )
        }
    }

    /// What the JS side needs of a track. `graphic` is only ever true of a
    /// subtitle, and the audio half of the event does not read it.
    private static func describe(_ stream: MediaStream, selected: Bool) -> NSDictionary {
        [
            "index": Int(stream.index),
            "codec": stream.codecName,
            "language": stream.language,
            "title": stream.title,
            "graphic": SubtitleDecoder.isGraphic(codecID: stream.codecID),
            "channels": Int(stream.channels),
            "default": stream.isDefault,
            "forced": stream.isForced,
            "selected": selected,
        ] as NSDictionary
    }

    /// What the JS side needs of a chapter mark.
    private static func describe(_ chapter: Chapter) -> NSDictionary {
        ["start": chapter.start, "title": chapter.title] as NSDictionary
    }
}

extension AudioRoute {
    /// The route the audio session is on now. Over HDMI the PCM channels are
    /// what the receiver advertises, often two over ARC, where a Dolby
    /// bitstream still carries 5.1; no other port hands one on to a receiver.
    static var current: AudioRoute {
        let session = AVAudioSession.sharedInstance()
        return AudioRoute(
            channels: Int32(session.maximumOutputNumberOfChannels),
            takesDolby: session.currentRoute.outputs.contains { $0.portType == .HDMI })
    }
}

/// An audio session activation, from the thread that runs it to the open
/// that waits for it. Unchecked because the semaphore orders the two:
/// `refusal` is written before the signal and read only after the wait.
private final class AudioActivation: @unchecked Sendable {
    let done = DispatchSemaphore(value: 0)
    var refusal: Error?
    var renderingMode = AVAudioSession.RenderingMode.notApplicable
}

/// One `preferredDisplayCriteria` write, watched until the screen has
/// answered it.
///
/// tvOS renegotiates HDMI on its own time and offers no getter for the mode
/// the display ended up in, so the answer is read where it shows: the display
/// link runs at the screen's own cadence, and `isDisplayModeSwitchInProgress`
/// says a renegotiation is still running. Neither is asked once, right after
/// the write, when the switch has not begun - both are read at every refresh
/// until one of them settles the question.
///
/// Built, ticked and stopped on the main thread; waited on from the player's
/// control queue, which the main thread must be free to tick past.
/// What the write on the main thread hands back to the queue waiting for it.
/// Unchecked because the semaphore is what orders the two: written before the
/// signal, read only after a successful wait, and never touched again.
private final class DisplayWrite: @unchecked Sendable {
    var watch: DisplaySwitchWatch?
    var note = "display left alone"
}

private final class DisplaySwitchWatch: NSObject {
    /// How a wait ended, in the words the open trace prints.
    enum Outcome: String {
        case switched = "display switched"
        case alreadyInMode = "display already in mode"
        case neverTook = "display never took the mode"
        case givenBack = "display given back"
        case neverSettled = "display never settled"
    }

    /// How long the screen is given to show any sign of the mode it was
    /// asked for before it is taken as one it will not take. Paid only by a
    /// display that ignores the request or lands somewhere else, and by one
    /// already in the mode, which has to stay quiet this long before it is
    /// taken as one: one that is renegotiating pushes this back for as long
    /// as it keeps at it.
    private static let graceSeconds = 0.5

    /// Half a frame a second, which is as fine as this can tell modes apart:
    /// 23.976 and 24 are one cadence to a display link, and to a projector.
    private static let toleranceHz = 0.5

    private let semaphore = DispatchSemaphore(value: 0)
    private let refreshRate: Double
    private weak var manager: AVDisplayManager?
    private var link: CADisplayLink?
    /// Written on the main thread before the signal, read off it only after
    /// a successful wait: the signal is what orders the two.
    private var outcome: Outcome?
    /// Whether the switch was ever seen running, which is what tells a
    /// display that renegotiated apart from one that was already there.
    private var sawSwitch = false
    /// The last moment the screen was seen doing something about the write.
    /// A display still renegotiating keeps pushing this back, so a slow one
    /// is never given up on for being slow.
    private var lastActivity: CFTimeInterval
    /// When the screen first ran at the film's cadence. Read after the wait,
    /// which the signal orders, and printed beside the outcome: the gap
    /// between this and the end of the wait is the cable's own share.
    private var cadenceAt: CFTimeInterval?
    /// The refresh the link was running at when it first matched: the
    /// screen's own answer to the request, to the precision of one frame
    /// period. Read after the wait, which the signal orders.
    private(set) var measuredRefreshHz: Double?
    private let startedAt: CFTimeInterval
    /// What tvOS says of the switch itself. Its end is the one sign the cable
    /// has settled: a change between 23.976 and 24 keeps the link's cadence,
    /// raises the flag for longer than the switch, and starts the switch
    /// proper seconds after the write, blanking the screen until its end.
    private var switchStarted = false
    private var switchEnded = false
    private var observers: [NSObjectProtocol] = []

    init(manager: AVDisplayManager, refreshRate: Float) {
        self.manager = manager
        self.refreshRate = Double(refreshRate)
        startedAt = CACurrentMediaTime()
        lastActivity = startedAt
        super.init()
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .AVDisplayManagerModeSwitchStart, object: nil, queue: .main) { [weak self] _ in
                self?.switchStarted = true
            },
            // an end only counts for a start seen here, not a switch before the write
            center.addObserver(forName: .AVDisplayManagerModeSwitchEnd, object: nil, queue: .main) { [weak self] _ in
                guard let self, self.switchStarted else { return }
                self.switchEnded = true
            },
        ]
    }

    /// Blocks until the screen has answered or `seconds` pass. Never called
    /// from the main thread: the answer arrives on it.
    func wait(seconds: Double) -> Outcome {
        guard semaphore.wait(timeout: .now() + seconds) == .success else {
            // the link is the main thread's to invalidate, and this wait is
            // over whatever the screen goes on to do
            DispatchQueue.main.async { self.finish(.neverSettled) }
            return .neverSettled
        }
        return outcome ?? .neverSettled
    }

    /// How long the Apple TV itself took to change cadence, which is the
    /// share of the wait that was not the cable's. Read only once the watch
    /// has stopped.
    var cadenceDelayMilliseconds: Double? {
        guard let cadenceAt else { return nil }
        return (cadenceAt - startedAt) * 1000
    }

    /// Ends the wait early, for a playback that no longer wants the mode.
    /// Main thread only.
    func release() {
        finish(.givenBack)
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let manager else {
            // the window went with the view: there is no display left to wait on
            finish(.givenBack)
            return
        }
        // The cadence is read before the flag, never behind it: tvOS holds
        // the switch open for the whole handshake while the screen has been
        // running at the film's cadence since early in it, and asking the
        // flag first hides that answer behind the slowest party on the cable.
        // Twice the film's rate is the film's cadence too: a screen that
        // offers 50 and not 25 shows each picture on two refreshes, evenly.
        if link.duration > 0, cadenceAt == nil,
            [1.0, 2.0].contains(where: {
                abs(1 / link.duration - $0 * refreshRate) <= DisplaySwitchWatch.toleranceHz
            }) {
            cadenceAt = link.timestamp
            measuredRefreshHz = 1 / link.duration
        }
        if switchEnded {
            finish(.switched)
            return
        }
        // A switch under way is waited out to its end, whatever the cadence
        // and the flag say meanwhile: the deadline is what bounds it.
        guard !switchStarted, !manager.isDisplayModeSwitchInProgress else {
            sawSwitch = true
            lastActivity = link.timestamp
            return
        }
        // A cadence already right is not the answer yet when the switch was
        // never seen: a write that changes only the range keeps the cadence,
        // and tvOS raises the flag some refreshes after it. Taken as a mode
        // the screen was already in only once the grace has passed quiet.
        if let cadenceAt {
            if sawSwitch {
                finish(.switched)
            } else if link.timestamp - cadenceAt >= DisplaySwitchWatch.graceSeconds {
                finish(.alreadyInMode)
            }
            return
        }
        if link.duration > 0, link.timestamp - lastActivity >= DisplaySwitchWatch.graceSeconds {
            finish(.neverTook)
        }
    }

    /// Stops before it signals, so nothing touches this watch's state after
    /// the thread waiting on it has been let go. Idempotent: the first
    /// answer is the one the wait gets.
    private func finish(_ outcome: Outcome) {
        guard self.outcome == nil else { return }
        link?.invalidate()
        link = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        self.outcome = outcome
        semaphore.signal()
    }
}

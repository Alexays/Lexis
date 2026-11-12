import AVFoundation
import CoreMedia
import Darwin
import Foundation
import QuartzCore
import os
import Synchronization

/// Where the subtitle paths say what they gave up on. A styled track that falls
/// back to plain text loses every colour, position and sign the script carries,
/// and nothing else in the pipeline would ever mention it.
let subtitleLog = Logger(subsystem: "org.lexis.player", category: "subtitles")

private let machTicksToSeconds: Double = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return Double(info.numer) / (Double(info.denom) * 1_000_000_000)
}()

/// Seconds on the host clock. This is the clock CoreMedia calls the host time
/// clock, so a display layer's timebase (`start(atPresentation:)` below) and
/// anything else that times against it agree.
public func hostTimeSeconds() -> Double {
    Double(mach_absolute_time()) * machTicksToSeconds
}

/// Where the pipeline hands finished samples. The tvOS app enqueues into an
/// AVSampleBufferDisplayLayer and an audio renderer that share one clock;
/// tests count instead of playing.
public protocol FrameSink: AnyObject {
    /// The display layer declares extended range only on the passthrough
    /// path; the tone-mapped one hands the renderer an already-mapped
    /// picture and must not ask for more range than that picture carries.
    func setWantsExtendedDynamicRange(_ value: Bool)
    /// Set once the renderer refuses what it was handed: a passthrough
    /// packet the route will not carry. Read from the reader thread; nil
    /// while nothing has gone wrong.
    var audioPassthroughError: String? { get }
    /// Whether a picture has actually reached the screen, as opposed to
    /// samples having been accepted. The only honest reading of that on the
    /// passthrough path, where nothing here decodes: `status` reports
    /// `.rendering` with no error for a working codec, for one with no
    /// decoder on the host and for a fourcc that does not exist alike,
    /// measured. False until the renderer has a first frame ready.
    var hasDisplayedPicture: Bool { get }
    /// Set once the renderer says it could not decode a sample, and held
    /// until the next flush throws those samples away - one sink plays every
    /// film, so a verdict kept past them would be the last film's.
    var videoDecodeFailure: String? { get }
    /// Where the sink's clock stands, in stream time.
    var presentationTime: Double { get }
    /// Starts the sink's clock at the first frame's presentation time.
    func start(atPresentation seconds: Double)
    /// The same, `lead` seconds from now rather than the sink's own lead.
    func start(atPresentation seconds: Double, lead: Double)
    /// Moves the stopped clock to `seconds` and leaves it stopped, which is
    /// what a seek with no frame to feed yet has to report as its position.
    func anchor(atPresentation seconds: Double)
    /// Stops (0) or resumes (1) the sink's clock where it stands. Called from
    /// the reader thread while it holds its own lock, so it must not call back
    /// into the player.
    func setRate(_ rate: Float)
    func enqueue(_ sampleBuffer: CMSampleBuffer)
    func enqueueAudio(_ sampleBuffer: CMSampleBuffer)
    /// Hands the sink a cue to show once the clock reaches it. Called from the
    /// reader thread, which runs ahead of that moment.
    func enqueueSubtitle(_ cue: SubtitleCue)
    /// Drops what both renderers are holding, the cues with them, and the
    /// styled events too: this is the whole of a seek's flush, and the reason
    /// neither seek path has to take the styled events back by hand.
    /// `keepingImage` leaves the last displayed frame on screen, which is what
    /// a seek wants: removing it flashes the screen black between the two
    /// positions.
    func flush(keepingImage: Bool)
    /// Drops the audio the renderer holds and leaves the clock, the picture and
    /// the cues alone, which is what an audio track switch needs.
    func flushAudio()
    /// Drops every cue, shown or waiting: a seek, or a subtitle track switch.
    func flushSubtitles()
    /// Starts drawing an ASS/SSA track through libass, off the caller's thread:
    /// building the renderer loads every font. `header` is the track's codec
    /// extradata and `fonts` are whole font files the container carried.
    /// `completion` runs once, never on the libass queue; false means libass
    /// did not take the track, or a stop or a later start came first, and the
    /// caller should draw it as text instead.
    func startStyled(
        header: Data, fonts: [Data], canvasWidth: Int, canvasHeight: Int,
        completion: @escaping (Bool) -> Void
    )
    /// Takes the text cue clock down and forgets that a cue ever arrived: a
    /// track turned off or handed to libass owes the main queue nothing more.
    func stopCues()
    /// Stops drawing it and frees what libass held. Safe when nothing started.
    func stopStyled()
    /// One dialogue line, exactly as the container gave it. Called from the
    /// reader thread, which runs ahead of the moment it belongs to.
    func enqueueStyled(event: Data, start: Double, duration: Double)
    /// Drops every event, on screen or not: a seek, or a track switch.
    func flushStyled()
    /// The sink calls `provider` on `queue` whenever it wants more video; the
    /// provider answers nil when the queue is dry, and the sink stops asking
    /// until `resumeVideoIfIdle` says there is more. This is
    /// requestMediaDataWhenReady, abstracted so tests can pull too.
    func requestVideo(on queue: DispatchQueue, provider: @escaping () -> CMSampleBuffer?)
    func requestAudio(on queue: DispatchQueue, provider: @escaping () -> CMSampleBuffer?)
    /// Cancels both requests. Safe to call when neither was ever made.
    func stopRequestingMedia()
    /// Re-arms the video request once the provider that went dry has more to
    /// give: the renderer only re-invokes its own block on a not-ready-to-
    /// ready transition, never merely because a provider that returned nil
    /// would now answer differently, so the caller has to say so itself
    /// after every push that could have broken that drought. A no-op when
    /// the request is not currently dry.
    func resumeVideoIfIdle()
    /// The audio request's own reading of `resumeVideoIfIdle`.
    func resumeAudioIfIdle()
    /// The most stream seconds the renderer may hold ahead of its clock, nil
    /// for no bound: decoded pictures wait in the renderer until they come
    /// due, and the memory budget pays for only so many of them.
    func setVideoRunwayLimit(_ seconds: Double?)
    /// What the renderer would like a decoded picture allocated with, so a
    /// picture the pipeline makes lands on its optimized compositing path
    /// rather than being copied onto it. Empty where the sink has no view.
    var recommendedPictureAttributes: [String: Any] { get }
    /// Whether every video sample from here on arrives in presentation
    /// order: true on the paths that decode here and reorder, false on the
    /// passthrough path, where compressed samples arrive in decode order.
    /// A renderer told so can skip its own reordering bookkeeping.
    func setPresentationOrderIsMonotonic(_ value: Bool)
    /// The period between two of the stream's frames, or nil where the
    /// container states no rate: how often a subtitle has to be looked at to
    /// change on the frame it belongs to.
    func setFramePeriod(_ seconds: Double?)
    /// The white subtitles are drawn at, 1 the layer's own: see
    /// `SubtitleOverlay.white`.
    func setSubtitleWhite(_ white: CGFloat)
    /// Told the stream time at which the audio route dropped what the renderer
    /// held on its own (a route change): the sound from there has to be handed
    /// over again. Called on no particular thread; nil takes the handler away.
    func setAudioRouteFlushHandler(_ handler: ((Double) -> Void)?)
}

extension FrameSink {
    /// A sink with no lead of its own to stretch starts as it always does.
    func start(atPresentation seconds: Double, lead: Double) {
        start(atPresentation: seconds)
    }
}

public extension FrameSink {
    func setVideoRunwayLimit(_ seconds: Double?) {}
    func stopCues() {}
    var recommendedPictureAttributes: [String: Any] { [:] }
    func setPresentationOrderIsMonotonic(_ value: Bool) {}
    func setFramePeriod(_ seconds: Double?) {}
    func setSubtitleWhite(_ white: CGFloat) {}
    func setAudioRouteFlushHandler(_ handler: ((Double) -> Void)?) {}
}

/// Where the video request's delivery timing is recorded, off unless a
/// measurement installs one.
///
/// What it records is RUNWAY, not the gap between two enqueues. A late
/// delivery into a renderer still holding half a second of pictures is
/// invisible; the same delivery into one holding nothing is a frame that
/// misses its slot. Runway is stream seconds already enqueued and still
/// ahead of the clock, so it reaches zero exactly when the renderer runs
/// out of picture to show - which is the failure, and the only figure that
/// says whether a given stall was ever seen.
public final class FrameDeliveryRecorder {
    public enum Mark: UInt8 {
        /// A sample crossed into the renderer.
        case enqueued
        /// The provider answered nil, so the request tore itself down.
        case wentDry
        /// A push re-registered the request after a drought.
        case rearmed
    }

    public struct Sample {
        public let mark: Mark
        public let hostSeconds: Double
        /// Stream seconds enqueued and not yet shown. Zero or less means the
        /// renderer has nothing left for the clock's current position.
        public let runwaySeconds: Double
        /// Whether the renderer would still take more at this moment. A pump
        /// that stopped with this false stopped on backpressure, which is the
        /// healthy reason; with it true, the provider is what ran out.
        public let rendererWantsMore: Bool
    }

    private let lock = NSLock()
    private var samples: [Sample] = []

    public init(expectedSamples: Int = 4096) {
        samples.reserveCapacity(expectedSamples)
    }

    func record(_ mark: Mark, runway: Double, wantsMore: Bool) {
        let sample = Sample(
            mark: mark, hostSeconds: hostTimeSeconds(),
            runwaySeconds: runway, rendererWantsMore: wantsMore
        )
        lock.lock()
        samples.append(sample)
        lock.unlock()
    }

    public var recorded: [Sample] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }
}

/// Counts the blocks the sink's clock observers put on the main queue over a
/// playback. Off unless a measurement installs one.
public final class MainBlockCounter {
    private let lock = NSLock()
    private var value = 0

    public init() {}

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

public final class DisplayLayerSink: FrameSink {
    public let layer: AVSampleBufferDisplayLayer
    /// Owns the timing. Public because it is also the anchor for any other
    /// renderer that has to stay in step with the video.
    public let synchronizer = AVSampleBufferRenderSynchronizer()
    /// Attached in init and never later: AVFoundation requires an audio
    /// renderer to join its synchronizer before its first enqueue, and its
    /// presence is what makes the audio device's clock the master.
    public let audioRenderer = AVSampleBufferAudioRenderer()

    /// Everything goes through `sampleBufferRenderer` and the synchronizer: the
    /// layer's own enqueue/flush/controlTimebase are deprecated and unsafe to
    /// call from the reader thread, and the two models must not be mixed.
    private let renderer: AVSampleBufferVideoRenderer
    /// The two renderers as the synchronizer hands them back: every sample
    /// goes in through `enqueue`, which waits for room itself and answers
    /// for what became of the sample, and every failure comes out of the
    /// same object's rendering events.
    private let videoReceiver: AVSampleBufferVideoRenderer.Receiver
    private let audioReceiver: AVSampleBufferAudioRenderer.Receiver

    /// Subtitles have no renderer and no clock of their own: they are drawn by
    /// a layer above the picture, on the timebase everything else follows.
    private let overlay = SubtitleOverlay()

    /// How much room whatever the host draws over the picture is taking at the
    /// bottom of the layer, in points: a cue that would fall inside that band
    /// is lifted clear of it. Main thread only, like everything else about the
    /// overlay's own layer tree.
    public var subtitleLift: CGFloat {
        get { overlay.lift }
        set { overlay.lift = newValue }
    }

    /// Seconds every subtitle shows after the time the track gives it,
    /// negative for before. Read by both cue clocks on every tick.
    public var subtitleOffset: Double {
        get { Double(bitPattern: subtitleOffsetBits.load(ordering: .relaxed)) }
        set {
            subtitleOffsetBits.store(newValue.bitPattern, ordering: .relaxed)
            DispatchQueue.main.async { [weak self] in self?.refreshCueTiming() }
            styledQueue.async { [weak self] in
                guard let self else { return }
                self.updateStyled(at: self.synchronizer.currentTime().seconds)
            }
        }
    }
    private let subtitleOffsetBits = Atomic<UInt64>(0)

    private let audioRouteFlushLock = NSLock()
    private var audioRouteFlushHandler: ((Double) -> Void)?

    public func setAudioRouteFlushHandler(_ handler: ((Double) -> Void)?) {
        audioRouteFlushLock.lock()
        audioRouteFlushHandler = handler
        audioRouteFlushLock.unlock()
    }

    public func setSubtitleWhite(_ white: CGFloat) {
        DispatchQueue.main.async { [overlay] in overlay.white = white }
        styledQueue.async { [self] in
            styledWhite = white
            styledRenderer?.setWhite(white)
        }
    }
    /// Cues arrive in stream order from the reader thread and wait here for
    /// their moment.
    private let subtitleLock = NSLock()
    private var pendingCues: [SubtitleCue] = []
    private var shownCue: SubtitleCue?
    /// Every cue whose moment has come and not gone, oldest first: dialogue
    /// lines may overlap, and `shownCue` is all of them as one.
    private var activeCues: [SubtitleCue] = []
    /// Bumped whenever `shownCue` changes, under `subtitleLock`: what tells a
    /// tick with something new to draw from one that would hand the overlay
    /// the same cue again, without comparing the cues' bitmaps.
    private var shownCueSerial = 0
    /// The serial and the bounds the overlay last drew, main thread only. A
    /// serial of -1 draws whatever is next, whatever it is.
    private var drawnCueSerial = -1
    private var drawnCueBounds = CGRect.null
    private var subtitleObserver: Any?
    /// One lock per side, guarding what that side's `requestVideo`/
    /// `requestAudio` registered and whether it has gone dry since. Each is
    /// held across its own provider call in `pumpVideo`/`pumpAudio`, not only
    /// around the flag, so a push landing on another thread either lands
    /// before the pop that would have seen it (and the pump keeps draining)
    /// or blocks on that lock until idle is actually set (and then wakes it)
    /// - never the gap in between, where a `resumeIfIdle` finding idle still
    /// false could otherwise no-op and leave the pump dry with a sample
    /// waiting.
    ///
    /// They must stay separate. A provider is allowed to block for as long as
    /// its own track is starved, and one lock over both sides turns that into
    /// a stall the pipeline cannot leave: video parked in its provider locks
    /// audio's pump out, audio's sample then packet queue fill behind it, the
    /// one demux thread parks on the audio queue, and the video packet queue
    /// it also feeds runs dry - so the video starvation that started it can
    /// never refill. Measured on the tvOS app: one frame on screen, forever.
    private let videoRequestLock = NSLock()
    private var videoQueue: DispatchQueue?
    private var videoProvider: (() -> CMSampleBuffer?)?
    private var videoIdle = false
    /// Bumped by every `resumeVideoIfIdle`, whether or not it finds the pump
    /// parked. A pump calls its provider with no lock held - the provider is
    /// allowed to wait out a whole starvation in there, and holding the lock
    /// across it parks the very decode threads whose pushes end that wait -
    /// so a push landing between a nil answer and the pump reading it back
    /// would otherwise be missed, and the pump would park on an answer that
    /// was already stale. The pump re-reads this before parking and asks
    /// again instead when it has moved.
    private var videoWakeups = 0
    /// The pump, parked on a dry provider until `resumeVideoIfIdle` lets it
    /// go. Under `videoRequestLock`.
    private var videoWaiter: CheckedContinuation<Void, Never>?
    /// The task that asks the provider and hands the renderer what it gives.
    /// One per `requestVideo`; cancelled by the next one and by
    /// `stopRequestingMedia`. Under `videoRequestLock`.
    private var videoPump: Task<Void, Never>?

    /// Installed by a measurement; nil in every shipping playback, where the
    /// whole cost of this is one nil check per frame.
    public var deliveryRecorder: FrameDeliveryRecorder?
    /// Installed by a measurement; nil in every shipping playback.
    public var mainBlockCounter: MainBlockCounter?
    /// Presentation time of the last sample handed to the renderer, which with
    /// the synchronizer's own clock is what `runway` measures against. Under
    /// `videoRequestLock`.
    private var lastEnqueuedPTS: Double?
    /// Bumped by every flush of the video renderer, under `videoRequestLock`:
    /// a sample the pump took before a flush and records after it would
    /// otherwise leave `lastEnqueuedPTS` at the position a seek left, and a
    /// backward seek would read as a runway of the whole distance.
    private var videoFlushes = 0
    /// What `setVideoRunwayLimit` asked for. Under `videoRequestLock`.
    private var videoRunwayLimit: Double?
    /// The host time the last frame was placed at by `placedOnRefresh`, nil
    /// after a flush or a clock re-anchor. Under `videoRequestLock`.
    private var lastRefreshSlot: Double?
    /// The luma bands of the last picture placed, under `videoRequestLock`.
    private var lastBands: SIMD16<Float>?
    /// Frames placed since the last phase line. Under `videoRequestLock`.
    private var placedSincePhaseTrace = 0
    private static let tracesRefreshPhase = ProcessInfo.processInfo.environment["LEXIS_TRACE_FILE"] == "1"

    /// Stream seconds enqueued and still ahead of the clock. Nil before the
    /// first frame, and while the clock is stopped there is no slot to miss.
    private var runwaySeconds: Double {
        guard let lastEnqueuedPTS else { return 0 }
        return lastEnqueuedPTS - synchronizer.currentTime().seconds
    }
    private let audioRequestLock = NSLock()
    private var audioQueue: DispatchQueue?
    private var audioProvider: (() -> CMSampleBuffer?)?
    private var audioIdle = false
    /// The audio pump's own reading of `videoWakeups`.
    private var audioWakeups = 0
    private var audioWaiter: CheckedContinuation<Void, Never>?
    private var audioPump: Task<Void, Never>?
    /// Why the audio renderer refused what it was handed, under
    /// `audioFailureLock`: a route that will not carry a compressed format
    /// says so on the enqueue that offered it. Cleared by `flushAudio`, which
    /// is what lets the renderer take samples again.
    private let audioFailureLock = NSLock()
    private var audioFailure: String?

    /// libass is not thread-safe, and a track's first render is slow enough to
    /// drop a frame, so it does not run on the main queue. Everything libass
    /// owns lives behind this one, and it is the process's single libass queue
    /// rather than one per sink: two sinks drawing and freeing at once is the
    /// case `-DHB_NO_MT` forbids.
    private let styledQueue = AssRenderer.sharedQueue
    /// Touched on styledQueue only.
    private var styledRenderer: AssRenderer?
    /// The subtitle white a renderer built later starts at. On styledQueue only.
    private var styledWhite: CGFloat = 1
    /// Under `styledLock`: three callers install and remove it.
    private var styledObserver: Any?
    /// Bumped by every stop, and so by every start, under `styledLock`: a
    /// build that finds it moved was stopped before it could be installed.
    private var styledStarts: UInt64 = 0
    /// The generation this sink last put on screen. On styledQueue only.
    private var publishedGeneration: UInt64 = 0
    private let styledLock = NSLock()
    private var shownStyled: SubtitleImage?
    /// The canvas `shownStyled` was rendered against, and whether a main-queue
    /// block is already on its way to draw it, both under `styledLock`: that
    /// block draws whatever is latest when it runs, so a burst of generations
    /// costs one block and one upload rather than one of each per bitmap.
    private var shownStyledCanvas: CGSize = .zero
    private var styledDrawPending = false
    /// The pixel size styled glyphs are rasterized at: the layer's bounds at
    /// its own contents scale. Zero until the layer has been laid out, which
    /// leaves libass at the video's canvas - the old behavior - until the
    /// first real size is known.
    private let renderSizeLock = NSLock()
    private var styledRenderSize: CGSize = .zero
    /// True from the first cue this sink is ever handed. Every clock
    /// transition below checks it: an anchor or a seek on a film with no
    /// subtitle track owes the main queue nothing.
    private var cueEverArrived = false

    /// Under `decodeFailureLock`. The first refusal is the one kept: a dead
    /// decoder refuses every sample and the hundredth says nothing the first
    /// did not.
    private let decodeFailureLock = NSLock()
    private var decodeFailure: String?
    /// The two rendering event streams, read for the life of the sink: what a
    /// renderer has to say after an enqueue has already been answered - a
    /// decode that failed later, the system taking the decoder back, a route
    /// that changed under the sound.
    private var videoEvents: Task<Void, Never>?
    private var audioEvents: Task<Void, Never>?
    /// What the engine last promised about sample order. A flush resets the
    /// renderer's own expectation, so it is stated again after every one.
    /// Under `videoRequestLock`.
    private var presentationOrderIsMonotonic = false
    /// The screen's own refresh, watched at a low rate for the life of the
    /// sink: when the last refresh happened on the host clock and how long
    /// one lasts, which is what a clock set running lines its frames up
    /// against. Written on the main thread by the link, read under
    /// `vsyncLock` from wherever the clock is started.
    private var vsyncLink: CADisplayLink?
    private let vsyncLock = NSLock()
    private var lastVsyncHostSeconds: Double?
    private var vsyncPeriodSeconds: Double?
    /// The stream's frame period, from the engine; nil where unknown. Under
    /// `vsyncLock`.
    private var framePeriodSeconds: Double?
    /// How far ahead of now a stopped clock is set running. Every start
    /// follows a hold in which the pull thread handed the renderer nothing,
    /// so it has this long to hand over the frames after the one on screen
    /// before they come due.
    private static let startLeadSeconds = 0.05

    public init(layer: AVSampleBufferDisplayLayer) {
        self.layer = layer
        renderer = layer.sampleBufferRenderer
        // The reader paces off its own clock, so a silently deferred rate
        // change would leave the two anchors describing different moments.
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
        // Joined here and never later: AVFoundation requires an audio
        // renderer to join its synchronizer before its first enqueue, and its
        // presence is what makes the audio device's clock the master.
        videoReceiver = synchronizer.sampleBufferReceiver(adding: renderer)
        audioReceiver = synchronizer.sampleBufferReceiver(adding: audioRenderer)
        overlay.layer.contentsScale = layer.contentsScale
        // Beside the video layer, above it, never inside it: a display layer
        // with a sublayer is one the compositor draws itself, frame by frame
        // on its own schedule, instead of handing the pictures to the
        // display's video plane. Measured: not one frame in a film took the
        // optimized path with the overlay inside, and a screen processing
        // the signal cannot lock onto pictures paced by the compositor.
        if let parent = layer.superlayer {
            parent.insertSublayer(overlay.layer, above: layer)
        } else {
            layer.addSublayer(overlay.layer)
        }
        DispatchQueue.main.async { [weak self] in self?.startVsyncWatch() }
        videoEvents = Task { [weak self] in
            guard let events = self?.videoReceiver.renderingEventsAfterFinishedEnqueuing else { return }
            for await event in events { self?.handle(event) }
        }
        audioEvents = Task { [weak self] in
            guard let events = self?.audioReceiver.renderingEventsAfterFinishedEnqueuing else { return }
            for await event in events { self?.handle(event) }
        }
    }

    private func handle(_ event: AVSampleBufferVideoRenderer.Receiver.RenderingEvent) {
        switch event {
        case .didFailToDecode(let errors):
            noteDecodeFailure(errors.first)
        case .failed(let error):
            noteDecodeFailure(error)
        case .requiresFlushToResumeDecoding:
            resumeDecoding()
        @unknown default:
            break
        }
    }

    private func handle(_ event: AVSampleBufferAudioRenderer.Receiver.RenderingEvent) {
        switch event {
        case .failed(let error):
            noteAudioFailure(error)
        case .wasFlushedAutomatically(let time):
            // The route flushed the sound itself: what was queued past this
            // moment is gone, and the pipeline hands it over again.
            traceLine(String(format: "[lexis.audio] route flushed itself at %.2f s", time.seconds))
            audioRouteFlushLock.lock()
            let handler = audioRouteFlushHandler
            audioRouteFlushLock.unlock()
            handler?(time.seconds)
        case .outputConfigurationChanged:
            traceLine("[lexis.audio] output configuration changed")
        @unknown default:
            break
        }
    }

    /// tvOS takes the video decoder back whenever the app stops being what is
    /// on screen, and says so through the renderer: every sample handed to it
    /// is refused until a flush lets decoding resume.
    ///
    /// The audio renderer is not affected, which is the whole shape of the
    /// bug this answers: a film left paused while the viewer visits the shelf
    /// comes back playing its sound over a black screen, and a seek only
    /// surfaces the refusal that was already standing.
    ///
    /// Not `flush(keepingImage:)`, which belongs to a seek and stops the clock
    /// with it: here the clock, the sound and the subtitles are all still
    /// right, and it is the picture alone that has to be let back in.
    private func resumeDecoding() {
        videoReceiver.flush()
        forgetEnqueuedVideo()
        restatePresentationOrder()
        // The pump parks itself when the renderer refuses samples, and
        // nothing else would ever wake it: this flush is what made room.
        resumeVideoIfIdle()
    }

    private func noteDecodeFailure(_ error: Error?) {
        decodeFailureLock.lock()
        if decodeFailure == nil {
            decodeFailure = error?.localizedDescription ?? "the renderer could not decode"
        }
        decodeFailureLock.unlock()
    }

    private func noteAudioFailure(_ error: Error) {
        audioFailureLock.lock()
        if audioFailure == nil { audioFailure = error.localizedDescription }
        audioFailureLock.unlock()
    }

    public var recommendedPictureAttributes: [String: Any] {
        renderer.recommendedPixelBufferAttributes.rawAttributes
    }

    public func setVideoRunwayLimit(_ seconds: Double?) {
        videoRequestLock.lock()
        videoRunwayLimit = seconds
        videoRequestLock.unlock()
    }

    public func setPresentationOrderIsMonotonic(_ value: Bool) {
        videoRequestLock.lock()
        presentationOrderIsMonotonic = value
        videoRequestLock.unlock()
        restatePresentationOrder()
    }

    /// The renderer holds nothing ahead of the clock once flushed.
    private func forgetEnqueuedVideo() {
        videoRequestLock.lock()
        lastEnqueuedPTS = nil
        lastRefreshSlot = nil
        videoFlushes &+= 1
        videoRequestLock.unlock()
    }

    /// The renderer forgets the promise on every flush; this is what says it
    /// again. Nothing is promised on the passthrough path: its samples are
    /// in decode order, and a promise broken by a B frame costs the picture.
    private func restatePresentationOrder() {
        videoRequestLock.lock()
        let monotonic = presentationOrderIsMonotonic
        videoRequestLock.unlock()
        renderer.presentationTimeExpectation = monotonic ? .monotonicallyIncreasing : .none
    }

    /// Installs the cue clock, once, the first time a cue arrives.
    ///
    /// A periodic observer and not a boundary at the next edge, which is what
    /// this was. A boundary has to be re-armed after every fire and after
    /// every enqueue, and the read-ahead delivers subtitles in bursts of
    /// dozens: each one added an observer and removed the one before it, and
    /// a boundary replaced just before its own deadline never fires at all.
    /// Nothing else wakes this path, so the cue sat there - late, or stuck on
    /// screen past its end - until the next packet happened to arrive. Which
    /// is why it showed on SRT and not on the styled path, whose clock ticks
    /// on its own.
    ///
    /// A tick a frame (`cueTickInterval`) bounds the error at one frame, and
    /// costs a main-queue block whose work is a lock and a comparison - the
    /// overlay is not touched when nothing changed. Installed on the first
    /// cue rather than at start, because a film with subtitles off must not
    /// pay for a single one of those blocks.
    private func startCueClock() {
        subtitleLock.lock()
        let already = subtitleObserver != nil
        subtitleLock.unlock()
        guard !already else { return }
        let observer = synchronizer.addPeriodicTimeObserver(
            forInterval: cueTickInterval, queue: .main
        ) { [weak self] time in
            guard let self else { return }
            self.mainBlockCounter?.increment()
            self.updateSubtitle(at: time.seconds)
        }
        subtitleLock.lock()
        // two enqueues can race here; the loser's observer is removed rather
        // than left ticking, and never double-removed
        let loser = subtitleObserver == nil ? nil : observer
        if subtitleObserver == nil { subtitleObserver = observer }
        subtitleLock.unlock()
        if let loser { synchronizer.removeTimeObserver(loser) }
    }

    public func stopCues() {
        subtitleLock.lock()
        let observer = subtitleObserver
        subtitleObserver = nil
        cueEverArrived = false
        subtitleLock.unlock()
        if let observer { synchronizer.removeTimeObserver(observer) }
    }

    /// Main thread only: re-evaluates what is on screen now. Counted like a
    /// tick of the clock above, because that is what it is - one main-queue
    /// block of subtitle work, however it was summoned.
    private func refreshCueTiming() {
        mainBlockCounter?.increment()
        updateSubtitle(at: synchronizer.currentTime().seconds)
    }

    deinit {
        if let subtitleObserver {
            synchronizer.removeTimeObserver(subtitleObserver)
        }
        if let styledObserver {
            synchronizer.removeTimeObserver(styledObserver)
        }
        videoEvents?.cancel()
        audioEvents?.cancel()
        videoPump?.cancel()
        audioPump?.cancel()
        // the link is the main run loop's, and the last release can land anywhere
        if let vsyncLink { DispatchQueue.main.async { vsyncLink.invalidate() } }
    }

    /// A display link at a few frames a second, which is all it takes to
    /// know where the screen's refreshes fall: `timestamp` is the last one
    /// on the host clock and `duration` the period, and a refresh is
    /// periodic between two readings. Main thread only, like every link.
    private func startVsyncWatch() {
        // No link on the macOS the tests run on: a link there belongs to a
        // view or a screen, and nothing here has one. The phase then reads
        // nil and the clock starts where it always did.
        #if !os(macOS)
        let target = VsyncTarget()
        target.sink = self
        let link = CADisplayLink(target: target, selector: #selector(VsyncTarget.tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 2, maximum: 4, preferred: 4)
        link.add(to: .main, forMode: .common)
        vsyncLink = link
        #endif
    }

    /// What the link holds in the sink's place: a display link keeps its
    /// target until invalidated, and the sink invalidates it only in deinit.
    private final class VsyncTarget: NSObject {
        weak var sink: DisplayLayerSink?
        @objc func tick(_ link: CADisplayLink) { sink?.vsyncTick(link) }
    }

    private func vsyncTick(_ link: CADisplayLink) {
        // The link's own callback cadence is what was asked for above; the
        // duration is still the screen's refresh period, not the callback's.
        guard link.duration > 0 else { return }
        vsyncLock.lock()
        lastVsyncHostSeconds = link.timestamp
        vsyncPeriodSeconds = link.duration
        vsyncLock.unlock()
    }

    public func setFramePeriod(_ seconds: Double?) {
        vsyncLock.lock()
        framePeriodSeconds = seconds
        vsyncLock.unlock()
    }

    /// How often the subtitle clocks tick: once a frame, so a cue changes on
    /// the frame it belongs to, and never more than 30 times a second, which
    /// a 60 fps film would otherwise double for no visible gain.
    private var cueTickInterval: CMTime {
        vsyncLock.lock()
        let framePeriod = framePeriodSeconds
        vsyncLock.unlock()
        return CMTime(seconds: max(framePeriod ?? 1.0 / 30, 1.0 / 30), preferredTimescale: 90_000)
    }

    /// The host time a stopped clock reaches its anchor at: `startLeadSeconds`
    /// from now, then on so the first frame after the anchor, `toNextFrame`
    /// host seconds past it, lands in the middle of a refresh period. That
    /// frame, and every one after it on a screen running at the film's rate,
    /// falls halfway between two refreshes, where clock jitter cannot decide
    /// which of the two shows it.
    private func runningHostTime(toNextFrame: Double = 0, lead: Double = DisplayLayerSink.startLeadSeconds) -> CMTime {
        var host = hostTimeSeconds() + lead + toNextFrame
        vsyncLock.lock()
        let vsync = lastVsyncHostSeconds
        let period = vsyncPeriodSeconds
        vsyncLock.unlock()
        if let vsync, let period {
            let middle = vsync + period / 2
            host = middle + ((host - middle) / period).rounded(.up) * period
        }
        return CMTime(seconds: host - toNextFrame, preferredTimescale: 1_000_000_000)
    }

    /// Where on the host clock a frame due at `frameHost` is shown from: the
    /// middle of a refresh, as `runningHostTime` lines the first one up. The
    /// clock is the audio device's and the refresh is the screen's, so after
    /// that first frame the two drift apart, and a frame time left to drift
    /// onto a refresh edge is one the renderer's jitter shows a refresh early
    /// or late: a drop and a repeat, more often the closer it gets.
    ///
    /// A frame keeps the slot `refreshesPerFrame` after `previous` while its
    /// own time is within three quarters of a refresh of it, so the frame
    /// grid moves against the refreshes one whole refresh at a time, once
    /// per refresh of drift. A frame due in the same refresh as the one
    /// before goes a quarter refresh after it: still that refresh, so the
    /// renderer drops the earlier one, and the times keep increasing.
    /// At a cut, where a frame shown twice or not at all does not show, the
    /// grid moves as soon as the frame sits nearer another refresh.
    static func refreshSlot(
        frameHost: Double, previous: Double?, vsync: Double, period: Double, refreshesPerFrame: Double,
        atCut: Bool = false
    ) -> Double {
        let middle = vsync + period / 2
        let nearest = middle + ((frameHost - middle) / period).rounded() * period
        guard let previous else { return nearest }
        let expected = middle + ((previous + refreshesPerFrame * period - middle) / period).rounded() * period
        if abs(frameHost - expected) <= (atCut ? 0.5 : 0.75) * period { return expected }
        return nearest > previous ? nearest : previous + period / 4
    }

    /// A picture's luma histogram in 16 bands off a 32 by 18 grid, which a cut
    /// changes and a pan mostly does not; nil for a store not plainly readable.
    static func lumaBands(of picture: CVPixelBuffer) -> SIMD16<Float>? {
        let format = CVPixelBufferGetPixelFormatType(picture)
        let tenBit = format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            || format == kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
        guard tenBit || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            CVPixelBufferLockBaseAddress(picture, .readOnly) == kCVReturnSuccess
        else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(picture, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(picture, 0) else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(picture, 0), height = CVPixelBufferGetHeightOfPlane(picture, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(picture, 0)
        var bands = SIMD16<Float>()
        for y in 0..<18 {
            let row = base.advanced(by: stride * ((2 * y + 1) * height / 36))
            for x in 0..<32 {
                let at = (2 * x + 1) * width / 64
                // ten bit codes sit in the top bits of each sample
                let code = tenBit ? Int(row.assumingMemoryBound(to: UInt16.self)[at] >> 6)
                    : Int(row.assumingMemoryBound(to: UInt8.self)[at]) * 4
                bands[min(max((code - 64) * 16 / 876, 0), 15)] += 1.0 / 576
            }
        }
        return bands
    }

    /// How far the luma bands move, zero to two, past which a picture starts
    /// a new shot.
    static let cutBandsMoved: Float = 0.8

    /// `sample` retimed onto `refreshSlot`, or untouched where there is no
    /// slot per frame: a stopped clock, an unknown refresh or frame rate, a
    /// screen not refreshing a whole number of times per frame, or samples
    /// in decode order.
    private func placedOnRefresh(_ sample: CMSampleBuffer, unlessFlushedSince flushes: Int) -> CMSampleBuffer {
        let rate = Double(synchronizer.rate)
        vsyncLock.lock()
        let vsync = lastVsyncHostSeconds
        let period = vsyncPeriodSeconds
        let framePeriod = framePeriodSeconds
        vsyncLock.unlock()
        guard rate > 0, let vsync, let period, let framePeriod, period > 0 else { return sample }
        let refreshes = (framePeriod / rate / period).rounded()
        guard refreshes >= 1, abs(framePeriod / rate - refreshes * period) < period * 0.005 else { return sample }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        guard pts.isNumeric else { return sample }
        let frameHost = CMSyncConvertTime(pts, from: synchronizer.timebase, to: CMClockGetHostTimeClock()).seconds
        let bands = CMSampleBufferGetImageBuffer(sample).flatMap(DisplayLayerSink.lumaBands(of:))
        videoRequestLock.lock()
        guard presentationOrderIsMonotonic, videoFlushes == flushes else {
            videoRequestLock.unlock()
            return sample
        }
        let previous = lastRefreshSlot
        var atCut = false
        if let bands {
            if let lastBands {
                atCut = (bands - lastBands).replacing(with: lastBands - bands, where: bands .< lastBands).sum()
                    > DisplayLayerSink.cutBandsMoved
            }
            lastBands = bands
        }
        let slot = DisplayLayerSink.refreshSlot(
            frameHost: frameHost, previous: previous, vsync: vsync, period: period, refreshesPerFrame: refreshes,
            atCut: atCut)
        lastRefreshSlot = slot
        placedSincePhaseTrace += 1
        let phaseDue = DisplayLayerSink.tracesRefreshPhase && placedSincePhaseTrace >= 1440
        if phaseDue { placedSincePhaseTrace = 0 }
        videoRequestLock.unlock()
        // The phase is where the frame grid stands against the refreshes on
        // its own: its drift over a playback is the drift between the clocks.
        let phase = ((frameHost - vsync) / period).truncatingRemainder(dividingBy: 1)
        if let previous, abs(slot - previous - refreshes * period) > period / 2 {
            traceLine(String(
                format: "[lexis.render] refresh slot moved at %.3f s: %@ %@, phase %.3f, offset %.1f ms",
                pts.seconds, slot - previous < refreshes * period ? "drop" : "repeat", atCut ? "at a cut" : "mid shot",
                phase < 0 ? phase + 1 : phase, (slot - frameHost) * 1000))
        } else if phaseDue {
            traceLine(String(
                format: "[lexis.render] refresh phase %.3f at %.1f s, offset %.1f ms",
                phase < 0 ? phase + 1 : phase, pts.seconds, (slot - frameHost) * 1000))
        }
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTimeAdd(
                pts, CMTime(seconds: (slot - frameHost) * rate, preferredTimescale: 1_000_000_000)),
            decodeTimeStamp: .invalid)
        var placed: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault, sampleBuffer: sample, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleBufferOut: &placed
        ) == noErr, let placed else { return sample }
        return placed
    }

    /// Stream seconds the renderer holds ahead of the clock: what the last
    /// sample handed to it was timed at, less where the clock stands.
    public var videoRunwaySeconds: Double {
        videoRequestLock.lock()
        defer { videoRequestLock.unlock() }
        return runwaySeconds
    }

    private var lastEnqueuedAudioPTS: Double?

    public var audioRunwaySeconds: Double {
        audioRequestLock.lock()
        defer { audioRequestLock.unlock() }
        guard let lastEnqueuedAudioPTS else { return 0 }
        return lastEnqueuedAudioPTS - synchronizer.currentTime().seconds
    }

    /// Where the clock stands in stream and host seconds, read together, so
    /// two readings say how fast the clock ran between them.
    public var clockReading: (stream: Double, host: Double, rate: Float) {
        (synchronizer.currentTime().seconds, CMClockGetTime(CMClockGetHostTimeClock()).seconds,
         synchronizer.rate)
    }

    public func setWantsExtendedDynamicRange(_ value: Bool) {
        layer.preferredDynamicRange = value ? .high : .standard
    }

    public var audioPassthroughError: String? {
        audioFailureLock.lock()
        defer { audioFailureLock.unlock() }
        return audioFailure
    }

    public var hasDisplayedPicture: Bool {
        layer.isReadyForDisplay
    }

    public var videoDecodeFailure: String? {
        decodeFailureLock.lock()
        defer { decodeFailureLock.unlock() }
        return decodeFailure
    }

    /// What the renderer itself counts, over its whole life: the frames it
    /// was handed, the ones it dropped for arriving after their time, and
    /// how late the frames it did show added up to. The one reading of a
    /// dropped frame the passthrough path has, since nothing in this process
    /// ever sees those pictures; the delay is what tells a pipeline running
    /// behind (delay grows with the drops) from a clock drifting against the
    /// screen (drops with no delay). `completion` runs on an AVFoundation
    /// thread with nil where the platform cannot say.
    public func loadRendererMetrics(
        _ completion: @escaping (
            (displayed: Int, dropped: Int, delaySeconds: Double, optimized: Int)?
        ) -> Void
    ) {
        renderer.loadVideoPerformanceMetrics { metrics in
            completion(metrics.map {
                ($0.totalNumberOfFrames, $0.numberOfDroppedFrames, $0.totalAccumulatedFrameDelay,
                 $0.numberOfFramesDisplayedUsingOptimizedCompositing)
            })
        }
    }

    public var presentationTime: Double {
        synchronizer.currentTime().seconds
    }

    /// The cue the clock has selected, which the overlay draws on the next main
    /// queue turn: this runs ahead of the screen rather than reading it.
    public var shownSubtitle: SubtitleCue? {
        subtitleLock.lock()
        defer { subtitleLock.unlock() }
        return shownCue
    }

    /// Pins stream time to host time so each sample is shown when its pts comes
    /// due. That mapping is what reorders B frames, and it runs on the same
    /// host clock hostTimeSeconds() reads.
    public func start(atPresentation seconds: Double) {
        start(atPresentation: seconds, lead: DisplayLayerSink.startLeadSeconds)
    }

    public func start(atPresentation seconds: Double, lead: Double) {
        synchronizer.setRate(
            1.0, time: CMTime(seconds: seconds, preferredTimescale: 90_000),
            atHostTime: runningHostTime(lead: lead)
        )
        videoRequestLock.lock()
        lastRefreshSlot = nil
        videoRequestLock.unlock()
        // A pump parked on a full runway waits for the clock to move it.
        resumeVideoIfIdle()
        // After the clock is set, not before: a start is rare, but it runs on
        // the pull thread at the moment the renderer most needs feeding.
        traceLine(String(format: "[lexis.render] clock start at %.3f s", seconds))
    }

    public func anchor(atPresentation seconds: Double) {
        synchronizer.setRate(0, time: CMTime(seconds: seconds, preferredTimescale: 90_000))
        // the clock just jumped to `seconds`: whatever is due there shows now,
        // and the boundary re-arms from the new position - a seek while
        // stopped makes a subtitle appear without any playback, which is the
        // contract the cue timing has always had. Nothing owed when no cue
        // ever arrived: a subtitle-free film anchors several times and pays
        // none of this.
        if cueEverArrived {
            DispatchQueue.main.async { [self] in
                refreshCueTiming()
            }
        }
    }

    /// A stopped clock set running again takes the same lead a start does:
    /// the pull thread fed nothing while it stood. It stopped between two
    /// frames, so the frame grid is found again from the last frame enqueued
    /// and the next frame on it is what the refresh is lined up against.
    public func setRate(_ rate: Float) {
        guard rate != 0, synchronizer.rate == 0 else {
            synchronizer.rate = rate
            return
        }
        let now = synchronizer.currentTime()
        videoRequestLock.lock()
        let lastFrame = lastEnqueuedPTS
        // the clock is lined up on the refreshes again below
        lastRefreshSlot = nil
        videoRequestLock.unlock()
        vsyncLock.lock()
        let framePeriod = framePeriodSeconds
        vsyncLock.unlock()
        var toNextFrame = 0.0
        if let lastFrame, let framePeriod, framePeriod > 0 {
            let offset = (lastFrame - now.seconds).truncatingRemainder(dividingBy: framePeriod)
            toNextFrame = (offset < 0 ? offset + framePeriod : offset) / Double(rate)
        }
        synchronizer.setRate(rate, time: now, atHostTime: runningHostTime(toNextFrame: toNextFrame))
        // A pump parked on a full runway waits for the clock to move it.
        resumeVideoIfIdle()
    }

    /// Straight in, without waiting for room: what a caller outside the pump
    /// hands over is a single frame it wants shown now.
    public func enqueue(_ sampleBuffer: CMSampleBuffer) {
        _ = videoReceiver.enqueueImmediately(CMReadySampleBuffer(unsafeBuffer: sampleBuffer))
    }

    public func enqueueAudio(_ sampleBuffer: CMSampleBuffer) {
        _ = audioReceiver.enqueueImmediately(CMReadySampleBuffer(unsafeBuffer: sampleBuffer))
    }

    /// One task asks the provider, on `queue`, and hands the renderer what it
    /// gives: `enqueue` itself waits for room, which is the renderer's own
    /// backpressure, and answers for what became of the sample. A provider
    /// that answers nil parks the task until `resumeVideoIfIdle` says there
    /// is more - never a flush, never the renderer becoming ready again.
    public func requestVideo(on queue: DispatchQueue, provider: @escaping () -> CMSampleBuffer?) {
        videoRequestLock.lock()
        videoQueue = queue
        videoProvider = provider
        videoIdle = false
        let previous = videoPump
        let waiter = videoWaiter
        videoWaiter = nil
        // Started under the lock, so the pump never reads its own slot as
        // empty and refuses to park on its first dry answer.
        videoPump = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.pumpVideo()
        }
        videoRequestLock.unlock()
        previous?.cancel()
        waiter?.resume()
    }

    public func requestAudio(on queue: DispatchQueue, provider: @escaping () -> CMSampleBuffer?) {
        audioRequestLock.lock()
        audioQueue = queue
        audioProvider = provider
        audioIdle = false
        let previous = audioPump
        let waiter = audioWaiter
        audioWaiter = nil
        audioPump = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.pumpAudio()
        }
        audioRequestLock.unlock()
        previous?.cancel()
        waiter?.resume()
    }

    /// The provider is called on the caller's own queue, where it is allowed
    /// to block for as long as its track is starved; the task only waits for
    /// the answer, and a cancellation lands at the next await.
    private func pumpVideo() async {
        while !Task.isCancelled {
            guard let (provider, queue, wakeups, flushes, runwayExcess) = videoRequest() else { return }
            if runwayExcess > 0 {
                // Not asked until the clock has eaten into the runway. Running,
                // that is a known wait, capped so a flush is seen soon; stopped,
                // only the clock starting again moves it, and starting it wakes
                // the pump the way a push does.
                let rate = Double(synchronizer.rate)
                if rate > 0 {
                    let wait = min(max(runwayExcess / rate, 0.004), 0.05)
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                } else {
                    await parkVideo(unless: wakeups)
                }
                continue
            }
            let sample: CMSampleBuffer? = await withCheckedContinuation { continuation in
                queue.async { continuation.resume(returning: provider()) }
            }
            if Task.isCancelled { return }
            guard let sample else {
                await parkVideo(unless: wakeups)
                continue
            }
            // Noted as placed: a clock set running again lines up on the
            // times the renderer actually holds.
            let placed = placedOnRefresh(sample, unlessFlushedSince: flushes)
            noteVideoEnqueued(placed, unlessFlushedSince: flushes)
            let result: AVSampleBufferVideoRenderer.Receiver.EnqueueResult
            do {
                result = try await videoReceiver.enqueue(CMReadySampleBuffer(unsafeBuffer: placed))
            } catch {
                // Only a cancellation throws: this pump is being stopped.
                return
            }
            switch result {
            case .enqueued:
                break
            case .enqueuedWithDecodeFailures(let errors):
                noteDecodeFailure(errors.first)
            case .cancelledDueToFlush:
                // A flush took it on the way in; the provider's next answer
                // belongs to whatever position the flush was for.
                break
            case .cancelledDueToFlushRequiredToResume:
                resumeDecoding()
            case .cancelledDueToError(let error):
                // A renderer refusing outright refuses every sample: draining
                // the queue into it would only throw the film away faster.
                // Parked until a flush, or a stop, says otherwise.
                noteDecodeFailure(error)
                await parkVideo(unless: wakeups)
            @unknown default:
                break
            }
        }
    }

    /// What the video pump asks with, read under the lock in one go, or nil
    /// once `stopRequestingMedia` has taken the request away. `runwayExcess`
    /// is how far the renderer's runway stands past its limit, 0 or less
    /// when there is room.
    private func videoRequest() -> (
        provider: () -> CMSampleBuffer?, queue: DispatchQueue, wakeups: Int, flushes: Int,
        runwayExcess: Double
    )? {
        videoRequestLock.lock()
        defer { videoRequestLock.unlock() }
        guard let provider = videoProvider, let queue = videoQueue else { return nil }
        let excess = videoRunwayLimit.map { runwaySeconds - $0 } ?? 0
        return (provider, queue, videoWakeups, videoFlushes, excess)
    }

    private func audioRequest() -> (provider: () -> CMSampleBuffer?, queue: DispatchQueue, wakeups: Int)? {
        audioRequestLock.lock()
        defer { audioRequestLock.unlock() }
        guard let provider = audioProvider, let queue = audioQueue else { return nil }
        return (provider, queue, audioWakeups)
    }

    private func noteVideoEnqueued(_ sample: CMSampleBuffer, unlessFlushedSince flushes: Int) {
        videoRequestLock.lock()
        if videoFlushes == flushes {
            lastEnqueuedPTS = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        }
        let recorder = deliveryRecorder
        let runway = recorder == nil ? 0 : runwaySeconds
        videoRequestLock.unlock()
        recorder?.record(.enqueued, runway: runway, wantsMore: true)
    }

    private func pumpAudio() async {
        while !Task.isCancelled {
            guard let (provider, queue, wakeups) = audioRequest() else { return }
            let sample: CMSampleBuffer? = await withCheckedContinuation { continuation in
                queue.async { continuation.resume(returning: provider()) }
            }
            if Task.isCancelled { return }
            guard let sample else {
                await parkAudio(unless: wakeups)
                continue
            }
            audioRequestLock.lock()
            lastEnqueuedAudioPTS = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            audioRequestLock.unlock()
            let result: AVSampleBufferAudioRenderer.Receiver.EnqueueResult
            do {
                result = try await audioReceiver.enqueue(CMReadySampleBuffer(unsafeBuffer: sample))
            } catch {
                return
            }
            switch result {
            case .enqueued, .cancelledDueToFlush:
                break
            case .enqueuedWithSuggestedFlush(let reasons):
                // The route moved under the sound. The samples already in are
                // played out as they stand; what follows is timed against the
                // same clock either way.
                traceLine("[lexis.audio] renderer suggests a flush: \(reasons)")
            case .cancelledDueToError(let error):
                // The route will not carry this format. The reader reads the
                // reason, rebuilds the track through the decoder and flushes
                // here, which is what wakes this pump again.
                noteAudioFailure(error)
                await parkAudio(unless: wakeups)
            @unknown default:
                break
            }
        }
    }

    /// Parks the video pump until a `resumeVideoIfIdle` newer than `wakeups`:
    /// a push that landed while the provider was answering is already in
    /// the queue, and parking on that stale nil would leave it there.
    private func parkVideo(unless wakeups: Int) async {
        guard markVideoIdle(unless: wakeups) else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            holdVideo(continuation)
        }
    }

    private func parkAudio(unless wakeups: Int) async {
        guard markAudioIdle(unless: wakeups) else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            holdAudio(continuation)
        }
    }

    /// False when a resume already landed since `wakeups`, or the pump is
    /// being stopped: there is nothing to park for.
    private func markVideoIdle(unless wakeups: Int) -> Bool {
        videoRequestLock.lock()
        guard videoWakeups == wakeups, videoPump != nil else {
            videoRequestLock.unlock()
            return false
        }
        videoIdle = true
        let recorder = deliveryRecorder
        let runway = recorder == nil ? 0 : runwaySeconds
        videoRequestLock.unlock()
        recorder?.record(.wentDry, runway: runway, wantsMore: true)
        return true
    }

    private func markAudioIdle(unless wakeups: Int) -> Bool {
        audioRequestLock.lock()
        defer { audioRequestLock.unlock() }
        guard audioWakeups == wakeups, audioPump != nil else { return false }
        audioIdle = true
        return true
    }

    /// Keeps the parked pump's continuation for `resumeVideoIfIdle`, unless
    /// a resume landed between marking idle and this: it found idle, cleared
    /// it, and has no waiter left to wake, so the pump goes straight on.
    private func holdVideo(_ continuation: CheckedContinuation<Void, Never>) {
        videoRequestLock.lock()
        guard videoIdle, videoPump != nil else {
            videoRequestLock.unlock()
            continuation.resume()
            return
        }
        videoWaiter = continuation
        videoRequestLock.unlock()
    }

    private func holdAudio(_ continuation: CheckedContinuation<Void, Never>) {
        audioRequestLock.lock()
        guard audioIdle, audioPump != nil else {
            audioRequestLock.unlock()
            continuation.resume()
            return
        }
        audioWaiter = continuation
        audioRequestLock.unlock()
    }

    public func resumeVideoIfIdle() {
        videoRequestLock.lock()
        videoWakeups &+= 1
        guard videoIdle else {
            videoRequestLock.unlock()
            return
        }
        videoIdle = false
        let waiter = videoWaiter
        videoWaiter = nil
        let recorder = deliveryRecorder
        let runway = recorder == nil ? 0 : runwaySeconds
        videoRequestLock.unlock()
        recorder?.record(.rearmed, runway: runway, wantsMore: true)
        waiter?.resume()
    }

    public func resumeAudioIfIdle() {
        audioRequestLock.lock()
        audioWakeups &+= 1
        guard audioIdle else {
            audioRequestLock.unlock()
            return
        }
        audioIdle = false
        let waiter = audioWaiter
        audioWaiter = nil
        audioRequestLock.unlock()
        waiter?.resume()
    }

    /// Cancels both pumps. A pump parked on a dry provider is let go so the
    /// cancellation reaches it; one waiting on its provider returns the
    /// moment the provider does.
    public func stopRequestingMedia() {
        videoRequestLock.lock()
        let video = videoPump
        videoPump = nil
        let videoWaiter = self.videoWaiter
        self.videoWaiter = nil
        videoIdle = false
        videoRequestLock.unlock()
        video?.cancel()
        videoWaiter?.resume()
        audioRequestLock.lock()
        let audio = audioPump
        audioPump = nil
        let audioWaiter = self.audioWaiter
        self.audioWaiter = nil
        audioIdle = false
        audioRequestLock.unlock()
        audio?.cancel()
        audioWaiter?.resume()
    }

    public func enqueueSubtitle(_ cue: SubtitleCue) {
        subtitleLock.lock()
        pendingCues.append(cue)
        cueEverArrived = true
        subtitleLock.unlock()
        startCueClock()
        // Only while the clock is stopped, where the observer above does not
        // fire: a cue that arrives during a pause, or between a seek's flush
        // and play resuming, would otherwise wait for a rate it has no reason
        // to expect. Running it every time would be what the boundary did -
        // a main-queue hop per packet, dozens at once behind the read-ahead -
        // to learn something the next tick reports anyway.
        guard synchronizer.rate == 0 else { return }
        DispatchQueue.main.async { [self] in
            self.refreshCueTiming()
        }
    }

    public func flush(keepingImage: Bool) {
        synchronizer.rate = 0
        // The refusal belonged to the samples being thrown away here, and one
        // sink plays every film this app opens: kept, it would be the last
        // film's verdict standing over the next one. A renderer still
        // refusing says so again on the very next sample it is handed.
        decodeFailureLock.lock()
        decodeFailure = nil
        decodeFailureLock.unlock()
        if keepingImage {
            videoReceiver.flush()
        } else {
            // The only flush the receiver does asynchronously; nothing here
            // waits on it, the same as before: a stop has nothing to feed
            // behind it, and the next open is seconds away.
            let receiver = videoReceiver
            Task { await receiver.flush(removingDisplayedImage: true) }
        }
        forgetEnqueuedVideo()
        restatePresentationOrder()
        flushAudio()
        flushSubtitles()
        flushStyled()
    }

    /// Drops what the audio renderer holds, and the refusal it stood on: a
    /// renderer that refused a format takes samples again after this, and the
    /// reader has rebuilt the track for the format it will take.
    public func flushAudio() {
        audioReceiver.flush()
        audioFailureLock.lock()
        audioFailure = nil
        audioFailureLock.unlock()
    }

    public func flushSubtitles() {
        subtitleLock.lock()
        pendingCues.removeAll()
        shownCue = nil
        activeCues.removeAll()
        shownCueSerial &+= 1
        subtitleLock.unlock()
        // a layer tree belongs to the main thread, and the caller is the reader
        DispatchQueue.main.async { [self] in
            // the boundary only exists where cues ever did: a film with no
            // subtitle track pays this flush's show(nil) and nothing more
            if cueEverArrived {
                refreshCueTiming()
            }
            overlay.show(nil, in: layer.bounds)
            // The overlay no longer shows what the refresh above drew.
            drawnCueSerial = -1
        }
    }

    /// What the styled path last put on screen, for the same reason
    /// `shownSubtitle` exists: a test reads the decision, not the pixels.
    public var shownStyledSubtitle: SubtitleImage? {
        styledLock.lock()
        defer { styledLock.unlock() }
        return shownStyled
    }

    /// Never call this, or `stopStyled`, from `styledQueue`: both wait on it.
    /// Three things drive them and the caller must serialize all three: a track
    /// selection, that selection failing over to the text path, and `close()`.
    /// `styledObserver` is taken and cleared under `styledLock` so that a race
    /// can at worst leave an observer running, never remove one twice, which
    /// AVFoundation treats as a programmer error.
    public func startStyled(
        header: Data, fonts: [Data], canvasWidth: Int, canvasHeight: Int,
        completion: @escaping (Bool) -> Void
    ) {
        stopStyled()
        styledLock.lock()
        let start = styledStarts
        styledLock.unlock()
        styledQueue.async { [self] in
            publishedGeneration = 0
            styledLock.lock()
            let wanted = styledStarts == start
            styledLock.unlock()
            var built: AssRenderer?
            if wanted {
                do {
                    built = try AssRenderer(
                        header: header, fonts: fonts,
                        canvasWidth: canvasWidth, canvasHeight: canvasHeight
                    )
                } catch {
                    // A track libass will not draw is not a failure of the film,
                    // but the caller draws it as plain text and nothing on screen
                    // says so: this is the only trace the reason leaves.
                    subtitleLog.error(
                        "libass refused the track: \(String(describing: error), privacy: .public)"
                    )
                }
            }
            // Off this queue: the caller answers with a stop or a start, and
            // both wait on it.
            guard let built else {
                DispatchQueue.global(qos: .userInitiated).async { completion(false) }
                return
            }
            built.setWhite(styledWhite)
            styledRenderer = built
            // The same tick the cue path follows, on the same timebase,
            // delivered on the queue that owns libass instead of on main.
            let observer = synchronizer.addPeriodicTimeObserver(
                forInterval: cueTickInterval, queue: styledQueue
            ) { [weak self] time in
                self?.updateStyled(at: time.seconds)
            }
            // A stop landing while this built took its observer before there
            // was one: this start is the one left to take both down.
            styledLock.lock()
            let kept = styledStarts == start
            if kept { styledObserver = observer }
            styledLock.unlock()
            if !kept {
                synchronizer.removeTimeObserver(observer)
                styledRenderer = nil
            }
            DispatchQueue.global(qos: .userInitiated).async { completion(kept) }
        }
    }

    public func stopStyled() {
        // taken and cleared in one step: two of these must not hand the same
        // token to removeTimeObserver. The bump tells a build still queued
        // that it has been stopped.
        styledLock.lock()
        styledStarts &+= 1
        let observer = styledObserver
        styledObserver = nil
        styledLock.unlock()
        if let observer {
            synchronizer.removeTimeObserver(observer)
        }
        // removeTimeObserver may return while a block is still running, and
        // that block is the only other thing that touches the renderer; the
        // barrier is what makes freeing it here safe.
        styledQueue.sync { styledRenderer = nil }
        styledLock.lock()
        shownStyled = nil
        styledLock.unlock()
        DispatchQueue.main.async { [self] in
            overlay.showStyled(nil, canvas: .zero, frameCanvas: .zero, in: layer.bounds)
        }
    }

    public func enqueueStyled(event: Data, start: Double, duration: Double) {
        styledQueue.async { [self] in
            styledRenderer?.process(event: event, start: start, duration: duration)
        }
    }

    public func flushStyled() {
        styledQueue.async { [self] in
            styledRenderer?.flush()
            // The screen goes now rather than at the next tick: a stop leaves
            // the clock frozen, so there may not be a next tick.
            publishedGeneration = styledRenderer?.generation ?? 0
            publishStyled(nil)
        }
    }

    /// The overlay is a sibling of the video layer, so its frame is the
    /// video layer's, taken again each time it draws: the host lays the
    /// video layer out, and nothing lays the overlay out but this.
    private func placeOverlay() {
        if overlay.layer.superlayer !== layer, overlay.layer.frame != layer.frame {
            overlay.layer.frame = layer.frame
        }
    }

    private func updateSubtitle(at clock: Double) {
        let seconds = clock - subtitleOffset
        placeOverlay()
        subtitleLock.lock()
        var changed = false
        var due = 0
        while due < pendingCues.count, pendingCues[due].start <= seconds {
            let first = pendingCues[due]
            due += 1
            // Only a stream with a canvas clears by emptiness: an empty display
            // set takes a bitmap off, an empty text event just draws nothing.
            // SubtitleDecoder.isGraphic is the exact test if a canvas ever lies.
            if first.isEmpty, first.canvasWidth == 0 { continue }
            // a display set replaces the screen, a line of dialogue joins it
            if first.canvasWidth > 0 { activeCues.removeAll() }
            activeCues.append(first)
            changed = true
        }
        pendingCues.removeFirst(due)
        let active = activeCues.count
        activeCues.removeAll { $0.end <= seconds || $0.isEmpty }
        if activeCues.count != active { changed = true }
        var next = activeCues.last
        if changed, activeCues.count > 1 {
            next = SubtitleCue(
                start: activeCues[0].start, end: activeCues.map(\.end).min() ?? .infinity,
                lines: activeCues.flatMap(\.lines), images: activeCues.flatMap(\.images),
                canvasWidth: activeCues[0].canvasWidth, canvasHeight: activeCues[0].canvasHeight
            )
        } else if !changed {
            next = shownCue
        }
        shownCue = next
        if changed { shownCueSerial &+= 1 }
        let serial = shownCueSerial
        subtitleLock.unlock()
        // A resize is picked up by the next fire; at rate 0 there is no next
        // fire, which is why every clock move refreshes here too.
        let bounds = layer.bounds
        guard serial != drawnCueSerial || bounds != drawnCueBounds else { return }
        drawnCueSerial = serial
        drawnCueBounds = bounds
        overlay.show(next, in: bounds)
    }

    /// On the libass queue, once a tick while the clock runs and once more
    /// whenever a pause or a seek moves it: the same contract the cue
    /// observer has, and for the same reason.
    private func updateStyled(at clock: Double) {
        guard let renderer = styledRenderer else { return }
        let image = renderer.render(at: clock - subtitleOffset)
        // A generation is what tells a changed frame from an unchanged one.
        // Comparing the bitmaps would be a memcmp of up to six megabytes,
        // every tick, to learn that nothing moved.
        guard renderer.generation != publishedGeneration else { return }
        publishedGeneration = renderer.generation
        publishStyled(image)
    }

    /// Records the decision and puts it on screen. The layer tree belongs to
    /// the main thread and this runs on the libass queue, so the hop is not
    /// optional; at most one is in flight, and it draws the latest decision.
    private func publishStyled(_ image: SubtitleImage?) {
        let canvas = styledRenderer?.canvas ?? .zero
        styledLock.lock()
        shownStyled = image
        shownStyledCanvas = canvas
        let alreadyPending = styledDrawPending
        styledDrawPending = true
        styledLock.unlock()
        guard !alreadyPending else { return }
        DispatchQueue.main.async { [self] in
            placeOverlay()
            styledLock.lock()
            let image = shownStyled
            let canvas = shownStyledCanvas
            styledDrawPending = false
            styledLock.unlock()
            refreshStyledRenderSize(canvas: canvas)
            let frameCanvas = {
                renderSizeLock.lock()
                defer { renderSizeLock.unlock() }
                return styledRenderSize
            }()
            overlay.showStyled(image, canvas: canvas, frameCanvas: frameCanvas, in: layer.bounds)
        }
    }

    /// Main thread only. Picks up the pixel size of the picture inside the
    /// layer the first time it has one, and every time it moves after that,
    /// handing libass the frame size its glyphs are rasterized at. Until there
    /// is one, libass stays at the video's canvas.
    private func refreshStyledRenderSize(canvas: CGSize) {
        guard canvas.width > 0, canvas.height > 0 else { return }
        // The picture, not the layer: libass fills its whole frame, and the
        // overlay places the bitmap against the letterboxed picture.
        let picture = SubtitleOverlay.fit(canvas: canvas, in: layer.bounds)
        let scale = layer.contentsScale
        let pixels = CGSize(
            width: (picture.width * scale).rounded(), height: (picture.height * scale).rounded()
        )
        renderSizeLock.lock()
        let unchanged = pixels == styledRenderSize
        if !unchanged { styledRenderSize = pixels }
        renderSizeLock.unlock()
        guard !unchanged else { return }
        styledQueue.async { [self] in
            styledRenderer?.setFrameSize(width: Int(pixels.width), height: Int(pixels.height))
        }
    }
}


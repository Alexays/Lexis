import AVFoundation
import CoreMedia
import Foundation
import VideoToolbox

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Every track a file offers and what is playing of it.
public struct TrackList: Sendable, Equatable {
    public let audio: [MediaStream]
    public let subtitle: [MediaStream]
    /// The stream index being played, or -1.
    public let selectedAudio: Int32
    /// The stream index being shown, or -1.
    public let selectedSubtitle: Int32
    /// The container's own chapter marks, empty when it carries none.
    public let chapters: [Chapter]

    public init(
        audio: [MediaStream], subtitle: [MediaStream],
        selectedAudio: Int32, selectedSubtitle: Int32, chapters: [Chapter] = []
    ) {
        self.audio = audio
        self.subtitle = subtitle
        self.selectedAudio = selectedAudio
        self.selectedSubtitle = selectedSubtitle
        self.chapters = chapters
    }
}

public enum VideoDynamicRange: String, Sendable, Equatable {
    case sdr
    case hdr10
    case hlg
    case dolbyVision
}

public enum PlayerEvent: Sendable, Equatable {
    case opened(width: Int32, height: Int32, codec: String)
    /// Sent once an open settles, and again whenever a selection changes.
    case tracks(TrackList)
    /// Once, the instant the first frame after an open or a completed seek
    /// is handed to the sink (or, on the tone-mapped path, to the mapper -
    /// an approximation of "displayed", not vsync-accurate, but the
    /// closest signal the reader has without a callback from the renderer
    /// itself). `seconds` is that frame's own presentation time.
    case firstFrame(seconds: Double)
    case playing
    case paused
    case stopped
    case endOfStream
    case failed(String)
    case unauthorized
    /// The film needs more memory in flight than the operating system will
    /// still give this process. Its own case rather than a `.failed` string,
    /// the same way `.unauthorized` is: what a viewer is told about a film
    /// this device cannot hold is not the sentence for one that would not
    /// open.
    case tooLargeForMemory(requiredBytes: Int, allowedBytes: Int)
    /// A starved buffer paused playback; `bufferedSeconds` is the reading
    /// that crossed the low watermark. Playback resumes on its own once the
    /// buffer refills - reported as `.playing` again, the same event a
    /// user-driven resume already uses.
    case buffering(bufferedSeconds: Double)
}

public struct PlaybackStats: Sendable, Equatable {
    public var packetsRead = 0
    public var framesDisplayed = 0
    /// Frames that reached the sink after the clock had passed them: a decode
    /// slower than the film. The pipeline copes by skipping the pictures
    /// nothing predicts from (`framesSkipped`), then by pausing and
    /// refilling (`rebufferCount`), so any reading above 0 here is a defect.
    public var framesDropped = 0
    /// Pictures nothing predicts from, left undecoded while the decoder ran
    /// behind the clock, so the rest of the film stayed on time.
    public var framesSkipped = 0
    /// Where the sink's clock stands, in seconds of stream time.
    public var position = 0.0
    /// What the container says the whole thing lasts; 0 when it does not say.
    public var duration = 0.0
    /// "pcm", "ac3" or "eac3": what is actually leaving the device. Nothing
    /// is, for the two that carry no sound at all - "none" for a film that
    /// has no audio track, "unsupported" for one whose track no decoder here
    /// answers for. Tokens the caller words for a viewer, never prose.
    public var audioFormat = "pcm"
    public var audioPassthrough = false
    /// The channels leaving the device: the track's own for a bitstream, at
    /// most what the route carries for PCM, 0 with no sound.
    public var audioChannels: Int32 = 0
    /// True when the route folds the decoded track down to fewer channels
    /// than it carries: what a setting outside Lexis may lift.
    public var audioRouteLimited = false
    /// Why the sound is not what the file asked for - a route that refused
    /// the format, or a decoder that refused a packet - and empty when it is.
    /// Set once per track and kept for the rest of it, so a decoder that
    /// recovered still leaves the record that it broke.
    public var audioFallbackReason = ""
    /// True when the video takes the passthrough path: the display layer
    /// decodes it, not the player, so `decodeSampleCount` and
    /// `hardwareAccelerationKnown` stay at their unmeasured defaults for the
    /// whole life of the file, not only until a frame happens to come back -
    /// there is no session here to ever read either one from. Set at open
    /// from the path the player chose, and again if a Dolby Vision path that
    /// showed nothing is turned round onto the mapped one: a structural fact
    /// about what is playing, never a measurement, the same way
    /// `audioPassthrough` is. Read with `dynamicRange`, it is also what tells
    /// a Dolby Vision film the display layer took from one it would not:
    /// `.dolbyVision` with this false is the film that had to be tone mapped.
    public var videoPassthrough = false
    /// The path the picture takes, the same fact with its reason: what a
    /// panel names where `videoPassthrough` only says no.
    public var videoPath: VideoPath = .passthrough
    /// The screen the path was decided against, as it read at the moment of
    /// deciding. Reportable because the decision is otherwise unfalsifiable
    /// from outside: a picture that was mapped when it should have been handed
    /// over looks like a badly graded film, and these two numbers are what
    /// tell the two apart.
    public var displayHeadroom: Float = 1
    public var displayEligibleForHDR = false
    public var displaySupportsDolbyVision = false
    /// True while the picture is being built bigger than the file carries
    /// it, by the upscaler. Structural, like the flag above.
    public var videoUpscaled = false
    /// The sample entry the video is described to the display layer or the
    /// decoder with: "dvh1" for a stream handed over as Dolby Vision, else
    /// "hvc1", "avc1" or "av01". Empty until a file is open. With
    /// `dynamicRange` this is what says whether tvOS sees Dolby Vision at all.
    public var videoDescription = ""
    /// The Dolby Vision profile the container declares, 0 where it declares
    /// none: a 7 that reads as HDR10 and an 8 that reads as Dolby Vision are
    /// both right, and only the profile says why.
    public var dolbyVisionProfile: Int32 = 0
    /// What the upscaled path renders at, or 0 when it is not taken: the
    /// stream's own width and height say what the file carries, and these say
    /// what it is being made into.
    public var upscaleWidth: Int32 = 0
    public var upscaleHeight: Int32 = 0
    public var decodeMillisecondsMean = 0.0
    public var decodeMillisecondsWorst = 0.0
    /// How many frames the two means above are computed over. 0 both before
    /// anything is timed and for a file whose video never goes through the
    /// tone-mapped path at all: the means read the same zero either way, and
    /// this is what a caller reads to tell "unmeasured" apart from "measured
    /// at zero".
    public var decodeSampleCount = 0
    /// What the tone map's or the enhancer's GPU passes cost, per picture:
    /// how many ran, and their mean and worst. 0 on a path with none.
    public var gpuPasses = 0
    public var gpuMillisecondsMean = 0.0
    public var gpuMillisecondsWorst = 0.0
    /// Read from a session that has actually decoded a frame, never inferred
    /// from timing and never from a session that merely exists - see
    /// `hardwareAccelerationKnown`, which is what tells the two apart.
    public var hardwareAccelerated = false
    /// True once `decodeSampleCount` is past zero: the answer is fixed for
    /// the life of a session, but reporting it the moment the session is
    /// built would state it as a fact about a file nothing has decoded yet.
    /// False before a file is open, on the passthrough path (no session here
    /// reads it back at all - a display layer decodes it, not the player),
    /// and for a file whose decoder never got built.
    public var hardwareAccelerationKnown = false
    /// Sustained bits/s the byte cache has fetched at, over its trailing
    /// window; 0 = UNMEASURED, before 4 MiB is fetched or before a file is
    /// open at all.
    public var ioSustainedBitsPerSecond = 0.0
    /// How long the byte cache's last real fetch took; 0 = UNMEASURED.
    public var ioFetchLatencySeconds = 0.0
    /// How many times a starved buffer paused playback and refilled it: the
    /// honest, counted alternative to dropping a frame.
    public var rebufferCount = 0
    /// Times the renderer asked for a picture and none was decoded, without
    /// the pipeline calling it a rebuffer: a stall too short to pause for.
    /// It counts on every path, including passthrough, where `framesDropped`
    /// cannot move at all.
    public var pictureStarvations = 0
    /// The combined buffer (packet queue plus sample queue, video and audio
    /// both), read live: what a viewer's own buffering indicator counts up
    /// from while it waits.
    public var bufferedSeconds = 0.0
    /// How long the last seek took, from the call that asked for it to its
    /// landed frame actually crossing the sink; 0 = UNMEASURED, before any
    /// seek has landed one.
    public var lastSeekLatencySeconds = 0.0
    /// Pictures the file carried that no route could turn into a frame: a
    /// decoder, a pool or a sample buffer refused them. Any reading above 0
    /// is a defect, the same way `framesDropped` is - and it comes with a
    /// `.failed`, because a film that cannot be decoded is a playback error
    /// the viewer is told about, not a film quietly played in part.
    public var decodeFailures = 0

    public init() {}
}

public protocol LexisPlayerAPI: AnyObject {
    func open(url: URL) throws
    func open(stream: MediaStreamIO) throws
    func play()
    func pause()
    /// Asks for the keyframe at or before `seconds`. Returns at once.
    func seek(to seconds: Double)
    var tracks: TrackList { get }
    /// What the open file is. `.sdr` when nothing is open.
    var dynamicRange: VideoDynamicRange { get }
    /// What the display should be asked to match, or nil when the open
    /// stream's frame rate could not be read.
    var displayCriteria: DisplayCriteriaRequest? { get }
    /// Plays another audio stream from where the clock stands. Returns at once.
    func selectAudioTrack(index: Int32)
    /// Shows another subtitle stream, or none at all for -1. Returns at once.
    func selectSubtitleTrack(index: Int32)
    func stop()
    func cancel()
    func close()
    var events: AsyncStream<PlayerEvent> { get }
    var stats: PlaybackStats { get }
    /// True once open() has committed a stream: `dynamicRange` and `stats`'s
    /// audio fields only carry a real reading from this point on. An open
    /// still probing a source (Plex over the network above all) has read
    /// nothing yet, and a caller must not report its defaults as one.
    var isOpen: Bool { get }
    var isCancelled: Bool { get }
}

/// Drives a `PlayerEngine` per play session: `open()` builds everything a
/// file needs once (the format description, the audio pipeline, the
/// tone-mapped session), and each `play()` that finds no engine alive builds
/// a fresh one over the same demuxer and hands it the already-chosen track
/// selection, mirroring the old reader's own thread-per-play-session shape.
public final class LexisPlayer: LexisPlayerAPI {
    public let events: AsyncStream<PlayerEvent>

    private let sink: FrameSink
    private let display: @Sendable () -> DisplayCapability
    private let continuation: AsyncStream<PlayerEvent>.Continuation

    /// Guards every piece of player state below.
    private let condition = NSCondition()
    private var demuxer: Demuxer?
    private var videoStream: MediaStream?
    private var audioStream: MediaStream?
    /// The same type `PlayerEngine` itself builds one of, from the same
    /// method: `audioPipeline(for:)` below is the one place a codec is
    /// weighed against what a compressed buffer needs, shared by an open and
    /// every track switch after it.
    private var audioPipeline: PlayerEngine.AudioPipeline?
    private var subtitleStream: MediaStream?
    private var subtitleDecoder: SubtitleDecoder?
    /// Set when the selected subtitle track is drawn by libass. Its packets go
    /// to the sink whole and never through a decoder, so `subtitleDecoder` is
    /// nil for the whole time this is true.
    private var subtitleIsStyled = false
    /// Orders subtitle selections against each other: a styled one finishes on
    /// whatever thread libass answers from, and an older one's answer must not
    /// undo a newer selection. Held across a whole commit, and by a selection
    /// only to take its number, so a newer one starts after an older one lands.
    private let subtitleSelectionLock = NSLock()
    /// Bumped by every selection, under `subtitleSelectionLock`.
    private var subtitleSelections: UInt64 = 0
    private var duration = 0.0
    private var formatDescription: CMVideoFormatDescription?
    /// Set when the display cannot show the picture as it is. Built once at
    /// open and reused by every engine a play() over this file builds.
    /// Built at open, read again when the engine is: the queues it sizes are
    /// created on the first play(), and a budget taken then would be reading a
    /// device the film has already started loading.
    private var budget: PipelineBudget?
    /// Fixed for this player's life: the queues it sizes and the watermarks
    /// it holds to must not change under a film that is already playing.
    private let policy: BufferPolicy
    private var toneMapped: ToneMappedVideo?
    /// What `toneMapped`'s own `enqueue` closure was actually built with: a
    /// weak, mutable hop to whichever engine is current. `ToneMappedVideo`
    /// takes its closure once, at construction, before any engine exists (a
    /// tone-mapped session is built at open, an engine only at the first
    /// play), and a picture it maps after a stop-then-play has to reach the
    /// NEW engine's queue, not a retired one's already-closed queue - which
    /// is exactly what updating this box at every engine build buys.
    private final class EngineBox {
        weak var engine: PlayerEngine?
    }
    private var engineBox: EngineBox?
    private var engine: PlayerEngine?
    /// Forwards the current engine's own event stream onto `continuation`,
    /// translating and applying it. Replaced, never appended to: exactly one
    /// runs per live engine.
    private var eventTask: Task<Void, Never>?
    /// Signalled once `eventTask`'s own `for await` loop ends. `stop()`
    /// waits on it after joining the engine's threads: a `Task` finishing
    /// its stream is not synchronized with anything else, and without this,
    /// the forwarding task can still hold the engine (and the `Demuxer` it
    /// owns) alive for a beat after `stop()` already returned - late enough
    /// that a caller reading a stream-close side effect right after
    /// `close()` returns sees it not yet having happened.
    private var eventTaskDrained: DispatchSemaphore?
    /// Bumped every time a new engine is built. An event this task reads is
    /// applied only if it still names the generation it was built under -
    /// what stops a previous engine's queued event, delivered after close()
    /// already reset the player's flags for a fresh open, from re-applying
    /// itself.
    private var engineGeneration = 0
    private var isPaused = false
    /// Set when the engine ran the stream out. The demuxer is still readable:
    /// a seek clears this and play() works again.
    private var didReachEnd = false
    /// Set when a stop, a cancel or a failure ended a stream-backed demuxer,
    /// or when the demuxer itself failed outright. A read the interrupt
    /// refused latches AVERROR_EXIT inside the AVIOContext and lowering the
    /// flag does not clear it, so only open() is the way back.
    private var isSpent = false
    /// Whether the current demuxer reads through a MediaStreamIO. Only those
    /// carry the interrupt, and only they are spent by a stop.
    private var readsThroughStream = false
    /// Set at open when this file's samples go to the display layer described
    /// as 'dvh1'. The one path with nowhere to go if the layer takes the
    /// session and shows nothing, and so the one the watchdog can act on.
    private var dolbyVisionCommitted = false
    /// Whether the description the decoder holds carries the Dolby Vision
    /// record, on 'dvh1' or beside an 'hvc1'. Under `condition`.
    private var recordHandedOver = false
    /// Stream time on the sink's own clock the picture watchdog is counting
    /// from - the presentation time of the first sample that crossed the
    /// sink, re-set by each landed frame. nil while nothing is being watched.
    /// Under `condition`'s lock.
    private var watchedFromPresentation: Double?
    /// Set the first time a picture is confirmed on screen, and then for the
    /// rest of the file: a seek re-anchors and fires `.firstFrame` again, and
    /// re-arming over a path already proven to work is exactly how a working
    /// film would be turned round by a flush that took its image away.
    private var pictureConfirmed = false
    private var pictureWatchdog: DispatchSourceTimer?
    private let watchdogQueue = DispatchQueue(label: "org.lexis.player.picture-watchdog")

    /// The screen the current file's path was decided against, recorded at
    /// adopt and at every turn-round: what a display change is compared to.
    /// Under `condition`'s lock.
    private var adoptedCapability: DisplayCapability?
    /// The screen-change observations this instance holds for its lifetime.
    private var displayObservers: [NSObjectProtocol] = []

    /// Raised by stop() and cancel(), lowered by play() and open(stream:).
    /// Raised, a demux operation gives up at its next cancellation point, so a
    /// stop does not wait out a stalled server.
    private let interrupt = InterruptFlag()

    /// True between a successful `PlaybackActivityGate.beginPlayer()` and the
    /// matching `endPlayer()`: this instance's own record of whether it is
    /// the one holding the gate, so `close()` releases it only when it does,
    /// never another instance's hold.
    private var holdsPlaybackGate = false

    private let statsLock = NSLock()
    private var currentStats = PlaybackStats()
    /// The last reading an engine ever produced, so `stats` still reports the
    /// final packet and frame counts once the engine that produced them is
    /// gone (end of stream, a stop, a failure) rather than reading the zero
    /// of a struct nothing has touched.
    private var lastEngineStatistics = EngineStatistics()

    /// `display` is asked once per open, which is what decides the path a
    /// file takes. It is a real input to that decision, not a knob: the
    /// default reads the screen the app is on, and a caller that names a
    /// display instead gets the same answer on any machine.
    ///
    /// `policy` is every span the engine reasons in. A film gets the standard
    /// one; a caller playing a clip orders of magnitude shorter states its
    /// own, so a rebuffer means the same fraction of the content either way.
    public init(
        sink: FrameSink,
        display: @escaping @Sendable () -> DisplayCapability = DisplayCapability.current,
        policy: BufferPolicy = .standard
    ) {
        self.sink = sink
        self.display = display
        self.policy = policy
        var escapee: AsyncStream<PlayerEvent>.Continuation!
        events = AsyncStream { escapee = $0 }
        continuation = escapee
        // On the watchdog's own queue, never the poster's: the turn-round
        // joins the engine's threads, and these notifications post on main.
        // The box is the Sendable hop for a class whose safety is its locks.
        final class Hop: @unchecked Sendable { weak var player: LexisPlayer? }
        let hop = Hop()
        hop.player = self
        let changed: @Sendable (Notification) -> Void = { _ in
            // Before the hop: the reading it takes must not be the one from
            // before the screens moved.
            DisplayCapability.screensChanged()
            guard let player = hop.player else { return }
            player.watchdogQueue.async { hop.player?.displayConfigurationChanged() }
        }
        #if canImport(AppKit)
        displayObservers = [
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil, queue: nil, using: changed
            )
        ]
        #elseif canImport(UIKit)
        // A screen appearing or disappearing, and - the one that matters on a
        // television - the attached display's own HDR modes changing. A
        // projector renegotiating HDMI from SDR to HDR is neither a connect
        // nor a disconnect, so without the third of these the path decided
        // before the switch stood for the whole film.
        var watched: [Notification.Name] = [
            UIScreen.didConnectNotification, UIScreen.didDisconnectNotification,
        ]
        #if os(tvOS)
        watched.append(AVPlayer.eligibleForHDRPlaybackDidChangeNotification)
        #endif
        displayObservers = watched.map {
            NotificationCenter.default.addObserver(
                forName: $0, object: nil, queue: nil, using: changed
            )
        }
        #endif
    }

    deinit {
        for observer in displayObservers { NotificationCenter.default.removeObserver(observer) }
        continuation.finish()
        // belt and braces: a caller that lets an open instance go without
        // calling close() first must not leave the gate held forever
        if holdsPlaybackGate { PlaybackActivityGate.shared.endPlayer() }
    }

    public var stats: PlaybackStats {
        condition.lock()
        var snapshot = currentStats
        let open = demuxer != nil
        snapshot.duration = duration
        let mapped = toneMapped
        let ioStatistics = demuxer?.ioStatistics
        let currentEngine = engine
        let adoptedScreen = adoptedCapability
        let audioChannels = audioStream?.channels ?? 0
        condition.unlock()

        // One reading, outside `statsLock`: it takes every queue's lock.
        let engineStatistics = currentEngine?.statistics
        statsLock.lock()
        if let engineStatistics {
            lastEngineStatistics = engineStatistics
        }
        let frozen = lastEngineStatistics
        statsLock.unlock()
        if let screen = adoptedScreen {
            snapshot.displayHeadroom = screen.headroom
            snapshot.displayEligibleForHDR = screen.eligibleForHDR
            snapshot.displaySupportsDolbyVision = screen.supportsDolbyVision
        }
        snapshot.packetsRead = frozen.packetsRead
        snapshot.framesDisplayed = frozen.framesDisplayed
        snapshot.framesDropped = frozen.framesDropped
        snapshot.framesSkipped = frozen.framesSkipped
        snapshot.rebufferCount = frozen.rebufferCount
        snapshot.pictureStarvations = frozen.pictureStarvations
        snapshot.lastSeekLatencySeconds = frozen.lastSeekLatencySeconds
        snapshot.decodeFailures = frozen.decodeFailures
        // Read live rather than frozen: a viewer's own indicator counts up
        // while a stall is still refilling, not only once it is over.
        snapshot.bufferedSeconds = engineStatistics?.bufferedSeconds ?? 0

        snapshot.ioSustainedBitsPerSecond = ioStatistics?.sustainedBitsPerSecond ?? 0
        snapshot.ioFetchLatencySeconds = ioStatistics?.lastFetchLatencySeconds ?? 0
        // The sink guards its own clock; taking the player's lock for it
        // would put the read behind whatever else is holding it.
        let clock = open ? sink.presentationTime : 0
        // End of stream leaves the synchronizer at rate 1 with empty renderers
        // so its clock sails past the stream, and every consumer computes seek
        // targets from this.
        snapshot.position = snapshot.duration > 0 ? min(clock, snapshot.duration) : clock
        // One reading of the three, from a lock the mapper takes for nothing
        // else: this runs on the main thread, once a second, and must never
        // end up behind the decode pipeline.
        let timing = mapped?.decodeTiming ?? ToneMappedVideo.DecodeTiming()
        snapshot.decodeMillisecondsMean = timing.meanMilliseconds
        snapshot.decodeMillisecondsWorst = timing.worstMilliseconds
        snapshot.decodeSampleCount = timing.sampleCount
        snapshot.gpuPasses = timing.gpuPasses
        snapshot.gpuMillisecondsMean = timing.gpuMeanMilliseconds
        snapshot.gpuMillisecondsWorst = timing.gpuWorstMilliseconds
        snapshot.hardwareAccelerated = mapped?.isHardwareAccelerated ?? false
        // Read back from a session, not from a session merely existing: a
        // freshly opened file's decoder answers hardware-or-software at
        // construction, before it has decoded anything, and reporting that
        // early would state "software" as a fact about a file nothing has
        // decoded yet. A count past zero is what makes it a fact.
        snapshot.hardwareAccelerationKnown = timing.sampleCount > 0
        // Read live rather than latched by a reader thread: a refusal
        // reaches the renderer asynchronously, on the engine's own audio
        // decode thread, which has nothing of its own to report it through.
        // Not gated on `pipeline` being passthrough - the renderer's own
        // `.error` is format-agnostic, and a decoded route can be refused
        // too.
        let passthroughError = sink.audioPassthroughError
        if let reason = passthroughError {
            snapshot.audioFormat = "pcm"
            snapshot.audioPassthrough = false
            snapshot.audioFallbackReason = reason
        }
        // The engine's own record outlives the renderer's error, which the
        // recovery flush clears: a route that refused is reported as the
        // decoded PCM the sound now takes.
        if frozen.audioRouteRefused {
            snapshot.audioFormat = "pcm"
            snapshot.audioPassthrough = false
        }
        if frozen.audioRouteRefused || passthroughError != nil {
            passthroughLock.lock()
            let routeChannels = audioRoute.channels
            passthroughLock.unlock()
            snapshot.audioChannels = min(audioChannels, routeChannels)
            snapshot.audioRouteLimited = audioChannels > routeChannels
        }
        // Last word, since a decoder that refused a packet is the newer and
        // the worse of the two: a refused route still plays the sound on the
        // other one, a refused packet plays none of it. The route itself is
        // unchanged by the failure, so `audioFormat` still names it.
        if let reason = frozen.audioFailureReason {
            snapshot.audioFallbackReason = reason
        }
        return snapshot
    }

    /// What the player gives back when the system asks for memory: every
    /// picture its pools are holding for reuse and nothing is using. The
    /// film keeps playing - a pool that has to allocate again costs one
    /// allocation, where dropping a queue would cost the viewer a stutter -
    /// so this is safe to call at any moment, open or not.
    public func releaseSpareBuffers() {
        condition.lock()
        let mapped = toneMapped
        let current = engine
        condition.unlock()
        mapped?.releaseSpareBuffers()
        current?.releaseSpareBuffers()
    }

    /// True while a stop or a cancel is in force. Whatever ends under it ended
    /// because it was told to, which is how a caller tells the two apart.
    public var isCancelled: Bool { interrupt.isRaised }

    /// `demuxer` is set once, at the end of `adopt()`, alongside `videoStream`
    /// and the audio pipeline `recordAudioPipelineStats` reads from: the
    /// moment this is true, `dynamicRange` and `stats`'s audio fields are
    /// real, not their struct defaults.
    public var isOpen: Bool {
        condition.lock()
        defer { condition.unlock() }
        return demuxer != nil
    }

    public func open(url: URL) throws {
        close()
        interrupt.lower()
        try PlaybackActivityGate.shared.beginPlayer()
        holdsPlaybackGate = true
        do {
            try adopt(Demuxer(url: url), readsThroughStream: false)
        } catch {
            PlaybackActivityGate.shared.endPlayer()
            holdsPlaybackGate = false
            throw error
        }
    }

    /// Reads through `stream` and owns it: the stream is closed when the
    /// player is done with it, and also when this call throws.
    ///
    /// A stream that keeps one hands over the probe of this same file the
    /// last open already paid for, which is what lets this one read a
    /// fraction of the container instead of whatever FFmpeg's own defaults
    /// ask for. A cached probe that no longer describes the file fails the
    /// open exactly as a cold one would on the same trouble, and the caller's
    /// next attempt probes cold and stores again.
    public func open(stream: MediaStreamIO) throws {
        close()
        interrupt.lower()
        try PlaybackActivityGate.shared.beginPlayer()
        holdsPlaybackGate = true
        do {
            let cached = stream.cachedAnalysis()
            // Read before the demuxer exists: its cache's pump reads the handle
            // from its own thread from the first probe read on.
            let sizeBytes = cached == nil ? stream.size(stream.handle) : 0
            let opened = try Demuxer(
                stream: stream, interrupt: interrupt, analysis: cached, resumeAt: nil,
                byteCacheWindow: policy.readAheadBytes
            )
            try adopt(opened, readsThroughStream: true)
            // The store touches only the stream's analysis key, never the
            // handle the pump is reading.
            if cached == nil {
                stream.store(MediaAnalysis(
                    sizeBytes: sizeBytes, duration: opened.duration,
                    streams: opened.streams, keyframeSeconds: opened.keyframeTable
                ))
            }
        } catch {
            PlaybackActivityGate.shared.endPlayer()
            holdsPlaybackGate = false
            throw error
        }
    }

    /// Stops the engine and drops everything an open left behind, which is
    /// what closes the stream and frees the container. Blocks exactly as
    /// stop() does. Only an open() revives the player: play() has nothing to
    /// start.
    public func close() {
        stop()
        if holdsPlaybackGate {
            PlaybackActivityGate.shared.endPlayer()
            holdsPlaybackGate = false
        }
        condition.lock()
        let spent = demuxer
        let spentMapping = toneMapped
        demuxer = nil
        videoStream = nil
        audioStream = nil
        audioPipeline = nil
        subtitleStream = nil
        subtitleDecoder = nil
        subtitleIsStyled = false
        duration = 0
        formatDescription = nil
        toneMapped = nil
        dolbyVisionCommitted = false
        recordHandedOver = false
        pictureConfirmed = false
        engineBox = nil
        isPaused = false
        didReachEnd = false
        isSpent = false
        readsThroughStream = false
        condition.unlock()
        upscalingLock.lock()
        upscalingShed = false
        upscalingLock.unlock()
        // releasing the demuxer closes its stream, and closing a network stream
        // tears down a socket: never under the lock the reader blocks on. The
        // mapped path goes the same way: letting go of it waits for whatever
        // VideoToolbox still has in flight.
        withExtendedLifetime(spent) {}
        withExtendedLifetime(spentMapping) {}
        // the styled track of the file that is being closed, whose renderer
        // would otherwise outlive it and draw over the next one, and the text
        // track's clock, which would tick on main for a film no longer there
        sink.stopStyled()
        sink.stopCues()
        statsLock.lock()
        currentStats = PlaybackStats()
        lastEngineStatistics = EngineStatistics()
        statsLock.unlock()
    }

    /// Commits only once the video stream and its format description both hold
    /// up: a failed open leaves an empty player rather than a half-open one.
    private func adopt(_ opened: Demuxer, readsThroughStream: Bool) throws {
        OpenTrace.shared.enter(.adopt)
        guard let video = opened.streams.first(where: { $0.kind == .video }) else {
            throw DemuxError.noStreamInfo(code: 0, message: "no video stream")
        }
        // The display as it stands at the open; a change while the file is
        // playing reaches `displayConfigurationChanged`, which re-decides.
        let capability = display()
        // Asked before the description is built, because when it answers the
        // answer is the description: a profile 5 stream the display layer will
        // take as Dolby Vision goes out described as 'dvh1', and everything
        // else as the HEVC or H.264 it is.
        let dolbyVisionAllowed = allowsDolbyVision()
        let dolbyVisionFormat = dolbyVisionAllowed
            ? dolbyVisionPassthroughFormat(for: video, capability: capability)
            : nil
        let path = videoPath(
            for: video, capability: capability, dolbyVisionPassthrough: dolbyVisionFormat != nil,
            upscalingAllowed: allowsUpscaling()
        )
        // Decoded here, a 'dvh1' description the device's decoder took at
        // the probe is what our own session is built on too: VideoToolbox is
        // where the record is applied, whichever side of the layer it runs.
        let recordRides = dolbyVisionAllowed && path != .decoded
        let format = try dolbyVisionFormat
            ?? makeFormatDescription(for: video, dolbyVisionRecord: recordRides)
        let range = LexisPlayer.dynamicRange(
            of: video,
            recordHandedOver: dolbyVisionFormat != nil
                || (recordRides && video.dolbyVision?.recordDescribesWhatIsHandedOver == true))
        onDisplayKnown?(playerDisplayCriteria(for: video, formatDescription: format), range)
        sink.setSubtitleWhite(range == .sdr
            ? 1
            : SubtitleOverlay.nightWhite
                + (SubtitleOverlay.hdrWhite - SubtitleOverlay.nightWhite) * CGFloat(Daylight.share(at: Date())))
        let upscaleSize = path == .upscaled ? upscaleTarget(for: video, capability: capability) : nil
        let debandStrength = Deband.strength(for: video, fileBitsPerSecond: opened.bitsPerSecond)
        // Weighed against what the device will still give this process before
        // anything is built, so a film it cannot hold costs a sentence at the
        // open rather than a jetsam ten seconds in. The path is read before
        // the mapper exists, so a Metal device that then refuses to build one
        // leaves the budget having reserved for pictures the pipeline never
        // makes - it under-claims, which is the safe direction.
        let audio = preferredAudioStream(among: opened.streams, route: choosingRoute())
        let budget = PlayerEngine.budget(
            for: opened, video: video,
            audio: audio,
            toneMapPixelFormat: picturePixelFormat(
                path, capability: capability, upscaling: upscaleSize != nil),
            processedSize: upscaleSize,
            policy: policy
        )
        if let shortfall = budget.shortfall {
            throw PlaybackMemoryError.tooLargeForMemory(
                requiredBytes: shortfall.requiredBytes, allowedBytes: shortfall.allowedBytes
            )
        }
        // One line per open, and the only place this arithmetic is visible
        // from a device. A film jetsam takes leaves a footprint and nothing
        // to divide it by: what the budget agreed to and what the process
        // then held have to be told apart afterwards, and the footprint
        // alone cannot do it.
        // Built in pieces rather than as one expression: a chain of
        // interpolations joined by `+` is what the Swift type checker gives up
        // on, and it gave up on this one.
        let mib = 1_048_576
        var budgetLine = "[lexis.mem] budget: picture \(budget.pictureBytes / mib) MiB"
        budgetLine += ", queue \(budget.videoSampleBytes / mib) MiB"
        budgetLine += ", reserve \(budget.pictureReserveBytes / mib) MiB"
        budgetLine += ", packets \(budget.videoPacketBytes / mib) MiB"
        budgetLine += ", path \(path)"
        budgetLine += String(
            format: ", video %.1f Mb/s, file %.1f Mb/s",
            Double(video.bitsPerSecond) / 1_000_000, Double(opened.bitsPerSecond) / 1_000_000)
        if let upscaleSize {
            budgetLine += ", upscale \(upscaleSize.width)x\(upscaleSize.height)"
        }
        traceLine(budgetLine)
        var toneMapped: ToneMappedVideo?
        let box = EngineBox()
        if path == .decoded {
            toneMapped = try? ToneMappedVideo(
                decodingOnly: format,
                videoDelay: video.videoDelay,
                budgetBytes: budget.pictureReserveBytes,
                rendererAttributes: sink.recommendedPictureAttributes
            ) { [weak box] sample in
                box?.engine?.pushToneMappedFrame(sample)
            }
        } else if path == .toneMapped {
            let reshapes = video.dolbyVision.map { !$0.baseLayerIsDisplayable } ?? false
            // A Metal device that will not build costs the mapping, not the
            // playback: the picture goes up as it is, which is what every
            // player did before this.
            toneMapped = try? ToneMappedVideo(
                formatDescription: format,
                sourcePeakPQ: contentPeakPQ(video.contentLight)
                    ?? masteringPeakPQ(video.masteringDisplay),
                sourceBlackPQ: masteringBlackPQ(video.masteringDisplay),
                sourceIsHLG: isHybridLogGamma(video.colorTransfer),
                videoDelay: video.videoDelay,
                capability: capability,
                budgetBytes: budget.pictureReserveBytes,
                queueBytes: budget.videoSampleBytes,
                rendererAttributes: sink.recommendedPictureAttributes,
                reshapesDolbyVision: reshapes,
                // a codec the device cannot decode is decoded by the engine
                decodesItself: hardwareDecodes(video) != false
            ) { [weak box] sample in
                box?.engine?.pushToneMappedFrame(sample)
            }
        } else if path == .upscaled, let upscaleSize {
            // A GPU the upscaler refuses costs the upscale, not the playback: the
            // picture goes up as it is, exactly as before this path existed.
            toneMapped = try? ToneMappedVideo(
                formatDescription: format,
                upscalingTo: upscaleSize,
                neural: allowsNeuralUpscaling(),
                picturesPerSecond: video.outputFrameRate,
                videoDelay: video.videoDelay,
                budgetBytes: budget.pictureReserveBytes,
                queueBytes: budget.videoSampleBytes,
                sourceBitDepth: video.bitDepth,
                rendererAttributes: sink.recommendedPictureAttributes,
                debandStrength: debandStrength,
                fields: FieldOrder(of: video)
            ) { [weak box] sample in
                box?.engine?.pushToneMappedFrame(sample)
            }
        }
        // The field builder at the film's own size: an interlaced film, and
        // one whose scaler would not build.
        let fields = FieldOrder(of: video)
        if toneMapped == nil, path == .deinterlaced || (path == .upscaled && fields != nil) {
            toneMapped = try? ToneMappedVideo(
                enhancing: format,
                sourceBitDepth: video.bitDepth,
                videoDelay: video.videoDelay,
                budgetBytes: budget.pictureReserveBytes,
                queueBytes: budget.videoSampleBytes,
                rendererAttributes: sink.recommendedPictureAttributes,
                fields: fields
            ) { [weak box] sample in
                box?.engine?.pushToneMappedFrame(sample)
            }
        }
        // The passthrough path hands its compressed sample straight to the
        // sink; nothing here decodes it, so nothing here can honestly time
        // it either. `PassthroughDecodeProbe` answers that question, but
        // only from the bench's own run, with nothing on screen - a second
        // session next to the display layer's own would cost this playback
        // the very frames a viewer would then see reported as dropped.
        toneMapped?.onPictureLost = { [weak box] error in box?.engine?.pictureLost(error) }
        toneMapped?.onPictureFolded = { [weak box] in box?.engine?.releaseSubmittedPicture() }
        sink.setWantsExtendedDynamicRange(wantsExtendedRange(toneMapped))
        // A codec we cannot decode costs the sound, not the playback.
        let pipeline = audio.flatMap(audioPipeline(for:))
        condition.lock()
        demuxer = opened
        videoStream = video
        formatDescription = format
        dolbyVisionCommitted = dolbyVisionFormat != nil
        recordHandedOver = dolbyVisionFormat != nil
            || (recordRides && video.dolbyVision?.recordDescribesWhatIsHandedOver == true)
        adoptedCapability = capability
        pictureConfirmed = false
        self.budget = budget
        self.toneMapped = toneMapped
        engineBox = box
        audioStream = pipeline != nil ? audio : nil
        audioPipeline = pipeline
        duration = opened.duration
        self.readsThroughStream = readsThroughStream
        recordAudioPipelineStats(pipeline, track: audio)
        statsLock.lock()
        currentStats.videoPassthrough = toneMapped == nil
        currentStats.videoPath = toneMapped == nil ? .passthrough
            // the scaler that would not build left the field builder at the film's size
            : path == .upscaled && toneMapped?.upscaledSize == nil ? .deinterlaced
            : path
        currentStats.videoDescription = fourCharCode(CMFormatDescriptionGetMediaSubType(format))
        currentStats.dolbyVisionProfile = Int32(video.dolbyVision?.profile ?? 0)
        // The size the path made: a target chosen for a scaler that then
        // refused to build is a size nothing renders at.
        let upscaled = toneMapped?.upscaledSize
        currentStats.videoUpscaled = upscaled != nil
        currentStats.upscaleWidth = upscaled?.width ?? 0
        currentStats.upscaleHeight = upscaled?.height ?? 0
        statsLock.unlock()
        let list = trackList
        condition.unlock()
        continuation.yield(.opened(width: video.width, height: video.height, codec: video.codecName))
        continuation.yield(.tracks(list))
    }

    /// Whether AC-3/E-AC-3 may ride to the display unmodified. A TV whose
    /// soundbar chain mishandles non-PCM over ARC stutters exactly here, and
    /// nothing in the pipeline can see it: the renderer accepts every buffer,
    /// so there is no error to fall back on - only ears. Off sends those
    /// codecs through the decoder, whose PCM every chain carries.
    private var passthroughAllowed = true
    /// Formats the route has refused during this player's life: offering one
    /// again only buys another silent gap while the refusal comes back.
    /// Under `passthroughLock`.
    private var refusedPassthrough: Set<CompressedAudioFormat> = []
    private let passthroughLock = NSLock()
    /// Under `passthroughLock`.
    private var audioRoute = AudioRoute.unlimited

    /// The route a track is chosen for: one that will not be handed a Dolby
    /// bitstream, by the viewer's switch or by an earlier refusal, decodes it
    /// like any other track.
    private func choosingRoute() -> AudioRoute {
        passthroughLock.lock()
        defer { passthroughLock.unlock() }
        var route = audioRoute
        route.takesDolby = route.takesDolby && passthroughAllowed
            && refusedPassthrough.isDisjoint(with: [.ac3, .eac3])
        return route
    }

    /// What the output takes, as the app reads it: weighed at the next open
    /// or track choice, like a passthrough turned back on.
    public func setAudioRoute(_ route: AudioRoute) {
        passthroughLock.lock()
        audioRoute = route
        passthroughLock.unlock()
    }

    /// Read wherever pipelines are built, which is deliberately off the
    /// reader's own lock.
    private func routeAllowsPassthrough(_ format: CompressedAudioFormat) -> Bool {
        passthroughLock.lock()
        defer { passthroughLock.unlock() }
        return passthroughAllowed && !refusedPassthrough.contains(format)
    }

    /// Seconds the sound plays after the picture, negative for before: the
    /// lip sync a sound system that adds its own latency needs. Kept for
    /// every film this player opens.
    public func setAudioDelay(_ seconds: Double) {
        condition.lock()
        audioDelay = seconds
        let current = engine
        condition.unlock()
        current?.setAudioDelay(seconds, started: true)
    }

    /// Flips the passthrough route for this and every later track choice.
    /// Turning it off mid-film rebuilds the current track as decoded at once;
    /// turning it back on takes effect at the next track choice or open.
    public func setPassthroughAllowed(_ value: Bool) {
        passthroughLock.lock()
        let changed = value != passthroughAllowed
        passthroughAllowed = value
        // turned back on is a viewer asking for the bitstream to be tried again
        if changed, value { refusedPassthrough.removeAll() }
        passthroughLock.unlock()
        guard changed, !value else { return }
        condition.lock()
        let index = audioStream?.index
        condition.unlock()
        if let index { selectAudioTrack(index: index) }
    }

    /// Whether a small SDR picture may be built bigger than the file carries
    /// it, by the upscaled path. On by default: the path only exists
    /// where it improves the picture, and the upscaler refusing the GPU already
    /// keeps it off the machines that cannot afford it.
    private var upscalingAllowed = true
    /// Behind `condition`, read as each engine is built.
    private var audioDelay = 0.0
    /// Set for the rest of the film once its pictures fell behind: the
    /// scaler is the heaviest pass the path has.
    private var upscalingShed = false
    private let upscalingLock = NSLock()

    private func allowsUpscaling() -> Bool {
        upscalingLock.lock()
        defer { upscalingLock.unlock() }
        return upscalingAllowed && !upscalingShed
    }

    /// Whether a Dolby Vision stream is handed over as Dolby Vision, on by
    /// default. Off, a profile 8 base layer goes as the HDR10 it also is
    /// and a profile 5 one is mapped: what a viewer wants where the screen
    /// does something in HDR10 it will not do in Dolby Vision, such as
    /// motion compensation. A change turns an open film round.
    public func setDolbyVisionAllowed(_ value: Bool) {
        dolbyVisionLock.lock()
        let changed = value != dolbyVisionAllowed
        dolbyVisionAllowed = value
        dolbyVisionLock.unlock()
        guard changed else { return }
        condition.lock()
        guard let open = demuxer, let video = videoStream, !isSpent, video.dolbyVision != nil,
            let capability = adoptedCapability
        else {
            condition.unlock()
            return
        }
        condition.unlock()
        turnPathRound(over: open, video: video, capability: capability)
    }

    private let dolbyVisionLock = NSLock()
    private var dolbyVisionAllowed = true

    private func allowsDolbyVision() -> Bool {
        dolbyVisionLock.lock()
        defer { dolbyVisionLock.unlock() }
        return dolbyVisionAllowed
    }

    /// Whether the scaler doubles the luma by its network, on the Neural
    /// Engine, rather than by its filters on the GPU. On by default: it scores
    /// as the filters do or better against true 4K, and the filters take the
    /// luma back where the Neural Engine cannot keep up. A change turns an
    /// open film round.
    private var neuralUpscaling = true

    private func allowsNeuralUpscaling() -> Bool {
        upscalingLock.lock()
        defer { upscalingLock.unlock() }
        return neuralUpscaling
    }

    public func setNeuralUpscaling(_ value: Bool) {
        upscalingLock.lock()
        let changed = value != neuralUpscaling
        neuralUpscaling = value
        upscalingLock.unlock()
        guard changed else { return }
        condition.lock()
        guard let open = demuxer, let video = videoStream, !isSpent,
            let capability = adoptedCapability
        else {
            condition.unlock()
            return
        }
        condition.unlock()
        // only a film the scaler scales has anything to turn round
        guard allowsUpscaling(), upscaleTarget(for: video, capability: capability) != nil else { return }
        turnPathRound(over: open, video: video, capability: capability)
    }

    /// Flips the upscaled path for this and every later open. Flipping it
    /// with a file open whose path decision moves turns that file round at
    /// once, the way a display change does.
    public func setUpscalingAllowed(_ value: Bool) {
        upscalingLock.lock()
        let changed = value != upscalingAllowed
        upscalingAllowed = value
        upscalingLock.unlock()
        guard changed else { return }
        condition.lock()
        guard let open = demuxer, let video = videoStream, !isSpent,
            let capability = adoptedCapability
        else {
            condition.unlock()
            return
        }
        condition.unlock()
        guard videoPath(for: video, capability: capability, upscalingAllowed: value)
            != videoPath(for: video, capability: capability, upscalingAllowed: !value)
        else { return }
        turnPathRound(over: open, video: video, capability: capability)
    }

    /// The one place the format is weighed against what a compressed buffer
    /// needs: an open and a track switch must not drift into two different
    /// answers for the same codec. Building is FFmpeg or CoreMedia work, so
    /// the caller keeps it outside the lock the reader blocks on.
    private func audioPipeline(for stream: MediaStream) -> PlayerEngine.AudioPipeline? {
        // The Apple TV's renderer takes a DTS bitstream without an error, then
        // never asks for more: the sound queue fills and the picture starves.
        if let format = compressedAudioFormat(codecID: stream.codecID), format != .dts,
           routeAllowsPassthrough(format),
           let description = try? makeCompressedAudioFormatDescription(
               format: format, sampleRate: stream.sampleRate, channels: stream.channels
           ) {
            return .passthrough(format, description)
        }
        return (try? AudioDecoder(stream: stream)).map(PlayerEngine.AudioPipeline.decoded)
    }

    /// What a freshly chosen pipeline reports before a single packet has
    /// flowed through it: a live read in `stats` is what corrects this if the
    /// route then refuses a passthrough buffer. The caller holds `condition`'s
    /// lock; nil is the same "nothing is playing" answer whether nothing was
    /// ever selected or a track was turned off, so it must not leave a stale
    /// track's numbers standing.
    ///
    /// `track` is the stream the pipeline was built for, and tells the two
    /// silent readings apart: no track at all, or a track nothing here can
    /// decode. A silent film that reported "pcm, decoded" read exactly like
    /// one playing normally, and a viewer with no sound could not tell it
    /// from a fault at their own end.
    private func recordAudioPipelineStats(
        _ pipeline: PlayerEngine.AudioPipeline?, track: MediaStream?
    ) {
        passthroughLock.lock()
        let routeChannels = audioRoute.channels
        passthroughLock.unlock()
        let channels = track?.channels ?? 0
        statsLock.lock()
        currentStats.audioChannels = channels
        currentStats.audioRouteLimited = false
        switch pipeline {
        case .decoded:
            currentStats.audioFormat = "pcm"; currentStats.audioPassthrough = false
            currentStats.audioChannels = min(channels, routeChannels)
            currentStats.audioRouteLimited = channels > routeChannels
        case .passthrough(.ac3, _): currentStats.audioFormat = "ac3"; currentStats.audioPassthrough = true
        case .passthrough(.eac3, _): currentStats.audioFormat = "eac3"; currentStats.audioPassthrough = true
        case .passthrough(.dts, _): currentStats.audioFormat = "dts"; currentStats.audioPassthrough = true
        case .passthrough(.trueHD, _): currentStats.audioFormat = "truehd"; currentStats.audioPassthrough = true
        case nil:
            currentStats.audioFormat = track == nil ? "none" : "unsupported"
            currentStats.audioPassthrough = false
            currentStats.audioChannels = 0
        }
        currentStats.audioFallbackReason = ""
        statsLock.unlock()
    }

    /// Every track and what is playing of it. The caller holds the lock.
    private var trackList: TrackList {
        TrackList(
            audio: demuxer?.streams.filter { $0.kind == .audio } ?? [],
            subtitle: demuxer?.streams.filter { $0.kind == .subtitle } ?? [],
            selectedAudio: audioStream?.index ?? -1,
            selectedSubtitle: subtitleStream?.index ?? -1,
            chapters: demuxer?.chapters ?? []
        )
    }

    public var tracks: TrackList {
        condition.lock()
        defer { condition.unlock() }
        return trackList
    }

    /// What the layer is asked to show the picture as. Passthrough leaves the
    /// range to the stream's own description; a mapped picture is HDR only
    /// where it was stored as half floats, which is the one container here
    /// that holds light above white. A layer told `.standard` under such a
    /// picture clips everything the curve placed above it.
    private func wantsExtendedRange(_ mapped: ToneMappedVideo?) -> Bool {
        mapped?.extendedRange ?? true
    }

    /// What the pictures a path makes are stored as, for the budget to
    /// weigh; nil on the passthrough path, which makes none.
    private func picturePixelFormat(
        _ path: VideoPath, capability: DisplayCapability, upscaling: Bool
    ) -> OSType? {
        switch path {
        case .toneMapped: return capability.toneMapPixelFormat
        case .decoded, .deinterlaced: return kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        case .upscaled: return upscaling ? Upscaler.pixelFormat : nil
        case .passthrough: return nil
        }
    }

    /// `.dolbyVision` only where the record rides to a decoder: a profile 7
    /// base layer is handed over as the HDR10 it is, and reporting Dolby
    /// Vision for it would name a picture nothing here shows.
    public var dynamicRange: VideoDynamicRange {
        condition.lock()
        defer { condition.unlock() }
        guard let stream = videoStream else { return .sdr }
        return LexisPlayer.dynamicRange(of: stream, recordHandedOver: recordHandedOver)
    }

    private static func dynamicRange(
        of stream: MediaStream, recordHandedOver: Bool
    ) -> VideoDynamicRange {
        if stream.dolbyVision != nil, recordHandedOver { return .dolbyVision }
        if isPerceptualQuantizer(stream.colorTransfer) { return .hdr10 }
        // the only other transfer the wider test answers to
        return isHighDynamicRange(stream.colorTransfer) ? .hlg : .sdr
    }

    /// Told, during an open, the mode the display will be asked for as soon
    /// as the path is chosen and before it is built: the screen's switch,
    /// seconds long, can then run while the pipeline is built rather than
    /// after it. Called on the thread `open` runs on.
    public var onDisplayKnown: ((DisplayCriteriaRequest?, VideoDynamicRange) -> Void)?

    public var displayCriteria: DisplayCriteriaRequest? {
        condition.lock()
        defer { condition.unlock() }
        guard let stream = videoStream, let format = formatDescription else { return nil }
        return playerDisplayCriteria(for: stream, formatDescription: format)
    }

    public func play() {
        condition.lock()
        // The spent demuxer refuses before anything else, and before the flag
        // is lowered: an engine the interrupt sent home leaves a demuxer there
        // is no resuming, and lowering the flag for it would let a read that
        // is still parked in the stream come back and feed the sink.
        guard demuxer != nil, !didReachEnd, !isSpent else {
            condition.unlock()
            return
        }
        interrupt.lower()
        if let engine {
            isPaused = false
            condition.unlock()
            engine.setPaused(false)
            continuation.yield(.playing)
            return
        }
        guard let demuxer, let videoStream else {
            condition.unlock()
            return
        }
        isPaused = false
        let tracks = PlayerEngine.Tracks(video: videoStream, audio: audioStream, subtitle: subtitleStream)
        let toneMapped = self.toneMapped
        let budget = self.budget
        // The one `adopt` settled on, so a Dolby Vision file keeps the 'dvh1'
        // description across every engine this player builds for it and not
        // only the first.
        let adoptedFormat = formatDescription
        condition.unlock()

        let newEngine = PlayerEngine(
            demuxer: demuxer, tracks: tracks, sink: sink, toneMapped: toneMapped,
            budget: budget, interrupt: interrupt, policy: policy,
            videoFormatDescription: adoptedFormat
        )

        let drained = DispatchSemaphore(value: 0)
        condition.lock()
        // A close(), or another open(), while the engine was being built.
        guard self.demuxer === demuxer else {
            condition.unlock()
            return
        }
        engine = newEngine
        engineBox?.engine = newEngine
        engineGeneration += 1
        let generation = engineGeneration
        // Published with the engine: a stop() that sees this engine must wait
        // on its own semaphore, never on the last engine's, already consumed.
        eventTaskDrained = drained
        let queue = watchdogQueue
        // Both are safe across threads through their own locks.
        nonisolated(unsafe) weak let player = self
        nonisolated(unsafe) let engine = newEngine
        eventTask = Task {
            for await event in engine.events {
                // Applied on the watchdog's queue: retiring an engine joins its
                // threads, which must not hold a cooperative pool thread.
                await withCheckedContinuation { (applied: CheckedContinuation<Void, Never>) in
                    queue.async {
                        player?.apply(event, from: engine, generation: generation)
                        applied.resume()
                    }
                }
            }
            drained.signal()
        }
        let seededAudio = audioStream
        let seededAudioPipeline = audioPipeline
        let seededSubtitle = subtitleStream
        let seededSubtitleDecoder = subtitleDecoder
        let seededSubtitleStyled = subtitleIsStyled
        let seededAudioDelay = audioDelay
        condition.unlock()

        newEngine.onPassthroughRefused = { [weak self] format, stream, decoder in
            guard let self else { return }
            self.passthroughLock.lock()
            self.refusedPassthrough.insert(format)
            self.passthroughLock.unlock()
            // the next engine built over this file starts on the decoder, not
            // on the bitstream the route just refused
            self.condition.lock()
            if self.audioStream?.index == stream.index, case .passthrough = self.audioPipeline {
                self.audioPipeline = .decoded(decoder)
            }
            self.condition.unlock()
        }
        // The engine's own `Tracks` only sizes its queues; the decode
        // pipeline itself is handed over the same way a live track switch
        // hands one over, seeded before the first packet is ever read.
        newEngine.setAudioDelay(seededAudioDelay, started: false)
        newEngine.selectAudio(seededAudio, pipeline: seededAudioPipeline)
        newEngine.selectSubtitle(seededSubtitle, decoder: seededSubtitleDecoder, styled: seededSubtitleStyled)

        continuation.yield(.playing)
        newEngine.start(paused: false)
    }

    public func pause() {
        condition.lock()
        guard let engine else {
            condition.unlock()
            return
        }
        isPaused = true
        condition.unlock()
        engine.setPaused(true)
        continuation.yield(.paused)
    }

    /// Asks for the keyframe at or before `seconds` and returns at once: a
    /// live engine performs it on its own demux thread, because that is the
    /// thread that owns the demuxer.
    ///
    /// A player with no engine (never played, or stopped) does it here
    /// instead, which is what makes seeking back from a stop, or from the end
    /// of a stream, work.
    public func seek(to seconds: Double) {
        condition.lock()
        guard let demuxer, !isSpent else {
            condition.unlock()
            return
        }
        // an mp4 seek past the end succeeds and lands on the last keyframe, so
        // the clamp is ours to make
        let target = duration > 0 ? min(max(0, seconds), duration) : max(0, seconds)
        if let engine {
            condition.unlock()
            engine.seek(to: target) { _ in }
            return
        }
        let pipeline = audioPipeline
        let subtitles = subtitleDecoder
        let mapped = toneMapped
        condition.unlock()
        do {
            try demuxer.seek(to: target)
        } catch {
            failDirectly(.failed(String(describing: error)))
            return
        }
        if case .decoded(let decoder) = pipeline { decoder.flush() }
        subtitles?.flush()
        // Before the sink, always: a picture already on the way from the old
        // position must not land in a window a flush is about to clear.
        mapped?.flush()
        sink.flush(keepingImage: true)
        // a flush leaves the clock where the old position left it, and with
        // no engine nothing will re-anchor it until a play() feeds a packet
        sink.anchor(atPresentation: target)
        condition.lock()
        didReachEnd = false
        condition.unlock()
    }

    /// Plays another audio stream. A live engine swaps the decoder in at its
    /// next packet: both tracks are interleaved in the same file, so the new
    /// one is already arriving and a seek would only rewind the picture to
    /// the keyframe before it.
    ///
    /// An index no audio stream answers to is a no-op; a codec with no decoder
    /// takes the sound off rather than refusing, and the list reports -1.
    public func selectAudioTrack(index: Int32) {
        condition.lock()
        let open = demuxer
        let spent = isSpent
        condition.unlock()
        // The stream list is fixed once a demuxer is open, and building a
        // decoder is FFmpeg work: neither belongs under the lock an engine's
        // own construction blocks on, which is why adopt() does it this way
        // too.
        guard let open, !spent,
              let stream = open.streams.first(where: { $0.index == index && $0.kind == .audio })
        else { return }
        let pipeline = audioPipeline(for: stream)
        condition.lock()
        // a close, or another file, while the decoder was being built
        guard demuxer === open else {
            condition.unlock()
            return
        }
        if let pipeline {
            audioStream = stream
            audioPipeline = pipeline
        } else {
            audioStream = nil
            audioPipeline = nil
        }
        // The new track's own answer, not the old one's: a viewer switching
        // from AAC to an E-AC-3 or Atmos track has changed what the format
        // allows, and the choice is remade for it, not carried over.
        recordAudioPipelineStats(pipeline, track: stream)
        let list = trackList
        let current = engine
        condition.unlock()
        current?.selectAudio(pipeline != nil ? stream : nil, pipeline: pipeline)
        continuation.yield(.tracks(list))
    }

    /// Shows another subtitle stream, or none at all for -1. Same swap as the
    /// audio, and the cues already queued in the sink go with the old track.
    public func selectSubtitleTrack(index: Int32) {
        condition.lock()
        let open = demuxer
        let spent = isSpent
        condition.unlock()
        guard let open, !spent else { return }
        subtitleSelectionLock.lock()
        subtitleSelections &+= 1
        let selection = subtitleSelections
        subtitleSelectionLock.unlock()
        let stream = open.streams.first { $0.index == index && $0.kind == .subtitle }
        // A styled track is libass's, and it needs the script header the track
        // carries and every font the container does. A font is a stream with no
        // packets whose whole file is its extradata; anything in there that is
        // not a font is refused by FreeType rather than by a mime type, which
        // was measured not to be reliable.
        if let stream, SubtitleDecoder.isStyled(codecID: stream.codecID),
           let header = stream.extradata, !header.isEmpty {
            let fonts = open.streams.filter { $0.kind == .other }.compactMap(\.extradata)
            let video = open.streams.first { $0.kind == .video }
            sink.startStyled(
                header: header, fonts: fonts,
                canvasWidth: Int(video?.width ?? 0), canvasHeight: Int(video?.height ?? 0)
            ) { [weak self] styled in
                if !styled {
                    // the track still plays, as stripped plain text; the sink
                    // logs which of libass's refusals this was
                    subtitleLog.error("styled track \(stream.index) is drawn as plain text")
                }
                self?.commitSubtitleSelection(
                    stream, styled: styled, over: open, selection: selection)
            }
            return
        }
        commitSubtitleSelection(stream, styled: false, over: open, selection: selection)
    }

    /// The rest of a selection, once libass has answered for a styled track.
    /// A newer selection has already started or stopped the renderer for
    /// itself, so a superseded one leaves without touching anything.
    private func commitSubtitleSelection(
        _ stream: MediaStream?, styled: Bool, over open: Demuxer, selection: UInt64
    ) {
        subtitleSelectionLock.lock()
        defer { subtitleSelectionLock.unlock() }
        guard selection == subtitleSelections else { return }
        var decoder: SubtitleDecoder?
        if let stream, !styled {
            decoder = try? SubtitleDecoder(stream: stream)
        }
        if !styled { sink.stopStyled() }
        if styled || decoder == nil { sink.stopCues() }
        // Before the swap is published, or a live engine that picks it up can
        // enqueue the new track's first cue into the window this flush clears.
        sink.flushSubtitles()
        sink.flushStyled()
        condition.lock()
        guard demuxer === open else {
            condition.unlock()
            // A close, or another file, while the renderer was being built. No
            // player state records it, so nothing else would ever free it and
            // it would draw the closed file's events over whatever plays next.
            if styled { sink.stopStyled() }
            return
        }
        if let stream, styled || decoder != nil {
            subtitleStream = stream
            subtitleDecoder = decoder
            subtitleIsStyled = styled
        } else {
            subtitleStream = nil
            subtitleDecoder = nil
            subtitleIsStyled = false
        }
        let list = trackList
        let current = engine
        condition.unlock()
        current?.selectSubtitle(
            subtitleStream, decoder: subtitleDecoder, styled: subtitleIsStyled
        )
        continuation.yield(.tracks(list))
    }

    public func stop() {
        // before the lock: an engine parked inside a read has to be cut loose
        // before this thread starts waiting for it to finish
        interrupt.raise()
        // Before the join, and from a thread that is not the watchdog's own:
        // a tick that fired a moment ago is still allowed to run to its end
        // and finds no engine, which is its own no-op.
        cancelPictureWatchdog()
        condition.lock()
        let current = engine
        let streamBacked = readsThroughStream
        let drained = eventTaskDrained
        if current != nil {
            engine = nil
            // invalidates any event this engine's own forwarding task still
            // has queued, so it cannot re-apply itself after the state below
            // has moved on
            engineGeneration += 1
        }
        condition.unlock()
        if let current {
            current.stop(join: true)
            freezeStatistics(from: current)
            // The forwarding task's own `for await` ends once `stop(join:
            // true)` above has finished the engine's `events` - waited on
            // here so this engine (and the demuxer it owns) is provably
            // gone, not merely on its way out, by the time stop() returns.
            drained?.wait()
            // A refused read latches AVERROR_EXIT inside the AVIOContext, so a
            // stream-backed demuxer a stop cut short is spent in the same way
            // as one that ran to its end; a path-backed one reads through no
            // such context and survives, which is what lets play() build a
            // fresh engine over it.
            if streamBacked {
                condition.lock()
                isSpent = true
                condition.unlock()
            }
        }
        // Before the sink is cleared, and after the engine is done feeding it:
        // a picture that landed between the two would sit on the layer as a
        // ghost with nothing to follow it.
        condition.lock()
        let mapped = toneMapped
        condition.unlock()
        mapped?.flush()
        // Unconditional: after end of stream the engine is already gone, but
        // the sink still holds the tail of the old stream. This is also what
        // clears it for the next open().
        sink.flush(keepingImage: false)
        if current != nil {
            continuation.yield(.stopped)
        }
    }

    /// Tells an open or a read in flight to give up, and returns at once. It
    /// exists because stop() waits for the engine and a caller on the main
    /// thread cannot: cancel() first, stop() from somewhere that may block.
    ///
    /// Like stop(), it spends a stream: open(stream:) is the way back.
    public func cancel() {
        interrupt.raise()
    }

    /// Applied for the current engine's own forwarding task, one event at a
    /// time, on `watchdogQueue`. `generation` pins this call to the engine
    /// that was current when the forwarding task started: a match is required
    /// before anything here touches the player's state or yields to `events`,
    /// so a previous engine's event, delivered after `stop()` or `close()`
    /// already moved the player on, cannot re-apply itself.
    private func apply(_ event: EngineEvent, from current: PlayerEngine, generation: Int) {
        condition.lock()
        guard generation == engineGeneration else {
            condition.unlock()
            return
        }
        switch event {
        case .firstFrame(let seconds):
            let watch = toneMapped == nil && !pictureConfirmed
            watchedFromPresentation = seconds
            condition.unlock()
            OpenTrace.shared.finish()
            // Only where nothing here decodes. The mapped path's own failures
            // arrive as `.failed` from the decoder itself and need no net.
            if watch { startPictureWatchdog() }
            continuation.yield(.firstFrame(seconds: seconds))
        case .endOfStream:
            didReachEnd = true
            engine = nil
            let paused = isPaused
            condition.unlock()
            retireNaturally(current)
            // A seek asked for while the tail played out is what the viewer
            // wants, not the end: it lands over the finished engine instead.
            if let target = current.takePendingSeek() {
                seek(to: target)
                if !paused { play() }
                return
            }
            continuation.yield(.endOfStream)
        case .failed(let message):
            isSpent = true
            engine = nil
            condition.unlock()
            traceLine("[lexis.open] engine failed: \(message)")
            retireNaturally(current)
            continuation.yield(.failed(message))
        case .unauthorized:
            isSpent = true
            engine = nil
            condition.unlock()
            retireNaturally(current)
            continuation.yield(.unauthorized)
        case .decoderTakenBack:
            // The same turn-round a display change performs, from where
            // the clock stands: the app was behind the home screen and the
            // decoder went with it, which is not a film that cannot play.
            guard let open = demuxer, let video = videoStream, let capability = adoptedCapability else {
                condition.unlock()
                return
            }
            condition.unlock()
            traceLine("[lexis.open] decoder taken back, turning round")
            turnPathRound(over: open, video: video, capability: capability)
        case .decodeFellBehind:
            // A softer picture rather than one that keeps freezing.
            guard let open = demuxer, let video = videoStream, let capability = adoptedCapability,
                toneMapped?.upscaledSize != nil
            else {
                condition.unlock()
                return
            }
            condition.unlock()
            upscalingLock.lock()
            let sheds = !upscalingShed
            upscalingShed = true
            upscalingLock.unlock()
            guard sheds else { return }
            traceLine("[lexis.open] pictures fell behind, turning round without the scaler")
            turnPathRound(over: open, video: video, capability: capability)
        case .buffering(let bufferedSeconds):
            condition.unlock()
            continuation.yield(.buffering(bufferedSeconds: bufferedSeconds))
        case .resumed:
            condition.unlock()
            continuation.yield(.playing)
        }
    }

    /// What every terminal engine event (end of stream, failed, unauthorized)
    /// retires with, before the event that announces it is yielded: joined,
    /// so a caller reading a stream-close side effect right after observing
    /// the event sees it already having happened, the same guarantee an
    /// explicit `stop()` gives. `interrupt` is lowered again afterwards -
    /// `stop(join:)` always raises it to cut a parked read loose, but this
    /// is not a stop a later seek or play on the same, still-open file
    /// should have to fight through.
    private func retireNaturally(_ engine: PlayerEngine) {
        engine.stop(join: true)
        interrupt.lower()
        freezeStatistics(from: engine)
    }

    /// Snapshots the engine's own counters before letting it go, so `stats`
    /// still reports its final packet and frame counts once it is gone.
    /// Updating them only opportunistically, whenever `stats` itself
    /// happened to be polled while the engine was still alive, would lose
    /// them for any caller that reads `stats` only after the event that
    /// ended playback - exactly what an end-of-stream waiter does.
    private func freezeStatistics(from engine: PlayerEngine) {
        statsLock.lock()
        lastEngineStatistics = engine.statistics
        statsLock.unlock()
    }

    /// How much may pass with a committed passthrough path showing nothing
    /// before it is taken as never going to show anything.
    ///
    /// STREAM seconds on the sink's own clock, never wall clock from the
    /// press, and that is the whole of the design. That clock is stopped for
    /// every second a viewer waits through an open - 13.8 s of it on a cold
    /// start, nearly all of it reaching the server before a byte is decoded -
    /// it is stopped again for the refill that holds the first frame up, and
    /// it is stopped for every rebuffer a starved source causes. None of
    /// those can spend this budget. It runs only while the pipeline believes
    /// a picture is due, which is the only span in which no picture means
    /// anything at all.
    ///
    /// A working decoder has its first frame ready in tens of milliseconds -
    /// measured here on 'hvc1' and on 'dvh1' alike - so the standard policy's
    /// second of running clock is more than an order of magnitude of room.
    ///
    /// The watchdog runs on its own timer and not on the pipeline's threads:
    /// a renderer that stops asking for media parks every one of them, and a
    /// watchdog the failure can silence is not one.
    private func startPictureWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: watchdogQueue)
        timer.schedule(
            deadline: .now() + policy.pictureWatchdogInterval,
            repeating: policy.pictureWatchdogInterval
        )
        timer.setEventHandler { [weak self] in self?.checkForPicture() }
        condition.lock()
        let previous = pictureWatchdog
        pictureWatchdog = timer
        condition.unlock()
        previous?.cancel()
        timer.resume()
    }

    private func cancelPictureWatchdog() {
        condition.lock()
        let running = pictureWatchdog
        pictureWatchdog = nil
        condition.unlock()
        running?.cancel()
    }

    /// On `watchdogQueue`. Ends the moment a picture is confirmed, and a
    /// confirmed picture is never asked about again: the layer gives this up
    /// on a flush that removes the image, and one seek would otherwise re-arm
    /// a watchdog over a path already proven to work.
    private func checkForPicture() {
        if sink.hasDisplayedPicture {
            condition.lock()
            pictureConfirmed = true
            condition.unlock()
            cancelPictureWatchdog()
            return
        }
        condition.lock()
        // A pause stops the clock, so it cannot spend the budget either - but
        // it must not be turned round underneath a viewer who paused it.
        guard let from = watchedFromPresentation, engine != nil, !isPaused, !isSpent else {
            condition.unlock()
            return
        }
        let committed = dolbyVisionCommitted
        condition.unlock()
        let elapsed = sink.presentationTime - from
        guard elapsed.isFinite, elapsed > policy.firstPictureGraceSeconds else { return }
        if committed {
            fallBackFromDolbyVision(from: from)
            return
        }
        // The ordinary passthrough path has nowhere better to go: the display
        // layer decodes it through the same VideoToolbox the mapped path
        // would use, so a fallback there would fail the same way. It is ended
        // with a sentence rather than left as a black screen, and only on two
        // signals agreeing - the renderer having refused a sample outright as
        // well as no picture - because a wrong answer here costs a film that
        // was playing, where a wrong answer on the Dolby Vision path costs
        // only the Dolby Vision.
        let refusal = sink.videoDecodeFailure
        cancelPictureWatchdog()
        if let refusal { abandonPlayback(refusal) }
    }

    /// The same retirement `apply` gives an engine's own `.failed`, for a
    /// verdict reached outside the engine.
    private func abandonPlayback(_ reason: String) {
        condition.lock()
        guard let current = engine else {
            condition.unlock()
            return
        }
        isSpent = true
        engine = nil
        engineGeneration += 1
        condition.unlock()
        retireNaturally(current)
        continuation.yield(.failed(reason))
    }

    /// Rebuilds this file on the tone-mapped path and plays it again, without
    /// re-opening the stream: the demuxer, its socket and every byte its
    /// cache already holds all survive, so the switch costs a warm start and
    /// a seek back to the preceding keyframe rather than the open again.
    ///
    /// The engine cannot be turned round in place. Its sample queue's
    /// ordering, its memory budget and whether it holds a software decoder
    /// are all fixed when it is built and all three differ between the two
    /// paths, so it is retired exactly the way an end of stream retires one -
    /// join, then lower the interrupt - which is a sequence a stream-backed
    /// file already survives today.
    private func fallBackFromDolbyVision(from resumeFrom: Double) {
        condition.lock()
        guard dolbyVisionCommitted, let current = engine, let open = demuxer,
              let video = videoStream, !isSpent
        else {
            condition.unlock()
            return
        }
        // Cleared before anything is torn down, so a second tick landing in
        // the span below finds nothing left to turn round.
        dolbyVisionCommitted = false
        recordHandedOver = false
        watchedFromPresentation = nil
        engine = nil
        engineGeneration += 1
        condition.unlock()
        cancelPictureWatchdog()
        // Retired the way an end of stream retires one: the file is only
        // being turned round, so the interrupt goes back down and the
        // demuxer stays readable.
        retireNaturally(current)

        // Never Dolby Vision again for this file: the probe said yes and the
        // layer showed nothing, which is the very verdict being acted on.
        rebuildVideoPath(
            over: open, video: video, capability: display(), allowDolbyVision: false,
            resumeFrom: resumeFrom, resumePlayback: true
        )
    }

    /// Re-reads the screen and, when its answer moves the decision this
    /// file's path was built on, turns the playback round onto the new one -
    /// the same turn-round the Dolby Vision fallback performs, resumed from
    /// where the clock stands. Wired to the platform's own screen-change
    /// notifications; public so a host that knows better can say so itself.
    public func displayConfigurationChanged() {
        let capability = display()
        condition.lock()
        guard let open = demuxer, let video = videoStream, !isSpent,
            let previous = adoptedCapability, capability != previous
        else {
            condition.unlock()
            return
        }
        // Only a change that moves a decision is worth a turn-round: the raw
        // headroom reading drifts, and a drift that stays on the same side
        // of every threshold must not cost the viewer a rebuild.
        let upscaling = allowsUpscaling()
        let decisionMoved =
            videoPath(for: video, capability: capability, upscalingAllowed: upscaling)
                != videoPath(for: video, capability: previous, upscalingAllowed: upscaling)
            || capability.toneMapPixelFormat != previous.toneMapPixelFormat
            || capability.supportsDolbyVision != previous.supportsDolbyVision
        adoptedCapability = capability
        condition.unlock()
        traceLine(
            "[lexis.open] display changed: headroom \(previous.headroom) -> \(capability.headroom),"
                + " eligible \(previous.eligibleForHDR) -> \(capability.eligibleForHDR),"
                + " dolby \(previous.supportsDolbyVision) -> \(capability.supportsDolbyVision),"
                + " \(decisionMoved ? "turning round" : "same path")")
        guard decisionMoved else { return }
        turnPathRound(over: open, video: video, capability: capability)
    }

    /// Retires whatever engine is live and rebuilds the path against
    /// `capability`, resumed from where the clock stands. The caller has
    /// already decided the turn is worth it, and holds no lock.
    private func turnPathRound(over open: Demuxer, video: MediaStream, capability: DisplayCapability) {
        condition.lock()
        guard demuxer === open, !isSpent else {
            condition.unlock()
            return
        }
        let current = engine
        let wasPaused = isPaused
        dolbyVisionCommitted = false
        recordHandedOver = false
        watchedFromPresentation = nil
        engine = nil
        engineGeneration += 1
        condition.unlock()
        cancelPictureWatchdog()
        let clock = sink.presentationTime
        let resumeFrom = clock.isFinite ? max(clock, 0) : 0
        if let current { retireNaturally(current) }
        rebuildVideoPath(
            over: open, video: video, capability: capability, allowDolbyVision: true,
            resumeFrom: resumeFrom,
            // A stopped or paused film is not restarted under the viewer:
            // the swapped path is simply what the next play() builds on.
            resumePlayback: current != nil && !wasPaused
        )
    }

    /// Rebuilds this file's video path against `capability`, without
    /// re-opening the stream: the demuxer, its socket and every byte its
    /// cache already holds all survive, so the switch costs a warm start and
    /// a seek back to the preceding keyframe rather than the open again.
    ///
    /// The engine cannot be turned round in place. Its sample queue's
    /// ordering, its memory budget and whether it holds a software decoder
    /// are all fixed when it is built and all three differ between the
    /// paths, so the caller retires it first, exactly the way an end of
    /// stream retires one.
    private func rebuildVideoPath(
        over open: Demuxer, video: MediaStream, capability: DisplayCapability,
        allowDolbyVision: Bool, resumeFrom: Double, resumePlayback: Bool
    ) {
        let audio = preferredAudioStream(among: open.streams, route: choosingRoute())
        let dolbyVisionAllowed = allowDolbyVision && allowsDolbyVision()
        let dolbyVisionFormat = dolbyVisionAllowed
            ? dolbyVisionPassthroughFormat(for: video, capability: capability)
            : nil
        // `failDirectly` and not `abandonPlayback`, here and below: the engine
        // is already retired, and a sentence that waits for a live one to
        // retire would never be said at all.
        let path = videoPath(
            for: video, capability: capability, dolbyVisionPassthrough: dolbyVisionFormat != nil,
            upscalingAllowed: allowsUpscaling()
        )
        let recordRides = dolbyVisionAllowed && path != .decoded
        guard let format = dolbyVisionFormat
            ?? (try? makeFormatDescription(for: video, dolbyVisionRecord: recordRides))
        else {
            failDirectly(.failed("no plain description for a stream that had one at open"))
            return
        }
        let upscaleSize = path == .upscaled ? upscaleTarget(for: video, capability: capability) : nil
        let debandStrength = Deband.strength(for: video, fileBitsPerSecond: open.bitsPerSecond)
        let budget = PlayerEngine.budget(
            for: open, video: video, audio: audio,
            toneMapPixelFormat: picturePixelFormat(
                path, capability: capability, upscaling: upscaleSize != nil),
            processedSize: upscaleSize,
            policy: policy
        )
        if let shortfall = budget.shortfall {
            // The pictures the mapped path holds are the ones the passthrough
            // path never had to: a film that fits one need not fit the other,
            // and this is the same sentence `adopt` gives at the open.
            failDirectly(
                .tooLargeForMemory(
                    requiredBytes: shortfall.requiredBytes, allowedBytes: shortfall.allowedBytes
                ))
            return
        }
        let box = EngineBox()
        var mapped: ToneMappedVideo?
        if path == .decoded {
            mapped = try? ToneMappedVideo(
                decodingOnly: format,
                videoDelay: video.videoDelay,
                budgetBytes: budget.pictureReserveBytes,
                rendererAttributes: sink.recommendedPictureAttributes
            ) { [weak box] sample in
                box?.engine?.pushToneMappedFrame(sample)
            }
        } else if path == .toneMapped {
            let reshapes = video.dolbyVision.map { !$0.baseLayerIsDisplayable } ?? false
            mapped = try? ToneMappedVideo(
                formatDescription: format,
                sourcePeakPQ: contentPeakPQ(video.contentLight)
                    ?? masteringPeakPQ(video.masteringDisplay),
                sourceBlackPQ: masteringBlackPQ(video.masteringDisplay),
                sourceIsHLG: isHybridLogGamma(video.colorTransfer),
                videoDelay: video.videoDelay,
                capability: capability,
                budgetBytes: budget.pictureReserveBytes,
                queueBytes: budget.videoSampleBytes,
                rendererAttributes: sink.recommendedPictureAttributes,
                reshapesDolbyVision: reshapes,
                // a codec the device cannot decode is decoded by the engine
                decodesItself: hardwareDecodes(video) != false
            ) { [weak box] sample in
                box?.engine?.pushToneMappedFrame(sample)
            }
        } else if path == .upscaled, let upscaleSize {
            mapped = try? ToneMappedVideo(
                formatDescription: format,
                upscalingTo: upscaleSize,
                neural: allowsNeuralUpscaling(),
                picturesPerSecond: video.outputFrameRate,
                videoDelay: video.videoDelay,
                budgetBytes: budget.pictureReserveBytes,
                queueBytes: budget.videoSampleBytes,
                sourceBitDepth: video.bitDepth,
                rendererAttributes: sink.recommendedPictureAttributes,
                debandStrength: debandStrength,
                fields: FieldOrder(of: video)
            ) { [weak box] sample in
                box?.engine?.pushToneMappedFrame(sample)
            }
        }
        // The field builder at the film's own size: an interlaced film, and
        // one whose scaler would not build.
        let fields = FieldOrder(of: video)
        if mapped == nil, path == .deinterlaced || (path == .upscaled && fields != nil) {
            mapped = try? ToneMappedVideo(
                enhancing: format,
                sourceBitDepth: video.bitDepth,
                videoDelay: video.videoDelay,
                budgetBytes: budget.pictureReserveBytes,
                queueBytes: budget.videoSampleBytes,
                rendererAttributes: sink.recommendedPictureAttributes,
                fields: fields
            ) { [weak box] sample in
                box?.engine?.pushToneMappedFrame(sample)
            }
        }
        mapped?.onPictureLost = { [weak box] error in box?.engine?.pictureLost(error) }
        mapped?.onPictureFolded = { [weak box] in box?.engine?.releaseSubmittedPicture() }
        sink.setWantsExtendedDynamicRange(wantsExtendedRange(mapped))

        condition.lock()
        // a close(), or another open(), while the mapper was being built
        guard demuxer === open else {
            condition.unlock()
            return
        }
        formatDescription = format
        dolbyVisionCommitted = dolbyVisionFormat != nil
        recordHandedOver = dolbyVisionFormat != nil
            || (recordRides && video.dolbyVision?.recordDescribesWhatIsHandedOver == true)
        adoptedCapability = capability
        let replaced = toneMapped
        toneMapped = mapped
        self.budget = budget
        engineBox = box
        statsLock.lock()
        currentStats.videoPassthrough = mapped == nil
        currentStats.videoPath = mapped == nil ? .passthrough
            // the scaler that would not build left the field builder at the film's size
            : path == .upscaled && mapped?.upscaledSize == nil ? .deinterlaced
            : path
        currentStats.videoDescription = fourCharCode(CMFormatDescriptionGetMediaSubType(format))
        currentStats.dolbyVisionProfile = Int32(video.dolbyVision?.profile ?? 0)
        let upscaled = mapped?.upscaledSize
        currentStats.videoUpscaled = upscaled != nil
        currentStats.upscaleWidth = upscaled?.width ?? 0
        currentStats.upscaleHeight = upscaled?.height ?? 0
        statsLock.unlock()
        condition.unlock()
        // Letting go of the old path waits out its decoder: never under the lock.
        withExtendedLifetime(replaced) {}

        guard resumePlayback else { return }
        // Back to where the picture was meant to start. Nothing was seen of
        // the span between, so nothing is lost by playing it again.
        seek(to: resumeFrom)
        play()
    }

    /// What a seek performed with no engine alive reaches on its own failure
    /// path: nothing here is a reader thread's own unwind, but the player
    /// state a failure leaves behind is the same either way.
    private func failDirectly(_ event: PlayerEvent) {
        condition.lock()
        isPaused = false
        isSpent = true
        condition.unlock()
        continuation.yield(event)
    }
}

/// A CoreMedia four character code as the string it spells: 'dvh1', 'hvc1'.
func fourCharCode(_ code: FourCharCode) -> String {
    let bytes = [
        UInt8(code >> 24 & 0xff), UInt8(code >> 16 & 0xff), UInt8(code >> 8 & 0xff), UInt8(code & 0xff),
    ]
    return String(bytes: bytes, encoding: .ascii) ?? ""
}

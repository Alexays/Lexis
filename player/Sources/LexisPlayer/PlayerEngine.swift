import CoreMedia
import VideoToolbox
import Foundation
import os.signpost
import Synchronization

/// What Instruments sees of the pull pipeline: one `OSSignposter` per stage,
/// so the os_signpost instrument lands each stage on its own lane instead of
/// interleaving five kinds of interval under one category. Filter Instruments
/// on `subsystem`, then read the stages side by side.
///
/// Never `OSSignposter.disabled`: a disabled signposter compiles the marks
/// away and leaves an Instruments trace that looks like a pipeline doing
/// nothing at that stage, which is worse than no lane at all.
enum PipelineSignposts {
    static let subsystem = "org.lexis.player"
    /// One span of bytes leaving the source, inside `ByteCache`'s pump.
    static let fetch = OSSignposter(subsystem: subsystem, category: "fetch")
    /// One `readPacket` off the demuxer, on the demux thread.
    static let demux = OSSignposter(subsystem: subsystem, category: "demux")
    /// One packet handed to a decoder, on the video decode thread.
    static let decode = OSSignposter(subsystem: subsystem, category: "decode")
    /// One push into the video sample queue, which is where the sink's own
    /// backpressure shows up as time.
    static let enqueue = OSSignposter(subsystem: subsystem, category: "enqueue")
    /// One starved-buffer pause, from the stall to the refill.
    static let rebuffer = OSSignposter(subsystem: subsystem, category: "rebuffer")
    /// The stages of one press-play, before any of the above has run once.
    /// Its own lane because it is a single sequence per playback, not a
    /// per-packet stream: see `OpenTrace`.
    static let startup = OSSignposter(subsystem: subsystem, category: "startup")

    /// Every stage, in pipeline order, for whoever enumerates them.
    static let all: [(stage: String, signposter: OSSignposter)] = [
        ("fetch", fetch), ("demux", demux), ("decode", decode),
        ("enqueue", enqueue), ("rebuffer", rebuffer),
    ]
}

enum EngineEvent: Equatable {
    case firstFrame(seconds: Double)
    case endOfStream
    case failed(String)
    case unauthorized
    /// tvOS took the decoder back while the app was off screen: every
    /// session this engine holds is invalid, and the path has to be built
    /// again from where the clock stands rather than declared failed.
    case decoderTakenBack
    /// Pictures reached the sink late with their packets waiting: the
    /// processing, not the source, is short. Just ahead of the `.buffering`
    /// that holds the clock for it.
    case decodeFellBehind
    /// The combined buffer (packet queue plus sample queue, video and audio
    /// both) crossed the low watermark going down mid-playback: the sink's
    /// rate goes to 0 and stays there until `.resumed`. Never fired for a
    /// real end of stream draining toward zero, only for a starved pipeline
    /// with more content still to come.
    case buffering(bufferedSeconds: Double)
    /// The same buffer recovered to what that wait was holding for - halfway
    /// to the high watermark for a starvation, the low one for the frame a
    /// seek landed on, depth in the picture queue for a decoder that fell
    /// behind - or a real end of stream made waiting pointless: the sink's
    /// rate returns to whatever the caller's own pause state asks for.
    case resumed
}

struct EngineStatistics: Sendable, Equatable {
    var packetsRead = 0
    var framesDisplayed = 0
    /// Frames handed to the sink after its clock had already passed them: a
    /// decode slower than the film. A pipeline that keeps up leaves it at 0.
    var framesDropped = 0
    /// Pictures nothing predicts from, left undecoded while the decoder was
    /// behind the clock: a skipped picture is what keeps the rest on time.
    var framesSkipped = 0
    var videoBufferedSeconds = 0.0
    var audioBufferedSeconds = 0.0
    /// min(video, audio), the honest buffer health the spec asks for. The
    /// audio term counts only while a track is selected: taking the sound off
    /// leaves `audioPacketQueue` in place with nothing left to fill it, and a
    /// minimum over that dead queue would hold the engine in a rebuffer it can
    /// never leave.
    var bufferedSeconds = 0.0
    /// How many times a starved buffer paused playback and refilled it: the
    /// honest, counted alternative to dropping a frame.
    var rebufferCount = 0
    /// Pulls that found no decoded picture and did not become a rebuffer: the
    /// renderer asked, the pipeline had nothing, and playback carried on. This
    /// is what a micro stall looks like from in here, and unlike
    /// `framesDropped` it counts on the passthrough path too, where the
    /// renderer decodes and a frame's time says nothing about this pace.
    var pictureStarvations = 0
    /// From the `seek(to:completion:)` call that asked for the last landed
    /// frame to that frame actually crossing the sink; 0 = UNMEASURED,
    /// before any seek has landed one.
    var lastSeekLatencySeconds = 0.0
    /// Pictures the file carried that no route could turn into a frame: a
    /// decoder, a pool or a sample buffer refused them. Terminal, so this
    /// reads 1 far more often than it reads more - it is the magnitude
    /// beside the `.failed` event, and the reading a caller that only ever
    /// sees statistics has. Stays 0 on a file every route can decode.
    var decodeFailures = 0
    /// Why the audio decoder first refused a packet, nil while it never has.
    /// Held for the rest of the track, whether or not the sound came back:
    /// a viewer who lost it needs to know why, and one who got it back is
    /// owed the record that it broke.
    var audioFailureReason: String?
    /// True once the route refused the compressed format and the track went
    /// on through the decoder. The renderer's own error is cleared by the
    /// flush that recovery needs, so this is what still says it happened.
    var audioRouteRefused = false
}

/// Every span the pipeline reasons in, together, so a caller playing a
/// clip of a different order of magnitude can state them at its own
/// scale instead of inheriting a reference film's.
///
/// One value, never several: the watermarks, the sample targets and the
/// poll cadence are only meaningful against each other, and a test that
/// moved one of them alone would be asking a question the engine never
/// answers in the field.
/// How deep the read-ahead runs, from the connection's own margin: the ratio
/// of the measured sustained rate to what the film consumes. Comfortable
/// margins keep the policy's own seconds; a narrow one buys more of them,
/// which is cheap in bytes precisely because the stream is slow - the same
/// arithmetic `PipelineBudget` applies in the other direction. Below the
/// narrow band no read-ahead saves the playback, and deeper seconds only
/// delay the stall: that case belongs to a lighter rendition, not to a
/// buffer.
///
/// Coarse quantized bands, so a measurement that flutters between two
/// readings moves nothing: a target that follows the noise makes the server
/// and TCP chase it. The policy's own seconds while nothing is measured yet,
/// so the unmeasured path is exactly what it always was.
enum AdaptiveReadAhead {
    static func readAheadSeconds(
        policy: BufferPolicy, sustainedBitsPerSecond: Double, streamBitsPerSecond: Double
    ) -> Double {
        guard sustainedBitsPerSecond > 0, streamBitsPerSecond > 0 else {
            return policy.highWatermarkSeconds
        }
        let margin = sustainedBitsPerSecond / streamBitsPerSecond
        if margin >= 2.5 { return policy.highWatermarkSeconds }
        if margin >= 1.2 { return policy.highWatermarkSeconds * 2 }
        return policy.highWatermarkSeconds * 3
    }
}

public struct BufferPolicy: Sendable, Equatable {
    /// Stage 3's own watermarks on the combined (packet queue plus sample
    /// queue) figure `bufferedSeconds` already reports, applied to when
    /// playback itself pauses and resumes rather than to when the demux
    /// thread parks.
    ///
    /// `bufferedSeconds` is a minimum over the tracks, and the tracks are
    /// fed by one demux thread that parks on whichever packet queue fills
    /// first - so the minimum cannot be counted on to ever reach the high
    /// figure, and `refillIsHopeless` is what ends a rebuffer waiting for
    /// it to.
    public var lowWatermarkSeconds: Double
    public var highWatermarkSeconds: Double
    /// What the sample queues are asked for, in the unit playback reasons
    /// in. The budget converts them into bytes at this film's own rates
    /// and hands back whatever it affords, so these are a want and never
    /// a promise.
    public var videoSampleTargetSeconds: Double
    public var audioSampleTargetSeconds: Double
    /// The longest the decode thread sleeps between looks while it paces
    /// pictures to the frame rate or waits for one back from the mapped
    /// path, so a flush is seen within it.
    public var pollInterval: TimeInterval
    /// The ring the reader keeps over the stream. A span the engine reasons
    /// in like the others, and the one the rest are measured against: an
    /// event only reaches the reader at all past what this can already hold,
    /// so a caller scaling the seconds down has to scale this with them or
    /// the whole clip fits in the window and nothing ever stalls.
    public var readAheadBytes: Int
    /// How long the clock may run with no picture on screen before the path
    /// in play is judged not to be working. A span like the others: a caller
    /// playing a clip orders of magnitude shorter states its own, or a
    /// verdict that takes a second to reach is most of what that clip costs.
    public var firstPictureGraceSeconds: Double
    /// How often that is looked at. Several ticks to the grace above, or the
    /// budget is spent in one look and the reading is the timer's, not the
    /// pipeline's.
    public var pictureWatchdogInterval: TimeInterval
    /// What a seek's landed frame waits for behind it before the clock runs
    /// again. Shallower than the low watermark a cold start holds for: the
    /// viewer is looking at the frame they aimed at, and every second here
    /// is a second the picture stands still after every press.
    public var seekResumeSeconds: Double
    /// How much of the film may pass with every picture refused before it is
    /// judged broken rather than damaged here and there.
    public var undecodablePictureSeconds: Double

    public init(
        lowWatermarkSeconds: Double,
        highWatermarkSeconds: Double,
        videoSampleTargetSeconds: Double,
        audioSampleTargetSeconds: Double,
        pollInterval: TimeInterval,
        readAheadBytes: Int,
        firstPictureGraceSeconds: Double,
        pictureWatchdogInterval: TimeInterval,
        seekResumeSeconds: Double = 1.0,
        undecodablePictureSeconds: Double = 5.0
    ) {
        self.lowWatermarkSeconds = lowWatermarkSeconds
        self.highWatermarkSeconds = highWatermarkSeconds
        self.videoSampleTargetSeconds = videoSampleTargetSeconds
        self.audioSampleTargetSeconds = audioSampleTargetSeconds
        self.pollInterval = pollInterval
        self.readAheadBytes = readAheadBytes
        self.firstPictureGraceSeconds = firstPictureGraceSeconds
        self.pictureWatchdogInterval = pictureWatchdogInterval
        self.seekResumeSeconds = seekResumeSeconds
        self.undecodablePictureSeconds = undecodablePictureSeconds
    }

    /// The figures a film plays under, measured off the reference file.
    public static let standard = BufferPolicy(
        lowWatermarkSeconds: 2.0,
        highWatermarkSeconds: 8.0,
        videoSampleTargetSeconds: 1.0,
        audioSampleTargetSeconds: 2.0,
        pollInterval: 0.02,
        readAheadBytes: ByteCache.windowCapacity,
        firstPictureGraceSeconds: 1.0,
        pictureWatchdogInterval: 0.2,
        seekResumeSeconds: 1.0
    )
}

/// The pull pipeline. Threads: one demux (readPacket -> per-stream
/// PacketQueues), one video decode (PacketQueue -> VideoToolbox or the
/// passthrough path -> SampleQueue), one audio decode. The sink's
/// synchronizer is THE clock: nothing here sleeps to pace, nothing is ever
/// "late", rate transitions (setPaused) are the only tempo control.
final class PlayerEngine {
    /// How far ahead of its clock the renderer is fed compressed samples:
    /// past the deepest reorder a B-frame stream needs.
    static let passthroughRunwaySeconds = 0.5

    struct Tracks {
        var video: MediaStream
        var audio: MediaStream?
        var subtitle: MediaStream?
    }

    /// The same division of labor `LexisPlayer.selectAudioTrack` already has
    /// with the old reader: the caller builds the pipeline (FFmpeg and
    /// format description work) off the demux thread, and hands the
    /// finished value over.
    enum AudioPipeline {
        case decoded(AudioDecoder)
        case passthrough(CompressedAudioFormat, CMAudioFormatDescription)
    }

    private enum AudioSelection {
        case off
        case on(MediaStream, AudioPipeline)
    }

    private enum SubtitleSelection {
        case off
        case on(MediaStream, SubtitleDecoder?, Bool)
    }

    /// One stream's packets read and not yet reached by the clock, oldest
    /// first from `head`. The front is pruned by moving `head`, and the dead
    /// prefix is dropped once it is a quarter of the array, so a prune never
    /// shifts a window thousands of packets deep.
    private struct RetainedWindow {
        var packets: [Packet] = []
        var head = 0
        /// What the live packets, from `head`, hold.
        var bytes = 0

        /// Prunes what `now` has run past, and the oldest past `capacityBytes`,
        /// then appends. Packets arrive in stream order, so the front is
        /// always the oldest.
        mutating func append(_ packet: Packet, timeBase: Double, now: Double, capacityBytes: Int) {
            while head < packets.count, let front = packets[head].pts ?? packets[head].dts,
                (Double(front) + Double(packets[head].duration)) * timeBase <= now
            {
                bytes -= packets[head].byteCount
                head += 1
            }
            while head < packets.count, bytes + packet.byteCount > capacityBytes {
                bytes -= packets[head].byteCount
                head += 1
            }
            if head >= 256, head * 4 >= packets.count {
                packets.removeFirst(head)
                head = 0
            }
            packets.append(packet)
            bytes += packet.byteCount
        }
    }

    let policy: BufferPolicy

    private let demuxer: Demuxer
    private let tracks: Tracks
    private let sink: FrameSink
    private let toneMapped: ToneMappedVideo?
    /// Live per file, never a table: `VTIsHardwareDecodeSupported` is asked
    /// once, here, for this stream's own codec. nil whenever hardware can
    /// decode it (the passthrough or tone-mapped path already covers that)
    /// or when FFmpeg itself has no decoder for it either.
    private let softwareDecoder: SoftwareVideoDecoder?
    private let interrupt: InterruptFlag

    private let videoFormatDescription: CMVideoFormatDescription?
    /// A profile 7 stream going to the display layer described as 8.1: each
    /// access unit is rewritten to match.
    private let handsOverProfileSevenAsEightOne: Bool
    private let videoLengthSize: Int
    /// The stream's own frame period, for putting a container's rounded
    /// timestamps back on the grid; nil where the container states no rate.
    private let videoFrameDuration: CMTime?

    /// Every byte ceiling below, derived at open from what this device will
    /// still give the process and what this film's own pictures cost.
    let budget: PipelineBudget

    private let videoPacketQueue: PacketQueue
    private let audioPacketQueue: PacketQueue?
    private let videoSampleQueue: SampleQueue
    private let audioSampleQueue: SampleQueue?

    /// userInitiated, not userInteractive: the pipeline must not lose to UI
    /// churn while a film plays, and the reverse priority would let it starve
    /// the interface instead.
    private let videoPullQueue = DispatchQueue(
        label: "org.lexis.player.engine.video-pull", qos: .userInitiated)
    private let audioPullQueue = DispatchQueue(
        label: "org.lexis.player.engine.audio-pull", qos: .userInitiated)

    // One id per stage, per engine: two engines alive at once (a film and a
    // probe) would otherwise interleave their intervals under the shared
    // `.exclusive` id and read in Instruments as one impossibly long stage.
    // Each stage below runs on a single thread, so its own intervals never
    // overlap each other.
    private let demuxSignpostID = PipelineSignposts.demux.makeSignpostID()
    private let decodeSignpostID = PipelineSignposts.decode.makeSignpostID()
    private let enqueueSignpostID = PipelineSignposts.enqueue.makeSignpostID()
    private let rebufferSignpostID = PipelineSignposts.rebuffer.makeSignpostID()

    private let joinGroup = DispatchGroup()
    private var demuxThread: Thread?
    private var videoThread: Thread?
    private var audioThread: Thread?

    /// Guards every piece of playback-control state below: the pending seek
    /// a public method hands the demux thread, and the flags the providers
    /// read to decide when the stream has truly ended.
    private let lock = NSLock()
    private var pendingSeek: (target: Double, completion: (Double) -> Void)?
    private var audioStream: MediaStream?
    private var audioPipeline: AudioPipeline?
    /// Told, on the audio thread, the format a route refused, the track it
    /// was refused for and the decoder that replaced it. Set before `start`.
    var onPassthroughRefused: ((CompressedAudioFormat, MediaStream, AudioDecoder) -> Void)?
    /// Raised by an audio swap for as long as it waits on the audio pull
    /// queue. A pull parked in a refill a pause keeps from resolving lets go
    /// when it reads this, rather than holding the swap, and the control
    /// queue behind it, for as long as the pause lasts.
    private var audioSwapsWaiting = 0
    /// Guards the subtitle selection and the retained windows below: what the
    /// demux thread routes packets by and no pull thread reads, so neither a
    /// replay decoding a bitmap window nor the read-ahead pruning its windows
    /// holds up a frame. Taken before `lock` wherever both are held.
    private let retainedLock = NSLock()
    private var subtitleStream: MediaStream?
    private var subtitleDecoder: SubtitleDecoder?
    private var subtitleIsStyled = false
    /// The time base of every subtitle stream the container carries, by
    /// index, whether or not one is selected: what `retainedSubtitles` needs
    /// to know a subtitle packet when it sees one, and to place it in time.
    /// The figure alone, so routing a packet copies no `MediaStream`.
    private let subtitleTimeBases: [Int32: Double]
    /// The same, for audio: what tells an unselected audio packet apart from
    /// any other stream's, so `retainedAudio` can hold it against a selection.
    private let audioTimeBases: [Int32: Double]
    /// The subtitle packets the demux thread has already read whose moment is
    /// still to come. The demux thread runs a whole packet queue ahead of the
    /// clock (8 s, `PacketQueue.Configuration`), and a track selected now
    /// would otherwise draw nothing until the reader got past that window -
    /// eight seconds of a viewer turning subtitles on and watching an empty
    /// screen. Held for every subtitle stream, since which one is chosen is
    /// not knowable in advance, and pruned by the clock, so it holds the
    /// read-ahead window and never a film.
    private var retainedSubtitles: [Int32: RetainedWindow] = [:]
    /// The same window, for the audio streams that are not selected. Without
    /// it a chosen track can only start where the demux thread has already
    /// read to - a whole packet queue ahead of the clock, measured at eleven
    /// seconds on the tvOS app - and the viewer hears nothing until then.
    /// Pruned by the clock, and the demux thread parks on the watermark once
    /// the queues are full, so this holds the read-ahead and never a film.
    private var retainedAudio: [Int32: RetainedWindow] = [:]
    /// Bumped by every seek, right before its queue flushes run. The video
    /// decode thread is free-running against its own packet queue, on its
    /// own thread, so a flush can land between one of its pops and the
    /// matching push - this is what lets it tell that its own in-flight
    /// packet belongs to the position the seek just left, and drop the
    /// result instead of handing the sink a sample from before the target.
    ///
    /// Written under `lock`, beside the state it moves with; atomic so the
    /// per-packet checks read it without taking the lock.
    private let flushGeneration = Atomic<Int>(0)
    /// The same discipline as `flushGeneration`, for the audio pipeline
    /// specifically: bumped by every seek AND by every audio track swap,
    /// since a swap flushes only the audio side and must not disturb video
    /// packets or samples already in flight from before it. Video never
    /// reads this counter, and audio never reads `flushGeneration` alone,
    /// so an audio-only swap cannot cost a video frame it has nothing to
    /// do with. Written under `lock`, read without it, as `flushGeneration`.
    private let audioFlushGeneration = Atomic<Int>(0)
    /// How much later than the picture the sound plays, in microseconds:
    /// added to every sample as it leaves for the renderer.
    private let audioDelayMicroseconds = Atomic<Int>(0)
    /// True for the span of `applySeek` from just before it bumps
    /// `flushGeneration` until the sample queues are actually emptied. A generation bump
    /// alone only catches a packet or a sample already out of ITS OWN
    /// queue when the bump lands; a sample still legitimately sitting in a
    /// sample queue that has not been flushed YET reads the same (new)
    /// generation on both sides of a pop landing in this span and passes
    /// unnoticed - confirmed rare but real by running the seek suite
    /// repeatedly without this guard, not merely theoretical. Pulling
    /// refuses outright for this span instead of trusting generation
    /// matching alone. Written under `lock`, read without it, as
    /// `flushGeneration`.
    private let seekInProgress = Atomic<Bool>(false)
    private var awaitingFirstFrame = true
    /// True from `applySeek` until the landed frame - the first sample
    /// decoded from the keyframe a seek lands on - has crossed the sink.
    /// Kept apart from `awaitingFirstFrame`: both frames are shown once, at
    /// rate 0, and then gate every further frame until the buffer clears a
    /// watermark, but they hold to different ones (`RefillHold`) and only
    /// this one carries a completion and a latency to report.
    private var awaitingLandedFrame = false
    /// Called with the landed frame's own PTS once it crosses the sink -
    /// never with the raw seek target, which a keyframe can land before.
    /// Cleared the moment it fires, or silently dropped by a later seek that
    /// supersedes this one before it does.
    private var seekLandedCompletion: ((Double) -> Void)?
    /// Host time `seek(to:completion:)` was called at, read back once the
    /// landed frame crosses the sink to time the whole span: overwritten by
    /// each new seek the same way `seekLandedCompletion` is, so a superseded
    /// seek never times its successor's landing.
    private var seekRequestedAtHostTime: Double?
    /// Which refill holding the clock at rate 0 `isBuffering` is currently
    /// holding for; nil while it holds for an ordinary mid-playback starvation
    /// instead. The two that put a frame up re-anchor the clock at
    /// `refillResumePTS` when they resolve (the frame on screen is one the
    /// clock has not run to yet), where a starvation resumes the rate where
    /// the clock already stood, and both hold to the LOW watermark: a frame is
    /// already up and the viewer is looking at it, where an ordinary
    /// starvation has nothing up behind it and refills halfway to the high
    /// one. Holding a seek out for more instead spends the whole refill of a
    /// thrown-away buffer before the picture moves again, which over a source
    /// delivering near the film's own bitrate is that many wall-clock
    /// seconds, every seek.
    private enum RefillHold {
        case coldStart
        case landedFrame
        /// Frames reaching the sink late with packets waiting to be decoded:
        /// the decoder is what is short. Resumes where the clock stood, once
        /// the picture queue has depth again, so the sound does not run on
        /// ahead of a picture that cannot keep up with it.
        case decodeDeficit
    }

    private var refillHold: RefillHold?
    /// The held frame's own PTS, read back by `waitOutStarvation`'s recovery
    /// step once `refillHold` is set. Set alongside it, cleared alongside it.
    private var refillResumePTS: Double?
    private var isPaused = false
    /// True whenever the video decode thread has nothing left to do until
    /// either more packets arrive or it is closed for good - not the same
    /// as the thread itself having returned, since a packet queue reaching
    /// its end (as opposed to being closed) parks this thread rather than
    /// ending it, resumable by a later seek the same way the demux thread's
    /// own park is. Read only by the demux thread's own park loop, to know
    /// there is nothing left running worth waiting on a seek for.
    private var videoDecodeIdle = false
    /// True once the video decode thread has actually returned: unlike
    /// `videoDecodeIdle`, this is what `.endOfStream` waits for, since a
    /// tone-mapped stream's reorder window is only drained in that thread's
    /// own teardown - firing the event as soon as the packet queue empties
    /// would leave whatever the window is still holding back never reaching
    /// the sink at all.
    private var videoDecodeDone = false
    private var audioDecodeDone: Bool
    /// True only once `demuxer.readPacket()` itself answered nil: what tells
    /// a real end of stream apart from a stop or an interrupt, both of which
    /// also drain the decode threads but must stay quiet.
    private var reachedRealEndOfStream = false
    private var endOfStreamFired = false
    /// Where the last packet read of the video and of the playing audio
    /// ends, in stream seconds: the demux thread's own running reading, and
    /// the copy taken at a real end, under `lock`, which `.endOfStream` waits
    /// for the clock to reach.
    private var readEnd = 0.0
    private var streamEnd = 0.0
    /// True once the sink itself has pulled and found nothing, with decode
    /// idle too: unlike `videoDecodeIdle` alone, this is paced by the sink's
    /// own real-time pulls (a display layer buffers ahead of what it is
    /// currently showing, and only asks again as real playback catches up
    /// to what it already has), so the demux thread's own park loop reads
    /// this instead - `videoDecodeIdle` on its own would give up on a seek
    /// as soon as decode finished handing everything off, well before the
    /// sink has actually gotten around to showing any of it.
    private var videoDeliveryDrained = false
    /// Pictures submitted to the processed path and not yet pushed back into
    /// the sample queue. Under `lock`.
    ///
    /// The queue's own byte bound is enforced by `waitForRoom`, BEFORE
    /// submission - and `pushWithoutWaiting` then accepts whatever comes
    /// back, deliberately: a picture already in flight is held either way,
    /// better queued than lost. That leaves the span between the two - decode,
    /// reorder, the GPU pass - bounded by nobody, and it was assumed small.
    /// On the processed path it is not: at an open the demux is eight seconds
    /// of packets ahead, decode submits them all, and 44 output-size pictures
    /// were measured alive at once before the first had landed. 1.4 GiB, and
    /// the process killed for it.
    /// Guards `picturesSubmitted` and wakes the gate the moment a picture
    /// comes back: a poll would add its whole interval to every frame once
    /// the bound is reached, which caps production at the poll rate.
    private let picturesCondition = NSCondition()
    private var picturesSubmitted = 0
    /// Where a pull waiting out a starvation and the demux thread parked at a
    /// real end of stream wait, untimed. Every change either one reads is
    /// followed by `wakeParked`, from a thread holding neither `lock` nor a
    /// queue's lock: the waiters take both while holding this.
    private let parkCondition = NSCondition()
    /// How many threads wait on `parkCondition`, so a queue filling wakes
    /// nobody when nobody waits.
    private let parkWaiters = Atomic<Int>(0)
    /// The read-ahead the connection's margin currently asks for, which the
    /// packet queues' watermark follows. Demux thread only.
    private var adaptiveReadAheadSeconds: Double
    /// Packets between two looks at the connection: a few times a second at
    /// an ordinary bitrate, and each look is two loads and a divide.
    private var packetsSinceAdaptiveCheck = 0
    /// The clock as the retained windows prune by, read on that same cadence
    /// rather than for every packet: a window pruned a fraction of a second
    /// late holds a few more packets, and a replay drops them against the
    /// clock it reads itself. Demux thread only.
    private var retainedWindowClock = 0.0
    /// How many pictures may be outstanding, two a frame for fields: the
    /// stream's own reorder depth, plus one decoding, one in each GPU pass,
    /// and one spare so none of them ever waits on another. The processors' pools are sized four beyond that. The reorder window's residents count as submitted
    /// (they come back to the queue only when evicted), so a bound that
    /// ignored the depth would hand the window the whole allowance and
    /// throttle production to nothing on a stream with B-frames.
    private let mostPicturesSubmitted: Int
    /// When the decode thread last handed the mapped path a picture, in host
    /// seconds. The decode thread's alone.
    private var lastPictureSubmitted: Double = 0
    /// True for the span between a `.buffering` event and its matching
    /// `.resumed`: distinct from `isPaused`, which is the caller's own
    /// intent. A video and an audio pull can both notice the same drain
    /// around the same moment, so every read and write of this flag is
    /// paired with the check that made it true, under `lock`, so only the
    /// first caller to notice acts and every later one just waits out (or
    /// observes) the same event.
    private var isBuffering = false
    /// How far behind the clock the frames in a row the sink was handed late
    /// were, added up, each one after a pull that found nothing decoded: a
    /// renderer that sets the pace itself keeps the queue full, and its
    /// lateness is its own. `videoPullQueue` only.
    private var lateSeconds = 0.0
    /// Whether the last pull found the picture queue empty. `videoPullQueue`
    /// only.
    private var pullCameUpEmpty = false
    /// How much of that makes a decoder falling behind rather than a thread
    /// descheduled for a beat: frames a millisecond late are not worth a
    /// pause, and three a whole frame late are.
    private static let latenessBeforeHold = 0.1
    /// Set by the video pull while the frames it waited for come up late,
    /// cleared by the first one on time: the decode thread then leaves the
    /// pictures nothing predicts from undecoded, so the decoder catches up
    /// by skipping one picture here and there rather than by freezing the
    /// picture for a hold.
    private let decoderBehind = Atomic<Bool>(false)
    /// Pictures refused since the last one decoded, and whether the decode
    /// thread passes over what precedes the next keyframe: a picture decoded
    /// against a refused one is that damage again.
    private let failuresSincePicture = Atomic<Int>(0)
    private let skipToKeyframe = Atomic<Bool>(false)
    private let decodedAnyPicture = Atomic<Bool>(false)
    /// The packet the film stopped decoding at, and the flush it belongs to:
    /// a seek starts the span over. Decode thread only.
    private var undecodedSince: (generation: Int, pts: Int64)?
    /// What tells those pictures apart, nil for a codec it cannot read.
    private let nonReference: NonReferencePictures?

    private let statsLock = NSLock()
    private var stats = EngineStatistics()
    /// `stats.packetsRead`, kept out of `statsLock`: the demux thread counts
    /// every packet.
    private let packetsRead = Atomic<Int>(0)
    /// Under `statsLock`: why the last picture was refused, which is what a
    /// film given up on says.
    private var lastDecodeFailure: String?

    let events: AsyncStream<EngineEvent>
    private let continuation: AsyncStream<EngineEvent>.Continuation

    /// Every ceiling the queues below hold themselves to, from what this
    /// device will still give the process and what this film's own pictures
    /// and packets cost. A track that states its own rate is believed; one
    /// that does not falls back on the file's, which FFmpeg computes from its
    /// size and its duration - a remux is nearly all video, so that is the
    /// closer reading of the two. Compressed audio never exceeds the PCM it
    /// decodes to, which is what stands in where the track says nothing.
    static func budget(
        for demuxer: Demuxer, video: MediaStream, audio: MediaStream?,
        toneMapPixelFormat: OSType?,
        /// The size the processed path renders at, where it differs from the
        /// stream's own: the upscaled path holds output-size pictures, and a
        /// budget weighed at the source size would be short by the square of
        /// the factor.
        processedSize: (width: Int32, height: Int32)? = nil,
        policy: BufferPolicy = .standard
    ) -> PipelineBudget {
        let decodedAudioBytesPerSecond = audio.map {
            Int($0.sampleRate) * Int($0.channels) * MemoryLayout<Float>.size
        } ?? 0
        // Every audio track but the one playing has a window kept of it, and
        // any of them may be the one playing later: each is weighed at the
        // costliest rate.
        var retainedAudioTracks = 0
        var retainedAudioBytesPerSecond = 0
        for stream in demuxer.streams where stream.kind == .audio {
            retainedAudioBytesPerSecond = max(
                retainedAudioBytesPerSecond,
                stream.bitsPerSecond > 0
                    ? Int(stream.bitsPerSecond / 8)
                    : Int(stream.sampleRate) * Int(stream.channels) * MemoryLayout<Float>.size)
            if stream.index != audio?.index { retainedAudioTracks += 1 }
        }
        let pictureBytes = pictureFormat(for: video, toneMapPixelFormat: toneMapPixelFormat).map {
            decodedPictureBytes(
                width: Int(processedSize?.width ?? video.width),
                height: Int(processedSize?.height ?? video.height), pixelFormat: $0
            )
        } ?? 0
        return PipelineBudget(
            available: availableMemoryBytes(),
            pictureBytes: pictureBytes,
            frameRate: video.outputFrameRate,
            videoDelay: Int(video.videoDelay),
            videoBytesPerSecond: Int(
                (video.bitsPerSecond > 0 ? video.bitsPerSecond : demuxer.bitsPerSecond) / 8),
            audioBytesPerSecond: audio.map {
                $0.bitsPerSecond > 0 ? Int($0.bitsPerSecond / 8) : decodedAudioBytesPerSecond
            } ?? 0,
            decodedAudioBytesPerSecond: decodedAudioBytesPerSecond,
            readAheadSeconds: policy.highWatermarkSeconds,
            videoTargetSeconds: policy.videoSampleTargetSeconds,
            audioTargetSeconds: policy.audioSampleTargetSeconds,
            minimumReadAheadSeconds: policy.lowWatermarkSeconds,
            retainedAudioTracks: retainedAudioTracks,
            retainedAudioBytesPerSecond: retainedAudioBytesPerSecond
        )
    }

    init(
        demuxer: Demuxer, tracks: Tracks, sink: FrameSink,
        toneMapped: ToneMappedVideo?, budget: PipelineBudget? = nil, interrupt: InterruptFlag,
        policy: BufferPolicy = .standard,
        /// The description outgoing samples carry, when the caller has already
        /// settled on one: a Dolby Vision stream goes to the display layer as
        /// 'dvh1', which cannot be derived from the stream alone since it also
        /// depends on the screen. nil builds it from the stream, as before.
        videoFormatDescription: CMVideoFormatDescription? = nil
    ) {
        self.demuxer = demuxer
        self.tracks = tracks
        self.sink = sink
        self.toneMapped = toneMapped
        self.interrupt = interrupt
        self.policy = policy
        subtitleTimeBases = Dictionary(
            uniqueKeysWithValues: demuxer.streams
                .filter { $0.kind == .subtitle }
                .map { ($0.index, Double($0.timeBaseNum) / Double($0.timeBaseDen)) }
        )
        audioTimeBases = Dictionary(
            uniqueKeysWithValues: demuxer.streams
                .filter { $0.kind == .audio }
                .map { ($0.index, Double($0.timeBaseNum) / Double($0.timeBaseDen)) }
        )

        self.videoFormatDescription =
            videoFormatDescription ?? (try? makeFormatDescription(for: tracks.video))
        videoLengthSize = nalLengthSize(hvcC: tracks.video.extradata)
        handsOverProfileSevenAsEightOne = toneMapped == nil && tracks.video.dolbyVision?.profile == 7
            && self.videoFormatDescription.map {
                CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_DolbyVisionHEVC
            } == true
        nonReference = NonReferencePictures(stream: tracks.video)
        videoFrameDuration = tracks.video.frameRateNum > 0 && tracks.video.frameRateDen > 0
            ? CMTime(value: Int64(tracks.video.frameRateDen), timescale: tracks.video.frameRateNum)
            : nil

        let budget = budget
            ?? PlayerEngine.budget(
                for: demuxer, video: tracks.video, audio: tracks.audio,
                toneMapPixelFormat: toneMapped?.pixelFormat, policy: policy
            )
        self.budget = budget

        videoPacketQueue = PacketQueue(
            timeBase: Double(tracks.video.timeBaseNum) / Double(tracks.video.timeBaseDen),
            configuration: .init(
                highWatermarkSeconds: policy.highWatermarkSeconds,
                capacityBytes: budget.videoPacketBytes
            )
        )
        // `pictureFormat` answers a software format only on the paths that
        // decode here. A mapped path over a codec the device cannot decode
        // is handed its pictures from here too, in the ten bit 4:2:0 its
        // own session would have made.
        let softwareFormat = toneMapped == nil
            ? pictureFormat(for: tracks.video, toneMapPixelFormat: nil)
            : hardwareDecodes(tracks.video) == false ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : nil
        if let softwareFormat {
            softwareDecoder = try? SoftwareVideoDecoder(
                stream: tracks.video, pixelFormat: softwareFormat,
                // One core left to the renderer, the audio and the pull
                // threads, which a decoder on every core preempts.
                threadCount: max(ProcessInfo.processInfo.activeProcessorCount - 1, 1),
                poolCeilingBytes: budget.poolCeilingBytes
            )
        } else {
            softwareDecoder = nil
        }
        // Tone mapping and software decode both hand back pictures already
        // in presentation order (ToneMappedVideo's own reorder window;
        // avcodec_receive_frame's own contract); passthrough hands the sink
        // the compressed samples the decode thread reads, which must stay in
        // decode order for a hardware decoder fed by B-frame content.
        videoSampleQueue = SampleQueue(
            targetSeconds: policy.videoSampleTargetSeconds,
            capacityBytes: budget.videoSampleBytes,
            ordering: toneMapped == nil && softwareDecoder == nil ? .decodeOrderArrival : .presentationTime
        )

        mostPicturesSubmitted = (Int(max(tracks.video.videoDelay, 0)) + 2) * (toneMapped?.picturesPerFrame ?? 1)
            + max(toneMapped?.passesPerPicture ?? 1, 1)
        adaptiveReadAheadSeconds = policy.highWatermarkSeconds

        // What the renderer may hold ahead of its own clock: the pictures the
        // budget already reserves for it, in this film's own stream time. On
        // the passthrough path the renderer decodes what it holds, and fed
        // seconds ahead of a 4K stream it drops pictures as it shows them.
        // Stated either way: one sink plays every film, and keeps the last one's.
        if budget.pictureBytes > 0, let rate = tracks.video.outputFrameRate, rate > 0 {
            let pictures = max(budget.pictureReserveBytes / budget.pictureBytes, 1)
            sink.setVideoRunwayLimit(Double(pictures) / rate)
        } else {
            sink.setVideoRunwayLimit(PlayerEngine.passthroughRunwaySeconds)
        }

        if let audio = tracks.audio {
            audioPacketQueue = PacketQueue(
                timeBase: Double(audio.timeBaseNum) / Double(audio.timeBaseDen),
                configuration: .init(
                    highWatermarkSeconds: policy.highWatermarkSeconds,
                    capacityBytes: budget.audioPacketBytes
                )
            )
            audioSampleQueue = SampleQueue(
                targetSeconds: policy.audioSampleTargetSeconds,
                capacityBytes: budget.audioSampleBytes
            )
            audioDecodeDone = false
        } else {
            audioPacketQueue = nil
            audioSampleQueue = nil
            audioDecodeDone = true
        }
        audioStream = tracks.audio
        subtitleStream = tracks.subtitle

        var escapee: AsyncStream<EngineEvent>.Continuation!
        events = AsyncStream { escapee = $0 }
        continuation = escapee

        // A queue's lock is let go before this runs, and the count is read
        // after it: a waiter that read the queue before the change counted
        // itself first, so the broadcast is never missed.
        let filled: () -> Void = { [unowned self] in
            if self.parkWaiters.load(ordering: .acquiring) > 0 { self.wakeParked() }
        }
        videoPacketQueue.onFill = filled
        audioPacketQueue?.onFill = filled
        videoSampleQueue.onFill = filled
        audioSampleQueue?.onFill = filled
    }

    private func wakeParked() {
        parkCondition.lock()
        parkCondition.broadcast()
        parkCondition.unlock()
    }

    func start(paused: Bool) {
        lock.lock(); isPaused = paused; lock.unlock()
        // The paths that decode here hand pictures over in presentation
        // order; passthrough hands compressed samples over in decode order.
        sink.setPresentationOrderIsMonotonic(toneMapped != nil || softwareDecoder != nil)
        sink.setFramePeriod(videoFrameDuration.map(\.seconds))
        sink.requestVideo(on: videoPullQueue) { [weak self] in self?.provideVideo() }
        if tracks.audio != nil {
            sink.requestAudio(on: audioPullQueue) { [weak self] in self?.provideAudio() }
            // off the caller, which is the renderer's own event task: the
            // replay waits on the audio pull queue
            sink.setAudioRouteFlushHandler { [weak self] _ in
                DispatchQueue.global(qos: .userInitiated).async { self?.replayAudio() }
            }
        }

        let demux = Thread { [weak self] in self?.runDemux() }
        demux.name = "org.lexis.player.engine.demux"
        demux.qualityOfService = .userInitiated
        demuxThread = demux
        joinGroup.enter()
        demux.start()

        let video = Thread { [weak self] in self?.runVideo() }
        video.name = "org.lexis.player.engine.video"
        video.qualityOfService = .userInitiated
        videoThread = video
        joinGroup.enter()
        video.start()

        if tracks.audio != nil {
            let audio = Thread { [weak self] in self?.runAudio() }
            audio.name = "org.lexis.player.engine.audio"
            audio.qualityOfService = .userInitiated
            audioThread = audio
            joinGroup.enter()
            audio.start()
        }
    }

    /// The synchronizer rate, except a starved buffer overrides it: a play()
    /// arriving while `waitOutStarvation` is still waiting for a refill must
    /// not force rate 1 onto an empty queue, only record the caller's own
    /// intent for that wait's own exit to read once it resolves.
    func setPaused(_ paused: Bool) {
        lock.lock()
        isPaused = paused
        let buffering = isBuffering
        lock.unlock()
        wakeParked()
        sink.setRate(paused || buffering ? 0 : 1)
        // A landed frame held through the pause put the pump to sleep with a
        // nil; rate alone wakes a renderer, never a provider that went dry.
        if !paused { sink.resumeVideoIfIdle() }
    }

    /// The seek asked for and never applied, taken: what an engine that ended
    /// first leaves for the player to apply over it.
    func takePendingSeek() -> Double? {
        lock.lock()
        defer { lock.unlock() }
        let target = pendingSeek?.target
        pendingSeek = nil
        return target
    }

    func seek(to seconds: Double, completion: @escaping (Double) -> Void) {
        lock.lock()
        pendingSeek = (target: seconds, completion: completion)
        seekRequestedAtHostTime = hostTimeSeconds()
        lock.unlock()
        // a push parked on a full queue asks for a pending seek only when woken
        videoPacketQueue.wake()
        audioPacketQueue?.wake()
        wakeParked()
    }

    /// Applied at once, on the caller's own thread, rather than queued for
    /// the demux thread to notice: that thread only gets back to the top of
    /// its own loop between packets, and for a short file - or one already
    /// paused with everything it will ever read already read - it can be
    /// gone, with nothing left to notice a pending swap at all. Every step
    /// `applyAudioSwap` takes is already safe from any thread: state behind
    /// `lock`, a sink that guards its own, a queue that guards its own.
    func selectAudio(_ selection: MediaStream?, pipeline: AudioPipeline?) {
        if let selection, let pipeline {
            applyAudioSwap(.on(selection, pipeline))
        } else {
            applyAudioSwap(.off)
        }
    }

    /// Moves the sound against the picture. The samples the renderer holds
    /// carry the old delay, so a change on a started engine hands the track
    /// over again.
    func setAudioDelay(_ seconds: Double, started: Bool) {
        let micros = Int((seconds * 1_000_000).rounded())
        guard audioDelayMicroseconds.exchange(micros, ordering: .acquiringAndReleasing) != micros,
            started
        else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.replayAudio() }
    }

    /// The same immediacy as `selectAudio`, for the same reason.
    func selectSubtitle(_ selection: MediaStream?, decoder: SubtitleDecoder?, styled: Bool) {
        applySubtitleSwap(selection.map { .on($0, decoder, styled) } ?? .off)
    }

    /// Where a tone-mapped picture lands once VideoToolbox hands it back.
    /// `toneMapped`'s own `enqueue` closure cannot capture `videoSampleQueue`
    /// directly - it has to exist before this initializer runs, since it is
    /// one of this initializer's own parameters - so the caller wires it to
    /// this method instead, right after construction.
    ///
    /// Called on a VideoToolbox decode thread, which must not be parked here:
    /// it is a thread of the decoder's own pipeline, and a picture whose
    /// queue is full has to be taken rather than waited on. `runVideo` holds
    /// the queue to its bounds on its own thread instead, before ever
    /// submitting the frame this hands back.
    ///
    /// `giveUp` on `seekInProgress` is what keeps a picture decoded from the
    /// position the player has just left out of the window that seek's own
    /// flush cleared.
    func pushToneMappedFrame(_ sample: CMSampleBuffer) {
        releaseSubmittedPicture()
        notePictureDecoded()
        if videoSampleQueue.pushWithoutWaiting(
            sample, giveUp: { self.seekInProgress.load(ordering: .acquiring) })
        {
            sink.resumeVideoIfIdle()
        }
    }

    private func notePictureDecoded() {
        failuresSincePicture.store(0, ordering: .relaxed)
        decodedAnyPicture.store(true, ordering: .relaxed)
    }

    /// A submitted picture that will never come back: the decoder or the
    /// pass refused it. Its slot is given back first, so the decode thread
    /// parked on the bound is not left there, and then it is the same
    /// failure a picture the software path cannot make is - see
    /// `reportDecodeFailure`. Called on a VideoToolbox or Metal thread.
    func pictureLost(_ error: Error) {
        releaseSubmittedPicture()
        reportDecodeFailure(error)
    }

    /// Gives back the slot of a submitted picture that will not come back,
    /// for no fault: one the mapped path folded away.
    func releaseSubmittedPicture() {
        picturesCondition.lock()
        picturesSubmitted = max(picturesSubmitted - 1, 0)
        picturesCondition.signal()
        picturesCondition.unlock()
    }

    func stop(join: Bool) {
        interrupt.raise()
        wakeParked()
        videoPacketQueue.close()
        audioPacketQueue?.close()
        videoSampleQueue.close()
        audioSampleQueue?.close()
        sink.stopRequestingMedia()
        if join {
            // `stopRequestingMedia` cancels the request but cannot reach
            // back into a provider block already mid-flight on its own
            // queue: a sample already popped and on its way into
            // `sink.enqueue` when this runs would otherwise still land
            // after this call returns. Both queues are this engine's own
            // and see nothing else once the request is cancelled, so
            // barriering them is what actually proves empty hands, the same
            // guarantee joining the three demux/decode threads below gives
            // for everything upstream of the sink.
            videoPullQueue.sync {}
            audioPullQueue.sync {}
            joinGroup.wait()
            // Every producer is joined and the sink has stopped asking, so
            // nothing can push again: what is still queued is dead weight,
            // and it is a whole video queue's worth of decoded pictures.
            // Freed here rather than left to whenever this engine is
            // released, because the memory budget reads the process
            // footprint BEFORE deciding whether the next film fits - a
            // playback that gives its pictures back only at the next open
            // is the playback that refuses the next film.
            videoPacketQueue.flush()
            audioPacketQueue?.flush()
            // What was in flight is abandoned with the rest: a flushed
            // pass never reaches pushToneMappedFrame, so nothing else
            // would ever bring the count back down.
            picturesCondition.lock()
            picturesSubmitted = 0
            picturesCondition.signal()
            picturesCondition.unlock()
            videoSampleQueue.flush()
            audioSampleQueue?.flush()
            // A stop or an interrupt drains everything quietly, with no
            // event - matching the pull threads' own contract - so this is
            // the only place left to finish `events` for that path: every
            // thread is joined by now, so nothing could still be mid-yield.
            // A `for await` over this stream only stops on its own once it
            // finishes; cancelling the Task around it does not unblock an
            // iterator already parked on the next event.
            continuation.finish()
        }
    }

    /// Hands back every picture the decode pools are only keeping for reuse.
    /// Safe while the film is playing: nothing in flight is touched, and the
    /// pools allocate again if the pipeline gets that busy a second time.
    func releaseSpareBuffers() {
        softwareDecoder?.releaseSpareBuffers()
        toneMapped?.releaseSpareBuffers()
    }

    var statistics: EngineStatistics {
        statsLock.lock()
        var result = stats
        statsLock.unlock()
        result.packetsRead = packetsRead.load(ordering: .relaxed)
        result.videoBufferedSeconds = videoPacketQueue.bufferedSeconds + videoSampleQueue.bufferedSeconds
        result.audioBufferedSeconds =
            (audioPacketQueue?.bufferedSeconds ?? 0) + (audioSampleQueue?.bufferedSeconds ?? 0)
        lock.lock()
        let sounding = audioStream != nil
        lock.unlock()
        result.bufferedSeconds = sounding
            ? min(result.videoBufferedSeconds, result.audioBufferedSeconds)
            : result.videoBufferedSeconds
        return result
    }

    // MARK: - Demux thread

    private func runDemux() {
        // At a real end the audio queue stays open, only marked ended: its
        // thread keeps the decoder for a track switch or a route replay while
        // the tail plays out, and the stop that follows `.endOfStream` closes it.
        var keepsAudio = false
        defer {
            videoPacketQueue.close()
            if !keepsAudio { audioPacketQueue?.close() }
            joinGroup.leave()
        }
        while true {
            lock.lock()
            let seek = pendingSeek
            pendingSeek = nil
            lock.unlock()

            if let seek {
                // One line per seek, and the only figure that can tell a
                // burst of seeks apart afterwards: what the process held
                // when each landed.
                traceLine("[lexis.mem] seek to \(seek.target)s"
                    + ", footprint \(footprintBytes() / 1_048_576) MiB")
                guard applySeek(seek) else { return }
                retainedWindowClock = seek.target
                readEnd = 0
                continue
            }

            let packet: Packet?
            do {
                let interval = PipelineSignposts.demux.beginInterval(
                    "readPacket", id: demuxSignpostID
                )
                defer { PipelineSignposts.demux.endInterval("readPacket", interval) }
                packet = try demuxer.readPacket()
            } catch {
                if interrupt.isRaised { return }
                if case DemuxError.unauthorized = error {
                    continuation.yield(.unauthorized)
                } else {
                    continuation.yield(.failed(String(describing: error)))
                }
                // Terminal either way: nothing after this is still true of a
                // demuxer that just answered unauthorized or failed, and a
                // `for await` over `events` only ever stops on its own once
                // the stream finishes - cancelling the Task around it does
                // not unblock an iterator already parked on the next event.
                continuation.finish()
                return
            }
            guard let packet else {
                lock.lock(); reachedRealEndOfStream = true; streamEnd = readEnd; lock.unlock()
                wakeParked()
                videoPacketQueue.markEndReached()
                audioPacketQueue?.markEndReached()
                // Parks rather than unwinding, for as long as the sink is
                // still catching up to what was already read: packet
                // reading answers to its own watermark, not to real time,
                // so a short file can be read start to finish - and decode
                // race through all of it - in a fraction of the time it
                // takes to actually show it, and a caller mid real-time
                // playback of everything already read can still seek,
                // which reads the file again from a different position.
                // `videoDeliveryDrained` (not `videoDecodeIdle` alone) is
                // what this waits for, since decode racing ahead of the
                // sink says nothing about whether the sink has gotten
                // around to asking for any of it yet - a display layer
                // buffers ahead of what it currently shows, and only pulls
                // again as real playback catches up. `.endOfStream` itself
                // is a stricter condition still, since it also needs
                // decode's own teardown (draining a tone-mapped stream's
                // reorder window), which only runs once this thread has
                // actually let it go - waiting on that here would deadlock
                // the one case that never seeks again, since nothing would
                // ever let this thread go first. `stop()` raises
                // `interrupt` before it closes anything, which is this
                // thread's own cue to unwind early. A stop, a seek and the
                // drain each wake this.
                parkCondition.lock()
                parkWaiters.wrappingAdd(1, ordering: .acquiringAndReleasing)
                while !interrupt.isRaised, !hasPendingSeek(), !isVideoDeliveryDrained() {
                    parkCondition.wait()
                }
                parkWaiters.wrappingSubtract(1, ordering: .acquiringAndReleasing)
                parkCondition.unlock()
                guard hasPendingSeek() else {
                    keepsAudio = !interrupt.isRaised
                    return
                }
                // Reset here, pessimistically, rather than left for the
                // video decode thread to notice on its own next poll: that
                // poll is up to `eofPollInterval` away, and this same
                // resumed seek can read every packet the file has left and
                // reach a second real end well inside that span, for a
                // short enough file - reading a stale drained flag through
                // that gap would park on it again before decode has even
                // seen what this seek just gave it.
                lock.lock()
                reachedRealEndOfStream = false
                videoDecodeIdle = false
                videoDeliveryDrained = false
                lock.unlock()
                videoPacketQueue.clearEndReached()
                audioPacketQueue?.clearEndReached()
                continue
            }
            packetsRead.wrappingAdd(1, ordering: .relaxed)
            // This thread is the one the watermark parks, so it is the one
            // that moves the watermark: no other thread and no timer. A look
            // every 64 packets is a few times a second at ordinary bitrates.
            packetsSinceAdaptiveCheck += 1
            if packetsSinceAdaptiveCheck >= 64 {
                packetsSinceAdaptiveCheck = 0
                retainedWindowClock = sink.presentationTime
                let sustained = demuxer.ioStatistics?.sustainedBitsPerSecond ?? 0
                let streamRate = Double(
                    tracks.video.bitsPerSecond > 0
                        ? tracks.video.bitsPerSecond : demuxer.bitsPerSecond)
                let target = AdaptiveReadAhead.readAheadSeconds(
                    policy: policy, sustainedBitsPerSecond: sustained,
                    streamBitsPerSecond: streamRate)
                if target != adaptiveReadAheadSeconds {
                    adaptiveReadAheadSeconds = target
                    videoPacketQueue.setHighWatermarkSeconds(target)
                    audioPacketQueue?.setHighWatermarkSeconds(target)
                }
            }
            if !routePacket(packet) {
                // A push can also abort for a reason that has nothing to do
                // with either queue closing or an interrupt cutting it
                // short: a pending seek, or - for the audio queue alone - a
                // track swap's own generation moving on. Either one just
                // drops this packet (the coming flush would have discarded
                // it anyway) and sends the loop straight back to the top,
                // where a pending seek is handled first; only a queue truly,
                // permanently closed, or a real interrupt, is a reason to
                // unwind this thread for good.
                if interrupt.isRaised { return }
                if videoPacketQueue.isPermanentlyClosed { return }
                if audioPacketQueue?.isPermanentlyClosed == true { return }
                continue
            }
        }
    }

    /// False does not, on its own, mean the demux thread must unwind: a
    /// pending seek or an audio track swap can abort a push too, and the
    /// loop above reads the packet's own queue state to tell those benign
    /// drops from a queue truly closed out from under it or an interrupt
    /// cutting the push short.
    private func routePacket(_ packet: Packet) -> Bool {
        // A packet with no timestamp cannot be placed in time, so it can be
        // neither pruned from a window nor replayed into the right moment.
        let placed = packet.pts != nil || packet.dts != nil
        let index = packet.streamIndex
        if let timeBase = subtitleTimeBases[index] {
            retainedLock.lock()
            if placed {
                retainedSubtitles[index, default: RetainedWindow()].append(
                    packet, timeBase: timeBase, now: retainedWindowClock, capacityBytes: .max)
            }
            let selected = subtitleStream?.index == index
            let styled = subtitleIsStyled
            let decoder = subtitleDecoder
            retainedLock.unlock()
            // A bitmap display set can take real milliseconds to decode, and a
            // selection's replay waits on this lock. The decode runs unlocked -
            // still on the demux thread, so packet order cannot change - and
            // the re-lock only rechecks that the selection this packet was
            // decoded for is still the one on screen, the generation check
            // every other cross-thread handoff in this file uses.
            if selected, !styled, let decoder {
                let cue = try? decoder.decode(packet)
                retainedLock.lock()
                defer { retainedLock.unlock() }
                if subtitleStream?.index == index, !subtitleIsStyled, let cue {
                    sink.enqueueSubtitle(cue)
                }
                return true
            }
            if selected {
                retainedLock.lock()
                deliver(packet, timeBase: timeBase, styled: styled, through: decoder)
                retainedLock.unlock()
            }
            return true
        }
        if let timeBase = audioTimeBases[index] {
            // The selection and its generation are read and the window written
            // in one hold of `retainedLock`, which a swap selects and takes the
            // window under: a packet is in the window that swap replays, or is
            // read after it under the swap's own generation, never both.
            retainedLock.lock()
            lock.lock()
            let playing = audioStream?.index == index
            let matchedGeneration = audioFlushGeneration.load(ordering: .acquiring)
            lock.unlock()
            if playing, let pts = packet.pts ?? packet.dts {
                readEnd = max(readEnd, Double(pts + packet.duration) * timeBase)
            }
            // Held against a selection that has not happened yet, and against
            // a route that drops the sound it held: the packets of every track
            // from the clock forward. The playing track's are the ones still
            // queued or already decoded, which their own budgets bound.
            if placed {
                retainedAudio[index, default: RetainedWindow()].append(
                    packet, timeBase: timeBase, now: retainedWindowClock,
                    capacityBytes: playing
                        ? budget.audioPacketBytes + budget.audioSampleBytes
                        : budget.retainedAudioWindowBytes)
            }
            retainedLock.unlock()
            guard playing, let audioPacketQueue else { return true }
            // `selectAudio` applies a swap at once, on whatever thread calls
            // it, rather than waiting for the demux thread to notice a
            // pending one - so what this packet was matched against here
            // can already be stale by the time the push below actually
            // lands: the generation it was matched under is what the push
            // rechecks, on the same poll cadence a parked wait already
            // uses, to abandon it rather than deposit it in a queue an
            // audio swap has since flushed. A pending seek is checked
            // alongside it, not folded into the same generation: applying
            // one is what bumps `audioFlushGeneration` in the first place,
            // and that only happens once this very push lets the demux
            // thread back to the top of its own loop - checking the
            // generation alone, a push parked here on the watermark would
            // never see a seek that is still only pending, and never let
            // the thread go find out.
            return audioPacketQueue.push(packet, generation: matchedGeneration, interrupt: interrupt) {
                matchedGeneration != self.audioFlushGeneration.load(ordering: .acquiring)
                    || self.hasPendingSeek()
            }
        }
        if packet.streamIndex == tracks.video.index {
            if let pts = packet.pts ?? packet.dts {
                let base = Double(tracks.video.timeBaseNum) / Double(tracks.video.timeBaseDen)
                let duration = packet.duration > 0
                    ? Double(packet.duration) * base : videoFrameDuration?.seconds ?? 0
                readEnd = max(readEnd, Double(pts) * base + duration)
            }
            return videoPacketQueue.push(
                packet, generation: flushGeneration.load(ordering: .acquiring), interrupt: interrupt,
                giveUp: hasPendingSeek
            )
        }
        return true
    }

    /// One subtitle packet to the sink, either whole for libass or through the
    /// decoder that turns it into a cue. `retainedLock` held: this is what
    /// keeps a selection's replay of the read-ahead window ordered against the
    /// packets the demux thread is delivering live at the same moment.
    private func deliver(
        _ packet: Packet, timeBase: Double, styled: Bool, through decoder: SubtitleDecoder?
    ) {
        if styled {
            if let pts = packet.pts ?? packet.dts {
                sink.enqueueStyled(
                    event: packet.copiedBytes, start: Double(pts) * timeBase,
                    duration: Double(packet.duration) * timeBase
                )
            }
        } else if let decoder, let cue = try? decoder.decode(packet) {
            sink.enqueueSubtitle(cue)
        }
    }

    /// Checked by a parked push, on the same poll cadence `interrupt` and
    /// `isClosed` already are: a seek asked for while the packet queue is
    /// sitting at its own watermark, deep in a backlog the demux thread
    /// read before anyone asked for it to stop, must not wait out however
    /// long draining that backlog back down takes before it is even
    /// noticed. The packet a give-up abandons is one the coming flush
    /// would have discarded anyway.
    private func hasPendingSeek() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return pendingSeek != nil
    }

    private func applyAudioSwap(_ swap: AudioSelection) {
        retainedLock.lock()
        lock.lock()
        switch swap {
        case .off:
            audioStream = nil
            audioPipeline = nil
        case .on(let stream, let pipeline):
            audioStream = stream
            audioPipeline = pipeline
        }
        // The same race a seek's own flush guards against: a packet from
        // the track being left, already out of `audioPacketQueue` or
        // parked pushing into `audioSampleQueue` when this runs, must not
        // land in the sink after the flush below as though the new
        // selection (or silence) produced it.
        audioFlushGeneration.wrappingAdd(1, ordering: .acquiringAndReleasing)
        audioSwapsWaiting += 1
        lock.unlock()
        // Kept rather than taken: a route that later drops the sound it held
        // replays this same track's window.
        var window: RetainedWindow?
        if case .on(let stream, _) = swap { window = retainedAudio[stream.index] }
        retainedLock.unlock()
        // what is parked on the track being left, and a refill the audio pull
        // holds, asks again: the barrier below waits on that pull
        audioPacketQueue?.wake()
        audioSampleQueue?.wake()
        wakeParked()
        // The reason belongs to the track that failed, not to the one being
        // selected: carrying it over would report a working track as broken.
        statsLock.lock()
        stats.audioFailureReason = nil
        stats.audioRouteRefused = false
        statsLock.unlock()
        // A sample already popped off `audioSampleQueue` by the old track,
        // and on its way into `sink.enqueueAudio` when this runs, is immune
        // to the queue flush below - there is nothing left in the queue for
        // it to remove. Barriering the pull queue waits out that one
        // delivery, so it lands (and counts toward the sink's own flush
        // bookkeeping as belonging to the track being left) before
        // `flushAudio` runs, the same guarantee `stop(join:)` relies on for
        // its own pull queue barriers. A pull parked in a refill lets go once
        // it reads `audioSwapsWaiting`, so this never waits on a pause.
        audioPullQueue.sync {}
        lock.lock(); audioSwapsWaiting -= 1; lock.unlock()
        sink.flushAudio()
        audioSampleQueue?.flush()
        // The packets of the track being left are still queued and are read
        // against the new decoder otherwise, which is the one thing it must
        // not be fed.
        audioPacketQueue?.flush()
        // What the reader has already read past for the chosen track: without
        // it the sound only starts where the demux thread has read to, which
        // is the whole read-ahead away from the clock. Prepended rather than
        // pushed: every packet here is older than anything the demux thread
        // is delivering live at this moment, and it must not park on a
        // watermark holding the one thread that feeds every other track.
        if case .on(let stream, _) = swap, let audioPacketQueue {
            let base = Double(stream.timeBaseNum) / Double(stream.timeBaseDen)
            let now = sink.presentationTime
            let generation = audioFlushGeneration.load(ordering: .acquiring)
            if let window {
                let live = window.packets[window.head...].drop {
                    guard let front = $0.pts ?? $0.dts else { return true }
                    return (Double(front) + Double($0.duration)) * base <= now
                }
                audioPacketQueue.prepend(Array(live), generation: generation)
            }
        }
        // A pull that let go of a refill for this swap left its pump idle, and
        // that refill needs a pull to see it resolve.
        sink.resumeAudioIfIdle()
    }

    /// The route dropped what the renderer held: the playing track is handed
    /// over again from the clock, out of its retained window, the way a track
    /// selection starts.
    private func replayAudio() {
        guard !interrupt.isRaised else { return }
        lock.lock()
        let stream = audioStream
        let pipeline = audioPipeline
        lock.unlock()
        guard let stream, let pipeline else { return }
        // the packets it is fed next are older than the last it decoded
        if case .decoded(let decoder) = pipeline { decoder.flush() }
        applyAudioSwap(.on(stream, pipeline))
    }

    private func applySubtitleSwap(_ swap: SubtitleSelection) {
        retainedLock.lock()
        defer { retainedLock.unlock() }
        switch swap {
        case .off:
            subtitleStream = nil
            subtitleDecoder = nil
            subtitleIsStyled = false
        case .on(let stream, let decoder, let styled):
            subtitleStream = stream
            subtitleDecoder = decoder
            subtitleIsStyled = styled
        }
        // Inside the lock, so a packet the demux thread is routing live cannot
        // land between the flush and the replay and end up behind cues that
        // are older than it. No pull thread takes this lock, so a bitmap
        // track's replay decoding under it holds up the demux thread alone.
        sink.flushSubtitles()
        sink.flushStyled()
        // What the reader has already read past for this track: without it a
        // selection draws nothing until the clock catches up with the demux
        // thread, which is a whole packet queue away.
        if case .on(let stream, let decoder, let styled) = swap,
            let window = retainedSubtitles[stream.index]
        {
            let timeBase = Double(stream.timeBaseNum) / Double(stream.timeBaseDen)
            for packet in window.packets[window.head...] {
                deliver(packet, timeBase: timeBase, styled: styled, through: decoder)
            }
        }
    }

    /// False means the seek itself failed and the demux thread must unwind.
    private func applySeek(_ seek: (target: Double, completion: (Double) -> Void)) -> Bool {
        do {
            try demuxer.seek(to: seek.target)
        } catch {
            continuation.yield(.failed(String(describing: error)))
            continuation.finish()
            return false
        }
        retainedLock.lock()
        // Under the lock, unlike the other decoders below: a track selection
        // on another thread decodes through this same one, and only the lock
        // orders the two.
        subtitleDecoder?.flush()
        // The windows describe the position being left; the reader refills
        // them from the target, and a stale cue or packet replayed by a
        // selection after this would be one from somewhere else in the film.
        retainedSubtitles.removeAll()
        retainedAudio.removeAll()
        retainedLock.unlock()
        lock.lock()
        let pipeline = audioPipeline
        // Raised before the bumps: a reader without the lock that sees a new
        // generation then sees this raised too, never a new generation alone.
        seekInProgress.store(true, ordering: .releasing)
        flushGeneration.wrappingAdd(1, ordering: .acquiringAndReleasing)
        audioFlushGeneration.wrappingAdd(1, ordering: .acquiringAndReleasing)
        decoderBehind.store(false, ordering: .relaxed)
        lock.unlock()
        // a producer parked on a full sample queue asks its generation again
        videoSampleQueue.wake()
        audioSampleQueue?.wake()
        if case .decoded(let audioDecoder) = pipeline { audioDecoder.flush() }
        toneMapped?.flush()
        softwareDecoder?.flush()
        videoPacketQueue.flush()
        audioPacketQueue?.flush()
        picturesCondition.lock()
        picturesSubmitted = 0
        picturesCondition.signal()
        picturesCondition.unlock()
        videoSampleQueue.flush()
        audioSampleQueue?.flush()
        sink.flushStyled()
        sink.flush(keepingImage: true)
        // An immediate, optimistic reading for anything polling `position`
        // before the landed frame itself has decoded - corrected below to
        // the frame's own PTS the moment it crosses the sink.
        sink.anchor(atPresentation: seek.target)
        lock.lock()
        awaitingLandedFrame = true
        seekLandedCompletion = seek.completion
        seekInProgress.store(false, ordering: .releasing)
        // A starvation wait parked across this seek would otherwise wake on
        // the buffer the NEW position refills and resume the clock at the
        // position that was left - `hasPendingSeek` only catches a seek not
        // yet applied. The refill it was waiting out belongs to the old
        // position, so its state goes the way of everything else flushed
        // above; the wait's own re-check under the lock is what makes this
        // clearing land safely whichever side of it the wait is on.
        isBuffering = false
        refillHold = nil
        refillResumePTS = nil
        lock.unlock()
        wakeParked()
        return true
    }

    /// What the demux thread, parked at a real end of stream, reads to know
    /// the sink has genuinely caught up: there is nothing queued left for a
    /// seek to resume, and nothing left running that would ever queue more.
    private func isVideoDeliveryDrained() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return videoDeliveryDrained
    }

    /// Blocks for the next video packet, the same way `videoPacketQueue.pop`
    /// already does - except a nil that only means "a real end of stream was
    /// reached, not a close" parks and retries rather than ending the loop:
    /// a seek arriving after can still refill this same queue, and this
    /// thread has to still be here to decode what it refills it with.
    ///
    /// The generation returned alongside the packet is the one `routePacket`
    /// stamped it with at push, under the packet queue's own lock - not one
    /// read afterward through `PlayerEngine.lock`, a second, separate lock a
    /// seek's own generation bump can land under in the gap between this
    /// pop and that later read. Nesting the two locks the other way to
    /// close that gap would only trade it for the lock-ordering deadlock
    /// `routePacket`'s own push already has with `PlayerEngine.lock` (held
    /// while parked, checking `giveUp`); carrying the generation with the
    /// packet needs neither lock held at the same time as the other.
    private func nextVideoPacket() -> (packet: Packet, generation: Int)? {
        while true {
            if let entry = videoPacketQueue.pop(deadline: nil) {
                lock.lock(); videoDecodeIdle = false; lock.unlock()
                return entry
            }
            lock.lock(); videoDecodeIdle = true; lock.unlock()
            if videoPacketQueue.isPermanentlyClosed { return nil }
            videoPacketQueue.waitPastEnd()
        }
    }

    // MARK: - Video decode thread

    /// What a picture the pipeline could not produce costs: that picture, and
    /// the ones up to the next keyframe, where the decode thread picks the
    /// film back up. A damaged frame is not a film that cannot play; one
    /// that refuses every picture for `undecodablePictureSeconds`, or never
    /// decodes one at all, is, and ends in `abandonUndecodable`.
    ///
    /// The count comes first and is unconditional: an interrupt tearing the
    /// decoder down mid-call must not announce a failure to a caller that
    /// already asked for the stop, but a picture lost is a picture lost, and
    /// the statistics say so either way.
    private func reportDecodeFailure(_ error: Error) {
        statsLock.lock()
        stats.decodeFailures += 1
        lastDecodeFailure = String(describing: error)
        statsLock.unlock()
        guard !interrupt.isRaised else { return }
        // A picture that leans on one from before the point decoding started
        // at, the leading pictures of an open GOP: that one picture is lost,
        // the ones after it decode.
        if case DecodeError.decodeFailed(kVTVideoDecoderReferenceMissingErr) = error { return }
        if case DecodeError.decodeFailed(kVTInvalidSessionErr) = error {
            continuation.yield(.decoderTakenBack)
            continuation.finish()
            return
        }
        failuresSincePicture.wrappingAdd(1, ordering: .relaxed)
        skipToKeyframe.store(true, ordering: .releasing)
    }

    /// Terminal, exactly as the demux thread's own read failure is: a `for
    /// await` over `events` only ever stops once the stream finishes, and
    /// finishing here is also what keeps the `.endOfStream` this thread's own
    /// teardown would otherwise fire from claiming a film ended that in fact
    /// broke.
    private func abandonUndecodable() {
        guard !interrupt.isRaised else { return }
        statsLock.lock()
        let reason = lastDecodeFailure ?? "no picture decodes"
        statsLock.unlock()
        continuation.yield(.failed(reason))
        continuation.finish()
    }

    private enum PacketFate {
        case decode
        case skip
        case abandon
    }

    /// On the decode thread: past a refused picture, everything up to the
    /// next keyframe is passed over, and a film that has decoded nothing for
    /// `undecodablePictureSeconds` of its own time is given up.
    private func fate(of packet: Packet, generation: Int) -> PacketFate {
        if failuresSincePicture.load(ordering: .relaxed) > 0, let pts = packet.pts ?? packet.dts {
            if undecodedSince?.generation != generation { undecodedSince = (generation, pts) }
            let seconds = Double(pts - undecodedSince!.pts) * Double(tracks.video.timeBaseNum)
                / Double(tracks.video.timeBaseDen)
            if seconds > policy.undecodablePictureSeconds { return .abandon }
        } else {
            undecodedSince = nil
        }
        guard skipToKeyframe.load(ordering: .acquiring) else { return .decode }
        guard packet.isKeyframe else { return .skip }
        skipToKeyframe.store(false, ordering: .relaxed)
        return .decode
    }

    private func runVideo() {
        var gaveUp = false
        defer {
            // A stop drops what the mapped path holds rather than mapping
            // pictures nobody will see; the drain then only waits out the decoder.
            let stopped = interrupt.isRaised
            if stopped { toneMapped?.flush() }
            toneMapped?.drain()
            // A playback already over does not ask the decoder for what it
            // still holds.
            if let softwareDecoder, !gaveUp, !stopped {
                do {
                    for sample in try softwareDecoder.drainAtEndOfStream() {
                        if let toneMapped {
                            guard submit(
                                sample, to: toneMapped, rpu: nil, picture: CMSampleBufferGetImageBuffer(sample),
                                generation: flushGeneration.load(ordering: .acquiring))
                            else { break }
                            continue
                        }
                        if videoSampleQueue.push(sample) { sink.resumeVideoIfIdle() }
                    }
                    toneMapped?.drain()
                } catch {
                    // The tail a frame-threaded decoder was still holding:
                    // losing it silently is the same defect as losing a
                    // frame mid-stream, only harder to notice, since what
                    // follows it is the end of the film either way.
                    reportDecodeFailure(error)
                }
            }
            // the packets ran out on a film that never showed a picture
            if !gaveUp, failuresSincePicture.load(ordering: .relaxed) > 0,
                !decodedAnyPicture.load(ordering: .relaxed)
            {
                abandonUndecodable()
            }
            videoSampleQueue.close()
            lock.lock(); videoDecodeDone = true; lock.unlock()
            // `.endOfStream` waits on this flag, not only on the queue being
            // empty, and a sink already idle on the last (too-early) nil pop
            // has nothing left to push that would otherwise wake it back up
            // to notice the flag is true now.
            sink.resumeVideoIfIdle()
            joinGroup.leave()
        }
        // FFmpeg decodes this stream itself, straight from the packet - it
        // needs no CMVideoFormatDescription, which `makeFormatDescription`
        // cannot even build for a codec VideoToolbox has no atom mapping
        // for (VP9, AV1, ...), exactly the codecs this path exists for.
        if let softwareDecoder {
            while let (packet, generationAtPop) = nextVideoPacket() {
                switch fate(of: packet, generation: generationAtPop) {
                case .decode: break
                case .skip: continue
                case .abandon:
                    gaveUp = true
                    abandonUndecodable()
                    return
                }
                let samples: [CMSampleBuffer]
                do {
                    let decodeInterval = PipelineSignposts.decode.beginInterval(
                        "software decode", id: decodeSignpostID
                    )
                    defer { PipelineSignposts.decode.endInterval("software decode", decodeInterval) }
                    samples = try softwareDecoder.decode(packet)
                } catch {
                    reportDecodeFailure(error)
                    continue
                }
                if !samples.isEmpty { notePictureDecoded() }
                guard generationAtPop == flushGeneration.load(ordering: .acquiring) else { continue }
                for sample in samples {
                    if let toneMapped {
                        guard submit(
                            sample, to: toneMapped, rpu: nil, picture: CMSampleBufferGetImageBuffer(sample),
                            generation: generationAtPop)
                        else {
                            gaveUp = true
                            return
                        }
                        continue
                    }
                    let enqueueInterval = PipelineSignposts.enqueue.beginInterval(
                        "push", id: enqueueSignpostID
                    )
                    let pushed = videoSampleQueue.push(sample) {
                        generationAtPop != self.flushGeneration.load(ordering: .acquiring)
                    }
                    PipelineSignposts.enqueue.endInterval("push", enqueueInterval)
                    if pushed { sink.resumeVideoIfIdle() }
                }
            }
            return
        }
        guard let videoFormatDescription else { return }
        // The keyframe a flush landed on, and the generation it belongs to:
        // a session of our own refuses the leading pictures that follow an
        // open GOP's keyframe in decode order and precede it on screen,
        // since their references were never fed, and it refuses them as a
        // decode failure. They are pictures from before the landing, so they
        // are dropped here rather than decoded. A display layer decoding for
        // itself passes over them on its own.
        var landing: (generation: Int, pts: Int64)?
        // The first keyframe's time, which the frame grid runs through: kept
        // for the whole playback, so a seek does not move the grid.
        var gridOrigin: CMTime?
        while let (packet, generationAtPop) = nextVideoPacket() {
            // A packet with no bytes carries no picture, so there is nothing
            // here to lose by passing over it - and CoreMedia has no empty
            // block buffer to wrap it in. `SoftwareVideoDecoder.decode` turns
            // the same input away at its own door.
            if packet.byteCount == 0 { continue }
            if gridOrigin == nil, packet.isKeyframe, let pts = packet.pts {
                gridOrigin = CMTimeMultiplyByRatio(
                    CMTime(value: pts, timescale: tracks.video.timeBaseDen),
                    multiplier: tracks.video.timeBaseNum, divisor: 1
                )
            }
            switch fate(of: packet, generation: generationAtPop) {
            case .decode: break
            case .skip: continue
            case .abandon:
                gaveUp = true
                abandonUndecodable()
                return
            }
            if toneMapped != nil {
                if landing?.generation != generationAtPop, packet.isKeyframe, let pts = packet.pts {
                    landing = (generationAtPop, pts)
                }
                if let landing, landing.generation == generationAtPop, let pts = packet.pts,
                    pts < landing.pts
                {
                    continue
                }
                if !packet.isKeyframe, decoderBehind.load(ordering: .relaxed), let nonReference,
                    packet.withUnsafeBytes({ nonReference.contains($0) })
                {
                    statsLock.lock(); stats.framesSkipped += 1; statsLock.unlock()
                    continue
                }
            }
            let sample: CMSampleBuffer
            do {
                sample = try makeSampleBuffer(
                    packet: packet, formatDescription: videoFormatDescription,
                    timeBaseNum: tracks.video.timeBaseNum, timeBaseDen: tracks.video.timeBaseDen,
                    frameDuration: videoFrameDuration, gridOrigin: gridOrigin ?? .zero,
                    data: handsOverProfileSevenAsEightOne
                        ? packet.withUnsafeBytes { dolbyVisionAccessUnitAsEightOne($0, lengthSize: videoLengthSize) }
                        : nil
                )
            } catch {
                reportDecodeFailure(error)
                continue
            }
            if let toneMapped {
                var rpu: DolbyVisionRPU?
                if tracks.video.dolbyVision != nil,
                    let payload = packet.withUnsafeBytes({
                        dolbyVisionRPUPayload(in: $0, lengthSize: videoLengthSize)
                    })
                {
                    rpu = try? parseDolbyVisionRPU(payload)
                }
                // A seek's flush can land between this packet's own pop and
                // this point, on the demux thread: what makes a keyframe
                // decoded from before the flush land on the reorder window
                // as though it were newly submitted after it, with the old
                // position's own pts. Dropped rather than decoded, the same
                // discipline the audio thread already applies at its own
                // push.
                guard submit(sample, to: toneMapped, rpu: rpu, generation: generationAtPop) else {
                    gaveUp = true
                    return
                }
            } else {
                guard generationAtPop == flushGeneration.load(ordering: .acquiring) else { continue }
                let enqueueInterval = PipelineSignposts.enqueue.beginInterval(
                    "push", id: enqueueSignpostID
                )
                let pushed = videoSampleQueue.push(sample) {
                    generationAtPop != self.flushGeneration.load(ordering: .acquiring)
                }
                PipelineSignposts.enqueue.endInterval("push", enqueueInterval)
                // the sink decodes it, and says nothing here of how that went
                notePictureDecoded()
                if pushed { sink.resumeVideoIfIdle() }
            }
        }
    }

    /// How far ahead of now a cold start sets the clock running.
    static let coldStartLeadSeconds = 0.25

    /// Hands one frame to the mapped path, once there is room for its
    /// picture: compressed, for VideoToolbox, or with `picture` already
    /// decoded in software. False once the playback is over, the decoder
    /// taken back; true otherwise, the frame taken, refused or passed over
    /// for a flush.
    private func submit(
        _ sample: CMSampleBuffer, to toneMapped: ToneMappedVideo, rpu: DolbyVisionRPU?,
        picture: CVPixelBuffer? = nil, generation generationAtPop: Int
    ) -> Bool {
        guard generationAtPop == flushGeneration.load(ordering: .acquiring) else { return true }
        // Where this path waits for room, rather than at the push:
        // the picture comes back on a VideoToolbox decode thread,
        // which cannot be parked without stalling the decoder's own
        // pipeline from inside it. This thread is the pipeline's own,
        // and a pause holds it here for as long as the pause lasts.
        guard videoSampleQueue.waitForRoom(giveUp: {
            generationAtPop != self.flushGeneration.load(ordering: .acquiring)
        }) else { return true }
        // Past half full, no faster than the film's own frames: each picture
        // reaches the GPU as one leaves, where a burst of the in-flight bound
        // every few frames would clock the GPU up to map it. A tenth of a
        // frame early, so the queue still creeps back up to full. Under half,
        // as fast as it goes: a start, a seek, a pass that fell behind.
        if let frame = videoFrameDuration?.seconds, videoSampleQueue.isHalfFull {
            let due = lastPictureSubmitted + frame * 0.9
            while hostTimeSeconds() < due {
                if generationAtPop != flushGeneration.load(ordering: .acquiring) { return true }
                Thread.sleep(forTimeInterval: min(due - hostTimeSeconds(), policy.pollInterval))
            }
        }
        lastPictureSubmitted = hostTimeSeconds()
        // And room in flight, which `waitForRoom` cannot see: it
        // counts pictures that have landed, and the burst this bounds
        // is made of pictures that have not. Waiting here is safe for
        // the same reason waiting just above is - this is the decode
        // thread, a pause may hold it, and seeks are applied by the
        // demux thread, which parks nowhere near here. A flush resets
        // the count, so a parked wait exits with the generation check.
        var flushed = false
        while true {
            if generationAtPop != flushGeneration.load(ordering: .acquiring) {
                flushed = true
                break
            }
            picturesCondition.lock()
            if picturesSubmitted < mostPicturesSubmitted {
                // counted in pictures, as each one handed back gives one back
                picturesSubmitted += toneMapped.picturesPerFrame
                picturesCondition.unlock()
                break
            }
            // Woken by the next picture coming back, or by the poll
            // interval as the ceiling on how long a flush that
            // signalled just before this wait can go unnoticed.
            picturesCondition.wait(until: Date(timeIntervalSinceNow: policy.pollInterval))
            picturesCondition.unlock()
        }
        if flushed { return true }
        // Submission, not decode: VideoToolbox hands the frame back
        // on its own callback well after this returns, so the
        // interval is named for what it actually brackets.
        do {
            let submitInterval = PipelineSignposts.decode.beginInterval(
                "submit to videotoolbox", id: decodeSignpostID
            )
            defer {
                PipelineSignposts.decode.endInterval("submit to videotoolbox", submitInterval)
            }
            try toneMapped.decode(sample, rpu: rpu, picture: picture) {
                generationAtPop == self.flushGeneration.load(ordering: .acquiring)
            }
        } catch DecodeError.decodeFailed(kVTVideoDecoderReferenceMissingErr) {
            // refused at once rather than on the callback: the same
            // one lost picture, and the room it was counted in given back
            for _ in 0..<toneMapped.picturesPerFrame { releaseSubmittedPicture() }
            return true
        } catch {
            for _ in 0..<toneMapped.picturesPerFrame { releaseSubmittedPicture() }
            reportDecodeFailure(error)
            if case DecodeError.decodeFailed(kVTInvalidSessionErr) = error { return false }
            return true
        }
        return true
    }

    /// Pulled by the sink's own request loop; never blocks.
    private func provideVideo() -> CMSampleBuffer? {
        while true {
            // Refused outright for the span a seek is actively flushing:
            // a sample already out of the queue by the time the flush
            // runs is immune to it (there is nothing left in the queue for
            // it to remove), and a generation comparison alone would not
            // catch a sample still legitimately queued the instant before
            // ITS OWN queue's flush call runs, since both sides of that
            // comparison would already read the bumped generation. Either
            // way it is not safe to hand the sink a sample from this span,
            // whether it is the old position's or the new one's. Checked
            // again after the pop, not only before: `seekInProgress` and the
            // pop are two separate operations, so a seek can start in the
            // gap between them - a sample popped in that gap generation
            // alone would not catch either, since the bump it is checked
            // against has, by then, already happened for both readings.
            // Read together, one lock acquisition instead of two on a path
            // this hot: the two are unrelated flags but both gate the very
            // next step below, and every extra lock/unlock pair here is
            // paid on every frame the whole file has.
            lock.lock()
            let seeking = seekInProgress.load(ordering: .acquiring)
            // At rate 0 only what the screen is owed is delivered: the one
            // frame of a cold start, and the one frame a seek landed on -
            // a paused scrub has to show where it went, and the seek's own
            // completion and latency are measured on that frame. Ordinary
            // frames hold: a paused player keeps the picture it has. Until
            // now that held only by timing - a paused pipeline eventually
            // starves, and a starved refill's recovery is itself held by
            // the pause (see waitOutStarvation), so deliveries stopped one
            // starvation late; bounding the in-flight pictures made the
            // pipeline fast enough to surface the gap.
            let holdLanded = isPaused && !awaitingFirstFrame && !awaitingLandedFrame
            // Only a refill holding a frame up at rate 0 withholds
            // unconditionally here, never an ordinary starvation: an
            // ordinary one leaves video free to keep draining its OWN queue
            // for as long as one remains (the existing "pop comes back
            // empty" path below still catches it once that runs out) -
            // gating it here too would withhold video a starvation elsewhere
            // in the pipeline (audio alone, say) never asked video to stop
            // for, which cost this exact span a real, reproducible spurious
            // rebuffer under load before this line existed.
            let mustRefill = isBuffering && refillHold != nil
            let generationAtPop = flushGeneration.load(ordering: .acquiring)
            lock.unlock()
            if seeking || holdLanded { return nil }
            // A held frame's own refill holds here the same way a starvation
            // does, checked before ever asking the queue for more: the queue
            // can easily hold plenty already (decode keeps filling it right
            // through this span), and popping from it would hand the sink a
            // second frame before the buffer has actually cleared its
            // watermark.
            if mustRefill {
                if waitOutStarvation() { continue }
                return nil
            }
            guard let sample = videoSampleQueue.pop() else {
                if waitOutStarvation() { continue }
                pullCameUpEmpty = true
                statsLock.lock(); stats.pictureStarvations += 1; statsLock.unlock()
                // Late frames with nothing decoded behind them and the packets
                // there to decode: the decoder, not the source, is what is
                // short, and the clock holds for it rather than letting the
                // sound run on ahead of the picture.
                if lateSeconds >= PlayerEngine.latenessBeforeHold,
                    videoPacketQueue.bufferedSeconds >= policy.lowWatermarkSeconds
                {
                    lock.lock()
                    let holds = !isBuffering && pendingSeek == nil
                        && !seekInProgress.load(ordering: .acquiring)
                        && !awaitingFirstFrame && !awaitingLandedFrame && !reachedRealEndOfStream
                    if holds {
                        isBuffering = true
                        refillHold = .decodeDeficit
                    }
                    lock.unlock()
                    lateSeconds = 0
                    if holds {
                        statsLock.lock(); stats.rebufferCount += 1; statsLock.unlock()
                        traceQueues(at: "decode deficit")
                        sink.setRate(0)
                        continuation.yield(.decodeFellBehind)
                        continuation.yield(.buffering(bufferedSeconds: statistics.bufferedSeconds))
                        continue
                    }
                }
                fireEndOfStreamIfDone()
                return nil
            }
            lock.lock()
            guard !seekInProgress.load(ordering: .acquiring),
                generationAtPop == flushGeneration.load(ordering: .acquiring)
            else {
                lock.unlock()
                continue
            }
            let isColdStart = awaitingFirstFrame
            let isLanded = awaitingLandedFrame
            if isColdStart { awaitingFirstFrame = false }
            if isLanded { awaitingLandedFrame = false }
            let completion = isLanded ? seekLandedCompletion : nil
            let requestedAt = isLanded ? seekRequestedAtHostTime : nil
            if isLanded {
                seekLandedCompletion = nil
                seekRequestedAtHostTime = nil
            }
            lock.unlock()
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            // A held frame goes up at rate 0 whatever its time. Passthrough
            // samples are compressed and decoded by the renderer in decode
            // order, so a time behind the clock there says nothing of this
            // pipeline's pace.
            let lateness = !isColdStart && !isLanded
                && (toneMapped != nil || softwareDecoder != nil) ? sink.presentationTime - pts : 0
            let late = lateness > 0
            // Every late frame is counted, but only one the pull waited for
            // is the decoder's to answer for. A late frame that was already
            // queued neither adds to that nor clears it: a decoder delivering
            // in bursts leaves some of each.
            if !late {
                lateSeconds = 0
            } else if pullCameUpEmpty {
                lateSeconds += lateness
            }
            decoderBehind.store(lateSeconds > 0, ordering: .relaxed)
            pullCameUpEmpty = false
            statsLock.lock()
            stats.framesDisplayed += 1
            if late { stats.framesDropped += 1 }
            statsLock.unlock()
            if isColdStart || isLanded {
                // Both are shown at rate 0, whether or not the engine was
                // playing: rate 1 only arrives once the buffer behind the
                // frame clears the low watermark, below in
                // `waitOutStarvation`'s recovery step. Neither span counts a
                // rebuffer or fires `.buffering` - `mustRefill` above enters
                // that wait with `isBuffering` already set, which is what
                // takes it straight past the counting gate.
                sink.anchor(atPresentation: pts)
                if isLanded, let requestedAt {
                    statsLock.lock()
                    stats.lastSeekLatencySeconds = hostTimeSeconds() - requestedAt
                    statsLock.unlock()
                }
                lock.lock()
                isBuffering = true
                refillHold = isLanded ? .landedFrame : .coldStart
                refillResumePTS = pts
                lock.unlock()
                // an audio pull already waiting holds to the new refill's mark
                wakeParked()
                if isLanded { completion?(pts) }
                continuation.yield(.firstFrame(seconds: pts))
            }
            return sample
        }
    }

    private func fireEndOfStreamIfDone() {
        lock.lock()
        // Set on every empty pop once decode is idle, not only the one
        // where `.endOfStream` itself is ready to fire: the demux thread's
        // own park loop reads this to know the sink has genuinely caught
        // up, well before decode's own thread has actually torn down.
        let drains = videoDecodeIdle && reachedRealEndOfStream && !videoDeliveryDrained
        if drains { videoDeliveryDrained = true }
        let done = videoDecodeDone && reachedRealEndOfStream && !endOfStreamFired
        if done { endOfStreamFired = true }
        lock.unlock()
        // the demux thread parked at the end waits for this
        if drains { wakeParked() }
        guard done else { return }
        // Everything has reached the sink, which still holds the tail of both
        // tracks: the end is when its clock gets there. Joined like the
        // threads, so a stop cannot return while this is still waiting.
        joinGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            defer { joinGroup.leave() }
            waitOutTail()
        }
    }

    /// How long a clock that is neither paused nor moving is waited for before
    /// the end is called anyway: a stalled renderer must not hold it back.
    private static let stalledTailSeconds = 1.0

    /// Waits for the clock to reach the end of what was read, then says the
    /// stream ended. Paused, it waits for as long as the pause lasts; a stop
    /// ends it quietly, and a seek asked for in the meantime ends it at once,
    /// for the player to apply over the finished engine.
    private func waitOutTail() {
        lock.lock()
        let tail = streamEnd
        lock.unlock()
        var clock = sink.presentationTime
        var movedAt = hostTimeSeconds()
        while clock < tail - 0.01 {
            if interrupt.isRaised { return }
            if hasPendingSeek() { break }
            Thread.sleep(forTimeInterval: min(0.05, max(0.005, tail - clock)))
            lock.lock()
            let paused = isPaused
            lock.unlock()
            let next = sink.presentationTime
            let now = hostTimeSeconds()
            if next != clock || paused {
                movedAt = now
            } else if now - movedAt > PlayerEngine.stalledTailSeconds {
                break
            }
            clock = next
        }
        if interrupt.isRaised { return }
        continuation.yield(.endOfStream)
        // Terminal: a `for await` over `events` only ever stops on its own
        // once the stream finishes - cancelling the Task around it does not
        // unblock an iterator already parked on the next event, and nothing
        // else ever finishes it. A stop or an interrupt drains everything
        // quietly with no event at all and so never reaches this method, but
        // `PlayerEngine.stop`'s own caller owns that engine's whole
        // lifetime already and has no `for await` left waiting on it either.
        continuation.finish()
    }

    /// Called by a provider whose own sample queue just came up empty
    /// outside a real end of stream. Blocks the calling pull thread - never
    /// the demux or decode threads, which keep filling the queues behind it
    /// exactly as they do for an explicit pause - until the combined buffer
    /// recovers to this wait's own watermark (`RefillHold`) or a real end of
    /// stream makes waiting for one pointless. Returns true when the caller
    /// should retry its own pop (the drain resolved, or never qualified as
    /// starvation in the first place), false when an interrupt or a seek
    /// ended the wait instead and the caller should fall through to its own
    /// nil path.
    ///
    /// Never fires for the span before the first frame ever reaches the sink
    /// (`awaitingFirstFrame`), nor for the span between a seek's own flush
    /// and its landed frame actually decoding (`awaitingLandedFrame`): a file
    /// whose whole content is shorter than the low watermark would otherwise
    /// starve before playback ever begins, and neither span is a rebuffer,
    /// they are loading. The two held frames' own refills, once they are up,
    /// skip this gate a different way: `provideVideo` already sets
    /// `isBuffering` itself before this is ever called for either span, so
    /// `notBuffering` reads false and this goes straight to the recovery
    /// wait below without counting a rebuffer or firing `.buffering` - an
    /// open or a seek asked for it, nothing here starved.
    /// A parked packet queue holds the one demux thread every track is fed
    /// from, so nothing can arrive for any of them. Playback stopped is what
    /// keeps it parked - the sample queues behind it are full and their decode
    /// threads idle - which makes waiting for a fuller buffer a wait on this
    /// thread's own resumption. Starting again is what drains it.
    ///
    /// Deliberately blind to which track parked it, and to how much picture
    /// is left: holding out for a fuller video buffer while the AUDIO queue
    /// is the parked one waits on a drain that only resumed playback can
    /// deliver, which is a freeze with no way out rather than a brief empty
    /// one. It costs a picture only where the file hands out more than the
    /// full 8 s watermark of sound before its next video packet.
    ///
    /// Gates entering the wait as well as leaving it, and the two readings
    /// must stay in step. This is the one way out that does not go through
    /// the high watermark, so it can be true at a buffer of zero - which is
    /// also exactly what the low watermark admits on the way in. Reading it
    /// only on the way out left nothing at all between leaving the state and
    /// re-entering it: the pull thread's own retry loop ran that round trip
    /// at CPU speed, counting a rebuffer and driving the rate 1-0-1 on every
    /// turn, and a renderer flipped that fast never gets a run at rate 1
    /// long enough to drain the queue whose parked push is the whole reason
    /// refilling is hopeless. The picture stops for good.
    private var refillIsHopeless: Bool {
        videoPacketQueue.isHoldingTheDemuxThread
            || audioPacketQueue?.isHoldingTheDemuxThread == true
    }

    /// What every queue holds at a rebuffer: which of them ran dry, and
    /// whether the packet queues were at their byte ceiling rather than their
    /// seconds.
    private func traceQueues(at reason: String) {
        let mib = 1_048_576.0
        traceLine(String(
            format: "[lexis.buf] %@: video packets %.2f s %.1f/%.1f MiB%@, pictures %.2f s,"
                + " audio packets %.2f s %.1f/%.1f MiB%@",
            reason, videoPacketQueue.bufferedSeconds, Double(videoPacketQueue.bufferedBytes) / mib,
            Double(budget.videoPacketBytes) / mib, videoPacketQueue.isHoldingTheDemuxThread ? " parked" : "",
            videoSampleQueue.bufferedSeconds, audioPacketQueue?.bufferedSeconds ?? 0,
            Double(audioPacketQueue?.bufferedBytes ?? 0) / mib, Double(budget.audioPacketBytes) / mib,
            audioPacketQueue?.isHoldingTheDemuxThread == true ? " parked" : ""))
    }

    /// `yieldsToAudioSwap` is the audio pull's own: it lets go for a swap
    /// waiting on its queue, and leaves the refill standing for whoever else
    /// is waiting it out.
    private func waitOutStarvation(yieldsToAudioSwap: Bool = false) -> Bool {
        // Only the thread that actually wins the buffering flag opens an
        // interval, so the trace carries one interval per rebuffer and not
        // one per pull thread that noticed the same stall.
        var rebufferInterval: OSSignpostIntervalState?
        defer {
            if let rebufferInterval {
                PipelineSignposts.rebuffer.endInterval("rebuffer", rebufferInterval)
            }
        }
        lock.lock()
        let notBuffering = !isBuffering
        let eligible = !awaitingFirstFrame && !awaitingLandedFrame && !reachedRealEndOfStream
        lock.unlock()

        if notBuffering {
            // `bufferedSeconds` reads the packet and sample queues' own
            // locks; it must never be read while `lock` is held. A packet
            // queue's own parked pusher calls back into `lock` (checking
            // for a pending seek) while holding ITS lock, the opposite
            // order, and nesting the two the other way deadlocks against
            // it - confirmed by a hung stall test before this was split
            // into two separate acquisitions.
            // Read here as well as in the recovery step below, so the same
            // condition that ends a wait also refuses to start one: stopping
            // the clock for a refill that cannot arrive until the clock runs
            // is what makes the starvation permanent.
            guard eligible, !refillIsHopeless,
                statistics.bufferedSeconds < policy.lowWatermarkSeconds
            else {
                return false
            }
            lock.lock()
            // Re-checked here: another pull thread's own call could have
            // already won this race and entered buffering (or the state
            // could have moved on) in the span this thread held no lock.
            let won = !isBuffering && !awaitingFirstFrame && !reachedRealEndOfStream
                && !(yieldsToAudioSwap && audioSwapsWaiting > 0)
            if won { isBuffering = true }
            let stillWaiting = isBuffering
            lock.unlock()
            guard stillWaiting else { return false }
            if won {
                statsLock.lock(); stats.rebufferCount += 1; statsLock.unlock()
                traceQueues(at: "starved")
                rebufferInterval = PipelineSignposts.rebuffer.beginInterval(
                    "rebuffer", id: rebufferSignpostID
                )
                sink.setRate(0)
                continuation.yield(.buffering(bufferedSeconds: statistics.bufferedSeconds))
            }
        }

        // Untimed: a stop, a seek, a pause or play, an audio swap, the end of
        // the stream and every queue filling wake this. Let go before the
        // sink is moved or the caller goes on.
        parkCondition.lock()
        parkWaiters.wrappingAdd(1, ordering: .acquiringAndReleasing)
        var parked = true
        func unpark() {
            guard parked else { return }
            parked = false
            parkWaiters.wrappingSubtract(1, ordering: .acquiringAndReleasing)
            parkCondition.unlock()
        }
        defer { unpark() }
        while true {
            if interrupt.isRaised || hasPendingSeek() {
                lock.lock()
                isBuffering = false
                refillHold = nil
                refillResumePTS = nil
                lock.unlock()
                // the other pull may be waiting out the same refill
                parkCondition.broadcast()
                return false
            }
            lock.lock()
            let stillBuffering = isBuffering
            let realEndOfStream = reachedRealEndOfStream
            let hold = refillHold
            // A held frame's own refill has nowhere to resume TO while the
            // caller is still paused: nothing asked for rate 1, so nothing
            // here should hand out a second frame either, however fast the
            // buffer itself fills - this is what keeps that one frame alone
            // on screen for as long as the engine stays paused, not just for
            // however long a local file happens to take filling its packet
            // queue back up.
            let heldByPause = hold != nil && isPaused
            let swapWaiting = yieldsToAudioSwap && audioSwapsWaiting > 0
            lock.unlock()
            guard stillBuffering else { return true }
            if swapWaiting { return false }
            var recovered = !heldByPause && realEndOfStream
            // Half a second of pictures decoded, or all the queue can hold:
            // its producer parked on it full, or the demux thread every packet
            // comes from held by the audio queue. In seconds, not in its
            // bytes: half the bytes of a queue of 4K pictures is a sixth of a
            // second, and a clock started on that drops frames.
            var picturesAhead: Bool {
                videoSampleQueue.bufferedSeconds * 2 >= policy.videoSampleTargetSeconds
                    || videoSampleQueue.isHoldingItsProducer
                    || audioPacketQueue?.isHoldingTheDemuxThread == true
            }
            if !heldByPause, !realEndOfStream {
                // Read outside `lock`, for the same reason as the entry check.
                switch hold {
                case nil:
                    // Halfway to the high watermark, not to it and not to the
                    // adaptive read-ahead: the packet queues' byte ceilings are
                    // sized for the high watermark at the film's average rate,
                    // so a figure past that is reached only by giving up on
                    // it, with the picture frozen for the whole wait.
                    recovered = refillIsHopeless
                        || statistics.bufferedSeconds
                            >= (policy.lowWatermarkSeconds + policy.highWatermarkSeconds) / 2
                case .coldStart:
                    // A cold start owes the viewer a picture now, not a
                    // deeper buffer; but pictures, not packets: a software
                    // decoder still spinning its threads up holds a second
                    // of packets and a third of a second of pictures, and a
                    // clock started on those drops frames in its first second.
                    recovered = refillIsHopeless
                        || (statistics.bufferedSeconds >= policy.lowWatermarkSeconds && picturesAhead)
                case .landedFrame:
                    // A landed seek owes them motion: the frame they aimed at
                    // is up, and the buffer behind it need only cover the
                    // next second, in pictures as much as in packets.
                    recovered = refillIsHopeless
                        || (statistics.bufferedSeconds >= policy.seekResumeSeconds && picturesAhead)
                case .decodeDeficit:
                    // Depth in the picture queue is what was missing, read
                    // against whichever of its bounds the budget made tighter.
                    // It stops growing once its producer parks on it full,
                    // and cannot grow at all while the audio queue holds the
                    // demux thread every packet comes from.
                    recovered = videoSampleQueue.isHalfFull
                        || videoSampleQueue.isHoldingItsProducer
                        || audioPacketQueue?.isHoldingTheDemuxThread == true
                }
            }
            if recovered {
                // A decoder that fell behind left the frames it has since made
                // behind the clock too, where every one of them would be late
                // again: the clock goes back to the first of them. Read while
                // the video pull is still held here, so none can leave first.
                let decodedBehind = hold == .decodeDeficit
                    ? videoSampleQueue.headPresentationSeconds.flatMap {
                        $0 < sink.presentationTime ? $0 : nil
                    }
                    : nil
                lock.lock()
                let stillOwnsIt = isBuffering
                if stillOwnsIt { isBuffering = false }
                let clearedHold = refillHold
                refillHold = nil
                let resumePTS = refillResumePTS
                refillResumePTS = nil
                let paused = isPaused
                lock.unlock()
                parkCondition.broadcast()
                unpark()
                guard stillOwnsIt else { return true }
                if let resumePTS, clearedHold != nil, !paused {
                    // A starvation resumes the clock where it already stood;
                    // a held frame's refill has a clock that never ran to
                    // that frame at all, and only this anchors it there
                    // before letting the rate run again. A cold start is
                    // given longer to hand the renderer its first frames: it
                    // follows a display's switch of mode and pictures the
                    // screen has never been handed, and fifty milliseconds
                    // dropped two of them on the Apple TV, where a quarter of
                    // a second on an open is not seen.
                    if clearedHold == .coldStart {
                        sink.start(atPresentation: resumePTS, lead: PlayerEngine.coldStartLeadSeconds)
                    } else {
                        sink.start(atPresentation: resumePTS)
                    }
                } else if let decodedBehind, clearedHold == .decodeDeficit, !paused {
                    sink.start(atPresentation: decodedBehind)
                } else {
                    sink.setRate(paused ? 0 : 1)
                }
                // A cold start announced nothing to be resumed FROM: the
                // caller's own `play()` already reported `.playing`, and a
                // second one for the end of a wait nobody was told about
                // would read as a stall that never happened. `.resumed` is
                // the counterpart of `.buffering` (a starvation) or of a
                // seek's own landed frame, and of nothing else.
                if clearedHold != .coldStart { continuation.yield(.resumed) }
                return true
            }
            parkCondition.wait()
        }
    }

    /// The audio pipeline's own reading of `nextVideoPacket`'s discipline.
    private func nextAudioPacket(_ audioPacketQueue: PacketQueue) -> (packet: Packet, generation: Int)? {
        var drained = false
        while true {
            if let entry = audioPacketQueue.pop(deadline: nil) { return entry }
            if !drained, !interrupt.isRaised {
                drained = true
                drainAudioDecoder()
            }
            if audioPacketQueue.isPermanentlyClosed { return nil }
            audioPacketQueue.waitPastEnd()
        }
    }

    /// Out of packets: what the decoder and its last partial buffer still
    /// hold is the end of the sound, and goes to the sink like the rest.
    private func drainAudioDecoder() {
        guard let audioSampleQueue else { return }
        lock.lock()
        let pipeline = audioPipeline
        lock.unlock()
        guard case .decoded(let decoder) = pipeline else { return }
        let generation = audioFlushGeneration.load(ordering: .acquiring)
        guard let samples = try? decoder.drain() else { return }
        for sample in samples {
            guard audioSampleQueue.push(sample, giveUp: {
                generation != self.audioFlushGeneration.load(ordering: .acquiring)
            }) else { return }
            sink.resumeAudioIfIdle()
        }
    }

    // MARK: - Audio decode thread

    private func runAudio() {
        guard let audioPacketQueue, let audioSampleQueue else { return }
        defer {
            audioSampleQueue.close()
            lock.lock(); audioDecodeDone = true; lock.unlock()
            joinGroup.leave()
        }
        while let (packet, generationAtPop) = nextAudioPacket(audioPacketQueue) {
            // `generationAtPop` is the generation `routePacket` stamped this
            // packet with at push, under the packet queue's own lock - not
            // one read afterward through `PlayerEngine.lock` on this thread,
            // which a seek's generation bump could land ahead of in the gap
            // between this packet leaving its queue and that later read,
            // stamping a stale packet with the generation the flush it
            // should have been caught by just moved to - confirmed by a
            // stale pre-seek sample landing past a seek's own flush before
            // the packet queue carried its own generation this way.
            lock.lock()
            let pipeline = audioPipeline
            let stream = audioStream
            lock.unlock()
            guard let pipeline, let stream else { continue }
            // A seek's flush, or an audio track swap's own narrower one,
            // can land between this pop and the matching push below, on
            // its own thread; a generation that has moved on since means
            // this packet's decoded result belongs to the position or the
            // track the swap just left, and it is dropped rather than hand
            // the sink a sample from before it.
            func stillCurrent() -> Bool {
                audioFlushGeneration.load(ordering: .acquiring) == generationAtPop
            }
            switch pipeline {
            case .decoded(let decoder):
                do {
                    let samples = try decoder.decode(packet)
                    guard stillCurrent() else { continue }
                    for sample in samples {
                        if audioSampleQueue.push(sample, giveUp: { !stillCurrent() }) {
                            sink.resumeAudioIfIdle()
                        }
                    }
                } catch {
                    // No audio frame is decoded against another, so a packet
                    // the decoder refuses costs its own sound and nothing
                    // after it: the next packet it accepts plays. Nothing is
                    // abandoned here - the reason is recorded once and the
                    // pipeline keeps feeding the decoder whatever the file
                    // has left, which is the only way the sound comes back.
                    statsLock.lock()
                    if stats.audioFailureReason == nil {
                        stats.audioFailureReason = error.localizedDescription
                    }
                    statsLock.unlock()
                }
            case .passthrough(_, let description):
                if let sample = try? makeCompressedAudioSampleBuffer(
                    packet: packet, formatDescription: description,
                    timeBaseNum: stream.timeBaseNum, timeBaseDen: stream.timeBaseDen
                ), stillCurrent() {
                    if audioSampleQueue.push(sample, giveUp: { !stillCurrent() }) {
                        sink.resumeAudioIfIdle()
                    }
                }
            }
            // Checked after every packet: a refusal reaches the renderer
            // asynchronously and has nothing to do with whether this packet's
            // own enqueue threw. A renderer that refused is failed until it
            // is flushed, and every compressed sample still queued behind the
            // refusal would only fail it again: the queue and the renderer
            // are emptied together and the decoder takes it from here.
            if case .passthrough = pipeline, let reason = sink.audioPassthroughError,
                let rebuilt = try? AudioDecoder(stream: stream)
            {
                statsLock.lock()
                stats.audioRouteRefused = true
                if stats.audioFailureReason == nil { stats.audioFailureReason = reason }
                statsLock.unlock()
                lock.lock(); audioPipeline = .decoded(rebuilt); lock.unlock()
                audioSampleQueue.flush()
                sink.flushAudio()
                sink.resumeAudioIfIdle()
                if case .passthrough(let format, _) = pipeline { onPassthroughRefused?(format, stream, rebuilt) }
            }
        }
    }

    /// Pulled by the sink's own request loop; never blocks.
    private func provideAudio() -> CMSampleBuffer? {
        guard let audioSampleQueue else { return nil }
        while true {
            // The same guard `provideVideo` applies for a seek, plus its
            // own generation for a track swap alone: `seekInProgress` only
            // covers the span a seek is flushing in, since an audio-only
            // swap must not stall video's own pulls, but the generation
            // check on its own line still catches a sample already queued
            // when either kind of flush runs.
            // Generation first: `applySeek` raises the flag before it bumps,
            // so a new generation read here is never paired with a lowered
            // flag from before the flush.
            let generationAtPop = audioFlushGeneration.load(ordering: .acquiring)
            if seekInProgress.load(ordering: .acquiring) { return nil }
            guard let sample = audioSampleQueue.pop() else {
                if waitOutStarvation(yieldsToAudioSwap: true) { continue }
                return nil
            }
            lock.lock()
            let current = !seekInProgress.load(ordering: .acquiring)
                && generationAtPop == audioFlushGeneration.load(ordering: .acquiring)
            let decoded: Bool
            if case .decoded = audioPipeline { decoded = true } else { decoded = false }
            lock.unlock()
            guard current else { continue }
            // A compressed sample popped in the instant between a route
            // refusal's queue flush and its renderer flush would put the
            // renderer straight back into the failure it just recovered
            // from, with nothing left to recover it a second time.
            if decoded, let format = CMSampleBufferGetFormatDescription(sample),
                CMFormatDescriptionGetMediaSubType(format) != kAudioFormatLinearPCM
            {
                continue
            }
            let delay = audioDelayMicroseconds.load(ordering: .relaxed)
            guard delay != 0 else { return sample }
            // A new header over the same data: the samples are not copied.
            // Every audio sample here is built with a single timing entry.
            var timing = CMSampleTimingInfo()
            guard CMSampleBufferGetSampleTimingInfo(sample, at: 0, timingInfoOut: &timing) == noErr else { return sample }
            let shift = CMTime(value: CMTimeValue(delay), timescale: 1_000_000)
            timing.presentationTimeStamp = CMTimeAdd(timing.presentationTimeStamp, shift)
            if timing.decodeTimeStamp.isValid { timing.decodeTimeStamp = CMTimeAdd(timing.decodeTimeStamp, shift) }
            var shifted: CMSampleBuffer?
            guard CMSampleBufferCreateCopyWithNewTiming(
                allocator: kCFAllocatorDefault, sampleBuffer: sample, sampleTimingEntryCount: 1,
                sampleTimingArray: &timing, sampleBufferOut: &shifted
            ) == noErr, let shifted else { return sample }
            return shifted
        }
    }
}

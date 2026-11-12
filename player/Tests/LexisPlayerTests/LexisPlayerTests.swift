import AVFoundation
import CLexisStream
import CoreMedia
import LexisCoreStream
import LexisTestSupport
import VideoToolbox
import XCTest
@testable import LexisPlayer

final class CountingSink: FrameSink {
    private let lock = NSLock()
    private var recordedSamples: [CMTime] = []
    private var recordedPictures = 0
    private var recordedPictureSize: (width: Int, height: Int)?
    private var recordedRates: [Float] = []
    private var recordedStart: Double?
    private var recordedFlushes: [Bool] = []
    private var recordedEDR: [Bool] = []
    private var injectedAudioError: String?
    /// True unless a test says otherwise: a sink that records what it was
    /// handed is a sink that showed it.
    private var displaysPictures = true
    private var injectedVideoDecodeFailure: String?
    /// A clock anchored but never actually moving: what every sink is through
    /// the refill that holds the first frame up, and what a starved one goes
    /// back to mid-film. Rate changes are recorded as a real sink records
    /// them; only time stands still.
    private var clockIsHeld = false
    private var recordedAudio: [CMTime] = []
    private var recordedAudioFormats: [FourCharCode] = []
    private var audioAtLastFlush = 0
    private var pendingCues: [SubtitleCue] = []
    private var deliveredCues: [SubtitleCue] = []
    private var shownCue: SubtitleCue?
    private var subtitleFlushes = 0
    private var audioFlushes = 0
    private var recordedTime = 0.0
    private var runningSince: Date?
    private var styledOffers = 0
    private var styledFlushes = 0
    private var styledStops = 0
    /// Blocks the pull loop inside enqueue()/enqueueAudio() for this long
    /// before recording - a consumer real enough to cost real wall time
    /// without ever refusing a sample, which is what stands in for a real
    /// renderer's own buffer target: nothing else paces delivery to content
    /// time any more, so a short fixture would otherwise finish playing
    /// before a test even gets to the assertion that means to catch it
    /// mid-flight.
    private var enqueueDelay: TimeInterval = 0
    /// A real renderer whose clock is stopped fills its own buffer and then
    /// stops asking for media, so a pause stops the drain and everything
    /// behind it fills. Off by default: most tests want every sample the
    /// pipeline makes, whatever the rate. Only `setRate` and `start` speak
    /// for it - a cold start's own anchor stops the clock with one frame held
    /// up and the renderer still asking, which is not a pause.
    private var stopsPullingWhilePaused = false
    /// A renderer whose own audio buffer is full stops asking for sound and
    /// says nothing about when it will ask again. Video keeps being pulled,
    /// which is the asymmetry `refillIsHopeless` exists for: the audio
    /// queues behind a silent renderer fill, and the one demux thread parks
    /// on them.
    private var stopsPullingAudio = false
    private var stopsPullingVideo = false
    private var clockStopped = false
    private var framesEnqueuedBeforeStart = 0
    private var clockEverStarted = false
    private var videoTimer: DispatchSourceTimer?
    private var audioTimer: DispatchSourceTimer?

    var isReadyForMoreFrames: Bool { true }

    var isReadyForMoreAudio: Bool { true }

    /// As the real synchronizer does: the clock runs in real time from the last
    /// anchor while the rate is 1, and holds where it stands at 0.
    var presentationTime: Double {
        lock.lock(); defer { lock.unlock() }
        return recordedTime + (runningSince.map { Date().timeIntervalSince($0) } ?? 0)
    }

    var samples: [CMTime] {
        lock.lock(); defer { lock.unlock() }
        return recordedSamples
    }

    /// How many of them arrived as pictures rather than as packets: what the
    /// tone mapped path enqueues and the display path never does.
    var pictures: Int {
        lock.lock(); defer { lock.unlock() }
        return recordedPictures
    }

    var audio: [CMTime] {
        lock.lock(); defer { lock.unlock() }
        return recordedAudio
    }

    /// The format of each audio sample, in arrival order.
    var audioFormats: [FourCharCode] {
        lock.lock(); defer { lock.unlock() }
        return recordedAudioFormats
    }

    var rates: [Float] {
        lock.lock(); defer { lock.unlock() }
        return recordedRates
    }

    var startedAt: Double? {
        lock.lock(); defer { lock.unlock() }
        return recordedStart
    }

    /// How many frames the sink was handed before its clock ever ran. A
    /// pipeline that holds the first frame up while it fills hands over
    /// exactly one; one that starts the clock on that same frame hands over
    /// none before it.
    var framesBeforeClockStart: Int {
        lock.lock(); defer { lock.unlock() }
        return framesEnqueuedBeforeStart
    }

    /// Runs on every `start(atPresentation:)`, outside the lock: what lets a
    /// test read the engine's own buffer at the instant playback begins.
    var onClockStart: (() -> Void)?

    var flushes: Int {
        lock.lock(); defer { lock.unlock() }
        return recordedFlushes.count
    }

    /// True where the flush kept the picture up, in the order they arrived.
    var keptImages: [Bool] {
        lock.lock(); defer { lock.unlock() }
        return recordedFlushes
    }

    /// The audio a real renderer would still be holding: what arrived after the
    /// last flush emptied it.
    var audioSinceLastFlush: [CMTime] {
        lock.lock(); defer { lock.unlock() }
        return Array(recordedAudio.dropFirst(audioAtLastFlush))
    }

    /// The cue a real sink's own clock-driven `updateSubtitle` would be
    /// showing right now - at most one, revealed once its own start has
    /// passed and cleared once its own end has, the same discipline
    /// `DisplayLayerSink` already has: nothing paces cue delivery to
    /// content time any more, so the reader can hand every cue in the file
    /// to `enqueueSubtitle` well before the clock reaches the first one.
    var cues: [SubtitleCue] {
        lock.lock(); defer { lock.unlock() }
        let now = recordedTime + (runningSince.map { Date().timeIntervalSince($0) } ?? 0)
        while let first = pendingCues.first, first.start <= now {
            pendingCues.removeFirst()
            if first.isEmpty, first.canvasWidth == 0 { continue }
            shownCue = first
        }
        if let cue = shownCue, cue.end <= now || cue.isEmpty { shownCue = nil }
        return shownCue.map { [$0] } ?? []
    }

    /// Every cue the player published, in the order it published them, with no
    /// clock in the way: what the text path produced, rather than what a sink
    /// would be showing at one instant.
    var delivered: [SubtitleCue] {
        lock.lock(); defer { lock.unlock() }
        return deliveredCues
    }

    var subtitleFlushCount: Int {
        lock.lock(); defer { lock.unlock() }
        return subtitleFlushes
    }

    var audioFlushCount: Int {
        lock.lock(); defer { lock.unlock() }
        return audioFlushes
    }

    var wantsEDRCalls: [Bool] {
        lock.lock(); defer { lock.unlock() }
        return recordedEDR
    }

    /// The test's hand on what a real `AVSampleBufferAudioRenderer` would
    /// report on `.error` after a route refuses a passthrough buffer.
    private var audioRouteFlushHandler: ((Double) -> Void)?

    func setAudioRouteFlushHandler(_ handler: ((Double) -> Void)?) {
        lock.lock(); audioRouteFlushHandler = handler; lock.unlock()
    }

    /// What a route change does to a real renderer: the sound it held is gone,
    /// and the pipeline is told from when.
    func dropAudioAsARouteWould() {
        lock.lock()
        audioAtLastFlush = recordedAudio.count
        let handler = audioRouteFlushHandler
        let time = recordedTime + (runningSince.map { Date().timeIntervalSince($0) } ?? 0)
        lock.unlock()
        handler?(time)
    }

    func injectAudioPassthroughError(_ message: String?) {
        lock.lock(); injectedAudioError = message; lock.unlock()
    }

    /// Stands in for a display layer that accepts every sample and shows none
    /// of them - a format description with no decoder behind it, which
    /// reports `.rendering` with no error the whole time it renders nothing.
    /// `refusing` is what the renderer said, for the layers that say
    /// anything at all.
    func showNoPicture(refusing reason: String? = nil) {
        lock.lock()
        displaysPictures = false
        injectedVideoDecodeFailure = reason
        lock.unlock()
    }

    /// The picture a real layer puts up, and gives back on a flush that
    /// removes the image.
    func setDisplaysPictures(_ value: Bool) {
        lock.lock(); displaysPictures = value; lock.unlock()
    }

    func holdClock() {
        lock.lock(); clockIsHeld = true; lock.unlock()
    }

    func setEnqueueDelay(_ seconds: TimeInterval) {
        lock.lock(); enqueueDelay = seconds; lock.unlock()
    }

    func setStopsPullingWhilePaused(_ value: Bool) {
        lock.lock(); stopsPullingWhilePaused = value; lock.unlock()
    }

    func setStopsPullingAudio(_ value: Bool) {
        lock.lock(); stopsPullingAudio = value; lock.unlock()
    }

    /// A renderer holding all the picture it wants stops asking for more, and
    /// says nothing about when it will ask again. Unlike the two above it is
    /// not tied to the clock: it is what a test sets to stop draining the
    /// pipeline at a chosen point, so what the engine does next is not being
    /// raced by a double that empties an eight second buffer in a millisecond.
    func setStopsPullingVideo(_ value: Bool) {
        lock.lock(); stopsPullingVideo = value; lock.unlock()
    }

    private var isAudioPullHeld: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopsPullingAudio || (stopsPullingWhilePaused && clockStopped)
    }

    private var isPullHeld: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopsPullingVideo || (stopsPullingWhilePaused && clockStopped)
    }

    var audioPassthroughError: String? {
        lock.lock(); defer { lock.unlock() }
        return injectedAudioError
    }

    var hasDisplayedPicture: Bool {
        lock.lock(); defer { lock.unlock() }
        return displaysPictures
    }

    var videoDecodeFailure: String? {
        lock.lock(); defer { lock.unlock() }
        return injectedVideoDecodeFailure
    }

    func start(atPresentation seconds: Double) {
        lock.lock()
        recordedStart = seconds
        recordedTime = seconds
        runningSince = clockIsHeld ? nil : Date()
        clockEverStarted = true
        clockStopped = false
        lock.unlock()
        onClockStart?()
    }

    func anchor(atPresentation seconds: Double) {
        lock.lock()
        recordedTime = seconds
        runningSince = nil
        lock.unlock()
    }

    func setRate(_ rate: Float) {
        lock.lock()
        recordedRates.append(rate)
        if let since = runningSince { recordedTime += Date().timeIntervalSince(since) }
        runningSince = rate == 0 || clockIsHeld ? nil : Date()
        clockStopped = rate == 0
        lock.unlock()
    }

    // The lock stays held across the delay in both of these, the same as a
    // real thread-safe renderer's own internal lock would: a flush landing
    // mid-delay waits for the enqueue it raced to finish, rather than
    // taking its own snapshot while a sample from the old position is
    // still in flight and about to land as though it belonged to the new
    // one.
    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }
        if enqueueDelay > 0 { usleep(useconds_t(enqueueDelay * 1_000_000)) }
        recordedSamples.append(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        if !clockEverStarted { framesEnqueuedBeforeStart += 1 }
        if let image = CMSampleBufferGetImageBuffer(sampleBuffer) {
            recordedPictures += 1
            recordedPictureSize = (CVPixelBufferGetWidth(image), CVPixelBufferGetHeight(image))
        }
    }

    /// The dimensions of the last picture enqueued, nil while only compressed
    /// samples have crossed: what the upscaled path is held to.
    var lastPictureSize: (width: Int, height: Int)? {
        lock.lock()
        defer { lock.unlock() }
        return recordedPictureSize
    }

    func enqueueAudio(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }
        if enqueueDelay > 0 { usleep(useconds_t(enqueueDelay * 1_000_000)) }
        recordedAudio.append(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        recordedAudioFormats.append(
            CMSampleBufferGetFormatDescription(sampleBuffer).map(CMFormatDescriptionGetMediaSubType) ?? 0)
    }

    /// isReadyForMoreFrames is always true here, so the contract this double
    /// owes a pulling engine is just "keep asking": a 120 Hz timer stands in
    /// for requestMediaDataWhenReady's readiness edges.
    func requestVideo(on queue: DispatchQueue, provider: @escaping () -> CMSampleBuffer?) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0 / 120.0)
        // Reread between samples, not only on entry: a provider that parks
        // this handler through a whole rebuffer would otherwise come back and
        // drain the refilled buffer whole, past a hold set while it waited.
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            while !self.isPullHeld, let sample = provider() { self.enqueue(sample) }
        }
        lock.lock(); videoTimer = timer; lock.unlock()
        timer.resume()
    }

    func requestAudio(on queue: DispatchQueue, provider: @escaping () -> CMSampleBuffer?) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0 / 120.0)
        timer.setEventHandler { [weak self] in
            guard let self, !self.isAudioPullHeld else { return }
            while let sample = provider() { self.enqueueAudio(sample) }
        }
        lock.lock(); audioTimer = timer; lock.unlock()
        timer.resume()
    }

    func stopRequestingMedia() {
        lock.lock()
        let video = videoTimer
        let audio = audioTimer
        videoTimer = nil
        audioTimer = nil
        lock.unlock()
        video?.cancel()
        audio?.cancel()
    }

    /// The timer above polls the provider on its own cadence regardless of
    /// readiness edges, so this double never goes idle: nothing for a resume
    /// to do.
    func resumeVideoIfIdle() {}

    func resumeAudioIfIdle() {}

    func setWantsExtendedDynamicRange(_ value: Bool) {
        lock.lock()
        recordedEDR.append(value)
        lock.unlock()
    }

    func flush(keepingImage: Bool) {
        lock.lock()
        recordedFlushes.append(keepingImage)
        audioAtLastFlush = recordedAudio.count
        // a real flush stops the clock where it stands
        if let since = runningSince { recordedTime += Date().timeIntervalSince(since) }
        runningSince = nil
        lock.unlock()
        flushSubtitles()
        // both halves of the real sink's flush, or a seek would look like it
        // left the styled path alone
        flushStyled()
    }

    func enqueueSubtitle(_ cue: SubtitleCue) {
        lock.lock()
        pendingCues.append(cue)
        deliveredCues.append(cue)
        lock.unlock()
    }

    /// Runs on every subtitle flush, outside the lock: it is how a test sees
    /// what the player had published by the time the flush landed.
    var onSubtitleFlush: (() -> Void)?

    func flushSubtitles() {
        lock.lock()
        pendingCues.removeAll()
        shownCue = nil
        subtitleFlushes += 1
        lock.unlock()
        onSubtitleFlush?()
    }

    func flushAudio() {
        lock.lock()
        audioAtLastFlush = recordedAudio.count
        audioFlushes += 1
        lock.unlock()
    }

    /// How many times the player offered a track to libass. It is refused, so
    /// the text path is what draws it, but the offer is the routing decision.
    var styledOfferCount: Int {
        lock.lock(); defer { lock.unlock() }
        return styledOffers
    }

    var styledFlushCount: Int {
        lock.lock(); defer { lock.unlock() }
        return styledFlushes
    }

    /// How many times the player tore a styled track down, offered or not.
    var styledStopCount: Int {
        lock.lock(); defer { lock.unlock() }
        return styledStops
    }

    /// Whether the double takes the track. False is the answer a sink gives
    /// when libass cannot draw it, and the one every test but the teardown ones
    /// wants: it is what keeps the text path under test.
    var acceptsStyled = false
    /// Runs inside startStyled, so a test can do there what another thread
    /// would have done in that window.
    var duringStartStyled: (() -> Void)?

    func startStyled(
        header: Data, fonts: [Data], canvasWidth: Int, canvasHeight: Int,
        completion: @escaping (Bool) -> Void
    ) {
        lock.lock(); styledOffers += 1; lock.unlock()
        duringStartStyled?()
        // This double has no renderer and draws nothing, which is exactly the
        // answer a sink gives when libass cannot take a track. Answered on
        // the caller's thread, so a test reads the selection as soon as it
        // returns.
        completion(acceptsStyled)
    }

    func stopCues() {}

    func stopStyled() {
        lock.lock(); styledStops += 1; lock.unlock()
    }

    func enqueueStyled(event: Data, start: Double, duration: Double) {}

    func flushStyled() {
        lock.lock(); styledFlushes += 1; lock.unlock()
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return recordedSamples.count
    }
}

/// A sink whose readiness is driven by the test, to exercise backpressure.
/// The pull engine never drops for it - it only ever holds the queue - so
/// what this double proves is that every frame still arrives, and in order,
/// once the gate opens again.
final class RecordingGatedSink: FrameSink {
    private let lock = NSLock()
    private var ready: Bool
    private var flags: [Bool] = []
    private var times: [CMTime] = []
    private var videoTimer: DispatchSourceTimer?
    /// The queue `requestVideo` was handed - the same one its pull loop
    /// below runs on. Stored only so `closeGateAndSettle` can
    /// synchronize against it.
    private var pullQueue: DispatchQueue?

    init(ready: Bool) {
        self.ready = ready
    }

    var isReadyForMoreFrames: Bool {
        lock.lock(); defer { lock.unlock() }
        return ready
    }

    var isReadyForMoreAudio: Bool { true }

    var audioPassthroughError: String? { nil }

    var hasDisplayedPicture: Bool { true }

    var videoDecodeFailure: String? { nil }

    var presentationTime: Double { 0 }

    func setReady(_ value: Bool) {
        lock.lock(); ready = value; lock.unlock()
    }

    /// Closes the gate, then blocks until any pull already in flight (or
    /// already enqueued to run) on the sink's own pull queue has finished -
    /// closing the gap between setting `ready` false from this thread and
    /// the pull loop's own `while self.isReadyForMoreFrames` check below,
    /// which reads it on a different thread and can still be mid-iteration,
    /// one pull past the write, the instant it lands. A caller that reads
    /// `count` right after this call is reading a value nothing can move
    /// again until the gate reopens.
    func closeGateAndSettle() {
        setReady(false)
        lock.lock(); let queue = pullQueue; lock.unlock()
        queue?.sync {}
    }

    /// True where the sample was a sync sample, in the order they arrived.
    var syncFlags: [Bool] {
        lock.lock(); defer { lock.unlock() }
        return flags
    }

    /// The presentation time of every sample this sink accepted, in the
    /// order it accepted them.
    var samples: [CMTime] {
        lock.lock(); defer { lock.unlock() }
        return times
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return flags.count
    }

    func start(atPresentation seconds: Double) {}

    func anchor(atPresentation seconds: Double) {}

    func setRate(_ rate: Float) {}

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: false
        ) as? [[CFString: Any]]
        let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        lock.lock()
        flags.append(!notSync)
        times.append(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        lock.unlock()
    }

    func enqueueAudio(_ sampleBuffer: CMSampleBuffer) {}

    /// Drains only while the test-driven `ready` flag holds, the same gate
    /// `isReadyForMoreFrames` reads: a pulling engine sees the same
    /// backpressure a pushed one would have been refused with.
    func requestVideo(on queue: DispatchQueue, provider: @escaping () -> CMSampleBuffer?) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0 / 120.0)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            while self.isReadyForMoreFrames {
                guard let sample = provider() else { return }
                self.enqueue(sample)
            }
        }
        lock.lock(); videoTimer = timer; pullQueue = queue; lock.unlock()
        timer.resume()
    }

    func requestAudio(on queue: DispatchQueue, provider: @escaping () -> CMSampleBuffer?) {}

    func stopRequestingMedia() {
        lock.lock()
        let timer = videoTimer
        videoTimer = nil
        lock.unlock()
        timer?.cancel()
    }

    /// The timer above polls on its own cadence, gated only by `ready`, so
    /// this double never goes idle: nothing for a resume to do.
    func resumeVideoIfIdle() {}

    func resumeAudioIfIdle() {}

    func setWantsExtendedDynamicRange(_ value: Bool) {}

    func flush(keepingImage: Bool) {}

    func enqueueSubtitle(_ cue: SubtitleCue) {}

    func flushSubtitles() {}

    func flushAudio() {}

    func startStyled(
        header: Data, fonts: [Data], canvasWidth: Int, canvasHeight: Int,
        completion: @escaping (Bool) -> Void
    ) {
        completion(false)
    }

    func stopStyled() {}

    func enqueueStyled(event: Data, start: Double, duration: Double) {}

    func flushStyled() {}
}

final class EventLog {
    private let lock = NSLock()
    private var events: [PlayerEvent] = []

    func append(_ event: PlayerEvent) {
        lock.lock(); events.append(event); lock.unlock()
    }

    var all: [PlayerEvent] {
        lock.lock(); defer { lock.unlock() }
        return events
    }
}

/// A short .mkv with a decodable AAC track and an E-AC-3 track passthrough
/// qualifies for, so a test can switch between the two pipelines without
/// touching `VideoFixture.swift`, which only ever authors AAC. The E-AC-3
/// frames are never decoded on the passthrough path, so their bytes do not
/// need to be a real bitstream, the same shortcut `AudioPassthroughTests`
/// takes.
private func makeDualAudioFixture(directory: URL, name: String) throws -> URL {
    let source = try makeVideoFixture(
        directory: directory, name: "\(name).source.mp4", codec: .h264,
        width: 320, height: 180, frameCount: 48, fps: 24, audio: true
    )
    let demuxer = try Demuxer(url: source)
    guard let video = demuxer.streams.first(where: { $0.kind == .video }),
          let audio = demuxer.streams.first(where: { $0.kind == .audio })
    else { throw SubtitleFixtureError.noSourceTrack }
    func stamp(_ ticks: Int64, _ stream: MediaStream) -> Int {
        let seconds = Double(ticks) * Double(stream.timeBaseNum) / Double(stream.timeBaseDen)
        return Int((seconds * 1000).rounded())
    }
    var frames: [MatroskaFrame] = []
    while let packet = try demuxer.readPacket() {
        if packet.streamIndex == video.index {
            frames.append(MatroskaFrame(
                track: 1, milliseconds: stamp(packet.pts ?? packet.dts ?? 0, video),
                decodeMilliseconds: stamp(packet.dts ?? packet.pts ?? 0, video),
                isKeyframe: packet.isKeyframe, data: packet.copiedBytes
            ))
        } else if packet.streamIndex == audio.index {
            let milliseconds = stamp(packet.pts ?? packet.dts ?? 0, audio)
            guard milliseconds >= 0 else { continue }
            frames.append(MatroskaFrame(
                track: 2, milliseconds: milliseconds, isKeyframe: true, data: packet.copiedBytes
            ))
        }
    }
    let durationMilliseconds = Int(demuxer.duration * 1000)
    for milliseconds in stride(from: 0, to: durationMilliseconds, by: 250) {
        frames.append(MatroskaFrame(
            track: 3, milliseconds: milliseconds, isKeyframe: true,
            data: Data(repeating: 0, count: 16)
        ))
    }
    let tracks = [
        MatroskaTrack(
            number: 1, kind: .video, codecID: "V_MPEG4/ISO/AVC",
            codecPrivate: video.extradata, width: 320, height: 180, language: "und"
        ),
        MatroskaTrack(
            number: 2, kind: .audio, codecID: "A_AAC", codecPrivate: audio.extradata,
            sampleRate: 48000, channels: 2, language: "eng", name: "Stereo"
        ),
        MatroskaTrack(
            number: 3, kind: .audio, codecID: "A_EAC3",
            sampleRate: 48000, channels: 6, language: "eng", name: "Atmos", isDefault: false
        ),
    ]
    return try makeMatroskaFixture(
        directory: directory, name: name, tracks: tracks, frames: frames,
        durationMilliseconds: durationMilliseconds, cueTrack: 1
    )
}

/// Two seconds of AAC over one second of video: the sound's tail plays on
/// after the last picture.
private func makeAudioTailFixture(directory: URL, name: String) throws -> URL {
    let source = try makeVideoFixture(
        directory: directory, name: "\(name).source.mp4", codec: .h264,
        width: 320, height: 180, frameCount: 48, fps: 24, audio: true
    )
    let demuxer = try Demuxer(url: source)
    guard let video = demuxer.streams.first(where: { $0.kind == .video }),
          let audio = demuxer.streams.first(where: { $0.kind == .audio })
    else { throw SubtitleFixtureError.noSourceTrack }
    func stamp(_ ticks: Int64, _ stream: MediaStream) -> Int {
        Int((Double(ticks) * Double(stream.timeBaseNum) / Double(stream.timeBaseDen) * 1000).rounded())
    }
    var frames: [MatroskaFrame] = []
    while let packet = try demuxer.readPacket() {
        if packet.streamIndex == video.index {
            let milliseconds = stamp(packet.pts ?? packet.dts ?? 0, video)
            guard milliseconds < 1000 else { continue }
            frames.append(MatroskaFrame(
                track: 1, milliseconds: milliseconds,
                decodeMilliseconds: stamp(packet.dts ?? packet.pts ?? 0, video),
                isKeyframe: packet.isKeyframe, data: packet.copiedBytes
            ))
        } else if packet.streamIndex == audio.index {
            let milliseconds = stamp(packet.pts ?? packet.dts ?? 0, audio)
            guard milliseconds >= 0 else { continue }
            frames.append(MatroskaFrame(
                track: 2, milliseconds: milliseconds, isKeyframe: true, data: packet.copiedBytes
            ))
        }
    }
    let tracks = [
        MatroskaTrack(
            number: 1, kind: .video, codecID: "V_MPEG4/ISO/AVC",
            codecPrivate: video.extradata, width: 320, height: 180, language: "und"
        ),
        MatroskaTrack(
            number: 2, kind: .audio, codecID: "A_AAC", codecPrivate: audio.extradata,
            sampleRate: 48000, channels: 2, language: "eng", name: "Stereo"
        ),
    ]
    return try makeMatroskaFixture(
        directory: directory, name: name, tracks: tracks, frames: frames,
        durationMilliseconds: Int(demuxer.duration * 1000), cueTrack: 1
    )
}

/// A byte source backed by a real file, that answers no faster than the
/// content plays (a direct-play server with little bandwidth headroom over
/// the file's own bitrate) and stalls once per entry in `stalls`, the first
/// time a read crosses that entry's own `atByte`. Held behind the handle
/// itself, not a static, since a C function pointer cannot capture.
///
/// An mp4 without faststart carries its moov atom at the very end, so
/// `avformat_open_input` seeks there before any sequential read of the
/// stream itself - and that seek, plus whatever the format probe reads
/// sequentially from byte 0 first, both run through this same source and
/// would otherwise retire a caller's own low `atByte` entry long before
/// real playback ever reaches it. `openTimeSacrifices` is what those
/// open-time reads retire instead, so every caller-supplied entry survives
/// to fire against a real, sequential, mid-playback read.
final class StallingSource {
    private let bytes: Data
    private var position = 0
    /// Each fires once, the first time `position` reaches it; consumed in
    /// order so several can be spread across one file.
    private var pendingStalls: [(atByte: Int, seconds: TimeInterval)]
    private let secondsPerByte: Double

    /// Sacrificial entries at the very front of the file: negligible in
    /// their own right, they exist only to be the ones the open-time probe
    /// and moov seek retire, so every caller-supplied entry survives to
    /// fire against a real, sequential, mid-playback read instead.
    private static let openTimeSacrifices = (1...10).map { (atByte: $0, seconds: 0.001) }

    init(bytes: Data, contentSeconds: Double, stalls: [(atByte: Int, seconds: TimeInterval)]) {
        self.bytes = bytes
        pendingStalls = (StallingSource.openTimeSacrifices + stalls).sorted { $0.atByte < $1.atByte }
        secondsPerByte = contentSeconds / Double(bytes.count)
    }

    func read(_ buffer: UnsafeMutablePointer<UInt8>, _ length: Int32) -> Int64 {
        let remaining = bytes.count - position
        guard remaining > 0 else { return 0 }
        let count = min(Int(length), remaining)
        bytes.copyBytes(to: buffer, from: position..<(position + count))
        position += count
        // A `while`, not an `if`: reads here move whole AVIO buffers at a
        // time (megabytes), so the seek-to-the-moov-atom-and-back dance
        // `avformat_open_input` does on a non-faststart file can cross
        // several pending entries in a single call - the ten sacrificial
        // ones are all inside that first buffer's worth of bytes on
        // purpose. An `if` here only ever retires ONE entry per call, so
        // the rest were retired one-per-call by whichever ordinary,
        // sequential, real-content reads happened to run next - each of
        // those paid the sacrifice's trivial sleep instead of its own
        // real pacing sleep, letting the reader race far ahead of the
        // content-time position this source means to simulate. Retiring
        // every entry the jump already passed, in the same call, is what
        // keeps every later read's own pacing honest.
        var retiredAStall = false
        while let next = pendingStalls.first, position >= next.atByte {
            pendingStalls.removeFirst()
            usleep(useconds_t(next.seconds * 1_000_000))
            retiredAStall = true
        }
        if !retiredAStall {
            usleep(useconds_t(secondsPerByte * Double(count) * 1_000_000))
        }
        return Int64(count)
    }

    func seek(_ offset: Int64, _ whence: Int32) -> Int64 {
        switch whence {
        case 1: position += Int(offset)
        case 2: position = bytes.count + Int(offset)
        default: position = Int(offset)
        }
        position = max(0, position)
        return Int64(position)
    }

    var size: Int64 { Int64(bytes.count) }
}

/// `contentSeconds` of playback delivered no faster than it plays, with one
/// stall of `stallSeconds` the first time the read crosses halfway through
/// the file's bytes.
func stallingStream(
    bytes: Data, contentSeconds: Double, stallSeconds: TimeInterval
) -> MediaStreamIO {
    stallingStream(
        bytes: bytes, contentSeconds: contentSeconds,
        stalls: [(atByte: bytes.count / 2, seconds: stallSeconds)]
    )
}

/// `contentSeconds` of playback delivered no faster than it plays, stalling
/// once at each point in `stalls` the first time the read crosses it.
func stallingStream(
    bytes: Data, contentSeconds: Double, stalls: [(atByte: Int, seconds: TimeInterval)]
) -> MediaStreamIO {
    let source = StallingSource(bytes: bytes, contentSeconds: contentSeconds, stalls: stalls)
    return MediaStreamIO(
        handle: Unmanaged.passRetained(source).toOpaque(),
        read: { handle, buffer, length in
            guard let handle, let buffer else { return -1 }
            return Unmanaged<StallingSource>.fromOpaque(handle)
                .takeUnretainedValue().read(buffer, length)
        },
        seek: { handle, offset, whence in
            guard let handle else { return -1 }
            return Unmanaged<StallingSource>.fromOpaque(handle)
                .takeUnretainedValue().seek(offset, whence)
        },
        size: { handle in
            guard let handle else { return -1 }
            return Unmanaged<StallingSource>.fromOpaque(handle).takeUnretainedValue().size
        },
        close: { handle in
            guard let handle else { return }
            Unmanaged<StallingSource>.fromOpaque(handle).release()
        }
    )
}

/// What the engine's own spans are divided by here, against the film they
/// were measured off.
///
/// These tests assert relationships - a stall outlasting the lead the reader
/// could have built, a buffer crossing a watermark, a rebuffer costing a
/// fraction of the content - and a relationship holds at any scale. Playing a
/// twelve second film to watch a four second stall spends twelve seconds
/// proving something a second and a half proves as well, so every span the
/// engine reasons in and every span of the fixture are divided by the same
/// figure and the relationships between them are untouched.
///
/// Eight is as far as it goes: the sink's own delivery, the watchdog's tick
/// and the reader's poll are real work on a real machine, and a watermark
/// pushed much below a tenth of a second stops being reliably distinguishable
/// from the jitter of getting there.
let testTimeScale = 8.0

/// The engine's own spans, as the stall tests read them back. Named rather
/// than repeated as literals: a test that asserts a buffer crossed "2.0" says
/// nothing about which 2.0 it meant, and these tests are about the watermarks
/// themselves.
///
/// `readAheadBytes` scales with the seconds: it is what the size of the stall
/// fixture below is measured against, and a window left at its full size over
/// a film scaled down would simply swallow the whole clip.
let testBufferPolicy = BufferPolicy(
    lowWatermarkSeconds: BufferPolicy.standard.lowWatermarkSeconds / testTimeScale,
    highWatermarkSeconds: BufferPolicy.standard.highWatermarkSeconds / testTimeScale,
    videoSampleTargetSeconds: BufferPolicy.standard.videoSampleTargetSeconds / testTimeScale,
    audioSampleTargetSeconds: BufferPolicy.standard.audioSampleTargetSeconds / testTimeScale,
    pollInterval: BufferPolicy.standard.pollInterval / testTimeScale,
    readAheadBytes: Int(Double(ByteCache.windowCapacity) / testTimeScale),
    firstPictureGraceSeconds: BufferPolicy.standard.firstPictureGraceSeconds / testTimeScale,
    pictureWatchdogInterval: BufferPolicy.standard.pictureWatchdogInterval / testTimeScale
)
/// Longer than the lead the reader can build by the time paced playback
/// reaches the stall, so the stall lands on the reader instead of being
/// absorbed silently.
let stallOutlastingTheLead = 4.0 / testTimeScale

let bigStallFixtureFPS = 24
/// A whole number of frames at `bigStallFixtureFPS`, so the duration below is
/// the exact one the encode really has: a frame count that does not divide
/// evenly leaves the two disagreeing by a fraction of a frame, and the stall
/// tests assert to within one frame.
let bigStallFixtureFrames = 36
let bigStallFixtureSeconds = Double(bigStallFixtureFrames) / Double(bigStallFixtureFPS)
/// One frame of it, in content seconds.
let bigStallFixtureFrameSeconds = 1.0 / Double(bigStallFixtureFPS)
/// Nearly every packet the fixture has: far enough in that a stall past the
/// window has landed and been recovered from, short enough of the end that
/// the reader is still working when the count is reached. A fraction of the
/// fixture rather than a count of its own, which would quietly become
/// unreachable - and a spin to its deadline - the moment the fixture changed.
let bigStallFixtureMostPackets = bigStallFixtureFrames * 29 / 30

/// A noisy 720p film twice the size of the policy's read-ahead window, shared
/// by every test that has to watch the reader do something.
///
/// Sized off the window rather than off a frame count: a film that fits
/// inside the read-ahead window is one the reader buffers whole and then
/// never touches the source again, so no stall, no mid-stream failure and no
/// seek can reach it - the questions those tests mean to ask cannot even be
/// put. Twice the window is the smallest size that still leaves room for two
/// separated events beyond it.
///
/// Shared rather than per-test because encoding it is heavy enough that
/// generating one for each has made AVAssetWriter fail outright under the
/// sustained load of back-to-back encodes in the same process.
let bigStallFixtureBytes: Data = {
    let url = try! makeVideoFixture(
        directory: FileManager.default.temporaryDirectory, name: "player-big-stall-source.mp4",
        codec: .h264, width: 1280, height: 720, frameCount: bigStallFixtureFrames,
        fps: Int32(bigStallFixtureFPS), noisy: true,
        bitrate: Int(Double(testBufferPolicy.readAheadBytes) * 2 * 8 / bigStallFixtureSeconds)
    )
    return try! Data(contentsOf: url)
}()

/// Where an event has to sit for the reader to feel it at all: past everything
/// the read-ahead window can hold by the time paced playback reaches it.
///
/// A fraction of the film rather than a multiple of the window, though the
/// two agree wherever the encode comes out at exactly twice the window. The
/// encoder only ever takes a target bitrate as a hint and routinely overshoots
/// it, so a multiple of the window lands at a different point of a longer film
/// than it was chosen for - and how far into the film a stall falls is the
/// whole of what these two constants say. `bigStallFixtureIsPastTheWindow`
/// below is what still holds them past the window.
let stallPastTheWindow = bigStallFixtureBytes.count * 5 / 8
/// A second one, far enough beyond the first that its own recovery is long
/// finished before this one lands.
let stallFurtherPastTheWindow = bigStallFixtureBytes.count * 13 / 16

/// That the film really is bigger than the window, which is what makes both
/// offsets above sit past it. Asserted by the tests that rely on it rather
/// than assumed here, where a failure would read as a crash on startup.
var bigStallFixtureIsPastTheWindow: Bool {
    bigStallFixtureBytes.count > 2 * testBufferPolicy.readAheadBytes
}

/// The one film here still played at the rate a real one is, for the one
/// test that cannot be told at any other scale.
///
/// Two stalls each producing their own pause and resume need the second to
/// land on a pipeline that has resumed and drained since the first, and what
/// makes that happen is the stall being longer than the lead the reader can
/// still build with the film about to end. That margin is thin even at full
/// length - a four second stall against the four and a half seconds of film
/// left after the first - and dividing both sides of it does not preserve it:
/// the lead wins instead, the second stall is absorbed in silence, and the
/// test stops testing anything. So this one keeps the full film and the
/// standard policy, and costs what it costs.
let separatedStallsPolicy = BufferPolicy.standard
let separatedStallsFrames = 300
let separatedStallsSeconds = Double(separatedStallsFrames) / Double(bigStallFixtureFPS)
let separatedStallsBytes: Data = {
    let url = try! makeVideoFixture(
        directory: FileManager.default.temporaryDirectory, name: "player-separated-stalls.mp4",
        codec: .h264, width: 1280, height: 720, frameCount: separatedStallsFrames,
        fps: Int32(bigStallFixtureFPS), noisy: true,
        bitrate: Int(Double(separatedStallsPolicy.readAheadBytes) * 2 * 8 / separatedStallsSeconds)
    )
    return try! Data(contentsOf: url)
}()
let separatedStallFirst = separatedStallsBytes.count * 5 / 8
let separatedStallSecond = separatedStallsBytes.count * 13 / 16

final class LexisPlayerTests: XCTestCase {
    /// The close callback is a C function pointer and cannot capture, so the
    /// count of streams the player let go of lives here.
    private static var closeCount = 0

    /// A core stream that counts its own close, so a player holding one past
    /// the point it claims to have released it is visible.
    private func countedStream(handle: OpaquePointer) -> MediaStreamIO {
        let core = coreStream(handle: handle)
        return MediaStreamIO(
            handle: core.handle,
            read: core.read,
            seek: core.seek,
            size: core.size,
            close: { handle in
                lexis_stream_close(OpaquePointer(handle))
                LexisPlayerTests.closeCount += 1
            }
        )
    }

    func testPlaysAFileToEndOfStreamInRealTime() throws {
        try skipUnlessRealtimeTests()
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "player-hevc.mp4",
            codec: .hevc, width: 320, height: 240, frameCount: 48, fps: 24
        )
        let sink = CountingSink()
        // Nothing paces delivery to content time any more: without this,
        // the whole clip could be delivered in a busy loop's worth of real
        // time, and the "real time, not a busy loop" assertion below would
        // have nothing left to tell the two apart.
        sink.setEnqueueDelay(0.03)
        let player = LexisPlayer(sink: sink)
        var seen: [PlayerEvent] = []
        let ended = expectation(description: "end of stream")
        let collector = Task {
            for await event in player.events {
                seen.append(event)
                if event == .endOfStream { ended.fulfill() }
            }
        }
        try player.open(url: url)
        let started = hostTimeSeconds()
        player.play()
        wait(for: [ended], timeout: 10)
        let elapsed = hostTimeSeconds() - started
        collector.cancel()

        XCTAssertEqual(sink.count, 48)
        XCTAssertEqual(sink.startedAt, 0)
        XCTAssertEqual(player.stats.packetsRead, 48)
        XCTAssertEqual(player.stats.framesDisplayed, 48)
        XCTAssertEqual(player.stats.framesDropped, 0)
        XCTAssertEqual(seen.first, .opened(width: 320, height: 240, codec: "hevc"))
        // 48 frames at 24 fps, fed with a fixed lead: real time, not a busy loop
        XCTAssertGreaterThan(elapsed, 1.0)
        XCTAssertLessThan(elapsed, 8.0)
    }

    func testThePositionStopsAtTheDurationAfterTheEnd() throws {
        try skipUnlessRealtimeTests()
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "player-ended-position.mp4",
            codec: .h264, width: 320, height: 240, frameCount: 48, fps: 24
        )
        let sink = CountingSink()
        // Nothing paces delivery to content time any more: without this,
        // end of stream fires while the clock is still anchored near zero,
        // and the sleep below would not be enough on its own to carry it
        // past the duration.
        sink.setEnqueueDelay(0.03)
        let player = LexisPlayer(sink: sink)
        let ended = expectation(description: "end of stream")
        let collector = Task {
            for await event in player.events where event == .endOfStream { ended.fulfill() }
        }
        try player.open(url: url)
        player.play()
        wait(for: [ended], timeout: 10)
        collector.cancel()
        // The end of stream stops nothing: the renderers still hold the tail,
        // so the clock keeps running past the stream it just finished.
        let duration = player.stats.duration
        pollUntil("the clock to run past the stream it finished") {
            sink.presentationTime > duration
        }

        XCTAssertEqual(duration, 2.0, accuracy: 0.2)
        XCTAssertGreaterThan(sink.presentationTime, duration)
        // what every consumer computes a seek target from
        XCTAssertLessThanOrEqual(player.stats.position, duration)
        XCTAssertGreaterThan(player.stats.position, duration - 0.5)
        player.stop()
    }

    func testPauseStopsFeedingAndPlayResumes() throws {
        try skipUnlessRealtimeTests()
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "player-pause.mp4",
            codec: .hevc, width: 320, height: 240, frameCount: 120, fps: 24
        )
        let sink = CountingSink()
        // Nothing paces delivery to content time any more, so a short clip
        // would otherwise finish inside the sleep below and leave pause()
        // nothing left to catch.
        sink.setEnqueueDelay(0.01)
        let player = LexisPlayer(sink: sink)
        try player.open(url: url)
        player.play()
        // The clock actually running, not merely a first frame delivered: a
        // pause that lands before the sink's own clock has started races it,
        // and the reading below is then of a clock that started afterwards.
        pollUntil("the clock to be running before the pause") { player.stats.position > 0.2 }
        player.pause()
        let positionAtPause = player.stats.position
        // Buffering ahead while paused is correct under the pull pipeline -
        // rate 0 stops the sink's own clock, not the queues filling behind
        // it - so what pause actually promises, and what every consumer
        // reads a position from, is that the clock itself holds still.
        usleep(400_000)
        XCTAssertEqual(player.stats.position, positionAtPause, accuracy: 0.001)
        XCTAssertGreaterThan(positionAtPause, 0)
        XCTAssertLessThan(positionAtPause, 5.0)
        // The sink's clock has to stop with the reader, or it runs on through
        // the pause.
        XCTAssertEqual(sink.rates, [0])
        player.play()
        pollUntil("the clock to move again once resumed") {
            player.stats.position > positionAtPause
        }
        XCTAssertGreaterThan(player.stats.position, positionAtPause)
        XCTAssertEqual(sink.rates, [0, 1])
        XCTAssertEqual(player.stats.framesDropped, 0)
        let flushesBeforeStop = sink.flushes
        player.stop()
        XCTAssertEqual(sink.flushes, flushesBeforeStop + 1)
    }

    /// The pull engine never drops for a refusing sink - it only ever holds
    /// the queue. A closed gate is never even asked (`isReadyForMoreFrames`
    /// gates the pull itself, not what the engine does with a refusal), so
    /// nothing is enqueued at all while it stays shut, keyframe or not.
    func testAFullSinkHoldsTheQueueAndNothingIsDropped() throws {
        try skipUnlessRealtimeTests()
        let frameCount = 240
        // gopSize forces off the encoder's own frame reordering: the
        // passthrough path hands the sink compressed samples in decode
        // order, and this test's order assertion is about the pipeline
        // never losing one, not about a real renderer's own reordering.
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "player-backpressure.mp4",
            codec: .hevc, width: 320, height: 240, frameCount: frameCount, fps: 24, gopSize: frameCount
        )
        let sink = RecordingGatedSink(ready: false)
        let player = LexisPlayer(sink: sink)
        try player.open(url: url)
        player.play()

        // long enough for the packet and sample queues to fill and park: a
        // shut gate is never pulled, so nothing here is ever popped
        usleep(1_000_000)
        XCTAssertEqual(sink.count, 0)
        XCTAssertEqual(player.stats.framesDropped, 0)
        XCTAssertGreaterThan(player.stats.packetsRead, 0)

        sink.setReady(true)
        let deadline = Date(timeIntervalSinceNow: 30)
        while sink.count < frameCount, Date() < deadline {
            usleep(20_000)
        }
        player.stop()

        XCTAssertEqual(sink.count, frameCount)
        XCTAssertEqual(player.stats.framesDropped, 0)
        XCTAssertEqual(sink.samples, sink.samples.sorted { $0.seconds < $1.seconds })
    }

    /// Nothing paces the demux thread against a clock, so a blocking read
    /// that stalls just makes the thread that owns it block a while longer;
    /// the queues it feeds simply drain a little further before it resumes.
    /// The file still plays out complete, and nothing is ever dropped for it.
    func testANetworkStallDropsNoFramesAndPlaybackCompletes() throws {
        try skipUnlessRealtimeTests()
        // Noisy: a compressible fixture is small enough that FFmpeg's own
        // probe during open() reads the whole thing through the 256 KiB AVIO
        // buffer, and the stall this test means for the middle of playback
        // fires during open instead, felt only as open() taking longer.
        let frames = Int(240 / testTimeScale)
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "player-stall.mp4",
            codec: .h264, width: 320, height: 240, frameCount: frames,
            fps: Int32(bigStallFixtureFPS), noisy: true
        )
        let bytes = try Data(contentsOf: url)
        let stream = stallingStream(
            bytes: bytes, contentSeconds: Double(frames) / Double(bigStallFixtureFPS),
            stallSeconds: 1.5 / testTimeScale)
        let sink = CountingSink()
        let player = LexisPlayer(sink: sink, policy: testBufferPolicy)
        try player.open(stream: stream)
        player.play()

        let deadline = Date(timeIntervalSinceNow: 20)
        while player.stats.packetsRead < frames, Date() < deadline {
            usleep(50_000)
        }
        player.stop()

        // A stall this far inside the read-ahead window is fully absorbed:
        // the file plays out complete and nothing is dropped.
        XCTAssertEqual(player.stats.packetsRead, frames)
        XCTAssertEqual(player.stats.framesDropped, 0)
    }

    /// A stall bigger than both the read-ahead buffer can absorb and the lead
    /// time the reader is normally allowed to run ahead by. `atByte` sits
    /// well past what the read-ahead window could have pre-fetched by
    /// the time real, paced playback reaches it, so the stall lands on the
    /// reader itself rather than being absorbed silently, and the reader
    /// must pause and resume around it without dropping frames.
    func testAVeryLongStallPausesAndResumesWithZeroDrops() throws {
        try skipUnlessRealtimeTests()
        let bytes = bigStallFixtureBytes
        let stream = stallingStream(
            bytes: bytes, contentSeconds: bigStallFixtureSeconds,
            stalls: [(atByte: stallPastTheWindow, seconds: stallOutlastingTheLead)]
        )
        XCTAssertTrue(bigStallFixtureIsPastTheWindow)
        let sink = CountingSink()
        let player = LexisPlayer(sink: sink, policy: testBufferPolicy)
        try player.open(stream: stream)
        player.play()

        let deadline = Date(timeIntervalSinceNow: 20)
        while player.stats.packetsRead < bigStallFixtureMostPackets, Date() < deadline {
            usleep(50_000)
        }
        player.stop()

        XCTAssertEqual(player.stats.framesDropped, 0)
        XCTAssertGreaterThanOrEqual(player.stats.rebufferCount, 1)
    }

    /// Two stalls spread through one file, each well clear of the other and
    /// each past what the read-ahead buffer can pre-fetch by the time real
    /// playback reaches it: the reader must pause and resume for each in
    /// turn, not just the first, and still drop nothing.
    ///
    /// Waits for `.endOfStream` rather than polling `packetsRead` toward a
    /// fixed count: the second stall's own recovery can read to within a
    /// few packets of the file's own end refilling to the high watermark,
    /// so a `packetsRead` threshold picked to sit short of that races
    /// whichever rebuffer is still resolving there - a `stop()` landing in
    /// that gap can cut off before the second rebuffer is counted even
    /// though the engine's own recovery is already deterministic.
    /// `.endOfStream` only fires once every buffering span has resolved
    /// (`waitOutStarvation`'s own recovery step also resolves on reaching
    /// real end of stream), so it is the one point at which `rebufferCount`
    /// is guaranteed final.
    func testSeveralStallsEachPauseAndResumeWithZeroDrops() throws {
        try skipUnlessRealtimeTests()
        let bytes = separatedStallsBytes
        let stream = stallingStream(
            bytes: bytes, contentSeconds: separatedStallsSeconds,
            stalls: [
                (atByte: separatedStallFirst, seconds: 4.0),
                (atByte: separatedStallSecond, seconds: 4.0),
            ]
        )
        XCTAssertGreaterThan(bytes.count, 2 * separatedStallsPolicy.readAheadBytes)
        let sink = CountingSink()
        let player = LexisPlayer(sink: sink, policy: separatedStallsPolicy)
        let ended = expectation(description: "end of stream")
        let collector = Task {
            for await event in player.events {
                if event == .endOfStream { ended.fulfill() }
            }
        }
        try player.open(stream: stream)
        player.play()

        wait(for: [ended], timeout: 90)
        player.stop()
        collector.cancel()

        XCTAssertEqual(player.stats.framesDropped, 0)
        XCTAssertGreaterThanOrEqual(player.stats.rebufferCount, 2)
    }

    func testPlayAfterEndOfStreamDoesNothingUntilReopened() throws {
        try skipUnlessRealtimeTests()
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "player-restart.mp4",
            codec: .hevc, width: 320, height: 240, frameCount: 24, fps: 24
        )
        let sink = CountingSink()
        let player = LexisPlayer(sink: sink)
        let log = EventLog()
        let ended = expectation(description: "end of stream")
        // Waited on only once, below; the second play() later in this test
        // reaches its own end of stream too, and nothing paces delivery to
        // content time any more for that one to arrive well inside this
        // test's own sleeps rather than after them.
        ended.assertForOverFulfill = false
        let collector = Task {
            for await event in player.events {
                log.append(event)
                if event == .endOfStream { ended.fulfill() }
            }
        }
        try player.open(url: url)
        player.play()
        wait(for: [ended], timeout: 10)

        let atEnd = sink.count
        XCTAssertEqual(atEnd, 24)
        // End of stream leaves the tail of the stream in the sink to play out;
        // only the open() that starts the next file clears it.
        let flushesAtEnd = sink.flushes
        XCTAssertEqual(flushesAtEnd, 1)
        // A spent stream is not restartable, and saying .playing would be a lie.
        player.play()
        usleep(200_000)
        XCTAssertEqual(sink.count, atEnd)
        XCTAssertEqual(player.stats.packetsRead, 24)
        XCTAssertEqual(log.all.filter { $0 == .playing }.count, 1)

        try player.open(url: url)
        XCTAssertEqual(sink.flushes, flushesAtEnd + 1)
        player.play()
        pollUntil("the reopened file to feed the sink again") { sink.count > atEnd }
        XCTAssertGreaterThan(sink.count, atEnd)
        XCTAssertEqual(log.all.filter { $0 == .playing }.count, 2)
        player.stop()
        collector.cancel()
    }

    func testPausingBeforePlayingDoesNotStallTheStart() throws {
        try skipUnlessRealtimeTests()
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "player-early-pause.mp4",
            codec: .hevc, width: 320, height: 240, frameCount: 120, fps: 24
        )
        let sink = CountingSink()
        let player = LexisPlayer(sink: sink)
        try player.open(url: url)
        player.pause()
        player.play()
        pollUntil("a play after a pause before any frame to still feed") { sink.count > 0 }
        XCTAssertGreaterThan(sink.count, 0)
        player.stop()
    }

    func testOpeningAFileWithoutVideoFails() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("not-media.mp4")
        try Data("not a container".utf8).write(to: url)
        let player = LexisPlayer(sink: CountingSink())
        XCTAssertThrowsError(try player.open(url: url))
        // adopt() throws before it commits anything: a caller watching this
        // must not read the failed open's defaults as a reading either
        XCTAssertFalse(player.isOpen)
    }

    func testIsOpenIsFalseUntilOpenCommitsAndFalseAgainAfterClose() throws {
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "player-is-open.mp4",
            codec: .hevc, width: 320, height: 240, frameCount: 20, fps: 24
        )
        let player = LexisPlayer(sink: CountingSink())
        // nothing has been asked for yet: a tick landing here reads defaults,
        // and isOpen is what says they are not a reading
        XCTAssertFalse(player.isOpen)
        try player.open(url: url)
        XCTAssertTrue(player.isOpen)
        player.close()
        XCTAssertFalse(player.isOpen)
    }

    func testAFailedOpenLeavesNothingOfThePreviousFile() throws {
        let good = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "player-replaced.mp4",
            codec: .hevc, width: 320, height: 240, frameCount: 120, fps: 24
        )
        let bad = FileManager.default.temporaryDirectory.appendingPathComponent("not-media-2.mp4")
        try Data("not a container".utf8).write(to: bad)
        let sink = CountingSink()
        let player = LexisPlayer(sink: sink)
        try player.open(url: good)
        XCTAssertThrowsError(try player.open(url: bad))
        player.play()
        usleep(200_000)
        XCTAssertEqual(sink.count, 0)
        XCTAssertEqual(player.stats.packetsRead, 0)
    }

    func testPlaysAStreamToEndOfStream() throws {
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "player-stream.mp4",
            codec: .hevc, width: 320, height: 240, frameCount: 48, fps: 24
        )
        let handle = try XCTUnwrap(lexis_stream_open_file(url.path, nil))
        let sink = CountingSink()
        let player = LexisPlayer(sink: sink)
        let ended = expectation(description: "end of stream")
        let collector = Task {
            for await event in player.events where event == .endOfStream {
                ended.fulfill()
            }
        }
        try player.open(stream: coreStream(handle: handle))
        player.play()
        wait(for: [ended], timeout: 10)
        collector.cancel()

        XCTAssertEqual(sink.count, 48)
        XCTAssertEqual(player.stats.packetsRead, 48)
        XCTAssertEqual(player.stats.framesDropped, 0)
    }

    func testCloseReleasesTheStreamAndOnlyAnOpenRevivesThePlayer() throws {
        try skipUnlessRealtimeTests()
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "player-close.mp4",
            codec: .hevc, width: 320, height: 240, frameCount: 48, fps: 24
        )
        LexisPlayerTests.closeCount = 0
        let sink = CountingSink()
        // Nothing paces delivery to content time any more: without this, the
        // first file's own 48 frames would fly through inside the 100 ms
        // window below and finish before close() ever interrupts it.
        sink.setEnqueueDelay(0.02)
        let player = LexisPlayer(sink: sink)
        let ended = expectation(description: "end of stream")
        let collector = Task {
            for await event in player.events where event == .endOfStream {
                ended.fulfill()
            }
        }

        let first = try XCTUnwrap(lexis_stream_open_file(url.path, nil))
        try player.open(stream: countedStream(handle: first))
        player.play()
        usleep(100_000)
        player.close()
        XCTAssertEqual(LexisPlayerTests.closeCount, 1)
        XCTAssertEqual(player.stats.packetsRead, 0)

        // there is nothing left to start, and a play() must not pretend there is
        let playedBeforeClose = sink.count
        player.play()
        usleep(100_000)
        XCTAssertEqual(sink.count, playedBeforeClose)

        let second = try XCTUnwrap(lexis_stream_open_file(url.path, nil))
        try player.open(stream: countedStream(handle: second))
        player.play()
        wait(for: [ended], timeout: 10)
        collector.cancel()
        XCTAssertEqual(sink.count, playedBeforeClose + 48)
        XCTAssertEqual(player.stats.packetsRead, 48)

        player.close()
        XCTAssertEqual(LexisPlayerTests.closeCount, 2)
    }

    func testAFailedStreamOpenLeavesThePlayerEmpty() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("player-not-media.bin")
        try Data(repeating: 7, count: 4096).write(to: url)
        let handle = try XCTUnwrap(lexis_stream_open_file(url.path, nil))
        let sink = CountingSink()
        let player = LexisPlayer(sink: sink)
        XCTAssertThrowsError(try player.open(stream: coreStream(handle: handle)))
        player.play()
        usleep(100_000)
        XCTAssertEqual(sink.count, 0)
    }

    func testPlaysTheAudioTrackIntoTheSink() throws {
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "player-audio.mp4",
            codec: .h264, width: 320, height: 240, frameCount: 96, fps: 24, audio: true
        )
        let sink = CountingSink()
        let player = LexisPlayer(sink: sink)
        try player.open(url: url)
        player.play()

        // the video can start a little behind the audio, its scaler readying
        let deadline = Date(timeIntervalSinceNow: 20)
        while sink.audio.count < 100 || sink.count <= 10, Date() < deadline {
            usleep(20_000)
        }
        player.stop()

        XCTAssertGreaterThanOrEqual(sink.audio.count, 100)
        XCTAssertGreaterThan(sink.count, 10)
        // audio and video ride the same timeline, so they arrive interleaved
        XCTAssertLessThan(sink.audio[0].seconds, 0.5)
        XCTAssertEqual(player.stats.duration, 4.0, accuracy: 0.2)
    }

    /// A decoder that throws part-way through a film has lost that packet's
    /// sound and nothing else: no audio frame is decoded against another, so
    /// the next packet it accepts plays. The reason it broke is reported
    /// either way - the same thing a refused route already says, since a
    /// viewer who is not told the sound died cannot act on it.
    func testAudioThatGoesCorruptMidStreamCostsThatFramesSoundAndSaysSo() throws {
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "player-audio-sound.mp4",
            codec: .h264, width: 320, height: 240, frameCount: 96, fps: 24, audio: true
        )
        let demuxer = try Demuxer(url: url)
        let audioStream = try XCTUnwrap(demuxer.streams.first { $0.kind == .audio })
        var payloads: [Data] = []
        while let packet = try demuxer.readPacket() {
            guard packet.streamIndex == audioStream.index else { continue }
            payloads.append(packet.copiedBytes)
        }
        XCTAssertGreaterThan(payloads.count, 120)

        // Garbage over one mid-stream audio frame, of exactly its length, so the
        // sample table still describes the file it sits in and only that frame
        // rots. The fixture's steady tone encodes to byte-identical frames, so
        // the copy to strike is found with a cursor that never goes back:
        // packets come out of the container in the order they are stored.
        var bytes = try Data(contentsOf: url)
        var cursor = bytes.startIndex
        var range = bytes.startIndex..<bytes.startIndex
        for payload in payloads[0...100] {
            range = try XCTUnwrap(bytes.range(of: payload, in: cursor..<bytes.endIndex))
            cursor = range.upperBound
        }
        bytes.replaceSubrange(range, with: Data(repeating: 0xFF, count: range.count))
        let corrupt = FileManager.default.temporaryDirectory
            .appendingPathComponent("player-audio-corrupt.mp4")
        try bytes.write(to: corrupt)

        let sink = CountingSink()
        let player = LexisPlayer(sink: sink)
        let log = EventLog()
        let ended = expectation(description: "end of stream")
        let collector = Task {
            for await event in player.events {
                log.append(event)
                if event == .endOfStream { ended.fulfill() }
            }
        }
        try player.open(url: corrupt)
        player.play()
        wait(for: [ended], timeout: 20)
        collector.cancel()

        XCTAssertEqual(sink.count, 96)
        XCTAssertFalse(log.all.contains { if case .failed = $0 { return true } else { return false } })
        // every frame but the rotten one, whose sound is the only sound lost:
        // without the recovery it stops at the rot, 101 frames in
        XCTAssertEqual(sink.audio.count, payloads.count - 1)
        XCTAssertFalse(
            player.stats.audioFallbackReason.isEmpty,
            "the readout has to say why the sound broke, as a refused route already does"
        )
    }

    /// A gate closed mid-stream, well clear of any keyframe boundary, is a
    /// full stop of the feed rather than a keyframes-only trickle: nothing
    /// but a pull ever moves a sample out of the queue. Reopening it lets
    /// the whole rest of the file arrive, in order, with nothing dropped.
    func testABlockedSinkStallsTheFeedAndEveryFrameStillArrivesInOrder() throws {
        try skipUnlessRealtimeTests()
        let frameCount = 240
        // gopSize forces off the encoder's own frame reordering, the same
        // reason `testAFullSinkHoldsTheQueueAndNothingIsDropped` above needs
        // it: decode order and presentation order coincide, so the order
        // assertion is about the pipeline, not a real renderer's reordering.
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "player-skip.mp4",
            codec: .h264, width: 320, height: 240, frameCount: frameCount, fps: 24, gopSize: frameCount
        )
        let sink = RecordingGatedSink(ready: true)
        let player = LexisPlayer(sink: sink)
        try player.open(url: url)
        player.play()

        let deadline = Date(timeIntervalSinceNow: 30)
        while sink.count < 3, Date() < deadline {
            usleep(20_000)
        }
        // `closeGateAndSettle` (not a plain `setReady(false)`) so `closedAt`
        // cannot be read out from under a pull the flag's own write raced:
        // see its doc comment.
        sink.closeGateAndSettle()
        let closedAt = sink.count
        usleep(500_000)
        XCTAssertEqual(sink.count, closedAt)
        XCTAssertEqual(player.stats.framesDropped, 0)

        sink.setReady(true)
        while sink.count < frameCount, Date() < deadline {
            usleep(20_000)
        }
        player.stop()

        XCTAssertEqual(sink.count, frameCount)
        XCTAssertEqual(player.stats.framesDropped, 0)
        XCTAssertEqual(sink.samples, sink.samples.sorted { $0.seconds < $1.seconds })
    }

    func testEACThreeAudioTakesThePassthroughPipeline() throws {
        let sink = CountingSink()
        let player = LexisPlayer(sink: sink)
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "audio-eac3.mp4",
            codec: .h264, width: 320, height: 180, frameCount: 4, fps: 30,
            audio: true
        )
        try player.open(url: url)
        player.play()
        let deadline = Date().addingTimeInterval(5)
        while player.stats.framesDisplayed < 4, Date() < deadline { usleep(5000) }
        // The fixture writer only ever authors AAC (see VideoFixture.swift),
        // so this pins the AAC-decodes case as the control: the codec check
        // in Task 5 is what makes an AC-3/E-AC-3 stream take the other path,
        // and that check is exercised directly in AudioPassthroughTests.
        XCTAssertEqual(player.stats.audioFormat, "pcm")
        XCTAssertFalse(player.stats.audioPassthrough)
        player.stop()
    }

    func testARouteThatRefusesPassthroughFallsBackOnceAndRecordsWhy() throws {
        let sink = CountingSink()
        let player = LexisPlayer(sink: sink)
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "audio-fallback.mp4",
            codec: .h264, width: 320, height: 180, frameCount: 4, fps: 30,
            audio: true
        )
        try player.open(url: url)
        sink.injectAudioPassthroughError("route refused the format")
        player.play()
        let deadline = Date().addingTimeInterval(5)
        while player.stats.framesDisplayed < 4, Date() < deadline { usleep(5000) }
        XCTAssertEqual(player.stats.audioFallbackReason, "route refused the format")
        player.stop()
    }

    func testAFormatTheRouteRefusedIsNotOfferedToItAgain() throws {
        let url = try makeDualAudioFixture(
            directory: FileManager.default.temporaryDirectory, name: "player-audio-refused.mkv"
        )
        let sink = CountingSink()
        let player = LexisPlayer(sink: sink)
        try player.open(url: url)
        let eac3 = try XCTUnwrap(player.tracks.audio.first { $0.codecName == "eac3" })
        player.selectAudioTrack(index: eac3.index)
        sink.injectAudioPassthroughError("route refused the format")
        player.play()
        let deadline = Date().addingTimeInterval(5)
        while player.stats.framesDisplayed < 48, Date() < deadline { usleep(5000) }
        player.stop()
        sink.injectAudioPassthroughError(nil)

        // The next engine over this file, and the same track chosen again, go
        // to the decoder: the bitstream the route refused is not offered again.
        for replay in 0..<2 {
            if replay == 1 { player.selectAudioTrack(index: eac3.index) }
            let heard = sink.audioFormats.count
            let shown = sink.count
            player.seek(to: 0)
            player.play()
            let playing = Date().addingTimeInterval(5)
            while sink.count < shown + 48, Date() < playing { usleep(5000) }
            player.stop()
            XCTAssertGreaterThanOrEqual(sink.count, shown + 48)
            XCTAssertFalse(
                sink.audioFormats.dropFirst(heard).contains(kAudioFormatEnhancedAC3), "replay \(replay)")
        }
        player.close()
    }

    func testSwitchingAudioTrackReDecidesThePipelineRatherThanKeepingTheOldOne() throws {
        let url = try makeDualAudioFixture(
            directory: FileManager.default.temporaryDirectory, name: "player-audio-swap.mkv"
        )
        let sink = CountingSink()
        let player = LexisPlayer(sink: sink)
        try player.open(url: url)
        let aac = try XCTUnwrap(player.tracks.audio.first { $0.codecName == "aac" })
        let eac3 = try XCTUnwrap(player.tracks.audio.first { $0.codecName == "eac3" })

        // Opened on the AAC track (the first audio stream in the file): decoded.
        XCTAssertEqual(player.stats.audioFormat, "pcm")
        XCTAssertFalse(player.stats.audioPassthrough)

        // AAC to E-AC-3: the readout has to answer for the new track at once,
        // not keep reporting the one that was just left.
        player.selectAudioTrack(index: eac3.index)
        XCTAssertEqual(player.stats.audioFormat, "eac3")
        XCTAssertTrue(player.stats.audioPassthrough)
        XCTAssertEqual(player.stats.audioFallbackReason, "")

        // And the reverse: E-AC-3 back to AAC.
        player.selectAudioTrack(index: aac.index)
        XCTAssertEqual(player.stats.audioFormat, "pcm")
        XCTAssertFalse(player.stats.audioPassthrough)
        player.close()
    }

    func testTheStatsSayWhatTheRouteLetsLeave() throws {
        let url = try makeDualAudioFixture(
            directory: FileManager.default.temporaryDirectory, name: "player-audio-route.mkv"
        )
        let sink = CountingSink()
        let player = LexisPlayer(sink: sink)
        player.setAudioRoute(AudioRoute(channels: 2, takesDolby: true))
        try player.open(url: url)
        XCTAssertEqual(player.stats.audioChannels, 2)
        XCTAssertFalse(player.stats.audioRouteLimited)

        let eac3 = try XCTUnwrap(player.tracks.audio.first { $0.codecName == "eac3" })
        player.selectAudioTrack(index: eac3.index)
        XCTAssertEqual(player.stats.audioFormat, "eac3")
        XCTAssertEqual(player.stats.audioChannels, 6)
        XCTAssertFalse(player.stats.audioRouteLimited)

        // decoded, the 5.1 is folded to the route's two channels
        player.setPassthroughAllowed(false)
        XCTAssertEqual(player.stats.audioFormat, "pcm")
        XCTAssertEqual(player.stats.audioChannels, 2)
        XCTAssertTrue(player.stats.audioRouteLimited)
        player.close()
    }

    func testSwitchingToAPassthroughTrackAndPlayingStillReachesTheSink() throws {
        let url = try makeDualAudioFixture(
            directory: FileManager.default.temporaryDirectory, name: "player-audio-swap-play.mkv"
        )
        let sink = CountingSink()
        let player = LexisPlayer(sink: sink)
        try player.open(url: url)
        let eac3 = try XCTUnwrap(player.tracks.audio.first { $0.codecName == "eac3" })
        player.selectAudioTrack(index: eac3.index)
        player.play()
        let deadline = Date().addingTimeInterval(5)
        while player.stats.framesDisplayed < 48, Date() < deadline { usleep(5000) }
        player.stop()
        XCTAssertEqual(player.stats.framesDisplayed, 48)
        XCTAssertEqual(player.stats.audioFormat, "eac3")
        XCTAssertTrue(player.stats.audioPassthrough)
    }

    /// A track chosen mid-film has to start where the viewer is, not where
    /// the demux thread has read to. The reader runs a whole packet queue
    /// ahead of the clock - eleven seconds of it, measured on the tvOS app -
    /// so a selection that waits for the next packet routed to it is silent
    /// for that entire window, and on a file already read to the end it is
    /// silent for good.
    func testATrackChosenMidFilmPlaysFromWhereTheViewerIs() throws {
        let url = try makeDualAudioFixture(
            directory: FileManager.default.temporaryDirectory, name: "player-audio-swap-live.mkv"
        )
        let sink = CountingSink()
        let player = LexisPlayer(sink: sink)
        try player.open(url: url)
        let eac3 = try XCTUnwrap(player.tracks.audio.first { $0.codecName == "eac3" })
        player.play()
        let playing = Date().addingTimeInterval(5)
        while player.stats.framesDisplayed < 24, Date() < playing { usleep(5000) }
        XCTAssertGreaterThan(sink.audio.count, 0)

        player.selectAudioTrack(index: eac3.index)
        let switched = Date().addingTimeInterval(5)
        while sink.audioSinceLastFlush.isEmpty, Date() < switched { usleep(5000) }
        let heard = sink.audioSinceLastFlush
        let playhead = sink.presentationTime
        player.stop()

        XCTAssertFalse(heard.isEmpty)
        // From the viewer's own moment: the window is pruned to the clock, so
        // the replay starts within one of this track's packets of it either
        // way, and nowhere near the boundary the reader had reached.
        XCTAssertEqual(try XCTUnwrap(heard.first).seconds, playhead, accuracy: 0.25)
    }

    /// A route that drops the sound it held gets it back from the clock, not
    /// from wherever the reader had read to.
    func testSoundARouteDroppedIsHandedOverAgainFromTheClock() throws {
        let url = try makeDualAudioFixture(
            directory: FileManager.default.temporaryDirectory, name: "player-audio-route-flush.mkv"
        )
        let sink = CountingSink()
        let player = LexisPlayer(sink: sink)
        try player.open(url: url)
        player.play()
        let playing = Date().addingTimeInterval(5)
        while player.stats.framesDisplayed < 24, Date() < playing { usleep(5000) }
        XCTAssertGreaterThan(sink.audio.count, 0)

        sink.dropAudioAsARouteWould()
        let replayed = Date().addingTimeInterval(5)
        while sink.audioSinceLastFlush.isEmpty, Date() < replayed { usleep(5000) }
        let heard = sink.audioSinceLastFlush
        let playhead = sink.presentationTime
        player.stop()

        XCTAssertFalse(heard.isEmpty)
        XCTAssertEqual(try XCTUnwrap(heard.first).seconds, playhead, accuracy: 0.25)
    }

    /// The end is when the last of the sound has played, not when the last
    /// picture was handed over: a film whose audio outlasts its video ends
    /// with the audio.
    func testEndOfStreamWaitsForTheSoundThatOutlastsThePicture() throws {
        try skipUnlessRealtimeTests()
        let url = try makeAudioTailFixture(
            directory: FileManager.default.temporaryDirectory, name: "player-audio-tail.mkv"
        )
        let sink = CountingSink()
        let player = LexisPlayer(sink: sink)
        let ended = expectation(description: "end of stream")
        let collector = Task {
            for await event in player.events where event == .endOfStream { ended.fulfill() }
        }
        try player.open(url: url)
        player.play()
        wait(for: [ended], timeout: 10)
        collector.cancel()
        let clock = sink.presentationTime
        let lastSound = try XCTUnwrap(sink.audio.last).seconds
        player.stop()
        XCTAssertGreaterThan(lastSound, 1.8)
        XCTAssertGreaterThanOrEqual(clock, lastSound)
    }

    func testEndOfStreamFiresOnAFilmWithNoSoundOnceThePictureHasPlayed() throws {
        try skipUnlessRealtimeTests()
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "player-video-only-end.mp4",
            codec: .h264, width: 320, height: 180, frameCount: 24, fps: 24
        )
        let sink = CountingSink()
        let player = LexisPlayer(sink: sink)
        let ended = expectation(description: "end of stream")
        let collector = Task {
            for await event in player.events where event == .endOfStream { ended.fulfill() }
        }
        try player.open(url: url)
        player.play()
        wait(for: [ended], timeout: 10)
        collector.cancel()
        let clock = sink.presentationTime
        player.stop()
        XCTAssertEqual(sink.count, 24)
        XCTAssertGreaterThanOrEqual(clock, 0.95)
    }

    /// A clock that stops on its own, with nothing paused, must not hold the
    /// end back for good.
    func testEndOfStreamFiresEvenWhenTheClockNeverMoves() throws {
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "player-held-clock-end.mp4",
            codec: .h264, width: 320, height: 180, frameCount: 24, fps: 24, audio: true
        )
        let sink = CountingSink()
        sink.holdClock()
        let player = LexisPlayer(sink: sink)
        let ended = expectation(description: "end of stream")
        let collector = Task {
            for await event in player.events where event == .endOfStream { ended.fulfill() }
        }
        try player.open(url: url)
        player.play()
        wait(for: [ended], timeout: 10)
        collector.cancel()
        player.stop()
    }

    /// The signal a bench times an open or a seek against: sub-second and
    /// fired exactly once per open and once per completed seek, unlike the
    /// once-a-second stats tick.
    func testFirstFrameFiresOnceAfterOpenAndOnceAfterEachSeek() throws {
        let sink = CountingSink()
        let player = LexisPlayer(sink: sink)
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "first-frame.mp4",
            codec: .h264, width: 320, height: 180, frameCount: 240, fps: 24
        )
        var seen: [PlayerEvent] = []
        let lock = NSLock()
        let collector = Task {
            for await event in player.events {
                lock.lock(); seen.append(event); lock.unlock()
            }
        }
        try player.open(url: url)
        player.play()
        let deadline = Date(timeIntervalSinceNow: 5)
        func firstFrameCount() -> Int {
            lock.lock(); defer { lock.unlock() }
            return seen.filter { if case .firstFrame = $0 { return true }; return false }.count
        }
        while firstFrameCount() < 1, Date() < deadline { usleep(10_000) }
        XCTAssertEqual(firstFrameCount(), 1)

        player.seek(to: 5)
        let seekDeadline = Date(timeIntervalSinceNow: 5)
        while firstFrameCount() < 2, Date() < seekDeadline { usleep(10_000) }
        XCTAssertEqual(firstFrameCount(), 2)

        collector.cancel()
        player.close()
    }
}

final class PlayerHDRTests: XCTestCase {
    /// Both displays, each named rather than inherited from whatever screen
    /// the test happens to run on. Every frame of the file arrives either
    /// way, which on the mapped path means the reorder window let the last
    /// ones go at the end of the stream.
    func testAnHDRFileReachesTheSinkOnEitherDisplay() throws {
        let url = try makeHDRFixture(
            directory: FileManager.default.temporaryDirectory, name: "player-pq.mp4",
            width: 320, height: 180, frameCount: 20, transfer: .pq
        )
        for headroom in [Float(1), 8] {
            let sink = CountingSink()
            let player = LexisPlayer(sink: sink, display: { DisplayCapability(headroom: headroom) })
            let ended = expectation(description: "end of stream on headroom \(headroom)")
            let collector = Task {
                for await event in player.events where event == .endOfStream { ended.fulfill() }
            }
            try player.open(url: url)
            XCTAssertEqual(player.dynamicRange, .hdr10)
            player.play()
            wait(for: [ended], timeout: 20)
            collector.cancel()

            XCTAssertEqual(sink.samples.count, 20)
            if headroom > 1 {
                // packets, in decode order: the display layer reorders them
                XCTAssertEqual(sink.pictures, 0)
            } else {
                // pictures the kernel mapped, put back in presentation order here
                XCTAssertEqual(sink.pictures, 20)
                XCTAssertEqual(sink.samples, sink.samples.sorted { $0.seconds < $1.seconds })
            }
            player.close()
        }
    }

    /// A stop leaves the reorder window holding the position it stopped at, and
    /// every frame decoded after a backward seek is older than what is held: the
    /// window evicts each one the instant it arrives, in decode order, until
    /// playback climbs back past the stale times. The flush is what empties it.
    /// An SDR display, because only the mapped path has a reorder window.
    func testAStopAndASeekLeaveTheReorderWindowInOrder() throws {
        try skipUnlessRealtimeTests()
        let sink = CountingSink()
        // Nothing paces delivery to content time any more: without this,
        // the whole 20-frame clip could reach its own natural end of
        // stream (fulfilling `ended` early, from the first play) before
        // the loop below even catches it at 8 samples in and stops it.
        sink.setEnqueueDelay(0.02)
        let player = LexisPlayer(sink: sink, display: { DisplayCapability(headroom: 1) })
        let url = try makeHDRFixture(
            directory: FileManager.default.temporaryDirectory, name: "player-pq-seek.mp4",
            width: 320, height: 180, frameCount: 20, transfer: .pq
        )
        let ended = expectation(description: "end of stream")
        let collector = Task {
            for await event in player.events where event == .endOfStream { ended.fulfill() }
        }
        try player.open(url: url)
        player.play()
        let deadline = Date(timeIntervalSinceNow: 20)
        while sink.samples.count < 8, Date() < deadline {
            usleep(20_000)
        }
        XCTAssertGreaterThanOrEqual(sink.samples.count, 8)
        // A file opened by path survives a stop, so seek() performs it here
        // rather than on a reader: that is the path with no flush in it.
        player.stop()
        let stopped = sink.samples.count
        player.seek(to: 0)
        player.play()
        wait(for: [ended], timeout: 20)
        collector.cancel()

        let tail = Array(sink.samples.dropFirst(stopped))
        XCTAssertEqual(tail.count, 20)
        XCTAssertEqual(tail, tail.sorted { $0.seconds < $1.seconds })
        // the stale pictures come back a second time when they are evicted
        XCTAssertEqual(Set(tail.map(\.value)).count, tail.count)
        player.close()
    }

    func testADolbyVisionFileIsReportedAsOne() throws {
        let sink = CountingSink()
        let player = LexisPlayer(sink: sink)
        let url = try makeHDRFixture(
            directory: FileManager.default.temporaryDirectory, name: "player-dv.mp4",
            width: 320, height: 180, frameCount: 8, transfer: .hlg
        )
        try player.open(url: url)
        XCTAssertEqual(player.dynamicRange, .dolbyVision)
        player.close()
        XCTAssertEqual(player.dynamicRange, .sdr)
    }

    func testAnSDRFileIsStillSDR() throws {
        let sink = CountingSink()
        let player = LexisPlayer(sink: sink)
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "player-sdr.mp4",
            codec: .h264, width: 320, height: 180, frameCount: 10, fps: 30
        )
        try player.open(url: url)
        XCTAssertEqual(player.dynamicRange, .sdr)
        player.close()
    }

    func testExtendedDynamicRangeFollowsThePassthroughPath() throws {
        let sink = CountingSink()
        let onSDR = LexisPlayer(sink: sink, display: { DisplayCapability(headroom: 1) })
        let sdr = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "edr-sdr.mp4",
            codec: .h264, width: 320, height: 180, frameCount: 2, fps: 30
        )
        try onSDR.open(url: sdr)
        // SDR takes the passthrough path (DisplayCapabilityTests already
        // pins this), so it declares extended range: the operating system
        // decides what to do with a plain SDR buffer, this app does not
        // second-guess it.
        XCTAssertEqual(sink.wantsEDRCalls, [true])
        onSDR.close()

        let pq = try makeHDRFixture(
            directory: FileManager.default.temporaryDirectory, name: "edr-pq.mp4",
            width: 320, height: 180, frameCount: 2, transfer: .pq
        )
        // On an SDR display a PQ stream is mapped, not passed through, and
        // the sink is told not to ask for extended range.
        try onSDR.open(url: pq)
        XCTAssertEqual(sink.wantsEDRCalls, [true, false])
        onSDR.close()

        // The same file on a display with headroom goes to the display layer
        // as it stands, and does declare extended range.
        let hdrSink = CountingSink()
        let onHDR = LexisPlayer(sink: hdrSink, display: { DisplayCapability(headroom: 8) })
        try onHDR.open(url: pq)
        XCTAssertEqual(hdrSink.wantsEDRCalls, [true])
        onHDR.close()
    }

    /// `videoPassthrough` is a structural fact about the path the player
    /// chose at open, set once and read back unchanged - not a measurement
    /// that resolves over time, the same way `audioPassthrough` is not.
    func testVideoPassthroughReflectsWhichPathTheFileTook() throws {
        let sink = CountingSink()
        let onSDR = LexisPlayer(sink: sink, display: { DisplayCapability(headroom: 1) })
        XCTAssertFalse(onSDR.stats.videoPassthrough)

        let sdr = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "video-passthrough-sdr.mp4",
            codec: .h264, width: 320, height: 180, frameCount: 2, fps: 30
        )
        try onSDR.open(url: sdr)
        XCTAssertTrue(onSDR.stats.videoPassthrough)
        onSDR.close()
        XCTAssertFalse(onSDR.stats.videoPassthrough)

        let pq = try makeHDRFixture(
            directory: FileManager.default.temporaryDirectory, name: "video-passthrough-pq.mp4",
            width: 320, height: 180, frameCount: 2, transfer: .pq
        )
        // Mapped on an SDR display, passed through on one with headroom: the
        // same file, and the flag follows the path rather than the file.
        try onSDR.open(url: pq)
        XCTAssertFalse(onSDR.stats.videoPassthrough)
        onSDR.close()

        let onHDR = LexisPlayer(sink: CountingSink(), display: { DisplayCapability(headroom: 8) })
        try onHDR.open(url: pq)
        XCTAssertTrue(onHDR.stats.videoPassthrough)
        onHDR.close()
    }

    /// The passthrough path hands a compressed sample straight to the sink;
    /// the display layer decodes it, and its session cannot be read back.
    /// Nothing here builds a second one to answer for it during ordinary
    /// playback - that costs the real playback the very frames the bench
    /// would then report as dropped, which is what `PassthroughDecodeProbe`
    /// exists to avoid: it runs on the bench's own turn, not this one.
    func testAPassthroughFileReportsNoDecodeTimingDuringOrdinaryPlayback() throws {
        let sink = CountingSink()
        // An SDR file on an SDR display: the case with the least excuse to
        // touch the picture, and it still goes to the sink untouched.
        let player = LexisPlayer(sink: sink, display: { DisplayCapability(headroom: 1) })
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "passthrough-no-probe.mp4",
            codec: .h264, width: 320, height: 180, frameCount: 10, fps: 30
        )
        try player.open(url: url)
        player.play()
        let deadline = Date(timeIntervalSinceNow: 5)
        while sink.samples.count < 10, Date() < deadline { usleep(10_000) }
        XCTAssertEqual(sink.samples.count, 10)
        // packets, not pictures: the passthrough path is untouched
        XCTAssertEqual(sink.pictures, 0)
        let stats = player.stats
        XCTAssertEqual(stats.decodeSampleCount, 0)
        XCTAssertEqual(stats.decodeMillisecondsMean, 0)
        XCTAssertFalse(stats.hardwareAccelerated)
        XCTAssertFalse(stats.hardwareAccelerationKnown)
        player.close()
    }

    /// The tone-mapped session is built synchronously inside `open()`, before
    /// a single frame has gone through it: hardware-vs-software is fixed for
    /// the life of that session and could be read the instant it exists, but
    /// doing so would report it as a fact about a file nothing has decoded
    /// yet. `hardwareAccelerationKnown` must wait for an actual frame back.
    func testHardwareAccelerationKnownWaitsForADecodedFrameNotJustASession() throws {
        let sink = CountingSink()
        // An SDR display, so this PQ stream is mapped rather than passed
        // through and there is a session to ask about at all.
        let player = LexisPlayer(sink: sink, display: { DisplayCapability(headroom: 1) })
        let url = try makeHDRFixture(
            directory: FileManager.default.temporaryDirectory, name: "player-pq-hw-known.mp4",
            width: 320, height: 180, frameCount: 10, transfer: .pq
        )
        try player.open(url: url)
        // its session already exists at this point - before play()
        XCTAssertFalse(player.stats.hardwareAccelerationKnown)
        player.play()
        let deadline = Date(timeIntervalSinceNow: 5)
        while player.stats.decodeSampleCount == 0, Date() < deadline { usleep(10_000) }
        let stats = player.stats
        XCTAssertTrue(stats.hardwareAccelerationKnown)
        XCTAssertEqual(stats.hardwareAccelerated, VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC))
        XCTAssertGreaterThan(stats.decodeSampleCount, 0)
        XCTAssertGreaterThan(stats.decodeMillisecondsMean, 0)
        player.close()
        XCTAssertFalse(player.stats.hardwareAccelerationKnown)
    }

    /// A stall well clear of any seek: the reported position must only ever
    /// climb, never regress, while the reanchor that fixes the reader's own
    /// pacing does its work. Before this, a stall's reanchor called the same
    /// sink.start() a seek uses, forcing the display back to the packet that
    /// ended the stall - behind where the sink's own synchronizer, which the
    /// stall never touched, had already ticked to in real time. A viewer
    /// watching the timecode saw it jump backward with no seek pressed, and
    /// a seek measured shortly after landed short for the same reason: this
    /// regression, not the seek itself, ate the difference.
    func testAStallNeverWalksTheReportedPositionBackward() throws {
        try skipUnlessRealtimeTests()
        // Sized and positioned, like the other big-fixture stall tests, past
        // what the read-ahead window could have pre-fetched by the time real
        // playback reaches it.
        let stream = stallingStream(
            bytes: bigStallFixtureBytes, contentSeconds: bigStallFixtureSeconds,
            stalls: [(atByte: stallPastTheWindow, seconds: stallOutlastingTheLead)]
        )
        XCTAssertTrue(bigStallFixtureIsPastTheWindow)
        let sink = CountingSink()
        let player = LexisPlayer(sink: sink, policy: testBufferPolicy)
        try player.open(stream: stream)
        player.play()

        var highWaterMark = 0.0
        let deadline = Date(timeIntervalSinceNow: 15)
        while player.stats.packetsRead < bigStallFixtureMostPackets, Date() < deadline {
            let position = player.stats.position
            XCTAssertGreaterThanOrEqual(
                position, highWaterMark,
                "position regressed from \(highWaterMark) to \(position) across the stall")
            highWaterMark = max(highWaterMark, position)
            usleep(20_000)
        }
        player.stop()
    }
}

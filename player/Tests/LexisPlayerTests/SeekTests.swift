import AVFoundation
import CLexisStream
import CoreMedia
import LexisCoreStream
import LexisTestSupport
import XCTest
@testable import LexisPlayer

final class SeekTests: XCTestCase {
    /// Long enough that paced delivery cannot drain the film before a seek
    /// runs, and that the target below sits a real way inside it. A quarter
    /// of the length it used to be: nothing here decodes more than a handful
    /// of frames, so the rest of the film costs only the open and the
    /// keyframe table, and neither says anything a shorter one does not.
    private static let longFrames = 600
    /// Landing between two of the fixture's keyframes, which fall on every
    /// whole second (`gopSize: 24` at 24 fps), so the frame a seek lands on
    /// has a known time either side of it.
    private static let betweenKeyframes = 16.5
    /// And landing exactly on one.
    private static let onKeyframe = 16.0
    func testSeekLandsOnTheKeyframeAtOrBeforeTheTarget() throws {
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "seek-file.mp4",
            codec: .h264, width: 320, height: 240, frameCount: 240, fps: 24
        )
        let demuxer = try Demuxer(url: url)
        let stream = try XCTUnwrap(demuxer.streams.first { $0.kind == .video })
        let timeBase = Double(stream.timeBaseNum) / Double(stream.timeBaseDen)
        XCTAssertEqual(demuxer.duration, 10.0, accuracy: 0.2)

        func firstVideoPacket() throws -> Packet {
            while let packet = try demuxer.readPacket() {
                if packet.streamIndex == stream.index { return packet }
            }
            throw DemuxError.readFailed(code: 0, message: "no packet after the seek")
        }

        try demuxer.seek(to: 5.5)
        let landed = try firstVideoPacket()
        XCTAssertTrue(landed.isKeyframe)
        let seconds = Double(try XCTUnwrap(landed.pts)) * timeBase
        XCTAssertLessThanOrEqual(seconds, 5.5)
        // the fixture carries a keyframe every 1.25 s, so a seek never lands
        // more than that before the target
        XCTAssertGreaterThan(seconds, 4.0)

        // and back to the head
        try demuxer.seek(to: 0)
        let rewound = try firstVideoPacket()
        XCTAssertTrue(rewound.isKeyframe)
        XCTAssertEqual(Double(try XCTUnwrap(rewound.pts)) * timeBase, 0, accuracy: 0.01)
    }

    func testATargetNoInt64CanHoldIsAnErrorAndNotACrash() throws {
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "seek-target.mp4",
            codec: .h264, width: 320, height: 240, frameCount: 240, fps: 24
        )
        let demuxer = try Demuxer(url: url)
        // a scrubber dividing by a duration of 0 reaches every one of these
        for target in [Double.nan, .infinity, -.infinity, 1e300] {
            XCTAssertThrowsError(try demuxer.seek(to: target), "\(target)") { error in
                guard case .seekFailed(let code, let message)? = error as? DemuxError else {
                    return XCTFail("wrong error \(error) for \(target)")
                }
                XCTAssertEqual(code, 0)
                XCTAssertFalse(message.isEmpty)
            }
        }
        // and a refused target leaves the demuxer where it was
        try demuxer.seek(to: 5.5)
        XCTAssertNotNil(try demuxer.readPacket())
    }

    func testSeekingOverAStreamReadsTheSameFramesAsOverAPath() throws {
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "seek-stream.mp4",
            codec: .h264, width: 320, height: 240, frameCount: 240, fps: 24
        )
        let handle = try XCTUnwrap(lexis_stream_open_file(url.path, nil))
        let overStream = try Demuxer(stream: coreStream(handle: handle))
        let overPath = try Demuxer(url: url)
        try overStream.seek(to: 5.5)
        try overPath.seek(to: 5.5)
        for _ in 0..<10 {
            let a = try XCTUnwrap(try overStream.readPacket())
            let b = try XCTUnwrap(try overPath.readPacket())
            XCTAssertEqual(a.pts, b.pts)
            XCTAssertEqual(a.isKeyframe, b.isKeyframe)
            XCTAssertEqual(a.copiedBytes, b.copiedBytes)
        }
    }

    func testABrokenStreamSeekSurfacesOnTheNextRead() throws {
        // The target has to land outside everything under the demuxer that
        // could answer the seek without ever asking the stream: the 256 KiB
        // AVIO buffer, and the read-ahead window behind it. A seek into
        // bytes the window already holds is served from memory and answers
        // correctly however broken the stream underneath is, so a fixture
        // that fits inside the window cannot put this question at all.
        let data = bigStallFixtureBytes
        XCTAssertGreaterThan(data.count, AVIOStream.bufferSize)
        XCTAssertGreaterThan(data.count, testBufferPolicy.readAheadBytes)
        let past = bigStallFixtureSeconds * 2 / 3

        BrokenSeekStream.load(data)
        let demuxer = try Demuxer(
            stream: BrokenSeekStream.io(),
            byteCacheWindow: testBufferPolicy.readAheadBytes)
        XCTAssertNotNil(try demuxer.readPacket())

        // mp4 does not seek when asked: it moves its own sample index and
        // seeks the stream when the next packet is read, which is where a
        // broken stream shows up.
        BrokenSeekStream.failSeeks = true
        try demuxer.seek(to: past)
        XCTAssertThrowsError(try demuxer.readPacket()) { error in
            guard case .readFailed(let code, let message)? = error as? DemuxError else {
                return XCTFail("wrong error \(error)")
            }
            XCTAssertLessThan(code, 0)
            XCTAssertFalse(message.isEmpty)
        }

        BrokenSeekStream.failSeeks = false
        try demuxer.seek(to: past)
        XCTAssertNotNil(try demuxer.readPacket())
    }

    func testSeekingMovesTheFeedAndTheClock() throws {
        try skipUnlessRealtimeTests()
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "seek-player.mp4",
            codec: .h264, width: 320, height: 240, frameCount: 240, fps: 24, audio: true
        )
        let sink = CountingSink()
        // Nothing paces delivery to content time any more: without this,
        // the whole 10 s clip could already be fully delivered by the time
        // the loop below even checks `sink.count`, well before the seek.
        sink.setEnqueueDelay(0.01)
        let player = LexisPlayer(sink: sink)
        try player.open(url: url)
        player.play()

        let deadline = Date(timeIntervalSinceNow: 20)
        while sink.count < 5, Date() < deadline {
            usleep(20_000)
        }
        XCTAssertLessThan(try XCTUnwrap(sink.samples.last).seconds, 2.0)
        XCTAssertEqual(player.stats.duration, 10.0, accuracy: 0.2)

        // open() flushes on its way in, so only what the seek adds counts
        let flushesBeforeSeek = sink.flushes
        player.seek(to: 7)
        while (sink.samples.last?.seconds ?? 0) < 6, Date() < deadline {
            usleep(20_000)
        }

        // both renderers were dropped, the picture was kept, and the feed
        // picked up at the keyframe at or before the target
        XCTAssertEqual(Array(sink.keptImages.dropFirst(flushesBeforeSeek)), [true])
        let afterSeek = try XCTUnwrap(sink.startedAt)
        XCTAssertLessThanOrEqual(afterSeek, 7.0)
        XCTAssertGreaterThan(afterSeek, 5.5)
        // nothing the renderers hold once the seek has flushed them belongs to
        // the position that was left. Gated on its own condition, not on
        // video's: AAC decode needs a packet or two past the flush before it
        // produces a frame, so video catching up to the seek target proves
        // nothing about whether audio has landed anything yet.
        let audioDeadline = Date(timeIntervalSinceNow: 20)
        while sink.audioSinceLastFlush.isEmpty, Date() < audioDeadline {
            usleep(20_000)
        }
        let audio = sink.audioSinceLastFlush
        XCTAssertFalse(audio.isEmpty)
        for stamp in audio {
            XCTAssertGreaterThan(stamp.seconds, 5.5)
        }
        player.stop()
    }

    func testASeekWhilePausedIsAppliedBeforeTheResume() throws {
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "seek-paused.mp4",
            codec: .h264, width: 320, height: 240, frameCount: 240, fps: 24
        )
        let sink = CountingSink()
        let player = LexisPlayer(sink: sink)
        try player.open(url: url)
        player.play()

        let deadline = Date(timeIntervalSinceNow: 20)
        while sink.count < 5, Date() < deadline {
            usleep(20_000)
        }
        player.pause()
        usleep(100_000)
        let flushesBeforeSeek = sink.flushes
        let framesBeforeSeek = sink.count

        player.seek(to: 7)
        let applied = Date(timeIntervalSinceNow: 5)
        while sink.flushes == flushesBeforeSeek, Date() < applied {
            usleep(20_000)
        }
        // the reader takes the seek without waiting for the resume, and the
        // picture of the old position stays up meanwhile: the flush keeps the
        // image, and whatever crosses the sink from here belongs to the seek
        // itself - its landed keyframe - never to the position that was left.
        // (Showing that landed frame while paused is the realtime lane's own
        // testASeekDisplaysTheLandedFrameWhilePaused.)
        XCTAssertEqual(Array(sink.keptImages.dropFirst(flushesBeforeSeek)), [true])
        for sample in sink.samples.dropFirst(framesBeforeSeek) {
            XCTAssertGreaterThanOrEqual(sample.seconds, 6.0)
        }
        // and it reports where it landed: the target at once, corrected to
        // the landed keyframe's own time when that frame crosses the sink.
        XCTAssertGreaterThanOrEqual(player.stats.position, 6.0)
        XCTAssertLessThanOrEqual(player.stats.position, 7.01)
        player.seek(to: 8)
        let moved = Date(timeIntervalSinceNow: 5)
        while player.stats.position < 7.0, Date() < moved {
            usleep(20_000)
        }
        XCTAssertGreaterThanOrEqual(player.stats.position, 7.0)
        XCTAssertLessThanOrEqual(player.stats.position, 8.01)

        player.play()
        // resume starts the clock where the seek left it, not where the pause
        // did: the cold start's own start(0) is overwritten by the recovery
        while (sink.startedAt ?? 0) <= 5.5, Date() < deadline {
            usleep(20_000)
        }
        player.stop()
        XCTAssertGreaterThan(try XCTUnwrap(sink.startedAt), 5.5)
    }

    func testASeekTheStreamNeverGotDoesNotFollowThePlayerIntoTheNext() throws {
        let long = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "seek-stale-long.mp4",
            codec: .h264, width: 320, height: 240, frameCount: 240, fps: 24
        )
        let short = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "seek-stale-short.mp4",
            codec: .h264, width: 320, height: 240, frameCount: 48, fps: 24
        )
        let sink = CountingSink()
        let player = LexisPlayer(sink: sink)
        try player.open(url: long)
        player.play()

        let deadline = Date(timeIntervalSinceNow: 20)
        while sink.count < 5, Date() < deadline {
            usleep(20_000)
        }
        // the back-out gesture: scrub, then leave the player for another video
        player.pause()
        player.seek(to: 7)
        player.close()

        try player.open(url: short)
        let framesBefore = sink.count
        player.play()
        while sink.count <= framesBefore, Date() < deadline {
            usleep(20_000)
        }
        player.stop()
        // 7 s is past the end of the second file, and its own duration never
        // clamped that target: it plays from its head
        XCTAssertEqual(try XCTUnwrap(sink.startedAt), 0, accuracy: 0.05)
    }

    func testSeekingAfterTheEndPlaysAgain() throws {
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "seek-ended.mp4",
            codec: .h264, width: 320, height: 240, frameCount: 48, fps: 24
        )
        let sink = CountingSink()
        let player = LexisPlayer(sink: sink)
        let log = EventLog()
        let events = Task { [events = player.events] in
            for await event in events { log.append(event) }
        }
        defer { events.cancel() }
        try player.open(url: url)
        player.play()

        let deadline = Date(timeIntervalSinceNow: 20)
        while !log.all.contains(.endOfStream), Date() < deadline {
            usleep(20_000)
        }
        XCTAssertTrue(log.all.contains(.endOfStream))
        let atEnd = sink.count

        // the stream ended by itself, so it is still readable: a seek is the
        // way back into it
        player.seek(to: 0)
        player.play()
        while sink.count <= atEnd, Date() < deadline {
            usleep(20_000)
        }
        player.stop()
        XCTAssertGreaterThan(sink.count, atEnd)
    }

    /// The frame a viewer lands on: with the engine paused, a seek must
    /// still show them exactly where they landed, once, immediately - not
    /// zero frames (a still of the old position) and not a burst of frames
    /// racing ahead of the refill that is only supposed to start once this
    /// one is up.
    func testASeekDisplaysTheLandedFrameWhilePaused() throws {
        try skipUnlessRealtimeTests()
        // Long enough that paced delivery (below) cannot drain the whole
        // file, pause or not, before the seek itself ever runs: the demux
        // thread that would service it parks and exits at a real end of
        // stream once nothing is left for it to seek, which a short fixture
        // can reach first.
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "seek-landed.mp4",
            codec: .h264, width: 320, height: 240, frameCount: SeekTests.longFrames, fps: 24, gopSize: 24
        )
        let demuxer = try Demuxer(url: url)
        let videoStream = try XCTUnwrap(demuxer.streams.first { $0.kind == .video })
        let sink = CountingSink()
        // Nothing paces delivery to content time any more: without this, the
        // clip could drain far ahead of the loop below before it even checks
        // `sink.count`.
        sink.setEnqueueDelay(0.01)
        let engine = PlayerEngine(
            demuxer: demuxer, tracks: .init(video: videoStream, audio: nil, subtitle: nil),
            sink: sink, toneMapped: nil, interrupt: InterruptFlag()
        )
        engine.start(paused: false)
        defer { engine.stop(join: true) }

        let deadline = Date(timeIntervalSinceNow: 20)
        while sink.count < 5, Date() < deadline { usleep(20_000) }
        engine.setPaused(true)
        // Paced delivery keeps handing out whatever the pre-seek queue still
        // holds the whole time, pause or not - only the seek's own flush
        // empties it, so that flush (not a frame count or a fixed sleep) is
        // the one boundary a baseline can actually be read against.
        let flushesBeforeSeek = sink.flushes

        let landedPTS = SeekLandedBox()
        engine.seek(to: SeekTests.betweenKeyframes) { landedPTS.set($0) }
        let flushDeadline = Date(timeIntervalSinceNow: 20)
        while sink.flushes == flushesBeforeSeek, Date() < flushDeadline { usleep(20_000) }
        guard sink.flushes > flushesBeforeSeek else {
            return XCTFail("the seek never flushed the sink")
        }
        // At most one pre-seek frame can still have been in flight (already
        // popped, mid-`enqueue`'s own delay) the instant the flush ran and
        // is immune to it; nothing else the old position was still holding
        // survives it.
        let framesAtFlush = sink.count

        let completionDeadline = Date(timeIntervalSinceNow: 20)
        while landedPTS.value == nil, Date() < completionDeadline { usleep(20_000) }
        guard let pts = landedPTS.value else {
            return XCTFail("the seek's own completion never reported a landed frame")
        }
        XCTAssertLessThanOrEqual(pts, SeekTests.betweenKeyframes)
        // the fixture forces a keyframe every second (gopSize: 24 at 24 fps)
        XCTAssertGreaterThan(pts, SeekTests.betweenKeyframes - 1)
        // the sink's own clock reads the landed frame's PTS, not the raw
        // raw target applySeek's own optimistic anchor set first: this is
        // what makes the frame actually SHOWN, not merely decoded and
        // handed off with nothing pointing the paused clock at it
        XCTAssertEqual(sink.presentationTime, pts, accuracy: 0.001)

        // A chance for the landed frame to cross, not a proof that it did:
        // what this asserts is that AT MOST one does, and the hold below is
        // what watches for a second. Paused, it usually does not cross at
        // all, and every second spent here is spent finding that out again.
        let landDeadline = Date(timeIntervalSinceNow: 0.5)
        while sink.count <= framesAtFlush, Date() < landDeadline { usleep(20_000) }
        let landed = sink.count
        XCTAssertLessThanOrEqual(landed, framesAtFlush + 1)

        // Held for a real span, not just the instant it first showed: the
        // fixture's keyframe is a full second before the target, which is
        // more than enough time for a leak past the gate to show up here.
        for _ in 0..<5 {
            usleep(20_000)
            XCTAssertEqual(sink.count, landed, "more than the landed frame crossed while paused")
        }
    }

    /// Rate only returns to 1 once the buffer the seek's own flush emptied
    /// has refilled to the high watermark: the landed frame must not just
    /// sit there forever, but playback past it must wait for a real refill,
    /// not resume off the first frame decode happens to produce.
    func testSeekRefillsBeforeRateOne() throws {
        try skipUnlessRealtimeTests()
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "seek-refill.mp4",
            codec: .h264, width: 320, height: 240, frameCount: SeekTests.longFrames, fps: 24, gopSize: 24
        )
        let demuxer = try Demuxer(url: url)
        let videoStream = try XCTUnwrap(demuxer.streams.first { $0.kind == .video })
        let sink = CountingSink()
        sink.setEnqueueDelay(0.01)
        let engine = PlayerEngine(
            demuxer: demuxer, tracks: .init(video: videoStream, audio: nil, subtitle: nil),
            sink: sink, toneMapped: nil, interrupt: InterruptFlag()
        )
        engine.start(paused: false)
        defer { engine.stop(join: true) }

        let deadline = Date(timeIntervalSinceNow: 20)
        while sink.count < 5, Date() < deadline { usleep(20_000) }
        // Paced delivery keeps handing out whatever the pre-seek queue still
        // holds; only the seek's own flush empties it - see the identical
        // reasoning in `testASeekDisplaysTheLandedFrameWhilePaused`.
        let flushesBeforeSeek = sink.flushes

        let landedPTS = SeekLandedBox()
        engine.seek(to: SeekTests.onKeyframe) { landedPTS.set($0) }
        let flushDeadline = Date(timeIntervalSinceNow: 20)
        while sink.flushes == flushesBeforeSeek, Date() < flushDeadline { usleep(20_000) }
        guard sink.flushes > flushesBeforeSeek else {
            return XCTFail("the seek never flushed the sink")
        }
        let framesAtFlush = sink.count

        let completionDeadline = Date(timeIntervalSinceNow: 20)
        while landedPTS.value == nil, Date() < completionDeadline { usleep(20_000) }
        guard let pts = landedPTS.value else {
            return XCTFail("the seek's own completion never reported a landed frame")
        }
        XCTAssertLessThanOrEqual(pts, SeekTests.onKeyframe)
        XCTAssertGreaterThan(pts, SeekTests.onKeyframe - 1)

        // Unlike the paused case above, nothing here holds the count at
        // exactly one once landed: a local fixture's own packet queue can
        // clear the high watermark as fast as it can read raw bytes off
        // disk, well under this suite's own polling grain, so a refill and
        // everything it lets flow can already be well past the landed frame
        // by the next time this reads `count`. The gate itself is what
        // `testASeekDisplaysTheLandedFrameWhilePaused` proves directly
        // (nothing paused ever leaks a second frame); what this proves
        // instead is that playback DOES resume, and through `start`,
        // anchored again at the landed frame's own pts, never through the
        // raw seek target a premature resume would have carried.
        let resumeDeadline = Date(timeIntervalSinceNow: 20)
        while sink.count <= framesAtFlush, Date() < resumeDeadline { usleep(20_000) }
        XCTAssertGreaterThan(sink.count, framesAtFlush, "never resumed once the buffer refilled")
        let resumedAt = try XCTUnwrap(sink.startedAt)
        XCTAssertLessThanOrEqual(resumedAt, SeekTests.onKeyframe)
        XCTAssertGreaterThan(resumedAt, SeekTests.onKeyframe - 1)
    }

    /// `stats.position` reads `sink.presentationTime` alone - never a
    /// hand-maintained number the engine keeps beside it - so once the
    /// landed frame actually decodes it reports THAT frame's own PTS, not
    /// the raw target a caller asked for. A second seek computed from that
    /// reading, the way `PlayerScreen.tsx`'s own right-press math does
    /// (`positionRef.current + SEEK_STEP`), lands 10 s past wherever the
    /// first one actually put it, not past the value first asked for -
    /// expected, though not promised, to close the 10s-press-moves-8s gap
    /// a hand-maintained position used to leave (the design spec's own
    /// principle 5: "Seek is flush and refill... Position reported to the
    /// UI comes from the synchronizer, not from a hand-maintained number").
    func testPositionAfterSeekIsTheSynchronizersOwn() throws {
        try skipUnlessRealtimeTests()
        // GOP-1s: a keyframe every second (gopSize: 24 at 24 fps), 30 s long
        // so both seeks below land well inside it.
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "seek-position.mp4",
            codec: .h264, width: 320, height: 240, frameCount: 720, fps: 24, gopSize: 24
        )
        let sink = CountingSink()
        sink.setEnqueueDelay(0.01)
        let player = LexisPlayer(sink: sink)
        try player.open(url: url)
        player.play()

        let deadline = Date(timeIntervalSinceNow: 20)
        while sink.count < 5, Date() < deadline { usleep(20_000) }

        // Paused right behind the seek, before the landed frame can
        // possibly have decoded yet: `testASeekDisplaysTheLandedFrameWhile
        // Paused` already proves the engine holds there once paused, which
        // is what makes a single settle-then-read safe here instead of a
        // race against ongoing playback.
        player.seek(to: 10.0)
        player.pause()
        usleep(300_000)
        let position1 = player.stats.position
        XCTAssertLessThanOrEqual(position1, 10.0)
        XCTAssertGreaterThan(position1, 9.0)
        // held, not still drifting off whatever the landed frame's own
        // decode happened to still be catching up to when the read above ran
        usleep(100_000)
        XCTAssertEqual(player.stats.position, position1, accuracy: 0.001)

        let target2 = position1 + 10
        player.seek(to: target2)
        usleep(300_000)
        let position2 = player.stats.position
        // at or before the target, never after - the same discipline the
        // UI suite's own `testScanAndPlay` checks at the screen
        XCTAssertLessThanOrEqual(position2, target2)
        XCTAssertGreaterThan(position2, target2 - 1.0)
        player.stop()
    }

    /// Measured at the frame, not guessed: 0 before any seek has ever
    /// landed one, then the real span from the `seek(to:)` call to that
    /// landed frame actually crossing the sink, every time - never frozen
    /// at whatever the first seek happened to take.
    func testSeekLatencyIsMeasuredAtTheLandedFrame() throws {
        try skipUnlessRealtimeTests()
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "seek-latency.mp4",
            codec: .h264, width: 320, height: 240, frameCount: 720, fps: 24, gopSize: 24
        )
        let sink = CountingSink()
        sink.setEnqueueDelay(0.01)
        let player = LexisPlayer(sink: sink)
        try player.open(url: url)
        player.play()

        let deadline = Date(timeIntervalSinceNow: 20)
        while sink.count < 5, Date() < deadline { usleep(20_000) }
        XCTAssertEqual(player.stats.lastSeekLatencySeconds, 0, "unmeasured before any seek has landed")

        player.seek(to: 10.0)
        player.pause()
        let settleDeadline = Date(timeIntervalSinceNow: 20)
        while player.stats.lastSeekLatencySeconds == 0, Date() < settleDeadline { usleep(20_000) }
        let firstLatency = player.stats.lastSeekLatencySeconds
        XCTAssertGreaterThan(firstLatency, 0)
        // a seek over an already-open local file settles well under a
        // second; this is a sanity bound against a runaway value, not a
        // performance assertion
        XCTAssertLessThan(firstLatency, 5.0)

        // measured again, not just held at the first reading: the wait
        // below is generous enough that the second seek's own landing has
        // certainly happened by the time it reads back, whatever the exact
        // moment its own measurement lands.
        player.seek(to: 20.0)
        usleep(500_000)
        let secondLatency = player.stats.lastSeekLatencySeconds
        XCTAssertGreaterThan(secondLatency, 0)
        XCTAssertLessThan(secondLatency, 5.0)
        player.stop()
    }

    /// The regression this guards: `requestMediaDataWhenReady`'s block only
    /// fires again on a not-ready-to-ready TRANSITION, never merely because
    /// a provider that answered nil would now answer differently. A seek's
    /// flush empties the sample queue while the renderer is already ready,
    /// so the provider goes dry with no transition left to notice decode
    /// catching up - the freeze this reproduces needs the real
    /// `DisplayLayerSink`, since `CountingSink`'s polling timer would ask
    /// again regardless and never see it. Nothing here paces delivery to
    /// content time, so a short fixture races through in well under a
    /// second once it is flowing again - `.endOfStream` firing again after
    /// the seek is what tells a real resume apart from one lucky frame
    /// slipping through before the pump dies for good.
    func testASeekDuringPlaybackDoesNotFreezeTheRenderer() throws {
        try skipUnlessRealtimeTests()
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "seek-freeze.mp4",
            codec: .h264, width: 320, height: 240, frameCount: 120, fps: 24
        )
        let sink = DisplayLayerSink(layer: AVSampleBufferDisplayLayer())
        let player = LexisPlayer(sink: sink)
        let log = EventLog()
        let events = Task { [events = player.events] in
            for await event in events { log.append(event) }
        }
        defer { events.cancel() }
        try player.open(url: url)
        player.play()

        let deadline = Date(timeIntervalSinceNow: 20)
        while player.stats.framesDisplayed < 5, Date() < deadline {
            usleep(20_000)
        }
        XCTAssertGreaterThanOrEqual(
            player.stats.framesDisplayed, 5, "playback must be under way before the seek"
        )

        // mid-playback, well before the end of a five second clip - the
        // freeze this guards is a seek landing while the film is still
        // going, not one at end of stream. What follows the seek plays at
        // the renderer's own rate, so the film's length is what it costs.
        let endOfStreamCountBeforeSeek = log.all.filter { $0 == .endOfStream }.count
        player.seek(to: 3)
        let framesAtSeek = player.stats.framesDisplayed

        while log.all.filter({ $0 == .endOfStream }).count <= endOfStreamCountBeforeSeek,
            Date() < deadline
        {
            usleep(20_000)
        }
        XCTAssertGreaterThan(
            log.all.filter { $0 == .endOfStream }.count, endOfStreamCountBeforeSeek,
            "playback must run all the way to a fresh end of stream after the seek, not freeze"
        )
        // a count of samples delivered after the seek, strictly greater than
        // zero: reaching a fresh end of stream could not have happened
        // otherwise
        XCTAssertGreaterThan(player.stats.framesDisplayed, framesAtSeek)

        player.stop()
    }

    /// The same shape as `AudioDecoder`'s own cross-thread race:
    /// `applySeek` calls `softwareDecoder.flush()` straight from the demux
    /// thread while the video decode thread can be inside `decode()` or its
    /// own `drainAtEndOfStream()` teardown, both against the same
    /// `AVCodecContext` - now serialised by `SoftwareVideoDecoder`'s own
    /// lock either way. A collision there corrupts FFmpeg's decoder state
    /// and it goes silent for the rest of the file; repeated seeks against a
    /// live decode thread are what give it the chances to land.
    ///
    /// The fixture has to stay well past every seek target plus the packet
    /// queue's own 8 s high watermark: land any target close enough to the
    /// real end that a single unthrottled read-ahead can reach it, and
    /// `PlayerEngine` retires for good on its own - by design, the same way
    /// `testSeekingAfterTheEndPlaysAgain` relies on - which a bare
    /// `PlayerEngine.seek()` with no `LexisPlayer` above it to revive was
    /// never going to survive, and has nothing to do with the decoder race
    /// this test exists to catch. `testASeekDisplaysTheLandedFrameWhilePaused`
    /// sizes its own fixture the same way for the same reason.
    func testRepeatedSeeksOnSoftwareDecodedVideoKeepFramesArriving() throws {
        try skipUnlessRealtimeTests()
        let url: URL
        do {
            url = try makeVP9Fixture(
                directory: FileManager.default.temporaryDirectory, name: "seek-vp9.mkv",
                width: 320, height: 240, frameCount: SeekTests.longFrames, fps: 24, gopSize: 24
            )
        } catch VP9FixtureError.ffmpegUnavailable {
            throw XCTSkip("no ffmpeg on PATH to encode a real VP9 fixture")
        }
        let demuxer = try Demuxer(url: url)
        let videoStream = try XCTUnwrap(demuxer.streams.first { $0.kind == .video })
        XCTAssertEqual(videoStream.codecName, "vp9")
        let sink = CountingSink()
        sink.setEnqueueDelay(0.005)
        let engine = PlayerEngine(
            demuxer: demuxer, tracks: .init(video: videoStream, audio: nil, subtitle: nil),
            sink: sink, toneMapped: nil, interrupt: InterruptFlag()
        )
        engine.start(paused: false)
        defer { engine.stop(join: true) }

        let startDeadline = Date(timeIntervalSinceNow: 20)
        while sink.count < 3, Date() < startDeadline { usleep(10_000) }
        XCTAssertGreaterThanOrEqual(sink.count, 3, "playback must be under way before seeking")

        let targets: [Double] = [4.0, 1.0, 7.0, 2.0, 8.0, 0.5, 6.0, 3.0, 9.0, 1.5]
        for target in targets {
            let countBeforeSeek = sink.count
            let landed = SeekLandedBox()
            engine.seek(to: target) { landed.set($0) }
            let landDeadline = Date(timeIntervalSinceNow: 10)
            while landed.value == nil, Date() < landDeadline { usleep(10_000) }
            XCTAssertNotNil(landed.value, "the seek to \(target) never landed a frame")

            let arrivalDeadline = Date(timeIntervalSinceNow: 10)
            while sink.count <= countBeforeSeek, Date() < arrivalDeadline { usleep(10_000) }
            XCTAssertGreaterThan(
                sink.count, countBeforeSeek,
                "no frame arrived after seeking to \(target) - the software decoder may have gone silent"
            )
        }
    }

    /// The two paths above at once: a codec with no hardware decoder, its
    /// pictures decoded in software and handed to a mapped path with no
    /// session of its own. Frames arrive, and keep arriving across seeks.
    func testRepeatedSeeksOnSoftwarePicturesThroughTheMappedPathKeepFramesArriving() throws {
        try skipUnlessRealtimeTests()
        let url: URL
        do {
            url = try makeVP9Fixture(
                directory: FileManager.default.temporaryDirectory, name: "seek-vp9-mapped.mkv",
                width: 320, height: 240, frameCount: SeekTests.longFrames, fps: 24, gopSize: 24
            )
        } catch VP9FixtureError.ffmpegUnavailable {
            throw XCTSkip("no ffmpeg on PATH to encode a real VP9 fixture")
        }
        let demuxer = try Demuxer(url: url)
        let videoStream = try XCTUnwrap(demuxer.streams.first { $0.kind == .video })
        XCTAssertEqual(hardwareDecodes(videoStream), false)
        let sink = CountingSink()
        sink.setEnqueueDelay(0.005)
        final class EngineBox { weak var engine: PlayerEngine? }
        let box = EngineBox()
        // VP9 has no compressed description: the decoded picture's stands in
        let toneMapped = try ToneMappedVideo(
            formatDescription: videoFormatDescription(
                for: videoStream, codecType: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, atoms: [:]),
            sourcePeakPQ: nil, videoDelay: videoStream.videoDelay, capability: DisplayCapability(headroom: 1),
            budgetBytes: 1 << 30, decodesItself: false
        ) { [weak box] sample in
            box?.engine?.pushToneMappedFrame(sample)
        }
        let engine = PlayerEngine(
            demuxer: demuxer, tracks: .init(video: videoStream, audio: nil, subtitle: nil),
            sink: sink, toneMapped: toneMapped, interrupt: InterruptFlag()
        )
        box.engine = engine
        engine.start(paused: false)
        defer { engine.stop(join: true) }

        let startDeadline = Date(timeIntervalSinceNow: 20)
        while sink.count < 3, Date() < startDeadline { usleep(10_000) }
        XCTAssertGreaterThanOrEqual(sink.count, 3, "playback must be under way before seeking")

        for target in [4.0, 1.0, 7.0, 2.0, 8.0, 0.5, 6.0, 3.0, 9.0, 1.5] {
            let countBeforeSeek = sink.count
            let landed = SeekLandedBox()
            engine.seek(to: target) { landed.set($0) }
            let landDeadline = Date(timeIntervalSinceNow: 10)
            while landed.value == nil, Date() < landDeadline { usleep(10_000) }
            XCTAssertNotNil(landed.value, "the seek to \(target) never landed a frame")
            let arrivalDeadline = Date(timeIntervalSinceNow: 10)
            while sink.count <= countBeforeSeek, Date() < arrivalDeadline { usleep(10_000) }
            XCTAssertGreaterThan(sink.count, countBeforeSeek, "no frame arrived after seeking to \(target)")
        }
    }

    /// `ToneMappedVideo.flush()` never touches the VideoToolbox session at
    /// all - only local bookkeeping (`held`, `inFlight`, `submitted`,
    /// `generation`) already serialised with `decode()`'s own writes under
    /// one lock - so there is no unsynchronised cross-thread call into
    /// shared decoder state on this path to race, unlike the software
    /// decode path above. This proves the outcome holds anyway: repeated
    /// seeks against a live tone-mapping decode thread must not stall
    /// frame delivery.
    func testRepeatedSeeksOnToneMappedVideoKeepFramesArriving() throws {
        try skipUnlessRealtimeTests()
        let url = try makeHDRFixture(
            directory: FileManager.default.temporaryDirectory, name: "seek-tone-mapped.mp4",
            width: 320, height: 180, frameCount: 240, transfer: .pq, gopSize: 24
        )
        let demuxer = try Demuxer(url: url)
        let videoStream = demuxer.streams[0]
        let format = try makeFormatDescription(for: videoStream)
        let sink = CountingSink()
        sink.setEnqueueDelay(0.005)

        final class EngineBox { weak var engine: PlayerEngine? }
        let box = EngineBox()
        let toneMapped = try ToneMappedVideo(
            formatDescription: format, sourcePeakPQ: masteringPeakPQ(videoStream.masteringDisplay),
            videoDelay: videoStream.videoDelay, capability: DisplayCapability(headroom: 1), budgetBytes: 1 << 30
        ) { [weak box] sample in
            box?.engine?.pushToneMappedFrame(sample)
        }
        let engine = PlayerEngine(
            demuxer: demuxer, tracks: .init(video: videoStream, audio: nil, subtitle: nil),
            sink: sink, toneMapped: toneMapped, interrupt: InterruptFlag()
        )
        box.engine = engine
        engine.start(paused: false)
        defer { engine.stop(join: true) }

        let startDeadline = Date(timeIntervalSinceNow: 20)
        while sink.count < 3, Date() < startDeadline { usleep(10_000) }
        XCTAssertGreaterThanOrEqual(sink.count, 3, "playback must be under way before seeking")

        let targets: [Double] = [3.0, 1.0, 5.0, 2.0, 6.0, 0.5, 4.0, 2.5, 7.0, 1.5]
        for target in targets {
            let countBeforeSeek = sink.count
            let landed = SeekLandedBox()
            engine.seek(to: target) { landed.set($0) }
            let landDeadline = Date(timeIntervalSinceNow: 10)
            while landed.value == nil, Date() < landDeadline { usleep(10_000) }
            XCTAssertNotNil(landed.value, "the seek to \(target) never landed a frame")

            let arrivalDeadline = Date(timeIntervalSinceNow: 10)
            while sink.count <= countBeforeSeek, Date() < arrivalDeadline { usleep(10_000) }
            XCTAssertGreaterThan(
                sink.count, countBeforeSeek,
                "no frame arrived after seeking to \(target) on the tone-mapped path"
            )
        }
    }
}

/// Where a seek's own completion, called from the demux thread, leaves its
/// landed PTS for the test's own thread to read back.
final class SeekLandedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var landedPTS: Double?

    func set(_ pts: Double) {
        lock.lock(); landedPTS = pts; lock.unlock()
    }

    var value: Double? {
        lock.lock(); defer { lock.unlock() }
        return landedPTS
    }
}

/// A file-backed stream whose seek can be told to fail. The callbacks are C
/// function pointers and cannot capture, so its state is static, and every
/// mention inside a callback carries the type name: an unqualified one is a
/// capture of `Self` and does not compile.
enum BrokenSeekStream {
    nonisolated(unsafe) static var bytes = Data()
    nonisolated(unsafe) static var position = 0
    nonisolated(unsafe) static var failSeeks = false

    static func load(_ data: Data) {
        bytes = data
        position = 0
        failSeeks = false
    }

    static func io() -> MediaStreamIO {
        MediaStreamIO(
            handle: UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1),
            read: { _, buffer, length in
                guard let buffer, length > 0 else { return -1 }
                let count = min(Int(length), BrokenSeekStream.bytes.count - BrokenSeekStream.position)
                if count <= 0 { return 0 }
                BrokenSeekStream.bytes.withUnsafeBytes { raw in
                    _ = memcpy(
                        buffer,
                        raw.baseAddress!.advanced(by: BrokenSeekStream.position),
                        count
                    )
                }
                BrokenSeekStream.position += count
                return Int64(count)
            },
            seek: { _, offset, whence in
                if BrokenSeekStream.failSeeks { return -1 }
                let target: Int
                switch whence {
                case 0: target = Int(offset)
                case 1: target = BrokenSeekStream.position + Int(offset)
                case 2: target = BrokenSeekStream.bytes.count + Int(offset)
                default: return -1
                }
                guard target >= 0, target <= BrokenSeekStream.bytes.count else { return -1 }
                BrokenSeekStream.position = target
                return Int64(target)
            },
            size: { _ in Int64(BrokenSeekStream.bytes.count) },
            close: { handle in handle?.deallocate() }
        )
    }
}

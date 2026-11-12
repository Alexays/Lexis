import AVFoundation
import CoreMedia
import LexisTestSupport
import XCTest
@testable import LexisPlayer

final class DisplayLayerSinkTests: XCTestCase {
    func testStartsEnqueuesAndFlushesARealLayer() throws {
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "sink-hevc.mp4",
            codec: .hevc, width: 320, height: 240, frameCount: 12, fps: 24
        )
        let demuxer = try Demuxer(url: url)
        let stream = try XCTUnwrap(demuxer.streams.first { $0.kind == .video })
        let formatDescription = try makeFormatDescription(for: stream)
        var samples: [CMSampleBuffer] = []
        while let packet = try demuxer.readPacket() {
            guard packet.streamIndex == stream.index else { continue }
            samples.append(try makeSampleBuffer(
                packet: packet, formatDescription: formatDescription,
                timeBaseNum: stream.timeBaseNum, timeBaseDen: stream.timeBaseDen
            ))
        }
        XCTAssertFalse(samples.isEmpty)

        let layer = AVSampleBufferDisplayLayer()
        let sink = DisplayLayerSink(layer: layer)
        XCTAssertEqual(sink.synchronizer.rate, 0)
        // The anchor must land when we ask for it; deferring it would put the
        // sink's clock out of step with the reader's pacing.
        XCTAssertFalse(sink.synchronizer.delaysRateChangeUntilHasSufficientMediaData)

        sink.start(atPresentation: 0)
        XCTAssertEqual(sink.synchronizer.rate, 1)
        for sample in samples {
            sink.enqueue(sample)
        }
        XCTAssertNil(layer.sampleBufferRenderer.error)
        XCTAssertNotEqual(layer.sampleBufferRenderer.status, .failed)

        // Pausing stops the clock in place, and resuming picks it back up.
        let paused = sink.synchronizer.currentTime()
        sink.setRate(0)
        XCTAssertEqual(sink.synchronizer.rate, 0)
        XCTAssertGreaterThanOrEqual(sink.synchronizer.currentTime().seconds, paused.seconds)
        sink.setRate(1)
        XCTAssertEqual(sink.synchronizer.rate, 1)

        sink.flush(keepingImage: false)
        XCTAssertEqual(sink.synchronizer.rate, 0)

        // Enqueueing after a flush must be accepted, not wedge the renderer.
        sink.enqueue(samples[0])
        XCTAssertNil(layer.sampleBufferRenderer.error)
        XCTAssertNotEqual(layer.sampleBufferRenderer.status, .failed)
    }

    func testTheAudioRendererDrivesTheSharedClock() throws {
        try skipUnlessRealtimeTests()
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "sink-audio.mp4",
            codec: .h264, width: 320, height: 240, frameCount: 96, fps: 24, audio: true
        )
        let demuxer = try Demuxer(url: url)
        let stream = try XCTUnwrap(demuxer.streams.first { $0.kind == .audio })
        let decoder = try AudioDecoder(stream: stream)
        var buffers: [CMSampleBuffer] = []
        while let packet = try demuxer.readPacket() {
            guard packet.streamIndex == stream.index else { continue }
            buffers.append(contentsOf: try decoder.decode(packet))
        }
        XCTAssertGreaterThan(buffers.count, 150)

        let sink = DisplayLayerSink(layer: AVSampleBufferDisplayLayer())
        for buffer in buffers {
            sink.enqueueAudio(buffer)
        }
        XCTAssertNil(sink.audioPassthroughError)
        // A machine with no audio output device cannot start the renderer, and
        // the clock this test is about is the device's. Everything else in the
        // suite counts samples instead, so only this one has to step aside.
        try XCTSkipIf(sink.audioRenderer.status != .rendering, "no audio output device")

        sink.start(atPresentation: 0)
        let started = Date()
        usleep(600_000)
        let elapsed = Date().timeIntervalSince(started)
        // the audio device's clock is the synchronizer's source clock once an
        // audio renderer is attached, so this is real playback time
        XCTAssertEqual(sink.presentationTime, elapsed, accuracy: 0.25)
        XCTAssertGreaterThan(sink.presentationTime, 0.3)
        XCTAssertNotEqual(sink.audioRenderer.status, .failed)

        // a seek: drop both queues, keep the picture, anchor somewhere else
        sink.flush(keepingImage: true)
        sink.start(atPresentation: 3)
        XCTAssertEqual(sink.presentationTime, 3, accuracy: 0.1)

        sink.setRate(0)
        let stopped = sink.presentationTime
        usleep(200_000)
        XCTAssertEqual(sink.presentationTime, stopped, accuracy: 0.02)
    }

    /// The observer that shows a cue fires on the main queue, so a test that
    /// never returns to the runloop never sees it.
    private func settle() {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
    }

    func testAProviderThatGoesDryIsOnlyAskedAgainAfterAResume() throws {
        try skipUnlessRealtimeTests()
        let sink = DisplayLayerSink(layer: AVSampleBufferDisplayLayer())
        let lock = NSLock()
        var callCount = 0
        sink.requestVideo(on: .main) {
            lock.lock(); callCount += 1; lock.unlock()
            // dry from the start: this exercises the no-frame-yet case, the
            // one a pulling engine spends most of its life in
            return nil
        }
        settle()
        lock.lock(); let first = callCount; lock.unlock()
        XCTAssertGreaterThan(first, 0, "must have been asked at least once")

        // AVFoundation only re-invokes the block on a not-ready-to-ready
        // TRANSITION, not merely because something else happened - a flush
        // alone must not quietly revive a dry request
        sink.flush(keepingImage: false)
        settle()
        lock.lock(); let afterFlush = callCount; lock.unlock()
        XCTAssertEqual(afterFlush, first, "a flush alone must not resume a dry request")

        // only an explicit resume, the caller's own signal that the
        // provider has more to give, brings it back
        sink.resumeVideoIfIdle()
        settle()
        lock.lock(); let afterResume = callCount; lock.unlock()
        XCTAssertGreaterThan(afterResume, afterFlush, "resumeVideoIfIdle must ask again")

        sink.stopRequestingMedia()
    }

    /// The renderer keeps every picture handed to it until it comes due, and
    /// the budget pays for only so many: past the limit the provider is not
    /// asked, and the clock running is what lets it be asked again.
    func testTheRunwayLimitHoldsTheProviderUntilTheClockMoves() throws {
        try skipUnlessRealtimeTests()
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "sink-runway.mp4",
            codec: .hevc, width: 320, height: 240, frameCount: 12, fps: 24
        )
        let demuxer = try Demuxer(url: url)
        let stream = try XCTUnwrap(demuxer.streams.first { $0.kind == .video })
        let formatDescription = try makeFormatDescription(for: stream)
        var samples: [CMSampleBuffer] = []
        while let packet = try demuxer.readPacket() {
            guard packet.streamIndex == stream.index else { continue }
            samples.append(try makeSampleBuffer(
                packet: packet, formatDescription: formatDescription,
                timeBaseNum: stream.timeBaseNum, timeBaseDen: stream.timeBaseDen
            ))
        }
        XCTAssertEqual(samples.count, 12)
        let film = samples

        let sink = DisplayLayerSink(layer: AVSampleBufferDisplayLayer())
        sink.anchor(atPresentation: 0)
        sink.setVideoRunwayLimit(0.1)
        let lock = NSLock()
        var handed = 0
        sink.requestVideo(on: DispatchQueue(label: "runway-test")) {
            lock.lock(); defer { lock.unlock() }
            guard handed < film.count else { return nil }
            handed += 1
            return film[handed - 1]
        }
        usleep(300_000)
        lock.lock(); let stopped = handed; lock.unlock()
        XCTAssertGreaterThan(stopped, 0)
        XCTAssertLessThanOrEqual(stopped, 6, "the provider was asked past the runway limit")

        sink.start(atPresentation: 0)
        usleep(800_000)
        lock.lock(); let running = handed; lock.unlock()
        XCTAssertEqual(running, film.count)
        sink.stopRequestingMedia()
    }

    func testStopRequestingMediaStopsTheCallbacks() throws {
        let sink = DisplayLayerSink(layer: AVSampleBufferDisplayLayer())
        let lock = NSLock()
        var callCount = 0
        sink.requestVideo(on: .main) {
            lock.lock(); callCount += 1; lock.unlock()
            return nil
        }
        settle()
        lock.lock(); let beforeStop = callCount; lock.unlock()
        XCTAssertGreaterThan(beforeStop, 0)

        sink.stopRequestingMedia()
        // the same edge that proved a live request gets asked again must
        // now prove a stopped one does not
        sink.flush(keepingImage: false)
        settle()
        lock.lock(); let afterStop = callCount; lock.unlock()
        XCTAssertEqual(afterStop, beforeStop, "no callback after stopRequestingMedia")
    }

    /// A provider is allowed to park for as long as its own track is starved
    /// - `PlayerEngine.waitOutStarvation` does exactly that, on the pull
    /// thread, inside the provider. The other track has to keep being asked
    /// through it: one demux thread feeds both, so audio delivery stopping
    /// behind a parked video pull fills the audio queues, parks that demux
    /// thread on them, and starves the very video queue the park is waiting
    /// to see refill.
    func testAParkedVideoProviderStillLetsAudioBeAsked() throws {
        let sink = DisplayLayerSink(layer: AVSampleBufferDisplayLayer())
        let parked = DispatchSemaphore(value: 0)
        let unpark = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var audioCalls = 0

        sink.requestVideo(on: DispatchQueue(label: "test.video-pull")) {
            parked.signal()
            unpark.wait()
            return nil
        }
        XCTAssertEqual(
            parked.wait(timeout: .now() + 5), .success, "the video provider was never asked")

        // Off the test thread on purpose: registering the audio side is
        // itself what blocks when the two share one lock, and this test has
        // to end in an assertion rather than in a hung test process.
        DispatchQueue.global().async {
            sink.requestAudio(on: DispatchQueue(label: "test.audio-pull")) {
                lock.lock(); audioCalls += 1; lock.unlock()
                return nil
            }
        }

        let deadline = Date(timeIntervalSinceNow: 5)
        var calls = 0
        while Date() < deadline, calls == 0 {
            Thread.sleep(forTimeInterval: 0.01)
            lock.lock(); calls = audioCalls; lock.unlock()
        }

        unpark.signal()
        sink.stopRequestingMedia()
        XCTAssertGreaterThan(
            calls, 0, "audio was never asked while the video provider sat parked")
    }

    private func cue(_ text: String, from start: Double, to end: Double) -> SubtitleCue {
        SubtitleCue(
            start: start, end: end, lines: [text], images: [],
            canvasWidth: 0, canvasHeight: 0
        )
    }

    func testSubtitlesWaitForTheClockAndFollowASeek() throws {
        try skipUnlessRealtimeTests()
        let sink = DisplayLayerSink(layer: AVSampleBufferDisplayLayer())
        sink.enqueueSubtitle(cue("one", from: 0.2, to: 0.5))
        sink.enqueueSubtitle(cue("two", from: 0.6, to: 5.0))
        settle()
        // nothing has started, so nothing is due
        XCTAssertNil(sink.shownSubtitle)

        // a seek while stopped moves the clock and fires the observer once,
        // which is what makes a subtitle appear without playback
        sink.anchor(atPresentation: 0.3)
        settle()
        XCTAssertEqual(sink.shownSubtitle?.lines, ["one"])

        // past the first cue's end and into the second: the one in between is
        // dropped rather than shown late
        sink.anchor(atPresentation: 0.7)
        settle()
        XCTAssertEqual(sink.shownSubtitle?.lines, ["two"])

        // and past everything the stream had
        sink.anchor(atPresentation: 6.0)
        settle()
        XCTAssertNil(sink.shownSubtitle)
    }

    func testFlushingDropsTheCuesAndTheAudioOnly() throws {
        try skipUnlessRealtimeTests()
        let sink = DisplayLayerSink(layer: AVSampleBufferDisplayLayer())
        sink.enqueueSubtitle(cue("one", from: 0.2, to: 5.0))
        sink.anchor(atPresentation: 0.3)
        settle()
        XCTAssertEqual(sink.shownSubtitle?.lines, ["one"])

        sink.flushSubtitles()
        settle()
        XCTAssertNil(sink.shownSubtitle)
        // and a cue that has not come due yet goes with it
        sink.enqueueSubtitle(cue("two", from: 1.0, to: 5.0))
        sink.flushSubtitles()
        sink.anchor(atPresentation: 1.5)
        settle()
        XCTAssertNil(sink.shownSubtitle)

        // an audio flush leaves the clock where it stands
        sink.flushAudio()
        XCTAssertEqual(sink.presentationTime, 1.5, accuracy: 0.05)
    }

    /// The two halves of the empty-cue rule: a text event this player draws
    /// nothing for is not a clear, a graphic display set with no bitmap is.
    func testAnEmptyCueClearsOnlyWhenItCameFromAGraphicStream() throws {
        let sink = DisplayLayerSink(layer: AVSampleBufferDisplayLayer())
        sink.enqueueSubtitle(cue("dialogue", from: 0.2, to: 5.0))
        // an ASS sign whose drawing commands were stripped, over that dialogue
        sink.enqueueSubtitle(SubtitleCue(
            start: 0.4, end: 0.8, lines: [], images: [],
            canvasWidth: 0, canvasHeight: 0
        ))
        sink.anchor(atPresentation: 0.5)
        settle()
        XCTAssertEqual(sink.shownSubtitle?.lines, ["dialogue"])

        // the same emptiness on a stream that has a canvas is a PGS display set
        // taking the last bitmap off the screen
        sink.enqueueSubtitle(SubtitleCue(
            start: 0.9, end: .infinity, lines: [], images: [],
            canvasWidth: 1920, canvasHeight: 1080
        ))
        sink.anchor(atPresentation: 1.0)
        settle()
        XCTAssertNil(sink.shownSubtitle)
    }

    func testOverlappingLinesShareTheScreenAndTheLongerOneOutlivesTheShorter() throws {
        let sink = DisplayLayerSink(layer: AVSampleBufferDisplayLayer())
        sink.enqueueSubtitle(cue("long", from: 0.2, to: 5.0))
        sink.enqueueSubtitle(cue("short", from: 0.4, to: 0.8))
        sink.anchor(atPresentation: 0.5)
        settle()
        XCTAssertEqual(sink.shownSubtitle?.lines, ["long", "short"])

        sink.anchor(atPresentation: 1.0)
        settle()
        XCTAssertEqual(sink.shownSubtitle?.lines, ["long"])
    }

    func testTheStyledPathIsDrivenByTheClockOnItsOwnQueue() throws {
        let sink = DisplayLayerSink(layer: AVSampleBufferDisplayLayer())
        sink.layer.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let built = expectation(description: "libass takes the track")
        sink.startStyled(
            header: Data(assStyledFixtureHeader.utf8), fonts: [],
            canvasWidth: 1920, canvasHeight: 1080
        ) { taken in
            XCTAssertTrue(taken)
            built.fulfill()
        }
        wait(for: [built], timeout: 2)
        sink.enqueueStyled(
            event: Data(#"0,0,Default,,0,0,0,,Bonjour la nuit"#.utf8),
            start: 1.0, duration: 2.0
        )
        XCTAssertNil(sink.shownStyledSubtitle)

        // the clock is what decides, exactly as it does for a cue
        sink.anchor(atPresentation: 1.5)
        let shown = expectation(description: "the styled subtitle reaches the screen")
        let poll = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { timer in
            if sink.shownStyledSubtitle != nil {
                timer.invalidate()
                shown.fulfill()
            }
        }
        wait(for: [shown], timeout: 2)
        poll.invalidate()
        let image = try XCTUnwrap(sink.shownStyledSubtitle)
        XCTAssertGreaterThan(image.width, 0)
        XCTAssertGreaterThan(image.y, 900)

        // a seek drops the events, and the screen goes with them
        sink.flushStyled()
        sink.anchor(atPresentation: 1.6)
        let cleared = expectation(description: "the flush reaches the screen")
        let second = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { timer in
            if sink.shownStyledSubtitle == nil {
                timer.invalidate()
                cleared.fulfill()
            }
        }
        wait(for: [cleared], timeout: 2)
        second.invalidate()

        sink.stopStyled()
        XCTAssertNil(sink.shownStyledSubtitle)
    }

    /// Waits until `condition` holds, running the main run loop meanwhile: the
    /// styled path decides on its own queue and publishes through main.
    private func waitForStyled(
        _ description: String, timeout: TimeInterval = 2, _ condition: () -> Bool
    ) {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        XCTFail("timed out waiting for \(description)")
    }

    /// The bitmap the styled slot is showing, read out of the sink's own layer
    /// tree: this is what reached the screen rather than what the sink decided.
    /// The overlay is the sublayer the sink puts above the picture, at
    /// zPosition 1, and the styled slot is the only thing visible in it while
    /// no cue is drawn. It is the image's identity the tests are after, so it
    /// is left untyped.
    private func styledBitmap(of sink: DisplayLayerSink) -> AnyObject? {
        let overlay = (sink.layer.sublayers ?? []).first { $0.zPosition == 1 }
        let styled = (overlay?.sublayers ?? []).first { !$0.isHidden }
        guard let contents = styled?.contents else { return nil }
        return contents as AnyObject
    }

    private func startStyledSink() -> DisplayLayerSink {
        let sink = DisplayLayerSink(layer: AVSampleBufferDisplayLayer())
        sink.layer.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let built = expectation(description: "libass takes the track")
        sink.startStyled(
            header: Data(assStyledFixtureHeader.utf8), fonts: [],
            canvasWidth: 1920, canvasHeight: 1080
        ) { taken in
            XCTAssertTrue(taken)
            built.fulfill()
        }
        wait(for: [built], timeout: 2)
        return sink
    }

    /// The styled path is reached through `flush(keepingImage:)` and nowhere
    /// else, so that is what a seek has to be tested through.
    func testASeekTakesTheStyledSubtitleOffTheScreenToo() throws {
        let sink = startStyledSink()
        defer { sink.stopStyled() }
        sink.enqueueStyled(
            event: Data(#"0,0,Default,,0,0,0,,Bonjour la nuit"#.utf8),
            start: 1.0, duration: 2.0
        )
        sink.anchor(atPresentation: 1.5)
        waitForStyled("the styled subtitle to reach the screen") {
            styledBitmap(of: sink) != nil
        }
        XCTAssertNotNil(sink.shownStyledSubtitle)

        // the flush a seek goes through, not flushStyled() by hand; the clock
        // stays where it is, so nothing else can take the bitmap off
        sink.flush(keepingImage: true)
        waitForStyled("the seek to take it off the screen") {
            styledBitmap(of: sink) == nil
        }
        XCTAssertNil(sink.shownStyledSubtitle)
    }

    /// What `publishedGeneration` is for: `showStyled` caches nothing, so a
    /// publish per tick would build a CGImage and re-upload megabytes 30 times
    /// a second for a line that is sitting still.
    func testASubtitleThatDoesNotMoveIsDrawnOnce() throws {
        try skipUnlessRealtimeTests()
        let sink = startStyledSink()
        defer { sink.stopStyled() }
        sink.enqueueStyled(
            event: Data(#"0,0,Default,,0,0,0,,Bonjour la nuit"#.utf8),
            start: 1.0, duration: 10.0
        )
        // the clock runs, so the observer fires 30 times a second
        sink.start(atPresentation: 1.5)
        defer { sink.setRate(0) }
        waitForStyled("the styled subtitle to reach the screen") {
            styledBitmap(of: sink) != nil
        }
        let first = try XCTUnwrap(styledBitmap(of: sink))
        // what the layer holds is the bitmap itself, so the identity compare
        // below is over the thing that would be rebuilt
        XCTAssertTrue(first is CGImage)

        // half a second of ticks over an event that does not move
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        XCTAssertLessThan(sink.presentationTime, 11.0)
        // the same object, not an equal one: a second upload would be a second
        // CGImage, and there is nothing between here and the layer that would
        // collapse them
        XCTAssertTrue(try XCTUnwrap(styledBitmap(of: sink)) === first)
    }

    func testATrackLibassCannotTakeLeavesTheTextPathToItsWork() {
        let sink = DisplayLayerSink(layer: AVSampleBufferDisplayLayer())
        // A container with no video stream has no canvas to put a subtitle in,
        // and the caller has to hear that rather than see a blank overlay.
        let refused = expectation(description: "libass refuses the track")
        sink.startStyled(
            header: Data(assStyledFixtureHeader.utf8), fonts: [],
            canvasWidth: 0, canvasHeight: 0
        ) { taken in
            XCTAssertFalse(taken)
            refused.fulfill()
        }
        wait(for: [refused], timeout: 2)
        XCTAssertNil(sink.shownStyledSubtitle)
        // and the members stay safe to call when nothing was started
        sink.enqueueStyled(event: Data("0,0,X,,0,0,0,,rien".utf8), start: 0, duration: 1)
        sink.flushStyled()
        sink.stopStyled()
    }

    /// Why there is a watchdog at all, and why it reads what it reads.
    /// `status` cannot tell a codec this host decodes from one it has never
    /// heard of - it says `.rendering` with no error for both - so a layer
    /// that renders nothing looks exactly like one that renders. Whether a
    /// picture is ready, and whether the renderer said it could not decode,
    /// are the two readings that do tell them apart.
    func testWhatTellsARenderedStreamFromAnUndecodableOne() throws {
        try skipUnlessRealtimeTests()
        guard #available(macOS 14.4, tvOS 17.4, *) else {
            throw XCTSkip("readyForDisplay needs tvOS 17.4 or macOS 14.4")
        }
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "sink-verdict.mp4",
            codec: .hevc, width: 320, height: 240, frameCount: 24, fps: 24
        )
        let demuxer = try Demuxer(url: url)
        let stream = try XCTUnwrap(demuxer.streams.first { $0.kind == .video })
        let extradata = try XCTUnwrap(stream.extradata)
        // 'xxxx', a fourcc no decoder anywhere answers to, beside the real one.
        let formats = try [kCMVideoCodecType_HEVC, CMVideoCodecType(0x7878_7878)].map {
            try videoFormatDescription(for: stream, codecType: $0, atoms: ["hvcC": extradata])
        }
        var described: [[CMSampleBuffer]] = [[], []]
        while let packet = try demuxer.readPacket() {
            guard packet.streamIndex == stream.index else { continue }
            for (index, format) in formats.enumerated() {
                described[index].append(try makeSampleBuffer(
                    packet: packet, formatDescription: format,
                    timeBaseNum: stream.timeBaseNum, timeBaseDen: stream.timeBaseDen
                ))
            }
        }
        XCTAssertFalse(described[0].isEmpty)

        func play(_ samples: [CMSampleBuffer]) -> DisplayLayerSink {
            let sink = DisplayLayerSink(layer: AVSampleBufferDisplayLayer())
            sink.start(atPresentation: 0)
            for sample in samples { sink.enqueue(sample) }
            let deadline = Date(timeIntervalSinceNow: 3)
            while !sink.hasDisplayedPicture, Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
            return sink
        }

        let real = play(described[0])
        XCTAssertTrue(real.hasDisplayedPicture)
        XCTAssertNil(real.videoDecodeFailure)

        let impossible = play(described[1])
        XCTAssertFalse(impossible.hasDisplayedPicture)
        XCTAssertNotNil(impossible.videoDecodeFailure)
        // One sink plays every film the app opens, so the verdict goes out
        // with the samples it was about rather than standing over the next.
        impossible.flush(keepingImage: false)
        XCTAssertNil(impossible.videoDecodeFailure)

        // And the reading that would have been trusted instead says the same
        // thing about both, which is the whole reason for the two above.
        XCTAssertEqual(
            real.layer.sampleBufferRenderer.status,
            impossible.layer.sampleBufferRenderer.status
        )
        XCTAssertNil(real.layer.sampleBufferRenderer.error)
        XCTAssertNil(impossible.layer.sampleBufferRenderer.error)
    }

    func testWantsExtendedDynamicRangeSetsTheLayersPreferredRange() throws {
        guard #available(tvOS 26.0, macOS 26.0, *) else {
            throw XCTSkip("preferredDynamicRange needs tvOS 26 or macOS 26")
        }
        let layer = AVSampleBufferDisplayLayer()
        let sink = DisplayLayerSink(layer: layer)
        sink.setWantsExtendedDynamicRange(true)
        XCTAssertEqual(layer.preferredDynamicRange, .high)
        // .standard, not .automatic: the tone-mapped path has already put an
        // SDR picture on the layer and must not ask the compositor for more
        // range than that picture carries.
        sink.setWantsExtendedDynamicRange(false)
        XCTAssertEqual(layer.preferredDynamicRange, .standard)
    }
}

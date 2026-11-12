import CoreMedia
import LexisTestSupport
import XCTest
@testable import LexisPlayer

/// The second net under the VideoToolbox probe: a display layer that takes
/// the 'dvh1' session and shows nothing has to end in tone mapping rather
/// than in a black screen the viewer cannot get out of.
final class DolbyVisionFallbackTests: RealtimeTestCase {
    /// The HLG fixture, whose Dolby Vision record says profile 8.4, patched on
    /// disk to say profile 5 with no compatible base layer - the one shape
    /// that either goes to the display layer described as 'dvh1' or gets tone
    /// mapped, with nothing in between.
    private func profileFiveFixture(named name: String, frameCount: Int) throws -> URL {
        let url = try makeHDRFixture(
            directory: FileManager.default.temporaryDirectory, name: name,
            width: 320, height: 180, frameCount: frameCount, transfer: .hlg, gopSize: 30
        )
        var bytes = try Data(contentsOf: url)
        let box = try XCTUnwrap(bytes.range(of: Data("dvvC".utf8)), "no Dolby Vision box")
        // The record's own layout: seven bits of profile over one of level in
        // byte 2, and the base layer's compatibility id in byte 4.
        let record = box.upperBound
        bytes[record + 2] = (5 << 1) | (bytes[record + 2] & 0x01)
        bytes[record + 4] = 0
        try bytes.write(to: url)
        return url
    }

    private let dolbyVisionScreen = DisplayCapability(headroom: 16, supportsDolbyVision: true)

    /// Skips where nothing would ever commit to Dolby Vision in the first
    /// place, so this reads as untested rather than as passing, on a host
    /// with no 'dvh1' decoder.
    private func requireDolbyVisionCommitment(_ url: URL) throws {
        let stream = try XCTUnwrap(Demuxer(url: url).streams.first { $0.kind == .video })
        XCTAssertEqual(stream.dolbyVision?.profile, 5)
        try XCTSkipIf(
            dolbyVisionPassthroughFormat(for: stream, capability: dolbyVisionScreen) == nil,
            "this host has no 'dvh1' decoder, so no playback here ever commits to one"
        )
    }

    /// Through a `MediaStreamIO`, which is what the app opens with and the
    /// only kind of demuxer a stop spends: the turn-round has to keep this one
    /// readable, or the fallback would cost the whole open again.
    func testAPathThatShowsNothingIsTurnedRoundOntoTheMappedOne() throws {
        let url = try profileFiveFixture(named: "dv-fallback.mp4", frameCount: 300)
        try requireDolbyVisionCommitment(url)
        let sink = CountingSink()
        // What the risk actually is: the layer accepts every sample, reports
        // `.rendering` with no error, and puts no picture up.
        sink.showNoPicture()
        sink.setEnqueueDelay(0.02)
        let player = LexisPlayer(sink: sink, display: { self.dolbyVisionScreen }, policy: testBufferPolicy)
        try player.open(
            stream: stallingStream(
                bytes: try Data(contentsOf: url), contentSeconds: 10, stalls: []
            ))
        // The open committed to the display layer, which is the state this
        // whole file exists to get back out of.
        XCTAssertTrue(player.stats.videoPassthrough)
        player.play()

        let deadline = Date(timeIntervalSinceNow: 60)
        while sink.pictures == 0, Date() < deadline { usleep(20_000) }
        player.stop()

        // Pictures, not packets: only the mapped path enqueues those.
        XCTAssertGreaterThan(sink.pictures, 0, "the mapped path never took over")
        XCTAssertFalse(player.stats.videoPassthrough)
    }

    /// Every second a viewer waits through an open is a second the sink's
    /// clock is anchored and not moving - the measured 13.8 s cold start,
    /// nearly all of it reaching the server, and then the refill that holds
    /// the first frame up behind it. A starved buffer mid-film puts the same
    /// clock back to a stop the same way. A budget counted against that clock
    /// cannot be spent by any of them; one counted in wall time from the
    /// press would tone map a perfectly good film on every cold start.
    func testAClockThatIsNotRunningCannotSpendTheBudget() throws {
        let url = try profileFiveFixture(named: "dv-cold.mp4", frameCount: 300)
        try requireDolbyVisionCommitment(url)
        let sink = CountingSink()
        sink.showNoPicture()
        sink.holdClock()
        sink.setEnqueueDelay(0.02)
        let player = LexisPlayer(sink: sink, display: { self.dolbyVisionScreen }, policy: testBufferPolicy)
        try player.open(url: url)
        player.play()

        // Several times the grace, in the only unit a wall clock has.
        let waitedOut = Date(timeIntervalSinceNow: 5 * testBufferPolicy.firstPictureGraceSeconds)
        while sink.samples.isEmpty, Date() < waitedOut { usleep(20_000) }
        XCTAssertFalse(sink.samples.isEmpty, "nothing ever crossed the sink")
        while Date() < waitedOut { usleep(50_000) }
        let stillPassthrough = player.stats.videoPassthrough
        player.stop()

        XCTAssertLessThan(
            sink.presentationTime, testBufferPolicy.firstPictureGraceSeconds,
            "the clock was supposed to be held"
        )
        XCTAssertTrue(
            stillPassthrough,
            "the Dolby Vision path was abandoned while its clock had not run at all"
        )
    }

    /// The film buffering at 1:04:23 is not a Dolby Vision failure, and it
    /// cannot be read as one here for a structural reason rather than a
    /// timing one: a picture seen once ends the watch for good, and every
    /// stall a viewer meets mid-film is on the far side of that. A layer
    /// gives `readyForDisplay` back on a flush that removes the image, so
    /// the answer going false again must change nothing.
    func testAPictureEndsTheWatchForGood() throws {
        let url = try profileFiveFixture(named: "dv-seen.mp4", frameCount: 450)
        try requireDolbyVisionCommitment(url)
        let sink = CountingSink()
        sink.setEnqueueDelay(0.02)
        let player = LexisPlayer(sink: sink, display: { self.dolbyVisionScreen }, policy: testBufferPolicy)
        try player.open(url: url)
        XCTAssertTrue(player.stats.videoPassthrough)
        player.play()

        // Half the grace with the picture up and the clock running, which is
        // several looks at it: the watch is over before the picture is taken
        // away below, and taking it away is what a flush does.
        let deadline = Date(timeIntervalSinceNow: 30)
        while sink.presentationTime < testBufferPolicy.firstPictureGraceSeconds / 2, Date() < deadline {
            usleep(20_000)
        }
        XCTAssertGreaterThan(sink.presentationTime, 0, "the clock never ran")
        sink.setDisplaysPictures(false)
        // A seek anchors a landed frame and reports `.firstFrame` all over
        // again, which is the one thing that could put the watch back on.
        player.seek(to: 5)

        // Long past the grace, with the clock running the whole way.
        let waitedOut = Date(timeIntervalSinceNow: 3 * testBufferPolicy.firstPictureGraceSeconds)
        while Date() < waitedOut { usleep(50_000) }
        let stillPassthrough = player.stats.videoPassthrough
        player.stop()

        XCTAssertTrue(stillPassthrough, "a path that had already shown a picture was abandoned")
        XCTAssertEqual(sink.pictures, 0, "nothing should have been tone mapped")
    }

    /// The ordinary passthrough path has nowhere better to go, so it is only
    /// ended on two signals agreeing. No picture on its own is not enough:
    /// that alone would turn a film that is playing into an error message.
    func testTheOrdinaryPathNeedsTheRendererToHaveRefusedTheSamplesToo() throws {
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "plain-nopicture.mp4",
            codec: .h264, width: 320, height: 180, frameCount: 300, fps: 30
        )
        let quiet = CountingSink()
        quiet.showNoPicture()
        quiet.setEnqueueDelay(0.02)
        let tolerant = LexisPlayer(sink: quiet, display: { DisplayCapability(headroom: 1) }, policy: testBufferPolicy)
        try tolerant.open(url: url)
        tolerant.play()
        let failures = FailureBox()
        let watching = Task { [events = tolerant.events] in
            for await event in events {
                if case .failed(let reason) = event { failures.record(reason) }
            }
        }
        let deadline = Date(timeIntervalSinceNow: 20)
        while quiet.presentationTime < 3 * testBufferPolicy.firstPictureGraceSeconds,
            Date() < deadline
        {
            usleep(20_000)
        }
        tolerant.stop()
        watching.cancel()
        XCTAssertNil(failures.reason, "a silent layer alone must not end a playback")

        let refusing = CountingSink()
        refusing.showNoPicture(refusing: "no decoder for this format")
        refusing.setEnqueueDelay(0.02)
        let strict = LexisPlayer(sink: refusing, display: { DisplayCapability(headroom: 1) }, policy: testBufferPolicy)
        let refused = FailureBox()
        try strict.open(url: url)
        strict.play()
        let listening = Task { [events = strict.events] in
            for await event in events {
                if case .failed(let reason) = event { refused.record(reason) }
            }
        }
        let secondDeadline = Date(timeIntervalSinceNow: 20)
        while refused.reason == nil, Date() < secondDeadline { usleep(20_000) }
        strict.stop()
        listening.cancel()
        XCTAssertEqual(refused.reason, "no decoder for this format")
    }
}

final class FailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: String?

    func record(_ value: String) {
        lock.lock()
        if recorded == nil { recorded = value }
        lock.unlock()
    }

    var reason: String? {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }
}

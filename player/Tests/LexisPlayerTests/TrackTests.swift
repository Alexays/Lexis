import AVFoundation
import LexisTestSupport
import XCTest
@testable import LexisPlayer

final class TrackTests: XCTestCase {
    private func fixture(_ name: String) throws -> URL {
        try makeSubtitleFixture(directory: FileManager.default.temporaryDirectory, name: name)
    }

    func testDescribesTheTracksItOpened() throws {
        let sink = CountingSink()
        let player = LexisPlayer(sink: sink)
        var reported: TrackList?
        let listed = expectation(description: "the track list")
        let collector = Task {
            for await event in player.events {
                if case .tracks(let list) = event {
                    reported = list
                    listed.fulfill()
                }
            }
        }
        try player.open(url: try fixture("tracks-open.mkv"))
        wait(for: [listed], timeout: 10)
        collector.cancel()

        let tracks = player.tracks
        XCTAssertEqual(tracks.audio.map(\.language), ["fre", "eng"])
        XCTAssertEqual(tracks.audio.map(\.title), ["VF", "VO"])
        XCTAssertEqual(tracks.subtitle.map(\.title), ["Forces", "SDH", "Bitmap"])
        // the first audio stream, and no subtitle until someone asks
        XCTAssertEqual(tracks.selectedAudio, 1)
        XCTAssertEqual(tracks.selectedSubtitle, -1)
        // and the same thing reached whoever was listening
        XCTAssertEqual(reported, tracks)
        player.close()
    }

    func testChaptersReachTheTrackList() throws {
        let sink = CountingSink()
        let player = LexisPlayer(sink: sink)
        let url = try makeSubtitleFixture(
            directory: FileManager.default.temporaryDirectory, name: "tracks-chapters.mkv",
            chapters: [
                MatroskaChapter(uid: 1, startMilliseconds: 0, title: "Intro"),
                MatroskaChapter(uid: 2, startMilliseconds: 2000, title: "Chapter Two"),
            ]
        )
        try player.open(url: url)
        XCTAssertEqual(player.tracks.chapters.map(\.start), [0, 2])
        XCTAssertEqual(player.tracks.chapters.map(\.title), ["Intro", "Chapter Two"])
        player.close()
    }

    func testSubtitleCuesReachTheSinkWithTheirTiming() throws {
        try skipUnlessRealtimeTests()
        let sink = CountingSink()
        let player = LexisPlayer(sink: sink)
        try player.open(url: try fixture("tracks-cues.mkv"))
        player.selectSubtitleTrack(index: 3)
        XCTAssertEqual(player.tracks.selectedSubtitle, 3)
        player.play()
        // the reader runs 0.3 s ahead of the clock, so by now it has read past
        // the first line and nowhere near the second at 3.2 s
        usleep(1_500_000)
        // before the stop: it flushes the sink, cues included
        let cues = sink.cues
        player.stop()
        player.close()

        XCTAssertEqual(cues.count, 1)
        let cue = try XCTUnwrap(cues.first)
        XCTAssertEqual(cue.start, 1.0, accuracy: 0.001)
        XCTAssertEqual(cue.end, 3.0, accuracy: 0.001)
        XCTAssertEqual(cue.lines, ["Bonjour la nuit"])
    }

    func testSwitchingAudioTrackDoesNotMoveThePicture() throws {
        try skipUnlessRealtimeTests()
        let sink = CountingSink()
        let player = LexisPlayer(sink: sink)
        try player.open(url: try fixture("tracks-audio.mkv"))
        player.play()
        usleep(1_200_000)
        let before = player.stats.position
        // open() closes whatever was there first, and that flushes the sink:
        // what matters is that the switch adds none of its own
        let flushesBefore = sink.flushes
        // the play that started the engine handed it its first track the same way
        let audioFlushesBefore = sink.audioFlushCount
        XCTAssertGreaterThan(before, 0.5)

        player.selectAudioTrack(index: 2)
        usleep(600_000)
        // everything is read before the teardown: a stop flushes the sink, and
        // a close forgets which tracks the file had
        let after = player.stats.position
        let selected = player.tracks.selectedAudio
        let flushes = sink.flushes
        let audioFlushes = sink.audioFlushCount
        let arrived = sink.audioSinceLastFlush
        player.stop()
        player.close()

        XCTAssertEqual(selected, 2)
        // the clock kept running: a switch is a swap, not a seek
        XCTAssertGreaterThan(after, before)
        XCTAssertEqual(flushes, flushesBefore)
        // what the old track had queued was dropped, and the new one arrived
        XCTAssertEqual(audioFlushes - audioFlushesBefore, 1)
        XCTAssertFalse(arrived.isEmpty)
    }

    func testSwitchingToATrackWithNoDecoderGoesSilent() throws {
        try skipUnlessRealtimeTests()
        let sink = CountingSink()
        // Nothing paces delivery to content time any more: without this,
        // this fixture's own short clip could already be fully played out
        // (and the engine gone with it) by the time the switch below is
        // even attempted, leaving nothing for it to apply to.
        sink.setEnqueueDelay(0.02)
        let player = LexisPlayer(sink: sink)
        try player.open(url: try makeSubtitleFixture(
            directory: FileManager.default.temporaryDirectory, name: "tracks-mute.mkv",
            undecodableAudio: true
        ))
        player.play()
        pollUntil("the old track to feed the renderer") { !sink.audioSinceLastFlush.isEmpty }

        player.selectAudioTrack(index: 6)
        pollUntil("the switch onto a track nothing decodes") {
            player.tracks.selectedAudio == -1
        }
        let selected = player.tracks.selectedAudio
        // the flush emptied the renderer, so this is what the new track fed it
        let arrived = sink.audioSinceLastFlush
        let format = player.stats.audioFormat
        player.stop()
        player.close()

        // the old track stopped with the switch rather than playing on under a
        // list that says nothing is selected
        XCTAssertEqual(selected, -1)
        XCTAssertTrue(arrived.isEmpty)
        // and the readout stopped naming the route the old track played on
        XCTAssertEqual(format, "unsupported")
    }

    /// A film whose only sound track no decoder answers for plays silent, and
    /// the readout has to say so: "pcm, decoded" is what a film playing its
    /// sound normally reports, and a viewer left with silence under it cannot
    /// tell the file from their own television.
    func testAFilmWhoseOnlySoundTrackHasNoDecoderSaysSo() throws {
        let directory = FileManager.default.temporaryDirectory
        let source = try makeVideoFixture(
            directory: directory, name: "tracks-silent.source.mp4", codec: .h264,
            width: 320, height: 240, frameCount: 24, fps: 24
        )
        let demuxer = try Demuxer(url: source)
        let video = try XCTUnwrap(demuxer.streams.first { $0.kind == .video })
        var frames: [MatroskaFrame] = []
        let base = Double(video.timeBaseNum) / Double(video.timeBaseDen)
        while let packet = try demuxer.readPacket() {
            guard packet.streamIndex == video.index else { continue }
            frames.append(MatroskaFrame(
                track: 1,
                milliseconds: Int((Double(packet.pts ?? 0) * base * 1000).rounded()),
                decodeMilliseconds: Int((Double(packet.dts ?? 0) * base * 1000).rounded()),
                isKeyframe: packet.isKeyframe, data: packet.copiedBytes
            ))
        }
        frames.append(MatroskaFrame(
            track: 2, milliseconds: 0, isKeyframe: true, data: Data(repeating: 0, count: 16)
        ))
        let url = try makeMatroskaFixture(
            directory: directory, name: "tracks-silent.mkv",
            tracks: [
                MatroskaTrack(
                    number: 1, kind: .video, codecID: "V_MPEG4/ISO/AVC",
                    codecPrivate: video.extradata, width: 320, height: 240, language: "und"
                ),
                MatroskaTrack(
                    number: 2, kind: .audio, codecID: "A_LEXIS/NOSUCHCODEC",
                    sampleRate: 48000, channels: 2, language: "ita"
                ),
            ],
            frames: frames, durationMilliseconds: 1000, cueTrack: 1
        )

        let player = LexisPlayer(sink: CountingSink())
        try player.open(url: url)
        let stats = player.stats
        let selected = player.tracks.selectedAudio
        player.close()

        XCTAssertEqual(selected, -1)
        XCTAssertEqual(stats.audioFormat, "unsupported")
        XCTAssertFalse(stats.audioPassthrough)
    }

    /// A film that simply carries no sound is not a fault, and reads apart
    /// from one whose track could not be decoded.
    func testAFilmWithNoSoundTrackAtAllReadsApartFromABrokenOne() throws {
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "tracks-mute-source.mp4",
            codec: .h264, width: 320, height: 240, frameCount: 24, fps: 24
        )
        let player = LexisPlayer(sink: CountingSink())
        try player.open(url: url)
        let stats = player.stats
        player.close()

        XCTAssertEqual(stats.audioFormat, "none")
        XCTAssertFalse(stats.audioPassthrough)
    }

    func testTurningSubtitlesOffTakesThemOffTheScreen() throws {
        try skipUnlessRealtimeTests()
        let sink = CountingSink()
        let player = LexisPlayer(sink: sink)
        try player.open(url: try fixture("tracks-off.mkv"))
        player.selectSubtitleTrack(index: 3)
        player.play()
        usleep(1_500_000)
        XCTAssertFalse(sink.cues.isEmpty)

        player.selectSubtitleTrack(index: -1)
        usleep(300_000)
        let selected = player.tracks.selectedSubtitle
        let flushes = sink.subtitleFlushCount
        let remaining = sink.cues
        player.stop()
        player.close()

        XCTAssertEqual(selected, -1)
        // the flush cleared what was queued, and nothing came after it
        XCTAssertGreaterThanOrEqual(flushes, 1)
        XCTAssertTrue(remaining.isEmpty)
    }

    func testSwitchingSubtitleTrackFlushesBeforeThePlayerPublishesTheSwap() throws {
        try skipUnlessRealtimeTests()
        let sink = CountingSink()
        let player = LexisPlayer(sink: sink)
        try player.open(url: try fixture("tracks-order.mkv"))
        player.selectSubtitleTrack(index: 3)
        player.play()
        usleep(1_000_000)

        let probe = NSLock()
        var selectedAtFlush: [Int32] = []
        sink.onSubtitleFlush = { [weak player] in
            guard let selected = player?.tracks.selectedSubtitle else { return }
            probe.lock()
            selectedAtFlush.append(selected)
            probe.unlock()
        }
        player.selectSubtitleTrack(index: 4)
        usleep(300_000)
        sink.onSubtitleFlush = nil
        player.stop()
        player.close()

        probe.lock()
        let observed = selectedAtFlush
        probe.unlock()
        // A running reader wakes on the swap and can enqueue the new track's
        // first cue: the flush has to land while the old track is still the
        // published one, or it drops that cue.
        XCTAssertEqual(observed.first, 3)
    }

    func testTurningSubtitlesOffWhilePausedClearsThemAtOnce() throws {
        try skipUnlessRealtimeTests()
        let sink = CountingSink()
        let player = LexisPlayer(sink: sink)
        try player.open(url: try fixture("tracks-paused.mkv"))
        player.selectSubtitleTrack(index: 3)
        player.play()
        usleep(1_500_000)
        player.pause()
        usleep(200_000)
        XCTAssertFalse(sink.cues.isEmpty)
        let flushesBefore = sink.subtitleFlushCount

        player.selectSubtitleTrack(index: -1)
        // the reader is parked on the pause and picks the swap up only when it
        // wakes, so this is the selector's own flush
        let cleared = sink.subtitleFlushCount
        let whilePaused = sink.cues
        player.play()
        usleep(400_000)
        let afterResume = sink.cues
        player.stop()
        player.close()

        XCTAssertGreaterThan(cleared, flushesBefore)
        XCTAssertTrue(whilePaused.isEmpty)
        // the reader's own flush on the swap changes nothing, and the track it
        // dropped feeds no more cues
        XCTAssertTrue(afterResume.isEmpty)
    }
}

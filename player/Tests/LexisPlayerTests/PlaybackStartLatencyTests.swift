import CLexisStream
import Foundation
import LexisCoreStream
import LexisTestSupport
import XCTest
@testable import LexisPlayer

/// What a viewer waits through between pressing play and seeing a picture,
/// against the profile the owner's own Plex stream was measured at rather
/// than a local file. Reports the stages rather than asserting a threshold:
/// the split between them is what says where the time goes, and a wall-clock
/// bound on a shared machine would only be flaky.
final class PlaybackStartLatencyTests: XCTestCase {
    /// Off unless asked for, the way the core's own scan benchmark is
    /// `#[ignore]`: a hundred megabytes of noise is minutes of encoding, and
    /// these report numbers rather than passing or failing on them. Run with
    /// `LEXIS_MEASURE=1 swift test --filter PlaybackStartLatencyTests`.
    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["LEXIS_MEASURE"] == "1",
            "set LEXIS_MEASURE=1 to run the start-latency measurements"
        )
    }

    /// Every stage of one press-play, in seconds since the press.
    private struct Timings {
        var coreOpen = 0.0
        var demuxOpen = 0.0
        var firstPicture = 0.0
        var firstMotion = 0.0
        var connections = 0
        var requestsToPicture = 0
        var requestsToMotion = 0
        var bufferedAtMotion = 0.0
    }

    /// The reference film's own bitrate, so seconds of buffer and megabytes
    /// of it line up the way they do on the real library.
    private static let referenceBitsPerSecond = 74_500_000
    private static let referenceSeconds = 12
    private static let fps: Int32 = 24

    private static var film: Data?

    /// One 12 s film at the reference bitrate, encoded once per process:
    /// a hundred megabytes of noise is minutes of encoding, and every
    /// measurement in this file reads the same bytes.
    private func referenceFilm() throws -> Data {
        if let film = PlaybackStartLatencyTests.film { return film }
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "start-latency.mp4",
            codec: .hevc, width: 1280, height: 720,
            frameCount: Int(PlaybackStartLatencyTests.fps) * PlaybackStartLatencyTests.referenceSeconds,
            fps: PlaybackStartLatencyTests.fps, noisy: true, audio: true,
            bitrate: PlaybackStartLatencyTests.referenceBitsPerSecond
        )
        let data = try Data(contentsOf: url)
        PlaybackStartLatencyTests.film = data
        return data
    }

    /// The whole press-play path the app takes: the core resolves and opens
    /// the part (one range request before a byte reaches the demuxer), the
    /// player probes the container, and the engine puts a frame up and then
    /// holds the clock until its buffer clears the cold-start watermark.
    /// `resumeAt` follows `PlayerScreen`'s own order - the seek is queued
    /// behind the open, never before it.
    private func pressPlay(_ server: RangeHTTPServer, resumeAt: Double?) throws -> Timings {
        let sink = CountingSink()
        let player = LexisPlayer(sink: sink)
        defer { player.close() }
        let motion = DispatchSemaphore(value: 0)
        sink.onClockStart = { motion.signal() }
        let picture = DispatchSemaphore(value: 0)
        let collector = Task {
            for await event in player.events {
                if case .firstFrame = event { picture.signal() }
            }
        }
        defer { collector.cancel() }

        var timings = Timings()
        let pressed = Date()
        let handle = try XCTUnwrap(lexis_stream_open_http_range(
            "\(server.baseURL)/library/parts/1/1/film.mp4", "X-Plex-Token", "tok", nil
        ))
        timings.coreOpen = Date().timeIntervalSince(pressed)
        try player.open(stream: coreStream(handle: handle))
        timings.demuxOpen = Date().timeIntervalSince(pressed)
        player.play()
        if let resumeAt { player.seek(to: resumeAt) }

        XCTAssertEqual(picture.wait(timeout: .now() + 120), .success, "no first frame")
        timings.firstPicture = Date().timeIntervalSince(pressed)
        timings.requestsToPicture = server.requests.count
        XCTAssertEqual(motion.wait(timeout: .now() + 300), .success, "the clock never started")
        timings.firstMotion = Date().timeIntervalSince(pressed)
        timings.requestsToMotion = server.requests.count
        timings.connections = server.connectionCount
        timings.bufferedAtMotion = player.stats.bufferedSeconds
        let starts = server.requests.compactMap { head -> Int? in
            guard let line = head.split(separator: "\r\n").first(where: { $0.hasPrefix("Range:") })
            else { return nil }
            return Int(line.dropFirst("Range: bytes=".count).split(separator: "-")[0])
        }
        print("  span starts (MiB): "
            + starts.prefix(22).map { String($0 / 1_048_576) }.joined(separator: " "))
        return timings
    }

    private func report(_ label: String, _ t: Timings) {
        // Requests times the span is bytes off the wire: against the buffer
        // it delivers, that ratio is what says whether the window is being
        // read once or read over and over.
        print(String(
            format: "MEASURE %@: core-open %.3f  demux-open %.3f  "
                + "FIRST PICTURE %.3f  first motion %.3f  "
                + "requests %d/%d  buffered %.2f s  conns %d",
            label, t.coreOpen, t.demuxOpen, t.firstPicture, t.firstMotion,
            t.requestsToPicture, t.requestsToMotion, t.bufferedAtMotion, t.connections
        ))
    }

    /// The two presses a viewer actually makes: one on a film never started,
    /// one on the continue-watching row.
    func testPressPlayToFirstPictureAgainstTheMeasuredProfile() throws {
        let data = try referenceFilm()
        print(String(
            format: "MEASURE film: %.1f MiB over %d s = %.1f Mbps",
            Double(data.count) / 1_048_576, PlaybackStartLatencyTests.referenceSeconds,
            Double(data.count) * 8 / Double(PlaybackStartLatencyTests.referenceSeconds) / 1e6
        ))

        for resumeAt in [nil, Double(6)] as [Double?] {
            let server = try RangeHTTPServer(body: data)
            defer { server.stop() }
            server.serveMeasuredProfile(MeasuredStreamProfile(), coldFirstConnection: false)
            let timings = try pressPlay(server, resumeAt: resumeAt)
            report(resumeAt == nil ? "cold start" : "resume at 6 s", timings)
        }
    }

    /// What the cold-start watermark is buying on the other side of the wait:
    /// the frozen picture it costs is only worth paying for if the buffer
    /// behind it would otherwise have drained. Plays the film out and reports
    /// how close the buffer ever came to empty.
    func testTheBufferAfterTheColdStartWatermarkIsReleased() throws {
        // A quarter of the reference, film and link together, so the ratio
        // the buffer actually lives or dies by is the one the profile
        // measured while the decoder stays well inside real time: at the
        // full reference this host decodes 720p noise at half speed and
        // every arm of the comparison stalls on the decoder instead.
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "start-latency-quarter.mp4",
            codec: .hevc, width: 1280, height: 720,
            frameCount: Int(PlaybackStartLatencyTests.fps) * PlaybackStartLatencyTests.referenceSeconds,
            fps: PlaybackStartLatencyTests.fps, noisy: true, audio: true,
            bitrate: PlaybackStartLatencyTests.referenceBitsPerSecond / 4
        )
        let data = try Data(contentsOf: url)
        print(String(
            format: "MEASURE quarter film: %.1f Mbps",
            Double(data.count) * 8 / Double(PlaybackStartLatencyTests.referenceSeconds) / 1e6
        ))
        for run in 1...3 { try playOut(data, run: run) }
    }

    private func playOut(_ data: Data, run: Int) throws {
        let server = try RangeHTTPServer(body: data)
        defer { server.stop() }
        var profile = MeasuredStreamProfile()
        profile.coldPerRequestBitsPerSecond /= 4
        profile.reusedBitsPerSecond /= 4
        server.serveMeasuredProfile(profile, coldFirstConnection: false)

        let sink = CountingSink()
        let player = LexisPlayer(sink: sink)
        defer { player.close() }
        let motion = DispatchSemaphore(value: 0)
        sink.onClockStart = { motion.signal() }

        let pressed = Date()
        let handle = try XCTUnwrap(lexis_stream_open_http_range(
            "\(server.baseURL)/library/parts/1/1/film.mp4", "X-Plex-Token", "tok", nil
        ))
        try player.open(stream: coreStream(handle: handle))
        player.play()
        XCTAssertEqual(motion.wait(timeout: .now() + 300), .success, "the clock never started")
        let started = Date().timeIntervalSince(pressed)

        // sampled from the clock starting to the end of the film: where each
        // rebuffer lands is what says whether starting sooner caused it
        var lowestEarly = Double.greatestFiniteMagnitude
        var rebuffersAt: [String] = []
        var seenRebuffers = 0
        var ticks = 0
        while player.stats.position < Double(PlaybackStartLatencyTests.referenceSeconds) - 0.5 {
            usleep(200_000)
            let stats = player.stats
            // the first three seconds of playback: the span a cold-start
            // watermark is the only thing standing in front of
            if stats.position < 3 { lowestEarly = min(lowestEarly, stats.bufferedSeconds) }
            if stats.rebufferCount > seenRebuffers {
                seenRebuffers = stats.rebufferCount
                rebuffersAt.append(String(format: "%.1f s in", stats.position))
            }
            ticks += 1
            if Date().timeIntervalSince(pressed) > 120 { break }
        }
        print(String(
            format: "MEASURE playing out %d: clock started %.3f  lowest buffer in the first 3 s "
                + "%.2f s  rebuffers %d [%@]  wall %.1f s for %d s of film",
            run, started, lowestEarly, player.stats.rebufferCount,
            rebuffersAt.joined(separator: ", "), Date().timeIntervalSince(pressed),
            PlaybackStartLatencyTests.referenceSeconds
        ))
    }
}

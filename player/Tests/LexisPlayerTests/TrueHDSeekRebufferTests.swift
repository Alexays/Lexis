import Foundation
import XCTest
@testable import LexisPlayer

/// The open defect: `H.264 + TrueHD` rebuffers on some runs, always at the
/// frame a seek just landed on. Reproduces it against the benchmark corpus
/// clip, beside the plain H.264 one under the same script, and reports what
/// each track had buffered when the seek's own hold let the clock go.
///
/// Both clips are released with the same buffer and only one of them
/// rebuffers, so the amount of buffer a seek leaves behind is not what
/// separates them: whatever it is costs the TrueHD path time after the
/// release, not bytes before it.
final class TrueHDSeekRebufferTests: XCTestCase {
    private func corpusClip(_ name: String) -> URL? {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".bench-corpus/\(name)")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private struct Landing {
        var rebuffers = 0
        var video = 0.0
        var audio = 0.0
    }

    /// One open, one seek to the middle, and whatever the pipeline does for a
    /// second and a half after the landed frame reaches the sink.
    private func openSeekAndWatch(_ url: URL) throws -> Landing {
        let demuxer = try Demuxer(url: url)
        let video = try XCTUnwrap(demuxer.streams.first { $0.kind == .video })
        let audio = try XCTUnwrap(demuxer.streams.first { $0.kind == .audio })
        let sink = CountingSink()
        let engine = PlayerEngine(
            demuxer: demuxer, tracks: .init(video: video, audio: audio, subtitle: nil),
            sink: sink, toneMapped: nil, interrupt: InterruptFlag()
        )
        defer { engine.stop(join: true) }
        engine.selectAudio(audio, pipeline: .decoded(try AudioDecoder(stream: audio)))
        engine.start(paused: false)

        // the first frame of the open, before the seek that is the subject
        let opened = Date(timeIntervalSinceNow: 20)
        while engine.statistics.framesDisplayed == 0, Date() < opened { usleep(5000) }

        let landed = DispatchSemaphore(value: 0)
        engine.seek(to: 5) { _ in landed.signal() }
        XCTAssertEqual(landed.wait(timeout: .now() + 20), .success, "the seek never landed")

        var result = Landing()
        // the hold is released a beat after the landed frame crosses the
        // sink, so this is read once the clock is actually running
        let released = Date(timeIntervalSinceNow: 10)
        while sink.presentationTime == 0, Date() < released { usleep(5000) }
        let atRelease = engine.statistics
        result.video = atRelease.videoBufferedSeconds
        result.audio = atRelease.audioBufferedSeconds

        let watchUntil = Date(timeIntervalSinceNow: 1.5)
        while Date() < watchUntil { usleep(20_000) }
        result.rebuffers = engine.statistics.rebufferCount
        return result
    }

    func testHowOftenASeekOnTrueHDRebuffers() throws {
        let clips = ["truehd.mkv", "h264.mp4"].compactMap { corpusClip($0) }
        guard clips.count == 2 else {
            throw XCTSkip("corpus not generated: run player/scripts/make-benchmark-corpus.sh")
        }
        // fifty seeks and a second and a half of watching after each
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["LEXIS_MEASURE"] == "1",
            "set LEXIS_MEASURE=1 to run the rebuffer measurement"
        )
        for url in clips {
            let name = url.lastPathComponent
            var rebuffered = 0
            var video: [Double] = []
            var audio: [Double] = []
            let runs = 25
            for _ in 0..<runs {
                let landing = try openSeekAndWatch(url)
                if landing.rebuffers > 0 { rebuffered += 1 }
                video.append(landing.video)
                audio.append(landing.audio)
            }
            print(String(
                format: "MEASURE %@: %d of %d seeks rebuffered; at the release "
                    + "video %.2f s, audio %.2f s",
                name, rebuffered, runs,
                video.reduce(0, +) / Double(runs), audio.reduce(0, +) / Double(runs)
            ))
        }
    }
}

import CoreMedia
import LexisTestSupport
import VideoToolbox
import XCTest
@testable import LexisPlayer

final class DecodeOnlyProbeRunTests: XCTestCase {
    static let corpusDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".bench-corpus")

    override func tearDown() {
        // belt and braces: a failing assertion inside a run must not leave
        // the gate held for whichever test runs next
        PlaybackActivityGate.shared.endPlayer()
        PlaybackActivityGate.shared.endProbe()
        super.tearDown()
    }

    func testItReportsHardwareFramesAndTimingForARealClip() throws {
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "decode-only-8.mp4",
            codec: .h264, width: 320, height: 180, frameCount: 8, fps: 24
        )
        let result = try DecodeOnlyProbeRun.run(url: url)
        XCTAssertEqual(result.hardwareAccelerated, VTIsHardwareDecodeSupported(kCMVideoCodecType_H264))
        XCTAssertTrue(result.hardwareAccelerationKnown)
        XCTAssertEqual(result.framesDecoded, 8)
        XCTAssertGreaterThan(result.wallMilliseconds, 0)
        XCTAssertGreaterThan(result.decodeMillisecondsMean, 0)
        XCTAssertGreaterThanOrEqual(result.decodeMillisecondsWorst, result.decodeMillisecondsMean)
        let ratio = try XCTUnwrap(result.decodeToContentRatio)
        XCTAssertGreaterThan(ratio, 0)
        #if targetEnvironment(simulator)
        XCTAssertTrue(result.isSimulator)
        XCTAssertFalse(result.hardwareAccelerated)
        #else
        XCTAssertFalse(result.isSimulator)
        #endif
    }

    func testItStopsAtTheProbesOwnFrameLimitOnALongerClip() throws {
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "decode-only-90.mp4",
            codec: .h264, width: 320, height: 180, frameCount: 90, fps: 24
        )
        let result = try DecodeOnlyProbeRun.run(url: url)
        XCTAssertEqual(result.framesDecoded, PassthroughDecodeProbe.frameLimit)
    }

    func testAFailedOpenPropagatesAndStillReleasesTheGate() throws {
        try skipUnlessRealtimeTests()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("not-media.mp4")
        try Data("not a container".utf8).write(to: url)
        XCTAssertThrowsError(try DecodeOnlyProbeRun.run(url: url))
        // the gate must not still be held by the failed attempt: a real run
        // right after it must succeed
        let good = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "decode-only-after-failure.mp4",
            codec: .h264, width: 320, height: 180, frameCount: 4, fps: 24
        )
        _ = try DecodeOnlyProbeRun.run(url: good)
    }

    func testARunningFilmRefusesTheProbe() throws {
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "decode-only-blocked.mp4",
            codec: .h264, width: 320, height: 180, frameCount: 4, fps: 24
        )
        let player = LexisPlayer(sink: CountingSink())
        try player.open(url: url)
        defer { player.close() }
        XCTAssertThrowsError(try DecodeOnlyProbeRun.run(url: url)) {
            XCTAssertEqual($0 as? PlaybackActivityGate.Busy, .playbackRunning)
        }
    }

    func testARunningProbeRefusesAFilmToOpen() throws {
        try PlaybackActivityGate.shared.beginProbe()
        defer { PlaybackActivityGate.shared.endProbe() }
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "decode-only-blocks-player.mp4",
            codec: .h264, width: 320, height: 180, frameCount: 4, fps: 24
        )
        let player = LexisPlayer(sink: CountingSink())
        XCTAssertThrowsError(try player.open(url: url)) {
            XCTAssertEqual($0 as? PlaybackActivityGate.Busy, .probeRunning)
        }
        XCTAssertFalse(player.isOpen)
    }

    func testClosingAFilmLetsAProbeRunAfterward() throws {
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "decode-only-unblocked.mp4",
            codec: .h264, width: 320, height: 180, frameCount: 4, fps: 24
        )
        let player = LexisPlayer(sink: CountingSink())
        try player.open(url: url)
        player.close()
        let result = try DecodeOnlyProbeRun.run(url: url)
        XCTAssertEqual(result.framesDecoded, 4)
    }

    /// Skips rather than fails when the corpus has not been generated on
    /// this machine, the same discipline BenchmarkCorpusTests already
    /// keeps: a contributor without ffmpeg is never forced to have it.
    private func corpusURL(_ file: String) throws -> URL {
        let url = Self.corpusDir.appendingPathComponent(file)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("corpus not generated: run player/scripts/make-benchmark-corpus.sh")
        }
        return url
    }

    func testAV1ReportsARealHardwareAnswerOnADeviceThatHasAnAV1Session() throws {
        let result = try DecodeOnlyProbeRun.run(url: try corpusURL("av1.mkv"))
        XCTAssertEqual(result.hardwareAccelerated, VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1))
        XCTAssertTrue(result.hardwareAccelerationKnown)
        XCTAssertGreaterThan(result.framesDecoded, 0)
    }

    /// VP9 carries no CodecPrivate in this corpus's own Matroska file
    /// (task 4b verified this against the real vp9.mkv) - measuring it at
    /// all is the point of this test, whichever way the device answers.
    /// Either this machine has no VP9 decoder at all, which is the
    /// `deviceRefused` case this task adds, or it decodes for real; a
    /// third failure (`formatDescriptionUnavailable`, "we never even
    /// asked") would mean the bitstream parser regressed.
    func testVP9EitherDecodesForRealOrIsHonestlyRefusedByTheDeviceNeverUnasked() throws {
        do {
            let result = try DecodeOnlyProbeRun.run(url: try corpusURL("vp9.mkv"))
            XCTAssertTrue(result.hardwareAccelerationKnown)
            XCTAssertGreaterThan(result.framesDecoded, 0)
        } catch let error as DecodeOnlyRunError {
            guard case .deviceRefused = error else {
                XCTFail("expected deviceRefused, a real VideoToolbox answer, got \(error)")
                return
            }
        }
    }

    /// MPEG-2 has no hardware decoder on any Apple chip (spec, and
    /// HardwareDecodeSupportTests pins VTIsHardwareDecodeSupported false
    /// for it): a real measurement here must agree, never hardware=true.
    func testMPEG2DecodesInSoftwareNeverHardware() throws {
        let result = try DecodeOnlyProbeRun.run(url: try corpusURL("mpeg2.ts"))
        XCTAssertTrue(result.hardwareAccelerationKnown)
        XCTAssertFalse(result.hardwareAccelerated)
        XCTAssertGreaterThan(result.framesDecoded, 0)
    }
}

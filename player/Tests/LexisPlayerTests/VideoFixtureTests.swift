import AVFoundation
import LexisTestSupport
import XCTest

final class VideoFixtureTests: XCTestCase {
    func testAuthorsAPlayableFile() async throws {
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "fixture-check.mp4",
            codec: .hevc, width: 320, height: 240, frameCount: 48, fps: 24
        )
        let fileSize = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
        XCTAssertGreaterThan(fileSize, 1000)
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(size.width, 320)
        XCTAssertEqual(size.height, 240)
    }

    func testAuthorsAVideoAndAudioFile() throws {
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "fixture-av.mp4",
            codec: .h264, width: 320, height: 240, frameCount: 96, fps: 24, audio: true
        )
        let asset = AVURLAsset(url: url)
        XCTAssertEqual(asset.tracks(withMediaType: .video).count, 1)
        let audio = try XCTUnwrap(asset.tracks(withMediaType: .audio).first)
        XCTAssertEqual(audio.naturalTimeScale, 48000)
        // 96 frames at 24 fps is 4 s, and the audio track covers it
        XCTAssertEqual(audio.timeRange.duration.seconds, 4.0, accuracy: 0.2)
    }
}

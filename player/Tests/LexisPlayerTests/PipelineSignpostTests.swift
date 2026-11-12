import LexisCoreStream
import LexisTestSupport
import XCTest
import os.signpost
@testable import LexisPlayer

/// The marks Instruments reads the pull pipeline through. Nothing in the
/// process can read a signpost back once it is emitted, so what is provable
/// here is the two things that actually go wrong: a stage wired to
/// `OSSignposter.disabled`, which leaves an Instruments lane silently empty,
/// and a mark on a hot path taking the pipeline down with it. The rebuffer
/// stage is the one an ordinary playback never reaches; `RebufferTests`
/// drives it, and now drives it through the interval that brackets it.
final class PipelineSignpostTests: XCTestCase {
    func testEveryStageHasItsOwnLiveSignposter() {
        XCTAssertEqual(PipelineSignposts.all.count, 5)
        for (stage, signposter) in PipelineSignposts.all {
            XCTAssertTrue(
                signposter.isEnabled,
                "\(stage) is signposted through a disabled signposter: its Instruments lane "
                    + "would read as a stage doing nothing, which is worse than no lane"
            )
        }
    }

    /// Fetch, demux, decode and enqueue all run on the hot path of an
    /// ordinary playback; a file played end to end walks every one of them
    /// with the marks live.
    func testAPlaybackWalksEveryStageWithTheMarksLive() throws {
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "signposts.mp4",
            codec: .hevc, width: 320, height: 240, frameCount: 96, fps: 24
        )
        let sink = CountingSink()
        let player = LexisPlayer(sink: sink)
        let ended = expectation(description: "end of stream")
        let collector = Task {
            for await event in player.events where event == .endOfStream { ended.fulfill() }
        }
        try player.open(url: url)
        player.play()
        wait(for: [ended], timeout: 15)
        collector.cancel()

        XCTAssertGreaterThan(player.stats.packetsRead, 0)
        XCTAssertGreaterThan(player.stats.framesDisplayed, 0)
    }
}

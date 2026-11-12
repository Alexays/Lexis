import AVFoundation
import CLexisStream
import LexisCoreStream
import LexisTestSupport
import XCTest
@testable import LexisPlayer

/// A film opened again and again, as the app does it: whatever the last
/// playback built has to be gone once it is closed and let go, or every
/// reopen stacks a whole pipeline on top of the last one.
final class ReopenReleaseTests: XCTestCase {
    private final class Weak {
        weak var object: AnyObject?
        init(_ object: AnyObject?) { self.object = object }
    }

    func testEveryReopenLetsTheLastPlaybackGo() throws {
        let url = try makeHDRFixture(
            directory: FileManager.default.temporaryDirectory, name: "reopen-pq.mp4",
            width: 320, height: 180, frameCount: 240, transfer: .pq, gopSize: 24
        )
        var released: [(String, Weak)] = []
        for round in 0..<3 {
            // One player screen: its own layer, sink and player, as the
            // bridge builds them, opened twice through a stream.
            let parent = CALayer()
            let layer = AVSampleBufferDisplayLayer()
            parent.addSublayer(layer)
            var sink: DisplayLayerSink? = DisplayLayerSink(layer: layer)
            // an SDR screen, so the HDR film takes the mapped path and its pools
            var player: LexisPlayer? = LexisPlayer(
                sink: try XCTUnwrap(sink), display: { DisplayCapability(headroom: 1) })
            released += [
                ("sink \(round)", Weak(sink)), ("layer \(round)", Weak(layer)), ("player \(round)", Weak(player)),
            ]
            let events = try XCTUnwrap(player).events
            var firstFrames = 0
            let lock = NSLock()
            let collector = Task {
                for await event in events {
                    if case .firstFrame = event { lock.withLock { firstFrames += 1 } }
                }
            }
            for open in 0..<2 {
                let handle = try XCTUnwrap(lexis_stream_open_file(url.path, nil))
                try XCTUnwrap(player).open(stream: coreStream(handle: handle))
                try XCTUnwrap(player).play()
                pollUntil("the first frame of open \(open) in round \(round)") {
                    lock.withLock { firstFrames > open }
                }
                // Read by label: they are the player's own, and what a reopen
                // must not leave behind.
                let held = Mirror(reflecting: try XCTUnwrap(player)).children
                for label in ["engine", "toneMapped", "demuxer"] {
                    let child = try XCTUnwrap(held.first { $0.label == label }?.value, "no \(label) in the player")
                    let object = try XCTUnwrap(Mirror(reflecting: child).children.first?.value, "\(label) is nil")
                    released.append(("\(label) of open \(open) in round \(round)", Weak(object as AnyObject)))
                }
                try XCTUnwrap(player).cancel()
                try XCTUnwrap(player).close()
                for (name, weak) in released where name.hasSuffix("of open \(open) in round \(round)") {
                    XCTAssertNil(weak.object, "\(name) outlived its close")
                }
            }
            collector.cancel()
            player = nil
            sink = nil
            layer.removeFromSuperlayer()
        }
        // The sink hands its last subtitle refresh to the main queue, which
        // holds it until that block has run.
        let deadline = Date(timeIntervalSinceNow: 5)
        while released.contains(where: { $0.1.object != nil }), Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        for (name, weak) in released {
            XCTAssertNil(weak.object, "\(name) outlived its player screen")
        }
    }
}

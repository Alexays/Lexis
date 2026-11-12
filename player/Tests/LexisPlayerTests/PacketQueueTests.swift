import Foundation
import XCTest
@testable import LexisPlayer

final class PacketQueueTests: XCTestCase {
    private func packet(dts: Int64, bytes: Int = 10, keyframe: Bool = true) -> Packet {
        Packet(
            streamIndex: 0, pts: dts, dts: dts, isKeyframe: keyframe, isDisposable: false,
            duration: 0, data: Data(repeating: 0, count: bytes)
        )
    }

    func testBufferedSecondsIsTheDtsSpan() {
        let queue = PacketQueue(timeBase: 1.0, configuration: .init(highWatermarkSeconds: 8.0, capacityBytes: 1 << 30))
        XCTAssertEqual(queue.bufferedSeconds, 0)
        XCTAssertTrue(queue.push(packet(dts: 10), generation: 0, interrupt: nil))
        XCTAssertEqual(queue.bufferedSeconds, 0)
        XCTAssertTrue(queue.push(packet(dts: 13), generation: 0, interrupt: nil))
        XCTAssertEqual(queue.bufferedSeconds, 3)
        XCTAssertTrue(queue.push(packet(dts: 15), generation: 0, interrupt: nil))
        XCTAssertEqual(queue.bufferedSeconds, 5)
    }

    func testPushParksAtTheHighWatermarkAndWakesOnTheFirstPop() {
        let configuration = PacketQueue.Configuration(
            highWatermarkSeconds: 4.0, capacityBytes: 1_000_000
        )
        let queue = PacketQueue(timeBase: 1.0, configuration: configuration)
        // one-second-apart packets so draining one at a time moves the span
        // by exactly one second: fills to exactly the high watermark, which
        // is where the next push must park.
        XCTAssertTrue(queue.push(packet(dts: 0), generation: 0, interrupt: nil))
        XCTAssertTrue(queue.push(packet(dts: 1), generation: 0, interrupt: nil))
        XCTAssertTrue(queue.push(packet(dts: 2), generation: 0, interrupt: nil))
        XCTAssertTrue(queue.push(packet(dts: 3), generation: 0, interrupt: nil))
        XCTAssertTrue(queue.push(packet(dts: 4), generation: 0, interrupt: nil))
        XCTAssertEqual(queue.bufferedSeconds, 4)

        let parked = expectation(description: "the pusher is parked")
        let pushed = expectation(description: "the pusher wakes and pushes")
        let thread = Thread {
            parked.fulfill()
            XCTAssertTrue(queue.push(self.packet(dts: 5), generation: 0, interrupt: nil))
            pushed.fulfill()
        }
        thread.start()
        wait(for: [parked], timeout: 1)
        // give the background push every chance to have wrongly gone through
        usleep(150_000)
        XCTAssertEqual(queue.bufferedSeconds, 4, "must not have pushed yet")

        // One pop is room for one packet, and that has to be enough to
        // release it: the demux thread this push holds is the only one
        // feeding every OTHER track too, so any deeper drain it holds out
        // for is a drought for all of them.
        _ = queue.pop(deadline: nil)
        wait(for: [pushed], timeout: 1)
        XCTAssertEqual(queue.bufferedSeconds, 4)
    }

    func testTheByteCeilingBoundsASecondsQueue() {
        // seconds alone would never trip (dts span stays 0), so only the byte
        // ceiling can be what parks the second push.
        let configuration = PacketQueue.Configuration(
            highWatermarkSeconds: 100, capacityBytes: 100
        )
        let queue = PacketQueue(timeBase: 1.0, configuration: configuration)
        XCTAssertTrue(queue.push(packet(dts: 0, bytes: 60), generation: 0, interrupt: nil))

        let parked = expectation(description: "the pusher is parked on bytes")
        let pushed = expectation(description: "the pusher wakes once bytes free up")
        let thread = Thread {
            parked.fulfill()
            XCTAssertTrue(queue.push(self.packet(dts: 0, bytes: 60), generation: 0, interrupt: nil))
            pushed.fulfill()
        }
        thread.start()
        wait(for: [parked], timeout: 1)
        usleep(150_000)
        XCTAssertEqual(queue.bufferedBytes, 60)

        _ = queue.pop(deadline: nil)
        wait(for: [pushed], timeout: 1)
        XCTAssertEqual(queue.bufferedBytes, 60)
    }

    func testFlushEmptiesAndUnparksThePusher() {
        let configuration = PacketQueue.Configuration(
            highWatermarkSeconds: 4.0, capacityBytes: 1_000_000
        )
        let queue = PacketQueue(timeBase: 1.0, configuration: configuration)
        XCTAssertTrue(queue.push(packet(dts: 0), generation: 0, interrupt: nil))
        XCTAssertTrue(queue.push(packet(dts: 4), generation: 0, interrupt: nil))

        let pushed = expectation(description: "flush wakes the parked pusher")
        let thread = Thread {
            XCTAssertTrue(queue.push(self.packet(dts: 5), generation: 0, interrupt: nil))
            pushed.fulfill()
        }
        thread.start()
        usleep(150_000)
        XCTAssertEqual(queue.bufferedBytes, 20, "must not have pushed yet")

        queue.flush()
        // the parked pusher races to fill the queue the instant flush wakes
        // it, so the only thing left to assert deterministically is that it
        // woke at all and its own packet is what the queue now holds.
        wait(for: [pushed], timeout: 1)
        XCTAssertEqual(queue.bufferedBytes, 10)
    }

    func testCloseDrainsThenAnswersNil() {
        let queue = PacketQueue(timeBase: 1.0, configuration: .init(highWatermarkSeconds: 8.0, capacityBytes: 1 << 30))
        XCTAssertTrue(queue.push(packet(dts: 0), generation: 0, interrupt: nil))
        XCTAssertTrue(queue.push(packet(dts: 1), generation: 0, interrupt: nil))
        queue.close()
        XCTAssertNotNil(queue.pop(deadline: nil))
        XCTAssertNotNil(queue.pop(deadline: nil))
        XCTAssertNil(queue.pop(deadline: nil))
        XCTAssertFalse(queue.push(packet(dts: 2), generation: 0, interrupt: nil))
    }

    func testInterruptUnparksABlockedPush() {
        let configuration = PacketQueue.Configuration(
            highWatermarkSeconds: 4.0, capacityBytes: 1_000_000
        )
        let queue = PacketQueue(timeBase: 1.0, configuration: configuration)
        XCTAssertTrue(queue.push(packet(dts: 0), generation: 0, interrupt: nil))
        XCTAssertTrue(queue.push(packet(dts: 4), generation: 0, interrupt: nil))

        let interrupt = InterruptFlag()
        let refused = expectation(description: "the interrupt unparks the pusher")
        let thread = Thread {
            XCTAssertFalse(queue.push(self.packet(dts: 5), generation: 0, interrupt: interrupt))
            refused.fulfill()
        }
        thread.start()
        usleep(150_000)
        // the parked push asks again when woken, which a stop's close does too
        interrupt.raise()
        queue.wake()
        wait(for: [refused], timeout: 1)
    }

    /// A pusher that abandoned its packet is not parked here any more, and
    /// this has to say so the instant it leaves. The engine reads it as "the
    /// one demux thread is held on this queue, so no track can be fed" and
    /// gives up on refilling a starved buffer on the strength of it: an audio
    /// track swapped to one with no decoder pushes nothing ever again, so a
    /// reading left standing by its last give-up would stand for the rest of
    /// the film, and every starvation after it would resume on whatever the
    /// picture happened to hold, empty included.
    func testAGiveUpStopsTheQueueHoldingTheDemuxThread() {
        let queue = PacketQueue(
            timeBase: 1.0, configuration: .init(highWatermarkSeconds: 4.0, capacityBytes: 1_000_000)
        )
        XCTAssertTrue(queue.push(packet(dts: 0), generation: 0, interrupt: nil))
        XCTAssertTrue(queue.push(packet(dts: 4), generation: 0, interrupt: nil))

        let abandon = NSLock()
        var giveUp = false
        let parked = expectation(description: "the pusher parks")
        let refused = expectation(description: "the pusher gives up")
        let thread = Thread {
            parked.fulfill()
            XCTAssertFalse(
                queue.push(self.packet(dts: 5), generation: 0, interrupt: nil) {
                    abandon.lock(); defer { abandon.unlock() }
                    return giveUp
                }
            )
            refused.fulfill()
        }
        thread.start()
        wait(for: [parked], timeout: 1)
        usleep(150_000)
        XCTAssertTrue(queue.isHoldingTheDemuxThread, "it really is parked")

        abandon.lock(); giveUp = true; abandon.unlock()
        queue.wake()
        wait(for: [refused], timeout: 1)
        XCTAssertFalse(queue.isHoldingTheDemuxThread)
    }

    /// Seconds per pop for a queue held `depth` packets deep, drained
    /// `drains` times over. Only the pops are timed, and nothing inside the
    /// timed loop touches XCTest: an assertion per pop costs microseconds
    /// and would swamp what this measures.
    private func secondsPerPop(depth: Int, drains: Int) -> Double {
        // A microsecond time base keeps `depth` packets well inside the high
        // watermark, so the drain measures popping and nothing else.
        let queue = PacketQueue(
            timeBase: 1.0 / 1_000_000,
            configuration: .init(highWatermarkSeconds: 8.0, capacityBytes: 90_000_000)
        )
        var pushed = 0
        var popped = 0
        var elapsed = 0.0
        for _ in 0..<drains {
            for index in 0..<depth {
                if queue.push(packet(dts: Int64(index)), generation: 0, interrupt: nil) { pushed += 1 }
            }
            let started = Date()
            for _ in 0..<depth {
                if queue.pop(deadline: nil) != nil { popped += 1 }
            }
            elapsed += Date().timeIntervalSince(started)
        }
        XCTAssertEqual(pushed, depth * drains)
        XCTAssertEqual(popped, depth * drains)
        return elapsed / Double(depth * drains)
    }

    /// A pop costs the same whether the queue is a thousand packets deep or
    /// twenty thousand. TrueHD hands its queue about a thousand
    /// one-millisecond packets per second of content, so the queue runs
    /// thousands deep all through a film - and a pop that shifts every
    /// remaining packet down one spends the whole depth of the buffer on
    /// each of them, holding the lock the demux thread's own pushes wait
    /// behind. Measured as a ratio, not a wall time, so the assertion says
    /// the same thing on a fast machine and a slow one.
    func testPopCostsTheSameHoweverDeepTheQueueIs() {
        let shallow = secondsPerPop(depth: 1_000, drains: 180)
        let deep = secondsPerPop(depth: 20_000, drains: 9)
        XCTAssertLessThan(
            deep, shallow * 4,
            "a pop twenty times deeper in the queue cost \(deep / shallow) times as much"
        )
    }
}

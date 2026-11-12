import AVFoundation
import LexisTestSupport
import XCTest
@testable import LexisPlayer

/// Seeded, so a damaged file that breaks something is the same file on the
/// next run.
private struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func below(_ bound: Int) -> Int {
        Int(next() % UInt64(bound))
    }
}

/// Every way a file is damaged here, applied to `bytes`: cut short, bytes
/// flipped at random, a run zeroed, the head garbled, two runs swapped.
private func damaged(_ bytes: Data, seed: UInt64) -> [(String, Data)] {
    var random = SplitMix64(state: seed)
    var cases: [(String, Data)] = [("empty", Data()), ("one byte", bytes.prefix(1))]
    for percent in [5, 30, 60, 95] {
        cases.append(("cut at \(percent)%", bytes.prefix(bytes.count * percent / 100)))
    }
    for (label, flips) in [("sparse flips", 8), ("dense flips", 400)] {
        var copy = bytes
        for _ in 0..<flips {
            copy[random.below(copy.count)] ^= UInt8(1 + random.below(255))
        }
        cases.append((label, copy))
    }
    for (label, from) in [("head flips", 0), ("tail flips", bytes.count * 3 / 4)] {
        var copy = bytes
        for _ in 0..<64 {
            copy[from + random.below(min(1024, copy.count - from))] ^= UInt8(1 + random.below(255))
        }
        cases.append((label, copy))
    }
    var zeroed = bytes
    let run = min(4096, bytes.count / 4)
    zeroed.replaceSubrange((bytes.count / 2)..<(bytes.count / 2 + run), with: Data(count: run))
    cases.append(("zeroed run", zeroed))
    var garbled = bytes
    for index in 0..<min(512, garbled.count) { garbled[index] = UInt8(random.below(256)) }
    cases.append(("garbled head", garbled))
    var swapped = bytes
    let chunk = min(2048, bytes.count / 8)
    let first = bytes.count / 4, second = bytes.count / 2
    swapped.replaceSubrange(first..<(first + chunk), with: bytes[second..<(second + chunk)])
    swapped.replaceSubrange(second..<(second + chunk), with: bytes[first..<(first + chunk)])
    cases.append(("swapped runs", swapped))
    return cases
}

final class CorruptFileTests: XCTestCase {
    private var directory: URL { FileManager.default.temporaryDirectory }

    /// An HEVC fixture whose video packets at `indices`, in decode order, are
    /// overwritten with 0xFF in place: their lengths are kept, so the sample
    /// table still describes the file and only those pictures rot.
    private func garblingVideoPackets(at indices: Set<Int>, name: String) throws -> URL {
        let url = try makeVideoFixture(
            directory: directory, name: "\(name).source.mp4", codec: .hevc,
            width: 320, height: 240, frameCount: 24, fps: 24, gopSize: 12
        )
        let demuxer = try Demuxer(url: url)
        let video = try XCTUnwrap(demuxer.streams.first { $0.kind == .video })
        var bytes = try Data(contentsOf: url)
        // packets come out in the order they are stored, so the cursor
        // never goes back and a repeated picture is found where it sits
        var cursor = bytes.startIndex
        var index = 0
        while let packet = try demuxer.readPacket() {
            guard packet.streamIndex == video.index else { continue }
            let range = try XCTUnwrap(bytes.range(of: packet.copiedBytes, in: cursor..<bytes.endIndex))
            cursor = range.upperBound
            if indices.contains(index) {
                bytes.replaceSubrange(range, with: Data(repeating: 0xFF, count: range.count))
            }
            index += 1
        }
        let damaged = directory.appendingPathComponent(name)
        try bytes.write(to: damaged)
        return damaged
    }

    private func play(_ url: URL) throws -> (events: [PlayerEvent], player: LexisPlayer, sink: CountingSink) {
        let sink = CountingSink()
        let player = LexisPlayer(sink: sink)
        let log = EventLog()
        let settled = expectation(description: "settled")
        settled.assertForOverFulfill = false
        let collector = Task {
            for await event in player.events {
                log.append(event)
                switch event {
                case .endOfStream, .failed: settled.fulfill()
                default: break
                }
            }
        }
        try player.open(url: url)
        player.play()
        wait(for: [settled], timeout: 20)
        collector.cancel()
        return (log.all, player, sink)
    }

    func testADamagedFrameCostsThePicturesUpToTheNextKeyframeAndNothingMore() throws {
        // the fourth picture of the first twelve: the rest of that group leans
        // on it, the second group starts on a keyframe of its own
        let (events, player, sink) = try play(
            garblingVideoPackets(at: [3], name: "corrupt-one-frame.mp4"))
        XCTAssertEqual(events.last, .endOfStream)
        XCTAssertGreaterThan(player.stats.decodeFailures, 0)
        XCTAssertGreaterThanOrEqual(sink.count, 15, "the first three pictures and the whole second group")
        XCTAssertLessThan(sink.count, 24)
        player.close()
    }

    func testAFilmThatDecodesNoPictureStillFails() throws {
        let (events, player, sink) = try play(
            garblingVideoPackets(at: Set(0..<24), name: "corrupt-every-frame.mp4"))
        guard case .failed = events.last else {
            return XCTFail("a film with no picture at all ended as \(String(describing: events.last))")
        }
        XCTAssertEqual(sink.count, 0)
        player.close()
    }

    /// The healthy files every damage is applied to, and the headers no
    /// muxer writes, each in a file of its own.
    private func corpus() throws -> [(String, Data)] {
        var files: [(String, Data)] = []
        for (codec, label) in [(AVVideoCodecType.hevc, "hevc mp4"), (.h264, "h264 mp4")] {
            let url = try makeVideoFixture(
                directory: directory, name: "corrupt-\(label).mp4", codec: codec,
                width: 320, height: 240, frameCount: 24, fps: 24, audio: true
            )
            for (damage, bytes) in damaged(try Data(contentsOf: url), seed: 0x1E415) {
                files.append(("\(label), \(damage)", bytes))
            }
        }
        let inBand = try makeHEVCMatroskaFixture(
            directory: directory, name: "corrupt-in-band.mkv",
            header: { $0.prefix(22) + [0] }, keyframe: { sets, packet in sets + packet }
        )
        for (damage, bytes) in damaged(try Data(contentsOf: inBand.url), seed: 0x5E75) {
            files.append(("in-band mkv, \(damage)", bytes))
        }
        let headers: [(String, (Data) -> Data, (Data, Data) -> Data)] = [
            ("bare hvcC, no set in band", { $0.prefix(22) + [0] }, { _, packet in packet }),
            ("bare hvcC, sets cut short", { $0.prefix(22) + [0] }, { sets, packet in sets.prefix(sets.count / 2) + packet }),
            ("bare hvcC, a length past the packet", { $0.prefix(22) + [0] },
             { _, packet in Data([0x7F, 0xFF, 0xFF, 0xFF]) + packet }),
            ("bare hvcC, a zero length", { $0.prefix(22) + [0] }, { sets, packet in Data(count: 4) + sets + packet }),
            ("bare hvcC, one byte lengths", { var record = $0.prefix(22) + [0]; record[21] &= 0xFC; return record },
             { sets, packet in sets + packet }),
            ("hvcC naming arrays it lacks", { $0.prefix(22) + [3] }, { sets, packet in sets + packet }),
            ("hvcC cut mid array", { $0.prefix(26) }, { sets, packet in sets + packet }),
            ("hvcC too short to read", { $0.prefix(12) }, { sets, packet in sets + packet }),
            ("hvcC of another version", { var record = $0; record[0] = 7; return record }, { _, packet in packet }),
        ]
        for (label, header, keyframe) in headers {
            let made = try makeHEVCMatroskaFixture(
                directory: directory, name: "corrupt-\(label).mkv", header: header, keyframe: keyframe
            )
            files.append((label, try Data(contentsOf: made.url)))
        }
        return files
    }

    /// The contract with a damaged file: the open refuses it, or playback
    /// ends, failed or not. Nothing crashes, and nothing waits forever.
    func testEveryDamagedFileIsRefusedOrPlaysToAnEnd() throws {
        for (index, (label, bytes)) in try corpus().enumerated() {
            let url = directory.appendingPathComponent("corrupt-play-\(index).bin")
            try bytes.write(to: url)
            let player = LexisPlayer(sink: CountingSink())
            let settled = expectation(description: label)
            settled.assertForOverFulfill = false
            let collector = Task {
                for await event in player.events {
                    switch event {
                    case .endOfStream, .failed, .unauthorized, .tooLargeForMemory: settled.fulfill()
                    default: break
                    }
                }
            }
            // off the test's thread, so an open that never returns is a
            // timeout below rather than a suite that never ends
            DispatchQueue.global().async {
                do {
                    try player.open(url: url)
                    player.play()
                } catch {
                    settled.fulfill()
                }
            }
            if XCTWaiter().wait(for: [settled], timeout: 15) != .completed {
                XCTFail("\(label): neither refused nor ended")
            }
            collector.cancel()
            player.close()
        }
    }

    /// The decoders the player hands every packet to on the paths this sink
    /// never takes: each packet of a damaged file is decoded or refused.
    func testEveryDamagedFileIsDecodedOrRefusedPacketByPacket() throws {
        for (index, (label, bytes)) in try corpus().enumerated() {
            let url = directory.appendingPathComponent("corrupt-decode-\(index).bin")
            try bytes.write(to: url)
            guard let demuxer = try? Demuxer(url: url) else { continue }
            let video = demuxer.streams.first { $0.kind == .video }
            let audio = demuxer.streams.first { $0.kind == .audio }
            let hardware = video.flatMap { stream in
                (try? makeFormatDescription(for: stream)).flatMap { description in
                    (try? VideoDecoder(formatDescription: description) { _ in }).map { ($0, description) }
                }
            }
            let software = video.flatMap {
                try? SoftwareVideoDecoder(stream: $0, threadCount: 2, poolCeilingBytes: 1 << 28)
            }
            let sound = audio.flatMap { try? AudioDecoder(stream: $0) }
            var packets = 0
            while let packet = try? demuxer.readPacket() {
                packets += 1
                XCTAssertLessThan(packets, 100_000, "\(label): the demuxer never reaches the end")
                if packets >= 100_000 { break }
                if let video, packet.streamIndex == video.index {
                    if let (decoder, description) = hardware,
                        let sample = try? makeSampleBuffer(
                            packet: packet, formatDescription: description,
                            timeBaseNum: video.timeBaseNum, timeBaseDen: video.timeBaseDen)
                    {
                        try? decoder.decode(sample)
                    }
                    _ = try? software?.decode(packet)
                } else if let audio, packet.streamIndex == audio.index {
                    _ = try? sound?.decode(packet)
                }
            }
            hardware?.0.waitForPendingFrames()
            _ = try? software?.drainAtEndOfStream()
        }
    }
}

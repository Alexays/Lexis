import CoreMedia
import LexisTestSupport
import XCTest
@testable import LexisPlayer

final class DemuxerTests: XCTestCase {
    func testDescribesTheVideoStream() throws {
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "demux-hevc.mp4",
            codec: .hevc, width: 320, height: 240, frameCount: 48, fps: 24
        )
        let demuxer = try Demuxer(url: url)
        XCTAssertEqual(demuxer.streams.count, 1)
        let video = demuxer.streams[0]
        XCTAssertEqual(video.index, 0)
        XCTAssertEqual(video.kind, .video)
        XCTAssertEqual(video.codecName, "hevc")
        XCTAssertEqual(video.width, 320)
        XCTAssertEqual(video.height, 240)
        XCTAssertEqual(video.timeBaseNum, 1)
        XCTAssertGreaterThan(video.timeBaseDen, 0)
        // hvcC, whose first byte is the configurationVersion
        XCTAssertGreaterThan(try XCTUnwrap(video.extradata).count, 20)
        XCTAssertEqual(try XCTUnwrap(video.extradata).first, 1)
    }

    func testReadsEveryPacketInDecodeOrder() throws {
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "demux-packets.mp4",
            codec: .hevc, width: 320, height: 240, frameCount: 48, fps: 24
        )
        let demuxer = try Demuxer(url: url)
        let video = demuxer.streams[0]
        var count = 0
        var keyframes = 0
        var bytes = 0
        // the first dts is negative when the encoder reorders, so start below it
        var previousDTS = Int64.min
        while let packet = try demuxer.readPacket() {
            XCTAssertEqual(packet.streamIndex, video.index)
            XCTAssertNotNil(packet.pts)
            let dts = try XCTUnwrap(packet.dts)
            XCTAssertGreaterThan(dts, previousDTS)
            previousDTS = dts
            count += 1
            bytes += packet.copiedBytes.count
            if packet.isKeyframe { keyframes += 1 }
        }
        XCTAssertEqual(count, 48)
        XCTAssertGreaterThanOrEqual(keyframes, 1)
        XCTAssertGreaterThan(bytes, 1000)
        XCTAssertNil(try demuxer.readPacket())
    }

    func testMissingFileReportsTheAverror() {
        XCTAssertThrowsError(try Demuxer(url: URL(fileURLWithPath: "/nope/missing.mp4"))) { error in
            guard case .openFailed(let code, let message)? = error as? DemuxError else {
                return XCTFail("wrong error \(error)")
            }
            XCTAssertLessThan(code, 0)
            XCTAssertEqual(message, "No such file or directory")
        }
    }

    func testDescribesAnAudioStreamAndTheDuration() throws {
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "demux-av.mp4",
            codec: .h264, width: 320, height: 240, frameCount: 96, fps: 24, audio: true
        )
        let demuxer = try Demuxer(url: url)
        XCTAssertEqual(demuxer.streams.count, 2)
        XCTAssertEqual(demuxer.duration, 4.0, accuracy: 0.2)

        let video = try XCTUnwrap(demuxer.streams.first { $0.kind == .video })
        XCTAssertEqual(video.sampleRate, 0)
        XCTAssertEqual(video.channels, 0)

        let audio = try XCTUnwrap(demuxer.streams.first { $0.kind == .audio })
        XCTAssertEqual(audio.codecName, "aac")
        XCTAssertEqual(audio.sampleRate, 48000)
        XCTAssertEqual(audio.channels, 2)
        XCTAssertEqual(audio.timeBaseNum, 1)
        XCTAssertEqual(audio.timeBaseDen, 48000)
        // the AudioSpecificConfig, which the decoder needs
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(audio.extradata).count, 2)

        var audioPackets = 0
        var videoPackets = 0
        while let packet = try demuxer.readPacket() {
            if packet.streamIndex == audio.index { audioPackets += 1 } else { videoPackets += 1 }
        }
        XCTAssertEqual(videoPackets, 96)
        // 4 s of 48 kHz in frames of 1024 samples, give or take the encoder's
        // priming frame
        XCTAssertGreaterThan(audioPackets, 180)
    }

    func testDescribesEveryTrackOfAMatroskaFile() throws {
        let url = try makeSubtitleFixture(
            directory: FileManager.default.temporaryDirectory, name: "demux-tracks.mkv"
        )
        let demuxer = try Demuxer(url: url)

        let video = try XCTUnwrap(demuxer.streams.first { $0.kind == .video })
        // the fixture tags the picture "und", which FFmpeg drops rather than
        // carries: an undefined language is no language
        XCTAssertEqual(video.language, "")
        XCTAssertTrue(video.isDefault)
        XCTAssertFalse(video.isForced)

        let audio = demuxer.streams.filter { $0.kind == .audio }
        XCTAssertEqual(audio.map(\.language), ["fre", "eng"])
        XCTAssertEqual(audio.map(\.title), ["VF", "VO"])
        XCTAssertEqual(audio.map(\.isDefault), [true, false])

        let subtitles = demuxer.streams.filter { $0.kind == .subtitle }
        XCTAssertEqual(subtitles.map(\.language), ["fre", "eng", "eng"])
        XCTAssertEqual(subtitles.map(\.title), ["Forces", "SDH", "Bitmap"])
        XCTAssertEqual(subtitles.map(\.codecName), ["ass", "subrip", "hdmv_pgs_subtitle"])
        XCTAssertEqual(subtitles.map(\.isForced), [true, false, false])

        // a subtitle packet lasts as long as the container says, which is the
        // only thing that ever takes a line back off the screen
        var durations: [Int32: [Int64]] = [:]
        while let packet = try demuxer.readPacket() {
            guard packet.streamIndex >= 3 else { continue }
            durations[packet.streamIndex, default: []].append(packet.duration)
        }
        XCTAssertEqual(durations[3], [2000, 800])
        XCTAssertEqual(durations[4], [1000])
        XCTAssertEqual(durations[5], [1500])
    }

    func testAnUntaggedMatroskaTrackReadsAsEnglish() throws {
        // Matroska's own default is eng, and FFmpeg applies it when the track
        // carries no Language element: only an explicit "und" reads empty.
        let url = try makeMatroskaFixture(
            directory: FileManager.default.temporaryDirectory, name: "demux-untagged.mkv",
            tracks: [MatroskaTrack(number: 1, kind: .subtitle, codecID: "S_TEXT/UTF8")],
            frames: [MatroskaFrame(
                track: 1, milliseconds: 0, durationMilliseconds: 1000, isKeyframe: true,
                data: Data("Untagged".utf8)
            )],
            durationMilliseconds: 1000, cueTrack: 1
        )
        let demuxer = try Demuxer(url: url)
        XCTAssertEqual(demuxer.streams.map(\.language), ["eng"])
    }

    func testAMatroskaFrameRateRoundedToTheNanosecondReadsAsItsExactRate() throws {
        // 41708000 ns is 23.976 rounded to the microsecond, as muxers write it:
        // a frame grid on anything but 24000/1001 drifts off the timestamps.
        let url = try makeMatroskaFixture(
            directory: FileManager.default.temporaryDirectory, name: "demux-ntsc-rate.mkv",
            tracks: [MatroskaTrack(
                number: 1, kind: .video, codecID: "V_VP9", width: 320, height: 240,
                defaultDurationNanoseconds: 41_708_000
            )],
            frames: (0..<4).map {
                MatroskaFrame(track: 1, milliseconds: $0 * 42, isKeyframe: $0 == 0, data: Data([0, 0, 0, 0]))
            },
            durationMilliseconds: 168, cueTrack: 1
        )
        let stream = try XCTUnwrap(Demuxer(url: url).streams.first)
        XCTAssertEqual(stream.frameRateNum, 24000)
        XCTAssertEqual(stream.frameRateDen, 1001)
    }

    func testChaptersFromAChapteredMatroskaFile() throws {
        let url = try makeMatroskaFixture(
            directory: FileManager.default.temporaryDirectory, name: "demux-chapters.mkv",
            tracks: [MatroskaTrack(number: 1, kind: .subtitle, codecID: "S_TEXT/UTF8")],
            frames: [MatroskaFrame(
                track: 1, milliseconds: 0, durationMilliseconds: 1000, isKeyframe: true,
                data: Data("marker".utf8)
            )],
            durationMilliseconds: 20_000, cueTrack: 1,
            chapters: [
                MatroskaChapter(uid: 1, startMilliseconds: 0, title: "Intro"),
                MatroskaChapter(uid: 2, startMilliseconds: 5000, title: "Chapter Two"),
                MatroskaChapter(uid: 3, startMilliseconds: 12_000, title: "Finale"),
            ]
        )
        let demuxer = try Demuxer(url: url)
        XCTAssertEqual(demuxer.chapters.map(\.start), [0, 5, 12])
        XCTAssertEqual(demuxer.chapters.map(\.title), ["Intro", "Chapter Two", "Finale"])
    }

    func testAFileWithNoChaptersReadsAnEmptyList() throws {
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "demux-no-chapters.mp4",
            codec: .h264, width: 320, height: 240, frameCount: 24, fps: 24
        )
        let demuxer = try Demuxer(url: url)
        XCTAssertEqual(demuxer.chapters, [])
    }
}

/// The rules a packet's bytes are held by now that they are FFmpeg's own
/// buffer and not a copy of it. Both of these are memory safety, not
/// performance: the first says nothing is copied, the second says what
/// depends on that copy not happening survives.
final class PacketOwnershipTests: XCTestCase {
    private func firstPacket(named name: String) throws -> (Demuxer, Packet, MediaStream) {
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: name,
            codec: .hevc, width: 320, height: 240, frameCount: 24, fps: 24
        )
        let demuxer = try Demuxer(url: url)
        let stream = try XCTUnwrap(demuxer.streams.first { $0.kind == .video })
        let packet = try XCTUnwrap(try demuxer.readPacket())
        return (demuxer, packet, stream)
    }

    private func dataPointer(of sample: CMSampleBuffer) throws -> UnsafeRawPointer {
        let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample))
        var lengthAtOffset = 0
        var totalLength = 0
        var pointer: UnsafeMutablePointer<Int8>?
        XCTAssertEqual(
            CMBlockBufferGetDataPointer(
                block, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset,
                totalLengthOut: &totalLength, dataPointerOut: &pointer),
            noErr)
        return UnsafeRawPointer(try XCTUnwrap(pointer))
    }

    /// The sample the sink is handed is built over the packet's own bytes.
    /// Same address, not the same contents: equal contents is what a copy
    /// would also give, and a copy is the thing this is here to catch.
    func testASampleIsBuiltOverThePacketsOwnBytesRatherThanACopyOfThem() throws {
        let (demuxer, packet, stream) = try firstPacket(named: "packet-zerocopy.mp4")
        let format = try makeFormatDescription(for: stream)
        let source = packet.withUnsafeBytes { UnsafeRawPointer($0.baseAddress!) }
        let sample = try makeSampleBuffer(
            packet: packet, formatDescription: format,
            timeBaseNum: stream.timeBaseNum, timeBaseDen: stream.timeBaseDen)
        XCTAssertEqual(try dataPointer(of: sample), source)
        withExtendedLifetime(demuxer) {}
    }

    /// And it keeps them. A sink holds samples long after the demux thread
    /// has moved past the packet and, on a close, past the demuxer itself -
    /// so the block buffer's reference has to be what keeps the bytes alive,
    /// or this reads freed memory.
    func testASampleOutlivesBothThePacketAndTheDemuxerItCameFrom() throws {
        var sample: CMSampleBuffer?
        var expected = Data()
        do {
            let (demuxer, packet, stream) = try firstPacket(named: "packet-outlives.mp4")
            expected = packet.copiedBytes
            sample = try makeSampleBuffer(
                packet: packet, formatDescription: try makeFormatDescription(for: stream),
                timeBaseNum: stream.timeBaseNum, timeBaseDen: stream.timeBaseDen)
            withExtendedLifetime(demuxer) {}
        }
        let held = try XCTUnwrap(sample)
        let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(held))
        var bytes = [UInt8](repeating: 0, count: expected.count)
        XCTAssertEqual(
            CMBlockBufferCopyDataBytes(
                block, atOffset: 0, dataLength: expected.count, destination: &bytes),
            noErr)
        XCTAssertGreaterThan(expected.count, 0)
        XCTAssertEqual(Data(bytes), expected)
    }
}

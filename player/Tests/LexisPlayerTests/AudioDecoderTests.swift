import AVFoundation
import CFFmpeg
import CoreMedia
import LexisTestSupport
import XCTest
@testable import LexisPlayer

final class AudioDecoderTests: XCTestCase {
    private func fixture(_ name: String) throws -> URL {
        try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: name,
            codec: .h264, width: 320, height: 240, frameCount: 96, fps: 24, audio: true
        )
    }

    func testDecodesTheWholeTrackToInterleavedFloat() throws {
        let demuxer = try Demuxer(url: try fixture("audio-decode.mp4"))
        let stream = try XCTUnwrap(demuxer.streams.first { $0.kind == .audio })
        let decoder = try AudioDecoder(stream: stream)

        var buffers: [CMSampleBuffer] = []
        while let packet = try demuxer.readPacket() {
            guard packet.streamIndex == stream.index else { continue }
            buffers.append(contentsOf: try decoder.decode(packet))
        }
        XCTAssertGreaterThan(buffers.count, 150)
        XCTAssertEqual(decoder.outputSampleRate, 48000)
        XCTAssertEqual(decoder.outputChannels, 2)

        let format = try XCTUnwrap(decoder.outputFormat)
        let asbd = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee)
        XCTAssertEqual(asbd.mFormatID, kAudioFormatLinearPCM)
        XCTAssertEqual(asbd.mSampleRate, 48000)
        XCTAssertEqual(asbd.mChannelsPerFrame, 2)
        XCTAssertEqual(asbd.mBytesPerFrame, 8)
        XCTAssertNotEqual(asbd.mFormatFlags & kAudioFormatFlagIsFloat, 0)

        // 4 s of 48 kHz, plus the two frames of priming and padding the AAC
        // encoder puts at the ends: 4.053 s, measured
        let samples = buffers.reduce(0) { $0 + CMSampleBufferGetNumSamples($1) }
        XCTAssertEqual(Double(samples) / 48000, 4.05, accuracy: 0.1)

        // presentation times climb, and the first one is at the head of the
        // stream: the encoder's priming makes it slightly negative, never late
        var previous = CMTime.negativeInfinity
        for buffer in buffers {
            let stamp = CMSampleBufferGetPresentationTimeStamp(buffer)
            XCTAssertTrue(stamp.isValid)
            XCTAssertGreaterThan(stamp, previous)
            previous = stamp
        }
        XCTAssertLessThan(CMSampleBufferGetPresentationTimeStamp(buffers[0]).seconds, 0.05)
        XCTAssertEqual(previous.seconds, 4.0, accuracy: 0.1)
    }

    func testFlushingKeepsTheDecoderUsable() throws {
        let demuxer = try Demuxer(url: try fixture("audio-flush.mp4"))
        let stream = try XCTUnwrap(demuxer.streams.first { $0.kind == .audio })
        let decoder = try AudioDecoder(stream: stream)
        var before = 0
        for _ in 0..<20 {
            guard let packet = try demuxer.readPacket() else { break }
            guard packet.streamIndex == stream.index else { continue }
            before += try decoder.decode(packet).count
        }
        XCTAssertGreaterThan(before, 0)

        decoder.flush()

        var after = 0
        while let packet = try demuxer.readPacket() {
            guard packet.streamIndex == stream.index else { continue }
            after += try decoder.decode(packet).count
        }
        XCTAssertGreaterThan(after, 0)
    }

    func testDrainingAtTheEndLeavesTheDecoderUsableAfterASeek() throws {
        let demuxer = try Demuxer(url: try fixture("audio-drain.mp4"))
        let stream = try XCTUnwrap(demuxer.streams.first { $0.kind == .audio })
        let decoder = try AudioDecoder(stream: stream)
        while let packet = try demuxer.readPacket() {
            guard packet.streamIndex == stream.index else { continue }
            _ = try decoder.decode(packet)
        }
        // whatever it held comes out once, and a second drain has nothing
        _ = try decoder.drain()
        XCTAssertTrue(try decoder.drain().isEmpty)

        // a packet after the drain starts the decoder over, even with no
        // flush between the two
        try demuxer.seek(to: 0)
        var after = 0
        while let packet = try demuxer.readPacket() {
            guard packet.streamIndex == stream.index else { continue }
            after += try decoder.decode(packet).count
        }
        XCTAssertGreaterThan(after, 150)
    }

    func testAnEmptyPacketLeavesTheDecoderRunning() throws {
        let demuxer = try Demuxer(url: try fixture("audio-empty-packet.mp4"))
        let stream = try XCTUnwrap(demuxer.streams.first { $0.kind == .audio })
        let decoder = try AudioDecoder(stream: stream)
        // av_read_frame can hand back a zero-length packet; sent as is it is
        // the drain signal, and every packet after it fails with EOF
        let empty = Packet(
            streamIndex: stream.index, pts: 0, dts: 0, isKeyframe: false,
            isDisposable: false, duration: 0, data: Data()
        )
        XCTAssertEqual(try decoder.decode(empty).count, 0)

        var buffers = 0
        while let packet = try demuxer.readPacket() {
            guard packet.streamIndex == stream.index else { continue }
            buffers += try decoder.decode(packet).count
        }
        XCTAssertGreaterThan(buffers, 150)
    }

    /// The ADTS header carries the config that an mp4 keeps in extradata, so
    /// wrapping the packets of two files makes one stream that changes config
    /// halfway, which no single mp4 can express.
    private func adtsFrame(_ payload: Data, channels: UInt8) -> Data {
        let length = payload.count + 7
        var header = Data(count: 7)
        header[0] = 0xFF
        header[1] = 0xF1
        // AAC LC, 48 kHz, then the channel configuration across the two bytes
        header[2] = (1 << 6) | (3 << 2) | (channels >> 2)
        header[3] = ((channels & 3) << 6) | UInt8((length >> 11) & 3)
        header[4] = UInt8((length >> 3) & 0xFF)
        header[5] = UInt8((length & 7) << 5) | 0x1F
        header[6] = 0xFC
        return header + payload
    }

    func testAChannelChangeMidStreamRebuildsTheOutputFormat() throws {
        var elementary = Data()
        for (name, channels) in [("audio-stereo.mp4", UInt8(2)), ("audio-mono.mp4", UInt8(1))] {
            let source = try makeVideoFixture(
                directory: FileManager.default.temporaryDirectory, name: name,
                codec: .h264, width: 320, height: 240, frameCount: 48, fps: 24,
                audio: true, channels: Int(channels)
            )
            let demuxer = try Demuxer(url: source)
            let stream = try XCTUnwrap(demuxer.streams.first { $0.kind == .audio })
            while let packet = try demuxer.readPacket() {
                guard packet.streamIndex == stream.index else { continue }
                elementary.append(adtsFrame(packet.copiedBytes, channels: channels))
            }
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-relayout.aac")
        try elementary.write(to: url)

        let demuxer = try Demuxer(url: url)
        let stream = try XCTUnwrap(demuxer.streams.first { $0.kind == .audio })
        let decoder = try AudioDecoder(stream: stream)
        var widths: [UInt32] = []
        while let packet = try demuxer.readPacket() {
            for buffer in try decoder.decode(packet) {
                let format = try XCTUnwrap(CMSampleBufferGetFormatDescription(buffer))
                let asbd = try XCTUnwrap(
                    CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee
                )
                if widths.last != asbd.mChannelsPerFrame {
                    widths.append(asbd.mChannelsPerFrame)
                }
            }
        }
        XCTAssertEqual(widths, [2, 1])
        XCTAssertEqual(decoder.outputChannels, 1)
    }

    func testAStreamWithNoDecoderIsRefused() {
        let stream = MediaStream(
            index: 0, kind: .audio, codecID: 0, codecName: "none",
            width: 0, height: 0, timeBaseNum: 1, timeBaseDen: 48000,
            sampleRate: 48000, channels: 2, videoDelay: 0, language: "", title: "",
            isDefault: true, isForced: false,
            colorPrimaries: 2, colorTransfer: 2, colorMatrix: 2, isFullRange: false,
            masteringDisplay: nil, contentLight: nil, dolbyVision: nil, extradata: nil
        )
        XCTAssertThrowsError(try AudioDecoder(stream: stream)) { error in
            XCTAssertEqual(error as? AudioDecodeError, .decoderUnavailable("none"))
        }
    }

    /// An .mkv stamps in whole milliseconds and an AAC frame at 48 kHz lasts
    /// 21.3333 ms, so no frame after the first starts where the container
    /// says it does. Reading each buffer's start off those stamps leaves
    /// every frame overlapping its neighbour by a third of a millisecond or
    /// gapping away from it by two thirds, forty-seven times a second, which
    /// the renderer plays as a crackle.
    func testBuffersRunContiguousThroughAMillisecondTimebase() throws {
        let demuxer = try Demuxer(url: try millisecondStampedFixture("audio-contiguous"))
        let stream = try XCTUnwrap(demuxer.streams.first { $0.kind == .audio })
        let decoder = try AudioDecoder(stream: stream)

        var buffers: [CMSampleBuffer] = []
        while let packet = try demuxer.readPacket() {
            guard packet.streamIndex == stream.index else { continue }
            buffers.append(contentsOf: try decoder.decode(packet))
        }
        XCTAssertGreaterThan(buffers.count, 20)
        XCTAssertEqual(decoder.outputSampleRate, 48000)

        let rate = Double(decoder.outputSampleRate)
        for (previous, next) in zip(buffers, buffers.dropFirst()) {
            let ends = CMSampleBufferGetPresentationTimeStamp(previous).seconds
                + Double(CMSampleBufferGetNumSamples(previous)) / rate
            XCTAssertEqual(
                CMSampleBufferGetPresentationTimeStamp(next).seconds, ends,
                accuracy: 1 / rate
            )
        }
    }

    /// The same track the mp4 fixture carries, remuxed into a container that
    /// stamps in milliseconds. The video track rides along because a cue
    /// track of audio alone would open a cluster on every frame.
    private func millisecondStampedFixture(_ name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
        let source = try makeVideoFixture(
            directory: directory, name: "\(name).source.mp4", codec: .h264,
            width: 320, height: 180, frameCount: 96, fps: 24, audio: true
        )
        let demuxer = try Demuxer(url: source)
        let video = try XCTUnwrap(demuxer.streams.first { $0.kind == .video })
        let audio = try XCTUnwrap(demuxer.streams.first { $0.kind == .audio })
        func stamp(_ ticks: Int64, _ stream: MediaStream) -> Int {
            let seconds = Double(ticks) * Double(stream.timeBaseNum) / Double(stream.timeBaseDen)
            return Int((seconds * 1000).rounded())
        }
        var frames: [MatroskaFrame] = []
        while let packet = try demuxer.readPacket() {
            if packet.streamIndex == video.index {
                frames.append(MatroskaFrame(
                    track: 1, milliseconds: stamp(packet.pts ?? packet.dts ?? 0, video),
                    decodeMilliseconds: stamp(packet.dts ?? packet.pts ?? 0, video),
                    isKeyframe: packet.isKeyframe, data: packet.copiedBytes
                ))
            } else if packet.streamIndex == audio.index {
                let milliseconds = stamp(packet.pts ?? packet.dts ?? 0, audio)
                guard milliseconds >= 0 else { continue }
                frames.append(MatroskaFrame(
                    track: 2, milliseconds: milliseconds, isKeyframe: true,
                    data: packet.copiedBytes
                ))
            }
        }
        return try makeMatroskaFixture(
            directory: directory, name: name,
            tracks: [
                MatroskaTrack(
                    number: 1, kind: .video, codecID: "V_MPEG4/ISO/AVC",
                    codecPrivate: video.extradata, width: 320, height: 180, language: "und"
                ),
                MatroskaTrack(
                    number: 2, kind: .audio, codecID: "A_AAC",
                    codecPrivate: audio.extradata, sampleRate: 48000, channels: 2,
                    language: "eng", name: "Stereo"
                ),
            ],
            frames: frames, durationMilliseconds: Int(demuxer.duration * 1000), cueTrack: 1
        )
    }

    /// The readout puts this straight on screen beside a refused route's own
    /// `localizedDescription`, so it has to be the library's words for the
    /// failure and not the Swift case's spelling.
    func testAFailureReadsAsTheLibrarysOwnWords() {
        XCTAssertEqual(
            AudioDecodeError.decodeFailed(Int32(LexisErrorInvalidData)).localizedDescription,
            "Invalid data found when processing input"
        )
    }

    /// The resampler writes in the order of FFmpeg's default layout for the
    /// channel count, and CoreAudio can only downmix what it can name: 7.1
    /// under a discrete tag is eight channels the system knows nothing about.
    func testTheDefaultLayoutsCarryRealCoreAudioLabels() {
        XCTAssertEqual(
            coreAudioChannelLabels(defaultLayoutFor: 8),
            [
                kAudioChannelLabel_Left, kAudioChannelLabel_Right,
                kAudioChannelLabel_Center, kAudioChannelLabel_LFEScreen,
                kAudioChannelLabel_RearSurroundLeft, kAudioChannelLabel_RearSurroundRight,
                kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround,
            ]
        )
        // every count a film plausibly carries has a fully named layout
        for channels in Int32(1)...8 {
            XCTAssertNotNil(coreAudioChannelLabels(defaultLayoutFor: channels), "\(channels)")
        }
    }

    func testAnEightChannelLayoutDescribesEveryChannel() throws {
        let data = makeAudioChannelLayoutData(channels: 8)
        try data.withUnsafeBytes { raw in
            let layout = raw.baseAddress!.assumingMemoryBound(to: AudioChannelLayout.self)
            XCTAssertEqual(
                layout.pointee.mChannelLayoutTag, kAudioChannelLayoutTag_UseChannelDescriptions
            )
            XCTAssertEqual(layout.pointee.mNumberChannelDescriptions, 8)
            let descriptions = try XCTUnwrap(
                raw.baseAddress?.advanced(by: MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)!)
                    .assumingMemoryBound(to: AudioChannelDescription.self)
            )
            XCTAssertEqual(descriptions[4].mChannelLabel, kAudioChannelLabel_RearSurroundLeft)
            XCTAssertEqual(descriptions[7].mChannelLabel, kAudioChannelLabel_RightSurround)
        }
    }

    /// The tags CoreAudio already has one name for stay tags: a single well
    /// known number where eight descriptions would say the same thing.
    func testTheSmallLayoutsKeepTheirTags() throws {
        for (channels, tag) in [
            (Int32(1), kAudioChannelLayoutTag_Mono),
            (2, kAudioChannelLayoutTag_Stereo),
            (6, kAudioChannelLayoutTag_MPEG_5_1_A),
        ] {
            makeAudioChannelLayoutData(channels: channels).withUnsafeBytes { raw in
                let layout = raw.baseAddress!.assumingMemoryBound(to: AudioChannelLayout.self)
                XCTAssertEqual(layout.pointee.mChannelLayoutTag, tag, "\(channels)")
            }
        }
    }
}

/// TrueHD decodes 40 samples at a time. PCM in 40-sample blocks is the same
/// shape with a decoder every build carries, and a ramp of sample values
/// shows any sample dropped or repeated on the way through.
extension AudioDecoderTests {
    private static let blockSamples = 40
    private static let rampPeriod = 30000

    private func shortFrameFixture(_ name: String, blocks: Int) throws -> URL {
        var frames: [MatroskaFrame] = []
        for block in 0..<blocks {
            var data = Data(capacity: AudioDecoderTests.blockSamples * 4)
            for index in 0..<AudioDecoderTests.blockSamples {
                let value = Int16((block * AudioDecoderTests.blockSamples + index)
                    % AudioDecoderTests.rampPeriod)
                withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
                withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
            }
            let start = Double(block * AudioDecoderTests.blockSamples) / 48
            frames.append(MatroskaFrame(
                track: 1, milliseconds: Int(start.rounded()), isKeyframe: true, data: data
            ))
        }
        return try makeMatroskaFixture(
            directory: FileManager.default.temporaryDirectory, name: name,
            tracks: [MatroskaTrack(
                number: 1, kind: .audio, codecID: "A_PCM/INT/LIT",
                sampleRate: 48000, channels: 2, language: "eng"
            )],
            frames: frames,
            durationMilliseconds: blocks * AudioDecoderTests.blockSamples / 48, cueTrack: 1
        )
    }

    func testShortFramesAreGatheredIntoContiguousBuffers() throws {
        let demuxer = try Demuxer(url: try shortFrameFixture("audio-short-frames.mkv", blocks: 1200))
        let stream = try XCTUnwrap(demuxer.streams.first { $0.kind == .audio })
        let decoder = try AudioDecoder(stream: stream)
        var buffers: [CMSampleBuffer] = []
        while let packet = try demuxer.readPacket() {
            buffers.append(contentsOf: try decoder.decode(packet))
        }
        // a second of 40-sample frames goes out as fiftieths of a second
        XCTAssertEqual(buffers.count, 50)
        let rate = Double(decoder.outputSampleRate)
        XCTAssertEqual(rate, 48000)
        var total = 0
        for (index, buffer) in buffers.enumerated() {
            let count = CMSampleBufferGetNumSamples(buffer)
            XCTAssertEqual(count, 960)
            XCTAssertEqual(
                CMSampleBufferGetPresentationTimeStamp(buffer).seconds, Double(total) / rate,
                accuracy: 1 / rate, "buffer \(index)"
            )
            let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(buffer))
            XCTAssertEqual(CMBlockBufferGetDataLength(block), count * 8)
            var samples = [Float](repeating: 0, count: count * 2)
            XCTAssertEqual(
                CMBlockBufferCopyDataBytes(
                    block, atOffset: 0, dataLength: count * 8, destination: &samples),
                noErr
            )
            for frame in stride(from: 0, to: count, by: 97) {
                let expected = Float((total + frame) % AudioDecoderTests.rampPeriod) / 32768
                XCTAssertEqual(samples[frame * 2], expected, "sample \(total + frame)")
                XCTAssertEqual(samples[frame * 2 + 1], expected, "sample \(total + frame)")
            }
            total += count
        }
        XCTAssertEqual(total, 48000)
    }

    /// What was gathered before a flush belongs to the position the seek
    /// left, and none of it may come out after.
    func testAFlushDropsWhatWasGathered() throws {
        let url = try shortFrameFixture("audio-short-frames-flush.mkv", blocks: 120)
        let demuxer = try Demuxer(url: url)
        let stream = try XCTUnwrap(demuxer.streams.first { $0.kind == .audio })
        let decoder = try AudioDecoder(stream: stream)
        var skipped = 0
        while skipped < 30, let packet = try demuxer.readPacket() {
            _ = try decoder.decode(packet)
            skipped += 1
        }
        decoder.flush()

        let replay = try Demuxer(url: url)
        var buffers: [CMSampleBuffer] = []
        while let packet = try replay.readPacket() {
            buffers.append(contentsOf: try decoder.decode(packet))
        }
        let first = try XCTUnwrap(buffers.first)
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(first).seconds, 0, accuracy: 1e-6)
        XCTAssertEqual(buffers.reduce(0) { $0 + CMSampleBufferGetNumSamples($1) }, 120 * 40)
    }
}

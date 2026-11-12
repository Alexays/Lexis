import CoreVideo
import LexisTestSupport
import XCTest
@testable import LexisPlayer

/// FNV-1a over the luma plane, which is what the fixture's frames differ in.
/// Rows are padded to a stride, and the padding is not part of the picture.
private func lumaChecksum(_ buffer: CVPixelBuffer) -> UInt64 {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let planar = CVPixelBufferGetPlaneCount(buffer) > 0
    let base = planar
        ? CVPixelBufferGetBaseAddressOfPlane(buffer, 0)
        : CVPixelBufferGetBaseAddress(buffer)
    let stride = planar
        ? CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        : CVPixelBufferGetBytesPerRow(buffer)
    guard let base else { return 0 }
    let bytes = base.assumingMemoryBound(to: UInt8.self)
    var hash: UInt64 = 0xCBF2_9CE4_8422_2325
    for row in 0..<CVPixelBufferGetHeight(buffer) {
        for column in 0..<CVPixelBufferGetWidth(buffer) {
            hash = (hash ^ UInt64(bytes[row * stride + column])) &* 0x100_0000_01B3
        }
    }
    return hash
}

/// One checksum a picture, keyed by presentation millisecond. Comparing two
/// files this way is what tells a wrongly ordered bitstream from a right one:
/// the packets are byte identical either way, only the pictures differ.
private func decodedPictures(_ url: URL) throws -> [Int: UInt64] {
    let demuxer = try Demuxer(url: url)
    let stream = try XCTUnwrap(demuxer.streams.first { $0.kind == .video })
    let formatDescription = try makeFormatDescription(for: stream)
    let lock = NSLock()
    var pictures: [Int: UInt64] = [:]
    let decoder = try VideoDecoder(formatDescription: formatDescription) { frame in
        let checksum = lumaChecksum(frame.imageBuffer)
        let millisecond = Int((frame.presentationTime.seconds * 1000).rounded())
        lock.lock()
        pictures[millisecond] = checksum
        lock.unlock()
    }
    while let packet = try demuxer.readPacket() {
        guard packet.streamIndex == stream.index else { continue }
        try decoder.decode(try makeSampleBuffer(
            packet: packet, formatDescription: formatDescription,
            timeBaseNum: stream.timeBaseNum, timeBaseDen: stream.timeBaseDen
        ))
    }
    decoder.waitForPendingFrames()
    lock.lock()
    defer { lock.unlock() }
    return pictures
}

final class MatroskaFixtureTests: XCTestCase {
    func testAuthorsAFileFFmpegOpens() throws {
        let url = try makeSubtitleFixture(
            directory: FileManager.default.temporaryDirectory, name: "fixture-subs.mkv"
        )
        let demuxer = try Demuxer(url: url)
        XCTAssertEqual(demuxer.duration, 4.0, accuracy: 0.2)
        XCTAssertEqual(
            demuxer.streams.map(\.kind),
            [.video, .audio, .audio, .subtitle, .subtitle, .subtitle]
        )
        XCTAssertEqual(
            demuxer.streams.map(\.codecName),
            ["h264", "aac", "aac", "ass", "subrip", "hdmv_pgs_subtitle"]
        )
        // one time base for the whole file: matroska stores a scale, and the
        // fixture's is a millisecond
        XCTAssertTrue(demuxer.streams.allSatisfy { $0.timeBaseNum == 1 && $0.timeBaseDen == 1000 })
        // the ASS script header, which the decoder needs to make sense of a line
        XCTAssertGreaterThan(try XCTUnwrap(demuxer.streams[3].extradata).count, 100)
        // the canvas a PGS rect is positioned in. No track entry says it:
        // find_stream_info decodes a display set to learn it
        XCTAssertEqual(demuxer.streams[5].width, 1920)
        XCTAssertEqual(demuxer.streams[5].height, 1080)

        var counts: [Int32: Int] = [:]
        var cues: [Int32: [Int64]] = [:]
        while let packet = try demuxer.readPacket() {
            counts[packet.streamIndex, default: 0] += 1
            // nothing before zero: the AAC priming would otherwise start the
            // container at -44 ms, and every cue is read against that start
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(packet.pts), 0)
            if demuxer.streams[Int(packet.streamIndex)].kind == .subtitle {
                cues[packet.streamIndex, default: []].append(try XCTUnwrap(packet.pts))
            }
        }
        // the times this fixture documents, to the millisecond
        XCTAssertEqual(cues[3], [1000, 3200])
        XCTAssertEqual(cues[4], [1500])
        XCTAssertEqual(cues[5], [2000])
        XCTAssertEqual(counts[0], 96)
        XCTAssertEqual(counts[3], 2)
        XCTAssertEqual(counts[4], 1)
        XCTAssertEqual(counts[5], 1)
        // 4 s of 48 kHz AAC, the same on both tracks
        XCTAssertGreaterThan(counts[1] ?? 0, 180)
        XCTAssertEqual(counts[1], counts[2])
    }

    func testSeekingLandsOnAKeyframe() throws {
        let url = try makeSubtitleFixture(
            directory: FileManager.default.temporaryDirectory, name: "fixture-seek.mkv"
        )
        let demuxer = try Demuxer(url: url)
        try demuxer.seek(to: 2.5)
        // a cluster starts at every video keyframe and every cluster has a cue,
        // so this is the keyframe at or before the target and nothing else
        while let packet = try demuxer.readPacket() {
            guard packet.streamIndex == 0 else { continue }
            XCTAssertTrue(packet.isKeyframe)
            XCTAssertEqual(packet.pts, 2500)
            return
        }
        XCTFail("no video packet after the seek")
    }

    func testAuthorsTheSameBytesWhateverOrderTheFramesArriveIn() throws {
        let tracks = [
            MatroskaTrack(number: 1, kind: .video, codecID: "V_MPEG4/ISO/AVC", width: 16, height: 16),
            MatroskaTrack(number: 2, kind: .audio, codecID: "A_AAC", sampleRate: 48000, channels: 2),
            MatroskaTrack(number: 3, kind: .audio, codecID: "A_AAC", sampleRate: 48000, channels: 2),
        ]
        // the two audio tracks tie on every decode time, which is what the sort
        // has to break to write the same file twice
        var frames: [MatroskaFrame] = []
        for step in 0..<8 {
            let time = step * 100
            frames.append(MatroskaFrame(
                track: 1, milliseconds: time, isKeyframe: step % 4 == 0, data: Data([UInt8(step)])
            ))
            frames.append(MatroskaFrame(
                track: 2, milliseconds: time, isKeyframe: true, data: Data([0x02])
            ))
            frames.append(MatroskaFrame(
                track: 3, milliseconds: time, isKeyframe: true, data: Data([0x03])
            ))
        }
        let directory = FileManager.default.temporaryDirectory
        let first = try makeMatroskaFixture(
            directory: directory, name: "fixture-order-1.mkv", tracks: tracks,
            frames: frames, durationMilliseconds: 800, cueTrack: 1
        )
        let second = try makeMatroskaFixture(
            directory: directory, name: "fixture-order-2.mkv", tracks: tracks,
            frames: frames.reversed(), durationMilliseconds: 800, cueTrack: 1
        )
        XCTAssertEqual(try Data(contentsOf: first), try Data(contentsOf: second))
    }

    func testVideoDecodesToTheSamePicturesAsItsSource() throws {
        try skipUnlessRealtimeTests()
        let directory = FileManager.default.temporaryDirectory
        let url = try makeSubtitleFixture(directory: directory, name: "fixture-pictures.mkv")
        // The mp4 the fixture lifted its video out of, left next to it - and
        // asked for the same way the fixture itself was, never by joining the
        // name onto `directory`: fixtures live in a directory of this
        // process's own, so a flat path finds either nothing or, worse, what
        // some earlier run left in /tmp. Against a stale one this comparison
        // reads a different encode's pictures and a handful of the 96 differ.
        let source = fixtureURL(in: directory, named: "fixture-pictures.mkv.source-2.mp4")
        // The header has to describe the slices stored under it. Nothing in the
        // packets says otherwise, so a file carrying another encode's SPS still
        // demuxes and still decodes - only a few of its pictures come out wrong.
        XCTAssertEqual(
            try XCTUnwrap(Demuxer(url: url).streams.first { $0.kind == .video }).extradata,
            try XCTUnwrap(Demuxer(url: source).streams.first { $0.kind == .video }).extradata
        )
        let expected = try decodedPictures(source)
        XCTAssertEqual(expected.count, 96)
        // the fixture cycles five colors, so its pictures repeat; a checksum
        // that told none of them apart would make the comparison vacuous
        XCTAssertGreaterThanOrEqual(Set(expected.values).count, 5)
        XCTAssertEqual(try decodedPictures(url), expected)

        // the styled fixture too: its blocks are stored in decode order, and a
        // file that stored them in presentation order still decodes, only to
        // the wrong pictures
        let styled = try makeStyledSubtitleFixture(
            directory: directory, name: "styled-pictures.mkv"
        )
        let styledExpected = try decodedPictures(
            fixtureURL(in: directory, named: "styled-pictures.mkv.source.mp4")
        )
        XCTAssertEqual(styledExpected.count, 96)
        XCTAssertEqual(try decodedPictures(styled), styledExpected)
    }

    func testDecodesAnHEVCTrackWhoseHeaderCarriesNoParameterSet() throws {
        // Some web releases mux an hvcC that names no VPS, SPS or PPS and send
        // them at every keyframe instead: VideoToolbox builds no session from
        // such a header alone.
        let (source, url) = try makeHEVCMatroskaFixture(
            directory: FileManager.default.temporaryDirectory, name: "in-band-sets.mkv",
            header: { $0.prefix(22) + [0] },
            keyframe: { sets, packet in sets + packet }
        )
        let expected = try decodedPictures(source)
        XCTAssertEqual(expected.count, 24)
        XCTAssertEqual(try decodedPictures(url), expected)
    }

    func testCarriesAFontAttachmentFFmpegHandsBackWhole() throws {
        let font = try systemFontData()
        let url = try makeStyledSubtitleFixture(
            directory: FileManager.default.temporaryDirectory, name: "styled-attach.mkv"
        )
        let demuxer = try Demuxer(url: url)
        XCTAssertEqual(
            demuxer.streams.map(\.kind), [.video, .subtitle, .other]
        )
        // an attachment is a stream with no packets: the whole file arrives as
        // extradata when the container is opened
        let attachment = try XCTUnwrap(demuxer.streams.last)
        XCTAssertEqual(attachment.extradata?.count, font.count)
        XCTAssertEqual(attachment.extradata, font)
        var counts: [Int32: Int] = [:]
        while let packet = try demuxer.readPacket() {
            counts[packet.streamIndex, default: 0] += 1
        }
        XCTAssertNil(counts[attachment.index])

        // and the ASS track still carries its script header
        let subtitle = try XCTUnwrap(demuxer.streams.first { $0.kind == .subtitle })
        XCTAssertEqual(subtitle.codecName, "ass")
        XCTAssertEqual(subtitle.extradata, Data(assStyledFixtureHeader.utf8))
        XCTAssertEqual(counts[subtitle.index], 3)
    }
}

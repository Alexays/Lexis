import CoreMedia
import CoreVideo
import Foundation
import LexisTestSupport
import XCTest
@testable import LexisPlayer

/// A real interlaced MPEG-2 file, through the path a DVD rip actually takes.
final class InterlacedPlaybackTests: XCTestCase {
    private static let width = 352
    private static let height = 288
    private static let frameCount = 12
    private static let fps = 25

    private func interlacedStream(name: String) throws -> (demuxer: Demuxer, stream: MediaStream) {
        let url: URL
        do {
            url = try makeInterlacedFixture(
                directory: FileManager.default.temporaryDirectory, name: name,
                width: Self.width, height: Self.height,
                frameCount: Self.frameCount, fps: Self.fps
            )
        } catch InterlacedFixtureError.ffmpegUnavailable {
            throw XCTSkip("no ffmpeg on PATH to encode a real interlaced fixture")
        }
        let demuxer = try Demuxer(url: url)
        let stream = try XCTUnwrap(demuxer.streams.first { $0.kind == .video })
        XCTAssertEqual(stream.codecName, "mpeg2video")
        return (demuxer, stream)
    }

    /// Every row of the luma plane, so a surviving comb shows up as a row
    /// that is not the field's own colour.
    private func lumaRows(of sample: CMSampleBuffer) throws -> [UInt8] {
        let buffer = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample) as CVPixelBuffer?)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 0))
            .assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        // One column in from the edge: MPEG-2 puts its own ringing on the
        // very first sample of a row and the picture is flat everywhere else.
        return (0..<CVPixelBufferGetHeightOfPlane(buffer, 0)).map { base[$0 * stride + 4] }
    }

    private func decodeAll(
        _ demuxer: Demuxer, _ stream: MediaStream, _ decoder: SoftwareVideoDecoder
    ) throws -> [CMSampleBuffer] {
        var samples: [CMSampleBuffer] = []
        while let packet = try demuxer.readPacket() {
            guard packet.streamIndex == stream.index else { continue }
            samples.append(contentsOf: try decoder.decode(packet))
        }
        samples.append(contentsOf: try decoder.drainAtEndOfStream())
        return samples
    }

    /// An interlaced H.264 track, what a 1080i broadcast is, decoded by
    /// VideoToolbox on the Enhanced rendering: each woven frame leaves as its
    /// two fields, flat rather than combed, in the order they were shot and
    /// half a frame apart.
    func testTheEnhancedPathSplitsEachFrameIntoItsFields() throws {
        let url: URL
        do {
            url = try makeInterlacedFixture(
                directory: FileManager.default.temporaryDirectory, name: "interlaced-h264.mkv",
                width: Self.width, height: Self.height, frameCount: Self.frameCount, fps: Self.fps, codec: .h264)
        } catch InterlacedFixtureError.ffmpegUnavailable {
            throw XCTSkip("no ffmpeg on PATH to encode a real interlaced fixture")
        }
        let demuxer = try Demuxer(url: url)
        let stream = try XCTUnwrap(demuxer.streams.first { $0.kind == .video })
        let fields = try XCTUnwrap(FieldOrder(of: stream), "field order \(stream.fieldOrder)")
        let format = try makeFormatDescription(for: stream)
        let lock = NSLock()
        var pictures: [(time: Double, low: Int, high: Int)] = []
        let path = try ToneMappedVideo(
            enhancing: format, sourceBitDepth: stream.bitDepth, videoDelay: stream.videoDelay,
            budgetBytes: 1 << 28, fields: fields
        ) { sample in
            guard let picture = CMSampleBufferGetImageBuffer(sample) else { return }
            CVPixelBufferLockBaseAddress(picture, .readOnly)
            let base = CVPixelBufferGetBaseAddressOfPlane(picture, 0)!.assumingMemoryBound(to: UInt16.self)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(picture, 0) / 2
            var low = Int.max, high = Int.min
            // clear of the edges, where the encoder's blocks may bleed
            for y in 8..<(Self.height - 8) {
                for x in 8..<(Self.width - 8) {
                    let code = Int(base[y * stride + x] >> 6)
                    low = min(low, code)
                    high = max(high, code)
                }
            }
            CVPixelBufferUnlockBaseAddress(picture, .readOnly)
            lock.lock()
            pictures.append((CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)), low, high))
            lock.unlock()
        }
        while let packet = try demuxer.readPacket() {
            guard packet.streamIndex == stream.index else { continue }
            try path.decode(
                try makeSampleBuffer(
                    packet: packet, formatDescription: format,
                    timeBaseNum: stream.timeBaseNum, timeBaseDen: stream.timeBaseDen),
                rpu: nil)
        }
        path.drain()
        lock.lock()
        defer { lock.unlock() }
        XCTAssertEqual(pictures.count, 2 * Self.frameCount)
        let field = 1.0 / Double(Self.fps * 2)
        for (index, picture) in pictures.enumerated() {
            XCTAssertEqual(picture.time - pictures[0].time, Double(index) * field, accuracy: field / 8, "picture \(index)")
            // the fields go white, black, black, white, top first; a comb spans both
            let white = (index + 1) % 4 < 2
            XCTAssertTrue(
                white ? picture.low > 900 : picture.high < 100,
                "picture \(index) holds \(picture.low) to \(picture.high)")
        }
    }

    func testTheContainerSaysTheTrackIsInterlaced() throws {
        let (_, stream) = try interlacedStream(name: "interlaced-flag.mkv")
        XCTAssertTrue(stream.isInterlaced, "field order \(stream.fieldOrder) read as progressive")
    }

    /// The comb itself. Each frame of the fixture is a solid white field
    /// combed with a solid black one; a picture that still alternates is a
    /// picture that was never deinterlaced.
    func testEveryPictureComesOutFlatRatherThanCombed() throws {
        let (demuxer, stream) = try interlacedStream(name: "interlaced-comb.mkv")
        let decoder = try SoftwareVideoDecoder(stream: stream, threadCount: 2, poolCeilingBytes: 1 << 30)
        let samples = try decodeAll(demuxer, stream, decoder)
        XCTAssertGreaterThan(samples.count, 0)
        for (index, sample) in samples.enumerated() {
            let rows = try lumaRows(of: sample)
            // Both fields of the fixture are flat, so a correct picture is
            // flat too, whichever field it came from.
            XCTAssertEqual(
                Set(rows).count, 1,
                "picture \(index) still carries \(Set(rows).sorted()) down its rows"
            )
        }
    }

    /// A bob is one picture per field, so twice as many as there are frames,
    /// and the order is the order the fields were shot in.
    func testAFrameBecomesItsTwoFieldsInTheOrderTheyWereShot() throws {
        let (demuxer, stream) = try interlacedStream(name: "interlaced-pairs.mkv")
        let decoder = try SoftwareVideoDecoder(stream: stream, threadCount: 2, poolCeilingBytes: 1 << 30)
        let samples = try decodeAll(demuxer, stream, decoder)
        XCTAssertEqual(samples.count, 2 * Self.frameCount)
        XCTAssertEqual(decoder.deinterlacedFrames, Self.frameCount)
        // The fixture is shot top field first, its fields white, black,
        // black, white.
        for (index, sample) in samples.enumerated() {
            let expected: UInt8 = (index + 1) % 4 < 2 ? 235 : 16
            let rows = try lumaRows(of: sample)
            XCTAssertEqual(
                Int(rows[0]), Int(expected), accuracy: 2,
                "picture \(index) is the wrong field"
            )
        }
    }

    /// The two fields of a frame are half a frame apart in time. Both landing
    /// on the frame's own timestamp is a renderer showing them back to back
    /// and then waiting out the whole frame, which is the judder the bob was
    /// meant to remove.
    func testTheSecondFieldLandsHalfAFrameAfterTheFirst() throws {
        let (demuxer, stream) = try interlacedStream(name: "interlaced-timing.mkv")
        let decoder = try SoftwareVideoDecoder(stream: stream, threadCount: 2, poolCeilingBytes: 1 << 30)
        let times = try decodeAll(demuxer, stream, decoder)
            .map { CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp($0)) }
        XCTAssertEqual(times.count, 2 * Self.frameCount)
        let field = 1.0 / Double(Self.fps * 2)
        for (index, time) in times.enumerated() {
            XCTAssertEqual(time, Double(index) * field, accuracy: field / 8, "picture \(index)")
        }
    }

    /// MPEG-PS leaves the pts off some frames. Every picture still carries a
    /// time, half a frame after the one before it.
    func testAProgramStreamFrameWithNoPtsKeepsItsPlace() throws {
        let (demuxer, stream) = try interlacedStream(name: "interlaced-no-pts.mpg")
        let decoder = try SoftwareVideoDecoder(stream: stream, threadCount: 2, poolCeilingBytes: 1 << 30)
        let times = try decodeAll(demuxer, stream, decoder)
            .map { CMSampleBufferGetPresentationTimeStamp($0) }
        XCTAssertEqual(times.count, 2 * Self.frameCount)
        XCTAssertTrue(times.allSatisfy(\.isValid))
        let field = 1.0 / Double(Self.fps * 2)
        for index in times.indices.dropFirst() {
            XCTAssertEqual(
                (times[index] - times[index - 1]).seconds, field, accuracy: field / 8, "picture \(index)")
        }
    }

    /// The luma of a picture either path hands over, as eight bit codes:
    /// the software decoder's own planar ones, or the enhancer's ten bit.
    private func luma(of sample: CMSampleBuffer) throws -> [UInt8] {
        let buffer = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample) as CVPixelBuffer?)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 0))
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0), height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let deep = CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        return (0..<height).flatMap { y in
            (0..<width).map { x in
                deep
                    ? UInt8(base.advanced(by: y * stride).assumingMemoryBound(to: UInt16.self)[x] >> 8)
                    : base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)[x]
            }
        }
    }

    /// Telecined film's pictures against the frames it was made from: past
    /// the frames the cadence takes to read, every picture is one film
    /// frame, whole and the next one along, never a repeat or a skip, and
    /// two or three fields after the one before, as the pulldown laid it
    /// out. Before that, each field is deinterlaced.
    private func assertFilmFrames(_ samples: [CMSampleBuffer], frames: URL, width: Int, height: Int) throws {
        let film = try Data(contentsOf: frames)
        let frameBytes = width * height * 3 / 2
        let filmFrames = film.count / frameBytes
        // fewer than the two a frame a deinterlace makes: the cadence was read
        XCTAssertLessThan(samples.count, filmFrames + 20)
        var matched: [(frame: Int, time: Double, psnr: Double)] = []
        for sample in samples {
            let picture = try luma(of: sample)
            var best = (frame: -1, error: Double.infinity)
            for frame in 0..<filmFrames {
                var error = 0.0
                film.withUnsafeBytes { raw in
                    let codes = raw.bindMemory(to: UInt8.self)
                    for at in stride(from: 0, to: width * height, by: 3) {
                        let difference = Double(picture[at]) - Double(codes[frame * frameBytes + at])
                        error += difference * difference
                    }
                }
                if error < best.error { best = (frame, error) }
            }
            let mse = best.error / Double((width * height + 2) / 3)
            matched.append((best.frame, CMSampleBufferGetPresentationTimeStamp(sample).seconds, 10 * log10(255 * 255 / max(mse, 1e-9))))
        }
        // the last twenty pictures are all past the lock
        let locked = matched.suffix(20)
        let field = 1001.0 / 60000
        for (before, after) in zip(locked.dropLast(), locked.dropFirst()) {
            XCTAssertEqual(after.frame, before.frame + 1, "film frames \(locked.map(\.frame))")
            XCTAssertGreaterThan(after.psnr, 38, "film frame \(after.frame) at \(after.time)")
            let fields = ((after.time - before.time) / field).rounded()
            XCTAssertTrue(fields == 2 || fields == 3, "\(fields) fields between film frames \(before.frame) and \(after.frame)")
        }
    }

    /// Film telecined to 29.97 interlaced, a DVD's 3:2 pulldown, through the
    /// software decoder a DVD takes.
    func testTelecinedFilmComesOutAsItsOwnFramesFromSoftware() throws {
        let fixture: (url: URL, frames: URL)
        do {
            fixture = try makeTelecineFixture(
                directory: FileManager.default.temporaryDirectory, name: "telecine-mpeg2.mpg",
                width: 320, height: 240, frameCount: 32)
        } catch InterlacedFixtureError.ffmpegUnavailable {
            throw XCTSkip("no ffmpeg on PATH to telecine a fixture")
        }
        let demuxer = try Demuxer(url: fixture.url)
        let stream = try XCTUnwrap(demuxer.streams.first { $0.kind == .video })
        let decoder = try SoftwareVideoDecoder(stream: stream, threadCount: 2, poolCeilingBytes: 1 << 30)
        try assertFilmFrames(decodeAll(demuxer, stream, decoder), frames: fixture.frames, width: 320, height: 240)
    }

    /// The same film as a 1080i broadcast of it carries it, H.264 decoded by
    /// VideoToolbox, its fields built on the GPU: every film frame folded
    /// into one picture gives its spare slot back.
    func testTelecinedFilmComesOutAsItsOwnFramesFromTheGPU() throws {
        let fixture: (url: URL, frames: URL)
        do {
            fixture = try makeTelecineFixture(
                directory: FileManager.default.temporaryDirectory, name: "telecine-h264.mkv",
                width: 320, height: 240, frameCount: 32, codec: .h264)
        } catch InterlacedFixtureError.ffmpegUnavailable {
            throw XCTSkip("no ffmpeg on PATH to telecine a fixture")
        }
        let demuxer = try Demuxer(url: fixture.url)
        let stream = try XCTUnwrap(demuxer.streams.first { $0.kind == .video })
        let format = try makeFormatDescription(for: stream)
        let lock = NSLock()
        var samples: [CMSampleBuffer] = []
        var folded = 0
        let path = try ToneMappedVideo(
            enhancing: format, sourceBitDepth: stream.bitDepth, videoDelay: stream.videoDelay,
            budgetBytes: 1 << 28, fields: FieldOrder(of: stream)
        ) { sample in
            lock.lock()
            samples.append(sample)
            lock.unlock()
        }
        path.onPictureFolded = {
            lock.lock()
            folded += 1
            lock.unlock()
        }
        var frames = 0
        while let packet = try demuxer.readPacket() {
            guard packet.streamIndex == stream.index else { continue }
            frames += 1
            try path.decode(
                try makeSampleBuffer(
                    packet: packet, formatDescription: format,
                    timeBaseNum: stream.timeBaseNum, timeBaseDen: stream.timeBaseDen),
                rpu: nil)
        }
        path.drain()
        lock.lock()
        defer { lock.unlock() }
        XCTAssertEqual(samples.count + folded, 2 * frames, "every picture a frame was counted for came or was folded")
        try assertFilmFrames(samples, frames: fixture.frames, width: 320, height: 240)
    }

    /// Interlacing no longer forces a route of its own: the track takes the
    /// same path its codec allows, so a capture the hardware can decode rides
    /// the passthrough (woven by the layer's decoder) and only a codec with
    /// no hardware support falls back to software.
    func testAnInterlacedTrackFollowsTheSameRouteAsItsCodecAllows() throws {
        let (_, stream) = try interlacedStream(name: "interlaced-route.mkv")
        // The fixture is MPEG-2, which this device may or may not decode in
        // hardware; the routing is asserted on the answer either way.
        if isHardwareDecodeSupported(ffmpegCodecName: stream.codecName) == true {
            XCTAssertNil(pictureFormat(for: stream, toneMapPixelFormat: nil))
        } else {
            XCTAssertEqual(
                pictureFormat(for: stream, toneMapPixelFormat: nil),
                kCVPixelFormatType_420YpCbCr8Planar
            )
        }
    }

    /// H.264 is decoded in hardware on every device this ships to, so an
    /// interlaced H.264 capture is never decoded in software: it is decoded
    /// here by VideoToolbox and its fields built up on the GPU.
    func testAnInterlacedHardwareCodecIsDeinterlacedOnTheGPU() throws {
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "interlaced-h264-route.mp4",
            codec: .h264, width: 320, height: 180, frameCount: 4, fps: 25
        )
        var stream = try Demuxer(url: url).streams[0]
        try XCTSkipUnless(
            isHardwareDecodeSupported(ffmpegCodecName: stream.codecName) == true,
            "no hardware H.264 decode here, so there is no passthrough to stay on"
        )
        XCTAssertNil(pictureFormat(for: stream, toneMapPixelFormat: nil))
        // AV_FIELD_TT, which the test target does not link libavcodec to name.
        stream.fieldOrder = 2
        XCTAssertNil(pictureFormat(for: stream, toneMapPixelFormat: nil))
        XCTAssertEqual(videoPath(for: stream, capability: DisplayCapability(headroom: 1)), .deinterlaced)
    }

    /// The deinterlaced path of an interlaced H.264 track: each frame
    /// leaves as its two fields, with the source's own codes - four times
    /// each, no grain and no deband - and the widescreen shape of its
    /// pixels on every picture.
    func testTheFaithfulPathSplitsEachFrameIntoItsFieldsAndAddsNothing() throws {
        let url: URL
        do {
            url = try makeInterlacedFixture(
                directory: FileManager.default.temporaryDirectory, name: "interlaced-faithful.mkv",
                width: Self.width, height: Self.height, frameCount: Self.frameCount, fps: Self.fps,
                codec: .h264, aspect: "16:9")
        } catch InterlacedFixtureError.ffmpegUnavailable {
            throw XCTSkip("no ffmpeg on PATH to encode a real interlaced fixture")
        }
        let demuxer = try Demuxer(url: url)
        let stream = try XCTUnwrap(demuxer.streams.first { $0.kind == .video })
        let format = try makeFormatDescription(for: stream)
        let lock = NSLock()
        var pictures = 0
        var offCode = 0
        var aspects: Set<String> = []
        let path = try ToneMappedVideo(
            enhancing: format, sourceBitDepth: stream.bitDepth, videoDelay: stream.videoDelay,
            budgetBytes: 1 << 28, fields: FieldOrder(of: stream)
        ) { sample in
            guard let picture = CMSampleBufferGetImageBuffer(sample) else { return }
            let aspect = CVBufferCopyAttachment(picture, kCVImageBufferPixelAspectRatioKey, nil) as? [String: Any]
            CVPixelBufferLockBaseAddress(picture, .readOnly)
            let base = CVPixelBufferGetBaseAddressOfPlane(picture, 0)!.assumingMemoryBound(to: UInt16.self)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(picture, 0) / 2
            var off = 0
            for y in 0..<Self.height {
                for x in 0..<Self.width where (base[y * stride + x] >> 6) % 4 != 0 { off += 1 }
            }
            CVPixelBufferUnlockBaseAddress(picture, .readOnly)
            lock.lock()
            pictures += 1
            offCode += off
            aspects.insert(aspect.map { "\($0[kCVImageBufferPixelAspectRatioHorizontalSpacingKey as String] ?? "")"
                + ":\($0[kCVImageBufferPixelAspectRatioVerticalSpacingKey as String] ?? "")" } ?? "none")
            lock.unlock()
        }
        while let packet = try demuxer.readPacket() {
            guard packet.streamIndex == stream.index else { continue }
            try path.decode(
                try makeSampleBuffer(
                    packet: packet, formatDescription: format,
                    timeBaseNum: stream.timeBaseNum, timeBaseDen: stream.timeBaseDen),
                rpu: nil)
        }
        path.drain()
        lock.lock()
        defer { lock.unlock() }
        XCTAssertEqual(pictures, 2 * Self.frameCount)
        XCTAssertEqual(offCode, 0, "a code that is not an eight bit one times four was added by a stage")
        XCTAssertEqual(aspects, ["16:11"])
    }

    /// A widescreen DVD's pixels are wider than they are tall, and every
    /// picture says so, whichever route the software decoder made it by:
    /// the description the container's shape is read into carries it too.
    func testAWidescreenDVDKeepsTheShapeOfItsPixels() throws {
        let url: URL
        do {
            url = try makeInterlacedFixture(
                directory: FileManager.default.temporaryDirectory, name: "interlaced-anamorphic.mkv",
                width: Self.width, height: Self.height, frameCount: Self.frameCount, fps: Self.fps,
                aspect: "16:9")
        } catch InterlacedFixtureError.ffmpegUnavailable {
            throw XCTSkip("no ffmpeg on PATH to encode a real interlaced fixture")
        }
        let demuxer = try Demuxer(url: url)
        let stream = try XCTUnwrap(demuxer.streams.first { $0.kind == .video })
        // 16:9 over 352:288 is 16:11 a pixel
        XCTAssertEqual(stream.pixelAspectNum * 11, stream.pixelAspectDen * 16)
        let decoder = try SoftwareVideoDecoder(stream: stream, threadCount: 2, poolCeilingBytes: 1 << 30)
        let samples = try decodeAll(demuxer, stream, decoder)
        XCTAssertEqual(samples.count, 2 * Self.frameCount)
        for sample in samples {
            let picture = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
            let aspect = try XCTUnwrap(
                CVBufferCopyAttachment(picture, kCVImageBufferPixelAspectRatioKey, nil) as? [String: Int])
            XCTAssertEqual(aspect[kCVImageBufferPixelAspectRatioHorizontalSpacingKey as String], 16)
            XCTAssertEqual(aspect[kCVImageBufferPixelAspectRatioVerticalSpacingKey as String], 11)
        }
    }

    /// Bobbing doubles the pictures a second, and the display has to be
    /// asked for the rate they actually arrive at: at the container's own 25
    /// the screen would show every other one.
    func testTheDisplayIsAskedForTheBobbedRate() throws {
        let (_, mpeg2) = try interlacedStream(name: "interlaced-criteria.mkv")
        XCTAssertEqual(try XCTUnwrap(mpeg2.frameRate), Double(Self.fps), accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(mpeg2.outputFrameRate), Double(Self.fps * 2), accuracy: 0.01)
        // The request itself needs a format description, which CoreMedia has
        // no atom mapping to build for MPEG-2: asked of an H.264 track at the
        // same rate, which is the same interlaced capture in the container a
        // remux would put it in.
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "interlaced-criteria.mp4",
            codec: .h264, width: 320, height: 180, frameCount: 4, fps: Int32(Self.fps)
        )
        var stream = try Demuxer(url: url).streams[0]
        let format = try makeFormatDescription(for: stream)
        XCTAssertEqual(
            try XCTUnwrap(playerDisplayCriteria(for: stream, formatDescription: format)).refreshRate,
            Float(Self.fps), accuracy: 0.01
        )
        stream.fieldOrder = 2
        XCTAssertEqual(
            try XCTUnwrap(playerDisplayCriteria(for: stream, formatDescription: format)).refreshRate,
            Float(Self.fps * 2), accuracy: 0.01
        )
    }

    /// A progressive track pays nothing: it takes the same path, at the same
    /// rate, with the same zero-copy count it had before any of this existed.
    func testAProgressiveTrackIsUntouched() throws {
        let url: URL
        do {
            url = try makeVP9Fixture(
                directory: FileManager.default.temporaryDirectory, name: "interlaced-none.mkv",
                width: 640, height: 384, frameCount: 12, fps: 24
            )
        } catch VP9FixtureError.ffmpegUnavailable {
            throw XCTSkip("no ffmpeg on PATH to encode a progressive fixture")
        }
        let demuxer = try Demuxer(url: url)
        let stream = demuxer.streams[0]
        XCTAssertFalse(stream.isInterlaced)
        XCTAssertEqual(stream.outputFrameRate, stream.frameRate)
        let decoder = try SoftwareVideoDecoder(stream: stream, threadCount: 2, poolCeilingBytes: 1 << 30)
        var samples: [CMSampleBuffer] = []
        var packets = 0
        while let packet = try demuxer.readPacket() {
            guard packet.streamIndex == stream.index else { continue }
            packets += 1
            samples.append(contentsOf: try decoder.decode(packet))
        }
        samples.append(contentsOf: try decoder.drainAtEndOfStream())
        XCTAssertGreaterThan(packets, 0)
        XCTAssertEqual(samples.count, packets, "one picture per frame, not two")
        XCTAssertEqual(decoder.deinterlacedFrames, 0)
        XCTAssertEqual(decoder.copiedFrames, 0, "a progressive picture was taken off the zero-copy path")
    }
}

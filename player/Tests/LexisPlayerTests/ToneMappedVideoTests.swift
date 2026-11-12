import CoreMedia
import LexisTestSupport
import XCTest
@testable import LexisPlayer

final class ToneMappedVideoTests: XCTestCase {
    func openFixture(_ name: String, transfer: HDRFixtureTransfer, frames: Int) throws
        -> (Demuxer, MediaStream, CMVideoFormatDescription)
    {
        let url = try makeHDRFixture(
            directory: FileManager.default.temporaryDirectory, name: name,
            width: 320, height: 180, frameCount: frames, transfer: transfer
        )
        let demuxer = try Demuxer(url: url)
        let stream = demuxer.streams[0]
        return (demuxer, stream, try makeFormatDescription(for: stream))
    }

    /// What the path stores a picture as is the screen's decision, and it is
    /// the same figure the budget weighs a picture with.
    func testThePictureFormatFollowsTheDisplay() throws {
        let (_, stream, format) = try openFixture("tmv-format.mp4", transfer: .hlg, frames: 2)
        for (headroom, expected) in [
            (Float(1), kCVPixelFormatType_32BGRA), (16, kCVPixelFormatType_64RGBAHalf),
        ] {
            let capability = DisplayCapability(headroom: headroom)
            let path = try ToneMappedVideo(
                formatDescription: format,
                sourcePeakPQ: masteringPeakPQ(stream.masteringDisplay),
                videoDelay: stream.videoDelay, capability: capability, budgetBytes: 1 << 30
            ) { _ in }
            XCTAssertEqual(path.pixelFormat, expected, "headroom \(headroom)")
            XCTAssertEqual(
                pictureFormat(for: stream, toneMapPixelFormat: path.pixelFormat), expected)
        }
    }

    func testEveryPacketBecomesAPictureInPresentationOrder() throws {
        let (demuxer, stream, format) = try openFixture(
            "tmv-order.mp4", transfer: .hlg, frames: 20
        )
        let lock = NSLock()
        var times: [Double] = []
        let path = try ToneMappedVideo(
            formatDescription: format, sourcePeakPQ: masteringPeakPQ(stream.masteringDisplay),
            videoDelay: stream.videoDelay, capability: DisplayCapability(headroom: 1), budgetBytes: 1 << 30
        ) { sample in
            lock.lock()
            times.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
            lock.unlock()
        }
        let lengthSize = nalLengthSize(hvcC: stream.extradata)
        var rpus = 0
        while let packet = try demuxer.readPacket() {
            var rpu: DolbyVisionRPU?
            if let payload = packet.withUnsafeBytes({
                dolbyVisionRPUPayload(in: $0, lengthSize: lengthSize)
            }) {
                rpu = try parseDolbyVisionRPU(payload)
                rpus += 1
            }
            try path.decode(
                try makeSampleBuffer(
                    packet: packet, formatDescription: format,
                    timeBaseNum: stream.timeBaseNum, timeBaseDen: stream.timeBaseDen
                ),
                rpu: rpu
            )
        }
        path.drain()
        lock.lock()
        defer { lock.unlock() }
        XCTAssertEqual(rpus, 20)
        XCTAssertEqual(times.count, 20)
        // VideoToolbox hands frames back in decode order; a renderer shows a
        // picture at the time it carries, so this is what the window is for
        XCTAssertEqual(times, times.sorted())
    }

    /// A screen that applies its own black, as an SDR one does through
    /// BT.1886, is handed the grade's black as black: every code at or under
    /// the stated black leaves as zero, and the ones over it rise from there
    /// with no step to a floor.
    func testTheRelativeStoreLandsTheGradesBlackOnZero() throws {
        let rows = 8
        let picture = try makeSource(codes: Array(64..<96), rows: rows)
        var described: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: nil, imageBuffer: picture, formatDescriptionOut: &described)
        let format = try XCTUnwrap(described)
        let lock = NSLock()
        var means: [Double] = []
        // 0.005 nits, a mastering monitor's black: ten bit code 77
        let black = pqInverseEOTF(0.0000005)
        let path = try ToneMappedVideo(
            formatDescription: format, sourcePeakPQ: pqInverseEOTF(0.1), sourceBlackPQ: black, videoDelay: 0,
            capability: DisplayCapability(headroom: 1), budgetBytes: 1 << 30, decodesItself: false
        ) { sample in
            guard let stored = CMSampleBufferGetImageBuffer(sample) else { return }
            XCTAssertEqual(CVPixelBufferGetPixelFormatType(stored), kCVPixelFormatType_32BGRA)
            CVPixelBufferLockBaseAddress(stored, .readOnly)
            let pixels = CVPixelBufferGetBaseAddress(stored)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(stored)
            let read = (0..<32).map { x in
                (0..<rows).reduce(0.0) { $0 + Double(pixels[$1 * stride + x * 4 + 2]) } / Double(rows)
            }
            CVPixelBufferUnlockBaseAddress(stored, .readOnly)
            lock.lock()
            means = read
            lock.unlock()
        }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 24), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil, imageBuffer: picture, formatDescription: format, sampleTiming: &timing,
            sampleBufferOut: &sample)
        try path.decode(try XCTUnwrap(sample), rpu: nil, picture: picture)
        path.drain()
        lock.lock()
        defer { lock.unlock() }
        XCTAssertEqual(means.count, 32)
        let lastBlack = Int((64 + 876 * black).rounded(.down)) - 64
        for x in 0...lastBlack { XCTAssertEqual(means[x], 0, "code \(64 + x) is under the grade's black") }
        for x in 1..<means.count {
            XCTAssertGreaterThanOrEqual(means[x], means[x - 1] - 0.5, "code \(64 + x)")
            XCTAssertLessThan(means[x] - means[x - 1], 6, "code \(64 + x) steps from \(means[x - 1]) to \(means[x])")
        }
    }

    func testAFlushDropsWhatIsInFlight() throws {
        let (demuxer, stream, format) = try openFixture("tmv-flush.mp4", transfer: .pq, frames: 20)
        let lock = NSLock()
        var count = 0
        let path = try ToneMappedVideo(
            formatDescription: format, sourcePeakPQ: masteringPeakPQ(stream.masteringDisplay),
            videoDelay: stream.videoDelay, capability: DisplayCapability(headroom: 1), budgetBytes: 1 << 30
        ) { _ in
            lock.lock()
            count += 1
            lock.unlock()
        }
        var fed = 0
        while fed < 6, let packet = try demuxer.readPacket() {
            try path.decode(
                try makeSampleBuffer(
                    packet: packet, formatDescription: format,
                    timeBaseNum: stream.timeBaseNum, timeBaseDen: stream.timeBaseDen
                ),
                rpu: nil
            )
            fed += 1
        }
        path.flush()
        path.drain()
        lock.lock()
        defer { lock.unlock() }
        // whatever the decoder had not finished belongs to the position the
        // player has left, and the window is emptied with it
        XCTAssertLessThan(count, fed)
    }

    func testNothingFedBeforeAFlushIsEnqueuedAfterIt() throws {
        let (demuxer, stream, format) = try openFixture("tmv-stale.mp4", transfer: .pq, frames: 60)
        let lock = NSLock()
        var flushed = false
        var stale = 0
        let path = try ToneMappedVideo(
            formatDescription: format, sourcePeakPQ: masteringPeakPQ(stream.masteringDisplay),
            videoDelay: stream.videoDelay, capability: DisplayCapability(headroom: 1), budgetBytes: 1 << 30
        ) { _ in
            lock.lock()
            if flushed { stale += 1 }
            lock.unlock()
        }
        while let packet = try demuxer.readPacket() {
            try path.decode(
                try makeSampleBuffer(
                    packet: packet, formatDescription: format,
                    timeBaseNum: stream.timeBaseNum, timeBaseDen: stream.timeBaseDen
                ),
                rpu: nil
            )
        }
        path.flush()
        lock.lock()
        flushed = true
        lock.unlock()
        path.drain()
        lock.lock()
        defer { lock.unlock() }
        // the decoder is still holding frames from before the flush, and none
        // of them belongs on a screen the player has moved on from
        XCTAssertEqual(stale, 0)
    }

    /// The stamp is invalid on such a packet, so every frame keys on zero: one
    /// entry per time would drop all but the first.
    func testAStreamWithNoPresentationTimesStillPlays() throws {
        let (demuxer, stream, format) = try openFixture("tmv-no-pts.mp4", transfer: .pq, frames: 8)
        let lock = NSLock()
        var count = 0
        let path = try ToneMappedVideo(
            formatDescription: format, sourcePeakPQ: masteringPeakPQ(stream.masteringDisplay),
            videoDelay: stream.videoDelay, capability: DisplayCapability(headroom: 1), budgetBytes: 1 << 30
        ) { _ in
            lock.lock()
            count += 1
            lock.unlock()
        }
        while let packet = try demuxer.readPacket() {
            let withoutPTS = Packet(
                streamIndex: packet.streamIndex, pts: nil, dts: packet.dts,
                isKeyframe: packet.isKeyframe, isDisposable: packet.isDisposable,
                duration: packet.duration, data: packet.copiedBytes
            )
            try path.decode(
                try makeSampleBuffer(
                    packet: withoutPTS, formatDescription: format,
                    timeBaseNum: stream.timeBaseNum, timeBaseDen: stream.timeBaseDen
                ),
                rpu: nil
            )
        }
        path.drain()
        lock.lock()
        defer { lock.unlock() }
        XCTAssertEqual(count, 8)
    }

    /// The middle row of the picture the path enqueues first, with `rpu` given
    /// for every frame.
    func middleRow(_ name: String, rpu: DolbyVisionRPU?) throws -> [Float] {
        let (demuxer, stream, format) = try openFixture(name, transfer: .pq, frames: 4)
        let lock = NSLock()
        var pictures: [(time: Double, image: CVPixelBuffer)] = []
        let path = try ToneMappedVideo(
            formatDescription: format, sourcePeakPQ: masteringPeakPQ(stream.masteringDisplay),
            videoDelay: stream.videoDelay, capability: DisplayCapability(headroom: 1), budgetBytes: 1 << 30
        ) { sample in
            guard let image = CMSampleBufferGetImageBuffer(sample) else { return }
            lock.lock()
            pictures.append((CMSampleBufferGetPresentationTimeStamp(sample).seconds, image))
            lock.unlock()
        }
        while let packet = try demuxer.readPacket() {
            try path.decode(
                try makeSampleBuffer(
                    packet: packet, formatDescription: format,
                    timeBaseNum: stream.timeBaseNum, timeBaseDen: stream.timeBaseDen
                ),
                rpu: rpu
            )
        }
        path.drain()
        lock.lock()
        defer { lock.unlock() }
        XCTAssertEqual(pictures.count, 4)
        let picture = try XCTUnwrap(pictures.min { $0.time < $1.time }?.image)
        CVPixelBufferLockBaseAddress(picture, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(picture, .readOnly) }
        // The mapper writes half floats only for a screen with headroom; an
        // SDR destination gets eight bits (DisplayCapability.toneMapPixelFormat).
        // Both are read back as 0...1 so the assertions mean the same thing.
        let base = CVPixelBufferGetBaseAddress(picture)!
        let bytesPerRow = CVPixelBufferGetBytesPerRow(picture)
        let row = CVPixelBufferGetHeight(picture) / 2
        let count = CVPixelBufferGetWidth(picture) * 4
        switch CVPixelBufferGetPixelFormatType(picture) {
        case kCVPixelFormatType_64RGBAHalf:
            let pixels = base.assumingMemoryBound(to: UInt16.self)
            let stride = bytesPerRow / 2
            return (0..<count).map { Float(Float16(bitPattern: pixels[row * stride + $0])) }
        case kCVPixelFormatType_32BGRA:
            let pixels = base.assumingMemoryBound(to: UInt8.self)
            return (0..<count).map { Float(pixels[row * bytesPerRow + $0]) / 255 }
        case let other:
            XCTFail("tone map wrote an unexpected format: \(other)")
            return []
        }
    }

    func testTheRPUsOwnMatrixIsWhatThePictureIsDecodedWith() throws {
        // No level 1 block, so the brightness is the mastering display's in
        // both runs and the colour matrix is the only difference. A profile 5
        // base layer is why this matters: it is not a BT.2020 picture at all.
        let rpu = DolbyVisionRPU(
            profile: 5, level: 6, blBitDepth: 10, elBitDepth: 10, vdrBitDepth: 12,
            disableResidual: true, sceneRefresh: false, sourceMinPQ: 0, sourceMaxPQ: 3079,
            yccToRGB: [0.5, 0, 0, 0, 0.5, 0, 0, 0, 0.5], yccOffset: [0, 0, 0],
            rgbToLMS: [Float](repeating: 0, count: 9), minPQ: nil, maxPQ: nil, avgPQ: nil, reshaping: nil
        )
        let withRPU = try middleRow("tmv-matrix-rpu.mp4", rpu: rpu)
        let withConstants = try middleRow("tmv-matrix-plain.mp4", rpu: nil)
        XCTAssertEqual(withRPU.count, withConstants.count)
        XCTAssertNotEqual(withRPU, withConstants)
    }

    func testADegenerateLevelOneRangeFallsBackToTheMasteringDisplay() throws {
        // A level 1 block whose two ends are the same describes no range at
        // all. Taken as one it maps every sample above black to the display's
        // peak, which is a white frame; the mastering display's numbers are
        // what a frame with no level 1 block already gets, so they stand in.
        let rpu = DolbyVisionRPU(
            profile: 8, level: 6, blBitDepth: 10, elBitDepth: 10, vdrBitDepth: 12,
            disableResidual: true, sceneRefresh: false, sourceMinPQ: 0, sourceMaxPQ: 3079,
            yccToRGB: [Float](repeating: 0, count: 9), yccOffset: [0, 0, 0],
            rgbToLMS: [Float](repeating: 0, count: 9), minPQ: 2081, maxPQ: 2081, avgPQ: 2081,
            reshaping: nil
        )
        let degenerate = try middleRow("tmv-degenerate-l1.mp4", rpu: rpu)
        let mastering = try middleRow("tmv-degenerate-none.mp4", rpu: nil)
        XCTAssertEqual(degenerate, mastering)
        // and the failure it stands guard over: a row pinned at the peak
        XCTAssertFalse(degenerate.allSatisfy { $0 > 0.99 })
    }

    func testDecodeTimingIsMeanAndWorstAcrossFramesDecodedSoFar() throws {
        let (demuxer, stream, format) = try openFixture("tmv-decode-timing.mp4", transfer: .pq, frames: 6)
        let path = try ToneMappedVideo(
            formatDescription: format, sourcePeakPQ: masteringPeakPQ(stream.masteringDisplay),
            videoDelay: stream.videoDelay, capability: DisplayCapability(headroom: 1), budgetBytes: 1 << 30
        ) { _ in }
        XCTAssertEqual(path.decodeTiming.meanMilliseconds, 0)
        XCTAssertEqual(path.decodeTiming.worstMilliseconds, 0)
        // 0 before anything is timed and 0 for a real, instant decode read the
        // same; this is what tells the two apart
        XCTAssertEqual(path.decodeTiming.sampleCount, 0)
        while let packet = try demuxer.readPacket() {
            try path.decode(
                try makeSampleBuffer(
                    packet: packet, formatDescription: format,
                    timeBaseNum: stream.timeBaseNum, timeBaseDen: stream.timeBaseDen
                ),
                rpu: nil
            )
        }
        path.drain()
        let timing = path.decodeTiming
        XCTAssertGreaterThan(timing.meanMilliseconds, 0)
        XCTAssertGreaterThanOrEqual(timing.worstMilliseconds, timing.meanMilliseconds)
        XCTAssertEqual(timing.sampleCount, 6)
    }

    func testItRefusesNothingItCanDecode() throws {
        let (demuxer, stream, format) = try openFixture("tmv-plain.mp4", transfer: .pq, frames: 8)
        let lock = NSLock()
        var count = 0
        let path = try ToneMappedVideo(
            formatDescription: format, sourcePeakPQ: masteringPeakPQ(stream.masteringDisplay),
            videoDelay: stream.videoDelay, capability: DisplayCapability(headroom: 1), budgetBytes: 1 << 30
        ) { _ in
            lock.lock()
            count += 1
            lock.unlock()
        }
        while let packet = try demuxer.readPacket() {
            try path.decode(
                try makeSampleBuffer(
                    packet: packet, formatDescription: format,
                    timeBaseNum: stream.timeBaseNum, timeBaseDen: stream.timeBaseDen
                ),
                rpu: nil
            )
        }
        path.drain()
        lock.lock()
        defer { lock.unlock() }
        // no RPU anywhere: the mastering display is what the curve uses
        XCTAssertEqual(count, 8)
    }

    /// A picture is handed over with nothing this object owns held. The
    /// handover runs on a VideoToolbox decode thread and whatever takes the
    /// picture can be full for as long as a pause lasts, so a lock held
    /// across it is held for that long too - and a seek, a stop and a close
    /// all flush this path from the caller's own thread, which is the main
    /// thread.
    func testAPictureIsHandedOverWithNothingOfOursHeld() throws {
        let (demuxer, stream, format) = try openFixture("tmv-handoff.mp4", transfer: .pq, frames: 6)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let firstPicture = NSLock()
        var handedOver = 0
        let path = try ToneMappedVideo(
            formatDescription: format, sourcePeakPQ: masteringPeakPQ(stream.masteringDisplay),
            videoDelay: stream.videoDelay, capability: DisplayCapability(headroom: 1),
            budgetBytes: 1 << 30
        ) { _ in
            firstPicture.lock()
            handedOver += 1
            let isFirst = handedOver == 1
            firstPicture.unlock()
            guard isFirst else { return }
            // One handover stopped where a full sample queue stops it. The
            // bound is the test's own way out, not the pipeline's.
            entered.signal()
            _ = release.wait(timeout: .now() + 10)
        }
        let fed = DispatchSemaphore(value: 0)
        // VideoToolbox holds the submitting thread once enough frames are out,
        // so the feed cannot be this thread: it has a stopped handover to
        // catch.
        Thread.detachNewThread {
            while let packet = try? demuxer.readPacket() {
                try? path.decode(
                    try makeSampleBuffer(
                        packet: packet, formatDescription: format,
                        timeBaseNum: stream.timeBaseNum, timeBaseDen: stream.timeBaseDen
                    ),
                    rpu: nil
                )
            }
            fed.signal()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 30), .success, "no picture was ever mapped")

        let flushed = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            path.flush()
            flushed.signal()
        }
        XCTAssertEqual(
            flushed.wait(timeout: .now() + 5), .success,
            "a flush was held back by a picture waiting to be taken"
        )
        release.signal()
        XCTAssertEqual(fed.wait(timeout: .now() + 30), .success)
        path.drain()
    }
}

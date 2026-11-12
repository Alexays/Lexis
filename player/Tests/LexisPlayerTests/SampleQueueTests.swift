import AVFoundation
import CoreMedia
import CoreVideo
import LexisTestSupport
import XCTest
@testable import LexisPlayer

final class SampleQueueTests: XCTestCase {
    /// Real, distinct CMSampleBuffers in ascending presentation order, from
    /// a small fixture: this is what a decode thread hands the queue, and
    /// what pts-based ordering has to sort correctly.
    private func realSamples(count: Int) throws -> [CMSampleBuffer] {
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "sample-queue.mp4",
            codec: .hevc, width: 320, height: 240, frameCount: count, fps: 24
        )
        let demuxer = try Demuxer(url: url)
        let stream = try XCTUnwrap(demuxer.streams.first { $0.kind == .video })
        let formatDescription = try makeFormatDescription(for: stream)
        var samples: [CMSampleBuffer] = []
        while let packet = try demuxer.readPacket() {
            guard packet.streamIndex == stream.index else { continue }
            samples.append(try makeSampleBuffer(
                packet: packet, formatDescription: formatDescription,
                timeBaseNum: stream.timeBaseNum, timeBaseDen: stream.timeBaseDen
            ))
        }
        return samples
    }

    private func pts(_ sample: CMSampleBuffer) -> Double {
        CMSampleBufferGetPresentationTimeStamp(sample).seconds
    }

    func testOrdersOutOfOrderPushesByPresentationTime() throws {
        let samples = try realSamples(count: 12)
        XCTAssertGreaterThanOrEqual(samples.count, 6)
        let queue = SampleQueue(targetSeconds: 100, capacityBytes: 1 << 30)
        // pushed in a scrambled order, as the async decode reorder window
        // can hand them back
        for sample in samples.shuffled() {
            XCTAssertTrue(queue.push(sample))
        }
        var popped: [Double] = []
        while let sample = queue.pop() { popped.append(pts(sample)) }
        XCTAssertEqual(popped, popped.sorted())
        XCTAssertEqual(popped.count, samples.count)
    }

    func testPopOnAnEmptyQueueNeverBlocks() {
        let queue = SampleQueue(targetSeconds: 1.0, capacityBytes: 1 << 30)
        XCTAssertNil(queue.pop())
    }

    func testBufferedSecondsIsTheSpanOfWhatIsQueued() throws {
        let samples = try realSamples(count: 25)
        let queue = SampleQueue(targetSeconds: 100, capacityBytes: 1 << 30)
        XCTAssertEqual(queue.bufferedSeconds, 0)
        for sample in samples { XCTAssertTrue(queue.push(sample)) }
        let expected = pts(samples.max { pts($0) < pts($1) }!)
            - pts(samples.min { pts($0) < pts($1) }!)
        XCTAssertEqual(queue.bufferedSeconds, expected, accuracy: 0.001)
    }

    func testPushParksAtTheTargetAndWakesOncePopped() throws {
        try skipUnlessRealtimeTests()
        let samples = try realSamples(count: 25)
        // 24 fps: consecutive frames are ~0.04 s apart, so a target well
        // under the fixture's own length parks partway through pushing it.
        let queue = SampleQueue(targetSeconds: 0.2, capacityBytes: 1 << 30)
        let filled = expectation(description: "every sample eventually gets pushed")
        let pusher = Thread {
            for sample in samples { XCTAssertTrue(queue.push(sample)) }
            filled.fulfill()
        }
        pusher.start()
        Thread.sleep(forTimeInterval: 0.3)
        // the target is far short of the whole fixture, so the pusher must
        // still be parked well short of having pushed everything
        XCTAssertLessThan(queue.bufferedSeconds, Double(samples.count) * 0.04)

        let drained = expectation(description: "draining unparks the pusher and empties it")
        let popper = Thread {
            var count = 0
            while count < samples.count {
                if queue.pop() != nil { count += 1 } else { Thread.sleep(forTimeInterval: 0.01) }
            }
            drained.fulfill()
        }
        popper.start()
        wait(for: [filled, drained], timeout: 3)
    }

    /// The pair a producer that cannot park uses instead: it waits for room
    /// before making the sample, on a thread of its own, and whatever it then
    /// hands over is taken whatever the queue holds. What lands past the
    /// target is what was already in flight when the room ran out.
    func testTheWaitParksAtTheTargetAndTheHandoverItselfNeverDoes() throws {
        try skipUnlessRealtimeTests()
        let samples = try realSamples(count: 25)
        let queue = SampleQueue(targetSeconds: 0.2, capacityBytes: 1 << 30)
        let filled = expectation(description: "the wait for room comes back once popped")
        let pusher = Thread {
            for sample in samples {
                XCTAssertTrue(queue.waitForRoom())
                XCTAssertTrue(queue.pushWithoutWaiting(sample))
            }
            filled.fulfill()
        }
        pusher.start()
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertLessThan(queue.bufferedSeconds, Double(samples.count) * 0.04)

        let drained = expectation(description: "draining unparks the wait and empties it")
        let popper = Thread {
            var count = 0
            while count < samples.count {
                if queue.pop() != nil { count += 1 } else { Thread.sleep(forTimeInterval: 0.01) }
            }
            drained.fulfill()
        }
        popper.start()
        wait(for: [filled, drained], timeout: 3)
    }

    func testAHandoverIsTakenPastTheTargetRatherThanWaitingForRoom() throws {
        let samples = try realSamples(count: 25)
        let queue = SampleQueue(targetSeconds: 0.2, capacityBytes: 1 << 30)
        for sample in samples { XCTAssertTrue(queue.pushWithoutWaiting(sample)) }
        // nothing popped anything: the whole fixture is in there, well past
        // the fifth of a second the target allows
        XCTAssertGreaterThan(queue.bufferedSeconds, 0.2)
        var count = 0
        while queue.pop() != nil { count += 1 }
        XCTAssertEqual(count, samples.count)
    }

    func testFlushEmptiesTheQueue() throws {
        let samples = try realSamples(count: 6)
        let queue = SampleQueue(targetSeconds: 100, capacityBytes: 1 << 30)
        for sample in samples { XCTAssertTrue(queue.push(sample)) }
        XCTAssertGreaterThan(queue.bufferedSeconds, 0)
        queue.flush()
        XCTAssertEqual(queue.bufferedSeconds, 0)
        XCTAssertNil(queue.pop())
    }

    func testCloseRefusesFurtherPushes() throws {
        let samples = try realSamples(count: 2)
        let queue = SampleQueue(targetSeconds: 100, capacityBytes: 1 << 30)
        queue.close()
        XCTAssertFalse(queue.push(samples[0]))
    }

    /// One decoded picture of `width` x `height`, as the tone-mapped path
    /// hands them over: an image buffer, not a block of compressed bytes.
    private func pictureSample(width: Int, height: Int, seconds: Double) throws -> CMSampleBuffer {
        var pixels: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(
                kCFAllocatorDefault, width, height, kCVPixelFormatType_64RGBAHalf,
                [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary,
                &pixels),
            kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixels)
        var description: CMVideoFormatDescription?
        XCTAssertEqual(
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault, imageBuffer: buffer,
                formatDescriptionOut: &description),
            noErr)
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 600),
            decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        XCTAssertEqual(
            CMSampleBufferCreateForImageBuffer(
                allocator: kCFAllocatorDefault, imageBuffer: buffer, dataReady: true,
                makeDataReadyCallback: nil, refcon: nil,
                formatDescription: try XCTUnwrap(description), sampleTiming: &timing,
                sampleBufferOut: &sample),
            noErr)
        return try XCTUnwrap(sample)
    }

    /// A second of pictures is not a size. The seconds target here is far
    /// beyond anything the test pushes, so only the byte ceiling can hold the
    /// queue down - and it has to, because these samples are images, where
    /// the span between two timestamps says nothing about what they cost.
    func testAQueueOfPicturesIsHeldDownByBytesWhereSecondsSayNothing() throws {
        try skipUnlessRealtimeTests()
        let side = 512
        let frameBytes = side * side * 8
        let ceiling = frameBytes * 4
        let queue = SampleQueue(targetSeconds: 100, capacityBytes: ceiling)
        var samples: [CMSampleBuffer] = []
        for index in 0..<24 {
            samples.append(try pictureSample(
                width: side, height: side, seconds: Double(index) / 24))
        }

        let pushed = expectation(description: "every picture lands once the queue drains")
        let pusher = Thread {
            for sample in samples { XCTAssertTrue(queue.push(sample)) }
            pushed.fulfill()
        }
        pusher.start()
        // Long enough for an unbounded queue to have swallowed all 24.
        Thread.sleep(forTimeInterval: 0.5)
        // The ceiling bounds depth, and one sample may always land on an
        // empty queue, so the most it can ever hold is the ceiling plus the
        // one that was allowed in on top of it.
        XCTAssertLessThanOrEqual(queue.bufferedBytes, ceiling + frameBytes)
        XCTAssertLessThan(queue.bufferedBytes, frameBytes * 24)

        let drained = expectation(description: "draining unparks the pusher")
        let popper = Thread {
            var count = 0
            while count < samples.count {
                if queue.pop() != nil { count += 1 } else { Thread.sleep(forTimeInterval: 0.01) }
            }
            drained.fulfill()
        }
        popper.start()
        wait(for: [pushed, drained], timeout: 5)
        XCTAssertEqual(queue.bufferedBytes, 0)
    }

    /// A queue the byte ceiling holds to four pictures never gets near half
    /// its second, and has to read as half full at two pictures all the same:
    /// that is the depth a refill waiting on it can count on.
    func testHalfFullFollowsWhicheverBoundIsTighter() throws {
        let side = 64
        let probe = try pictureSample(width: side, height: side, seconds: 0)
        let frameBytes = CVPixelBufferGetDataSize(try XCTUnwrap(CMSampleBufferGetImageBuffer(probe)))
        let queue = SampleQueue(targetSeconds: 1, capacityBytes: frameBytes * 4)
        XCTAssertNil(queue.headPresentationSeconds)
        XCTAssertFalse(queue.isHalfFull)
        XCTAssertTrue(queue.push(try pictureSample(width: side, height: side, seconds: 2.0 / 24)))
        XCTAssertFalse(queue.isHalfFull)
        XCTAssertTrue(queue.push(try pictureSample(width: side, height: side, seconds: 1.0 / 24)))
        XCTAssertTrue(queue.isHalfFull)
        XCTAssertEqual(try XCTUnwrap(queue.headPresentationSeconds), 1.0 / 24, accuracy: 0.002)
    }

    /// The other direction, and the one a ceiling gets wrong: a picture too
    /// big for the whole budget still has to reach the sink. Nothing but this
    /// push can free the room it is short of, so a queue that parked here
    /// would park for good and the film would stop on the frame before it.
    func testAPictureBiggerThanTheWholeCeilingStillGoesThrough() throws {
        let side = 512
        let queue = SampleQueue(targetSeconds: 100, capacityBytes: 1024)
        for index in 0..<4 {
            let landed = expectation(description: "picture \(index) lands")
            let pusher = Thread {
                XCTAssertTrue(queue.push(
                    try! self.pictureSample(width: side, height: side, seconds: Double(index))))
                landed.fulfill()
            }
            pusher.start()
            wait(for: [landed], timeout: 2)
            XCTAssertNotNil(queue.pop())
        }
    }

    func testSteadyStateAllocatesNothing() throws {
        let samples = try realSamples(count: 4)
        let queue = SampleQueue(targetSeconds: 100, capacityBytes: 1 << 30)
        // warms the free list up to the deepest concurrent depth this test
        // ever reaches: pushing all four before popping any.
        for sample in samples { XCTAssertTrue(queue.push(sample)) }
        while queue.pop() != nil {}
        let warm = queue.allocationsAfterWarmup
        XCTAssertGreaterThan(warm, 0)

        for _ in 0..<500 {
            XCTAssertTrue(queue.push(samples[0]))
            XCTAssertNotNil(queue.pop())
        }
        XCTAssertEqual(queue.allocationsAfterWarmup, warm)
    }

    /// A queue released with samples still in it gives their pictures back.
    /// It is released that way on every teardown: the decode threads close
    /// the queues and stop, and whatever the sink had not drained yet is
    /// still in the list.
    ///
    /// Counted in pool buffers rather than in bytes, because a pool that
    /// cannot get a buffer back says so exactly: the pool's whole allowance
    /// is four pictures, so the third round is the one that finds nothing
    /// left if the two before it kept theirs.
    ///
    /// Two samples a round, never one: a single node links to nothing, and
    /// it takes an adjacent pair for the two links to hold each other.
    func testAQueueReleasedHoldingSamplesGivesThePicturesBack() throws {
        let width = 320, height = 240
        let pool = try PixelBufferPool(
            width: Int32(width), height: Int32(height),
            pixelFormat: kCVPixelFormatType_32BGRA, warmCount: 1,
            ceilingBytes: 4 * width * height * 4
        )
        XCTAssertEqual(pool.capacity, 4)
        for round in 0..<16 {
            let queue = SampleQueue(targetSeconds: 100, capacityBytes: 1 << 30)
            for index in 0..<2 {
                let picture = try XCTUnwrap(
                    pool.take(), "round \(round): every picture before this one is still held")
                XCTAssertTrue(queue.push(
                    try pictureSample(picture, seconds: Double(round * 2 + index))))
            }
            // What a teardown does, and all it does: the samples still queued
            // are never popped.
            queue.close()
        }
        XCTAssertEqual(pool.poolMisses, 0)
    }

    /// One picture in a CMSampleBuffer, the way both decode paths hand one on.
    private func pictureSample(_ picture: CVPixelBuffer, seconds: Double) throws -> CMSampleBuffer {
        var description: CMVideoFormatDescription?
        XCTAssertEqual(
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault, imageBuffer: picture,
                formatDescriptionOut: &description
            ), noErr)
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 600),
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        XCTAssertEqual(
            CMSampleBufferCreateForImageBuffer(
                allocator: kCFAllocatorDefault, imageBuffer: picture, dataReady: true,
                makeDataReadyCallback: nil, refcon: nil,
                formatDescription: try XCTUnwrap(description),
                sampleTiming: &timing, sampleBufferOut: &sample
            ), noErr)
        return try XCTUnwrap(sample)
    }
}

final class PixelBufferPoolTests: XCTestCase {
    func testTakeReturnsWarmBuffersWithNoMisses() throws {
        let pool = try PixelBufferPool(
            width: 64, height: 64, pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            warmCount: 3, ceilingBytes: 1 << 30
        )
        var held: [CVPixelBuffer] = []
        for _ in 0..<3 {
            let buffer = pool.take()
            XCTAssertNotNil(buffer)
            if let buffer { held.append(buffer) }
        }
        XCTAssertEqual(pool.poolMisses, 0)
        held.removeAll()
    }

    func testWarmedTakeAndReleaseCyclesHitZeroMisses() throws {
        let pool = try PixelBufferPool(
            width: 64, height: 64, pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            warmCount: 2, ceilingBytes: 1 << 30
        )
        for _ in 0..<20 {
            var held: [CVPixelBuffer] = []
            for _ in 0..<2 {
                guard let buffer = pool.take() else { continue }
                held.append(buffer)
            }
            held.removeAll()
        }
        XCTAssertEqual(pool.poolMisses, 0)
    }

    /// The warm count is what the pool keeps ready, never the ceiling: a
    /// caller holding every buffer it has taken still gets the next one.
    func testTakingMoreThanTheWarmCountStillHandsBuffersBack() throws {
        let pool = try PixelBufferPool(
            width: 64, height: 64, pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            warmCount: 1, ceilingBytes: 1 << 30
        )
        var held: [CVPixelBuffer] = []
        for _ in 0..<8 {
            held.append(try XCTUnwrap(pool.take()))
        }
        XCTAssertEqual(pool.poolMisses, 0)
        held.removeAll()
    }

    /// The defect a count-based ceiling caused: a 320x240 file whose pipeline
    /// held far more than eight pictures at once lost every one the pool
    /// refused - 125 of 180 on the bench. Against the ceiling the software
    /// decoder actually uses, a picture this small has to come back 180 times
    /// over with every one of them still held.
    func testASmallPictureIsNotRationedByAByteCeilingSizedForA4KOne() throws {
        let pool = try PixelBufferPool(
            width: 320, height: 240, pixelFormat: kCVPixelFormatType_420YpCbCr8Planar,
            warmCount: 8, ceilingBytes: 256 * 1024 * 1024
        )
        var held: [CVPixelBuffer] = []
        for _ in 0..<180 {
            held.append(try XCTUnwrap(pool.take()))
        }
        XCTAssertEqual(pool.poolMisses, 0)
        held.removeAll()
    }

    /// The same ceiling, the same policy, a picture 200 times the size: what
    /// a small stream gets thousands of, a 4K one gets twenty-one of, and the
    /// twenty-second is refused rather than paid for.
    func testALargePictureIsRationedByTheSameByteCeiling() throws {
        let pool = try PixelBufferPool(
            width: 3840, height: 2160, pixelFormat: kCVPixelFormatType_420YpCbCr8Planar,
            warmCount: 8, ceilingBytes: 256 * 1024 * 1024
        )
        XCTAssertLessThanOrEqual(pool.capacity, 24)
        var held: [CVPixelBuffer] = []
        while held.count < pool.capacity {
            held.append(try XCTUnwrap(pool.take()))
        }
        XCTAssertNil(pool.take())
        XCTAssertEqual(pool.poolMisses, 1)
        held.removeAll()
    }

    /// A pool keeps every buffer its busiest moment needed, resident, for as
    /// long as it lives. This is what a memory warning gets back: the ones
    /// nothing is using, freed for real rather than merely recycled.
    func testReleasingSpareBuffersGivesTheirMemoryBack() throws {
        let pool = try PixelBufferPool(
            width: 3840, height: 2160, pixelFormat: kCVPixelFormatType_420YpCbCr8Planar,
            warmCount: 1, ceilingBytes: 256 * 1024 * 1024
        )
        var held: [CVPixelBuffer] = []
        for _ in 0..<16 {
            let buffer = try XCTUnwrap(pool.take())
            // Written, or the pages are never faulted in and the footprint
            // this test measures would not have counted them in the first
            // place. A decoder writes every one of them.
            CVPixelBufferLockBaseAddress(buffer, [])
            for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
                memset(
                    CVPixelBufferGetBaseAddressOfPlane(buffer, plane), 1,
                    CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
                        * CVPixelBufferGetHeightOfPlane(buffer, plane))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            held.append(buffer)
        }
        // Back to the pool, which keeps them: recycled is not freed.
        held.removeAll()
        let recycled = footprintBytes()
        pool.releaseSpareBuffers()
        // 16 pictures of 4K planar is about 190 MB; anything under half of
        // that came back is the pool still sitting on them.
        XCTAssertGreaterThan(recycled - footprintBytes(), 95 * 1_048_576)
    }
}

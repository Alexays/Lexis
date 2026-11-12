import CFFmpeg
import CLexisStream
import Foundation
import LexisCoreStream
import LexisTestSupport
import XCTest
@testable import LexisPlayer

/// A fixed byte buffer served through `MediaStreamIO`, recording every real
/// `read`/`seek` the pump makes so a test can assert on fetch counts and
/// seek targets without a network round trip.
private final class MemoryStream {
    let bytes: [UInt8]
    private(set) var lastSeekOffset: Int64 = -1
    private(set) var lastSeekWhence: Int32 = -1
    private var position: Int64 = 0
    private let lock = NSLock()
    /// Delays every real read by this long, so a test can park inside one.
    var readDelay: TimeInterval = 0

    init(bytes: [UInt8]) { self.bytes = bytes }

    var stream: MediaStreamIO {
        MediaStreamIO(
            handle: Unmanaged.passUnretained(self).toOpaque(),
            read: memoryStreamRead,
            seek: memoryStreamSeek,
            size: memoryStreamSize,
            close: memoryStreamClose
        )
    }

    fileprivate func read(into destination: UnsafeMutablePointer<UInt8>, _ length: Int32) -> Int64 {
        let delay = readDelay
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        lock.lock()
        defer { lock.unlock() }
        let remaining = max(0, Int64(bytes.count) - position)
        let n = min(Int64(length), remaining)
        guard n > 0 else { return 0 }
        bytes.withUnsafeBufferPointer { buf in
            destination.update(from: buf.baseAddress! + Int(position), count: Int(n))
        }
        position += n
        return n
    }

    fileprivate func seek(_ offset: Int64, _ whence: Int32) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        lastSeekOffset = offset
        lastSeekWhence = whence
        switch whence {
        case 0: position = offset
        case 1: position += offset
        case 2: position = Int64(bytes.count) + offset
        default: return Int64(LexisErrorIO)
        }
        return position
    }

    fileprivate var size: Int64 { Int64(bytes.count) }
    fileprivate func close() {}
}

private let memoryStreamRead: MediaStreamIO.Read = { handle, buffer, length in
    guard let handle, let buffer else { return Int64(LexisErrorIO) }
    return Unmanaged<MemoryStream>.fromOpaque(handle).takeUnretainedValue().read(into: buffer, length)
}

private let memoryStreamSeek: MediaStreamIO.Seek = { handle, offset, whence in
    guard let handle else { return Int64(LexisErrorIO) }
    return Unmanaged<MemoryStream>.fromOpaque(handle).takeUnretainedValue().seek(offset, whence)
}

private let memoryStreamSize: MediaStreamIO.Size = { handle in
    guard let handle else { return -1 }
    return Unmanaged<MemoryStream>.fromOpaque(handle).takeUnretainedValue().size
}

private let memoryStreamClose: MediaStreamIO.Close = { handle in
    guard let handle else { return }
    Unmanaged<MemoryStream>.fromOpaque(handle).takeUnretainedValue().close()
}

/// A stream of a given length whose bytes are made up as they are asked for.
/// What a footprint measurement needs where `MemoryStream` will not do: half
/// a gigabyte of body held in the test would swamp the window it is weighing.
private final class GeneratedStream {
    let total: Int64
    private var position: Int64 = 0
    private let lock = NSLock()

    init(total: Int64) { self.total = total }

    var stream: MediaStreamIO {
        MediaStreamIO(
            handle: Unmanaged.passUnretained(self).toOpaque(),
            read: generatedRead,
            seek: generatedSeek,
            size: { handle in
                Unmanaged<GeneratedStream>.fromOpaque(handle!).takeUnretainedValue().total
            },
            close: { _ in }
        )
    }

    fileprivate func read(into destination: UnsafeMutablePointer<UInt8>, _ length: Int32) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        let n = min(Int64(length), total - position)
        guard n > 0 else { return 0 }
        destination.update(repeating: UInt8(truncatingIfNeeded: position >> 21), count: Int(n))
        position += n
        return n
    }

    fileprivate func seek(_ offset: Int64, _ whence: Int32) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        switch whence {
        case 0: position = offset
        case 1: position += offset
        case 2: position = total + offset
        default: return Int64(LexisErrorIO)
        }
        return position
    }
}

private let generatedRead: MediaStreamIO.Read = { handle, buffer, length in
    guard let handle, let buffer else { return Int64(LexisErrorIO) }
    return Unmanaged<GeneratedStream>.fromOpaque(handle).takeUnretainedValue()
        .read(into: buffer, length)
}

private let generatedSeek: MediaStreamIO.Seek = { handle, offset, whence in
    guard let handle else { return Int64(LexisErrorIO) }
    return Unmanaged<GeneratedStream>.fromOpaque(handle).takeUnretainedValue().seek(offset, whence)
}

/// Records where each fetch is asked to write and how much, then fills it.
/// Where the second fetch lands relative to the first is the only outside
/// evidence of whether the pump reads straight into the window or into a
/// buffer of its own that is copied in afterwards.
private final class SpanRecordingStream {
    private let lock = NSLock()
    private var destinations: [(address: UInt, length: Int)] = []

    var stream: MediaStreamIO {
        MediaStreamIO(
            handle: Unmanaged.passUnretained(self).toOpaque(),
            read: spanRecordingRead,
            seek: { _, offset, _ in offset },
            size: { _ in 1 << 30 },
            close: { _ in }
        )
    }

    var recorded: [(address: UInt, length: Int)] {
        lock.lock(); defer { lock.unlock() }
        return destinations
    }

    fileprivate func read(into destination: UnsafeMutablePointer<UInt8>, _ length: Int32) -> Int64 {
        lock.lock()
        destinations.append((UInt(bitPattern: destination), Int(length)))
        lock.unlock()
        destination.update(repeating: 0xA5, count: Int(length))
        return Int64(length)
    }
}

private let spanRecordingRead: MediaStreamIO.Read = { handle, buffer, length in
    guard let handle, let buffer else { return Int64(LexisErrorIO) }
    return Unmanaged<SpanRecordingStream>.fromOpaque(handle).takeUnretainedValue()
        .read(into: buffer, length)
}

final class ByteCacheTests: XCTestCase {
    /// Copied a page at a time rather than written a byte at a time: the
    /// pattern repeats every 256 bytes, and these sources run to tens of
    /// megabytes each in a build with no optimisation to lean on.
    private func sequentialBytes(_ count: Int) -> [UInt8] {
        var page = [UInt8](repeating: 0, count: 256)
        for index in 0..<256 { page[index] = UInt8(index) }
        var out = [UInt8](repeating: 0, count: count)
        out.withUnsafeMutableBytes { destination in
            page.withUnsafeBytes { source in
                var offset = 0
                while offset < count {
                    let span = min(256, count - offset)
                    destination.baseAddress!.advanced(by: offset)
                        .copyMemory(from: source.baseAddress!, byteCount: span)
                    offset += span
                }
            }
        }
        return out
    }

    private func flatBytes(_ count: Int) -> [UInt8] {
        [UInt8](repeating: 0x5A, count: count)
    }

    /// The pump reads straight into the ring: each fetch lands right after
    /// the one before it, never in a span of its own copied in afterwards
    /// under the lock every reader waits on.
    func testThePumpFetchesStraightIntoTheWindow() {
        let source = SpanRecordingStream()
        let cache = ByteCache(io: source.stream, interrupt: nil)
        defer { cache.stream.close(cache.stream.handle) }
        _ = readExact(cache, count: 8)
        let deadline = Date(timeIntervalSinceNow: 5)
        while source.recorded.count < 2, Date() < deadline { usleep(2000) }
        let recorded = source.recorded
        XCTAssertGreaterThanOrEqual(recorded.count, 2)
        guard recorded.count >= 2 else { return }
        XCTAssertEqual(recorded[1].address, recorded[0].address + UInt(recorded[0].length))
    }

    /// Reads exactly `count` bytes through the cache's raw `MediaStreamIO`,
    /// looping the way FFmpeg's own avio caller does: a single call answers
    /// with whatever is currently in the window, never blocking for the
    /// whole request.
    private func readExact(_ cache: ByteCache, count: Int) -> [UInt8] {
        var result = [UInt8]()
        result.reserveCapacity(count)
        var chunk = [UInt8](repeating: 0, count: min(count, 256 * 1024))
        while result.count < count {
            let want = min(chunk.count, count - result.count)
            let n = chunk.withUnsafeMutableBufferPointer { buf in
                cache.stream.read(cache.stream.handle, buf.baseAddress, Int32(want))
            }
            guard n > 0 else { break }
            result.append(contentsOf: chunk[0..<Int(n)])
        }
        return result
    }

    func testSmallReadsAreServedFromTheWindow() throws {
        let source = MemoryStream(bytes: sequentialBytes(4 * 1024 * 1024 + 8192))
        let cache = ByteCache(io: source.stream, interrupt: nil)
        defer { cache.stream.close(cache.stream.handle) }
        for _ in 0..<1000 {
            let chunk = readExact(cache, count: 4096)
            XCTAssertEqual(chunk.count, 4096)
        }
        let expectedFetches = Int(ceil(Double(4 * 1024 * 1024) / Double(ByteCache.spanSize))) + 1
        XCTAssertLessThanOrEqual(cache.statistics.fetchCount, expectedFetches)
    }

    func testABackwardSeekInsideTheWindowCostsNoFetch() throws {
        let source = MemoryStream(bytes: sequentialBytes(8 * 1024 * 1024 + 4096))
        let cache = ByteCache(io: source.stream, interrupt: nil)
        defer { cache.stream.close(cache.stream.handle) }
        let first = readExact(cache, count: 8 * 1024 * 1024)
        XCTAssertEqual(first.count, 8 * 1024 * 1024)
        let fetchesAfterFirstRead = cache.statistics.fetchCount
        let hitsBefore = cache.statistics.windowHits

        let result = cache.stream.seek(cache.stream.handle, -4 * 1024 * 1024, 1)
        XCTAssertEqual(result, 4 * 1024 * 1024)

        let again = readExact(cache, count: 4096)
        XCTAssertEqual(again, Array(first.suffix(4096)))

        XCTAssertEqual(cache.statistics.fetchCount, fetchesAfterFirstRead)
        XCTAssertGreaterThan(cache.statistics.windowHits, hitsBefore)
    }

    /// The half an mp4 makes on almost every packet: its audio and its video
    /// sit in different regions of the file, so the demuxer walks forward and
    /// back across bytes the window is already holding.
    func testAForwardSeekInsideTheWindowCostsNoFetch() throws {
        let total = 8 * 1024 * 1024 + 4096
        let source = MemoryStream(bytes: sequentialBytes(total))
        let cache = ByteCache(io: source.stream, interrupt: nil)
        defer { cache.stream.close(cache.stream.handle) }
        let whole = readExact(cache, count: total)
        XCTAssertEqual(whole.count, total)
        // read to the end first, so the pump has nothing of its own left to
        // fetch and any fetch after this point is a refetch of the window
        let settled = Date(timeIntervalSinceNow: 2)
        var fetchesBefore = cache.statistics.fetchCount
        while Date() < settled {
            usleep(100_000)
            let now = cache.statistics.fetchCount
            if now == fetchesBefore { break }
            fetchesBefore = now
        }
        let hitsBefore = cache.statistics.windowHits

        XCTAssertEqual(cache.stream.seek(cache.stream.handle, 1024 * 1024, 0), 1024 * 1024)
        XCTAssertEqual(cache.stream.seek(cache.stream.handle, 6 * 1024 * 1024, 0), 6 * 1024 * 1024)
        let again = readExact(cache, count: 4096)
        XCTAssertEqual(again, Array(whole[(6 * 1024 * 1024)..<(6 * 1024 * 1024 + 4096)]))

        XCTAssertEqual(cache.statistics.fetchCount, fetchesBefore)
        XCTAssertGreaterThan(cache.statistics.windowHits, hitsBefore + 1)
    }

    /// The other half of that walk: the head jumps a short way past what the
    /// pump has fetched, and the bytes behind it are the ones it comes back
    /// for a packet later. Repositioning there throws those away.
    func testAShortForwardGapDoesNotRepositionTheRealStream() throws {
        try skipUnlessRealtimeTests()
        let source = MemoryStream(bytes: sequentialBytes(64 * 1024 * 1024))
        // slow enough that the pump is still a span or two in when the jump
        // lands, which is what makes the gap a gap
        source.readDelay = 0.1
        let cache = ByteCache(io: source.stream, interrupt: nil)
        defer { cache.stream.close(cache.stream.handle) }
        _ = readExact(cache, count: 4096)

        // within a span of the frontier, which the first fetch put a span in
        let ahead = Int64(ByteCache.spanSize + ByteCache.spanSize / 2)
        XCTAssertEqual(cache.stream.seek(cache.stream.handle, ahead, 0), ahead)
        let there = readExact(cache, count: 4096)
        XCTAssertEqual(there, Array(source.bytes[Int(ahead)..<Int(ahead) + 4096]))

        let back = Int64(1024 * 1024)
        XCTAssertEqual(cache.stream.seek(cache.stream.handle, back, 0), back)
        let again = readExact(cache, count: 4096)
        XCTAssertEqual(again, Array(source.bytes[Int(back)..<Int(back) + 4096]))

        XCTAssertEqual(source.lastSeekOffset, -1, "the real stream was repositioned")
    }

    /// A forward seek well past the frontier, still inside what the window
    /// could hold, repositions: fetching through tens of megabytes to reach
    /// it costs far more than one new request does.
    func testAForwardSeekFarPastTheFrontierRepositions() throws {
        try skipUnlessRealtimeTests()
        let source = MemoryStream(bytes: sequentialBytes(64 * 1024 * 1024))
        // slow enough that the frontier is still a span or two in
        source.readDelay = 0.1
        let cache = ByteCache(io: source.stream, interrupt: nil)
        defer { cache.stream.close(cache.stream.handle) }
        _ = readExact(cache, count: 4096)

        let ahead = Int64(16 * 1024 * 1024)
        XCTAssertEqual(cache.stream.seek(cache.stream.handle, ahead, 0), ahead)
        let there = readExact(cache, count: 4096)
        XCTAssertEqual(there, Array(source.bytes[Int(ahead)..<Int(ahead) + 4096]))
        XCTAssertEqual(source.lastSeekOffset, ahead)
    }

    /// A container whose tracks lie megabytes apart walks forward out of the
    /// window and straight back. Once that walk has been seen, the next jump
    /// that far is fetched through: the real stream is repositioned for the
    /// way in, the first jump and the return that teaches the gap, and never
    /// again for the rest of the walk.
    func testAnInterleaveSeenOnceIsFetchedThroughAfterwards() throws {
        try skipUnlessRealtimeTests()
        let source = MemoryStream(bytes: sequentialBytes(64 * 1024 * 1024))
        source.readDelay = 0.02
        let cache = ByteCache(io: source.stream, interrupt: nil)
        // the pump is still inside a read of `source` when the walk ends,
        // and the source has to outlive it
        defer {
            cache.stream.close(cache.stream.handle)
            Thread.sleep(forTimeInterval: 0.1)
        }
        _ = readExact(cache, count: 4096)

        let gap = Int64(8 * 1024 * 1024)
        var audio = Int64(20 * 1024 * 1024)
        var repositions = Set<Int64>()
        for _ in 0..<4 {
            for offset in [audio, audio + gap] {
                XCTAssertEqual(cache.stream.seek(cache.stream.handle, offset, 0), offset)
                XCTAssertEqual(
                    readExact(cache, count: 4096), Array(source.bytes[Int(offset)..<Int(offset) + 4096]))
                repositions.insert(source.lastSeekOffset)
            }
            audio += 512 * 1024
        }
        XCTAssertEqual(repositions.subtracting([-1]).count, 3, "repositioned at \(repositions.sorted())")
    }

    func testAForwardSeekPastTheWindowRepositionsTheRealStream() throws {
        let source = MemoryStream(bytes: flatBytes(64 * 1024 * 1024))
        let cache = ByteCache(io: source.stream, interrupt: nil)
        defer { cache.stream.close(cache.stream.handle) }
        _ = readExact(cache, count: 8)

        let target = Int64(40 * 1024 * 1024)
        let result = cache.stream.seek(cache.stream.handle, target, 0)
        XCTAssertEqual(result, target)

        let deadline = Date(timeIntervalSinceNow: 5)
        while source.lastSeekOffset != target, Date() < deadline {
            usleep(1000)
        }
        XCTAssertEqual(source.lastSeekOffset, target)
        XCTAssertEqual(source.lastSeekWhence, 0)
    }

    /// A film is read start to finish, so the bytes that have already gone
    /// past the reader are the part of the window with no natural bound. What
    /// this weighs is the process footprint, because that is what jetsam
    /// weighs: a window whose count reads 32 MiB while its allocation has
    /// quietly grown to hold the whole film kills the app just the same, and
    /// costs nothing on the way there - no stutter, no rebuffer, only a
    /// footprint that never stops climbing.
    ///
    /// Sixteen windows' worth, far more than any read-ahead: the reader is
    /// kept level with the fetch frontier throughout, which is the regime
    /// that never trips a bound measured only on what lies ahead of it.
    func testTheWindowNeverExceedsItsCapacity() throws {
        try skipUnlessRealtimeTests()
        let total = 16 * ByteCache.windowCapacity
        let source = GeneratedStream(total: Int64(total))
        let cache = ByteCache(io: source.stream, interrupt: nil)
        defer { cache.stream.close(cache.stream.handle) }
        let base = footprintBytes()
        var readCount = 0
        while readCount < total {
            let want = min(64 * 1024, total - readCount)
            let chunk = readExact(cache, count: want)
            XCTAssertFalse(chunk.isEmpty)
            readCount += chunk.count
        }
        XCTAssertEqual(readCount, total)
        // The window is 32 MiB; anything approaching
        // the 512 MiB just read is the window holding what it has passed.
        let grew = footprintBytes() - base
        XCTAssertLessThan(
            grew, 128 * 1024 * 1024,
            "the window grew to \(grew / 1_048_576) MiB over \(total / 1_048_576) MiB read")
        // no re-fetch loop: the fetch count stays close to the ideal span
        // count rather than blowing up the way a capacity bug would
        let idealFetches = Int(ceil(Double(total) / Double(ByteCache.spanSize)))
        XCTAssertLessThanOrEqual(cache.statistics.fetchCount, idealFetches + 2)
    }

    /// A turn round stops an engine, which raises the interrupt, then reads
    /// the same stream again from a new position once it is lowered. The pump
    /// the interrupt stopped has to come back for that read, or it waits for
    /// bytes nothing will ever fetch.
    func testAStreamReadsAgainAfterTheInterruptIsLowered() throws {
        let source = MemoryStream(bytes: flatBytes(64 * 1024 * 1024))
        let interrupt = InterruptFlag()
        let cache = ByteCache(io: source.stream, interrupt: interrupt)
        defer { cache.stream.close(cache.stream.handle) }
        _ = readExact(cache, count: 8)
        interrupt.raise()
        // long enough for the pump to come round its loop and see it
        usleep(300_000)
        interrupt.lower()
        let target = Int64(40 * 1024 * 1024)
        XCTAssertEqual(cache.stream.seek(cache.stream.handle, target, 0), target)
        // read elsewhere, so a pump that never comes back fails the test
        // rather than hanging it
        let landed = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var read: Int64 = 0
        DispatchQueue.global().async {
            var buffer = [UInt8](repeating: 0, count: 16)
            let n = buffer.withUnsafeMutableBufferPointer { cache.stream.read(cache.stream.handle, $0.baseAddress, 16) }
            lock.lock()
            read = n
            lock.unlock()
            landed.signal()
        }
        XCTAssertEqual(landed.wait(timeout: .now() + 3), .success, "the read after the interrupt never returned")
        lock.lock()
        XCTAssertEqual(read, 16)
        lock.unlock()
    }

    /// The same turn round seeking back inside the window, which is where the
    /// clock usually stands: reading on past what the window held must fetch,
    /// not answer the stopped pump's exit or a false end of stream.
    func testAStreamReadsPastTheWindowAfterAnInterruptAndASeekInsideIt() throws {
        let span = ByteCache.spanSize
        let source = MemoryStream(bytes: sequentialBytes(16 * span))
        // slow enough that the pump is inside a fetch when the interrupt lands
        source.readDelay = 0.1
        let interrupt = InterruptFlag()
        let cache = ByteCache(io: source.stream, interrupt: interrupt)
        defer { cache.stream.close(cache.stream.handle) }
        _ = readExact(cache, count: 8)
        interrupt.raise()
        usleep(300_000)
        interrupt.lower()
        XCTAssertEqual(cache.stream.seek(cache.stream.handle, 0, 0), 0)
        let again = readExact(cache, count: 4 * span)
        XCTAssertEqual(again.count, 4 * span, "the read stopped where the interrupted pump left the window")
        XCTAssertTrue(again == Array(source.bytes[0..<(4 * span)]), "the bytes read back are not the stream's")
    }

    func testInterruptCutsABlockedReadWithLexisErrorExit() throws {
        let source = MemoryStream(bytes: sequentialBytes(1024))
        source.readDelay = 5
        let interrupt = InterruptFlag()
        let cache = ByteCache(io: source.stream, interrupt: interrupt)
        defer { cache.stream.close(cache.stream.handle) }
        interrupt.raise()

        var buffer = [UInt8](repeating: 0, count: 16)
        let started = Date()
        let n = buffer.withUnsafeMutableBufferPointer { buf in
            cache.stream.read(cache.stream.handle, buf.baseAddress, 16)
        }
        XCTAssertEqual(n, Int64(LexisErrorExit))
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    /// The pump parks whenever the window is full, which is most of a film
    /// played over a fast link. The rate is the link's: time spent inside
    /// `io.read`, never the wall clock between two fetches a park sat in.
    func testTheSustainedRateLeavesOutTimeParkedOnAFullWindow() throws {
        try skipUnlessRealtimeTests()
        let source = MemoryStream(bytes: flatBytes(64 * 1024 * 1024))
        source.readDelay = 0.02
        let cache = ByteCache(io: source.stream, interrupt: nil)
        defer { cache.stream.close(cache.stream.handle) }
        _ = readExact(cache, count: 8)
        let spansInWindow = ByteCache.windowCapacity / ByteCache.spanSize
        func waitForFetches(_ count: Int) {
            let deadline = Date(timeIntervalSinceNow: 10)
            while cache.statistics.fetchCount < count, Date() < deadline { usleep(5000) }
        }
        waitForFetches(spansInWindow)
        // each span the reader takes frees room for exactly one fetch, and
        // the pump parks again for the whole pause before the next
        for round in 1...2 {
            usleep(600_000)
            XCTAssertEqual(readExact(cache, count: ByteCache.spanSize).count, ByteCache.spanSize)
            waitForFetches(spansInWindow + round)
        }
        // one 2 MiB span per 20 ms read is about 840 Mbps; the 600 ms parks
        // would read as about 56 Mbps
        XCTAssertGreaterThan(cache.statistics.sustainedBitsPerSecond, 150_000_000)
    }

    func testStatisticsReportSustainedThroughputOrUnmeasured() throws {
        try skipUnlessRealtimeTests()
        let profile = MeasuredStreamProfile()
        let body = flatBytes(16 * 1024 * 1024)
        let server = try RangeHTTPServer(body: Data(body))
        defer { server.stop() }
        server.serveMeasuredProfile(profile, coldFirstConnection: false)
        var error: Int32 = -7
        let handle = try XCTUnwrap(lexis_stream_open_http_range(
            "\(server.baseURL)/clip.mp4", "", "", &error
        ))
        XCTAssertEqual(error, LEXIS_STREAM_OK)
        let cache = ByteCache(io: coreStream(handle: handle), interrupt: nil)
        defer { cache.stream.close(cache.stream.handle) }

        XCTAssertEqual(cache.statistics.sustainedBitsPerSecond, 0)
        _ = readExact(cache, count: 4 * 1024 * 1024)
        XCTAssertGreaterThan(cache.statistics.sustainedBitsPerSecond, 0)
    }
}


extension ByteCacheTests {
// An interleaved demuxer lives on backward seeks and small reads between big
// ones, and every one of those crosses whatever seam the ring happens to have
// at that offset. This walks a deterministic interleave against the pattern
// over a window a fraction of the stream, on a capacity chosen so the wrap
// point lands inside the walked region again and again.
func testAnInterleavedWalkAcrossTheRingSeamServesExactBytes() throws {
    let capacity = 6 * 1024 * 1024
    let total = 16 * 1024 * 1024
    let source = MemoryStream(bytes: sequentialBytes(total))
    let cache = ByteCache(io: source.stream, interrupt: nil,
                          windowCapacity: capacity)
    defer { cache.stream.close(cache.stream.handle) }

    let stream = cache.stream
    var position: Int64 = 0
    var buffer = [UInt8](repeating: 0, count: 512 * 1024)

    /// One assertion for the whole span rather than one per byte: the walk
    /// compares tens of megabytes, and an XCTAssert per byte is the entire
    /// cost of this test.
    func check(_ count: Int, at start: Int64, got: [UInt8],
               label: String, file: StaticString = #filePath, line: UInt = #line) {
        var mismatch = -1
        got.withUnsafeBufferPointer { bytes in
            var i = 0
            while i < count {
                if bytes[i] != UInt8(truncatingIfNeeded: start + Int64(i)) {
                    mismatch = i
                    return
                }
                i += 1
            }
        }
        guard mismatch >= 0 else { return }
        XCTFail("byte \(start + Int64(mismatch)) (\(label)): got \(got[mismatch]), "
                + "want \(UInt8(truncatingIfNeeded: start + Int64(mismatch)))",
                file: file, line: line)
    }

    srand48(2000)
    var steps = 0
    while position < Int64(total), steps < 400 {
        steps += 1
        switch steps % 5 {
        case 0, 1:
            let want = Int.random(in: 64 * 1024...min(512 * 1024,
                                                     total - Int(position)))
            guard want > 0 else { continue }
            let n = stream.read(stream.handle, &buffer, Int32(want))
            XCTAssertEqual(Int64(n), Int64(want), "short video read")
            check(want, at: position, got: buffer, label: "video@\(steps)")
            position += Int64(n)
        case 2:
            let want = Int.random(in: 512...4096)
            let n = stream.read(stream.handle, &buffer, Int32(want))
            XCTAssertEqual(Int64(n), Int64(want), "short audio read")
            check(want, at: position, got: buffer, label: "audio@\(steps)")
            position += Int64(n)
        case 3:
            let back = Int64.random(in: 128 * 1024...768 * 1024)
            let target = max(0, position - back)
            let landed = stream.seek(stream.handle, target, 0)
            XCTAssertEqual(landed, target)
            position = target
        default:
            let want = Int.random(in: 1024...8192)
            let n = stream.read(stream.handle, &buffer, Int32(want))
            XCTAssertEqual(Int64(n), Int64(want))
            check(Int(n), at: position, got: buffer, label: "replay@\(steps)")
            position += Int64(n)
        }
    }
    XCTAssertGreaterThan(steps, 100, "the walk covered real ground")
}
}

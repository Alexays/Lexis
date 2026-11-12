import CFFmpeg
import Foundation
import os.signpost

/// A sliding window of the stream's bytes around the demuxer's read
/// position. One fetch thread, honouring the one-handle-one-thread contract
/// every `MediaStreamIO` carries; reads land in `windowCapacity`-bounded
/// memory; a seek inside the window is served from memory either way.
final class ByteCache {
    /// 32 MiB: about 3.4 s of the measured 74.5 Mbps reference file
    /// and 2.8 s of the 90 Mbps ceiling - a seconds-equivalent window
    /// the stage-1 measurement task revisits with its own numbers.
    static let windowCapacity = 32 * 1024 * 1024
    /// 2 MiB, the measured span (task 1.2's CHUNK): latency amortised
    /// over megabytes, not tens of kilobytes.
    static let spanSize = 2 * 1024 * 1024
    /// The floor a fetch can shrink back to on a slow link. Fetches START at
    /// `spanSize` - a fast or local stream behaves exactly as it always has,
    /// and every existing read contract holds - and only a measured slow
    /// link walks them down.
    static let minimumSpanSize = 256 * 1024

    /// How much the next fetch asks for, from what the last one measured.
    ///
    /// The span chases one target: a fetch should cost about a quarter of a
    /// second at the measured rate. Larger buys throughput a slow link cannot
    /// deliver and holds the pump inside one blocking read for it; smaller
    /// spends the rate on round trips. Powers of two between the floor and
    /// `spanSize`, one step per fetch: the quantization is the hysteresis,
    /// and a rate that flutters between two targets moves nothing.
    static func nextSpanSize(current: Int, fetchedBytes: Int64, fetchSeconds: Double) -> Int {
        guard fetchedBytes > 0, fetchSeconds > 0 else { return current }
        let target = Double(fetchedBytes) / fetchSeconds * 0.25
        if target >= Double(current * 2) { return min(current * 2, spanSize) }
        if target < Double(current) / 2 { return max(current / 2, minimumSpanSize) }
        return current
    }
    /// How often a blocked reader rechecks the interrupt flag, which raises
    /// nothing on `condition`: short enough that a stop or a cancel is never
    /// held up by more than a beat past whatever the source itself is doing.
    /// The pump parks untimed; every change it waits on broadcasts.
    private static let pollInterval: TimeInterval = 0.05
    /// What `sustainedBitsPerSecond` is computed over: enough fetches to
    /// smooth over one span's own jitter, not so many that a rate change
    /// takes forever to show up.
    private static let sustainedWindowBytes: Int64 = 4 * 1024 * 1024

    private let io: MediaStreamIO
    private let interrupt: InterruptFlag?
    let size: Int64
    /// This window's own capacity: the class default unless the caller asked
    /// for a smaller window at init.
    private let capacity: Int

    private let condition = NSCondition()
    /// The window's bytes live in a ring of `capacity`: logical stream offsets
    /// `windowStart` through `windowStart + windowLength`, wrapped so trimming
    /// the front advances an offset instead of memmoving what remains - a
    /// steady-state slide used to move ~30 MiB per fetched span. Grows forward
    /// as the pump fetches and is trimmed from the front only to make room for
    /// a new span, never on a read - a read must never discard bytes a later
    /// backward seek might still want.
    ///
    /// One allocation of `capacity`, made once and never resized, and
    /// deliberately not a `Data`: appended at the back and trimmed at the
    /// front forever, a `Data` grows its own backing by every byte that passes
    /// through it however small its count stays.
    private let buffer: UnsafeMutableRawPointer
    private var windowLength = 0
    private var windowStart: Int64 = 0
    private var position: Int64 = 0

    /// Physical index of a logical offset inside the ring. Logical offsets are
    /// absolute stream positions, always non-negative, so the wrap is plain.
    private func indexOf(_ logical: Int64) -> Int {
        Int(logical % Int64(capacity))
    }
    /// Set by `seek` when the target falls outside the window, cleared by
    /// the pump once it has repositioned the real stream.
    private var seekTarget: Int64?
    /// How far apart the container lays its interleaved tracks, learned from
    /// the demuxer jumping forward out of the window and straight back to
    /// where it was: from then on a forward seek that close is fetched
    /// through rather than repositioned. A viewer's own skip never comes
    /// back, so it teaches nothing and keeps repositioning.
    private var interleaveReach: Int64 = 0
    /// The last reposition forward: where reading was, and where it went.
    private var lastJump: (from: Int64, to: Int64)?
    private var reachedEnd = false
    private var pendingError: Int64?
    private var isClosing = false
    private var pumpStarted = false
    /// True while the pump is inside a call on `io` with `condition` let go.
    /// A close landing then leaves `io` to the pump, which closes it once
    /// that call returns: waiting for it here is waiting out a network read.
    private var pumpInIO = false
    private let pumpQueue = DispatchQueue(label: "org.lexis.player.byte-cache", qos: .userInitiated)
    // One id per cache: several caches fetch at once (a film, a thumbnail
    // strip, a probe), and a shared `.exclusive` id would splice their spans
    // into one interval in Instruments. One pump per cache, so a cache's own
    // spans never overlap each other.
    private let fetchSignpostID = PipelineSignposts.fetch.makeSignpostID()

    private var bytesFetched: Int64 = 0
    private var fetchCount = 0
    private var lastFetchLatencySeconds: Double = 0
    private var windowHits = 0
    /// Recent (bytes, seconds inside `io.read`) fetches, trimmed to the
    /// trailing `sustainedWindowBytes`: what the sustained rate is computed
    /// over. Time only, never wall clock between fetches: the pump parks
    /// whenever the window is full, and counting that would measure the
    /// film's own bitrate instead of the link.
    private var recentFetches: [(bytes: Int64, seconds: Double)] = []

    /// - Parameter windowCapacity: the ring's size. The class default is what
    ///   a playing film gets; a secondary path over the same stream (a
    ///   thumbnail strip) asks for less, since its reads are sparse seeks and
    ///   a full window of a second stream is bandwidth and memory the film is
    ///   paying for.
    init(io: MediaStreamIO, interrupt: InterruptFlag?, windowCapacity: Int = ByteCache.windowCapacity) {
        self.io = io
        self.interrupt = interrupt
        capacity = windowCapacity
        size = io.size(io.handle)
        buffer = UnsafeMutableRawPointer.allocate(byteCount: windowCapacity, alignment: 16)
    }

    deinit { buffer.deallocate() }

    /// Under `condition`. Idempotent: both `read` and `seek` call it.
    private func startPumpIfNeeded() {
        guard !pumpStarted, !isClosing else { return }
        pumpStarted = true
        // The latch an interrupted pump left belongs to that interrupt: a seek
        // inside the window clears neither, and the new pump would park on it.
        if pendingError == Int64(LexisErrorExit) {
            pendingError = nil
            reachedEnd = false
        }
        // Strong: a close can hand `io` to the pump and return, and whatever
        // owns this cache may let it go while that read is still out.
        pumpQueue.async { self.pump() }
    }

    /// A `MediaStreamIO` whose calls land on this window instead of on the
    /// real stream, so `AVIOStream` wires it up exactly as it would any
    /// other source. `self` must outlive every call this produces, which is
    /// what `AVIOStream` holding this instance guarantees.
    var stream: MediaStreamIO {
        MediaStreamIO(
            handle: Unmanaged.passUnretained(self).toOpaque(),
            read: byteCacheRead,
            seek: byteCacheSeek,
            size: byteCacheSize,
            close: byteCacheClose
        )
    }

    var statistics: ByteCacheStatistics {
        condition.lock()
        defer { condition.unlock() }
        return ByteCacheStatistics(
            bytesFetched: bytesFetched,
            fetchCount: fetchCount,
            sustainedBitsPerSecond: sustainedBitsPerSecondLocked(),
            lastFetchLatencySeconds: lastFetchLatencySeconds,
            windowHits: windowHits
        )
    }

    /// Under `condition`. 0 (UNMEASURED) until fetches cover the trailing
    /// window, so an early, small sample never reads as a real rate.
    private func sustainedBitsPerSecondLocked() -> Double {
        var total: Int64 = 0
        var seconds = 0.0
        for fetch in recentFetches {
            total += fetch.bytes
            seconds += fetch.seconds
        }
        guard total >= ByteCache.sustainedWindowBytes, seconds > 0 else { return 0 }
        return Double(total) * 8 / seconds
    }

    fileprivate func read(into destination: UnsafeMutablePointer<UInt8>, _ length: Int32) -> Int64 {
        let want = Int(length)
        condition.lock()
        defer { condition.unlock() }
        startPumpIfNeeded()
        while true {
            if interrupt?.isRaised == true { return Int64(LexisErrorExit) }
            let available = windowStart + Int64(windowLength) - position
            if available > 0 {
                let n = min(want, Int(available))
                // one logical read can straddle the ring's seam: copy the two
                // physical runs separately
                let start = indexOf(position)
                let firstRun = min(n, capacity - start)
                destination.update(
                    from: (buffer + start).assumingMemoryBound(to: UInt8.self),
                    count: firstRun)
                if n > firstRun {
                    destination.advanced(by: firstRun).update(
                        from: buffer.assumingMemoryBound(to: UInt8.self),
                        count: n - firstRun)
                }
                position += Int64(n)
                condition.broadcast()
                return Int64(n)
            }
            if let error = pendingError {
                pendingError = nil
                // the pump parks until the error is taken
                condition.broadcast()
                return error
            }
            if reachedEnd { return 0 }
            condition.wait(until: Date(timeIntervalSinceNow: ByteCache.pollInterval))
        }
    }

    fileprivate func seek(_ offset: Int64, _ whence: Int32) -> Int64 {
        condition.lock()
        defer { condition.unlock() }
        let kind = whence & ~LexisSeekForce
        if kind == LexisSeekSize { return size }
        startPumpIfNeeded()
        let target: Int64
        switch kind {
        case 0: target = offset
        case 1: target = position + offset
        case 2: target = size >= 0 ? size + offset : offset
        default: return Int64(LexisErrorIO)
        }
        guard target >= 0 else { return Int64(LexisErrorIO) }
        // A seek this window can answer without moving the real stream, in
        // either direction: the bytes are already here, or they are a short
        // way past what the pump has reached and it will fetch through the
        // gap sooner than a reposition would arrive. An interleaved
        // container walks its audio and its video regions megabytes apart
        // and comes straight back - at the reference bitrate a one-second
        // interleave is 9 MiB - so dumping the window on either half of
        // that walk refetches the whole of it, every packet, forever. The
        // gap past the frontier is one span at most: a user's forward seek
        // past it repositions instead of fetching up to a window through.
        // An empty window never counts, even at a matching offset: there is
        // nothing cached there to answer from.
        let frontier = windowStart + Int64(windowLength)
        let reachable = min(
            windowStart + Int64(capacity - ByteCache.spanSize),
            frontier + max(Int64(ByteCache.spanSize), interleaveReach))
        if windowLength > 0, target >= windowStart, target <= reachable {
            if target <= frontier { windowHits += 1 }
            position = target
            condition.broadcast()
            return target
        }
        if let jump = lastJump, target < jump.to, target + Int64(ByteCache.spanSize) >= jump.from {
            interleaveReach = min(
                max(interleaveReach, jump.to - target + Int64(ByteCache.spanSize)),
                Int64(capacity - 2 * ByteCache.spanSize))
        }
        lastJump = target > position ? (position, target) : nil
        windowLength = 0
        windowStart = target
        position = target
        reachedEnd = false
        pendingError = nil
        seekTarget = target
        condition.broadcast()
        return target
    }

    /// Returns at once. A read already inside the real stream cannot be cut
    /// short, so when one is out the pump closes `io` as it comes back, and
    /// `pumpInIO` under `condition` is what makes exactly one of the two close.
    fileprivate func close() {
        condition.lock()
        guard !isClosing else {
            condition.unlock()
            return
        }
        isClosing = true
        let closesHere = !pumpInIO
        condition.broadcast()
        condition.unlock()
        if closesHere { io.close(io.handle) }
    }

    /// Runs on its own queue for the stream's whole life. Only this method
    /// touches `io` while it runs, honouring the one-handle-one-thread
    /// contract every `MediaStreamIO` carries; `close` touches it only when
    /// this is not inside a call on it.
    private func pump() {
        // What the next io.read asks for. Pump-local: only this thread reads
        // or moves it, so the adaptation costs no lock and nothing per read.
        var span = ByteCache.spanSize
        while true {
            condition.lock()
            if isClosing { condition.unlock(); return }
            if interrupt?.isRaised == true {
                pendingError = Int64(LexisErrorExit)
                reachedEnd = true
                // a turn round lowers the interrupt and reads this stream
                // again: the next read or seek starts a pump of its own
                pumpStarted = false
                condition.broadcast()
                condition.unlock()
                return
            }
            if let target = seekTarget {
                pumpInIO = true
                condition.unlock()
                let result = io.seek(io.handle, target, 0)
                condition.lock()
                pumpInIO = false
                // A close that landed during the call left `io` to this thread.
                if isClosing {
                    condition.unlock()
                    io.close(io.handle)
                    return
                }
                if result < 0 {
                    // windowStart names a byte offset the real stream never
                    // actually reached; keeping seekTarget set is what
                    // retries the same real reposition, the way a fetch
                    // that fails once keeps being retried below, rather
                    // than fetching against an offset nothing confirmed
                    pendingError = Int64(LexisErrorIO)
                    condition.broadcast()
                    // the full back-off: the read taking this error broadcasts,
                    // and retrying at once would only latch it again
                    let deadline = Date(timeIntervalSinceNow: ByteCache.pollInterval)
                    while !isClosing, seekTarget == target, condition.wait(until: deadline) {}
                    condition.unlock()
                    continue
                }
                seekTarget = nil
                condition.broadcast()
                condition.unlock()
                continue
            }
            // An error not yet read, or a real end already reached, pauses
            // fetching: a span landing in the window first would let a read
            // past it silently, and there is nothing more to fetch anyway.
            // A seek clears both, a read takes the error, a close ends the
            // pump: each broadcasts.
            if reachedEnd || pendingError != nil {
                condition.wait()
                condition.unlock()
                continue
            }
            // The window sits AROUND the read position, and the capacity is
            // the whole of it: what a read has already passed stays resident
            // too, and it is the part that has no natural bound - a film read
            // start to finish passes every byte of itself. Room for the next
            // span comes out of that history first, oldest byte first, and
            // only what the span needs, so whatever is left of the window
            // behind the reader still answers a backward seek. When the
            // history alone cannot pay for the span the frontier is already a
            // window's depth ahead of the reader, so park until it catches up
            // rather than reading further ahead than anything asked for.
            if windowLength + ByteCache.spanSize > capacity {
                let history = Int(max(0, min(Int64(windowLength), position - windowStart)))
                let trimmable = min(history, windowLength + ByteCache.spanSize - capacity)
                // the ring makes a trim an offset advance: no bytes move
                windowLength -= trimmable
                windowStart += Int64(trimmable)
                // a read moving the position, a seek or a close broadcasts
                if windowLength + ByteCache.spanSize > capacity {
                    condition.wait()
                    condition.unlock()
                    continue
                }
            }
            // The read lands straight in the ring, past the frontier: bytes no
            // reader can reach until `windowLength` grows under the lock, and
            // at least `spanSize` of them free after the trim above. A span
            // that meets the seam carries on from the ring's start before it
            // is published, so a reader never sees a sliver cut by the seam.
            let head = indexOf(windowStart + Int64(windowLength))
            let length = min(span, capacity - head)
            pumpInIO = true
            condition.unlock()

            let fetchStarted = Date()
            let fetchInterval = PipelineSignposts.fetch.beginInterval("span", id: fetchSignpostID)
            var n = io.read(
                io.handle, (buffer + head).assumingMemoryBound(to: UInt8.self), Int32(length))
            if n == Int64(length), length < span {
                let rest = io.read(
                    io.handle, buffer.assumingMemoryBound(to: UInt8.self), Int32(span - length))
                if rest > 0 { n += rest }
            }
            PipelineSignposts.fetch.endInterval("span", fetchInterval)
            let latency = Date().timeIntervalSince(fetchStarted)

            condition.lock()
            pumpInIO = false
            // A close that landed during the read left `io` to this thread.
            if isClosing {
                condition.unlock()
                io.close(io.handle)
                return
            }
            // A seek that arrived while this read was in flight moved the
            // window out from under it; what just came back belongs to the
            // offset before the seek and must not be published after it.
            if seekTarget != nil {
                condition.unlock()
                continue
            }
            if n > 0 {
                windowLength += Int(n)
                bytesFetched += n
                fetchCount += 1
                lastFetchLatencySeconds = latency
                // The round trip the container header waits on, which is the
                // one worth telling apart from FFmpeg's own probing above it.
                if fetchCount == 1 {
                    OpenTrace.shared.mark(
                        "first bytes in \(String(format: "%.0f", latency * 1000)) ms")
                }
                span = ByteCache.nextSpanSize(
                    current: span, fetchedBytes: n, fetchSeconds: latency)
                recentFetches.append((n, latency))
                var total = recentFetches.reduce(Int64(0)) { $0 + $1.bytes }
                while total - recentFetches[0].bytes >= ByteCache.sustainedWindowBytes,
                    recentFetches.count > 1
                {
                    total -= recentFetches.removeFirst().bytes
                }
            } else if n == 0 {
                reachedEnd = true
            } else {
                pendingError = n
            }
            condition.broadcast()
            condition.unlock()
        }
    }
}

/// Instrumentation is part of the pipeline: what Diagnostics and the
/// benchmark read from this stage.
struct ByteCacheStatistics: Sendable, Equatable {
    var bytesFetched: Int64
    var fetchCount: Int
    /// Sustained bits/s over the last 4 MiB fetched; 0 = UNMEASURED.
    var sustainedBitsPerSecond: Double
    var lastFetchLatencySeconds: Double
    /// Seeks answered from the window without a fetch.
    var windowHits: Int
}

private let byteCacheRead: MediaStreamIO.Read = { handle, buffer, length in
    guard let handle, let buffer else { return Int64(LexisErrorIO) }
    return Unmanaged<ByteCache>.fromOpaque(handle).takeUnretainedValue().read(into: buffer, length)
}

private let byteCacheSeek: MediaStreamIO.Seek = { handle, offset, whence in
    guard let handle else { return Int64(LexisErrorIO) }
    return Unmanaged<ByteCache>.fromOpaque(handle).takeUnretainedValue().seek(offset, whence)
}

private let byteCacheSize: MediaStreamIO.Size = { handle in
    guard let handle else { return -1 }
    return Unmanaged<ByteCache>.fromOpaque(handle).takeUnretainedValue().size
}

private let byteCacheClose: MediaStreamIO.Close = { handle in
    guard let handle else { return }
    Unmanaged<ByteCache>.fromOpaque(handle).takeUnretainedValue().close()
}

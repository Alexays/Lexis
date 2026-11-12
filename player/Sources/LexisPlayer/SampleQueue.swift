import CoreMedia
import CoreVideo
import Foundation

/// What a queue sorts its samples by. Decoded pictures (and anything else a
/// renderer consumes by timestamp alone, audio included) want presentation
/// order, because an async decoder hands frames back slightly out of the
/// order they were submitted in. Compressed video on the passthrough path
/// wants the opposite: a hardware decoder needs B-frame content in DECODE
/// order (the order the demux/decode thread already reads and pushes it in,
/// one packet at a time, with no concurrency to reorder it), and
/// AVSampleBufferDisplayLayer/AVSampleBufferVideoRenderer reorder for
/// display themselves from each sample's own presentation timestamp - see
/// CMSampleBuffer.h's own worked example ("dataBuffer: contains 6 H.264
/// frames in decode order") and AVQueuedSampleBufferRendering.h's
/// enqueueSampleBuffer: ("the decoded image will be displayed at
/// sampleBuffer's output presentation timestamp"). Sorting those samples by
/// presentation time before they reach the renderer would scramble the very
/// decode order the renderer relies on this queue to preserve.
enum SampleOrdering {
    case presentationTime
    case decodeOrderArrival
}

/// What a sample costs in memory: the picture behind it where a decode path
/// put one there, the compressed bytes where passthrough did not.
private func sampleBytes(_ sample: CMSampleBuffer) -> Int {
    if let image = CMSampleBufferGetImageBuffer(sample) {
        return CVPixelBufferGetDataSize(image)
    }
    return CMSampleBufferGetTotalSampleSize(sample)
}

/// Decoded (or display-ready compressed) samples, bounded by BOTH a span of
/// content and a byte ceiling. Seconds alone bound a queue of compressed
/// packets, whose size follows the bitrate; they bound nothing at all once
/// the samples are pictures, where a second of 4K costs whatever the frame
/// rate and the pixel format make it cost. Nodes come from a free list so
/// steady-state push/pop asks the allocator for nothing.
final class SampleQueue {
    private final class Node {
        var sample: CMSampleBuffer?
        /// Read at push and kept, so a pop subtracts exactly what the push
        /// added even if the sample's own backing has changed since.
        var bytes = 0
        var next: Node?
        /// Weak, or the list retains itself: with `next` strong too, every
        /// adjacent pair is a cycle, and a queue released with samples still
        /// in it leaks the pictures they hold - a whole video queue's worth
        /// per playback, unreachable, past any close and past any memory
        /// warning. A node's predecessor is held by `head` or by the node
        /// before it for as long as this node is linked, so it never reads
        /// nil while it matters.
        weak var prev: Node?
    }

    private let targetSeconds: Double
    private let capacityBytes: Int
    private let ordering: SampleOrdering

    private let condition = NSCondition()
    private var head: Node?
    private var tail: Node?
    private var freeList: Node?
    private var isClosed = false
    private var bytes = 0
    private var allocations = 0
    /// True for exactly as long as a producer is parked on this queue being
    /// full, in `push` or `waitForRoom`, and cleared however it leaves.
    private var producerIsParked = false
    /// Called outside the lock whenever a sample lands or a producer parks:
    /// what a starvation wait reads of this queue only moves then. Set before
    /// anything pushes.
    var onFill: (() -> Void)?

    init(targetSeconds: Double, capacityBytes: Int, ordering: SampleOrdering = .presentationTime) {
        self.targetSeconds = targetSeconds
        self.capacityBytes = capacityBytes
        self.ordering = ordering
    }

    /// Under `condition`. Only place a `Node` is ever created.
    private func takeNode() -> Node {
        if let node = freeList {
            freeList = node.next
            node.next = nil
            return node
        }
        allocations += 1
        return Node()
    }

    /// Under `condition`. The node returns to the free list instead of being
    /// dropped, so the next push reuses it rather than allocating.
    private func releaseNode(_ node: Node) {
        node.sample = nil
        node.bytes = 0
        node.prev = nil
        node.next = freeList
        freeList = node
    }

    private func presentationSeconds(_ node: Node) -> Double {
        CMSampleBufferGetPresentationTimeStamp(node.sample!).seconds
    }

    /// The span `bufferedSecondsLocked` measures by. Decode order arrives
    /// with decode time monotonically increasing (head oldest, tail newest,
    /// by construction of a queue that never resorts), so decode time is
    /// what makes that span non-negative; presentation order sorts on
    /// insert, so presentation time does the same job there.
    private func orderingSeconds(_ node: Node) -> Double {
        guard ordering == .decodeOrderArrival else { return presentationSeconds(node) }
        let decodeTime = CMSampleBufferGetDecodeTimeStamp(node.sample!)
        return decodeTime.isValid ? decodeTime.seconds : presentationSeconds(node)
    }

    /// Under `condition`.
    private func bufferedSecondsLocked() -> Double {
        guard let head, let tail else { return 0 }
        return max(0, orderingSeconds(tail) - orderingSeconds(head))
    }

    /// Under `condition`. `size` is what the caller is about to add, or 0 for
    /// one that cannot know yet - a frame not decoded yet - which weighs the
    /// queue as it stands.
    ///
    /// An empty queue is never full: a picture too big for the whole ceiling
    /// - one 4K frame against a budget of two - must still go somewhere, or
    /// the file would lose the frame outright.
    private func isFullLocked(adding size: Int) -> Bool {
        guard head != nil else { return false }
        return bufferedSecondsLocked() >= targetSeconds || bytes + size > capacityBytes
    }

    /// Under `condition`. Where a sample actually joins the queue, in
    /// whichever order this queue keeps.
    private func insertLocked(_ sample: CMSampleBuffer, bytes size: Int) {
        let node = takeNode()
        node.sample = sample
        node.bytes = size
        bytes += size
        if ordering == .decodeOrderArrival {
            // Appended as pushed, never resorted: the decode thread already
            // reads and pushes compressed passthrough samples in decode
            // order, one at a time, with no concurrency to reorder them.
            node.prev = tail
            tail?.next = node
            tail = node
            if head == nil { head = node }
            return
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        // Scans backward from the tail: the common case is an in-order
        // arrival, which finds its slot in one step.
        var cursor = tail
        while let candidate = cursor, presentationSeconds(candidate) > pts {
            cursor = candidate.prev
        }
        if let cursor {
            node.next = cursor.next
            node.prev = cursor
            cursor.next?.prev = node
            cursor.next = node
            if tail === cursor { tail = node }
        } else {
            node.next = head
            head?.prev = node
            head = node
            if tail == nil { tail = node }
        }
    }

    /// Parks the caller while the queue already holds `targetSeconds`;
    /// returns false when closed or `giveUp` answers true - what stops a push
    /// a seek's flush interrupts mid-park from landing the position it was
    /// decoded from into the freshly emptied queue the instant that flush
    /// frees the room its own wait was blocking on. A push `flush()` only
    /// ever wakes to recheck room, never to succeed unconditionally, so
    /// without this a decode thread parked here at flush time deposits a
    /// stale sample right after the flush it should have been discarded by.
    ///
    /// The wait is untimed: `giveUp` is asked again only when the queue
    /// changes or `wake` is called, so whoever moves its answer calls `wake`
    /// (or `flush`) after.
    func push(_ sample: CMSampleBuffer, giveUp: () -> Bool = { false }) -> Bool {
        let size = sampleBytes(sample)
        condition.lock()
        var landed = false
        while !isClosed, !giveUp() {
            if !isFullLocked(adding: size) {
                insertLocked(sample, bytes: size)
                condition.broadcast()
                landed = true
                break
            }
            if !producerIsParked {
                // Told outside the lock, which a starvation wait takes the
                // other way round, then the room is asked again.
                producerIsParked = true
                condition.unlock()
                onFill?()
                condition.lock()
                continue
            }
            condition.wait()
        }
        producerIsParked = false
        condition.unlock()
        if landed { onFill?() }
        return landed
    }

    /// Takes the sample whatever the queue already holds, for a producer that
    /// must not park: a VideoToolbox callback waiting for room is a decode
    /// thread of the decoder's own, stalled inside its own pipeline. What
    /// holds the queue to its bounds for such a producer is `waitForRoom`,
    /// called before the frame is submitted at all, and what still lands past
    /// them here is what the decoder already had in flight - pictures the
    /// process is holding either way, queued rather than parked.
    ///
    /// `giveUp` is read under the same lock a `flush` needs, so a picture from
    /// a position the player has left cannot land in the window that flush
    /// just cleared.
    func pushWithoutWaiting(_ sample: CMSampleBuffer, giveUp: () -> Bool = { false }) -> Bool {
        let size = sampleBytes(sample)
        condition.lock()
        guard !isClosed, !giveUp() else {
            condition.unlock()
            return false
        }
        insertLocked(sample, bytes: size)
        condition.broadcast()
        condition.unlock()
        onFill?()
        return true
    }

    /// Parks the caller while the queue is at either of its bounds, so a
    /// producer whose own push cannot wait applies the backpressure here
    /// instead - on the thread that submits the frame, which is a thread the
    /// pipeline owns. Returns false when the queue closed or `giveUp`
    /// (asked when `push` would ask it) answers true.
    func waitForRoom(giveUp: () -> Bool = { false }) -> Bool {
        condition.lock()
        var gaveUp = false
        while !isClosed, isFullLocked(adding: 0) {
            if giveUp() {
                gaveUp = true
                break
            }
            if !producerIsParked {
                producerIsParked = true
                condition.unlock()
                onFill?()
                condition.lock()
                continue
            }
            condition.wait()
        }
        producerIsParked = false
        let room = !isClosed && !gaveUp
        condition.unlock()
        return room
    }

    /// True while a producer is parked on this queue being full: it holds all
    /// it will take until something pops, whichever of its two bounds did it.
    var isHoldingItsProducer: Bool {
        condition.lock()
        defer { condition.unlock() }
        return producerIsParked
    }

    /// nil = empty, never blocks.
    func pop() -> CMSampleBuffer? {
        condition.lock()
        defer { condition.unlock() }
        guard let node = head else { return nil }
        head = node.next
        head?.prev = nil
        if tail === node { tail = nil }
        let sample = node.sample
        bytes -= node.bytes
        releaseNode(node)
        condition.broadcast()
        return sample
    }

    var bufferedSeconds: Double {
        condition.lock()
        defer { condition.unlock() }
        return bufferedSecondsLocked()
    }

    /// Half of either bound reached: a queue the budget holds to a few
    /// pictures never reaches half its seconds, and half its bytes is the
    /// same depth read the other way.
    var isHalfFull: Bool {
        condition.lock()
        defer { condition.unlock() }
        return bufferedSecondsLocked() * 2 >= targetSeconds || bytes * 2 >= capacityBytes
    }

    /// The presentation time of the next sample `pop` hands out, nil while
    /// empty. The earliest one queued only in presentation order.
    var headPresentationSeconds: Double? {
        condition.lock()
        defer { condition.unlock() }
        return head.map(presentationSeconds)
    }

    var bufferedBytes: Int {
        condition.lock()
        defer { condition.unlock() }
        return bytes
    }

    func flush() {
        condition.lock()
        var node = head
        while let current = node {
            let next = current.next
            releaseNode(current)
            node = next
        }
        head = nil
        tail = nil
        bytes = 0
        condition.broadcast()
        condition.unlock()
    }

    /// Has a parked producer ask its `giveUp` again.
    func wake() {
        condition.lock()
        condition.broadcast()
        condition.unlock()
    }

    func close() {
        condition.lock()
        isClosed = true
        condition.broadcast()
        condition.unlock()
    }

    /// Steady-state proof: node allocations after the pool warmed.
    var allocationsAfterWarmup: Int {
        condition.lock()
        defer { condition.unlock() }
        return allocations
    }
}

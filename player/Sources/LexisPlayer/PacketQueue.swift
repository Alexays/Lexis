import Foundation

/// A bounded FIFO of demuxed packets for one stream, measured in SECONDS of
/// content (dts span), with a byte ceiling that `PipelineBudget` derives from
/// this file's own measured bitrate and this device's own free memory, so
/// seconds cannot become unbounded memory on a remux. One `NSCondition`, the
/// discipline `ByteCache` (formerly `ReadAheadStream`) uses for its own
/// blocking reads and seeks.
final class PacketQueue {
    struct Configuration {
        /// The demux thread parks above this.
        var highWatermarkSeconds: Double
        /// The ceiling in bytes. No default: a queue whose size nobody stated
        /// is a queue budgeted against a bitrate nobody measured, which is the
        /// assumption this stopped making.
        var capacityBytes: Int

        init(highWatermarkSeconds: Double, capacityBytes: Int) {
            self.highWatermarkSeconds = highWatermarkSeconds
            self.capacityBytes = capacityBytes
        }
    }

    /// How many popped slots accumulate before the array actually drops them.
    /// Bounds the emptied prefix (nil slots, no packet data behind them)
    /// while leaving the shift amortized to a fraction of a slot per pop.
    private static let compactionStride = 256
    /// How far under the watermark a parked push is let go.
    private static let wakeMarginSeconds = 0.1

    private let timeBase: Double
    private let configuration: Configuration
    /// The one figure of `configuration` a running playback may move: the
    /// read-ahead follows the connection's own margin, and the adaptive
    /// controller writes it here. Under `condition`, like every reader.
    private var highWatermarkSeconds: Double

    private let condition = NSCondition()
    /// Paired with the flush generation that was current the instant each
    /// packet was inserted, under this same lock: what lets a consumer that
    /// popped a packet moments before a flush tell it apart from one the
    /// flush's own refill produced, without racing that flush's generation
    /// bump (a separate lock entirely) against its own pop.
    /// Slots below `head` have been popped and hold nil, so a popped
    /// packet's bytes are released at the pop rather than at the compaction.
    private var packets: [(packet: Packet, generation: Int)?] = []
    /// Where the live entries start. A pop steps this forward instead of
    /// shifting every remaining packet down one: on a track like TrueHD - a
    /// thousand one-millisecond packets a second, a queue thousands deep -
    /// shifting cost the depth of the queue on every pop, and it was paid
    /// holding the lock the demux thread's own pushes wait on. The shift is
    /// paid once per `compactionStride` pops now.
    private var head = 0
    private var bytes = 0
    private var isClosed = false
    /// True once the demux thread has read everything the source currently
    /// has, distinct from `isClosed`: a live engine mid real-time playback of
    /// a source already read start to finish can still be asked to seek,
    /// which reads it again from a different position. `pop` treats this the
    /// same way it treats `isClosed`, but a resumed seek can clear it, where
    /// `isClosed` never comes back.
    private var reachedEnd = false
    /// True for exactly as long as a push is parked on this queue being full,
    /// set as it goes to sleep and cleared however it leaves - landing its
    /// packet, or abandoning it for a close, an interrupt or a `giveUp`. A
    /// reading that outlived its pusher would say the demux thread is held
    /// here when it is free and feeding every track normally.
    private var pushIsParked = false
    /// Called outside the lock whenever a packet lands or a push parks: what
    /// a starvation wait reads of this queue only moves then. Set before
    /// anything pushes.
    var onFill: (() -> Void)?

    init(timeBase: Double, configuration: Configuration) {
        highWatermarkSeconds = configuration.highWatermarkSeconds
        self.timeBase = timeBase
        self.configuration = configuration
    }

    /// Blocks the caller (the demux thread) above the high watermark or the
    /// byte ceiling; returns false when closed, interrupted, or `giveUp`
    /// answers true - what lets a seek waiting behind a watermark parked deep
    /// in the buffer's own backlog abort the wait instead of sitting through
    /// however long draining it back down takes.
    ///
    /// The wait is untimed: the interrupt and `giveUp` are asked again only
    /// when the queue changes or `wake` is called, so whoever moves either
    /// answer calls `wake` (or `close`) after.
    func push(_ packet: Packet, generation: Int, interrupt: InterruptFlag?, giveUp: () -> Bool = { false }) -> Bool {
        condition.lock()
        while true {
            if isClosed || interrupt?.isRaised == true { break }
            let fitsBytes = bytes + packet.byteCount <= configuration.capacityBytes
            // Room for one packet is enough to take one. A parked push must
            // not hold out for a deeper drain: one demux thread feeds every
            // track, so for as long as this one queue keeps it parked no
            // OTHER track is being fed either - and video, which the display
            // renderer drains far faster than an audio renderer drains
            // sound, empties and stays empty for the whole wait. Measured on
            // the tvOS app: holding out for a low watermark froze the picture
            // in six-second blocks between bursts.
            if fitsBytes, bufferedSecondsLocked() < highWatermarkSeconds {
                packets.append((packet, generation))
                bytes += packet.byteCount
                pushIsParked = false
                condition.broadcast()
                condition.unlock()
                onFill?()
                return true
            }
            // Asked only once the packet has to wait: the answer takes the
            // engine's lock, and a packet that fits lands whatever it would
            // say, to be discarded by the flush a give-up is waiting on.
            if giveUp() { break }
            if !pushIsParked {
                // Told outside the lock, which a starvation wait takes the
                // other way round, then the room is asked again.
                pushIsParked = true
                condition.unlock()
                onFill?()
                condition.lock()
                continue
            }
            condition.wait()
        }
        pushIsParked = false
        condition.unlock()
        return false
    }

    /// Puts a batch in ahead of everything already queued, past the watermark
    /// a push waits on: the caller is replaying a window it read before the
    /// packets the queue holds, so every entry here is older than every entry
    /// already in it, and the demux thread must not be able to slip a live
    /// packet in front of them. Bounded by the window the caller retains,
    /// which is the read-ahead itself.
    func prepend(_ batch: [Packet], generation: Int) {
        guard !batch.isEmpty else { return }
        condition.lock()
        guard !isClosed else {
            condition.unlock()
            return
        }
        packets.insert(
            contentsOf: batch.map { Optional(($0, generation)) } as [(packet: Packet, generation: Int)?],
            at: head
        )
        bytes += batch.reduce(0) { $0 + $1.byteCount }
        condition.broadcast()
        condition.unlock()
        onFill?()
    }

    /// nil after close-and-drained or end-reached-and-drained, or on deadline.
    /// The generation returned alongside the packet is the one `push` was
    /// given for it, read under this same lock at insertion - never a value
    /// a caller reads separately afterward, which is what would race a
    /// flush's own generation bump.
    func pop(deadline: Date?) -> (packet: Packet, generation: Int)? {
        condition.lock()
        defer { condition.unlock() }
        while true {
            if head < packets.count {
                // Non-nil by construction: nil is exactly what marks a slot
                // already popped, and every one of those is below `head`.
                let entry = packets[head]!
                packets[head] = nil
                head += 1
                if head >= PacketQueue.compactionStride {
                    packets.removeFirst(head)
                    head = 0
                }
                bytes -= entry.packet.byteCount
                // A parked push is woken once there is room for a run of
                // packets rather than for one: woken per pop, the demux
                // thread lands one packet and parks again, a context switch
                // a packet on a track of a thousand packets a second. The
                // margin is a tenth of a second, nothing like the drains
                // that froze the picture; an empty queue always wakes it.
                if !pushIsParked || head >= packets.count
                    || (bufferedSecondsLocked() <= highWatermarkSeconds - PacketQueue.wakeMarginSeconds
                        && bytes <= configuration.capacityBytes - configuration.capacityBytes / 16)
                {
                    condition.broadcast()
                }
                return entry
            }
            if isClosed || reachedEnd { return nil }
            if let deadline {
                if Date() >= deadline { return nil }
                condition.wait(until: deadline)
            } else {
                condition.wait()
            }
        }
    }

    var bufferedSeconds: Double {
        condition.lock()
        defer { condition.unlock() }
        return bufferedSecondsLocked()
    }

    /// True while a push is parked on this queue being full. One demux thread
    /// feeds every track, so a parked push means no track can grow any
    /// further until this one is drained: a reader waiting on some other
    /// track to fill up is waiting for something that cannot happen.
    var isHoldingTheDemuxThread: Bool {
        condition.lock()
        defer { condition.unlock() }
        return pushIsParked
    }

    var bufferedBytes: Int {
        condition.lock()
        defer { condition.unlock() }
        return bytes
    }

    /// Under `condition`. The span between the oldest and newest queued
    /// packet's own decode time, packets arriving in decode order already.
    private func bufferedSecondsLocked() -> Double {
        guard head < packets.count, let first = packets[head], let last = packets[packets.count - 1],
            let firstTime = decodeTimeSeconds(first.packet), let lastTime = decodeTimeSeconds(last.packet)
        else { return 0 }
        return max(0, lastTime - firstTime)
    }

    private func decodeTimeSeconds(_ packet: Packet) -> Double? {
        (packet.dts ?? packet.pts).map { Double($0) * timeBase }
    }


    /// Moves the read-ahead target. Written rarely - the controller only
    /// writes on a level change - and read at every push under `condition`.
    func setHighWatermarkSeconds(_ seconds: Double) {
        condition.lock()
        highWatermarkSeconds = seconds
        condition.broadcast()
        condition.unlock()
    }

    func flush() {
        condition.lock()
        packets.removeAll()
        head = 0
        bytes = 0
        condition.broadcast()
        condition.unlock()
    }

    /// Has a parked push ask its interrupt and its `giveUp` again.
    func wake() {
        condition.lock()
        condition.broadcast()
        condition.unlock()
    }

    /// End of stream: push refuses, pop drains then answers nil.
    func close() {
        condition.lock()
        isClosed = true
        condition.broadcast()
        condition.unlock()
    }

    /// Marks a real end of stream: `pop` drains what is already queued, then
    /// answers nil, the same as `close()` - but a later seek can undo it with
    /// `clearEndReached()`, where `close()` is for good.
    func markEndReached() {
        condition.lock()
        reachedEnd = true
        condition.broadcast()
        condition.unlock()
    }

    /// What a resumed seek clears: the source has more to give again.
    func clearEndReached() {
        condition.lock()
        reachedEnd = false
        condition.broadcast()
        condition.unlock()
    }

    /// Parks a consumer whose `pop` answered nil at a real end until a seek
    /// clears it, a packet lands or the queue closes.
    func waitPastEnd() {
        condition.lock()
        while reachedEnd, !isClosed, head >= packets.count { condition.wait() }
        condition.unlock()
    }

    /// What a decode thread reads after a nil `pop()` to tell `close()`'s
    /// terminal answer from `markEndReached()`'s resumable one: the first
    /// means unwind for good, the second means park and try again, since a
    /// seek arriving after can still refill this same queue.
    var isPermanentlyClosed: Bool {
        condition.lock()
        defer { condition.unlock() }
        return isClosed
    }
}

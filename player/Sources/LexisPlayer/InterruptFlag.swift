import Synchronization

/// A cancellation flag FFmpeg polls. Raised, every blocking demux operation
/// gives up at its next cancellation point instead of running to completion.
///
/// It cannot cut a read that is already inside the stream, only refuse the next
/// one, so the bound it buys is one outstanding read rather than zero.
///
/// An atomic rather than a lock: FFmpeg polls it from its own thread on every
/// interrupt check and every AVIO read, while the app raises it from the main one.
public final class InterruptFlag: Sendable {
    private let raised = Atomic<Bool>(false)

    public init() {}

    public var isRaised: Bool {
        raised.load(ordering: .acquiring)
    }

    public func raise() {
        raised.store(true, ordering: .releasing)
    }

    public func lower() {
        raised.store(false, ordering: .releasing)
    }
}

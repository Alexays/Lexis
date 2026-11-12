import Foundation

/// The one place that knows whether a film is playing right now, shared by
/// every `LexisPlayer` instance and the bench's decode-only run
/// (`DecodeOnlyProbeRun`). The spec's rule - the probe never runs while the
/// film does - only holds if the two can never both be active at once, in
/// either order: a second decode session started while the first is already
/// running would cost the first the very frames a bench would then report
/// as dropped.
///
/// A count for each side, not a flag: two `LexisPlayer` instances can
/// legitimately be open at once (a recycled view still finishing its close
/// while another opens), and likewise two probes can legitimately be asked
/// for at once (two mounted views racing `DecodeOnlyProbeRun.run`, which is
/// `public static` and callable from anywhere) - the gate must stay held
/// until the LAST holder on either side lets go, not the first, or the
/// first one finishing would open the door for the other side while a
/// second instance of its own is still using it.
final class PlaybackActivityGate {
    static let shared = PlaybackActivityGate()

    /// Names whichever side is refusing the call: the side already holding
    /// the gate, not the side asking.
    enum Busy: Error, Equatable {
        case probeRunning
        case playbackRunning
    }

    private enum Holder { case none, player, probe }

    private let lock = NSLock()
    private var holder: Holder = .none
    private var playerCount = 0
    private var probeCount = 0

    private init() {}

    func beginPlayer() throws {
        lock.lock(); defer { lock.unlock() }
        guard holder != .probe else { throw Busy.probeRunning }
        playerCount += 1
        holder = .player
    }

    /// Safe to call even when this caller never held the gate (an open that
    /// closes itself before ever committing): the count floors at zero
    /// rather than going negative and corrupting another instance's hold.
    func endPlayer() {
        lock.lock(); defer { lock.unlock() }
        guard playerCount > 0 else { return }
        playerCount -= 1
        if playerCount == 0 { holder = .none }
    }

    func beginProbe() throws {
        lock.lock(); defer { lock.unlock() }
        guard holder != .player else { throw Busy.playbackRunning }
        probeCount += 1
        holder = .probe
    }

    /// Safe to call even when this caller never held the gate, the same
    /// floor `endPlayer()` keeps: without it, the first of two concurrent
    /// probes to finish would release the gate out from under the second,
    /// which is still decoding - the exact overlap this gate exists to stop.
    func endProbe() {
        lock.lock(); defer { lock.unlock() }
        guard probeCount > 0 else { return }
        probeCount -= 1
        if probeCount == 0 { holder = .none }
    }
}

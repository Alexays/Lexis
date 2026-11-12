import Foundation

/// The owner's real Plex stream, measured 2026-08-17 (stage 0). Every
/// synthetic source in the I/O layer's tests carries THIS profile; an
/// invented one certified the previous fix and it did not survive
/// contact with the real server.
public struct MeasuredStreamProfile: Sendable {
    /// Bits per second the reference file carries. Measured: 74.5 Mbps.
    public var fileBitsPerSecond: Double = 74_500_000
    /// The library's ceiling, what buffers must be budgeted against.
    public var ceilingBitsPerSecond: Double = 90_000_000
    /// Throughput of a fresh connection per 256 KiB request. Measured.
    public var coldPerRequestBitsPerSecond: Double = 10_700_000
    /// Throughput once the connection is reused or spans reach 2 MiB.
    public var reusedBitsPerSecond: Double = 130_000_000
    /// The one cold connection observed. Cause unpinned; budgeted for.
    public var coldConnectSeconds: Double = 13.4
    public init() {}

    /// The same shape, `coldConnectSeconds` scaled by `factor` so a test
    /// suite can stay fast. The scale is the test's own, never the
    /// measured number: callers keep `factor` visible at the call site
    /// rather than inventing a new constant.
    public func scaled(by factor: Double) -> MeasuredStreamProfile {
        var copy = self
        copy.coldConnectSeconds *= factor
        return copy
    }
}

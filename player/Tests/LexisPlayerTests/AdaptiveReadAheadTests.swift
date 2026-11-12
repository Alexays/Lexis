import XCTest
@testable import LexisPlayer

/// The two adaptation laws, as tables: pure functions from measurements to
/// targets, tested the way `PipelineBudget` already is.
final class AdaptiveReadAheadTests: XCTestCase {
    private let policy = BufferPolicy.standard

    /// The property the law exists for: a narrow margin buys seconds, and it
    /// can afford to precisely because the stream is slow.
    func testANarrowMarginBuysSecondsAndAComfortableOneKeepsThePolicys() {
        func seconds(_ sustained: Double, _ stream: Double) -> Double {
            AdaptiveReadAhead.readAheadSeconds(
                policy: policy, sustainedBitsPerSecond: sustained, streamBitsPerSecond: stream)
        }
        // comfortable: a local server ten times faster than the film
        XCTAssertEqual(seconds(80_000_000, 8_000_000), policy.highWatermarkSeconds)
        // narrow: the link holds one and a half films
        XCTAssertEqual(seconds(12_000_000, 8_000_000), policy.highWatermarkSeconds * 2)
        // barely: deeper still, the last thing a buffer can do
        XCTAssertEqual(seconds(8_500_000, 8_000_000), policy.highWatermarkSeconds * 3)
    }

    /// Nothing measured is exactly what it always was: the law must not turn
    /// the unmeasured open into a behaviour change.
    func testAnUnmeasuredConnectionKeepsThePolicysOwnSeconds() {
        XCTAssertEqual(
            AdaptiveReadAhead.readAheadSeconds(
                policy: policy, sustainedBitsPerSecond: 0, streamBitsPerSecond: 8_000_000),
            policy.highWatermarkSeconds)
        XCTAssertEqual(
            AdaptiveReadAhead.readAheadSeconds(
                policy: policy, sustainedBitsPerSecond: 50_000_000, streamBitsPerSecond: 0),
            policy.highWatermarkSeconds)
    }

    /// The span chases a quarter-second fetch: it grows one power of two
    /// toward it, shrinks one power of two away from it, and the quantization
    /// is what keeps a fluttering rate from moving it at all.
    func testTheFetchSpanChasesAQuarterSecondOfTheMeasuredRate() {
        let floor = ByteCache.minimumSpanSize
        // a link that recovered: 256 KiB came back in 10 ms -> 25 MB/s -> grow
        XCTAssertEqual(
            ByteCache.nextSpanSize(current: floor, fetchedBytes: Int64(floor), fetchSeconds: 0.01),
            floor * 2)
        // a slow link: 2 MiB took 4 s -> 0.5 MB/s -> a quarter second is
        // 128 KiB -> shrink, and never below the floor
        XCTAssertEqual(
            ByteCache.nextSpanSize(
                current: ByteCache.spanSize, fetchedBytes: Int64(ByteCache.spanSize),
                fetchSeconds: 4),
            ByteCache.spanSize / 2)
        XCTAssertEqual(
            ByteCache.nextSpanSize(current: floor, fetchedBytes: Int64(floor), fetchSeconds: 4),
            floor)
        // steady in between: a rate whose target sits inside the band moves
        // nothing, which is the hysteresis
        XCTAssertEqual(
            ByteCache.nextSpanSize(
                current: 512 * 1024, fetchedBytes: 512 * 1024, fetchSeconds: 0.2),
            512 * 1024)
        // never past the window's own span
        XCTAssertEqual(
            ByteCache.nextSpanSize(
                current: ByteCache.spanSize, fetchedBytes: Int64(ByteCache.spanSize),
                fetchSeconds: 0.001),
            ByteCache.spanSize)
    }

    /// A fetch that measured nothing moves nothing.
    func testAFailedFetchMovesTheSpanNowhere() {
        XCTAssertEqual(
            ByteCache.nextSpanSize(current: 512 * 1024, fetchedBytes: 0, fetchSeconds: 0.1),
            512 * 1024)
    }
}

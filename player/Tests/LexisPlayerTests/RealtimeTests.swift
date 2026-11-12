import XCTest

let realtimeTestsVariable = "LEXIS_REALTIME_TESTS"

/// Skips the caller unless real-time tests were asked for.
///
/// Some tests here spend real wall clock because the wall clock is the thing
/// they assert on: a stall that has to outlast the lead the reader can build,
/// a grace period that has to elapse before nothing having happened means
/// anything, a film delivered at the rate it would really be delivered at.
/// They are the bulk of the suite's runtime, and shortening them would only
/// make them prove less.
///
/// So they keep their full length and are asked for rather than shortened:
/// `swift test` stays quick enough to sit inside a save cycle, and
/// `LEXIS_REALTIME_TESTS=1 swift test` runs everything.
func skipUnlessRealtimeTests() throws {
    guard ProcessInfo.processInfo.environment[realtimeTestsVariable] == nil else { return }
    throw XCTSkip("real-time test; set \(realtimeTestsVariable)=1 to run it")
}

/// A class whose every test is one of those. Subclasses overriding
/// `setUpWithError` must call `super`, or they will run unasked.
class RealtimeTestCase: XCTestCase {
    override func setUpWithError() throws {
        try skipUnlessRealtimeTests()
    }
}

/// Waits for `condition` to hold, and fails the caller if it never does.
///
/// The alternative these replace is a fixed sleep picked to be long enough on
/// a slow machine, which costs that long on every machine and is still only a
/// guess. This costs whatever the pipeline actually takes. It says nothing
/// about something NOT happening: a test that means to watch a span go by
/// with nothing in it still has to let the span go by.
func pollUntil(
    _ what: String, timeout: TimeInterval = 10,
    file: StaticString = #filePath, line: UInt = #line,
    _ condition: () -> Bool
) {
    let deadline = Date(timeIntervalSinceNow: timeout)
    while Date() < deadline {
        if condition() { return }
        usleep(2_000)
    }
    XCTFail("timed out waiting for \(what)", file: file, line: line)
}

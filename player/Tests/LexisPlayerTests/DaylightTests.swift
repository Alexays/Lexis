import XCTest
@testable import LexisPlayer

final class DaylightTests: XCTestCase {
    private func share(_ text: String, _ zone: String) -> Float {
        let tz = TimeZone(identifier: zone)!
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.timeZone = tz
        return Daylight.share(at: formatter.date(from: text)!, in: tz)
    }

    func testANoonIsDayAndAMidnightIsNight() {
        XCTAssertEqual(share("2026-06-21 13:00", "Europe/Paris"), 1)
        XCTAssertGreaterThan(share("2026-12-21 13:00", "Europe/Paris"), 0.9, "a winter noon has the sun 18 degrees up")
        XCTAssertEqual(share("2026-06-21 00:00", "Europe/Paris"), 0)
    }

    /// The light comes in after sunrise, not at a fixed hour: Paris sees the
    /// sun at about 8:40 in late December and 5:50 in late June.
    func testTheShareFollowsTheSeasonsSunrise() {
        XCTAssertEqual(share("2026-12-21 08:30", "Europe/Paris"), 0)
        XCTAssertEqual(share("2026-06-21 08:30", "Europe/Paris"), 1)
        XCTAssertEqual(share("2026-10-10 19:00", "Europe/Paris"), 0, accuracy: 0.01, "a sun on the horizon lights no room")
        let rising = share("2026-12-21 09:30", "Europe/Paris")
        XCTAssertGreaterThan(rising, 0)
        XCTAssertLessThan(rising, 1)
    }

    /// A zone the table does not hold is placed on its offset's meridian.
    func testAZoneOffTheTableStillHasASun() {
        XCTAssertEqual(share("2026-06-21 12:00", "Etc/GMT-1"), 1)
        XCTAssertEqual(share("2026-06-21 00:00", "Etc/GMT-1"), 0)
    }
}

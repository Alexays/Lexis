import LexisCore
import XCTest
@testable import Lexis

final class AskChipTests: XCTestCase {
    private let understood = AskFilters(
        maxMinutes: 100, kind: .movie, unseen: true, rewatch: false, decade: 1980,
        people: ["Jean-Paul Belmondo"], mood: "light", tonight: false, text: "robots")

    func testEveryFilterTheCoreUnderstoodIsAChip() {
        XCTAssertEqual(
            AskChip.of(understood),
            [.movies, .unseen, .length(100), .decade(1980), .person("Jean-Paul Belmondo"), .mood("light"),
             .words("robots")])
    }

    func testTakingAChipOffClearsOnlyItsOwnFilter() {
        var filters = understood
        AskChip.person("Jean-Paul Belmondo").clear(&filters)
        XCTAssertTrue(filters.people.isEmpty)
        AskChip.movies.clear(&filters)
        XCTAssertNil(filters.kind)
        XCTAssertEqual(filters.maxMinutes, 100)
        XCTAssertEqual(AskChip.of(filters).count, 5)
    }
}

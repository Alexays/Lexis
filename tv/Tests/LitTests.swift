import LexisCore
import XCTest

@testable import Lexis

@MainActor
final class LitTests: XCTestCase {
    private func item(_ id: Int64) -> TitleItem {
        TitleItem(id: id, kind: .movie, name: "Movie \(id)", year: nil, fileCount: 1, firstFileId: id)
    }

    func testAStepTakenOnItsOwnLandsAtOnce() {
        let lit = Lit()
        lit.light(item(1))
        XCTAssertEqual(lit.item?.id, 1)
    }

    /// The whole point: a card swept past never becomes the lit one, so the
    /// screen never starts loading its picture.
    func testASweepLandsOnlyOnTheCardTheThumbStopsOn() async throws {
        let lit = Lit()
        lit.light(item(1))
        lit.light(item(2))
        lit.light(item(3))
        XCTAssertEqual(lit.item?.id, 1)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(lit.item?.id, 3)
    }

    func testAStepAfterTheThumbHasRestedLandsAtOnceAgain() async throws {
        let lit = Lit()
        lit.light(item(1))
        try await Task.sleep(for: .milliseconds(400))
        lit.light(item(2))
        XCTAssertEqual(lit.item?.id, 2)
    }
}

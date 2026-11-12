import LexisCore
import XCTest
@testable import Lexis

final class LifecycleTests: XCTestCase {
    func testAShelfLinkNamesItsTitle() {
        let link = Lifecycle.shelfLink(URL(string: "lexis://title?kind=show&name=The%20Wire&year=2002")!)
        XCTAssertEqual(link, Lifecycle.ShelfLink(kind: .show, name: "The Wire", year: 2002))
        let played = Lifecycle.shelfLink(URL(string: "lexis://title?kind=movie&name=Heat&year=1995&play=1")!)
        XCTAssertEqual(played, Lifecycle.ShelfLink(kind: .movie, name: "Heat", year: 1995, play: true))
    }

    func testALinkMissingAPartIsIgnored() {
        XCTAssertNil(Lifecycle.shelfLink(URL(string: "lexis://title?kind=movie&year=1999")!))
        XCTAssertNil(Lifecycle.shelfLink(URL(string: "lexis://title?kind=book&name=X&year=1999")!))
        XCTAssertNil(Lifecycle.shelfLink(URL(string: "lexis://title?kind=movie&name=X&year=abc")!))
        XCTAssertNil(Lifecycle.shelfLink(URL(string: "lexis://person?name=X")!))
    }
}

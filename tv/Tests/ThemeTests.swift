import SwiftUI
import XCTest
@testable import Lexis

final class ThemeTests: XCTestCase {
    /// The floor is what a viewer reads from three metres, and the tvOS
    /// guidance puts a body at about 24 points. This lot raised the top and
    /// deliberately left the bottom alone; a later one must not undo that by
    /// accident.
    func testTheTypeFloorDoesNotMove() {
        XCTAssertEqual(Theme.Typography.bodySize, 29)
        XCTAssertEqual(Theme.Typography.captionSize, 23)
        XCTAssertEqual(Theme.Typography.captionCompactSize, 17)
    }

    /// The bar, the title under the remote, and one whole reason: that is
    /// the first screen, and nothing of the three may fall below the fold.
    /// The bands declare their heights and the views draw what they declare,
    /// so this cannot drift from the screen without somebody meaning it.
    func testTheFirstScreenHoldsABarAHeroAndAReason() {
        XCTAssertLessThanOrEqual(Theme.Home.total, Theme.Layout.screenHeight)
        XCTAssertEqual(Theme.Home.total, Theme.Layout.bar + Theme.Home.hero + Theme.Home.heroGap + Theme.Home.row)
    }

    /// The air left under the first reason. Too much and the second one is
    /// invisible; too little and the first looks cut rather than placed.
    func testTheFirstScreenIsNotMostlyAir() {
        XCTAssertGreaterThan(Theme.Home.total, Theme.Layout.screenHeight - Theme.Space.s24)
    }

    /// Eight posters sit whole and the ninth is cut by the right edge. That
    /// overhang is the only thing on the screen saying the row continues:
    /// eight landing flush at the margin reads as a row that has ended.
    func testTheNinthPosterIsCutByTheEdge() {
        let ninth = Theme.Layout.gutter + 8 * (Theme.Reason.width + Theme.Reason.gap)
        XCTAssertLessThan(ninth, Theme.Layout.screenWidth)
        XCTAssertGreaterThan(ninth + Theme.Reason.width, Theme.Layout.screenWidth)
    }

    /// A focused card lifts its picture and moves the band that names it down
    /// by as much: the rail reserves that growth above and below.
    func testARailReservesTheWholeOfACardsGrowth() {
        let grown = Theme.Reason.height * (Theme.Focus.lift - 1) / 2
        XCTAssertGreaterThanOrEqual(Theme.Reason.inset, grown)
    }

    /// tvOS keeps the top 60 points clear for overscan; the bar starts below.
    func testTheBarClearsTheOverscanInset() {
        XCTAssertGreaterThanOrEqual(Theme.Layout.pillTop, 60)
    }

    /// The library keeps its own, wider poster and its five columns. The
    /// reason's poster is a second size on purpose; it must not be allowed
    /// to drag this one along with it.
    func testTheLibraryGridStillLandsOnTheScreen() {
        let content = Theme.Layout.screenWidth - 2 * Theme.Layout.gutter
        let cards = 5 * Theme.Poster.width
        XCTAssertLessThan(cards, content)
        XCTAssertEqual((content - cards) / 4, 65)
    }

    /// The grid a reason opens onto has nothing hanging off it: six columns
    /// and their gutters land inside the safe area.
    func testTheOpenedGridLandsOnTheScreen() {
        let content = Theme.Layout.screenWidth - 2 * Theme.Layout.gutter
        let columns = CGFloat(Theme.Reason.columns)
        let cards = columns * Theme.Reason.width + (columns - 1) * Theme.Reason.gap
        XCTAssertLessThanOrEqual(cards, content)
    }

    /// Three storeys of glass, not two. Four per cent between the lowest
    /// surface and the highest is a rounding error, not an elevation.
    func testTheDepthLadderIsWideEnoughToRead() {
        XCTAssertGreaterThan(Theme.Depth.focusRadius, Theme.Depth.restRadius * 2)
        XCTAssertGreaterThan(Theme.Depth.focusOpacity, Theme.Depth.restOpacity)
    }

    func testAPosterStaysTwoByThree() {
        XCTAssertEqual(Theme.Poster.height / Theme.Poster.width, 1.5, accuracy: 0.001)
        XCTAssertEqual(Theme.Reason.height / Theme.Reason.width, 1.5, accuracy: 0.001)
    }

    func testTheScaleRisesAtTheTop() {
        XCTAssertEqual(Theme.Typography.displaySize, 108)
        XCTAssertEqual(Theme.Typography.titleSize, 44)
        XCTAssertEqual(Theme.Typography.labelSize, 20)
    }
}

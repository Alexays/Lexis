import XCTest
@testable import LexisPlayer

final class DeinterlacerTests: XCTestCase {
    /// Runs `deinterlacePlane` over a plane whose rows are `rows`, one byte
    /// per column, between the frames `previous` and `next` (the plane
    /// itself where nil), and hands back the output rows in the same shape.
    private func deinterlace(
        _ rows: [[UInt8]], previous: [[UInt8]]? = nil, next: [[UInt8]]? = nil, field: VideoField,
        second: Bool = false
    ) -> [[UInt8]] {
        let width = rows[0].count
        let height = rows.count
        let planes = [previous ?? rows, rows, next ?? rows].map { $0.flatMap { $0 } }
        var destination = [UInt8](repeating: 0xAA, count: height * width)
        planes[0].withUnsafeBufferPointer { before in
            planes[1].withUnsafeBufferPointer { current in
                planes[2].withUnsafeBufferPointer { after in
                    destination.withUnsafeMutableBufferPointer { output in
                        Deinterlacer.deinterlacePlane(
                            previous: PlaneRows(base: before.baseAddress!, stride: width),
                            current: PlaneRows(base: current.baseAddress!, stride: width),
                            next: PlaneRows(base: after.baseAddress!, stride: width),
                            destination: output.baseAddress!, destinationStride: width,
                            widthBytes: width, height: height, field: field, second: second)
                    }
                }
            }
        }
        return (0..<height).map { Array(destination[$0 * width..<($0 + 1) * width]) }
    }

    /// A frame of solid rows, white on one field and black on the other.
    private func comb(topWhite: Bool, rows: Int = 12, width: Int = 32) -> [[UInt8]] {
        (0..<rows).map { row in [UInt8](repeating: (row % 2 == 0) == topWhite ? 235 : 16, count: width) }
    }

    /// The comb itself, moving: every field is one flat colour and each
    /// swaps from one frame to the next, so a correct pass leaves a flat
    /// picture and any surviving alternation is the comb.
    func testTheCombIsGoneFromEitherField() {
        let current = comb(topWhite: true)
        let around = comb(topWhite: false)
        XCTAssertEqual(
            deinterlace(current, previous: around, next: around, field: .top),
            Array(repeating: [UInt8](repeating: 235, count: 32), count: 12))
        XCTAssertEqual(
            deinterlace(current, previous: around, next: around, field: .bottom, second: true),
            Array(repeating: [UInt8](repeating: 16, count: 32), count: 12))
    }

    /// The field's own scanlines must land on the rows they were shot on. A
    /// pass that puts both fields at the same height makes the picture bounce
    /// a line up and down fifty times a second.
    func testEachFieldKeepsItsOwnScanlinePositions() {
        let rows: [[UInt8]] = (0..<8).map { [UInt8](repeating: UInt8($0 * 10), count: 16) }
        let moved = rows.map { $0.map { $0 &+ 50 } }
        let top = deinterlace(rows, previous: moved, next: moved, field: .top)
        for row in stride(from: 0, to: 8, by: 2) {
            XCTAssertEqual(top[row], rows[row], "top field row \(row) moved")
        }
        let bottom = deinterlace(rows, previous: moved, next: moved, field: .bottom, second: true)
        for row in stride(from: 1, to: 8, by: 2) {
            XCTAssertEqual(bottom[row], rows[row], "bottom field row \(row) moved")
        }
    }

    /// Where nothing moved from the frame before to the frame after, the
    /// other field's own rows are the ones in between: a still frame comes
    /// back whole, its full vertical detail to the edges, where a bob would
    /// have blurred every other row.
    func testAStillFrameKeepsItsFullVerticalDetail() {
        let rows: [[UInt8]] = (0..<16).map { row in
            (0..<32).map { (column: Int) -> UInt8 in UInt8((row * 37 + column * 11) % 220 + 16) }
        }
        XCTAssertEqual(deinterlace(rows, field: .top), rows)
        XCTAssertEqual(deinterlace(rows, field: .bottom, second: true), rows)
    }

    /// A row of the other field is held within how far the picture moved
    /// around it: two frames that agree with each other but not with this
    /// one are motion, and the row follows this field's own.
    func testAMovingRowFollowsItsOwnField() {
        var rows = [[UInt8]](repeating: [UInt8](repeating: 100, count: 24), count: 12)
        // the other field still shows where the bright band was
        for row in stride(from: 1, to: 12, by: 2) { rows[row] = [UInt8](repeating: 200, count: 24) }
        let before = [[UInt8]](repeating: [UInt8](repeating: 200, count: 24), count: 12)
        let built = deinterlace(rows, previous: before, next: rows, field: .top)
        for row in stride(from: 1, to: 12, by: 2) {
            XCTAssertEqual(built[row], [UInt8](repeating: 100, count: 24), "row \(row)")
        }
    }

    /// Past the last row of the field there is no second neighbour, and
    /// reaching for one would read outside the plane: the one row stands for
    /// both, as it does in FFmpeg.
    func testTheEdgeRowsReplicateRatherThanReachOutside() {
        let rows: [[UInt8]] = (0..<6).map { [UInt8](repeating: UInt8(($0 + 1) * 7), count: 24) }
        let moved = rows.map { $0.map { $0 &+ 90 } }
        XCTAssertEqual(deinterlace(rows, previous: moved, next: moved, field: .top)[5], rows[4])
        XCTAssertEqual(deinterlace(rows, previous: moved, next: moved, field: .bottom, second: true)[0], rows[1])
    }

    /// A width that is not a whole number of vectors: each column is built
    /// from its own column alone, so the tail done by hand matches the same
    /// columns of a wider plane done in vectors.
    func testAWidthThatIsNotAWholeNumberOfVectorsIsFinishedByHand() {
        func plane(_ seed: Int, width: Int) -> [[UInt8]] {
            (0..<14).map { row in
                (0..<width).map { (column: Int) -> UInt8 in UInt8((row * 53 + (column % 37) * 29 + seed * 71) % 240) }
            }
        }
        let narrow = deinterlace(plane(0, width: 37), previous: plane(1, width: 37), next: plane(2, width: 37), field: .top)
        let wide = deinterlace(plane(0, width: 48), previous: plane(1, width: 48), next: plane(2, width: 48), field: .top)
        XCTAssertEqual(narrow, wide.map { Array($0.prefix(37)) })
    }

    /// The stride is not the width: a pixel buffer pads its rows, and the
    /// padding of one row is not the start of the next.
    func testPaddingBetweenRowsIsNotReadAsPicture() {
        let width = 8
        let stride = 16
        var source = [UInt8](repeating: 0xFF, count: 4 * stride)
        for row in 0..<4 {
            for column in 0..<width {
                source[row * stride + column] = row % 2 == 0 ? 100 : 200
            }
        }
        var destination = [UInt8](repeating: 0, count: 4 * stride)
        source.withUnsafeBufferPointer { input in
            destination.withUnsafeMutableBufferPointer { output in
                let rows = PlaneRows(base: input.baseAddress!, stride: stride)
                Deinterlacer.deinterlacePlane(
                    previous: rows, current: rows, next: rows,
                    destination: output.baseAddress!, destinationStride: stride,
                    widthBytes: width, height: 4, field: .top, second: false
                )
            }
        }
        for row in 0..<4 {
            XCTAssertEqual(
                Array(destination[row * stride..<(row * stride + width)]),
                [UInt8](repeating: row % 2 == 0 ? 100 : 200, count: width), "row \(row)"
            )
        }
    }

    /// The comb a weave would leave: none for a frame's own still fields,
    /// every code of the stripe for two moments woven together.
    func testCombingIsTheStripeAWeaveLeaves() {
        let still: [UInt8] = (0..<(8 * 32)).map { UInt8($0 / 32 * 10) }
        let stripe: [UInt8] = comb(topWhite: true, rows: 8).flatMap { $0 }
        still.withUnsafeBufferPointer { still in
            stripe.withUnsafeBufferPointer { stripe in
                let rows = PlaneRows(base: still.baseAddress!, stride: 32)
                let combed = PlaneRows(base: stripe.baseAddress!, stride: 32)
                XCTAssertEqual(Deinterlacer.combing(current: rows, other: rows, widthBytes: 32, height: 8, field: .top), 0)
                // rows 1, 3 and 5 of black between white ones
                XCTAssertEqual(
                    Deinterlacer.combing(current: combed, other: combed, widthBytes: 32, height: 8, field: .top),
                    3 * 32 * (235 - 16))
            }
        }
    }

    /// The comb of a 3:2 cycle, frame by frame: each frame's first field
    /// with its own second field and with the frame before's, and which of
    /// them leaves a stripe. Two of every five frames weave across, one
    /// stays ambiguous, the rest weave with their own.
    private func cycle(_ count: Int, startingAt start: Int = 0) -> [(own: Int, previous: Int)] {
        let pattern: [(Int, Int)] = [(10, 9000), (10, 9000), (9000, 10), (9000, 10), (10, 10)]
        return (0..<count).map { pattern[(start + $0) % 5] }
    }

    /// Film is found after six frames that agree, then shown once a film
    /// frame: the frame woven whole, the frame woven across, the repeat
    /// left out, and a film frame starting on the field before goes up at
    /// that field's time.
    func testTelecineLocksOntoTheCycleAndFoldsTheRepeat() {
        var telecine = Telecine()
        let pictures = cycle(15).map { telecine.picture(ownComb: $0.own, previousComb: $0.previous, samples: 1000) }
        XCTAssertEqual(Array(pictures.prefix(6)), Array(repeating: .fields, count: 6))
        XCTAssertEqual(pictures[6...], [
            .film(weavesPrevious: false, early: false), .repeated, .film(weavesPrevious: true, early: true),
            .film(weavesPrevious: false, early: true), .film(weavesPrevious: false, early: false),
            .film(weavesPrevious: false, early: false), .repeated, .film(weavesPrevious: true, early: true),
            .film(weavesPrevious: false, early: true),
        ])
    }

    /// A frame that contradicts the cycle - an edit, a cut to video - lets
    /// it go at once, and every frame after is deinterlaced until the new
    /// cycle has been read as long as the first was.
    func testTelecineLetsGoAtACadenceBreak() {
        var telecine = Telecine()
        for reading in cycle(12) { _ = telecine.picture(ownComb: reading.own, previousComb: reading.previous, samples: 1000) }
        // a cut one frame into the cycle: its first frame says nothing, its
        // second contradicts the old cycle
        let after = cycle(12, startingAt: 4).map {
            telecine.picture(ownComb: $0.own, previousComb: $0.previous, samples: 1000)
        }
        XCTAssertEqual(after[0], .repeated)
        XCTAssertTrue(after[1..<7].allSatisfy { $0 == .fields })
        XCTAssertNotEqual(after.last, .fields)
    }

    /// True interlaced video combs either weave alike, and a still picture
    /// neither: nothing is ever read as film.
    func testVideoAndStillPicturesAreNeverTakenForFilm() {
        var telecine = Telecine()
        for frame in 0..<40 {
            let still = frame < 20
            let picture = telecine.picture(
                ownComb: still ? 30 : 9000 + frame * 37 % 500, previousComb: still ? 12 : 9000, samples: 1000)
            XCTAssertEqual(picture, .fields, "frame \(frame)")
        }
    }
}

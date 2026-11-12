import CFFmpeg
import CoreMedia
import Foundation

/// Which of an interlaced frame's two fields a picture is being built from.
/// `top` owns the even scanlines of every plane, `bottom` the odd ones.
public enum VideoField {
    case top
    case bottom

    var firstRow: Int { self == .top ? 0 : 1 }
}

/// How an interlaced stream's frames become pictures: the field shown first,
/// and how long each field is on screen. Nil for a progressive stream, or
/// one whose rate is not known.
public struct FieldOrder {
    let topFirst: Bool
    let duration: CMTime

    public init?(of stream: MediaStream) {
        guard stream.isInterlaced, stream.frameRateNum > 0, stream.frameRateDen > 0 else { return nil }
        // The first letter is the field shown first, whatever defs.h says of
        // TB: a top field first H.264 track is read back as TB.
        topFirst = stream.fieldOrder == Int32(AV_FIELD_TT.rawValue) || stream.fieldOrder == Int32(AV_FIELD_TB.rawValue)
        duration = CMTime(value: Int64(stream.frameRateDen), timescale: stream.frameRateNum * 2)
    }
}

/// One plane of eight bit samples, and how far apart its rows are.
struct PlaneRows {
    let base: UnsafePointer<UInt8>
    let stride: Int
}

/// Motion adaptive deinterlace, FFmpeg's bwdif to the code: one interlaced
/// frame becomes two full-height pictures, one per field, half a frame
/// apart. The field's own scanlines keep the rows they were shot on; every
/// row between them is the other field's two moments either side of this
/// one, averaged, wherever the picture did not move between them. Where it
/// did, that average is held within how far it moved, and drawn from a
/// cubic down the field's own rows blended with the other field's detail
/// (Weston's three field filter): a still picture keeps its full vertical
/// resolution, a moving one loses no motion and shows no comb.
///
/// It needs the frames either side of the one it builds, which is a frame
/// of latency and a history a seek starts over: at either end of the
/// stream the frame stands in for its missing neighbour.
///
/// One byte a sample, on a planar plane: 8 bit planes only, which the
/// caller guards. `PictureEnhancer`'s GPU pass applies the same rule and has
/// to stay equal to it.
enum Deinterlacer {
    /// Writes `field` of `current` out as a full-height plane, `second` when
    /// it is the frame's second field.
    ///
    /// `height` is the plane's own row count, not the picture's: a 4:2:0
    /// chroma plane is half as tall and its rows alternate between the fields
    /// exactly as luma's do.
    static func deinterlacePlane(
        previous: PlaneRows, current: PlaneRows, next: PlaneRows,
        destination: UnsafeMutablePointer<UInt8>, destinationStride: Int,
        widthBytes: Int, height: Int, field: VideoField, second: Bool
    ) {
        guard widthBytes > 0, height > 0 else { return }
        let parity = field.firstRow
        // the other field's moments half a field before and after this one
        let (before, after) = second ? (current, next) : (previous, current)
        for row in 0..<height {
            let out = destination + row * destinationStride
            // a plane of one row has no row of the other field to read
            if row & 1 == parity || height < 2 {
                memcpy(out, current.base + row * current.stride, widthBytes)
                continue
            }
            bwdifRow(row, height: height, previous: previous, current: current, next: next,
                     before: before, after: after, into: out, count: widthBytes)
        }
    }

    /// A film frame's two fields woven back into the picture they were cut
    /// from: `field`'s rows from `current`, the others from `other`.
    static func weavePlane(
        current: PlaneRows, other: PlaneRows, destination: UnsafeMutablePointer<UInt8>, destinationStride: Int,
        widthBytes: Int, height: Int, field: VideoField
    ) {
        for row in 0..<height {
            let source = row & 1 == field.firstRow ? current : other
            memcpy(destination + row * destinationStride, source.base + row * source.stride, widthBytes)
        }
    }

    /// The comb a weave of `field`'s rows from `current` with the other
    /// rows from `other` would leave: by how many codes each row of the
    /// other field stands outside the two rows either side of it, summed. A
    /// still picture or a matched pair leaves only what an edge's own
    /// overshoot does; two moments woven leave a stripe on every moving edge.
    static func combing(current: PlaneRows, other: PlaneRows, widthBytes: Int, height: Int, field: VideoField) -> Int {
        typealias Wide = SIMD16<UInt16>
        func load(_ rows: PlaneRows, _ row: Int, _ at: Int) -> Wide {
            Wide(truncatingIfNeeded: UnsafeRawPointer(rows.base + row * rows.stride + at)
                .loadUnaligned(as: SIMD16<UInt8>.self))
        }
        var total = 0
        // the first of the other field's rows with one of `field`'s above it
        var row = field == .top ? 1 : 2
        while row + 1 < height {
            // a lane gains at most 255 a step: a row of 4096 columns stays within 16 bits
            var sum = Wide()
            var x = 0
            while x + 16 <= widthBytes {
                let above = load(current, row - 1, x), below = load(current, row + 1, x)
                let own = load(other, row, x)
                let low = pointwiseMin(above, below), high = pointwiseMax(above, below)
                sum &+= (pointwiseMax(own, high) &- high) &+ (low &- pointwiseMin(own, low))
                x += 16
            }
            total += Int(sum.wrappedSum())
            row += 2
        }
        return total
    }
}

/// bwdif's two sets of taps: the cubic down the field's own rows, alone
/// where the picture holds nothing to reconstruct from the other field, and
/// with the other field's high frequencies where it does. Over 2^13.
private let spatialTaps: (Int32, Int32) = (5077, 981)
private let lowTaps: (Int32, Int32) = (4309, 213)
private let highTaps: (Int32, Int32, Int32) = (5570, 3801, 1016)

/// The eight samples at `x` of `row`, or the `count` left at its end.
@inline(__always)
private func lanes(_ rows: PlaneRows, _ row: Int, _ x: Int, _ count: Int) -> SIMD8<Int32> {
    let start = rows.base + row * rows.stride + x
    if count == 8 {
        return SIMD8<Int32>(truncatingIfNeeded: UnsafeRawPointer(start).loadUnaligned(as: SIMD8<UInt8>.self))
    }
    var lanes = SIMD8<Int32>()
    for i in 0..<count { lanes[i] = Int32(start[i]) }
    return lanes
}

/// One row of the other field's, `y`, as bwdif builds it, edges included,
/// eight samples at a time: sixteen lanes of 32 bits spill the registers.
/// within four rows of either end the cubic is the two rows' mean, and
/// within two the spatial check is left out, as FFmpeg's edge path does.
@inline(__always)
private func bwdifRow(
    _ y: Int, height: Int, previous: PlaneRows, current: PlaneRows, next: PlaneRows,
    before: PlaneRows, after: PlaneRows, into out: UnsafeMutablePointer<UInt8>, count: Int
) {
    typealias Wide = SIMD8<Int32>
    func absolute(_ value: Wide) -> Wide { pointwiseMax(value, 0 &- value) }
    let up = y > 0 ? y - 1 : y + 1
    let down = y + 1 < height ? y + 1 : y - 1
    let interior = y >= 4 && y + 5 <= height
    let checksSpace = y >= 2 && y + 3 <= height
    var x = 0
    while x < count {
        let n = min(8, count - x)
        let c = lanes(current, up, x, n), e = lanes(current, down, x, n)
        let early = lanes(before, y, x, n), late = lanes(after, y, x, n)
        let d = (early &+ late) &>> 1
        let still = absolute(early &- late)
        let sincePrevious = (absolute(lanes(previous, up, x, n) &- c) &+ absolute(lanes(previous, down, x, n) &- e)) &>> 1
        let untilNext = (absolute(lanes(next, up, x, n) &- c) &+ absolute(lanes(next, down, x, n) &- e)) &>> 1
        let moved = pointwiseMax(still &>> 1, pointwiseMax(sincePrevious, untilNext))
        var reach = moved
        if checksSpace {
            let b = ((lanes(before, y - 2, x, n) &+ lanes(after, y - 2, x, n)) &>> 1) &- c
            let f = ((lanes(before, y + 2, x, n) &+ lanes(after, y + 2, x, n)) &>> 1) &- e
            let dc = d &- c, de = d &- e
            let most = pointwiseMax(pointwiseMax(de, dc), pointwiseMin(b, f))
            let least = pointwiseMin(pointwiseMin(de, dc), pointwiseMax(b, f))
            reach = pointwiseMax(reach, pointwiseMax(least, 0 &- most))
        }
        var built: Wide
        if interior {
            let far = lanes(current, y - 3, x, n) &+ lanes(current, y + 3, x, n)
            let spatial = (spatialTaps.0 &* (c &+ e) &- spatialTaps.1 &* far) &>> 13
            let twoAway = lanes(before, y - 2, x, n) &+ lanes(after, y - 2, x, n)
                &+ lanes(before, y + 2, x, n) &+ lanes(after, y + 2, x, n)
            let fourAway = lanes(before, y - 4, x, n) &+ lanes(after, y - 4, x, n)
                &+ lanes(before, y + 4, x, n) &+ lanes(after, y + 4, x, n)
            let high = (highTaps.0 &* (early &+ late) &- highTaps.1 &* twoAway &+ highTaps.2 &* fourAway) &>> 2
            let blended = (high &+ lowTaps.0 &* (c &+ e) &- lowTaps.1 &* far) &>> 13
            built = spatial
            built.replace(with: blended, where: absolute(c &- e) .> still)
        } else {
            built = (c &+ e) &>> 1
        }
        built = pointwiseMin(pointwiseMax(built, d &- reach), d &+ reach)
        // nothing moved in time: the other field's own rows, whatever the space says
        built.replace(with: d, where: moved .== 0)
        let stored = SIMD8<UInt8>(truncatingIfNeeded: pointwiseMin(pointwiseMax(built, Wide(repeating: 0)), Wide(repeating: 255)))
        if n == 8 {
            UnsafeMutableRawPointer(out + x).storeBytes(of: stored, as: SIMD8<UInt8>.self)
        } else {
            for i in 0..<n { out[x + i] = stored[i] }
        }
        x += 8
    }
}

/// Film carried in an interlaced stream by 3:2 pulldown, the NTSC DVD's and
/// American television's way of fitting 23.976 frames into 59.94 fields:
/// each film frame two fields, then three, so two of every five frames
/// weave fields of two different film frames. Read from the comb each
/// frame's first field would make woven with its own second field and
/// with the previous frame's, it locks onto the five frame cycle once
/// enough frames have said the same thing, follows the cycle through still
/// stretches where neither weave combs, and lets go at the first frame
/// that contradicts it: an edit, a cut to video, or a cadence restarted.
///
/// Locked, each film frame goes up once, woven back whole, from the field
/// that started it: the 59.94 Hz grid keeps its pictures two and three
/// fields long, as the source laid them out, with full vertical resolution
/// and no comb. Unlocked, each field is deinterlaced.
struct Telecine {
    /// What one frame of the stream is shown as.
    enum Picture: Equatable {
        /// Both fields built up, half a frame apart: video, or a cadence
        /// not found.
        case fields
        /// A film frame woven back: the frame as it is, or with
        /// `weavesPrevious` its first field with the previous frame's
        /// second. `early`, it goes up at that previous second field's time,
        /// where the film frame began.
        case film(weavesPrevious: Bool, early: Bool)
        /// A film frame already shown by the frame before.
        case repeated
    }

    /// Which second field a frame's first field weaves cleanly with.
    private enum Match { case own, previous }

    /// Clear readings the five phases have each agreed with in a row.
    private var agreeing = [Int](repeating: 0, count: 5)
    private var phase: Int?
    private var index = 0
    /// What the last frame's first field was matched with, nil where it
    /// was deinterlaced.
    private var last: Match?

    /// Six frames that agree, a cycle and a bit: 0.2 s at 29.97.
    private static let lockAfter = 6

    mutating func reset() {
        self = Telecine()
    }

    /// The next frame, from the comb its first field leaves woven with its
    /// own second field and with the previous frame's, over `samples`
    /// samples: read only where one weave combs both twice as much as the
    /// other and by an eighth of a code a sample more. A still picture
    /// combs neither, and says nothing.
    mutating func picture(ownComb: Int, previousComb: Int, samples: Int) -> Picture {
        defer { index += 1 }
        let low = min(ownComb, previousComb), high = max(ownComb, previousComb)
        let reading: Match? = high > 2 * low && (high - low) * 8 > samples
            ? (ownComb < previousComb ? .own : .previous) : nil
        // the cycle's two frames that weave across, at index - phase 0 and 1
        func expected(_ phase: Int) -> Match { ((index - phase) % 5 + 5) % 5 < 2 ? .previous : .own }
        if let reading {
            for candidate in 0..<5 {
                agreeing[candidate] = expected(candidate) == reading ? agreeing[candidate] + 1 : 0
            }
            if let phase, expected(phase) != reading { self.phase = nil }
        }
        if phase == nil, let best = agreeing.indices.max(by: { agreeing[$0] < agreeing[$1] }),
            agreeing[best] >= Telecine.lockAfter
        {
            phase = best
        }
        guard let phase else {
            last = nil
            return .fields
        }
        let match = expected(phase)
        defer { last = match }
        switch (match, last) {
        // its first field repeats the frame just woven whole
        case (.previous, .own): return .repeated
        case (.previous, nil): return .film(weavesPrevious: true, early: false)
        case (.previous, .previous): return .film(weavesPrevious: true, early: true)
        // the previous second field woven with nothing is this film frame's first
        case (.own, let last): return .film(weavesPrevious: false, early: last == .previous)
        }
    }
}

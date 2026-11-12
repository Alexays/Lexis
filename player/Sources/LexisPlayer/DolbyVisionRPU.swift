import Foundation

/// One RPU's worth of what the player needs: what the stream is, the colour
/// matrices it wants used, and how bright this frame is.
public struct DolbyVisionRPU: Sendable, Equatable {
    public let profile: UInt8
    public let level: UInt8
    public let blBitDepth: Int
    public let elBitDepth: Int
    public let vdrBitDepth: Int
    public let disableResidual: Bool
    public let sceneRefresh: Bool
    public let sourceMinPQ: UInt16
    public let sourceMaxPQ: UInt16
    /// YCbCr to RGB, row major (9 coefficients over 8192) with its three
    /// offsets (over 2^28), then RGB to LMS (9 coefficients over 16384).
    public let yccToRGB: [Float]
    public let yccOffset: [Float]
    public let rgbToLMS: [Float]
    /// Per-frame brightness, absent when the RPU carries no level 1 block.
    public let minPQ: UInt16?
    public let maxPQ: UInt16?
    public let avgPQ: UInt16?
    /// The base layer's reshaping, one curve per component, which is what
    /// turns a profile 5 base layer into a signal. Nil where this RPU reuses
    /// the previous one's mapping.
    public let reshaping: [DolbyVisionReshapingCurve]?
    /// The colourist's trim passes, one per target display, their peaks
    /// rising: level 8 where the RPU carries content mapping v4.0, level 2
    /// otherwise, none where it carries neither.
    public var trims: [DolbyVisionTrim] = []
}

/// One trim pass, how the grade's curve is bent for a display of
/// `targetMaxPQ`: ST 2094-10's gain, offset and gamma on the mapped signal,
/// then its chroma compensation and saturation. Each a 12 bit code, 2048
/// changing nothing.
public struct DolbyVisionTrim: Sendable, Equatable {
    /// The target display's peak, a 12 bit PQ code.
    public let targetMaxPQ: UInt16
    public let slope: UInt16
    public let offset: UInt16
    public let power: UInt16
    public let chromaWeight: UInt16
    public let saturationGain: UInt16
    /// The detail management's weight, -1 where a level 2 block leaves it
    /// to the display.
    public let msWeight: Int16
    /// Content mapping v4.0's mid contrast and highlight clip, nil where the
    /// block is too short to hold them, and on level 2.
    public let midContrast: UInt16?
    public let clipTrim: UInt16?
}

/// One component's reshaping curve: pieces between pivots, each a
/// polynomial in the component itself or an MMR over all three.
public struct DolbyVisionReshapingCurve: Sendable, Equatable {
    public enum Piece: Sendable, Equatable {
        /// Coefficients from the constant up, two or three of them.
        case polynomial([Double])
        /// Order 1 to 3, a constant, then seven coefficients per order over
        /// the three components, their three pairwise products and their
        /// triple product, each raised to the order.
        case mmr(order: Int, constant: Double, coefficients: [Double])
    }

    /// In base layer codes, rising; one piece between each pair.
    public let pivots: [UInt16]
    public let pieces: [Piece]
}

public enum RPUParseError: Error, Equatable {
    case notAnRPU
    case unsupportedType(Int)
    case truncated
    /// A shape whose fields cannot be located, so the walk would silently
    /// desync into a struct that still looks plausible. The reference decoder
    /// refuses each of these too.
    case unsupported(String)
}

struct BitReader {
    let bytes: [UInt8]
    var bit = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    mutating func read(_ count: Int) throws -> UInt32 {
        guard count <= 32, bit + count <= bytes.count * 8 else { throw RPUParseError.truncated }
        var value: UInt32 = 0
        for _ in 0..<count {
            let byte = bytes[bit >> 3]
            value = value << 1 | UInt32((byte >> (7 - UInt8(bit & 7))) & 1)
            bit += 1
        }
        return value
    }

    mutating func flag() throws -> Bool { try read(1) == 1 }

    mutating func skip(_ count: Int) throws {
        guard bit + count <= bytes.count * 8 else { throw RPUParseError.truncated }
        bit += count
    }

    mutating func unsignedGolomb() throws -> UInt32 {
        var zeros = 0
        while try !flag() {
            zeros += 1
            guard zeros < 32 else { throw RPUParseError.truncated }
        }
        guard zeros > 0 else { return 0 }
        return (1 << UInt32(zeros)) - 1 + (try read(zeros))
    }

    mutating func signedGolomb() throws -> Int32 {
        let value = try unsignedGolomb()
        return value % 2 == 0 ? -Int32(value / 2) : Int32((value + 1) / 2)
    }

    mutating func align() { bit = (bit + 7) & ~7 }
}

/// Strips the 0x000003 escapes a NAL payload carries.
func unescape(_ data: Data) -> [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity(data.count)
    var zeros = 0
    data.withUnsafeBytes { bytes in
        for byte in bytes {
            if zeros >= 2, byte == 3 {
                zeros = 0
                continue
            }
            zeros = byte == 0 ? zeros + 1 : 0
            out.append(byte)
        }
    }
    return out
}

/// The length of a NAL unit's length prefix, out of byte 21 of the hvcC. Four
/// is what every mp4 in the wild uses and what a missing box falls back to.
public func nalLengthSize(hvcC: Data?) -> Int {
    guard let hvcC, hvcC.count > 21 else { return 4 }
    return Int(hvcC[hvcC.startIndex + 21] & 0x03) + 1
}

/// The Dolby Vision RPU riding in an access unit, without its two-byte NAL
/// header, or nil when the frame carries none. Packets stay in the container's
/// length-prefixed form, so this is a walk over lengths and never a start code
/// search.
///
/// Takes the packet's own bytes rather than a `Data`: this runs on every frame
/// of a Dolby Vision film, and copying an access unit to walk its lengths
/// would cost more than the walk. The payload it finds is small and is copied.
public func dolbyVisionRPUPayload(in packet: UnsafeRawBufferPointer, lengthSize: Int) -> Data? {
    var offset = 0
    while offset + lengthSize + 2 <= packet.count {
        var length = 0
        for i in 0..<lengthSize { length = length << 8 | Int(packet[offset + i]) }
        let start = offset + lengthSize
        guard length >= 3, start + length <= packet.count else { return nil }
        // NAL unit type 62 is where Dolby put the RPU: unspecified, so no
        // HEVC decoder looks at it.
        if (packet[start] >> 1) & 0x3f == 62 {
            return Data(bytes: packet.baseAddress! + start + 2, count: length - 2)
        }
        offset = start + length
    }
    return nil
}

public func parseDolbyVisionRPU(_ payload: Data) throws -> DolbyVisionRPU {
    var reader = BitReader(unescape(payload))
    guard try reader.read(8) == 25 else { throw RPUParseError.notAnRPU }
    let type = Int(try reader.read(6))
    guard type == 2 else { throw RPUParseError.unsupportedType(type) }
    let format = try reader.read(11)
    let profile = UInt8(try reader.read(4))
    let level = UInt8(try reader.read(4))
    // Everything below fixes the width of a later read, so a shape whose
    // fields cannot be located is refused rather than guessed: a desynced walk
    // does not fail, it returns a plausible struct with the wrong numbers in it.
    guard try reader.flag() else { // vdr_seq_info_present_flag
        throw RPUParseError.unsupported("no sequence info")
    }
    _ = try reader.flag() // chroma_resampling_explicit_filter_flag
    // float coefficients are a flat 32 bits with no exponential Golomb part and
    // no denominator, which is a different walk altogether
    guard try reader.read(2) == 0 else { // coefficient_data_type
        throw RPUParseError.unsupported("float coefficients")
    }
    let coefLog2Denom = Int(try reader.unsignedGolomb())
    _ = try reader.read(2) // vdr_rpu_normalized_idc
    _ = try reader.flag() // bl_video_full_range_flag
    guard format & 0x700 == 0 else {
        throw RPUParseError.unsupported("rpu format \(format)")
    }
    let blBitDepth = Int(try reader.unsignedGolomb()) + 8
    // ext_mapping_idc rides in the upper 8 bits of el_bit_depth_minus8
    let elBitDepth = Int(try reader.unsignedGolomb() & 0xff) + 8
    let vdrBitDepth = Int(try reader.unsignedGolomb()) + 8
    _ = try reader.flag() // spatial_resampling_filter_flag
    // dm_compression: nonzero takes the whole colour block out of the payload
    guard try reader.read(3) == 0 else {
        throw RPUParseError.unsupported("compressed display management")
    }
    _ = try reader.flag() // el_spatial_resampling_filter_flag
    let disableResidual = try reader.flag()
    let dmPresent = try reader.flag()
    let usePrevious = try reader.flag()
    var reshaping: [DolbyVisionReshapingCurve]?
    var nlq: [Range<Int>] = []
    if usePrevious {
        _ = try reader.unsignedGolomb() // prev_vdr_rpu_id
    } else {
        reshaping = try readMapping(
            &reader, blBitDepth: blBitDepth, elBitDepth: elBitDepth,
            coefLog2Denom: coefLog2Denom, disableResidual: disableResidual, nlq: &nlq
        )
    }
    var sceneRefresh = false
    var sourceMinPQ: UInt16 = 0, sourceMaxPQ: UInt16 = 0
    var yccToRGB = [Float](repeating: 0, count: 9)
    var yccOffset = [Float](repeating: 0, count: 3)
    var rgbToLMS = [Float](repeating: 0, count: 9)
    var minPQ: UInt16?, maxPQ: UInt16?, avgPQ: UInt16?
    var levelTwo: [DolbyVisionTrim] = []
    var levelEight: [DolbyVisionTrim] = []
    if dmPresent {
        _ = try reader.unsignedGolomb() // affected_dm_metadata_id
        _ = try reader.unsignedGolomb() // current_dm_metadata_id
        sceneRefresh = try reader.unsignedGolomb() != 0
        for i in 0..<9 { yccToRGB[i] = Float(Int16(bitPattern: UInt16(try reader.read(16)))) / 8192 }
        for i in 0..<3 {
            yccOffset[i] = Float(Int32(bitPattern: try reader.read(32))) / 268_435_456
        }
        for i in 0..<9 { rgbToLMS[i] = Float(Int16(bitPattern: UInt16(try reader.read(16)))) / 16384 }
        try reader.skip(16 + 16 + 16 + 32) // signal_eotf and its three parameters
        try reader.skip(5 + 2 + 2 + 2) // bit depth, colour space, chroma format, range
        sourceMinPQ = UInt16(try reader.read(12))
        sourceMaxPQ = UInt16(try reader.read(12))
        _ = try reader.read(10) // source_diagonal
        // every extension block starts on a byte and says how long it is,
        // so the ones this player has no use for cost a skip each
        let blocks = try reader.unsignedGolomb()
        reader.align()
        for _ in 0..<blocks {
            let length = Int(try reader.unsignedGolomb())
            let blockLevel = try reader.read(8)
            let end = reader.bit + length * 8
            if blockLevel == 1 {
                minPQ = UInt16(try reader.read(12))
                maxPQ = UInt16(try reader.read(12))
                avgPQ = UInt16(try reader.read(12))
            } else if blockLevel == 2 {
                let target = UInt16(try reader.read(12))
                let codes = try (0..<5).map { _ in UInt16(try reader.read(12)) }
                let weight = Int16(try reader.read(13))
                levelTwo.append(DolbyVisionTrim(
                    targetMaxPQ: target, slope: codes[0], offset: codes[1], power: codes[2],
                    chromaWeight: codes[3], saturationGain: codes[4],
                    msWeight: weight > 4095 ? weight - 8192 : weight, midContrast: nil, clipTrim: nil))
            }
            guard end <= reader.bytes.count * 8 else { throw RPUParseError.truncated }
            reader.bit = end
        }
        // Content mapping v4.0's blocks follow, where more is left than the
        // CRC and the terminator: at least one block's count, length and
        // level beside them. A walk that fails in them leaves level 1 and 2
        // as read, which is what a display of v2.9 alone would use.
        if reader.bytes.count * 8 - reader.bit >= 3 + 1 + 8 + 32 + 8 {
            var eight: [(index: UInt8, trim: DolbyVisionTrim)] = []
            var customTargets: [UInt8: UInt16] = [:]
            do {
                let blocks = try reader.unsignedGolomb()
                reader.align()
                for _ in 0..<blocks {
                    let length = Int(try reader.unsignedGolomb())
                    let blockLevel = try reader.read(8)
                    let end = reader.bit + length * 8
                    guard end <= reader.bytes.count * 8 else { throw RPUParseError.truncated }
                    if blockLevel == 8, length >= 10 {
                        let index = UInt8(try reader.read(8))
                        let codes = try (0..<6).map { _ in UInt16(try reader.read(12)) }
                        let midContrast = length >= 12 ? UInt16(try reader.read(12)) : nil
                        let clipTrim = length >= 13 ? UInt16(try reader.read(12)) : nil
                        eight.append((index, DolbyVisionTrim(
                            targetMaxPQ: 0, slope: codes[0], offset: codes[1], power: codes[2],
                            chromaWeight: codes[3], saturationGain: codes[4], msWeight: Int16(codes[5]),
                            midContrast: midContrast, clipTrim: clipTrim)))
                    } else if blockLevel == 10, length >= 5 {
                        let index = UInt8(try reader.read(8))
                        customTargets[index] = UInt16(try reader.read(12))
                    }
                    reader.bit = end
                }
            } catch {
                eight = []
            }
            // A level 8 names its display by index: one a level 10 of the
            // same RPU describes, or one of Dolby's own, as dovi_tool lists
            // them, 100 nits where the index is neither.
            levelEight = eight.map { block in
                let nits: Double = switch block.index {
                case 16, 18, 21: 48
                case 42: 108
                case 24, 25: 300
                case 27, 28: 600
                case 48, 49: 1000
                case 37, 38: 2000
                default: 100
                }
                let target = customTargets[block.index]
                    ?? UInt16((Double(pqInverseEOTF(nits / 10000)) * 4095).rounded())
                let trim = block.trim
                return DolbyVisionTrim(
                    targetMaxPQ: target, slope: trim.slope, offset: trim.offset, power: trim.power,
                    chromaWeight: trim.chromaWeight, saturationGain: trim.saturationGain,
                    msWeight: trim.msWeight, midContrast: trim.midContrast, clipTrim: trim.clipTrim)
            }
        }
    }
    return DolbyVisionRPU(
        profile: profile, level: level, blBitDepth: blBitDepth, elBitDepth: elBitDepth,
        vdrBitDepth: vdrBitDepth, disableResidual: disableResidual, sceneRefresh: sceneRefresh,
        sourceMinPQ: sourceMinPQ, sourceMaxPQ: sourceMaxPQ,
        yccToRGB: yccToRGB, yccOffset: yccOffset, rgbToLMS: rgbToLMS,
        minPQ: minPQ, maxPQ: maxPQ, avgPQ: avgPQ, reshaping: reshaping,
        trims: (levelEight.isEmpty ? levelTwo : levelEight).sorted { $0.targetMaxPQ < $1.targetMaxPQ }
    )
}

/// The mapping section: the base layer's reshaping curves, then, for a
/// dual layer stream, the enhancement layer's quantisation, which nothing
/// here uses but which has to be walked to reach the display management
/// data behind it. `nlq` gets the bits of the two NLQ sections.
func readMapping(
    _ reader: inout BitReader, blBitDepth: Int, elBitDepth: Int, coefLog2Denom: Int,
    disableResidual: Bool, nlq: inout [Range<Int>]
) throws -> [DolbyVisionReshapingCurve] {
    _ = try reader.unsignedGolomb() // vdr_rpu_id
    _ = try reader.unsignedGolomb() // mapping_color_space
    _ = try reader.unsignedGolomb() // mapping_chroma_format_idc
    // a coefficient is a signed integer part and a fraction of
    // coef_log2_denom bits, the fraction always added
    func coefficient() throws -> Double {
        let integer = try reader.signedGolomb()
        let fraction = try reader.read(coefLog2Denom)
        return Double(integer) + Double(fraction) / Double(UInt64(1) << UInt64(coefLog2Denom))
    }
    var pivots: [[UInt16]] = []
    pivots.reserveCapacity(3)
    for _ in 0..<3 {
        let count = Int(try reader.unsignedGolomb()) + 2
        guard count <= 9 else { throw RPUParseError.unsupported("\(count) pivots") }
        // each pivot is written as the step from the one before
        var pivot = 0
        var component: [UInt16] = []
        component.reserveCapacity(count)
        for _ in 0..<count {
            pivot += Int(try reader.read(blBitDepth))
            component.append(UInt16(min(pivot, Int(UInt16.max))))
        }
        pivots.append(component)
    }
    if !disableResidual {
        let start = reader.bit
        // the linear dead zone is the only quantisation method anyone
        // documents, and so the only one whose payload length is known
        guard try reader.read(3) == 0 else { // nlq_method_idc
            throw RPUParseError.unsupported("nlq method")
        }
        for _ in 0..<2 { try reader.skip(blBitDepth) }
        nlq.append(start..<reader.bit)
    }
    _ = try reader.unsignedGolomb() // num_x_partitions_minus1
    _ = try reader.unsignedGolomb() // num_y_partitions_minus1
    var curves: [DolbyVisionReshapingCurve] = []
    curves.reserveCapacity(3)
    for component in 0..<3 {
        var pieces: [DolbyVisionReshapingCurve.Piece] = []
        pieces.reserveCapacity(pivots[component].count - 1)
        for _ in 0..<(pivots[component].count - 1) {
            let method = try reader.unsignedGolomb()
            if method == 0 {
                let order = Int(try reader.unsignedGolomb()) + 1
                // how many coefficients a linearly interpolated piece carries
                // is undocumented, so the reference decoder refuses it too
                if order == 1, try reader.flag() { // linear_interp_flag
                    throw RPUParseError.unsupported("linear interpolation")
                }
                guard order <= 2 else { throw RPUParseError.unsupported("polynomial order \(order)") }
                pieces.append(.polynomial(try (0...order).map { _ in try coefficient() }))
            } else {
                let order = Int(try reader.read(2)) + 1
                guard order <= 3 else { throw RPUParseError.unsupported("mmr order \(order)") }
                let constant = try coefficient()
                let coefficients = try (0..<(order * 7)).map { _ in try coefficient() }
                pieces.append(.mmr(order: order, constant: constant, coefficients: coefficients))
            }
        }
        curves.append(DolbyVisionReshapingCurve(pivots: pivots[component], pieces: pieces))
    }
    if !disableResidual {
        // one non-linear quantisation block per component, behind the curves:
        // an offset, then the input maximum with the dead zone's slope and
        // threshold
        let start = reader.bit
        for _ in 0..<3 {
            try reader.skip(elBitDepth)
            for _ in 0..<3 {
                _ = try reader.unsignedGolomb()
                try reader.skip(coefLog2Denom)
            }
        }
        nlq.append(start..<reader.bit)
    }
    return curves
}

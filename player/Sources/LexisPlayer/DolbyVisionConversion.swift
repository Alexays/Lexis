import CoreMedia
import Foundation

/// The 8.1 configuration a profile 7 stream is handed over as: its base layer
/// is HDR10, and the enhancement layer is left behind.
func dolbyVisionEightOne(from seven: DolbyVisionConfiguration) -> DolbyVisionConfiguration {
    var record = [UInt8](seven.record)
    record[2] = (8 << 1) | ((seven.level >> 5) & 0x01)
    // RPU and base layer present, no enhancement layer
    record[3] = ((seven.level & 0x1f) << 3) | 0b101
    record[4] = (1 << 4) | (record[4] & 0x0c)
    return DolbyVisionConfiguration(
        profile: 8, level: seven.level, hasRPU: true, hasEnhancementLayer: false, hasBaseLayer: true,
        compatibility: 1, record: Data(record))
}

/// A profile 7 RPU as profile 8.1 carries it, the rewrite dovi_tool's mode 2
/// makes: the residual turned off and its NLQ sections dropped, the base
/// layer's reshaping and the display management kept bit for bit. Takes and
/// returns the NAL payload behind its two-byte header, escaped.
public func dolbyVisionRPUAsEightOne(_ payload: Data) throws -> Data {
    let source = unescape(payload)
    var reader = BitReader(source)
    guard source.count > 6, try reader.read(8) == 25, try reader.read(6) == 2 else {
        throw RPUParseError.notAnRPU
    }
    let format = try reader.read(11)
    try reader.skip(8) // vdr_rpu_profile, vdr_rpu_level
    guard try reader.flag() else { throw RPUParseError.unsupported("no sequence info") }
    try reader.skip(1) // chroma_resampling_explicit_filter_flag
    guard try reader.read(2) == 0 else { throw RPUParseError.unsupported("float coefficients") }
    let coefLog2Denom = Int(try reader.unsignedGolomb())
    try reader.skip(3) // vdr_rpu_normalized_idc, bl_video_full_range_flag
    guard format & 0x700 == 0 else { throw RPUParseError.unsupported("rpu format \(format)") }
    let blBitDepth = Int(try reader.unsignedGolomb()) + 8
    let elBitDepth = Int(try reader.unsignedGolomb() & 0xff) + 8
    _ = try reader.unsignedGolomb() // vdr_bit_depth_minus8
    try reader.skip(1) // spatial_resampling_filter_flag
    guard try reader.read(3) == 0 else { throw RPUParseError.unsupported("compressed display management") }
    let flags = reader.bit
    try reader.skip(1) // el_spatial_resampling_filter_flag
    let disableResidual = try reader.flag()
    let dmPresent = try reader.flag()
    let usePrevious = try reader.flag()

    var writer = BitWriter()
    writer.copy(source, from: 0, to: flags)
    // no enhancement layer to resample, no residual to add
    writer.write(0b01, 2)
    var at = flags + 2
    var dropped: [Range<Int>] = []
    if usePrevious {
        _ = try reader.unsignedGolomb() // prev_vdr_rpu_id
    } else {
        _ = try readMapping(
            &reader, blBitDepth: blBitDepth, elBitDepth: elBitDepth, coefLog2Denom: coefLog2Denom,
            disableResidual: disableResidual, nlq: &dropped)
    }
    for span in dropped {
        writer.copy(source, from: at, to: span.lowerBound)
        at = span.upperBound
    }
    writer.copy(source, from: at, to: reader.bit)
    let end = (source.count - 5) * 8 // the CRC and the terminator
    if dmPresent {
        // The fields up to the first alignment are copied as bits; from it
        // on everything is whole bytes, on both sides.
        let start = reader.bit
        for _ in 0..<3 { _ = try reader.unsignedGolomb() } // affected, current id, scene refresh
        try reader.skip(9 * 16 + 3 * 32 + 9 * 16 + 3 * 16 + 32 + 11 + 12 + 12 + 10)
        _ = try reader.unsignedGolomb() // num_ext_blocks
        writer.copy(source, from: start, to: reader.bit)
        reader.align()
        writer.align()
        guard reader.bit <= end else { throw RPUParseError.truncated }
        writer.copy(source, from: reader.bit, to: end)
    }
    writer.align()

    var bytes = writer.bytes
    // MPEG-2 CRC32 over everything after the 0x19 prefix
    var crc: UInt32 = 0xffff_ffff
    for byte in bytes.dropFirst() {
        crc ^= UInt32(byte) << 24
        for _ in 0..<8 { crc = crc & 0x8000_0000 != 0 ? (crc << 1) ^ 0x04c1_1db7 : crc << 1 }
    }
    bytes += [UInt8(crc >> 24), UInt8(crc >> 16 & 0xff), UInt8(crc >> 8 & 0xff), UInt8(crc & 0xff), 0x80]

    var escaped = Data(capacity: bytes.count + bytes.count / 64 + 4)
    var zeros = 0
    for byte in bytes {
        if zeros >= 2, byte <= 3 {
            escaped.append(3)
            zeros = 0
        }
        escaped.append(byte)
        zeros = byte == 0 ? zeros + 1 : 0
    }
    return escaped
}

/// A profile 7 access unit as profile 8.1 carries it, in one new block: the
/// enhancement layer's NALs (type 63) left out and the RPU rewritten. An RPU
/// the rewrite refuses goes as it was. Nil where the packet does not walk.
public func dolbyVisionAccessUnitAsEightOne(_ packet: UnsafeRawBufferPointer, lengthSize: Int) -> CMBlockBuffer? {
    var kept: [Range<Int>] = []
    var rpu: (at: Int, nal: Data)?
    var size = 0
    var offset = 0
    while offset + lengthSize <= packet.count {
        var length = 0
        for i in 0..<lengthSize { length = length << 8 | Int(packet[offset + i]) }
        let start = offset + lengthSize
        guard length >= 2, start + length <= packet.count else { return nil }
        let type = (packet[start] >> 1) & 0x3f
        if type == 62, rpu == nil,
            let converted = try? dolbyVisionRPUAsEightOne(Data(bytes: packet.baseAddress! + start + 2, count: length - 2))
        {
            rpu = (kept.count, Data([packet[start], packet[start + 1]]) + converted)
            size += lengthSize + converted.count + 2
        } else if type != 63 {
            kept.append(offset..<start + length)
            size += lengthSize + length
        }
        offset = start + length
    }
    var block: CMBlockBuffer?
    guard CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: size,
        blockAllocator: CMMemoryPoolGetAllocator(accessUnitPool),
        customBlockSource: nil, offsetToData: 0, dataLength: size, flags: kCMBlockBufferAssureMemoryNowFlag,
        blockBufferOut: &block) == noErr, let block
    else { return nil }
    var pointer: UnsafeMutablePointer<CChar>?
    guard CMBlockBufferGetDataPointer(
        block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: nil, dataPointerOut: &pointer) == noErr,
        let pointer
    else { return nil }
    let out = UnsafeMutableRawPointer(pointer)
    var written = 0
    func writeRPU(_ nal: Data) {
        for i in 0..<lengthSize { out.storeBytes(of: UInt8(nal.count >> (8 * (lengthSize - 1 - i)) & 0xff), toByteOffset: written + i, as: UInt8.self) }
        nal.copyBytes(to: (out + written + lengthSize).assumingMemoryBound(to: UInt8.self), count: nal.count)
        written += lengthSize + nal.count
    }
    for (index, range) in kept.enumerated() {
        if let rpu, rpu.at == index { writeRPU(rpu.nal) }
        (out + written).copyMemory(from: packet.baseAddress! + range.lowerBound, byteCount: range.count)
        written += range.count
    }
    if let rpu, rpu.at == kept.count { writeRPU(rpu.nal) }
    return block
}

/// Where the rewritten access units come from: a fresh allocation the size of
/// a UHD frame is fresh pages, faulted in on the decode thread every frame,
/// where a pool hands back the ones the display layer let go of.
private let accessUnitPool = CMMemoryPoolCreate(options: nil)

/// The reverse of `BitReader`, for the RPU rewrite.
struct BitWriter {
    private(set) var bytes: [UInt8] = []
    private(set) var bit = 0

    mutating func write(_ value: UInt32, _ count: Int) {
        for shift in stride(from: count - 1, through: 0, by: -1) {
            if bit & 7 == 0 { bytes.append(0) }
            if (value >> UInt32(shift)) & 1 != 0 { bytes[bit >> 3] |= 0x80 >> UInt8(bit & 7) }
            bit += 1
        }
    }

    /// Bits `from..<to` of `source`, a byte at a time where both sides stand
    /// on a byte.
    mutating func copy(_ source: [UInt8], from: Int, to: Int) {
        var at = from
        if bit & 7 == 0, at & 7 == 0, to - at >= 8 {
            let whole = (to - at) >> 3
            bytes += source[(at >> 3)..<(at >> 3) + whole]
            bit += whole << 3
            at += whole << 3
        }
        while at < to {
            write(UInt32(source[at >> 3] >> (7 - UInt8(at & 7)) & 1), 1)
            at += 1
        }
    }

    /// The bits up to the next byte are zero already.
    mutating func align() { bit = (bit + 7) & ~7 }
}

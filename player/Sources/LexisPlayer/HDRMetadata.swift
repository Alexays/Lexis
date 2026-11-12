import CFFmpeg
import CoreMedia
import Foundation

/// What the container says about a Dolby Vision track, straight out of its
/// dvcC or dvvC box.
public struct DolbyVisionConfiguration: Sendable, Equatable, Codable {
    public let profile: UInt8
    public let level: UInt8
    public let hasRPU: Bool
    public let hasEnhancementLayer: Bool
    public let hasBaseLayer: Bool
    /// 0 none, 1 HDR10, 2 SDR, 4 HLG, 6 HDR10 as a UHD Blu-ray carries it.
    /// What the base layer is on its own.
    public let compatibility: UInt8
    /// The 24 bytes a format description carries as its dvcC or dvvC atom.
    public let record: Data

    /// The base layer is a picture a display can show without the RPU. Profile
    /// 5 signals none of that and has to be mapped here instead. Profile 7's
    /// base layer (id 6) is HDR10: the enhancement layer refines it and is
    /// not read here, so the picture shown is the HDR10 every other player
    /// shows for that profile.
    public var baseLayerIsDisplayable: Bool {
        compatibility == 1 || compatibility == 2 || compatibility == 4 || compatibility == 6
    }

    /// Whether the record may ride to the display layer beside the hvcC: only
    /// a stream the platform can decode whole. A profile 7 record announces an
    /// enhancement layer this player never hands over, and a decoder told to
    /// expect one is not being told the truth about the samples it gets.
    public var recordDescribesWhatIsHandedOver: Bool {
        baseLayerIsDisplayable && !hasEnhancementLayer
    }

    /// dvvC from profile 8 up, dvcC below.
    public var atomKey: String { profile >= 8 ? "dvvC" : "dvcC" }
}

/// Rebuilds the 24-byte record from FFmpeg's parsed struct, in the layout the
/// ISO box uses: seven bits of profile, six of level, three flags, then the
/// compatibility id and the compression method.
func dolbyVisionRecord(_ record: AVDOVIDecoderConfigurationRecord) -> Data {
    var bytes = [UInt8](repeating: 0, count: 24)
    bytes[0] = record.dv_version_major
    bytes[1] = record.dv_version_minor
    bytes[2] = (record.dv_profile << 1) | ((record.dv_level >> 5) & 0x01)
    bytes[3] = ((record.dv_level & 0x1f) << 3)
        | (record.rpu_present_flag << 2)
        | (record.el_present_flag << 1)
        | record.bl_present_flag
    bytes[4] = (record.dv_bl_signal_compatibility_id << 4) | (record.dv_md_compression << 2)
    return Data(bytes)
}

/// SMPTE ST 2086 as CoreMedia wants it: green, blue, red and the white point
/// in units of 0.00002, then the two luminances in units of 0.0001 cd/m2.
/// FFmpeg holds the primaries in red, green, blue order, so they are swapped
/// here and nowhere else.
func masteringDisplayVolume(_ metadata: AVMasteringDisplayMetadata) -> Data? {
    guard metadata.has_primaries != 0, metadata.has_luminance != 0 else { return nil }
    var data = Data(capacity: 24)
    func append(_ value: UInt16) {
        data.append(UInt8(value >> 8))
        data.append(UInt8(value & 0xff))
    }
    // A 0/0 rational from the container scales to NaN, which min and max
    // propagate rather than clamp, and converting NaN to an integer traps.
    func chromaticity(_ rational: AVRational) -> UInt16 {
        let scaled = (Double(rational.num) / Double(rational.den) * 50000).rounded()
        guard scaled.isFinite else { return 0 }
        return UInt16(min(max(scaled, 0), 65535))
    }
    let primaries = withUnsafeBytes(of: metadata.display_primaries) { raw in
        Array(raw.bindMemory(to: AVRational.self))
    }
    for component in [1, 2, 0] {
        append(chromaticity(primaries[component * 2]))
        append(chromaticity(primaries[component * 2 + 1]))
    }
    append(chromaticity(metadata.white_point.0))
    append(chromaticity(metadata.white_point.1))
    func appendLuminance(_ rational: AVRational) {
        let scaled = (Double(rational.num) / Double(rational.den) * 10000).rounded()
        // NaN for the same reason, and it traps the same way.
        let value = scaled.isFinite ? UInt32(min(max(scaled, 0), Double(UInt32.max))) : 0
        data.append(UInt8((value >> 24) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8(value & 0xff))
    }
    appendLuminance(metadata.max_luminance)
    appendLuminance(metadata.min_luminance)
    return data
}

/// CTA-861.3: maximum content light level then maximum frame average, in nits.
func contentLightLevel(_ metadata: AVContentLightMetadata) -> Data? {
    guard metadata.MaxCLL > 0 || metadata.MaxFALL > 0 else { return nil }
    var data = Data(capacity: 4)
    for value in [metadata.MaxCLL, metadata.MaxFALL] {
        let clamped = UInt16(min(value, UInt32(UInt16.max)))
        data.append(UInt8(clamped >> 8))
        data.append(UInt8(clamped & 0xff))
    }
    return data
}

/// The colour tags CoreMedia has a name for, and nil where it has none. A
/// missing tag is left off the format description, which is what every stream
/// got before HDR.
func colorPrimariesName(_ value: Int32) -> CFString? {
    switch AVColorPrimaries(rawValue: UInt32(bitPattern: value)) {
    case AVCOL_PRI_BT709: return kCMFormatDescriptionColorPrimaries_ITU_R_709_2
    case AVCOL_PRI_BT2020: return kCMFormatDescriptionColorPrimaries_ITU_R_2020
    case AVCOL_PRI_SMPTE170M: return kCMFormatDescriptionColorPrimaries_SMPTE_C
    case AVCOL_PRI_BT470BG: return kCMFormatDescriptionColorPrimaries_EBU_3213
    case AVCOL_PRI_SMPTE431, AVCOL_PRI_SMPTE432: return kCMFormatDescriptionColorPrimaries_P3_D65
    default: return nil
    }
}

func transferFunctionName(_ value: Int32) -> CFString? {
    switch AVColorTransferCharacteristic(rawValue: UInt32(bitPattern: value)) {
    case AVCOL_TRC_BT709, AVCOL_TRC_SMPTE170M, AVCOL_TRC_BT2020_10, AVCOL_TRC_BT2020_12:
        return kCMFormatDescriptionTransferFunction_ITU_R_709_2
    case AVCOL_TRC_SMPTE2084: return kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
    case AVCOL_TRC_ARIB_STD_B67: return kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG
    case AVCOL_TRC_IEC61966_2_1: return kCMFormatDescriptionTransferFunction_sRGB
    case AVCOL_TRC_LINEAR: return kCMFormatDescriptionTransferFunction_Linear
    default: return nil
    }
}

func yCbCrMatrixName(_ value: Int32) -> CFString? {
    switch AVColorSpace(rawValue: UInt32(bitPattern: value)) {
    case AVCOL_SPC_BT709: return kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2
    case AVCOL_SPC_BT2020_NCL, AVCOL_SPC_BT2020_CL:
        return kCMFormatDescriptionYCbCrMatrix_ITU_R_2020
    case AVCOL_SPC_SMPTE170M, AVCOL_SPC_BT470BG: return kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4
    default: return nil
    }
}

/// The peak the master was graded on, as a PQ code, out of the last eight
/// bytes of the ST 2086 payload, or nil where the stream carries no box.
///
/// Nil rather than a stand-in, because the two cases are not the same
/// question. A stated peak is the colourist's, and the curve is entitled to
/// clip above it. A missing one is a guess, and a guess that lands under what
/// the picture actually holds flattens every highlight above it to white:
/// remuxes lose this box routinely, and a 4000 nit grade read as 1000 loses
/// three quarters of its range. The caller decides what to do about not
/// knowing; see `ToneMappedVideo`.
/// The brightest pixel the film holds, as a PQ code, out of the first two
/// bytes of the CTA-861.3 payload, or nil where the stream carries none or
/// states zero.
///
/// Better information than the mastering display's peak wherever both are
/// present, which is most of the time. ST 2086 states what the monitor the
/// grade was made on could reach; this states what the picture actually does.
/// A film graded on a 4000 nit monitor whose brightest shot is 800 spends
/// three quarters of the curve on light that is not in it, and the shadows
/// are what pay for that.
public func contentPeakPQ(_ contentLight: Data?) -> Float? {
    guard let data = contentLight, data.count >= 2 else { return nil }
    let nits = UInt32(data[data.startIndex]) << 8 | UInt32(data[data.startIndex + 1])
    guard nits > 0 else { return nil }
    return pqInverseEOTF(min(Double(nits), 10000) / 10000)
}

/// The black the master was graded against, as a PQ code, out of the last
/// four bytes of the ST 2086 payload, or nil where the stream carries no box
/// or states zero.
///
/// The curve's source range starts here rather than at absolute black. What
/// it changes is small - masters state somewhere between 0.0001 and 0.005
/// nits, whose PQ codes are near zero either way - but it is the difference
/// between a range the file described and one this code assumed, and the box
/// is already being read for its other half.
public func masteringBlackPQ(_ masteringDisplay: Data?) -> Float? {
    guard let data = masteringDisplay, data.count >= 24 else { return nil }
    var raw: UInt32 = 0
    for i in 20..<24 { raw = raw << 8 | UInt32(data[data.startIndex + i]) }
    guard raw > 0 else { return nil }
    return pqInverseEOTF(min(Double(raw) / 10000, 10000) / 10000)
}

public func masteringPeakPQ(_ masteringDisplay: Data?) -> Float? {
    guard let data = masteringDisplay, data.count >= 24 else { return nil }
    var nits: UInt32 = 0
    for i in 16..<20 { nits = nits << 8 | UInt32(data[data.startIndex + i]) }
    guard nits > 0 else { return nil }
    return pqInverseEOTF(min(Double(nits) / 10000, 10000) / 10000)
}

/// The two transfers a display has to be told about. Everything else is shown
/// the way SDR always was.
public func isHighDynamicRange(_ transfer: Int32) -> Bool {
    let value = AVColorTransferCharacteristic(rawValue: UInt32(bitPattern: transfer))
    return value == AVCOL_TRC_SMPTE2084 || value == AVCOL_TRC_ARIB_STD_B67
}

/// One of the two transfers the tone map kernel decodes; `isHybridLogGamma`
/// is the other, and the pair partitions `isHighDynamicRange`.
public func isPerceptualQuantizer(_ transfer: Int32) -> Bool {
    AVColorTransferCharacteristic(rawValue: UInt32(bitPattern: transfer)) == AVCOL_TRC_SMPTE2084
}

public func isHybridLogGamma(_ transfer: Int32) -> Bool {
    AVColorTransferCharacteristic(rawValue: UInt32(bitPattern: transfer)) == AVCOL_TRC_ARIB_STD_B67
}

/// The static HDR10 metadata for a picture mapped onto a display of the given
/// peak: a P3-D65 mastering display, what HDR10 masters state, whose
/// luminance runs from 0.005 nits, a mastering monitor's black, to the peak,
/// and a content light level of the peak. A display reads the stated black as where the picture's own sits and
/// may lift its blacks to meet it, so it is never a share of the peak. The 24
/// and 4 byte payloads a format description or a picture carries.
public func hdr10StaticMetadata(peakNits: Double) -> (masteringDisplay: Data, contentLight: Data) {
    var mastering = Data()
    // G, B, R, then the white point, in units of 0.00002: P3 and D65
    for value in [13250, 34500, 7500, 3000, 34000, 16000, 15635, 16450] as [UInt16] {
        mastering.append(contentsOf: [UInt8(value >> 8), UInt8(value & 0xFF)])
    }
    let peak = UInt32(min(max(peakNits, 1), 10000) * 10000)
    for value in [peak, 50] as [UInt32] {
        mastering.append(contentsOf: [
            UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF),
        ])
    }
    let light = UInt16(min(max(peakNits, 1), 10000))
    let contentLight = Data([UInt8(light >> 8), UInt8(light & 0xFF), 0, 0])
    return (mastering, contentLight)
}

/// The T.35 header the decoder may leave on an HDR10+ payload.
private let hdr10PlusHeader: [UInt8] = [0xB5, 0x00, 0x3C, 0x00, 0x01, 0x04]

/// HDR10+'s tone mapping curve for a scene (ST 2094-40): drawn for a display
/// of `display` (1.0 is 10000 nits) over linear light normalized to the
/// scene's peak, a line to the knee and a Bezier past it through
/// `anchorCount` inner anchors, each in 0...1.
struct HDR10PlusCurve: Equatable {
    var display: Float
    var knee: SIMD2<Float>
    var anchors: SIMD16<Float>
    var anchorCount: Int
}

/// The scene's own peak and mean from an HDR10+ payload (ST 2094-40), as PQ
/// codes: the highest percentile of its maxRGB distribution at or past 99,
/// or its brightest maxSCL, and its average maxRGB; and the first window's
/// curve, where it carries one. The curve is drawn over the brightest
/// maxSCL, or the top percentile where maxSCL is missing (ST 2094-40 B.3),
/// and the peak is that one then. The decoder hands the payload over with or
/// without its T.35 header. Nil for bytes ffmpeg cannot read, a peak under 5
/// nits, or a mean that is not under it.
func hdr10PlusScene(_ payload: Data) -> (peakPQ: Float, averagePQ: Float, curve: HDR10PlusCurve?)? {
    let body = payload.starts(with: hdr10PlusHeader) ? payload.dropFirst(hdr10PlusHeader.count) : payload
    var metadata = AVDynamicHDRPlus()
    let status = body.withUnsafeBytes { bytes in
        av_dynamic_hdr_plus_from_t35(&metadata, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count)
    }
    guard status >= 0, metadata.num_windows > 0 else { return nil }
    let window = metadata.params.0
    // on ffmpeg's axis, where 1.0 is 10000 nits
    func light(_ value: AVRational) -> Double { value.den == 0 ? 0 : Double(value.num) / Double(value.den) }
    // read in place: this runs on every picture of an HDR10+ film
    let highest = withUnsafeBytes(of: window.distribution_maxrgb) { raw -> AVHDRPlusPercentile? in
        var highest: AVHDRPlusPercentile?
        let percentiles = raw.bindMemory(to: AVHDRPlusPercentile.self)
        for percentile in percentiles.prefix(Int(window.num_distribution_maxrgb_percentiles))
        where percentile.percentage >= 99 && percentile.percentage > (highest?.percentage ?? 0) {
            highest = percentile
        }
        return highest
    }
    let brightest = max(light(window.maxscl.0), light(window.maxscl.1), light(window.maxscl.2))
    var curve: HDR10PlusCurve?
    var peak = highest.map { light($0.percentile) } ?? brightest
    let count = Int(window.num_bezier_curve_anchors)
    if window.tone_mapping_flag != 0, count > 0, count < 16 {
        var anchors = SIMD16<Float>()
        withUnsafeBytes(of: window.bezier_curve_anchors) { raw in
            for (i, anchor) in raw.bindMemory(to: AVRational.self).prefix(count).enumerated() {
                anchors[i] = Float(light(anchor))
            }
        }
        curve = HDR10PlusCurve(
            display: Float(light(metadata.targeted_system_display_maximum_luminance) / 10000),
            knee: SIMD2(Float(light(window.knee_point_x)), Float(light(window.knee_point_y))),
            anchors: anchors, anchorCount: count)
        let top = withUnsafeBytes(of: window.distribution_maxrgb) { raw in
            raw.bindMemory(to: AVHDRPlusPercentile.self)
                .prefix(Int(window.num_distribution_maxrgb_percentiles)).last.map { light($0.percentile) }
        }
        peak = brightest > 0 ? brightest : top ?? peak
    }
    let average = light(window.average_maxrgb)
    guard peak >= 5.0 / 10000, average > 0, average < peak else { return nil }
    return (pqInverseEOTF(peak), pqInverseEOTF(average), curve)
}

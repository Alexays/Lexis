import CFFmpeg
import CoreMedia
import LexisTestSupport
import XCTest
@testable import LexisPlayer

final class DolbyVisionRPUTests: XCTestCase {
    func testEveryAccessUnitCarriesAnRPUAndItParses() throws {
        let url = try makeHDRFixture(
            directory: FileManager.default.temporaryDirectory, name: "rpu.mp4",
            width: 320, height: 180, frameCount: 8, transfer: .hlg
        )
        let demuxer = try Demuxer(url: url)
        let lengthSize = nalLengthSize(hvcC: demuxer.streams[0].extradata)
        XCTAssertEqual(lengthSize, 4)
        var parsed: [DolbyVisionRPU] = []
        while let packet = try demuxer.readPacket() {
            guard let payload = packet.withUnsafeBytes({
                dolbyVisionRPUPayload(in: $0, lengthSize: lengthSize)
            })
            else { continue }
            XCTAssertEqual(payload.count, 420)
            XCTAssertEqual(payload.first, 0x19)
            parsed.append(try parseDolbyVisionRPU(payload))
        }
        XCTAssertEqual(parsed.count, 8)
        let rpu = try XCTUnwrap(parsed.first)
        XCTAssertEqual(rpu.profile, 1)
        XCTAssertEqual(rpu.level, 0)
        XCTAssertEqual(rpu.blBitDepth, 10)
        XCTAssertEqual(rpu.elBitDepth, 10)
        XCTAssertEqual(rpu.vdrBitDepth, 12)
        XCTAssertTrue(rpu.disableResidual)
        XCTAssertTrue(rpu.sceneRefresh)
        XCTAssertEqual(rpu.sourceMinPQ, 62)
        XCTAssertEqual(rpu.sourceMaxPQ, 3079)
        // the level 1 block: how bright this frame is
        XCTAssertEqual(rpu.minPQ, 0)
        XCTAssertEqual(rpu.maxPQ, 3079)
        XCTAssertEqual(rpu.avgPQ, 1731)
        // the colour matrix, which for this stream is BT.2020 limited range
        XCTAssertEqual(rpu.yccToRGB[0], 9574.0 / 8192, accuracy: 1e-6)
        XCTAssertEqual(rpu.yccToRGB[2], 13802.0 / 8192, accuracy: 1e-6)
        XCTAssertEqual(rpu.yccOffset, [0.0625, 0.5, 0.5])
        XCTAssertEqual(rpu.rgbToLMS[0], 7222.0 / 16384, accuracy: 1e-6)
    }

    func testARPUThatIsNotOneIsRefused() {
        XCTAssertThrowsError(try parseDolbyVisionRPU(Data([0x00, 0x01, 0x02]))) { error in
            XCTAssertEqual(error as? RPUParseError, .notAnRPU)
        }
        XCTAssertThrowsError(try parseDolbyVisionRPU(Data([25, 0x00]))) { error in
            XCTAssertEqual(error as? RPUParseError, .unsupportedType(0))
        }
        XCTAssertThrowsError(try parseDolbyVisionRPU(Data([25, 0x08, 0x09]))) { error in
            XCTAssertEqual(error as? RPUParseError, .truncated)
        }
    }

    func testAPacketWithNoRPUAnswersNil() throws {
        let url = try makeHDRFixture(
            directory: FileManager.default.temporaryDirectory, name: "rpu-none.mp4",
            width: 320, height: 180, frameCount: 4, transfer: .pq
        )
        let demuxer = try Demuxer(url: url)
        while let packet = try demuxer.readPacket() {
            XCTAssertNil(packet.withUnsafeBytes { dolbyVisionRPUPayload(in: $0, lengthSize: 4) })
        }
    }

    /// The fixture is profile 8 single layer, so it never carries the NLQ
    /// section a dual layer stream puts behind the reshaping curves. This
    /// authors one, and asks that the display management behind it reads the
    /// same either way.
    func testAnRPUCarryingAnNLQSectionStillReachesItsDisplayManagement() throws {
        var shape = SyntheticRPU()
        // the enhancement layer bit depth shares its field with
        // ext_mapping_idc, and the NLQ section is measured in that bit depth
        shape.extMappingIdc = 1
        shape.residual = false
        let plain = makeRPU(shape)
        let baseline = try parseDolbyVisionRPU(plain)
        XCTAssertEqual(baseline.profile, 7)
        XCTAssertTrue(baseline.disableResidual)
        XCTAssertEqual(baseline.blBitDepth, 10)
        XCTAssertEqual(baseline.elBitDepth, 10)
        XCTAssertEqual(baseline.vdrBitDepth, 12)
        XCTAssertTrue(baseline.sceneRefresh)
        XCTAssertEqual(baseline.sourceMinPQ, 62)
        XCTAssertEqual(baseline.sourceMaxPQ, 3079)
        XCTAssertEqual(baseline.minPQ, 7)
        XCTAssertEqual(baseline.maxPQ, 3000)
        XCTAssertEqual(baseline.avgPQ, 1200)
        XCTAssertEqual(baseline.yccToRGB[0], 1000.0 / 8192, accuracy: 1e-6)
        XCTAssertEqual(baseline.yccOffset[0], 1.0 / 256, accuracy: 1e-9)
        XCTAssertEqual(baseline.rgbToLMS[0], -100.0 / 16384, accuracy: 1e-6)

        shape.residual = true
        let withNLQ = try parseDolbyVisionRPU(makeRPU(shape))
        XCTAssertFalse(withNLQ.disableResidual)
        XCTAssertEqual(withNLQ.sourceMinPQ, baseline.sourceMinPQ)
        XCTAssertEqual(withNLQ.sourceMaxPQ, baseline.sourceMaxPQ)
        XCTAssertEqual(withNLQ.minPQ, baseline.minPQ)
        XCTAssertEqual(withNLQ.maxPQ, baseline.maxPQ)
        XCTAssertEqual(withNLQ.avgPQ, baseline.avgPQ)
        XCTAssertEqual(withNLQ.yccToRGB, baseline.yccToRGB)
        XCTAssertEqual(withNLQ.yccOffset, baseline.yccOffset)
        XCTAssertEqual(withNLQ.rgbToLMS, baseline.rgbToLMS)
    }

    /// Shapes whose fields this parser cannot locate. Each one is refused, the
    /// way the reference decoder refuses it, instead of walking on with a
    /// guessed width and answering a plausible struct full of wrong numbers.
    func testAShapeThatCannotBeWalkedIsRefusedRatherThanGuessed() {
        var noSequenceInfo = SyntheticRPU()
        noSequenceInfo.sequenceInfo = false
        XCTAssertThrowsError(try parseDolbyVisionRPU(makeRPU(noSequenceInfo))) { error in
            XCTAssertEqual(error as? RPUParseError, .unsupported("no sequence info"))
        }
        var floatCoefficients = SyntheticRPU()
        floatCoefficients.coefficientDataType = 1
        XCTAssertThrowsError(try parseDolbyVisionRPU(makeRPU(floatCoefficients))) { error in
            XCTAssertEqual(error as? RPUParseError, .unsupported("float coefficients"))
        }
        var unknownFormat = SyntheticRPU()
        unknownFormat.format = 0x100
        XCTAssertThrowsError(try parseDolbyVisionRPU(makeRPU(unknownFormat))) { error in
            XCTAssertEqual(error as? RPUParseError, .unsupported("rpu format 256"))
        }
        var compressed = SyntheticRPU()
        compressed.dmCompression = 1
        XCTAssertThrowsError(try parseDolbyVisionRPU(makeRPU(compressed))) { error in
            XCTAssertEqual(error as? RPUParseError, .unsupported("compressed display management"))
        }
        var linear = SyntheticRPU()
        linear.linearInterpolation = true
        XCTAssertThrowsError(try parseDolbyVisionRPU(makeRPU(linear))) { error in
            XCTAssertEqual(error as? RPUParseError, .unsupported("linear interpolation"))
        }
        var unknownNLQ = SyntheticRPU()
        unknownNLQ.residual = true
        unknownNLQ.nlqMethod = 1
        XCTAssertThrowsError(try parseDolbyVisionRPU(makeRPU(unknownNLQ))) { error in
            XCTAssertEqual(error as? RPUParseError, .unsupported("nlq method"))
        }
    }

    /// The parser against FFmpeg's, on the same bytes: libavcodec's HEVC
    /// decoder reads the RPU too and hands it back as frame side data.
    func testItAgreesWithFFmpegsOwnParser() throws {
        let url = try makeHDRFixture(
            directory: FileManager.default.temporaryDirectory, name: "rpu-ref.mp4",
            width: 320, height: 180, frameCount: 8, transfer: .hlg
        )
        var context: UnsafeMutablePointer<AVFormatContext>?
        XCTAssertEqual(avformat_open_input(&context, url.path, nil, nil), 0)
        defer { avformat_close_input(&context) }
        XCTAssertGreaterThanOrEqual(avformat_find_stream_info(context, nil), 0)
        let parameters = context!.pointee.streams[0]!.pointee.codecpar!
        let codec = avcodec_find_decoder(parameters.pointee.codec_id)
        let decoder = try XCTUnwrap(avcodec_alloc_context3(codec))
        defer {
            var toFree: UnsafeMutablePointer<AVCodecContext>? = decoder
            avcodec_free_context(&toFree)
        }
        XCTAssertGreaterThanOrEqual(avcodec_parameters_to_context(decoder, parameters), 0)
        XCTAssertEqual(avcodec_open2(decoder, codec, nil), 0)
        let packet = try XCTUnwrap(av_packet_alloc())
        let frame = try XCTUnwrap(av_frame_alloc())
        defer {
            var onePacket: UnsafeMutablePointer<AVPacket>? = packet
            var oneFrame: UnsafeMutablePointer<AVFrame>? = frame
            av_packet_free(&onePacket)
            av_frame_free(&oneFrame)
        }
        var reference: (UInt16, UInt16, UInt16)?
        var header: (UInt8, UInt8, UInt16, UInt16)?
        var curves: [DolbyVisionReshapingCurve] = []
        while reference == nil {
            av_packet_unref(packet)
            guard av_read_frame(context, packet) >= 0 else { break }
            guard avcodec_send_packet(decoder, packet) >= 0 else { continue }
            while avcodec_receive_frame(decoder, frame) >= 0, reference == nil {
                guard let side = av_frame_get_side_data(frame, AV_FRAME_DATA_DOVI_METADATA)
                else { continue }
                let base = UnsafeRawPointer(side.pointee.data!)
                let metadata = base.assumingMemoryBound(to: AVDOVIMetadata.self).pointee
                let rpuHeader = base.advanced(by: metadata.header_offset)
                    .assumingMemoryBound(to: AVDOVIRpuDataHeader.self).pointee
                let color = base.advanced(by: metadata.color_offset)
                    .assumingMemoryBound(to: AVDOVIColorMetadata.self).pointee
                header = (
                    rpuHeader.vdr_rpu_profile, rpuHeader.bl_bit_depth,
                    color.source_min_pq, color.source_max_pq
                )
                var mapping = base.advanced(by: metadata.mapping_offset)
                    .assumingMemoryBound(to: AVDOVIDataMapping.self).pointee
                let scale = Double(UInt64(1) << UInt64(rpuHeader.coef_log2_denom))
                curves = withUnsafeBytes(of: &mapping.curves) { raw in
                    raw.bindMemory(to: AVDOVIReshapingCurve.self).map { curve in
                        var curve = curve
                        let count = Int(curve.num_pivots)
                        let pivots = withUnsafeBytes(of: &curve.pivots) { Array($0.bindMemory(to: UInt16.self).prefix(count)) }
                        let methods = withUnsafeBytes(of: &curve.mapping_idc) { Array($0.bindMemory(to: UInt32.self).prefix(count - 1)) }
                        let orders = withUnsafeBytes(of: &curve.poly_order) { Array($0.bindMemory(to: UInt8.self).prefix(count - 1)) }
                        let poly = withUnsafeBytes(of: &curve.poly_coef) { Array($0.bindMemory(to: Int64.self)) }
                        let mmrOrders = withUnsafeBytes(of: &curve.mmr_order) { Array($0.bindMemory(to: UInt8.self)) }
                        let mmrConstants = withUnsafeBytes(of: &curve.mmr_constant) { Array($0.bindMemory(to: Int64.self)) }
                        let mmr = withUnsafeBytes(of: &curve.mmr_coef) { Array($0.bindMemory(to: Int64.self)) }
                        let pieces = (0..<(count - 1)).map { i -> DolbyVisionReshapingCurve.Piece in
                            guard methods[i] == 1 else {
                                return .polynomial((0...Int(orders[i])).map { Double(poly[i * 3 + $0]) / scale })
                            }
                            // mmr_coef is [piece][order][7]
                            let order = Int(mmrOrders[i])
                            return .mmr(
                                order: order, constant: Double(mmrConstants[i]) / scale,
                                coefficients: (0..<(order * 7)).map { Double(mmr[i * 21 + $0]) / scale })
                        }
                        return DolbyVisionReshapingCurve(pivots: pivots, pieces: pieces)
                    }
                }
                for i in 0..<Int(metadata.num_ext_blocks) {
                    let block = base
                        .advanced(by: metadata.ext_block_offset + metadata.ext_block_size * i)
                        .assumingMemoryBound(to: AVDOVIDmData.self).pointee
                    if block.level == 1 {
                        reference = (block.l1.min_pq, block.l1.max_pq, block.l1.avg_pq)
                    }
                }
            }
        }
        let expected = try XCTUnwrap(reference)
        let expectedHeader = try XCTUnwrap(header)

        let demuxer = try Demuxer(url: url)
        let lengthSize = nalLengthSize(hvcC: demuxer.streams[0].extradata)
        var ours: DolbyVisionRPU?
        while ours == nil, let packet = try demuxer.readPacket() {
            guard let payload = packet.withUnsafeBytes({
                dolbyVisionRPUPayload(in: $0, lengthSize: lengthSize)
            })
            else { continue }
            ours = try parseDolbyVisionRPU(payload)
        }
        let rpu = try XCTUnwrap(ours)
        XCTAssertEqual(rpu.minPQ, expected.0)
        XCTAssertEqual(rpu.maxPQ, expected.1)
        XCTAssertEqual(rpu.avgPQ, expected.2)
        XCTAssertEqual(rpu.profile, expectedHeader.0)
        XCTAssertEqual(UInt8(rpu.blBitDepth), expectedHeader.1)
        XCTAssertEqual(rpu.sourceMinPQ, expectedHeader.2)
        XCTAssertEqual(rpu.sourceMaxPQ, expectedHeader.3)
        XCTAssertEqual(rpu.reshaping, curves)
    }

    /// The trim passes, level 2 for content mapping v2.9 and level 8 for
    /// v4.0, each at its field's own width; v4.0's are the ones handed back
    /// where both are there, each display named by index as its peak.
    func testTrimPassesAreReadForEachTargetDisplay() throws {
        var shape = SyntheticRPU()
        shape.levelTwo = true
        shape.levelEight = true
        let rpu = try parseDolbyVisionRPU(makeRPU(shape))
        XCTAssertEqual(rpu.minPQ, 7)
        XCTAssertEqual(rpu.maxPQ, 3000)
        XCTAssertEqual(rpu.avgPQ, 1200)
        XCTAssertEqual(rpu.trims, [
            DolbyVisionTrim(
                targetMaxPQ: 2081, slope: 2170, offset: 2039, power: 1910, chromaWeight: 2048,
                saturationGain: 1942, msWeight: 2048, midContrast: 2048, clipTrim: 2365),
            DolbyVisionTrim(
                targetMaxPQ: 2557, slope: 2100, offset: 2048, power: 2000, chromaWeight: 2048,
                saturationGain: 2048, msWeight: 2048, midContrast: nil, clipTrim: nil),
            DolbyVisionTrim(
                targetMaxPQ: 2851, slope: 2060, offset: 2050, power: 2040, chromaWeight: 2048,
                saturationGain: 2030, msWeight: 2048, midContrast: nil, clipTrim: nil),
        ])
    }

    /// Without content mapping v4.0's blocks, the level 2 passes are the
    /// trims, the 13 bit ms_weight read signed; with none at all, there are
    /// none.
    func testLevelTwoPassesStandWithoutLevelEight() throws {
        var shape = SyntheticRPU()
        shape.levelTwo = true
        let rpu = try parseDolbyVisionRPU(makeRPU(shape))
        XCTAssertEqual(rpu.trims, [
            DolbyVisionTrim(
                targetMaxPQ: 2081, slope: 1800, offset: 2000, power: 1900, chromaWeight: 2048,
                saturationGain: 1844, msWeight: -1, midContrast: nil, clipTrim: nil),
            DolbyVisionTrim(
                targetMaxPQ: 2851, slope: 2100, offset: 2000, power: 1900, chromaWeight: 2048,
                saturationGain: 1844, msWeight: -1, midContrast: nil, clipTrim: nil),
        ])
        XCTAssertEqual(rpu.avgPQ, 1200)
        XCTAssertEqual(try parseDolbyVisionRPU(makeRPU(SyntheticRPU())).trims, [])
    }

    /// Two films' own RPUs, as their profile 8.1 streams carry them, read as
    /// libavcodec reads them: Kingdom's content mapping v2.9 passes for 100,
    /// 600 and 1000 nits, and Sous la Seine's v4.0 ones for Dolby's 100 and
    /// 600 nit displays, which stand in for its v2.9 copies.
    func testRealFilmsTrimPassesAreRead() throws {
        let kingdom = try parseDolbyVisionRPU(Data(hex: """
            19080908406136506f003ff801ffc00fffd0000008000006800000400000340000030200000301c95980000d7a8959be\
            7f3ac7095991328000004000000302000003000200000300070d8890c06182978c23814500000300698f96bfffc00000\
            0300000300000300180803e038542030080643fbea00c02821aef80492c800734400018056470dd017107000fd480003\
            00b01e00600a00a0020010000808e280a020140000030003c01e0048301f4000081d7800001ca35eeb80
            """))
        XCTAssertEqual([kingdom.minPQ, kingdom.maxPQ, kingdom.avgPQ], [12, 2175, 2004])
        XCTAssertEqual(kingdom.trims, [
            DolbyVisionTrim(
                targetMaxPQ: 2081, slope: 2799, offset: 2052, power: 2348, chromaWeight: 2048,
                saturationGain: 1844, msWeight: 2048, midContrast: nil, clipTrim: nil),
            DolbyVisionTrim(
                targetMaxPQ: 2851, slope: 2158, offset: 2059, power: 2179, chromaWeight: 2048,
                saturationGain: 2026, msWeight: 2048, midContrast: nil, clipTrim: nil),
            DolbyVisionTrim(
                targetMaxPQ: 3079, slope: 2049, offset: 2050, power: 2050, chromaWeight: 2048,
                saturationGain: 2048, msWeight: 2048, midContrast: nil, clipTrim: nil),
        ])
        let seine = try parseDolbyVisionRPU(Data(hex: """
            19080908406136506f003ff801ffc00fffd0000008000006800000400000340000030200000301a2566000035ea2566f\
            9fceb1c256644ca00000100000030080000003008000000301c36224301860a5e308e0514000001a63e5affff0000003\
            00000300000300060200f80e15083008014b6a6680c0282153b7e14a980079640001805647021000f4d0010008000300\
            b01e006001ffa00200100008085743d620140000030000030000030048301f4000081fc809b180301c004003ed00e080\
            187a7f777680079680080093d16103700100100100100100082409ff000100261bc32680
            """))
        XCTAssertEqual([seine.minPQ, seine.maxPQ, seine.avgPQ], [2, 2413, 1229])
        XCTAssertEqual(seine.trims, [
            DolbyVisionTrim(
                targetMaxPQ: 2081, slope: 2170, offset: 2039, power: 1910, chromaWeight: 2048,
                saturationGain: 1942, msWeight: 2048, midContrast: 2048, clipTrim: 2365),
            DolbyVisionTrim(
                targetMaxPQ: 2851, slope: 2048, offset: 2048, power: 2048, chromaWeight: 2048,
                saturationGain: 2048, msWeight: 2048, midContrast: nil, clipTrim: nil),
        ])
    }

    /// An MMR piece, which the fixture's encoder never writes: its order,
    /// constant and seven coefficients an order come back as written, each
    /// an integer part plus a fraction of coef_log2_denom bits.
    func testAnMMRPieceIsRead() throws {
        var shape = SyntheticRPU()
        shape.mmr = true
        let rpu = try parseDolbyVisionRPU(makeRPU(shape))
        let curves = try XCTUnwrap(rpu.reshaping)
        XCTAssertEqual(curves.count, 3)
        let fraction = 1.0 / Double(1 << 23)
        for curve in curves {
            XCTAssertEqual(curve.pivots, [0, 1023])
            XCTAssertEqual(curve.pieces, [.mmr(
                order: 2, constant: -1 + fraction,
                coefficients: (0..<14).map { Double($0 % 3) - 1 + fraction })])
        }
        XCTAssertEqual(rpu.minPQ, 7)
    }

    /// Profile 7 RPUs as UHD Blu-ray remuxes carry them, read as libavcodec
    /// reads them: a full enhancement layer's, its luma reshaped in eight
    /// pieces and its chroma by MMR, with content mapping v2.9's level 2, and
    /// a minimal one's with v4.0's level 8. Both put an NLQ section behind
    /// the curves, and neither is refused.
    func testProfileSevenRPUsAreRead() throws {
        let fel = try parseDolbyVisionRPU(Data(hex: profileSevenFEL))
        // a profile 7 RPU names itself 1 in its header, as profile 8 does;
        // its residual is what sets it apart
        XCTAssertEqual(fel.profile, 1)
        XCTAssertFalse(fel.disableResidual)
        XCTAssertEqual([fel.blBitDepth, fel.elBitDepth, fel.vdrBitDepth], [10, 10, 12])
        XCTAssertEqual([fel.sourceMinPQ, fel.sourceMaxPQ], [7, 3079])
        XCTAssertEqual([fel.minPQ, fel.maxPQ, fel.avgPQ], [0, 2873, 1060])
        XCTAssertEqual(fel.yccToRGB[0], 9574.0 / 8192, accuracy: 1e-6)
        XCTAssertEqual(fel.yccToRGB[2], 13802.0 / 8192, accuracy: 1e-6)
        XCTAssertEqual(fel.yccOffset, [0.0625, 0.5, 0.5])
        XCTAssertEqual(fel.trims, [
            DolbyVisionTrim(
                targetMaxPQ: 2081, slope: 2271, offset: 2085, power: 2048, chromaWeight: 2048,
                saturationGain: 1556, msWeight: 0, midContrast: nil, clipTrim: nil),
        ])
        let curves = try XCTUnwrap(fel.reshaping)
        XCTAssertEqual(curves[0], DolbyVisionReshapingCurve(
            pivots: [0, 128, 256, 384, 512, 640, 768, 896, 1023],
            pieces: Array(repeating: .polynomial([0, 1]), count: 8)))
        let scale = Double(1 << 23)
        XCTAssertEqual(curves[1], DolbyVisionReshapingCurve(pivots: [0, 1023], pieces: [.mmr(
            order: 3, constant: 448_998 / scale,
            coefficients: ([
                -1_262_056, 8_122_466, -1_703_266, 1_622_123, 808_554, -829_469, -13459,
                801_251, 694_657, 3_697_830, -1_819_391, -772_917, -654_425, 78034,
                -181_321, -324_811, -2_213_356, -716_030, 761_880, 365_184, 2_545_494,
            ] as [Double]).map { $0 / scale })]))

        let mel = try parseDolbyVisionRPU(Data(hex: profileSevenMEL))
        XCTAssertEqual(mel.profile, 1)
        XCTAssertFalse(mel.disableResidual)
        XCTAssertEqual([mel.minPQ, mel.maxPQ, mel.avgPQ], [0, 3100, 2048])
        XCTAssertEqual(mel.reshaping, Array(repeating: DolbyVisionReshapingCurve(
            pivots: [0, 1023], pieces: [.polynomial([0, 1])]), count: 3))
        // its v4.0 pass for Dolby's 100 nit display stands in for the three
        // v2.9 passes beside it
        XCTAssertEqual(mel.trims, [
            DolbyVisionTrim(
                targetMaxPQ: 2081, slope: 2036, offset: 2060, power: 1987, chromaWeight: 2048,
                saturationGain: 1985, msWeight: 2048, midContrast: 2048, clipTrim: 2011),
        ])
    }

    /// A remux muxes profile 7's two layers into one track: each enhancement
    /// layer NAL wrapped as unspecified type 63 beside the base layer's, the
    /// RPU last, as type 62. The walk passes over the wrapped layer to it.
    func testADualLayerAccessUnitHandsOverItsRPU() {
        let rpu = Data(hex: profileSevenFEL)
        let nals: [[UInt8]] = [[0x02, 0x01, 0xaf, 0x00, 0x03], [0x7e, 0x01, 0x02, 0x01, 0xd0, 0x00], [0x7c, 0x01] + rpu]
        var packet: [UInt8] = []
        for nal in nals {
            packet += withUnsafeBytes(of: UInt32(nal.count).bigEndian, Array.init) + nal
        }
        XCTAssertEqual(packet.withUnsafeBytes { dolbyVisionRPUPayload(in: $0, lengthSize: 4) }, rpu)
    }

    /// The rewrite profile 7 goes to the display as, byte for byte what
    /// dovi_tool's mode 2 writes for the same RPU, CRC included.
    func testAProfileSevenRPUIsRewrittenAsDoviToolWritesItsEightOne() throws {
        let converted = try dolbyVisionRPUAsEightOne(Data(hex: profileSevenFEL))
        XCTAssertEqual(converted, Data(hex: profileSevenFELAsEightOne))
        let mel = try parseDolbyVisionRPU(dolbyVisionRPUAsEightOne(Data(hex: profileSevenMEL)))
        XCTAssertTrue(mel.disableResidual)
        XCTAssertEqual([mel.minPQ, mel.maxPQ, mel.avgPQ], [0, 3100, 2048])
        XCTAssertEqual(mel.trims, try parseDolbyVisionRPU(Data(hex: profileSevenMEL)).trims)
    }

    /// The enhancement layer's NALs go, the base layer's stay in order, and
    /// the RPU is the 8.1 one where the original stood.
    func testADualLayerAccessUnitIsHandedOverAsEightOne() throws {
        let rpu = Data(hex: profileSevenFEL)
        let base: [UInt8] = [0x02, 0x01, 0xaf, 0x00, 0x05]
        let nals: [[UInt8]] = [base, [0x7e, 0x01, 0x02, 0x01, 0xd0, 0x00], [0x7c, 0x01] + rpu]
        var packet: [UInt8] = []
        for nal in nals {
            packet += withUnsafeBytes(of: UInt32(nal.count).bigEndian, Array.init) + nal
        }
        let block = try XCTUnwrap(packet.withUnsafeBytes { dolbyVisionAccessUnitAsEightOne($0, lengthSize: 4) })
        var out = [UInt8](repeating: 0, count: CMBlockBufferGetDataLength(block))
        XCTAssertEqual(CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: out.count, destination: &out), noErr)
        let eightOne = [UInt8]([0x7c, 0x01] + Data(hex: profileSevenFELAsEightOne))
        var expected: [UInt8] = []
        for nal in [base, eightOne] {
            expected += withUnsafeBytes(of: UInt32(nal.count).bigEndian, Array.init) + nal
        }
        XCTAssertEqual(out, expected)
    }
}

// dovi_tool's test assets: fel_orig.bin, a full enhancement layer's RPU,
// and mel_variable_l8_length13.bin, a minimal enhancement layer's.
private let profileSevenFEL = """
    1908090840613650ae20002008020080200802007f801ffc00ffc001fffa0000030100000300d0000008000006800000\
    400000340000030200000301a000001000000d0000030080000068000004000003034000002000000a86d9e67b2f863e\
    fc189e6029e98c06b8c566a7cd5f8dffcb6d8c39e38a9981b86ca6790f405f434cb7d80e9e04c349fd3bb77ec2cd5de3\
    a147d44c0a2e8062164a029b5d59500ed38f58c46c4ec13a14582cff3023536d57bbb6e411483b92966413698fce6bc3\
    1bd620fadd405bbef4643160b1f01bf2eefbf2a5e2f3ccb4abf3cc3983779e7568311b00480000400400400000401200\
    0010010010000010048000040040040000072566000035ea2566f9fceb1c256644ca0000030100000300080000030008\
    000003001c36224301860a5e308e051400000301a63e5affff000003000003000003000060200f80e1518030080059ca\
    1200c028218df82580080061400002022a512088050000030002281150120c07d000020d60015eb8f29d8280
    """

// fel_to_81.bin: dovi_tool's profile 8.1 conversion of fel_orig.bin.
private let profileSevenFELAsEightOne = """
    19080908406136506e20002008020080200802007f801ffc00fffd000003008000006800000400000303400000200000\
    1a0000030100000300d0000008000006800000400000340000030200000301a0000010000005436cf33d97c31f7e0c4f\
    3014f4c6035c62b353e6afc6ffe5b6c61cf1c54cc0dc36533c87a02fa1a65bec074f0261a4fe9ddbbf6166aef1d0a3ea\
    26051740310b25014daeaca80769c7ac623627609d0a2c167f9811a9b6abdddb7208a41dc94b3209b4c7e735e18deb10\
    7d6ea02ddf7a3218b058f80df9777df952f179e65a55f9e61cc1bbcf3ab4188de4acc00006bd44acdf3f9d6384acc899\
    40000020000003010000030001000003000386c4486030c14bc611c0a280000034c7cb5fffe000000300000300000300\
    0c0401f01c2a3030080059ca1200c028218df82580080061400002022a512088050000030002281150120c07d000020d\
    60015e6210c68d80
    """

private let profileSevenMEL = """
    1908090840613650af003ff801ffc00ffc001fffa000001000000d000003008000006800000400000300004000002000\
    0020000003000400000302000003020000030000400000200000200000392b300001af512b37cfe758e12b3226500000\
    080000030040000003004000000300e1b112180c3052f1847028a000000d31f2d7fff800000300000300000300030100\
    7c070a840030080060e40000c0282162d7ee5518007c140001805646ff9008fdb000ff28000300b01e05a00614600200\
    1000080891c32c20140000030000030000030048301f400008000003000140301c0040031900e08017f480c7c38007c1\
    8008007db41200ff800080aaa02e0580
    """

private extension Data {
    /// Bytes written as hex digits, two to a byte.
    init(hex: String) {
        let digits = Array(hex.utf8)
        self.init((0..<digits.count / 2).map {
            UInt8(String(decoding: digits[2 * $0...2 * $0 + 1], as: UTF8.self), radix: 16)!
        })
    }
}

/// Writes an RPU bit by bit, so the shapes this fixture cannot produce can
/// still be put through the parser.
private struct RPUWriter {
    private var bytes: [UInt8] = []
    private var pending: UInt8 = 0
    private var used = 0

    mutating func write(_ value: UInt32, _ count: Int) {
        for shift in stride(from: count - 1, through: 0, by: -1) {
            pending = pending << 1 | UInt8((value >> UInt32(shift)) & 1)
            used += 1
            if used == 8 {
                bytes.append(pending)
                pending = 0
                used = 0
            }
        }
    }

    mutating func flag(_ value: Bool) { write(value ? 1 : 0, 1) }

    mutating func unsignedGolomb(_ value: UInt32) {
        var zeros = 0
        while (UInt32(1) << (zeros + 1)) - 1 <= value { zeros += 1 }
        write(0, zeros)
        write(1, 1)
        if zeros > 0 { write(value - ((UInt32(1) << zeros) - 1), zeros) }
    }

    mutating func signedGolomb(_ value: Int32) {
        unsignedGolomb(value > 0 ? UInt32(2 * value - 1) : UInt32(-2 * value))
    }

    mutating func align() {
        while used != 0 { write(0, 1) }
    }

    /// The bytes as a NAL payload, with the 0x000003 escapes an encoder would
    /// insert, so the parser's unescape gives these bits back.
    var data: Data {
        var out: [UInt8] = []
        var zeros = 0
        for byte in bytes {
            if zeros >= 2, byte <= 3 {
                out.append(3)
                zeros = 0
            }
            zeros = byte == 0 ? zeros + 1 : 0
            out.append(byte)
        }
        return Data(out)
    }
}

/// The knobs the fixture cannot turn: an NLQ section, float coefficients,
/// compressed display management, an unreadable header.
private struct SyntheticRPU {
    var profile: UInt32 = 7
    var format: UInt32 = 0
    var sequenceInfo = true
    var coefficientDataType: UInt32 = 0
    var dmCompression: UInt32 = 0
    var extMappingIdc: UInt32 = 0
    var nlqMethod: UInt32 = 0
    /// Polynomial pieces flagged as linearly interpolated: order 1 with
    /// linear_interp_flag set.
    var linearInterpolation = false
    /// The dual layer shape: residual data present, so an NLQ section follows
    /// the reshaping curves.
    var residual = false
    /// An order 2 MMR piece per component instead of the polynomial.
    var mmr = false
    /// Two level 2 trim passes.
    var levelTwo = false
    /// Content mapping v4.0's blocks behind them: a level 8 pass for one of
    /// Dolby's own displays, one for a display a level 10 describes, and one
    /// long enough to hold its mid contrast and clip.
    var levelEight = false
}

private func makeRPU(_ shape: SyntheticRPU) -> Data {
    let blBitDepth = 10, elBitDepth = 10, coefLog2Denom = 23
    var writer = RPUWriter()
    writer.write(25, 8) // the NAL prefix byte the parser checks
    writer.write(2, 6) // rpu_type
    writer.write(shape.format, 11)
    writer.write(shape.profile, 4)
    writer.write(0, 4) // vdr_rpu_level
    writer.flag(shape.sequenceInfo)
    if shape.sequenceInfo {
        writer.flag(false) // chroma_resampling_explicit_filter_flag
        writer.write(shape.coefficientDataType, 2)
        if shape.coefficientDataType == 0 { writer.unsignedGolomb(UInt32(coefLog2Denom)) }
        writer.write(0, 2) // vdr_rpu_normalized_idc
        writer.flag(false) // bl_video_full_range_flag
        // an unsupported format word means the fields below are not really
        // there; they are written anyway, since a parser that refuses the word
        // never reads this far
        writer.unsignedGolomb(UInt32(blBitDepth - 8))
        // ext_mapping_idc shares this field, in its upper 8 bits
        writer.unsignedGolomb(shape.extMappingIdc << 8 | UInt32(elBitDepth - 8))
        writer.unsignedGolomb(4) // vdr_bit_depth_minus8
        writer.flag(false) // spatial_resampling_filter_flag
        writer.write(shape.dmCompression, 3)
        writer.flag(false) // el_spatial_resampling_filter_flag
        writer.flag(!shape.residual) // disable_residual_flag
    }
    writer.flag(true) // vdr_dm_metadata_present_flag
    writer.flag(false) // use_prev_vdr_rpu_flag
    writer.unsignedGolomb(0) // vdr_rpu_id
    writer.unsignedGolomb(0) // mapping_color_space
    writer.unsignedGolomb(0) // mapping_chroma_format_idc
    for _ in 0..<3 { // two pivots per component
        writer.unsignedGolomb(0)
        writer.write(0, blBitDepth)
        writer.write(1023, blBitDepth)
    }
    if shape.residual {
        writer.write(shape.nlqMethod, 3)
        writer.write(0, blBitDepth)
        writer.write(1023, blBitDepth)
    }
    writer.unsignedGolomb(0) // num_x_partitions_minus1
    writer.unsignedGolomb(0) // num_y_partitions_minus1
    for _ in 0..<3 { // one piece per component
        if shape.mmr {
            writer.unsignedGolomb(1) // mapping_idc
            writer.write(1, 2) // mmr_order_minus1: order 2
            writer.signedGolomb(-1) // the constant
            writer.write(1, coefLog2Denom)
            for coefficient in 0..<14 {
                writer.signedGolomb(Int32(coefficient % 3) - 1)
                writer.write(1, coefLog2Denom)
            }
            continue
        }
        writer.unsignedGolomb(0) // mapping_idc
        if shape.linearInterpolation {
            writer.unsignedGolomb(0) // poly_order_minus1
            writer.flag(true) // linear_interp_flag
            writer.signedGolomb(0)
            writer.write(1, coefLog2Denom)
        } else {
            writer.unsignedGolomb(1) // poly_order_minus1: order 2
            for coefficient in 0..<3 {
                writer.signedGolomb(Int32(coefficient))
                writer.write(1, coefLog2Denom)
            }
        }
    }
    if shape.residual {
        for _ in 0..<3 {
            writer.write(511, elBitDepth) // nlq_offset
            for _ in 0..<3 { // vdr_in_max, then the dead zone slope and threshold
                writer.unsignedGolomb(2)
                writer.write(3, coefLog2Denom)
            }
        }
    }
    writer.unsignedGolomb(0) // affected_dm_metadata_id
    writer.unsignedGolomb(0) // current_dm_metadata_id
    writer.unsignedGolomb(1) // scene_refresh_flag
    for i in 0..<9 { writer.write(UInt32(UInt16(bitPattern: Int16(1000 * (i + 1)))), 16) }
    for i in 0..<3 { writer.write(UInt32(1) << UInt32(20 + i), 32) }
    for i in 0..<9 { writer.write(UInt32(UInt16(bitPattern: Int16(-100 * (i + 1)))), 16) }
    writer.write(1, 16) // signal_eotf
    writer.write(2, 16)
    writer.write(3, 16)
    writer.write(4, 32)
    writer.write(10, 5) // signal_bit_depth
    writer.write(1, 2) // signal_colour_space
    writer.write(1, 2) // signal_chroma_format
    writer.write(1, 2) // signal_full_range_flag
    writer.write(62, 12) // source_min_pq
    writer.write(3079, 12) // source_max_pq
    writer.write(42, 10) // source_diagonal
    writer.unsignedGolomb(shape.levelTwo ? 4 : 2) // level 1, level 4, then the two level 2 passes
    writer.align()
    writer.unsignedGolomb(5)
    writer.write(1, 8)
    writer.write(7, 12) // min_pq
    writer.write(3000, 12) // max_pq
    writer.write(1200, 12) // avg_pq
    writer.write(0, 4) // out to the five bytes the block declares
    writer.unsignedGolomb(3)
    writer.write(4, 8)
    writer.write(0, 24)
    if shape.levelTwo {
        // 600 then 100 nits: the parser hands them back by their peak
        for (target, slope) in [(2851, 2100), (2081, 1800)] as [(UInt32, UInt32)] {
            writer.unsignedGolomb(11)
            writer.write(2, 8)
            writer.write(target, 12)
            for code in [slope, 2000, 1900, 2048, 1844] as [UInt32] { writer.write(code, 12) }
            writer.write(UInt32(8192 - 1), 13) // ms_weight -1, left to the display
            writer.write(0, 3)
        }
    }
    if shape.levelEight {
        writer.unsignedGolomb(4)
        writer.align()
        // index 27, Dolby's 600 nit display, without its mid contrast
        writer.unsignedGolomb(10)
        writer.write(8, 8)
        writer.write(27, 8)
        for code in [2060, 2050, 2040, 2048, 2030, 2048] as [UInt32] { writer.write(code, 12) }
        // index 1, the 100 nit display, with mid contrast and clip
        writer.unsignedGolomb(13)
        writer.write(8, 8)
        writer.write(1, 8)
        for code in [2170, 2039, 1910, 2048, 1942, 2048, 2048, 2365] as [UInt32] { writer.write(code, 12) }
        // index 200, which the level 10 after it puts at 300 nits
        writer.unsignedGolomb(10)
        writer.write(8, 8)
        writer.write(200, 8)
        for code in [2100, 2048, 2000, 2048, 2048, 2048] as [UInt32] { writer.write(code, 12) }
        writer.unsignedGolomb(5)
        writer.write(10, 8)
        writer.write(200, 8)
        writer.write(2557, 12) // target_max_pq
        writer.write(62, 12) // target_min_pq
        writer.write(0, 8) // target_primary_index
    }
    writer.align()
    if shape.levelTwo || shape.levelEight {
        writer.write(0x12345678, 32) // the CRC
        writer.write(0x80, 8) // the terminator
    }
    return writer.data
}

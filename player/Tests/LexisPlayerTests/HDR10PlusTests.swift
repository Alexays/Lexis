import CFFmpeg
import XCTest
@testable import LexisPlayer

/// An HDR10+ payload read as the scene's own peak and mean.
final class HDR10PlusTests: XCTestCase {
    /// A payload as a mastering tool writes it, serialized by ffmpeg: a
    /// 1000 nit maxSCL, its 99th percentile at 800 nits, a 40 nit average;
    /// with `curve`, a knee at a tenth and nine anchors drawn for 500 nits.
    func payload(average: Int32 = 400, header: Bool, curve: Bool = false) throws -> Data {
        var metadata = AVDynamicHDRPlus()
        metadata.itu_t_t35_country_code = 0xB5
        metadata.application_version = 1
        metadata.num_windows = 1
        metadata.targeted_system_display_maximum_luminance = AVRational(num: 400, den: 1)
        metadata.params.0.maxscl = (
            AVRational(num: 10000, den: 100000), AVRational(num: 9000, den: 100000),
            AVRational(num: 8000, den: 100000))
        metadata.params.0.average_maxrgb = AVRational(num: average, den: 100000)
        metadata.params.0.fraction_bright_pixels = AVRational(num: 0, den: 1000)
        let levels: [(UInt8, Int32)] = [
            (1, 5), (5, 20), (10, 50), (25, 100), (50, 300), (75, 700), (90, 1500), (95, 3000), (99, 8000),
        ]
        metadata.params.0.num_distribution_maxrgb_percentiles = UInt8(levels.count)
        withUnsafeMutableBytes(of: &metadata.params.0.distribution_maxrgb) { raw in
            let slots = raw.bindMemory(to: AVHDRPlusPercentile.self)
            for (i, level) in levels.enumerated() {
                slots[i] = AVHDRPlusPercentile(percentage: level.0, percentile: AVRational(num: level.1, den: 100000))
            }
        }
        if curve {
            metadata.targeted_system_display_maximum_luminance = AVRational(num: 500, den: 1)
            metadata.params.0.tone_mapping_flag = 1
            metadata.params.0.knee_point_x = AVRational(num: 410, den: 4095)
            metadata.params.0.knee_point_y = AVRational(num: 600, den: 4095)
            metadata.params.0.num_bezier_curve_anchors = 9
            withUnsafeMutableBytes(of: &metadata.params.0.bezier_curve_anchors) { raw in
                let slots = raw.bindMemory(to: AVRational.self)
                for (i, anchor) in [141, 293, 435, 574, 706, 833, 872, 906, 935].enumerated() {
                    slots[i] = AVRational(num: Int32(anchor), den: 1023)
                }
            }
        }
        var bytes: UnsafeMutablePointer<UInt8>?
        var size = 0
        XCTAssertGreaterThanOrEqual(av_dynamic_hdr_plus_to_t35(&metadata, &bytes, &size), 0)
        let written = try XCTUnwrap(bytes)
        defer { av_free(written) }
        let body = Data(bytes: written, count: size)
        return header ? Data([0xB5, 0x00, 0x3C, 0x00, 0x01, 0x04]) + body : body
    }

    /// The highest percentile at or past 99 is the peak, the average maxRGB
    /// the mean, both in PQ, with or without the T.35 header.
    func testThePayloadGivesTheScenesPeakAndMean() throws {
        for header in [false, true] {
            let scene = try XCTUnwrap(hdr10PlusScene(try payload(header: header)), "header \(header)")
            XCTAssertEqual(scene.peakPQ, pqInverseEOTF(0.08), accuracy: 0.001, "header \(header)")
            XCTAssertEqual(scene.averagePQ, pqInverseEOTF(0.004), accuracy: 0.001, "header \(header)")
        }
    }

    /// The scene's curve, as ST 2094-40 writes it: the display it was drawn
    /// for, the knee and the anchors, each at its field's own precision; the
    /// peak is then the brightest maxSCL, which the curve is drawn over.
    func testThePayloadsCurveIsRead() throws {
        let scene = try XCTUnwrap(hdr10PlusScene(try payload(header: true, curve: true)))
        let curve = try XCTUnwrap(scene.curve)
        XCTAssertEqual(curve.display, 0.05, accuracy: 1e-6)
        XCTAssertEqual(curve.knee.x, 410.0 / 4095, accuracy: 1e-6)
        XCTAssertEqual(curve.knee.y, 600.0 / 4095, accuracy: 1e-6)
        XCTAssertEqual(curve.anchorCount, 9)
        XCTAssertEqual(curve.anchors[0], 141.0 / 1023, accuracy: 1e-6)
        XCTAssertEqual(curve.anchors[8], 935.0 / 1023, accuracy: 1e-6)
        XCTAssertEqual(curve.anchors[9], 0)
        XCTAssertEqual(scene.peakPQ, pqInverseEOTF(0.1), accuracy: 0.001)
        XCTAssertNil(try XCTUnwrap(hdr10PlusScene(try payload(header: true))).curve)
    }

    /// A mean past the peak describes no scene, and bytes ffmpeg cannot
    /// read are none either: the frame falls back on its histogram.
    func testANonsensePayloadIsRefused() throws {
        XCTAssertNil(hdr10PlusScene(try payload(average: 9000, header: false)))
        XCTAssertNil(hdr10PlusScene(Data([0x01, 0x02, 0x03])))
    }
}

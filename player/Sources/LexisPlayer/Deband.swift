import CFFmpeg
import Foundation

/// The tone map's deband: four taps a quarter turn apart at a distance and
/// angle drawn per pixel, averaged where all four sit within a threshold of
/// the centre.
enum Deband {
    /// How starved a stream is, 1 to 2, which the upscaler mixes its
    /// filter banks by: an encode with bits to spare bands by a code, a
    /// starved one flattens its fields into steps of several. Read off its
    /// bits per pixel, H.264 and older counted at half for what HEVC, VP9
    /// and AV1 make of the same bits: 1 from 0.2 up, where a UHD remux sits
    /// at 0.3, 2 from 0.05 down, and between the two by the octave.
    static func strength(for stream: MediaStream, fileBitsPerSecond: Int64) -> Float {
        let bits = stream.bitsPerSecond > 0 ? stream.bitsPerSecond : fileBitsPerSecond
        guard bits > 0, stream.width > 0, stream.height > 0 else { return 1 }
        let efficient = [AV_CODEC_ID_HEVC, AV_CODEC_ID_VP9, AV_CODEC_ID_AV1].contains { $0.rawValue == stream.codecID }
        let perPixel = Double(bits) / (Double(stream.width) * Double(stream.height) * (stream.frameRate ?? 24))
            * (efficient ? 1 : 0.5)
        return Float(1 + min(max(log2(0.2 / perPixel) / 2, 0), 1))
    }

    /// The 256 directions a tap is drawn from, a table rather than a sin and
    /// a cos per pixel: a 256th of a turn moves a tap at the full reach by
    /// under half a pixel.
    private static let directions = (0..<256).map { step -> String in
        let angle = Double(step) / 256 * 2 * Double.pi
        return "float2(\(Float(cos(angle)))f, \(Float(sin(angle)))f)"
    }.joined(separator: ", ")

    /// Metal source for the tone map's library.
    static let shader = """
    constant float2 debandDirections[256] = { \(directions) };

    // lowbias32, a full avalanche integer hash: every pixel draws its own
    // deband taps.
    static inline uint hash(uint x) {
        x ^= x >> 16;
        x *= 0x7feb352du;
        x ^= x >> 15;
        x *= 0x846ca68bu;
        x ^= x >> 16;
        return x;
    }

    // Flattens the step between two codes on a flat field: four taps a
    // quarter turn apart, at a distance up to `reach` and an angle drawn
    // per pixel, are averaged where every one sits within the threshold of
    // the centre. Drawn per pixel, what the smoothing leaves is noise
    // rather than a pattern; an edge, texture or grain sits far above the
    // threshold and is left alone. Both channels are read, so the luma
    // plane and the chroma pair go through the same test.
    static inline float2 deband(texture2d<float, access::read> plane, int2 c, int2 limit,
                                float reach, float threshold) {
        float2 centre = plane.read(uint2(c)).rg;
        uint h = hash(uint(c.x) | (uint(c.y) << 16));
        float distance = float(h & 0xffffu) / 65536.0f * reach;
        int2 o = int2(round(distance * debandDirections[h >> 24]));
        int2 q = int2(-o.y, o.x);
        float2 a = plane.read(uint2(clamp(c + o, int2(0), limit))).rg;
        float2 b = plane.read(uint2(clamp(c - o, int2(0), limit))).rg;
        float2 d = plane.read(uint2(clamp(c + q, int2(0), limit))).rg;
        float2 e = plane.read(uint2(clamp(c - q, int2(0), limit))).rg;
        float2 deviation = max(max(abs(a - centre), abs(b - centre)),
                               max(abs(d - centre), abs(e - centre)));
        return max(deviation.x, deviation.y) < threshold ? (a + b + d + e) * 0.25f : centre;
    }
    """
}

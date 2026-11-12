import Foundation

public enum InterlacedFixtureError: Error, Equatable {
    /// No `ffmpeg` on PATH, or a platform that cannot spawn one - the same
    /// discipline `makeVP9Fixture` uses, for the same reason: the vendored
    /// FFmpeg is built with every encoder and muxer disabled.
    case ffmpegUnavailable
    case ffmpegFailed(Int32)
}

/// MPEG-2, what a DVD carries and the software decoder takes; H.264, what a
/// 1080i broadcast carries and VideoToolbox decodes.
public enum InterlacedFixtureCodec {
    case mpeg2
    case h264
}

#if os(macOS)

/// A real interlaced MPEG-2 clip: every field is solid white or solid black,
/// each frame's two fields one of each, which is the worst comb a picture can
/// carry and the one a deinterlacer can be held to exactly. The fields go
/// white, black, black, white, and again, so each field's own rows change
/// from one frame to the next, as moving pictures do: a motion adaptive
/// deinterlacer weaves a field that holds still. Built up correctly, each
/// field becomes one uniformly white or black picture; any row of either
/// that is neither is the comb surviving.
///
/// Flat fields survive MPEG-2 intact - a solid block is its DC coefficient -
/// so the test can assert on the values themselves rather than a tolerance.
/// H.264 keeps them within a code or two.
///
/// `aspect`, as ffmpeg's `-aspect` takes it ("16:9"), is the picture's shape
/// on screen, which its pixels then carry: a widescreen DVD's.
public func makeInterlacedFixture(
    directory: URL, name: String, width: Int, height: Int, frameCount: Int, fps: Int,
    codec: InterlacedFixtureCodec = .mpeg2, aspect: String? = nil
) throws -> URL {
    guard commandSucceeds(["ffmpeg", "-version"]) else {
        throw InterlacedFixtureError.ffmpegUnavailable
    }
    let url = fixtureURL(in: directory, named: name)
    try? FileManager.default.removeItem(at: url)
    // The commas are escaped for the filtergraph parser, which splits filters
    // on them, and not for any shell: these arguments never see one.
    let alternate = "geq=lum='if(lt(mod(N+1\\,4)\\,2)\\,235\\,16)':cb=128:cr=128"
    let status = run([
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
        // Twice the output rate in, since `interlace` takes two source frames
        // for each interlaced one: source frame 2k becomes the top field and
        // 2k+1 the bottom.
        "-f", "lavfi", "-i", "nullsrc=s=\(width)x\(height):r=\(fps * 2)",
        "-vf", "\(alternate),interlace=scan=tff",
        "-frames:v", "\(frameCount)",
        "-c:v", codec == .mpeg2 ? "mpeg2video" : "libx264", "-flags", "+ilme+ildct", "-top", "1",
        "-pix_fmt", "yuv420p", "-g", "\(frameCount)", "-b:v", "6M",
    ] + (aspect.map { ["-aspect", $0] } ?? []) + [
        url.path,
    ])
    guard status == 0, FileManager.default.fileExists(atPath: url.path) else {
        throw InterlacedFixtureError.ffmpegFailed(status)
    }
    return url
}

/// Film telecined the NTSC way: a moving test pattern at 23.976 frames a
/// second through 3:2 pulldown into 29.97 interlaced frames, each film frame
/// two fields then three, top field first. Hands back the clip and the
/// progressive frames it was made from, eight bit 4:2:0 back to back.
public func makeTelecineFixture(
    directory: URL, name: String, width: Int, height: Int, frameCount: Int, codec: InterlacedFixtureCodec = .mpeg2
) throws -> (url: URL, frames: URL) {
    guard commandSucceeds(["ffmpeg", "-version"]) else {
        throw InterlacedFixtureError.ffmpegUnavailable
    }
    let url = fixtureURL(in: directory, named: name)
    let frames = url.appendingPathExtension("yuv")
    try? FileManager.default.removeItem(at: url)
    try? FileManager.default.removeItem(at: frames)
    let made = run([
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
        "-f", "lavfi", "-i", "testsrc2=s=\(width)x\(height):r=24000/1001", "-frames:v", "\(frameCount)",
        "-pix_fmt", "yuv420p", "-f", "rawvideo", frames.path,
    ])
    let status = made == 0 ? run([
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
        "-f", "rawvideo", "-pix_fmt", "yuv420p", "-s", "\(width)x\(height)", "-r", "24000/1001", "-i", frames.path,
        "-vf", "telecine=first_field=top:pattern=23", "-flags", "+ilme+ildct", "-top", "1", "-pix_fmt", "yuv420p",
    ] + (codec == .mpeg2 ? ["-c:v", "mpeg2video", "-q:v", "2"] : ["-c:v", "libx264", "-crf", "12"]) + [url.path]) : made
    guard status == 0, FileManager.default.fileExists(atPath: url.path) else {
        throw InterlacedFixtureError.ffmpegFailed(status)
    }
    return (url, frames)
}

private func commandSucceeds(_ arguments: [String]) -> Bool {
    run(arguments) == 0
}

private func run(_ arguments: [String]) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        return -1
    }
    process.waitUntilExit()
    return process.terminationStatus
}

#else

/// tvOS builds this module too and has no `Process`; nothing there ever calls
/// a test-only fixture, so it only has to compile and refuse honestly.
public func makeTelecineFixture(
    directory: URL, name: String, width: Int, height: Int, frameCount: Int, codec: InterlacedFixtureCodec = .mpeg2
) throws -> (url: URL, frames: URL) {
    throw InterlacedFixtureError.ffmpegUnavailable
}

public func makeInterlacedFixture(
    directory: URL, name: String, width: Int, height: Int, frameCount: Int, fps: Int,
    codec: InterlacedFixtureCodec = .mpeg2, aspect: String? = nil
) throws -> URL {
    throw InterlacedFixtureError.ffmpegUnavailable
}

#endif

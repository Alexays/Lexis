import Foundation

public enum AV1FixtureError: Error, Equatable {
    /// No `ffmpeg` with libaom on PATH, or a platform that cannot spawn one -
    /// the same discipline `makeVP9Fixture` uses, for the same reason: the
    /// vendored FFmpeg is built with every encoder and muxer disabled.
    case ffmpegUnavailable
    case ffmpegFailed(Int32)
}

#if os(macOS)

/// A short AV1-in-Matroska clip of one flat mid grey, encoded by the
/// system's own ffmpeg. Flat grey survives AV1 nearly intact - a solid
/// block is its DC coefficient - so a decode test can assert on the sample
/// values themselves within a small tolerance.
///
/// `tenBit` encodes yuv420p10le and tags the stream BT.2020 PQ, which is
/// the shape real ten bit AV1 film content arrives in.
public func makeAV1Fixture(
    directory: URL, name: String, width: Int, height: Int, frameCount: Int, fps: Int,
    tenBit: Bool = false
) throws -> URL {
    guard commandSucceeds(["ffmpeg", "-version"]) else {
        throw AV1FixtureError.ffmpegUnavailable
    }
    let url = fixtureURL(in: directory, named: name)
    try? FileManager.default.removeItem(at: url)
    let duration = Double(frameCount) / Double(fps)
    // Whichever AV1 encoder this machine's ffmpeg carries: Homebrew's ships
    // SVT-AV1, others libaom. Both at their fastest effort - the bitstream
    // only has to be real AV1, not a good encode. The CICP triple rides in
    // svtav1-params because the wrapper does not forward the generic colour
    // flags into the sequence header, measured.
    let encoders: [[String]] = [
        ["-c:v", "libsvtav1", "-preset", "12"]
            + (tenBit
                ? [
                    "-svtav1-params",
                    "color-primaries=9:transfer-characteristics=16:matrix-coefficients=9",
                ]
                : []),
        ["-c:v", "libaom-av1", "-usage", "realtime", "-cpu-used", "8"]
            + (tenBit
                ? ["-color_primaries", "bt2020", "-color_trc", "smpte2084", "-colorspace", "bt2020nc"]
                : []),
    ]
    var status: Int32 = -1
    for encoder in encoders {
        var arguments = [
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi",
            "-i", "color=c=0x808080:size=\(width)x\(height):rate=\(fps):duration=\(duration)",
            "-frames:v", "\(frameCount)",
        ]
        arguments += encoder
        arguments += ["-g", "\(frameCount)", "-b:v", "500k"]
        arguments += ["-pix_fmt", tenBit ? "yuv420p10le" : "yuv420p"]
        arguments.append(url.path)
        status = run(arguments)
        if status == 0, FileManager.default.fileExists(atPath: url.path) { return url }
    }
    throw AV1FixtureError.ffmpegFailed(status)
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

/// tvOS builds this module too, but `Process` does not exist there: nothing
/// on that platform ever calls this, since it is a test-only fixture, so it
/// only has to compile and refuse honestly if it ever were.
public func makeAV1Fixture(
    directory: URL, name: String, width: Int, height: Int, frameCount: Int, fps: Int,
    tenBit: Bool = false
) throws -> URL {
    throw AV1FixtureError.ffmpegUnavailable
}

#endif

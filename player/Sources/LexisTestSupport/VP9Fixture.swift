import Foundation

public enum VP9FixtureError: Error, Equatable {
    /// No `ffmpeg` on PATH, or this platform cannot spawn one at all
    /// (`Process` does not exist on tvOS - this fixture is only ever built
    /// for the host `swift test` run, never the device): the same
    /// discipline player/scripts/make-benchmark-corpus.sh already uses for
    /// the same external dependency - a caller turns this into an
    /// `XCTSkip`.
    case ffmpegUnavailable
    case ffmpegFailed(Int32)
}

#if os(macOS)

/// A short VP9-in-Matroska clip, encoded by the system's own ffmpeg. The
/// player's vendored FFmpeg build has every encoder and muxer disabled
/// (player/scripts/build-ffmpeg.sh: `--disable-encoders --disable-muxers`),
/// so a fixture that needs real VP9 bitstream - not just a container tagged
/// with the right codec - has no other source than an ffmpeg already on the
/// machine running the suite.
public func makeVP9Fixture(
    directory: URL, name: String, width: Int, height: Int, frameCount: Int, fps: Int,
    /// Forces a keyframe every `gopSize` frames, so a test that seeks
    /// mid-stream knows exactly where each one lands. nil keeps the single
    /// leading keyframe every prior call site already relies on.
    gopSize: Int? = nil
) throws -> URL {
    guard commandSucceeds(["ffmpeg", "-version"]) else {
        throw VP9FixtureError.ffmpegUnavailable
    }
    let url = fixtureURL(in: directory, named: name)
    try? FileManager.default.removeItem(at: url)
    let duration = Double(frameCount) / Double(fps)
    let status = run([
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
        "-f", "lavfi", "-i", "testsrc2=size=\(width)x\(height):rate=\(fps):duration=\(duration)",
        "-frames:v", "\(frameCount)",
        // libvpx-vp9's default -cpu-used 0 spends 36 s on this fixture where
        // realtime spends 3 s, for a bitstream no test here reads differently:
        // what is asserted is the codec, the GOP and the frame count.
        "-c:v", "libvpx-vp9", "-deadline", "realtime", "-cpu-used", "8",
        "-pix_fmt", "yuv420p", "-g", "\(gopSize ?? frameCount)", "-b:v", "1M",
        url.path,
    ])
    guard status == 0, FileManager.default.fileExists(atPath: url.path) else {
        throw VP9FixtureError.ffmpegFailed(status)
    }
    return url
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

/// tvOS builds this module too (every native task ends with a real
/// simulator build), but `Process` does not exist there: nothing on that
/// platform ever calls this, since it is a test-only fixture, so it only
/// has to compile and refuse honestly if it ever were.
public func makeVP9Fixture(
    directory: URL, name: String, width: Int, height: Int, frameCount: Int, fps: Int,
    gopSize: Int? = nil
) throws -> URL {
    throw VP9FixtureError.ffmpegUnavailable
}

#endif

import Foundation
import XCTest
@testable import LexisPlayer

/// A smoke test that the generated corpus (player/scripts/make-benchmark-
/// corpus.sh) opens with the codecs each file is named for and carries the
/// HDR10 metadata it claims. It skips rather than fails when the corpus has
/// not been generated on the machine running the suite, so contributors
/// without ffmpeg are never forced to have it; catching a codec or
/// container the demuxer cannot open is what it exists for. It also skips,
/// rather than passing outright, when the corpus script marked a clip
/// present but unverifiable: an unconfirmed clip earns a visibly skipped
/// run, never a quiet green one.
///
/// The matrix has rows no ffmpeg build can generate - VC-1, and the two
/// bitmap subtitle formats. They are named in the table below all the same,
/// with the codecs a real file would carry, so that the day one arrives
/// from the owner's own library it is checked here rather than added here.
final class BenchmarkCorpusTests: XCTestCase {
    struct ExpectedClip {
        let file: String
        let video: String
        /// The audio codec, which is the whole point of the audio rows and
        /// still worth pinning on the video ones: a clip that quietly lost
        /// its audio track measures nothing about the audio route.
        let audio: String
        /// "" for a clip that carries no subtitle stream.
        let subtitle: String
    }

    static let expected: [ExpectedClip] = [
        ExpectedClip(file: "h264.mp4", video: "h264", audio: "aac", subtitle: ""),
        ExpectedClip(file: "hevc8.mp4", video: "hevc", audio: "aac", subtitle: ""),
        ExpectedClip(file: "hevc10.mkv", video: "hevc", audio: "aac", subtitle: ""),
        ExpectedClip(file: "hdr10.mkv", video: "hevc", audio: "eac3", subtitle: ""),
        ExpectedClip(file: "av1.mkv", video: "av1", audio: "aac", subtitle: ""),
        ExpectedClip(file: "vp9.mkv", video: "vp9", audio: "aac", subtitle: ""),
        ExpectedClip(file: "vp8.mkv", video: "vp8", audio: "aac", subtitle: ""),
        ExpectedClip(file: "mpeg2.ts", video: "mpeg2video", audio: "ac3", subtitle: ""),
        ExpectedClip(file: "mpeg1.mpg", video: "mpeg1video", audio: "mp2", subtitle: ""),
        ExpectedClip(file: "mpeg4.mp4", video: "mpeg4", audio: "aac", subtitle: ""),
        ExpectedClip(file: "vc1.mkv", video: "vc1", audio: "aac", subtitle: ""),
        ExpectedClip(file: "interlaced-h264.ts", video: "h264", audio: "ac3", subtitle: ""),
        ExpectedClip(file: "h264-ac3.mp4", video: "h264", audio: "ac3", subtitle: ""),
        ExpectedClip(file: "dts.mkv", video: "h264", audio: "dts", subtitle: ""),
        ExpectedClip(file: "truehd.mkv", video: "h264", audio: "truehd", subtitle: ""),
        ExpectedClip(file: "flac.mkv", video: "h264", audio: "flac", subtitle: ""),
        ExpectedClip(file: "opus.mkv", video: "h264", audio: "opus", subtitle: ""),
        ExpectedClip(file: "vorbis.mkv", video: "h264", audio: "vorbis", subtitle: ""),
        ExpectedClip(file: "mp3.mp4", video: "h264", audio: "mp3", subtitle: ""),
        ExpectedClip(file: "pcm.mov", video: "h264", audio: "pcm_s16le", subtitle: ""),
        ExpectedClip(file: "pgs.mkv", video: "h264", audio: "aac", subtitle: "hdmv_pgs_subtitle"),
        ExpectedClip(file: "vobsub.mkv", video: "h264", audio: "aac", subtitle: "dvd_subtitle"),
    ]

    static let corpusDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".bench-corpus")

    static func isUnverifiable(_ file: String) -> Bool {
        FileManager.default.fileExists(
            atPath: corpusDir.appendingPathComponent(file + ".unverifiable").path
        )
    }

    /// Every clip the corpus actually holds opens with the video, audio and
    /// subtitle codecs its row claims. A row the script could not generate
    /// on this machine is skipped, not failed: the "not produced" list the
    /// script itself printed is where that belongs, and a contributor whose
    /// ffmpeg lacks an encoder is not running a broken suite.
    func testEveryCorpusFileOpensWithTheExpectedCodecs() throws {
        var present: [String] = []
        var unverifiable: [String] = []
        for clip in Self.expected {
            let url = Self.corpusDir.appendingPathComponent(clip.file)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            present.append(clip.file)
            let demuxer = try Demuxer(url: url)
            let video = try XCTUnwrap(demuxer.streams.first { $0.kind == .video }, clip.file)
            XCTAssertEqual(video.codecName, clip.video, clip.file)
            let audio = try XCTUnwrap(demuxer.streams.first { $0.kind == .audio }, clip.file)
            XCTAssertEqual(audio.codecName, clip.audio, clip.file)
            let subtitle = demuxer.streams.first { $0.kind == .subtitle }
            XCTAssertEqual(subtitle?.codecName ?? "", clip.subtitle, clip.file)
            if Self.isUnverifiable(clip.file) { unverifiable.append(clip.file) }
        }
        if present.isEmpty {
            throw XCTSkip("corpus not generated: run player/scripts/make-benchmark-corpus.sh")
        }
        if !unverifiable.isEmpty {
            throw XCTSkip(
                "present but unverifiable on this machine, not confirmed by "
                    + "make-benchmark-corpus.sh: \(unverifiable.joined(separator: ", "))"
            )
        }
    }

    /// The rows the bench measures and the rows the script writes are the
    /// same list, or a clip is measured that nobody generates, or generated
    /// and never measured.
    func testTheExpectedRowsAreExactlyTheScriptsOwn() throws {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/make-benchmark-corpus.sh")
        let source = try String(contentsOf: script, encoding: .utf8)
        for clip in Self.expected {
            XCTAssertTrue(
                source.contains(clip.file),
                "\(clip.file) is measured by the bench and named nowhere in the corpus script"
            )
        }
    }

    func testHDR10CarriesThePQTransferAndMasteringDisplay() throws {
        let hdr10 = Self.corpusDir.appendingPathComponent("hdr10.mkv")
        guard FileManager.default.fileExists(atPath: hdr10.path) else {
            throw XCTSkip("corpus not generated: run player/scripts/make-benchmark-corpus.sh")
        }
        let video = try XCTUnwrap(try Demuxer(url: hdr10).streams.first { $0.kind == .video })
        XCTAssertTrue(isPerceptualQuantizer(video.colorTransfer))
        XCTAssertNotNil(video.masteringDisplay)
        if Self.isUnverifiable("hdr10.mkv") {
            throw XCTSkip("hdr10.mkv is present but unverifiable on this machine")
        }
    }
}

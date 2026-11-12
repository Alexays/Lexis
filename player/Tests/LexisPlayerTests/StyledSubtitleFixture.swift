import AVFoundation
import Foundation
import LexisTestSupport
@testable import LexisPlayer

enum StyledFixtureError: Error {
    case noSourceTrack
    case noFontOnThisSystem
}

/// A TrueType file this machine already has. No font is committed: the fixture
/// borrows one at test time, which is enough to prove that a font travelling
/// inside a container reaches libass.
func systemFontData() throws -> Data {
    let candidates = [
        "/System/Library/Fonts/Supplemental/Arial.ttf",
        "/System/Library/Fonts/Supplemental/Courier New.ttf",
        "/System/Library/Fonts/SFNS.ttf",
    ]
    for path in candidates where FileManager.default.fileExists(atPath: path) {
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }
    throw StyledFixtureError.noFontOnThisSystem
}

/// An .mkv every libass test shares. Four seconds of 320x240 H.264 and:
///
/// - stream 1, ASS, `fre`, "Styles": three events against `assStyledFixtureHeader`
///   - 1.0 to 3.0 s, Default, italic in the middle of the line
///   - 1.5 to 3.0 s, Sign, `{\pos(300,200)}` in an explicit green
///   - 3.2 to 4.0 s, Default, two lines broken with \N
/// - stream 2, an attachment: a TrueType font, so the font path has something
///   to load that CoreText did not provide
///
/// The video comes out of an mp4 an AVAssetWriter authored, as everywhere else:
/// nothing is encoded twice.
func makeStyledSubtitleFixture(directory: URL, name: String) throws -> URL {
    let source = try makeVideoFixture(
        directory: directory, name: "\(name).source.mp4", codec: .h264,
        width: 320, height: 240, frameCount: 96, fps: 24, audio: false
    )
    let demuxer = try Demuxer(url: source)
    guard let video = demuxer.streams.first(where: { $0.kind == .video }) else {
        throw StyledFixtureError.noSourceTrack
    }
    let timeBase = Double(video.timeBaseNum) / Double(video.timeBaseDen)
    var frames: [MatroskaFrame] = []
    while let packet = try demuxer.readPacket() {
        guard packet.streamIndex == video.index else { continue }
        let pts = packet.pts ?? packet.dts ?? 0
        let dts = packet.dts ?? packet.pts ?? 0
        frames.append(MatroskaFrame(
            track: 1, milliseconds: Int((Double(pts) * timeBase * 1000).rounded()),
            decodeMilliseconds: Int((Double(dts) * timeBase * 1000).rounded()),
            isKeyframe: packet.isKeyframe, data: packet.copiedBytes
        ))
    }

    // Field 0 is ReadOrder, which is what libass dedupes on when a seek makes
    // the reader hand it the same event twice.
    frames.append(MatroskaFrame(
        track: 2, milliseconds: 1000, durationMilliseconds: 2000, isKeyframe: true,
        data: Data(#"0,0,Default,,0,0,0,,{\i1}Bonjour{\i0} la nuit"#.utf8)
    ))
    frames.append(MatroskaFrame(
        track: 2, milliseconds: 1500, durationMilliseconds: 1500, isKeyframe: true,
        data: Data(#"1,0,Sign,,0,0,0,,{\pos(300,200)\c&H00FF00&}Panneau"#.utf8)
    ))
    frames.append(MatroskaFrame(
        track: 2, milliseconds: 3200, durationMilliseconds: 800, isKeyframe: true,
        data: Data(#"2,0,Default,,0,0,0,,Deuxieme ligne\Nsur deux"#.utf8)
    ))

    return try makeMatroskaFixture(
        directory: directory,
        name: name,
        tracks: [
            MatroskaTrack(
                number: 1, kind: .video, codecID: "V_MPEG4/ISO/AVC",
                codecPrivate: video.extradata, width: 320, height: 240
            ),
            MatroskaTrack(
                number: 2, kind: .subtitle, codecID: "S_TEXT/ASS",
                codecPrivate: Data(assStyledFixtureHeader.utf8),
                language: "fre", name: "Styles"
            ),
        ],
        frames: frames,
        durationMilliseconds: Int(demuxer.duration * 1000),
        cueTrack: 1,
        attachments: [
            MatroskaAttachment(
                fileName: "Embedded.ttf",
                // application/x-truetype-font is the spelling FFmpeg's table
                // knows; font/ttf reads back as codec id 0, which is why
                // nothing in this player selects an attachment by mime type
                mimeType: "application/x-truetype-font",
                data: try systemFontData()
            )
        ]
    )
}

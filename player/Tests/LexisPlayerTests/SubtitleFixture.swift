import AVFoundation
import Foundation
import LexisTestSupport
@testable import LexisPlayer

enum SubtitleFixtureError: Error {
    case noSourceTrack
}

/// A packet timestamp in whole milliseconds, which is what the fixture's one
/// millisecond timestamp scale stores.
private func stamp(_ ticks: Int64, _ stream: MediaStream) -> Int {
    let seconds = Double(ticks) * Double(stream.timeBaseNum) / Double(stream.timeBaseDen)
    return Int((seconds * 1000).rounded())
}

/// An .mkv every subtitle and track test shares. Four seconds of 320x240 H.264
/// and, on top of it:
///
/// - stream 1, audio, `fre`, "VF", default, a 440 Hz sine
/// - stream 2, audio, `eng`, "VO", a 880 Hz sine, so the two decode differently
/// - stream 3, ASS, `fre`, "Forces", forced: 1.0 to 3.0 s, and 3.2 to 4.0 s on
///   two lines
/// - stream 4, SubRip, `eng`, "SDH": 1.5 to 2.5 s
/// - stream 5, PGS, `eng`, "Bitmap": 2.0 to 3.5 s, 96x32 at 100,900
///
/// The video and the sound are lifted out of mp4s an AVAssetWriter authored:
/// the packets are already in the length-prefixed form V_MPEG4/ISO/AVC wants,
/// and nothing is encoded twice.
///
/// `undecodableAudio` appends stream 6, an audio track whose codec ID no
/// decoder answers to, which is how a failed track switch is tested.
func makeSubtitleFixture(
    directory: URL, name: String, undecodableAudio: Bool = false,
    chapters: [MatroskaChapter] = []
) throws -> URL {
    var frames: [MatroskaFrame] = []
    var videoExtradata: Data?
    var audioExtradata: [Int: Data] = [:]
    var durationMilliseconds = 0
    for (track, frequency) in [(2, 440.0), (3, 880.0)] {
        let source = try makeVideoFixture(
            directory: directory, name: "\(name).source-\(track).mp4", codec: .h264,
            width: 320, height: 240, frameCount: 96, fps: 24, audio: true,
            audioFrequency: frequency
        )
        let demuxer = try Demuxer(url: source)
        guard let video = demuxer.streams.first(where: { $0.kind == .video }),
              let audio = demuxer.streams.first(where: { $0.kind == .audio })
        else { throw SubtitleFixtureError.noSourceTrack }
        audioExtradata[track] = audio.extradata
        // The two passes are independent encodes and their SPS/PPS can differ,
        // so everything describing the picture has to come from the same pass
        // the picture itself does, or the file stores one encode's slices under
        // another's header and a handful of them decode to something else.
        if track == 2 {
            videoExtradata = video.extradata
            durationMilliseconds = Int(demuxer.duration * 1000)
        }
        while let packet = try demuxer.readPacket() {
            if packet.streamIndex == audio.index {
                // The AAC priming samples are stamped before zero. Keeping them
                // would start the container at -44 ms, and every cue time is
                // read against that start.
                let milliseconds = stamp(packet.pts ?? packet.dts ?? 0, audio)
                guard milliseconds >= 0 else { continue }
                frames.append(MatroskaFrame(
                    track: track, milliseconds: milliseconds, isKeyframe: true,
                    data: packet.copiedBytes
                ))
            } else if packet.streamIndex == video.index, track == 2 {
                // the picture comes from the first source only
                frames.append(MatroskaFrame(
                    track: 1, milliseconds: stamp(packet.pts ?? packet.dts ?? 0, video),
                    decodeMilliseconds: stamp(packet.dts ?? packet.pts ?? 0, video),
                    isKeyframe: packet.isKeyframe, data: packet.copiedBytes
                ))
            }
        }
    }

    // An .mkv ASS line is ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,
    // Effect,Text, and the block is what times it.
    frames.append(MatroskaFrame(
        track: 4, milliseconds: 1000, durationMilliseconds: 2000, isKeyframe: true,
        data: Data(#"0,0,Default,,0,0,0,,{\i1}Bonjour{\i0} la nuit"#.utf8)
    ))
    frames.append(MatroskaFrame(
        track: 4, milliseconds: 3200, durationMilliseconds: 800, isKeyframe: true,
        data: Data(#"1,0,Default,,0,0,0,,Deuxieme ligne\Nsur deux"#.utf8)
    ))
    frames.append(MatroskaFrame(
        track: 5, milliseconds: 1500, durationMilliseconds: 1000, isKeyframe: true,
        data: Data("Hello <i>there</i>".utf8)
    ))
    frames.append(MatroskaFrame(
        track: 6, milliseconds: 2000, durationMilliseconds: 1500, isKeyframe: true,
        data: makePGSDisplaySet(x: 100, y: 900, width: 96, height: 32, colorIndex: 1)
    ))

    var tracks = [
        MatroskaTrack(
            number: 1, kind: .video, codecID: "V_MPEG4/ISO/AVC",
            codecPrivate: videoExtradata, width: 320, height: 240, language: "und"
        ),
        MatroskaTrack(
            number: 2, kind: .audio, codecID: "A_AAC", codecPrivate: audioExtradata[2],
            sampleRate: 48000, channels: 2, language: "fre", name: "VF"
        ),
        MatroskaTrack(
            number: 3, kind: .audio, codecID: "A_AAC", codecPrivate: audioExtradata[3],
            sampleRate: 48000, channels: 2, language: "eng", name: "VO", isDefault: false
        ),
        MatroskaTrack(
            number: 4, kind: .subtitle, codecID: "S_TEXT/ASS",
            codecPrivate: Data(assFixtureHeader.utf8), language: "fre", name: "Forces",
            isForced: true
        ),
        MatroskaTrack(
            number: 5, kind: .subtitle, codecID: "S_TEXT/UTF8",
            language: "eng", name: "SDH", isDefault: false
        ),
        MatroskaTrack(
            number: 6, kind: .subtitle, codecID: "S_HDMV/PGS",
            language: "eng", name: "Bitmap", isDefault: false
        ),
    ]
    if undecodableAudio {
        tracks.append(MatroskaTrack(
            number: 7, kind: .audio, codecID: "A_LEXIS/NOSUCHCODEC",
            sampleRate: 48000, channels: 2, language: "ita", name: "Muet",
            isDefault: false
        ))
        // one block, so the track carries data like any other
        frames.append(MatroskaFrame(
            track: 7, milliseconds: 0, isKeyframe: true, data: Data(repeating: 0, count: 16)
        ))
    }
    return try makeMatroskaFixture(
        directory: directory, name: name, tracks: tracks, frames: frames,
        durationMilliseconds: durationMilliseconds, cueTrack: 1, chapters: chapters
    )
}

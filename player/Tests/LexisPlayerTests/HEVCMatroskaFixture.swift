import Foundation
import LexisTestSupport
@testable import LexisPlayer

enum HEVCMatroskaFixtureError: Error {
    case noVideo
    case unexpectedLengthSize
}

/// A real HEVC encode rewrapped in an .mkv, for the headers no encoder on
/// this machine writes: `header` rewrites its hvcC, and `keyframe` each
/// keyframe, handed the VPS, SPS and PPS as four byte length prefixed NAL
/// units. Returns the mp4 the encode came from beside the .mkv.
func makeHEVCMatroskaFixture(
    directory: URL, name: String,
    header: (Data) -> Data,
    keyframe: (_ sets: Data, _ packet: Data) -> Data
) throws -> (source: URL, url: URL) {
    let source = try makeVideoFixture(
        directory: directory, name: "\(name).source.mp4", codec: .hevc,
        width: 320, height: 240, frameCount: 24, fps: 24, gopSize: 12
    )
    let demuxer = try Demuxer(url: source)
    guard let video = demuxer.streams.first(where: { $0.kind == .video }), let record = video.extradata
    else { throw HEVCMatroskaFixtureError.noVideo }
    guard record[21] & 0x03 == 3 else { throw HEVCMatroskaFixtureError.unexpectedLengthSize }
    var sets = Data()
    var offset = 23
    for _ in 0..<Int(record[22]) {
        let count = Int(record[offset + 1]) << 8 | Int(record[offset + 2])
        offset += 3
        for _ in 0..<count {
            let length = Int(record[offset]) << 8 | Int(record[offset + 1])
            sets.append(contentsOf: [0, 0, UInt8(length >> 8), UInt8(length & 0xFF)])
            sets.append(record[(offset + 2)..<(offset + 2 + length)])
            offset += 2 + length
        }
    }
    func stamp(_ ticks: Int64) -> Int {
        Int((Double(ticks) * 1000 * Double(video.timeBaseNum) / Double(video.timeBaseDen)).rounded())
    }
    var frames: [MatroskaFrame] = []
    while let packet = try demuxer.readPacket() {
        guard packet.streamIndex == video.index else { continue }
        frames.append(MatroskaFrame(
            track: 1, milliseconds: stamp(packet.pts ?? packet.dts ?? 0),
            decodeMilliseconds: stamp(packet.dts ?? packet.pts ?? 0),
            isKeyframe: packet.isKeyframe,
            data: packet.isKeyframe ? keyframe(sets, packet.copiedBytes) : packet.copiedBytes
        ))
    }
    let url = try makeMatroskaFixture(
        directory: directory, name: name,
        tracks: [MatroskaTrack(
            number: 1, kind: .video, codecID: "V_MPEGH/ISO/HEVC", codecPrivate: header(record),
            width: 320, height: 240
        )],
        frames: frames, durationMilliseconds: 1000, cueTrack: 1
    )
    return (source, url)
}

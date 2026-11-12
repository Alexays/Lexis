import Foundation

// A minimal Matroska writer. The FFmpeg build has every muxer disabled, so a
// test that needs an .mkv has to author the bytes itself.

public enum MatroskaFixtureError: Error, Equatable {
    case blockTooFarFromCluster
}

/// One frame of one track, at a whole millisecond. A duration turns the block
/// into a group, which is the only way a subtitle says how long it stays up.
public struct MatroskaFrame {
    public let track: Int
    public let milliseconds: Int
    /// When the frame decodes, which is the order the blocks are stored in.
    /// It differs from `milliseconds` only on a stream with frame reordering.
    public let decodeMilliseconds: Int
    public let durationMilliseconds: Int?
    public let isKeyframe: Bool
    public let data: Data

    public init(
        track: Int, milliseconds: Int, decodeMilliseconds: Int? = nil,
        durationMilliseconds: Int? = nil, isKeyframe: Bool, data: Data
    ) {
        self.track = track
        self.milliseconds = milliseconds
        self.decodeMilliseconds = decodeMilliseconds ?? milliseconds
        self.durationMilliseconds = durationMilliseconds
        self.isKeyframe = isKeyframe
        self.data = data
    }
}

/// A file carried beside the tracks. A styled ASS subtitle names fonts the
/// viewer may not have, and an attachment is how they travel with the film.
public struct MatroskaAttachment {
    public let fileName: String
    public let mimeType: String
    public let data: Data

    public init(fileName: String, mimeType: String, data: Data) {
        self.fileName = fileName
        self.mimeType = mimeType
        self.data = data
    }
}

/// One chapter mark. `uid` must be non-zero and `startMilliseconds` strictly
/// increasing across a fixture's chapter list: FFmpeg's Matroska reader
/// requires both before it adds a chapter to `AVFormatContext.chapters`.
public struct MatroskaChapter {
    public let uid: UInt64
    public let startMilliseconds: Int
    public let title: String

    public init(uid: UInt64, startMilliseconds: Int, title: String) {
        self.uid = uid
        self.startMilliseconds = startMilliseconds
        self.title = title
    }
}

public struct MatroskaTrack {
    public enum Kind: UInt64 {
        case video = 1
        case audio = 2
        case subtitle = 17
    }

    public let number: Int
    public let kind: Kind
    public let codecID: String
    public let codecPrivate: Data?
    public let width: Int
    public let height: Int
    public let sampleRate: Double
    public let channels: Int
    public let language: String?
    public let name: String?
    public let isDefault: Bool
    public let isForced: Bool
    /// The frame duration the track states, which is where Matroska carries
    /// a video track's frame rate.
    public let defaultDurationNanoseconds: Int?

    public init(
        number: Int, kind: Kind, codecID: String, codecPrivate: Data? = nil,
        width: Int = 0, height: Int = 0, sampleRate: Double = 0, channels: Int = 0,
        language: String? = nil, name: String? = nil, isDefault: Bool = true,
        isForced: Bool = false, defaultDurationNanoseconds: Int? = nil
    ) {
        self.number = number
        self.kind = kind
        self.codecID = codecID
        self.codecPrivate = codecPrivate
        self.width = width
        self.height = height
        self.sampleRate = sampleRate
        self.channels = channels
        self.language = language
        self.name = name
        self.isDefault = isDefault
        self.isForced = isForced
        self.defaultDurationNanoseconds = defaultDurationNanoseconds
    }
}

/// An EBML length: the first set bit says how many bytes it takes, and an
/// all-ones value means unknown, which is why the loop stops one short.
private func ebmlSize(_ value: Int) -> Data {
    var length = 1
    while length < 8, value >= (1 << (7 * length)) - 1 { length += 1 }
    var bytes = [UInt8](repeating: 0, count: length)
    var remaining = UInt64(value)
    for index in stride(from: length - 1, through: 0, by: -1) {
        bytes[index] = UInt8(remaining & 0xFF)
        remaining >>= 8
    }
    bytes[0] |= UInt8(1 << (8 - length))
    return Data(bytes)
}

private func ebmlUInt(_ value: UInt64) -> Data {
    var bytes: [UInt8] = []
    var remaining = value
    repeat {
        bytes.insert(UInt8(remaining & 0xFF), at: 0)
        remaining >>= 8
    } while remaining > 0
    return Data(bytes)
}

/// Always eight bytes, so a value written twice takes the same room both times.
/// Cue positions are computed in a second pass and must not resize.
private func ebmlFixedUInt(_ value: UInt64) -> Data {
    var bytes = [UInt8](repeating: 0, count: 8)
    var remaining = value
    for index in stride(from: 7, through: 0, by: -1) {
        bytes[index] = UInt8(remaining & 0xFF)
        remaining >>= 8
    }
    return Data(bytes)
}

private func element(_ id: [UInt8], _ payload: Data) -> Data {
    var out = Data(id)
    out.append(ebmlSize(payload.count))
    out.append(payload)
    return out
}

private func uintElement(_ id: [UInt8], _ value: UInt64) -> Data {
    element(id, ebmlUInt(value))
}

private func stringElement(_ id: [UInt8], _ value: String) -> Data {
    element(id, Data(value.utf8))
}

private func floatElement(_ id: [UInt8], _ value: Double) -> Data {
    var bits = value.bitPattern.bigEndian
    return element(id, Data(bytes: &bits, count: 8))
}

private func trackEntry(_ track: MatroskaTrack) -> Data {
    var body = Data()
    body.append(uintElement([0xD7], UInt64(track.number)))        // TrackNumber
    body.append(uintElement([0x73, 0xC5], UInt64(track.number)))  // TrackUID
    body.append(uintElement([0x83], track.kind.rawValue))         // TrackType
    body.append(uintElement([0x9C], 0))                           // FlagLacing
    body.append(uintElement([0x88], track.isDefault ? 1 : 0))     // FlagDefault
    body.append(uintElement([0x55, 0xAA], track.isForced ? 1 : 0))  // FlagForced
    body.append(stringElement([0x86], track.codecID))             // CodecID
    if let duration = track.defaultDurationNanoseconds {
        body.append(uintElement([0x23, 0xE3, 0x83], UInt64(duration)))  // DefaultDuration
    }
    if let language = track.language {
        body.append(stringElement([0x22, 0xB5, 0x9C], language))  // Language
    }
    if let name = track.name {
        body.append(stringElement([0x53, 0x6E], name))            // Name
    }
    if let codecPrivate = track.codecPrivate {
        body.append(element([0x63, 0xA2], codecPrivate))          // CodecPrivate
    }
    switch track.kind {
    case .video:
        var video = uintElement([0xB0], UInt64(track.width))      // PixelWidth
        video.append(uintElement([0xBA], UInt64(track.height)))   // PixelHeight
        body.append(element([0xE0], video))
    case .audio:
        var audio = floatElement([0xB5], track.sampleRate)        // SamplingFrequency
        audio.append(uintElement([0x9F], UInt64(track.channels))) // Channels
        body.append(element([0xE1], audio))
    case .subtitle:
        break
    }
    return element([0xAE], body)
}

private func blockPayload(_ frame: MatroskaFrame, clusterStart: Int) throws -> Data {
    let relative = frame.milliseconds - clusterStart
    guard relative >= Int(Int16.min), relative <= Int(Int16.max) else {
        throw MatroskaFixtureError.blockTooFarFromCluster
    }
    var payload = ebmlSize(frame.track)  // the track number is an EBML-coded integer
    let stamp = Int16(relative).bigEndian
    withUnsafeBytes(of: stamp) { payload.append(contentsOf: $0) }
    // The keyframe bit lives in a SimpleBlock only; a Block inside a BlockGroup
    // carries none, and its group is what says how long it lasts.
    payload.append(frame.durationMilliseconds == nil && frame.isKeyframe ? 0x80 : 0x00)
    payload.append(frame.data)
    return payload
}

/// Writes an .mkv holding `tracks` and `frames` and returns its URL. A cluster
/// starts at every keyframe of `cueTrack` and each one gets a cue, which is
/// what a seek lands on.
public func makeMatroskaFixture(
    directory: URL,
    name: String,
    tracks: [MatroskaTrack],
    frames: [MatroskaFrame],
    durationMilliseconds: Int,
    cueTrack: Int,
    attachments: [MatroskaAttachment] = [],
    chapters: [MatroskaChapter] = []
) throws -> URL {
    // With no frame there is no cluster, and a Cues master with no CuePoint is
    // a file FFmpeg cannot open.
    precondition(!frames.isEmpty, "a matroska fixture needs at least one frame")

    var header = uintElement([0x42, 0x86], 1)              // EBMLVersion
    header.append(uintElement([0x42, 0xF7], 1))            // EBMLReadVersion
    header.append(uintElement([0x42, 0xF2], 4))            // EBMLMaxIDLength
    header.append(uintElement([0x42, 0xF3], 8))            // EBMLMaxSizeLength
    header.append(stringElement([0x42, 0x82], "matroska")) // DocType
    header.append(uintElement([0x42, 0x87], 4))            // DocTypeVersion
    header.append(uintElement([0x42, 0x85], 2))            // DocTypeReadVersion
    let ebmlHeader = element([0x1A, 0x45, 0xDF, 0xA3], header)

    var info = uintElement([0x2A, 0xD7, 0xB1], 1_000_000)   // TimestampScale: 1 ms
    info.append(stringElement([0x4D, 0x80], "lexis"))       // MuxingApp
    info.append(stringElement([0x57, 0x41], "lexis"))       // WritingApp
    info.append(floatElement([0x44, 0x89], Double(durationMilliseconds)))
    let infoElement = element([0x15, 0x49, 0xA9, 0x66], info)

    var trackBodies = Data()
    for track in tracks { trackBodies.append(trackEntry(track)) }
    let tracksElement = element([0x16, 0x54, 0xAE, 0x6B], trackBodies)

    var attachmentBodies = Data()
    for (order, attachment) in attachments.enumerated() {
        var body = stringElement([0x46, 0x6E], attachment.fileName)    // FileName
        body.append(stringElement([0x46, 0x60], attachment.mimeType))  // FileMimeType
        body.append(element([0x46, 0x5C], attachment.data))            // FileData
        body.append(uintElement([0x46, 0xAE], UInt64(order + 1)))      // FileUID
        attachmentBodies.append(element([0x61, 0xA7], body))           // AttachedFile
    }
    let attachmentsElement = attachments.isEmpty
        ? Data()
        : element([0x19, 0x41, 0xA4, 0x69], attachmentBodies)          // Attachments

    var chapterAtoms = Data()
    for chapter in chapters {
        var atom = uintElement([0x73, 0xC4], chapter.uid)              // ChapterUID
        // ChapterTimeStart is always nanoseconds, regardless of the
        // segment's own TimestampScale.
        atom.append(uintElement([0x91], UInt64(chapter.startMilliseconds) * 1_000_000))
        let display = element([0x80], stringElement([0x85], chapter.title))  // ChapterDisplay/ChapterString
        atom.append(display)
        chapterAtoms.append(element([0xB6], atom))                     // ChapterAtom
    }
    let chaptersElement = chapters.isEmpty
        ? Data()
        : element([0x10, 0x43, 0xA7, 0x70], element([0x45, 0xB9], chapterAtoms))  // Chapters/EditionEntry

    // Blocks are stored in decode order and carry a presentation timestamp, so
    // a reordered stream stays decodable. A cluster starts at a keyframe of the
    // cue track and runs to the next one, which is what makes every cue point
    // at a frame a seek can decode from; its timestamp is that keyframe's
    // presentation time, which is what a cue reports.
    // The track breaks ties: sorted(by:) is not stable, and two tracks sharing a
    // decode time would otherwise land in a different order run to run.
    let sorted = frames.sorted {
        ($0.decodeMilliseconds, $0.track) < ($1.decodeMilliseconds, $1.track)
    }
    var starts = sorted.filter { $0.track == cueTrack && $0.isKeyframe }
        .map { (decode: $0.decodeMilliseconds, timestamp: $0.milliseconds) }
    if starts.first?.decode != sorted[0].decodeMilliseconds {
        starts.insert((decode: sorted[0].decodeMilliseconds, timestamp: 0), at: 0)
    }
    var clusters: [(timestamp: Int, data: Data)] = []
    var index = 0
    var boundary = 0
    while index < sorted.count {
        let start = starts[boundary]
        let end = boundary + 1 < starts.count ? starts[boundary + 1].decode : Int.max
        boundary += 1
        var body = uintElement([0xE7], UInt64(start.timestamp))        // Timestamp
        while index < sorted.count, sorted[index].decodeMilliseconds < end {
            let frame = sorted[index]
            let payload = try blockPayload(frame, clusterStart: start.timestamp)
            if let duration = frame.durationMilliseconds {
                var group = element([0xA1], payload)                   // Block
                group.append(uintElement([0x9B], UInt64(duration)))    // BlockDuration
                body.append(element([0xA0], group))                    // BlockGroup
            } else {
                body.append(element([0xA3], payload))                  // SimpleBlock
            }
            index += 1
        }
        clusters.append((start.timestamp, element([0x1F, 0x43, 0xB6, 0x75], body)))
    }

    // Cues carry the offset of each cluster from the start of the segment's
    // data, which is only known once the cues themselves have a length. Every
    // position is eight bytes wide, so the first pass sizes what the second
    // fills in.
    func makeCues(positions: [Int]) -> Data {
        var body = Data()
        for (order, cluster) in clusters.enumerated() {
            var point = uintElement([0xB3], UInt64(cluster.timestamp))  // CueTime
            var track = uintElement([0xF7], UInt64(cueTrack))           // CueTrack
            track.append(element([0xF1], ebmlFixedUInt(UInt64(positions[order]))))
            point.append(element([0xB7], track))                        // CueTrackPositions
            body.append(element([0xBB], point))                         // CuePoint
        }
        return element([0x1C, 0x53, 0xBB, 0x6B], body)
    }

    var offsets = [Int](repeating: 0, count: clusters.count)
    let placeholder = makeCues(positions: offsets)
    var position = infoElement.count + tracksElement.count
        + attachmentsElement.count + chaptersElement.count + placeholder.count
    for (order, cluster) in clusters.enumerated() {
        offsets[order] = position
        position += cluster.data.count
    }
    let cues = makeCues(positions: offsets)
    precondition(cues.count == placeholder.count, "cue positions changed the cue size")

    var segment = infoElement
    segment.append(tracksElement)
    segment.append(attachmentsElement)
    segment.append(chaptersElement)
    segment.append(cues)
    for cluster in clusters { segment.append(cluster.data) }

    var file = ebmlHeader
    file.append(element([0x18, 0x53, 0x80, 0x67], segment))  // Segment
    let url = fixtureURL(in: directory, named: name)
    try? FileManager.default.removeItem(at: url)
    try file.write(to: url)
    return url
}

/// The script header an .mkv ASS track carries as its CodecPrivate. Its
/// dialogue lines carry no timestamps of their own: the blocks say when they
/// start and how long they last.
public let assFixtureHeader = """
[Script Info]
ScriptType: v4.00+
PlayResX: 1920
PlayResY: 1080

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Arial,48,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,0,2,10,10,10,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text

"""

/// A script with two styles, an outline and a PlayRes that is not the video's
/// size, so a test can tell libass's own layout from a coincidence.
public let assStyledFixtureHeader = """
[Script Info]
ScriptType: v4.00+
PlayResX: 1280
PlayResY: 720

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Helvetica,36,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,0,2,10,10,20,1
Style: Sign,Helvetica,48,&H0000FFFF,&H000000FF,&H00FF0000,&H00000000,1,0,0,0,100,100,0,0,1,3,0,5,10,10,10,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text

"""

/// One PGS display set: a rectangle of one palette entry, and the segments that
/// put it on screen. A `hdmv_pgs_subtitle` packet in an .mkv is exactly this,
/// one display set to a packet. The colour is the palette entry as PGS stores
/// it, YCrCb and alpha, and defaults to opaque white.
public func makePGSDisplaySet(
    x: Int, y: Int, width: Int, height: Int, colorIndex: UInt8,
    color: (luma: UInt8, cr: UInt8, cb: UInt8, alpha: UInt8) = (235, 128, 128, 255)
) -> Data {
    func segment(_ type: UInt8, _ payload: Data) -> Data {
        var out = Data([type, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)])
        out.append(payload)
        return out
    }
    func be16(_ value: Int) -> Data { Data([UInt8(value >> 8), UInt8(value & 0xFF)]) }

    var composition = be16(1920)          // the video the composition is against
    composition.append(be16(1080))
    composition.append(0x10)              // frame rate, which the decoder ignores
    composition.append(be16(0))           // composition number
    composition.append(0x80)              // composition state: epoch start
    composition.append(0x00)              // no palette update
    composition.append(0x00)              // palette id
    composition.append(0x01)              // one composition object
    composition.append(be16(0))           // object id
    composition.append(0x00)              // window id
    composition.append(0x00)              // no cropping
    composition.append(be16(x))
    composition.append(be16(y))

    var window = Data([0x01, 0x00])       // one window, id 0
    window.append(be16(x))
    window.append(be16(y))
    window.append(be16(width))
    window.append(be16(height))

    var palette = Data([0x00, 0x00])      // palette id 0, version 0
    palette.append(contentsOf: [colorIndex, color.luma, color.cr, color.cb, color.alpha])

    // Run length coding: a run is 00, then 0x80 or'd with its length, then the
    // colour; two zero bytes end a line. Runs are capped at 63 so the length
    // stays in one byte.
    var rle = Data()
    for _ in 0..<height {
        var remaining = width
        while remaining > 0 {
            let run = min(remaining, 63)
            rle.append(contentsOf: [0x00, 0x80 | UInt8(run), colorIndex])
            remaining -= run
        }
        rle.append(contentsOf: [0x00, 0x00])
    }
    var object = be16(0)                  // object id
    object.append(0x00)                   // version
    object.append(0xC0)                   // first and last in the sequence
    let dataLength = rle.count + 4        // the width and height that follow it
    object.append(contentsOf: [
        UInt8((dataLength >> 16) & 0xFF), UInt8((dataLength >> 8) & 0xFF),
        UInt8(dataLength & 0xFF),
    ])
    object.append(be16(width))
    object.append(be16(height))
    object.append(rle)

    var out = segment(0x16, composition)  // PCS
    out.append(segment(0x17, window))     // WDS
    out.append(segment(0x14, palette))    // PDS
    out.append(segment(0x15, object))     // ODS
    out.append(segment(0x80, Data()))     // END
    return out
}

/// The CodecPrivate a Matroska `S_VOBSUB` track carries: literally the
/// significant lines of a VobSub .idx sidecar. FFmpeg's dvdsub decoder reads
/// its 16-entry global palette from exactly this text
/// (libavcodec/dvdsubdec.c's dvdsub_parse_extradata scans for a "palette:"
/// line and ignores everything else) - never from the packet, which carries
/// no palette of its own.
public func makeVobSubIdxExtradata(canvasWidth: Int, canvasHeight: Int, palette: [UInt32]) -> Data {
    precondition(palette.count == 16, "a VobSub global palette is always 16 entries")
    let hex = palette.map { String(format: "%06x", $0) }.joined(separator: ", ")
    return Data(
        """
        size: \(canvasWidth)x\(canvasHeight)
        palette: \(hex)
        """.utf8
    )
}

/// One classic DVD sub-picture unit: the packet a VobSub track packs into
/// one Matroska block. A solid `width` x `height` rectangle at `x`, `y`,
/// drawn in the 2-bit RLE dvdsubdec.c's `decode_rle` reads (never the 8-bit
/// HD variant), every pixel resolving through pixel-value 1, which
/// `SET_COLOR` maps to the caller's chosen entry of the 16-entry global
/// palette `makeVobSubIdxExtradata` describes.
public func makeVobSubPacket(x: Int, y: Int, width: Int, height: Int, paletteIndex: UInt8) -> Data {
    precondition(height == 2, "one fill-line code per field, below, draws exactly one row each")
    func be16(_ value: Int) -> [UInt8] { [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)] }

    var buffer: [UInt8] = [0x00, 0x00, 0x00, 0x00]  // SPDSZ (filled in below), cmd_pos
    let cmdPos = 4
    buffer.replaceSubrange(2..<4, with: be16(cmdPos))

    // date, next_cmd_pos == cmd_pos: one command sequence, nothing chained
    // after it.
    buffer.append(contentsOf: [0x00, 0x00])
    buffer.append(contentsOf: be16(cmdPos))

    // SET_COLOR: the four 2-bit pixel values map to the global palette's own
    // 16 entries; pixel-value 1 is the only one this rectangle ever draws.
    buffer.append(0x03)
    buffer.append(contentsOf: [0x00, paletteIndex << 4])

    // SET_CONTR: alpha per pixel value, a 4-bit nibble each; 0xF is opaque.
    buffer.append(0x04)
    buffer.append(contentsOf: [0x00, 0xF0])

    // SET_DAREA: the rectangle, three 12-bit pairs packed into six bytes.
    let x1 = x, x2 = x + width - 1, y1 = y, y2 = y + height - 1
    buffer.append(0x05)
    buffer.append(contentsOf: [
        UInt8((x1 >> 4) & 0xFF), UInt8(((x1 & 0xF) << 4) | ((x2 >> 8) & 0xF)), UInt8(x2 & 0xFF),
        UInt8((y1 >> 4) & 0xFF), UInt8(((y1 & 0xF) << 4) | ((y2 >> 8) & 0xF)), UInt8(y2 & 0xFF),
    ])

    // SET_DSPXA: the even- and odd-field RLE offsets, patched in once the
    // bytes they point at are actually placed, below.
    let offsetsCmdIndex = buffer.count
    buffer.append(0x06)
    buffer.append(contentsOf: [0x00, 0x00, 0x00, 0x00])

    buffer.append(0xFF)  // the command sequence's own end

    // Two-bit RLE. decode_run_2bit reads 4-bit groups until the value it has
    // accumulated reaches the next power-of-4 threshold (1, 4, 16, 64); three
    // leading zero nibbles followed by the colour is the only sequence that
    // survives all three thresholds and still comes out under 4, which is
    // decode_rle's own code for "fill the rest of the line" - two bytes,
    // 0x00 then the colour in the low nibble. height 2 keeps this to one row
    // a field, so one such code is every row each field call ever needs.
    let runBytes: [UInt8] = [0x00, 0x01]  // pixel-value 1, "fill rest of line"
    let evenOffset = buffer.count
    buffer.append(contentsOf: runBytes)
    let oddOffset = buffer.count
    buffer.append(contentsOf: runBytes)

    buffer.replaceSubrange(
        offsetsCmdIndex + 1..<offsetsCmdIndex + 5, with: be16(evenOffset) + be16(oddOffset)
    )
    buffer.replaceSubrange(0..<2, with: be16(buffer.count))  // SPDSZ, now that the packet is whole
    return Data(buffer)
}

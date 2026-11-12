import CFFmpeg
import CLibass
import CoreGraphics
import Foundation
import Synchronization

public enum SubtitleDecodeError: Error, Equatable {
    case decoderUnavailable(String)
    case allocationFailed
    case openFailed(Int32)
    case decodeFailed(Int32)
}

/// One bitmap of a graphic subtitle, in the cue's canvas coordinates.
///
/// Equality is identity: two images are equal when they are copies of one
/// bitmap at one place. A cue is compared on every tick, and comparing
/// pixels would be a memcmp of megabytes to learn nothing.
public struct SubtitleImage: Sendable, Equatable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int
    /// Premultiplied ARGB in native order, `width * 4` bytes to a row.
    public let pixels: Data
    /// Which bitmap this is: a copy, or the same pixels moved elsewhere,
    /// keeps it; anything built again gets a new one.
    let bitmap: UInt64

    private static let bitmaps = Atomic<UInt64>(0)

    public init(x: Int, y: Int, width: Int, height: Int, pixels: Data) {
        self.init(
            x: x, y: y, width: width, height: height, pixels: pixels,
            bitmap: SubtitleImage.bitmaps.add(1, ordering: .relaxed).newValue
        )
    }

    init(x: Int, y: Int, width: Int, height: Int, pixels: Data, bitmap: UInt64) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.pixels = pixels
        self.bitmap = bitmap
    }

    public static func == (lhs: SubtitleImage, rhs: SubtitleImage) -> Bool {
        lhs.bitmap == rhs.bitmap && lhs.x == rhs.x && lhs.y == rhs.y
    }

    /// The bitmap as an image a layer can hold. Nil when the pixels do not
    /// match the size, which no decoder produces.
    /// `white` scales the colour and leaves the alpha: premultiplied, a
    /// colour scaled stays within its alpha.
    public func makeImage(white: CGFloat = 1) -> CGImage? {
        guard width > 0, height > 0, pixels.count == width * height * 4 else { return nil }
        var drawn = pixels
        if white < 1 {
            let scale = UInt32(white * 256)
            drawn.withUnsafeMutableBytes { bytes in
                // BGRA in memory, the alpha last
                for pixel in stride(from: 0, to: bytes.count, by: 4) {
                    for channel in pixel..<pixel + 3 {
                        // parenthesized: Swift's >> binds tighter than *
                        bytes[channel] = UInt8((UInt32(bytes[channel]) * scale) >> 8)
                    }
                }
            }
        }
        guard let provider = CGDataProvider(data: drawn as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
                .union(.byteOrder32Little),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}

/// What to show and until when, in seconds of stream time.
public struct SubtitleCue: Sendable, Equatable {
    public let start: Double
    /// `.infinity` when nothing says: a PGS subtitle lasts until the display
    /// set that clears it.
    public let end: Double
    /// The dialogue, one entry to a line, with its markup taken off.
    public let lines: [String]
    /// The bitmaps a graphic subtitle draws.
    public let images: [SubtitleImage]
    /// What the images are positioned against, which is the video's own size.
    /// Zero on a text cue, which is also how the sink tells the two kinds apart.
    public let canvasWidth: Int
    public let canvasHeight: Int

    public init(
        start: Double, end: Double, lines: [String], images: [SubtitleImage],
        canvasWidth: Int, canvasHeight: Int
    ) {
        self.start = start
        self.end = end
        self.lines = lines
        self.images = images
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
    }

    /// Shows nothing: a clear on a graphic stream, an event that draws nothing
    /// on a text one. `DisplayLayerSink.updateSubtitle` tells the two apart.
    public var isEmpty: Bool { lines.isEmpty && images.isEmpty }
}

/// Decodes one subtitle stream to cues. Text formats all arrive as ASS dialogue
/// whatever they were on disk, so one parser serves them; the styling that
/// dialogue carries is dropped, which is what this player draws until libass
/// is vendored.
public final class SubtitleDecoder {
    /// avcodec reads past the end of extradata, so the buffer it is given is
    /// oversized by this much.
    private static let extradataPadding = 64

    private let context: UnsafeMutablePointer<AVCodecContext>
    private let packet: UnsafeMutablePointer<AVPacket>
    private let timeBaseNum: Int32
    private let timeBaseDen: Int32
    /// Serializes decode/flush/close against each other. The engine used to
    /// guarantee this with its own lock; decoding a bitmap display set moved
    /// off that lock (it is the one every pipeline thread contends on), so
    /// the guarantee lives here now: a track switch may flush while a display
    /// set is mid-decode without touching libavcodec from two threads.
    private let stateLock = NSLock()

    public init(stream: MediaStream) throws {
        guard let codec = avcodec_find_decoder(AVCodecID(rawValue: stream.codecID)) else {
            throw SubtitleDecodeError.decoderUnavailable(stream.codecName)
        }
        var allocatedContext = avcodec_alloc_context3(codec)
        var allocatedPacket = av_packet_alloc()
        var kept = false
        // deinit never runs for an init that throws, so every failure below has
        // to give back what was allocated here
        defer {
            if !kept {
                avcodec_free_context(&allocatedContext)
                av_packet_free(&allocatedPacket)
            }
        }
        guard let context = allocatedContext, let packet = allocatedPacket else {
            throw SubtitleDecodeError.allocationFailed
        }
        if let extradata = stream.extradata, !extradata.isEmpty {
            guard let bytes = av_mallocz(extradata.count + SubtitleDecoder.extradataPadding) else {
                throw SubtitleDecodeError.allocationFailed
            }
            extradata.withUnsafeBytes { raw in
                _ = memcpy(bytes, raw.baseAddress!, extradata.count)
            }
            // the context owns it from here: avcodec_free_context frees it
            context.pointee.extradata = bytes.assumingMemoryBound(to: UInt8.self)
            context.pointee.extradata_size = Int32(extradata.count)
        }
        // what the decoder rescales a packet's timestamps against
        context.pointee.pkt_timebase = AVRational(num: stream.timeBaseNum, den: stream.timeBaseDen)
        // The probe's canvas, when its decode of one display set found it.
        // A track silent through the probe opens without one; the decoder
        // learns it from each presentation segment, so decode reads it back.
        context.pointee.width = stream.width
        context.pointee.height = stream.height
        let code = avcodec_open2(context, codec, nil)
        guard code >= 0 else {
            throw SubtitleDecodeError.openFailed(code)
        }
        self.context = context
        self.packet = packet
        timeBaseNum = stream.timeBaseNum
        timeBaseDen = stream.timeBaseDen
        kept = true
    }

    deinit {
        var packet: UnsafeMutablePointer<AVPacket>? = self.packet
        av_packet_free(&packet)
        var context: UnsafeMutablePointer<AVCodecContext>? = self.context
        avcodec_free_context(&context)
    }

    /// The cue this packet makes, if any. A cue that shows nothing is normal:
    /// it is a graphic stream taking the last one off the screen.
    public func decode(_ input: Packet) throws -> SubtitleCue? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try decodeLocked(input)
    }

    /// `stateLock` held: every touch of the codec context runs behind it.
    private func decodeLocked(_ input: Packet) throws -> SubtitleCue? {
        av_packet_unref(packet)
        // Referenced, not copied back in: these bytes came out of FFmpeg, and
        // this hands the same buffer to the decoder that read it. A text
        // decoder reads the packet as a C string and runs past the end of the
        // data; the zeroed padding it lands in is already there, since every
        // `PacketBuffer` is an AVPacket either referenced from a demuxer or
        // allocated through av_new_packet.
        guard let source = input.buffer,
            av_packet_ref(packet, source.packet) >= 0
        else { throw SubtitleDecodeError.allocationFailed }
        // The reference carries the source packet's side data and flags, which
        // the copy it replaced silently dropped - and a decoder acts on them:
        // AAC honours AV_PKT_DATA_SKIP_SAMPLES and swallows the encoder's
        // priming, a seek's own AV_PKT_FLAG_DISCARD makes a decoder throw the
        // packet away. Sharing the bytes is this change; forwarding directives
        // that were never forwarded is a different one, with its own effect on
        // sync and its own tests. `av_packet_ref` deep-copies side data into
        // this packet, so freeing it here leaves the source's untouched.
        av_packet_free_side_data(packet)
        packet.pointee.flags = 0
        packet.pointee.pts = input.pts ?? LexisNoPTS
        packet.pointee.duration = input.duration
        var subtitle = AVSubtitle()
        var got: Int32 = 0
        let code = avcodec_decode_subtitle2(context, &subtitle, &got, packet)
        av_packet_unref(packet)
        // freeing an untouched AVSubtitle is a no-op, so one defer covers the
        // error and no-cue paths as well as the one that builds a cue
        defer { avsubtitle_free(&subtitle) }
        guard code >= 0 else { throw SubtitleDecodeError.decodeFailed(code) }
        guard got != 0 else { return nil }
        // a subtitle with no timestamp cannot be shown at the right moment, and
        // showing it at the wrong one is worse than dropping it
        guard let pts = input.pts ?? input.dts else { return nil }

        let base = Double(timeBaseNum) / Double(timeBaseDen)
        let start = Double(pts) * base + Double(subtitle.start_display_time) / 1000
        let end: Double
        if input.duration > 0 {
            // the container's own answer, and the only one PGS ever has
            end = Double(pts) * base + Double(input.duration) * base
        } else if subtitle.end_display_time != UInt32.max {
            end = Double(pts) * base + Double(subtitle.end_display_time) / 1000
        } else {
            end = .infinity
        }

        var lines: [String] = []
        var images: [SubtitleImage] = []
        for index in 0..<Int(subtitle.num_rects) {
            guard let rect = subtitle.rects[index]?.pointee else { continue }
            switch rect.type {
            case SUBTITLE_ASS:
                guard let ass = rect.ass else { continue }
                lines.append(contentsOf: SubtitleDecoder.lines(fromDialogue: String(cString: ass)))
            case SUBTITLE_TEXT:
                guard let text = rect.text else { continue }
                lines.append(contentsOf: String(cString: text).split(
                    separator: "\n", omittingEmptySubsequences: false
                ).map(String.init))
            case SUBTITLE_BITMAP:
                guard let image = SubtitleDecoder.image(from: rect) else { continue }
                images.append(image)
            default:
                continue
            }
        }
        return SubtitleCue(
            start: start, end: end, lines: lines, images: images,
            canvasWidth: Int(context.pointee.width), canvasHeight: Int(context.pointee.height)
        )
    }

    /// Drops what the decoder is holding. PGS keeps the composition state of
    /// its epoch across packets, so a seek has to call this or the next display
    /// set draws into a window that is no longer there.
    public func flush() {
        stateLock.lock()
        avcodec_flush_buffers(context)
        stateLock.unlock()
    }

    /// The rect's indexed pixels resolved against its palette and
    /// premultiplied, which is the only 32-bit layout CoreGraphics takes. The
    /// palette is 256 native-order ARGB words whatever nb_colors says.
    private static func image(from rect: AVSubtitleRect) -> SubtitleImage? {
        let width = Int(rect.w)
        let height = Int(rect.h)
        guard width > 0, height > 0, let indices = rect.data.0, let palette = rect.data.1
        else { return nil }
        let stride = Int(rect.linesize.0)
        guard stride >= width else { return nil }
        var pixels = Data(count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: UInt32.self)
            // premultiplied once per palette entry rather than once per pixel
            withUnsafeTemporaryAllocation(of: UInt32.self, capacity: 256) { table in
                palette.withMemoryRebound(to: UInt32.self, capacity: 256) { colors in
                    for index in 0..<256 {
                        let color = colors[index]
                        let alpha = color >> 24
                        let red = ((color >> 16) & 0xFF) * alpha / 255
                        let green = ((color >> 8) & 0xFF) * alpha / 255
                        let blue = (color & 0xFF) * alpha / 255
                        table[index] = alpha << 24 | red << 16 | green << 8 | blue
                    }
                }
                for y in 0..<height {
                    let row = indices + y * stride
                    let target = y * width
                    for x in 0..<width {
                        out[target + x] = table[Int(row[x])]
                    }
                }
            }
        }
        return SubtitleImage(
            x: Int(rect.x), y: Int(rect.y), width: width, height: height, pixels: pixels
        )
    }

    /// Whether this codec's cues carry bitmaps rather than text. The descriptor
    /// knows, so the track list can say so without opening a decoder.
    public static func isGraphic(codecID: UInt32) -> Bool {
        guard let descriptor = avcodec_descriptor_get(AVCodecID(rawValue: codecID)) else {
            return false
        }
        return descriptor.pointee.props & LexisCodecPropBitmapSub != 0
    }

    /// Whether this track is styled ASS/SSA, which libass draws rather than
    /// this decoder. Only AV_CODEC_ID_ASS: AV_CODEC_ID_SSA is legacy and
    /// nothing in this build ever produces it.
    public static func isStyled(codecID: UInt32) -> Bool {
        codecID == LexisCodecIDASS
    }

    /// The text of an ASS dialogue line: nine comma-separated fields, of which
    /// the last is the text, and the text carries \N line breaks and {...}
    /// override blocks that nothing here draws.
    private static func lines(fromDialogue dialogue: String) -> [String] {
        let fields = dialogue.split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false)
        guard fields.count == 9 else { return [] }
        var text = ""
        var block = ""
        var depth = 0
        var escaped = false
        // what a \p1 opens is vector commands until a \p0 takes it back, and
        // nothing here draws them, so they are dropped rather than spelled out
        var drawing = false
        for character in fields[8] {
            // inside a block a backslash starts a tag, not an escape, so the
            // whole block is read aside and only its \p tags are looked at
            if depth > 0 {
                switch character {
                case "{": depth += 1
                case "}":
                    depth -= 1
                    guard depth == 0 else { break }
                    if let scale = SubtitleDecoder.drawingScale(in: block) { drawing = scale > 0 }
                    block = ""
                default: block.append(character)
                }
                continue
            }
            if escaped {
                escaped = false
                guard !drawing else { continue }
                switch character {
                case "N", "n": text.append("\n")
                case "h": text.append(" ")
                default: text.append(character)
                }
                continue
            }
            switch character {
            case "\\": escaped = true
            case "{": depth += 1
            // a brace that closes nothing is still markup
            case "}": break
            default: if !drawing { text.append(character) }
            }
        }
        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The scale of the last \p tag of an override block, nil when it carries
    /// none. \pos and \pbo start the same way and are not drawings.
    private static func drawingScale(in block: String) -> Int? {
        let characters = Array(block)
        var scale: Int?
        var index = 0
        while index < characters.count {
            guard characters[index] == "\\", index + 1 < characters.count,
                  characters[index + 1] == "p"
            else {
                index += 1
                continue
            }
            var value = 0
            var cursor = index + 2
            while cursor < characters.count, characters[cursor].isASCII,
                  let digit = characters[cursor].wholeNumberValue
            {
                value = value * 10 + digit
                cursor += 1
            }
            // a tag ends at the next backslash or at the end of the block; a \p
            // that runs into anything else is the start of a longer tag name
            if cursor > index + 2 || cursor == characters.count || characters[cursor] == "\\" {
                scale = value
            }
            index = cursor
        }
        return scale
    }
}

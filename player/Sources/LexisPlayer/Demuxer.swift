import CFFmpeg
import Foundation

public enum StreamKind: Sendable, Equatable, Codable {
    case video
    case audio
    case subtitle
    case other
}

public struct MediaStream: Sendable, Equatable, Codable {
    public let index: Int32
    public let kind: StreamKind
    public let codecID: UInt32
    public let codecName: String
    public let width: Int32
    public let height: Int32
    public let timeBaseNum: Int32
    public let timeBaseDen: Int32
    /// Audio only; 0 on every other kind of stream.
    public let sampleRate: Int32
    public let channels: Int32
    /// How many frames a decoder holds before it can emit the first one: the
    /// reorder depth of the stream, 0 when nothing is out of order.
    public let videoDelay: Int32
    /// The container's language tag, empty when it says "und" or has no default
    /// for it. An untagged Matroska track reads "eng", the format's own default.
    public let language: String
    /// The container's own name for the track, empty when it has none.
    public let title: String
    /// What the container says to play when nobody has chosen.
    public let isDefault: Bool
    /// A track meant to be shown even with subtitles off: signs, or the one
    /// alien language in a film.
    public let isForced: Bool
    /// AVColorPrimaries, AVColorTransferCharacteristic and AVColorSpace as the
    /// container tagged them; 2 (unspecified) when it said nothing.
    public let colorPrimaries: Int32
    public let colorTransfer: Int32
    public let colorMatrix: Int32
    public let isFullRange: Bool
    /// SMPTE ST 2086 and CTA-861.3, in the byte layout a format description
    /// takes; nil when the container carries neither.
    public let masteringDisplay: Data?
    public let contentLight: Data?
    /// The dvcC or dvvC box, when the track has one.
    public let dolbyVision: DolbyVisionConfiguration?
    /// avcC / hvcC for mp4-style streams; nil when the container carries none.
    public let extradata: Data?
    /// FFmpeg's own average, not `r_frame_rate` (its header calls that one
    /// "just a guess"). Either half 0 means the container did not say.
    ///
    /// `var`, not `let`: a stored `let` with a default value is dropped from
    /// Swift's memberwise initializer entirely, which would make every
    /// existing hand-built `MediaStream(...)` in the test suite stop
    /// compiling the moment this field existed.
    public var frameRateNum: Int32 = 0
    public var frameRateDen: Int32 = 0
    /// What the container says this track costs on the wire. 0 when it says
    /// nothing, which a Matroska track usually does.
    public var bitsPerSecond: Int64 = 0
    /// `AVFieldOrder` as the container and the bitstream declared it: 0 for
    /// a stream that said nothing, 1 for progressive, 2 to 5 for the four
    /// interlaced orders. Defaulted for the same reason the frame rate
    /// fields above are.
    public var fieldOrder: Int32 = 0
    /// Bits per luma sample of a video track: 10 for the ten bit profiles,
    /// 0 where the container did not say, which decodes as 8.
    public var bitDepth: Int32 = 0
    /// The shape of one pixel, width over height, as the container or the
    /// bitstream states it: 16:11 for a widescreen PAL DVD. 0 where neither
    /// says, which is square.
    public var pixelAspectNum: Int32 = 0
    public var pixelAspectDen: Int32 = 0
    /// `AVChromaLocation`: where a 4:2:0 chroma sample sits, 0 where the
    /// stream does not say.
    public var chromaLocation: Int32 = 0

    public var frameRate: Double? {
        frameRateNum > 0 && frameRateDen > 0
            ? Double(frameRateNum) / Double(frameRateDen)
            : nil
    }

    /// A track whose pictures carry two fields half a frame apart. Read
    /// before a decoder exists, so it is what picks the path: a hardware
    /// passthrough hands the display layer compressed samples and nothing in
    /// this process ever sees the picture, which leaves nowhere to
    /// deinterlace. `AV_FIELD_UNKNOWN` is not a claim either way and reads
    /// false here; the per-frame flag still catches it once decoding starts.
    public var isInterlaced: Bool {
        fieldOrder >= Int32(AV_FIELD_TT.rawValue) && fieldOrder <= Int32(AV_FIELD_BT.rawValue)
    }

    /// The rate pictures actually reach the screen at, which is what the
    /// display should be asked to run at. Deinterlacing is a bob: every
    /// interlaced frame becomes its two fields, so a 25i track puts 50
    /// pictures a second on screen and asking the display for 25 would make
    /// it drop every other one. A 29.97i track carrying telecined film stays
    /// at 59.94: its cadence is only read a few frames in, and lost at every
    /// edit, while a mode change blanks the screen, so the film frames go up
    /// two and three fields long on the field grid, as the pulldown laid
    /// them out.
    public var outputFrameRate: Double? {
        isInterlaced ? frameRate.map { $0 * 2 } : frameRate
    }
}

/// One chapter mark from `AVFormatContext.chapters`.
public struct Chapter: Sendable, Equatable, Codable {
    public let start: Double
    public let title: String

    public init(start: Double, title: String) {
        self.start = start
        self.title = title
    }
}

/// One packet's bytes, as the buffer FFmpeg already owns rather than a copy
/// of it, taken over from the demuxer's packet in O(1): a queue of packets
/// holds the demuxer's own bytes once instead of a second copy of them, and a
/// decoder fed from here is handed back the very buffer the packet was read
/// into.
///
/// `@unchecked Sendable`, and honestly so: the `AVPacket` is written once, in
/// these initializers, and only read afterward; the `AVBufferRef` beneath it is
/// reference counted by FFmpeg itself with atomics, so a reference crossing a
/// thread costs one atomic and shares no mutable state; and `deinit` runs
/// exactly once, wherever the last reference happens to die.
final class PacketBuffer: @unchecked Sendable {
    let packet: UnsafeMutablePointer<AVPacket>

    /// Takes over `source`'s buffer and leaves `source` blank: no reference
    /// is added, and none is dropped later on the source's side.
    init?(moving source: UnsafeMutablePointer<AVPacket>) {
        guard let allocated = av_packet_alloc() else { return nil }
        av_packet_move_ref(allocated, source)
        packet = allocated
    }

    /// Bytes that never came from a demuxer - a fixture's, a caller's. This is
    /// the one case that must copy, and `av_new_packet` is why: it puts
    /// avcodec's own zeroed padding after the data, which a bitstream reader
    /// running past the end of a packet relies on, and which a bare buffer of
    /// someone else's bytes has no room for.
    init?(bytes: Data) {
        guard let allocated = av_packet_alloc() else { return nil }
        guard av_new_packet(allocated, Int32(bytes.count)) >= 0 else {
            var owned: UnsafeMutablePointer<AVPacket>? = allocated
            av_packet_free(&owned)
            return nil
        }
        if !bytes.isEmpty {
            bytes.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                _ = memcpy(allocated.pointee.data, base, raw.count)
            }
        }
        packet = allocated
    }

    deinit {
        var owned: UnsafeMutablePointer<AVPacket>? = packet
        av_packet_free(&owned)
    }
}

public struct Packet: Sendable {
    public let streamIndex: Int32
    /// In the stream time base; nil when the container gives no timestamp.
    public let pts: Int64?
    public let dts: Int64?
    public let isKeyframe: Bool
    /// Nothing else references this frame, so dropping it costs one picture
    /// and nothing after it.
    public let isDisposable: Bool
    /// In the stream time base; 0 when the container does not say. On a
    /// subtitle packet this is how long the line stays up.
    public let duration: Int64
    /// nil only where FFmpeg would not allocate, which reads downstream as a
    /// packet carrying nothing - the state every consumer already handles.
    let buffer: PacketBuffer?

    public init(
        streamIndex: Int32, pts: Int64?, dts: Int64?, isKeyframe: Bool, isDisposable: Bool,
        duration: Int64, data: Data
    ) {
        self.init(
            streamIndex: streamIndex, pts: pts, dts: dts, isKeyframe: isKeyframe,
            isDisposable: isDisposable, duration: duration, buffer: PacketBuffer(bytes: data)
        )
    }

    init(
        streamIndex: Int32, pts: Int64?, dts: Int64?, isKeyframe: Bool, isDisposable: Bool,
        duration: Int64, buffer: PacketBuffer?
    ) {
        self.streamIndex = streamIndex
        self.pts = pts
        self.dts = dts
        self.isKeyframe = isKeyframe
        self.isDisposable = isDisposable
        self.duration = duration
        self.buffer = buffer
    }

    /// mp4-style length-prefixed NAL units, exactly as the container stores
    /// them. VideoToolbox takes them as is.
    public var byteCount: Int { buffer.map { Int($0.packet.pointee.size) } ?? 0 }

    /// The bytes themselves, without copying them. Valid only for the call.
    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        guard let buffer, buffer.packet.pointee.size > 0, let base = buffer.packet.pointee.data
        else { return try body(UnsafeRawBufferPointer(start: nil, count: 0)) }
        return try body(
            UnsafeRawBufferPointer(start: base, count: Int(buffer.packet.pointee.size)))
    }

    /// A copy, for the callers that keep the bytes past the packet: a styled
    /// subtitle event the renderer stores, a keyframe the bench describes a
    /// format from. Never on a path that runs per packet of a playback.
    public var copiedBytes: Data {
        withUnsafeBytes { Data($0) }
    }
}

public enum DemuxError: Error, Equatable {
    case openFailed(code: Int32, message: String)
    case noStreamInfo(code: Int32, message: String)
    case readFailed(code: Int32, message: String)
    case seekFailed(code: Int32, message: String)
    /// The stream refused the credential while reading, not at open time.
    case unauthorized

    public static func message(for code: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        av_strerror(code, &buffer, buffer.count)
        return String(cString: buffer)
    }
}

/// Non-zero tells FFmpeg to abandon whatever it is doing. FFmpeg polls this
/// between operations; the AVIO read callback is what covers the rest.
private let interruptPoll: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = { opaque in
    guard let opaque else { return 0 }
    return Unmanaged<InterruptFlag>.fromOpaque(opaque).takeUnretainedValue().isRaised ? 1 : 0
}

public final class Demuxer {
    private var context: UnsafeMutablePointer<AVFormatContext>?
    private let packet: UnsafeMutablePointer<AVPacket>
    /// Held for as long as the demuxer reads; nil when FFmpeg opened the file
    /// itself. Releasing it frees the AVIOContext and closes the stream.
    private let io: AVIOStream?
    /// Held because the format context stores an unretained pointer to it.
    private let interrupt: InterruptFlag?
    public let streams: [MediaStream]
    /// The container's own chapter marks, in presentation order. Empty when
    /// the container carries none.
    public let chapters: [Chapter]
    /// The container's own duration in seconds, 0 when it does not say. Only
    /// the format context knows it: no stream carries it.
    public private(set) var duration: Double = 0
    /// What the byte cache has measured, nil when this demuxer opened a
    /// plain file rather than a `MediaStreamIO`.
    var ioStatistics: ByteCacheStatistics? { io?.byteCacheStatistics }
    /// The keyframe table FFmpeg holds after open, presentation seconds.
    /// Empty when the file carries no video stream.
    /// The whole file's rate. FFmpeg computes it from the file's size and its
    /// duration where the container states none, which is what makes this the
    /// measurable stand-in for a remux's video track: a remux is nearly all
    /// video. 0 when it can say neither.
    public var bitsPerSecond: Int64 {
        context.map { max(0, $0.pointee.bit_rate) } ?? 0
    }

    public var keyframeTable: [Double] {
        guard let context, let videoStream = streams.first(where: { $0.kind == .video }),
            let avStream = context.pointee.streams[Int(videoStream.index)]
        else { return [] }
        let count = Int(avformat_index_get_entries_count(avStream))
        var result: [Double] = []
        result.reserveCapacity(count)
        for i in 0..<count {
            guard let entry = avformat_index_get_entry(avStream, Int32(i)),
                entry.pointee.flags & Int32(AVINDEX_KEYFRAME) != 0
            else { continue }
            result.append(
                Double(entry.pointee.timestamp) * Double(videoStream.timeBaseNum)
                    / Double(videoStream.timeBaseDen)
            )
        }
        return result
    }

    public init(url: URL) throws {
        var context: UnsafeMutablePointer<AVFormatContext>?
        let openCode = avformat_open_input(&context, url.path, nil, nil)
        guard openCode == 0, let opened = context else {
            throw DemuxError.openFailed(code: openCode, message: DemuxError.message(for: openCode))
        }
        let infoCode = avformat_find_stream_info(opened, nil)
        guard infoCode >= 0 else {
            var toClose: UnsafeMutablePointer<AVFormatContext>? = opened
            avformat_close_input(&toClose)
            throw DemuxError.noStreamInfo(code: infoCode, message: DemuxError.message(for: infoCode))
        }
        guard let packet = av_packet_alloc() else {
            var toClose: UnsafeMutablePointer<AVFormatContext>? = opened
            avformat_close_input(&toClose)
            throw DemuxError.openFailed(code: 0, message: "packet allocation failed")
        }
        self.context = opened
        self.packet = packet
        io = nil
        interrupt = nil
        streams = Demuxer.describeStreams(opened)
        chapters = Demuxer.describeChapters(opened)
        let reported = opened.pointee.duration
        duration = reported == LexisNoPTS || reported <= 0
            ? 0
            : Double(reported) / Double(LexisTimeBase)
    }

    /// Reads through `stream` and takes ownership of it: the stream is closed
    /// when the demuxer goes away, and also when this initializer throws.
    /// Raising `interrupt` makes every later operation give up.
    public convenience init(stream: MediaStreamIO, interrupt: InterruptFlag? = nil) throws {
        try self.init(
            stream: stream, interrupt: interrupt,
            byteCacheWindow: ByteCache.windowCapacity
        )
    }

    /// Same open, for a caller inside the package that wants its own window
    /// size over the stream - the thumbnail strip's smaller ring.
    init(
        stream: MediaStreamIO, interrupt: InterruptFlag? = nil,
        byteCacheWindow: Int
    ) throws {
        let io = try AVIOStream(io: stream, interrupt: interrupt, byteCacheWindow: byteCacheWindow)
        guard let allocated = avformat_alloc_context() else {
            throw DemuxError.openFailed(code: 0, message: "format context allocation failed")
        }
        if let interrupt {
            allocated.pointee.interrupt_callback = AVIOInterruptCB(
                callback: interruptPoll,
                opaque: Unmanaged.passUnretained(interrupt).toOpaque()
            )
        }
        // set before opening: that is what makes FFmpeg read through the
        // callbacks and leaves the AVIOContext ours to free
        allocated.pointee.pb = io.context
        allocated.pointee.probesize = Demuxer.coldProbeSize
        allocated.pointee.max_analyze_duration = Demuxer.coldAnalyzeDuration
        var context: UnsafeMutablePointer<AVFormatContext>? = allocated
        OpenTrace.shared.enter(.formatOpen)
        let openCode = avformat_open_input(&context, nil, nil, nil)
        guard openCode == 0, let opened = context else {
            // a token that expires between the core opening the stream and the
            // probe reading through it fails here, and is as recoverable as one
            // refused mid-playback
            throw io.refusedCredential
                ? DemuxError.unauthorized
                : DemuxError.openFailed(code: openCode, message: DemuxError.message(for: openCode))
        }
        OpenTrace.shared.enter(.streamInfo)
        let infoCode = avformat_find_stream_info(opened, nil)
        guard infoCode >= 0 else {
            var toClose: UnsafeMutablePointer<AVFormatContext>? = opened
            avformat_close_input(&toClose)
            throw io.refusedCredential
                ? DemuxError.unauthorized
                : DemuxError.noStreamInfo(code: infoCode, message: DemuxError.message(for: infoCode))
        }
        guard let packet = av_packet_alloc() else {
            var toClose: UnsafeMutablePointer<AVFormatContext>? = opened
            avformat_close_input(&toClose)
            throw DemuxError.openFailed(code: 0, message: "packet allocation failed")
        }
        self.context = opened
        self.packet = packet
        self.io = io
        self.interrupt = interrupt
        streams = Demuxer.describeStreams(opened)
        chapters = Demuxer.describeChapters(opened)
        let reported = opened.pointee.duration
        duration = reported == LexisNoPTS || reported <= 0
            ? 0
            : Double(reported) / Double(LexisTimeBase)
    }

    /// Small enough that a container whose shape is already known reads
    /// far less than a cold probe would; generous enough that a real
    /// stream's own headers still fit comfortably inside it.
    private static let cachedProbeSize: Int64 = 256 * 1024
    private static let cachedAnalyzeDuration: Int64 = 1_000_000
    /// A stream's cold probe, under FFmpeg's 5 MB and 5 s: still every
    /// track's header and the first keyframe, whose probe decode states the
    /// bit depth and the field order, without reading seconds past them.
    private static let coldProbeSize: Int64 = 2 * 1024 * 1024
    private static let coldAnalyzeDuration: Int64 = 2_000_000

    /// Opens and seeks to `resumeAt` BEFORE the first packet read, so a
    /// resume never reads the head first. `analysis`, when given, lowers
    /// the probe's own budget: the container's shape is already known, so
    /// finding it again costs less than a cold probe does. A stream
    /// `MediaStreamIO` hands over is one-shot - `AVIOStream` closes its
    /// real handle on any failure - so there is no second attempt to fall
    /// back to on this same stream; a container that no longer matches
    /// what was cached fails exactly as an uncached open would if it hit
    /// the same trouble, and the caller re-probes (and re-stores) on the
    /// next open the ordinary way.
    public convenience init(
        stream: MediaStreamIO, interrupt: InterruptFlag? = nil,
        analysis: MediaAnalysis?, resumeAt: Double?
    ) throws {
        try self.init(
            stream: stream, interrupt: interrupt, analysis: analysis, resumeAt: resumeAt,
            byteCacheWindow: ByteCache.windowCapacity
        )
    }

    convenience init(
        stream: MediaStreamIO, interrupt: InterruptFlag? = nil,
        analysis: MediaAnalysis?, resumeAt: Double?, byteCacheWindow: Int
    ) throws {
        guard let analysis else {
            try self.init(stream: stream, interrupt: interrupt, byteCacheWindow: byteCacheWindow)
            if let resumeAt { try self.seek(to: resumeAt) }
            return
        }
        let io = try AVIOStream(io: stream, interrupt: interrupt, byteCacheWindow: byteCacheWindow)
        guard let allocated = avformat_alloc_context() else {
            throw DemuxError.openFailed(code: 0, message: "format context allocation failed")
        }
        if let interrupt {
            allocated.pointee.interrupt_callback = AVIOInterruptCB(
                callback: interruptPoll,
                opaque: Unmanaged.passUnretained(interrupt).toOpaque()
            )
        }
        allocated.pointee.pb = io.context
        allocated.pointee.probesize = Demuxer.cachedProbeSize
        allocated.pointee.max_analyze_duration = Demuxer.cachedAnalyzeDuration
        var context: UnsafeMutablePointer<AVFormatContext>? = allocated
        let openCode = avformat_open_input(&context, nil, nil, nil)
        guard openCode == 0, let opened = context else {
            throw io.refusedCredential
                ? DemuxError.unauthorized
                : DemuxError.openFailed(code: openCode, message: DemuxError.message(for: openCode))
        }
        let infoCode = avformat_find_stream_info(opened, nil)
        guard infoCode >= 0 else {
            var toClose: UnsafeMutablePointer<AVFormatContext>? = opened
            avformat_close_input(&toClose)
            throw io.refusedCredential
                ? DemuxError.unauthorized
                : DemuxError.noStreamInfo(code: infoCode, message: DemuxError.message(for: infoCode))
        }
        let described = Demuxer.describeStreams(opened)
        guard described.count == analysis.streams.count else {
            var toClose: UnsafeMutablePointer<AVFormatContext>? = opened
            avformat_close_input(&toClose)
            throw DemuxError.noStreamInfo(
                code: 0, message: "cached analysis no longer matches this container"
            )
        }
        try self.init(io: io, context: opened, interrupt: interrupt, streams: described)
        if let resumeAt { try self.seek(to: resumeAt) }
    }

    /// The tail every open path shares once FFmpeg has a context it
    /// already trusts: packet allocation and property assignment.
    private init(
        io: AVIOStream, context opened: UnsafeMutablePointer<AVFormatContext>,
        interrupt: InterruptFlag?, streams: [MediaStream]
    ) throws {
        guard let packet = av_packet_alloc() else {
            var toClose: UnsafeMutablePointer<AVFormatContext>? = opened
            avformat_close_input(&toClose)
            throw DemuxError.openFailed(code: 0, message: "packet allocation failed")
        }
        self.context = opened
        self.packet = packet
        self.io = io
        self.interrupt = interrupt
        self.streams = streams
        chapters = Demuxer.describeChapters(opened)
        let reported = opened.pointee.duration
        duration = reported == LexisNoPTS || reported <= 0
            ? 0
            : Double(reported) / Double(LexisTimeBase)
    }

    deinit {
        var packet: UnsafeMutablePointer<AVPacket>? = self.packet
        av_packet_free(&packet)
        avformat_close_input(&context)
    }

    /// The next packet, or nil at end of file.
    public func readPacket() throws -> Packet? {
        // av_read_frame requires an already-unreffed packet on this FFmpeg major; it does not unref for us
        av_packet_unref(packet)
        let code = av_read_frame(context, packet)
        if code == LexisErrorEOF {
            return nil
        }
        if code == LexisErrorUnauthorized {
            throw DemuxError.unauthorized
        }
        guard code >= 0 else {
            // the same rule the open paths follow: a container that rewrites
            // the callback's code, as mp4 does after a seek, must not turn a
            // refused credential into a corrupt file
            throw io?.refusedCredential == true
                ? DemuxError.unauthorized
                : DemuxError.readFailed(code: code, message: DemuxError.message(for: code))
        }
        // Moved, not copied: the queue this lands in holds FFmpeg's own buffer,
        // and the decoder it reaches is handed that same buffer back. The
        // buffer argument is evaluated last, after the fields it blanks.
        return Packet(
            streamIndex: packet.pointee.stream_index,
            pts: packet.pointee.pts == LexisNoPTS ? nil : packet.pointee.pts,
            dts: packet.pointee.dts == LexisNoPTS ? nil : packet.pointee.dts,
            isKeyframe: packet.pointee.flags & Int32(AV_PKT_FLAG_KEY) != 0,
            isDisposable: packet.pointee.flags & Int32(AV_PKT_FLAG_DISPOSABLE) != 0,
            duration: packet.pointee.duration,
            buffer: PacketBuffer(moving: packet)
        )
    }

    /// Moves to the keyframe at or before `seconds`, so the next packets can be
    /// decoded from nothing. The window ending at the target is what makes the
    /// seek backward: a renderer that was just flushed has to start on a sync
    /// sample, and a keyframe after the target would skip past what was asked
    /// for.
    ///
    /// Seeking past the end of an mp4 succeeds and lands on its last keyframe,
    /// so a caller that means to stay inside the file clamps first. mp4 also
    /// moves nothing but its own sample index here and seeks the stream when
    /// the next packet is read, so a stream that cannot seek fails there, not
    /// here.
    public func seek(to seconds: Double) throws {
        // Int64(_: Double) traps on a NaN, an infinity or anything past Int64,
        // and a target computed from a duration is one division away from all
        // three. Code 0 marks a failure of ours rather than one of FFmpeg's.
        guard let target = Int64(exactly: (seconds * Double(LexisTimeBase)).rounded(.towardZero))
        else {
            throw DemuxError.seekFailed(code: 0, message: "seek target out of range")
        }
        let code = avformat_seek_file(context, -1, Int64.min, target, target, 0)
        guard code >= 0 else {
            throw DemuxError.seekFailed(code: code, message: DemuxError.message(for: code))
        }
    }

    private static func describeStreams(
        _ context: UnsafeMutablePointer<AVFormatContext>
    ) -> [MediaStream] {
        var result: [MediaStream] = []
        for i in 0..<Int(context.pointee.nb_streams) {
            guard let stream = context.pointee.streams[i],
                  let parameters = stream.pointee.codecpar?.pointee
            else { continue }
            let kind: StreamKind
            switch parameters.codec_type {
            case AVMEDIA_TYPE_VIDEO: kind = .video
            case AVMEDIA_TYPE_AUDIO: kind = .audio
            case AVMEDIA_TYPE_SUBTITLE: kind = .subtitle
            default: kind = .other
            }
            var extradata: Data?
            if let bytes = parameters.extradata, parameters.extradata_size > 0 {
                extradata = Data(bytes: bytes, count: Int(parameters.extradata_size))
            }
            if parameters.codec_id == AV_CODEC_ID_HEVC, let record = extradata, record.count >= 23,
                record[0] == 1, record[22] == 0
            {
                extradata = inBandParameterSets(context, stream: stream.pointee.index, record: record) ?? record
            }
            let disposition = stream.pointee.disposition
            let frameRate = standardFrameRate(stream.pointee.avg_frame_rate)
            var masteringDisplay: Data?
            var contentLight: Data?
            var dolbyVision: DolbyVisionConfiguration?
            // Stream side data lives on the codec parameters in this FFmpeg
            // major, not on the stream.
            for i in 0..<Int(parameters.nb_coded_side_data) {
                let side = parameters.coded_side_data[i]
                guard let data = side.data else { continue }
                switch side.type {
                case AV_PKT_DATA_MASTERING_DISPLAY_METADATA:
                    guard side.size >= MemoryLayout<AVMasteringDisplayMetadata>.size else { break }
                    masteringDisplay = masteringDisplayVolume(
                        data.withMemoryRebound(to: AVMasteringDisplayMetadata.self, capacity: 1) {
                            $0.pointee
                        }
                    )
                case AV_PKT_DATA_CONTENT_LIGHT_LEVEL:
                    guard side.size >= MemoryLayout<AVContentLightMetadata>.size else { break }
                    contentLight = contentLightLevel(
                        data.withMemoryRebound(to: AVContentLightMetadata.self, capacity: 1) {
                            $0.pointee
                        }
                    )
                case AV_PKT_DATA_DOVI_CONF:
                    guard side.size >= MemoryLayout<AVDOVIDecoderConfigurationRecord>.size
                    else { break }
                    let configuration = data.withMemoryRebound(
                        to: AVDOVIDecoderConfigurationRecord.self, capacity: 1
                    ) { $0.pointee }
                    dolbyVision = DolbyVisionConfiguration(
                        profile: configuration.dv_profile,
                        level: configuration.dv_level,
                        hasRPU: configuration.rpu_present_flag != 0,
                        hasEnhancementLayer: configuration.el_present_flag != 0,
                        hasBaseLayer: configuration.bl_present_flag != 0,
                        compatibility: configuration.dv_bl_signal_compatibility_id,
                        record: dolbyVisionRecord(configuration)
                    )
                default:
                    break
                }
            }
            let pixelAspect = kind == .video
                ? av_guess_sample_aspect_ratio(context, stream, nil) : AVRational(num: 0, den: 1)
            result.append(MediaStream(
                index: stream.pointee.index,
                kind: kind,
                codecID: parameters.codec_id.rawValue,
                codecName: String(cString: avcodec_get_name(parameters.codec_id)),
                width: parameters.width,
                height: parameters.height,
                timeBaseNum: stream.pointee.time_base.num,
                timeBaseDen: stream.pointee.time_base.den,
                sampleRate: parameters.sample_rate,
                channels: parameters.ch_layout.nb_channels,
                videoDelay: parameters.video_delay,
                language: Demuxer.metadata(stream, "language"),
                title: Demuxer.metadata(stream, "title"),
                isDefault: disposition & LexisDispositionDefault != 0,
                isForced: disposition & LexisDispositionForced != 0,
                colorPrimaries: Int32(bitPattern: parameters.color_primaries.rawValue),
                colorTransfer: Int32(bitPattern: parameters.color_trc.rawValue),
                colorMatrix: Int32(bitPattern: parameters.color_space.rawValue),
                isFullRange: parameters.color_range == AVCOL_RANGE_JPEG,
                masteringDisplay: masteringDisplay,
                contentLight: contentLight,
                dolbyVision: dolbyVision,
                extradata: extradata,
                frameRateNum: frameRate.num,
                frameRateDen: frameRate.den,
                bitsPerSecond: max(0, parameters.bit_rate),
                fieldOrder: Int32(parameters.field_order.rawValue),
                bitDepth: lumaBitDepth(parameters),
                pixelAspectNum: pixelAspect.num,
                pixelAspectDen: pixelAspect.den,
                chromaLocation: Int32(bitPattern: parameters.chroma_location.rawValue)
            ))
        }
        return result
    }

    /// `record`, an hvcC naming no parameter set, completed with the VPS, SPS
    /// and PPS the stream's first packet carries in band: VideoToolbox builds
    /// no session from the bare header. Reads from the head and seeks back to
    /// it; nil, and nothing to rely on, when that packet carries none.
    private static func inBandParameterSets(
        _ context: UnsafeMutablePointer<AVFormatContext>, stream index: Int32, record: Data
    ) -> Data? {
        guard let packet = av_packet_alloc() else { return nil }
        defer {
            var owned: UnsafeMutablePointer<AVPacket>? = packet
            av_packet_free(&owned)
            let start = context.pointee.start_time == LexisNoPTS ? 0 : context.pointee.start_time
            avformat_seek_file(context, -1, Int64.min, start, start, 0)
        }
        // other tracks interleave ahead of it; a stream with no packet near
        // the head is left as it is rather than read to its end
        var read = 0
        while read < 256 {
            guard av_read_frame(context, packet) >= 0 else { return nil }
            read += 1
            if packet.pointee.stream_index == index { break }
            av_packet_unref(packet)
        }
        guard packet.pointee.stream_index == index, let data = packet.pointee.data else { return nil }
        let size = Int(packet.pointee.size)
        let lengthSize = Int(record[21] & 0x03) + 1
        // VPS, SPS and PPS, in the order the hvcC lists its arrays
        var sets: [[Data]] = [[], [], []]
        var offset = 0
        while offset + lengthSize <= size {
            var length = 0
            for byte in 0..<lengthSize { length = length << 8 | Int(data[offset + byte]) }
            offset += lengthSize
            guard length > 0, offset + length <= size else { break }
            let type = Int(data[offset] >> 1) & 0x3F
            if (32...34).contains(type) { sets[type - 32].append(Data(bytes: data + offset, count: length)) }
            offset += length
        }
        guard sets.allSatisfy({ !$0.isEmpty }) else { return nil }
        var completed = record.prefix(22)
        completed.append(3)
        for (order, units) in sets.enumerated() {
            completed.append(0x80 | UInt8(32 + order))
            completed.append(contentsOf: [UInt8(units.count >> 8), UInt8(units.count & 0xFF)])
            for unit in units {
                completed.append(contentsOf: [UInt8(unit.count >> 8), UInt8(unit.count & 0xFF)])
                completed.append(unit)
            }
        }
        return completed
    }

    /// The container's own figure where it states one, the pixel format's
    /// where stream probing filled that in instead: matroska says nothing
    /// itself, and the probe decode is what learns a track is ten bit.
    /// The exact rate a container rounded: Matroska states a frame's
    /// duration in whole nanoseconds, so 23.976 arrives as 23185/967 rather
    /// than 24000/1001, and a frame grid built on that drifts off the real
    /// timestamps within minutes. A rate within 0.05% of an NTSC or whole
    /// rate is taken to be it; any other is left as stated.
    private static func standardFrameRate(_ rate: AVRational) -> (num: Int32, den: Int32) {
        guard rate.num > 0, rate.den > 0 else { return (rate.num, rate.den) }
        let fps = Double(rate.num) / Double(rate.den)
        let tolerance = 0.0005
        let whole = fps.rounded()
        if whole >= 1, abs(fps - whole) <= whole * tolerance {
            return (Int32(whole), 1)
        }
        let ntsc = (fps * 1.001).rounded()
        if ntsc >= 1, abs(fps * 1.001 - ntsc) <= ntsc * tolerance {
            return (Int32(ntsc) * 1000, 1001)
        }
        return (rate.num, rate.den)
    }

    private static func lumaBitDepth(_ parameters: AVCodecParameters) -> Int32 {
        if parameters.bits_per_raw_sample > 0 { return parameters.bits_per_raw_sample }
        guard parameters.codec_type == AVMEDIA_TYPE_VIDEO,
            let descriptor = av_pix_fmt_desc_get(AVPixelFormat(rawValue: parameters.format))
        else { return 0 }
        return Int32(descriptor.pointee.comp.0.depth)
    }

    private static func describeChapters(
        _ context: UnsafeMutablePointer<AVFormatContext>
    ) -> [Chapter] {
        var result: [Chapter] = []
        for i in 0..<Int(context.pointee.nb_chapters) {
            guard let chapter = context.pointee.chapters[i] else { continue }
            let timeBase = chapter.pointee.time_base
            guard timeBase.den != 0 else { continue }
            let start = Double(chapter.pointee.start) * Double(timeBase.num) / Double(timeBase.den)
            var title = ""
            if let entry = av_dict_get(chapter.pointee.metadata, "title", nil, 0),
                let value = entry.pointee.value
            {
                title = String(cString: value)
            }
            result.append(Chapter(start: start, title: title))
        }
        return result
    }

    /// A metadata entry of the stream, empty when it has none. The dictionary
    /// belongs to the format context and its strings live as long as it does,
    /// so they are copied out here.
    private static func metadata(_ stream: UnsafeMutablePointer<AVStream>, _ key: String) -> String {
        guard let entry = av_dict_get(stream.pointee.metadata, key, nil, 0),
              let value = entry.pointee.value
        else { return "" }
        return String(cString: value)
    }
}

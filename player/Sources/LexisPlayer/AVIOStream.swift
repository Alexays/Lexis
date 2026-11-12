import CFFmpeg
import Foundation

/// What the AVIO callbacks see through their opaque pointer.
private final class StreamBox {
    let io: MediaStreamIO
    let interrupt: InterruptFlag?
    /// Written by the read callback, read by the demuxer that called into
    /// FFmpeg: the callbacks run synchronously on that same thread.
    var refusedCredential = false

    init(_ io: MediaStreamIO, _ interrupt: InterruptFlag?) {
        self.io = io
        self.interrupt = interrupt
    }
}

/// What `MediaStreamIO.read` answers when the credential was refused. The C
/// ABI's own constant lives in the core's header, which the player does not
/// include: the value is the contract.
private let LexisErrorUnauthorizedRead: Int64 = -2

/// Returning 0 makes FFmpeg 6 and later call again forever, so the end of the
/// stream has to be AVERROR_EOF.
private let readPacket: @convention(c) (
    UnsafeMutableRawPointer?, UnsafeMutablePointer<UInt8>?, Int32
) -> Int32 = { opaque, buffer, size in
    guard let opaque, let buffer, size > 0 else { return LexisErrorIO }
    let box = Unmanaged<StreamBox>.fromOpaque(opaque).takeUnretainedValue()
    // the only place bytes enter FFmpeg, so it is the cancellation point that
    // holds whatever FFmpeg is doing above it
    if box.interrupt?.isRaised == true { return LexisErrorExit }
    let count = box.io.read(box.io.handle, buffer, size)
    // clamping, not a trap: the count is an Int64 the stream chose, and it can
    // never exceed `size` anyway
    if count > 0 { return Int32(clamping: count) }
    if count == 0 { return LexisErrorEOF }
    // -2 is the stream's own code for a refused credential; keeping it
    // distinct here is what lets the app tell a stale token from a dead link
    guard count == LexisErrorUnauthorizedRead else { return LexisErrorIO }
    // the returned code does not always survive: a refusal during the mp4
    // header parse comes back out of avformat_open_input as invalid data
    box.refusedCredential = true
    return LexisErrorUnauthorized
}

private let seekPacket: @convention(c) (UnsafeMutableRawPointer?, Int64, Int32) -> Int64 = {
    opaque, offset, whence in
    guard let opaque else { return Int64(LexisErrorIO) }
    let box = Unmanaged<StreamBox>.fromOpaque(opaque).takeUnretainedValue()
    // the same cancellation point the read callback carries: a stop during a
    // seek must not wait out a stalled server
    if box.interrupt?.isRaised == true { return Int64(LexisErrorExit) }
    // AVSEEK_FORCE is an advisory bit on top of the whence value
    let kind = whence & ~LexisSeekForce
    let result = kind == LexisSeekSize
        ? box.io.size(box.io.handle)
        : box.io.seek(box.io.handle, offset, kind)
    // A bare -1 is AVERROR(EPERM) to FFmpeg, which would describe an
    // unreachable server as an operation it was not allowed to perform.
    return result < 0 ? Int64(LexisErrorIO) : result
}

/// An AVIOContext reading through a `MediaStreamIO`, and the owner of both.
/// Freeing it closes the stream, so a demuxer that took one keeps it alive for
/// exactly as long as it reads.
final class AVIOStream {
    /// One Plex range chunk, so a demuxer's small reads mostly land in memory.
    static let bufferSize = 256 * 1024

    let context: UnsafeMutablePointer<AVIOContext>
    private let box: StreamBox
    /// A sliding window around the demuxer's own read position: prefetches
    /// ahead of it, and serves a backward seek inside the window for free.
    private let byteCache: ByteCache
    private let io: MediaStreamIO

    /// Whether the stream ever refused the credential, which outlives the error
    /// code FFmpeg answers with.
    var refusedCredential: Bool { box.refusedCredential }
    /// What the byte cache underneath this stream has measured: throughput,
    /// fetch latency, window hits.
    var byteCacheStatistics: ByteCacheStatistics { byteCache.statistics }

    init(
        io realStream: MediaStreamIO, interrupt: InterruptFlag? = nil,
        byteCacheWindow: Int = ByteCache.windowCapacity
    ) throws {
        let byteCache = ByteCache(
            io: realStream, interrupt: interrupt, windowCapacity: byteCacheWindow)
        let io = byteCache.stream
        // av_malloc'd because avio may reallocate it; it is freed through the
        // context's own buffer field, never through this pointer
        guard let buffer = av_malloc(AVIOStream.bufferSize) else {
            io.close(io.handle)
            throw DemuxError.openFailed(code: 0, message: "avio buffer allocation failed")
        }
        let box = StreamBox(io, interrupt)
        guard let context = avio_alloc_context(
            buffer.assumingMemoryBound(to: UInt8.self),
            Int32(AVIOStream.bufferSize),
            0,
            Unmanaged.passUnretained(box).toOpaque(),
            readPacket,
            nil,
            seekPacket
        ) else {
            av_free(buffer)
            io.close(io.handle)
            throw DemuxError.openFailed(code: 0, message: "avio context allocation failed")
        }
        self.context = context
        self.box = box
        self.byteCache = byteCache
        self.io = io
    }

    deinit {
        // avio_context_free frees the context and nothing else, and the buffer
        // it holds now may not be the one that was handed to it
        av_freep(&self.context.pointee.buffer)
        var context: UnsafeMutablePointer<AVIOContext>? = self.context
        avio_context_free(&context)
        io.close(io.handle)
    }
}

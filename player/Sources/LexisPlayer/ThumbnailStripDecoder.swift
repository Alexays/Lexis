import CoreGraphics
import CoreMedia
import Foundation
import VideoToolbox

public enum ThumbnailStripError: Error, Equatable {
    case noVideoStream
}

/// A lightweight parallel decode path for scrub thumbnails: its own
/// `Demuxer` over its own stream, seeking to the keyframe at or before each
/// requested second and decoding it through a dedicated VideoToolbox
/// session scaled down at decode time (`VideoDecoder`'s own `scaledSize`,
/// so nothing here runs swscale).
///
/// Deliberately never touches `PlaybackActivityGate`: the gate exists to
/// keep two real decode sessions off each other (a playing film and the
/// bench's decode-only probe), but a scrub has to work WHILE a film is
/// already playing, which the gate would otherwise refuse outright. This
/// stays safe to run alongside a playing film precisely because it is
/// lightweight and separate - its own file handle, its own small scaled
/// buffer, one frame decoded at a time - never because it asked the gate
/// for permission.
public final class ThumbnailStripDecoder {
    private let demuxer: Demuxer
    private let videoStream: MediaStream
    private let interrupt: InterruptFlag
    private let queue = DispatchQueue(label: "org.lexis.player.thumbnailstrip", qos: .utility)

    private let lock = NSLock()
    private var latestFrame: DecodedFrame?
    private var decoder: VideoDecoder?

    /// A strip's own window of the stream: sparse seeks, one keyframe read
    /// after each, so one span is all a seek fetches before the reader asks
    /// for more. A wider window is bandwidth the playing film next door pays.
    static let byteCacheWindow = ByteCache.spanSize

    /// The keyframe last decoded, by its timestamp: neighbouring seconds of a
    /// scrub land on the same one. Touched only from `queue`.
    private var lastKeyframe: (pts: Int64, second: Double?, image: CGImage)?
    /// The video stream's indexed keyframes in seconds, ascending, read at open.
    private let keyframes: [Double]

    /// `height` is every picture's own; the width follows the stream's aspect ratio.
    public init(stream: MediaStreamIO, analysis: MediaAnalysis?, height: Int = 240) throws {
        let interrupt = InterruptFlag()
        let demuxer = try Demuxer(
            stream: stream, interrupt: interrupt, analysis: analysis, resumeAt: nil,
            byteCacheWindow: ThumbnailStripDecoder.byteCacheWindow
        )
        guard let video = demuxer.streams.first(where: { $0.kind == .video }) else {
            throw ThumbnailStripError.noVideoStream
        }
        self.demuxer = demuxer
        self.videoStream = video
        keyframes = demuxer.keyframeTable
        self.interrupt = interrupt
        let format = try makeFormatDescription(for: video)
        let width = video.height > 0
            ? max(2, Int((Double(video.width) / Double(video.height) * Double(height)).rounded()))
            : height
        // BGRA, converted by the decoder from whatever the stream is: a ten
        // bit or lossless picture read through CoreImage came out with its
        // planes misread - green bars, and a picture wider than the frame.
        // VideoToolbox converts with the stream's own colour tags and the
        // image is made straight from the buffer.
        decoder = try VideoDecoder(
            formatDescription: format, pixelFormat: kCVPixelFormatType_32BGRA,
            scaledSize: (width: width, height: height)
        ) { [weak self] frame in
            guard let self else { return }
            self.lock.lock()
            self.latestFrame = frame
            self.lock.unlock()
        }
    }

    /// Decodes the keyframe at or before each of `seconds`, off the caller's
    /// thread; `completion` runs once with whatever landed, keyed by the
    /// second it was asked for. A second nothing could decode for (past the
    /// stream's own end, or abandoned by `cancel()`) is simply missing from
    /// the result, never a placeholder.
    ///
    /// Only the newest request is served: one still waiting when another
    /// arrives is answered empty at once, and one being decoded stops at its
    /// next target. A scrub asks as fast as the hand moves, and a backlog of
    /// frames it has already moved past would drain on the film's link.
    public func strip(at seconds: [Double], completion: @escaping ([Double: CGImage]) -> Void) {
        lock.lock()
        latest &+= 1
        let superseded = wanted
        wanted = (seconds, completion)
        lock.unlock()
        superseded?.completion([:])
        queue.async { [weak self] in
            guard let self else { return }
            // A later call's block may already have taken this request: the
            // queue holds one block per call and each takes the newest.
            self.lock.lock()
            let request = self.wanted
            let serial = self.latest
            self.wanted = nil
            self.lock.unlock()
            guard let request else { return }
            var result: [Double: CGImage] = [:]
            for target in request.seconds {
                if self.interrupt.isRaised { break }
                // a film that is rebuffing has first claim on the link: a
                // strip request parks here until the bridge stands it back
                // up, which is what makes this path polite without ever
                // asking the playback gate for permission
                var parked = false
                repeat {
                    self.lock.lock()
                    parked = self.suspended
                    self.lock.unlock()
                    guard parked else { break }
                    Thread.sleep(forTimeInterval: 0.05)
                } while !self.interrupt.isRaised
                if self.interrupt.isRaised { break }
                self.lock.lock()
                let current = self.latest == serial
                self.lock.unlock()
                guard current else { break }
                if let image = self.decodeKeyframe(at: target) {
                    result[target] = image
                }
            }
            request.completion(result)
        }
    }

    /// Answers the request still waiting, if any, with nothing, and stops the
    /// one being decoded at its next target. A committed seek calls this: the
    /// film is refilling, and the frames a finished scrub asked for are not
    /// worth a byte of its link. Safe to call from any thread.
    public func dropPending() {
        lock.lock()
        latest &+= 1
        let pending = wanted
        wanted = nil
        lock.unlock()
        pending?.completion([:])
    }

    /// The request the next free turn of `queue` serves, and the count of
    /// requests and drops so far, which is how a strip being decoded learns
    /// it is no longer the newest. Under `lock`.
    private var wanted: (seconds: [Double], completion: ([Double: CGImage]) -> Void)?
    private var latest: UInt64 = 0
    private var suspended = false

    /// Pauses and resumes whatever `strip(at:)` is doing between targets.
    /// The bridge drives this off the engine's buffering transitions: during
    /// a rebuffer the film needs every byte on the link, and a scrub can wait
    /// half a second for them. Safe to call from any thread.
    public func setSuspended(_ value: Bool) {
        lock.lock()
        suspended = value
        lock.unlock()
    }

    /// Abandons whatever `strip(at:)` is still doing, at its next
    /// cancellation point - the same one-outstanding-read bound
    /// `InterruptFlag` already carries for a blocked network read.
    public func cancel() {
        interrupt.raise()
    }

    private func decodeKeyframe(at target: Double) -> CGImage? {
        guard let decoder else { return nil }
        // The keyframe the seek lands on, when the index brackets the target:
        // the neighbouring seconds of a scrub then cost no seek and no read.
        var low = 0, high = keyframes.count
        while low < high {
            let middle = (low + high) / 2
            if keyframes[middle] <= target { low = middle + 1 } else { high = middle }
        }
        let landing = low > 0 && low < keyframes.count ? keyframes[low - 1] : nil
        if let landing, let lastKeyframe, lastKeyframe.second == landing { return lastKeyframe.image }
        do {
            try demuxer.seek(to: target)
            guard let packet = try nextVideoPacket() else { return nil }
            if let pts = packet.pts, let lastKeyframe, lastKeyframe.pts == pts {
                self.lastKeyframe = (pts, landing, lastKeyframe.image)
                return lastKeyframe.image
            }
            let sample = try makeSampleBuffer(
                packet: packet, formatDescription: decoder.formatDescription,
                timeBaseNum: videoStream.timeBaseNum, timeBaseDen: videoStream.timeBaseDen
            )
            lock.lock()
            latestFrame = nil
            lock.unlock()
            try decoder.decode(sample)
            // A keyframe carries no reference, so this one call always waits
            // for exactly the frame just fed, never one from an earlier
            // target still in flight.
            decoder.waitForPendingFrames()
            lock.lock()
            let frame = latestFrame
            lock.unlock()
            guard let frame else { return nil }
            var image: CGImage?
            guard VTCreateCGImageFromCVPixelBuffer(frame.imageBuffer, options: nil, imageOut: &image) == noErr,
                let image
            else { return nil }
            if let pts = packet.pts { lastKeyframe = (pts, landing, image) }
            return image
        } catch {
            return nil
        }
    }

    private func nextVideoPacket() throws -> Packet? {
        while let packet = try demuxer.readPacket() {
            if packet.streamIndex == videoStream.index { return packet }
        }
        return nil
    }
}

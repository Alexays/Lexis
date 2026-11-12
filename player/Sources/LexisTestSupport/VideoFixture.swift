import AVFoundation
import CoreVideo
import Foundation

public enum VideoFixtureError: Error {
    case writerFailed(String)
}

/// The writer pulls its data on its own queues, and those blocks cannot capture
/// mutable locals, so each input's progress lives here. Every field belongs to
/// one queue except `failure` and `appends`, which the lock covers.
private final class FixtureProgress: @unchecked Sendable {
    var frameIndex = 0
    var sampleIndex = 0
    var phase = 0.0

    private let lock = NSLock()
    private var failure: String?
    private var appendCount = 0

    func fail(_ reason: String) {
        lock.lock()
        if failure == nil { failure = reason }
        lock.unlock()
    }

    var reason: String? {
        lock.lock()
        defer { lock.unlock() }
        return failure
    }

    func appended() {
        lock.lock()
        appendCount += 1
        lock.unlock()
    }

    var appends: Int {
        lock.lock()
        defer { lock.unlock() }
        return appendCount
    }
}

/// Writes `frameCount` solid-color frames into an .mp4 and returns its URL.
/// The colors cycle so consecutive frames differ and the encoder emits real
/// inter frames instead of collapsing everything into one.
///
/// `noisy` fills the frames with noise instead. It costs a few hundred
/// kilobytes a frame rather than a few hundred bytes, which is what a test
/// needs when playback has to keep reading rather than fit in a buffer.
///
/// `audio` adds a 48 kHz AAC track of a sine at `audioFrequency`, as long as
/// the video.
public func makeVideoFixture(
    directory: URL,
    name: String,
    codec: AVVideoCodecType,
    width: Int,
    height: Int,
    frameCount: Int,
    fps: Int32,
    noisy: Bool = false,
    audio: Bool = false,
    channels: Int = 2,
    audioFrequency: Double = 440,
    /// Forces a keyframe every `gopSize` frames, so a test that reads the
    /// keyframe table back knows exactly where each one lands. nil leaves
    /// the encoder's own placement, which is not test-predictable.
    gopSize: Int? = nil,
    /// Target video bits per second. What a fixture standing in for a real
    /// film needs: seconds of content and megabytes of it have to line up,
    /// or a buffer measured in seconds means nothing.
    bitrate: Int? = nil
) throws -> URL {
    let key = """
        video|\(codec.rawValue)|\(width)x\(height)|\(frameCount)@\(fps)|noisy:\(noisy)\
        |audio:\(audio)|channels:\(channels)|frequency:\(audioFrequency)\
        |gop:\(gopSize.map(String.init) ?? "-")|bitrate:\(bitrate.map(String.init) ?? "-")
        """
    return try cachedFixture(key: key, at: fixtureURL(in: directory, named: name)) { url in
        try writeVideoFixture(
            to: url, codec: codec, width: width, height: height, frameCount: frameCount,
            fps: fps, noisy: noisy, audio: audio, channels: channels,
            audioFrequency: audioFrequency, gopSize: gopSize, bitrate: bitrate
        )
    }
}

private func writeVideoFixture(
    to url: URL,
    codec: AVVideoCodecType,
    width: Int,
    height: Int,
    frameCount: Int,
    fps: Int32,
    noisy: Bool,
    audio: Bool,
    channels: Int,
    audioFrequency: Double,
    gopSize: Int?,
    bitrate: Int?
) throws {
    let sampleRate = 48000.0
    try? FileManager.default.removeItem(at: url)

    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    var videoSettings: [String: Any] = [
        AVVideoCodecKey: codec,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
    ]
    var compression: [String: Any] = [:]
    if let gopSize {
        compression[AVVideoMaxKeyFrameIntervalKey] = gopSize
        compression[AVVideoAllowFrameReorderingKey] = false
    }
    if let bitrate {
        compression[AVVideoAverageBitRateKey] = bitrate
    }
    if !compression.isEmpty {
        videoSettings[AVVideoCompressionPropertiesKey] = compression
    }
    let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
    videoInput.expectsMediaDataInRealTime = false
    let pixelBufferAttributes: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
    ]
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: videoInput,
        sourcePixelBufferAttributes: pixelBufferAttributes
    )
    // Frames come from a pool this function owns, not from `adaptor
    // .pixelBufferPool`. The adaptor's pool belongs to the writer, which
    // replaces it partway through the write once its compression session comes
    // up and tears it down on its own queues; a frame that allocates from it
    // meanwhile has died with a null attributes dictionary inside
    // CVPixelBufferPoolCreatePixelBuffer. A pool nothing else holds cannot go
    // out from under the writer thread.
    var createdPool: CVPixelBufferPool?
    guard CVPixelBufferPoolCreate(
        kCFAllocatorDefault, nil, pixelBufferAttributes as CFDictionary, &createdPool
    ) == kCVReturnSuccess, let pool = createdPool else {
        throw VideoFixtureError.writerFailed("cannot create the pixel buffer pool")
    }
    guard writer.canAdd(videoInput) else {
        throw VideoFixtureError.writerFailed("cannot add the video input")
    }
    writer.add(videoInput)

    var audioInput: AVAssetWriterInput?
    var audioFormat: CMAudioFormatDescription?
    if audio {
        let input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: 128_000,
            ]
        )
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else {
            throw VideoFixtureError.writerFailed("cannot add the audio input")
        }
        writer.add(input)
        audioInput = input

        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * channels),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(4 * channels),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &audioFormat
        ) == noErr else {
            throw VideoFixtureError.writerFailed("cannot describe the PCM input")
        }
    }

    guard writer.startWriting() else {
        throw VideoFixtureError.writerFailed(String(describing: writer.error))
    }
    writer.startSession(atSourceTime: .zero)

    // The writer pulls. Pushing both inputs from one loop deadlocks: an input
    // that gets ahead climbs above its high water level, and from there the
    // muxer drains neither. Measured, and not reliably enough to keep a loop.
    let progress = FixtureProgress()
    let group = DispatchGroup()

    group.enter()
    videoInput.requestMediaDataWhenReady(on: DispatchQueue(label: "org.lexis.fixture.video")) {
        while videoInput.isReadyForMoreMediaData {
            // Bail on a failed writer here too: it may fail while this block is
            // not scheduled, and then nothing else would ever leave the group.
            guard writer.status == .writing else {
                progress.fail(String(describing: writer.error))
                videoInput.markAsFinished()
                group.leave()
                return
            }
            if progress.frameIndex >= frameCount {
                videoInput.markAsFinished()
                group.leave()
                return
            }
            var buffer: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard status == kCVReturnSuccess, let pixelBuffer = buffer else {
                progress.fail("pixel buffer allocation failed")
                videoInput.markAsFinished()
                group.leave()
                return
            }
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
                let bytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
                    * CVPixelBufferGetHeight(pixelBuffer)
                if noisy {
                    // xorshift rather than a system generator: this runs over
                    // millions of pixels a frame, and the bytes only have to be
                    // incompressible, not unpredictable
                    var state = UInt32(truncatingIfNeeded: progress.frameIndex &* 2_654_435_761 &+ 1)
                    let words = base.assumingMemoryBound(to: UInt32.self)
                    for word in 0..<(bytes / 4) {
                        state ^= state << 13
                        state ^= state >> 17
                        state ^= state << 5
                        words[word] = state
                    }
                } else {
                    memset(base, Int32(20 + (progress.frameIndex * 40) % 200), bytes)
                }
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            let time = CMTime(value: CMTimeValue(progress.frameIndex), timescale: fps)
            guard adaptor.append(pixelBuffer, withPresentationTime: time) else {
                progress.fail(String(describing: writer.error))
                videoInput.markAsFinished()
                group.leave()
                return
            }
            progress.frameIndex += 1
            progress.appended()
        }
    }

    if let audioInput, let audioFormat {
        let totalSamples = Int(sampleRate * Double(frameCount) / Double(fps))
        group.enter()
        audioInput.requestMediaDataWhenReady(on: DispatchQueue(label: "org.lexis.fixture.audio")) {
            while audioInput.isReadyForMoreMediaData {
                guard writer.status == .writing else {
                    progress.fail(String(describing: writer.error))
                    audioInput.markAsFinished()
                    group.leave()
                    return
                }
                if progress.sampleIndex >= totalSamples {
                    audioInput.markAsFinished()
                    group.leave()
                    return
                }
                let count = min(1024, totalSamples - progress.sampleIndex)
                var samples = [Float](repeating: 0, count: count * channels)
                for frame in 0..<count {
                    let value = Float(sin(progress.phase) * 0.25)
                    progress.phase += 2 * Double.pi * audioFrequency / sampleRate
                    for channel in 0..<channels {
                        samples[frame * channels + channel] = value
                    }
                }
                let byteCount = samples.count * 4
                var block: CMBlockBuffer?
                guard CMBlockBufferCreateWithMemoryBlock(
                    allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
                    blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                    dataLength: byteCount, flags: 0, blockBufferOut: &block
                ) == noErr, let block else {
                    progress.fail("audio block buffer failed")
                    audioInput.markAsFinished()
                    group.leave()
                    return
                }
                samples.withUnsafeBytes { raw in
                    _ = CMBlockBufferReplaceDataBytes(
                        with: raw.baseAddress!, blockBuffer: block,
                        offsetIntoDestination: 0, dataLength: byteCount
                    )
                }
                var timing = CMSampleTimingInfo(
                    duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
                    presentationTimeStamp: CMTime(
                        value: CMTimeValue(progress.sampleIndex),
                        timescale: CMTimeScale(sampleRate)
                    ),
                    decodeTimeStamp: .invalid
                )
                var sample: CMSampleBuffer?
                guard CMSampleBufferCreateReady(
                    allocator: kCFAllocatorDefault, dataBuffer: block,
                    formatDescription: audioFormat, sampleCount: count,
                    sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                    sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample
                ) == noErr, let sample else {
                    progress.fail("audio sample buffer failed")
                    audioInput.markAsFinished()
                    group.leave()
                    return
                }
                guard audioInput.append(sample) else {
                    progress.fail(String(describing: writer.error))
                    audioInput.markAsFinished()
                    group.leave()
                    return
                }
                progress.sampleIndex += count
                progress.appended()
            }
        }
    }

    // An unbounded wait would park the whole test process, and silently, if an
    // input ever stops being fed without leaving the group. That is the only
    // thing this bound is for, so it counts appends rather than elapsed time: a
    // budget for the whole write grows with the fixture and with whatever else
    // on the machine holds the video encoder, and it fires on a writer that is
    // still feeding perfectly well.
    let idleLimit = 120
    var lastAppends = -1
    var idleSeconds = 0
    while group.wait(timeout: .now() + 1) == .timedOut {
        let appends = progress.appends
        idleSeconds = appends == lastAppends ? idleSeconds + 1 : 0
        lastAppends = appends
        if idleSeconds >= idleLimit {
            preconditionFailure(
                "fixture writer stalled: no append in \(idleLimit) s after \(appends), "
                    + "status \(writer.status.rawValue), "
                    + "error \(String(describing: writer.error))"
            )
        }
    }
    if let reason = progress.reason {
        writer.cancelWriting()
        throw VideoFixtureError.writerFailed(reason)
    }
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    done.wait()
    guard writer.status == .completed else {
        throw VideoFixtureError.writerFailed(String(describing: writer.error))
    }
}

import CoreVideo
import Foundation

/// What the operating system will still hand this process before jetsam takes
/// it, asked rather than assumed. An Apple TV with 4 GB and one with four
/// times that answer differently, and so does the same Apple TV with the
/// library still mounted behind the film - which is the point: no figure
/// derived from this needs revisiting when either changes.
///
/// Two cases have no jetsam figure to give, and they take the same fallback.
/// macOS has neither the call nor jetsam at all. And the call answers 0
/// whenever the limit cannot be read - a simulator whose runningboardd loaded
/// no jetsam database is the everyday one, measured returning 0 on tvOS 26.5.
/// A zero there means "I cannot tell you", never "you have none": read
/// literally it makes the allowance 0, and every film is refused as too large
/// before a single track is looked at.
///
/// So the fallback is a share of the machine's own memory, which
/// `ProcessInfo` always answers and which still adapts to the device the way
/// asking the OS was meant to. A quarter, of which the pipeline then claims
/// half: an eighth of a 4 GB Apple TV is far above the floor an ordinary film
/// needs and far below what jetsam would take the process for.
public func availableMemoryBytes() -> Int {
    let shareOfMachine = Int(ProcessInfo.processInfo.physicalMemory / 4)
    #if os(macOS)
    return shareOfMachine
    #else
    let stated = os_proc_available_memory()
    return stated > 0 ? stated : shareOfMachine
    #endif
}

/// What this process is currently charged for, which is the figure jetsam
/// weighs and the one `os_proc_available_memory` is the headroom above.
/// 0 when the kernel will not answer, so a reading of 0 is "unknown" and
/// never "nothing resident".
public func footprintBytes() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
}

/// One picture of this size in this format, measured off a real buffer rather
/// than computed from the format's own bits per pixel: only CoreVideo knows
/// the row padding it chose, and a budget wrong by that padding is wrong on
/// every frame of the film at once.
///
/// A format CoreVideo will not allocate falls back to eight bytes a pixel,
/// which is the widest picture this pipeline ever produces (`64RGBAHalf`, the
/// tone mapper's own output): a picture that cannot be weighed is assumed to
/// be the most expensive kind rather than the cheapest.
func decodedPictureBytes(width: Int, height: Int, pixelFormat: OSType) -> Int {
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault, width, height, pixelFormat, nil, &buffer
    )
    guard status == kCVReturnSuccess, let buffer else { return width * height * 8 }
    return CVPixelBufferGetDataSize(buffer)
}

/// What one decoded picture of this stream is made of on the path it will
/// actually take, or nil where nothing in this process decodes it and the
/// sample queue carries compressed samples instead. Asked twice - by the
/// budget, to weigh a picture, and by the engine, to build the decoder that
/// makes them - and the two must not be able to disagree.
///
/// - Parameter toneMapPixelFormat: what the mapper will store a picture as on
///   this screen, or nil on the paths that do not map at all.
public func pictureFormat(for stream: MediaStream, toneMapPixelFormat: OSType?) -> OSType? {
    if let toneMapPixelFormat { return toneMapPixelFormat }
    // An interlaced track rides the hardware path like any other the decoder
    // can take, and its fields are built up on the GPU (`VideoPath
    // .deinterlaced`): a cadence no software decode and bob on this box can
    // promise. The software path below stays for codecs with no hardware
    // support at all.
    guard hardwareDecodes(stream) != true else { return nil }
    // dav1d hands a ten bit track back as planar ten bit; the biplanar
    // video-range format is the shape the display layer takes it in, filled
    // by the software decoder's copy-out path.
    return stream.bitDepth == 10
        ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        : kCVPixelFormatType_420YpCbCr8Planar
}

/// A film this device has not got the memory to play. Thrown by `open`, where
/// it costs the viewer a sentence rather than the process its life.
public enum PlaybackMemoryError: Error, Equatable {
    case tooLargeForMemory(requiredBytes: Int, allowedBytes: Int)
}

/// Why a film cannot be played on this device at this moment, in the two
/// numbers that say it.
struct MemoryShortfall: Equatable {
    /// What the pipeline needs at its floor: the pictures it cannot hold
    /// fewer of, and the read-ahead below which the buffer is starved by the
    /// engine's own reckoning.
    let requiredBytes: Int
    /// What it was allowed to claim.
    let allowedBytes: Int
}

/// Every byte ceiling the pipeline holds itself to, derived at open from two
/// things that can be asked instead of assumed: what this device will still
/// give the process, and what this film's own pictures and packets cost.
///
/// Seconds stay the unit the pipeline reasons in, because seconds are what
/// playback needs - a second of read-ahead absorbs a second of network
/// hiccup whatever the bitrate. Bytes are only the clamp. So a film whose
/// seconds cost more than the device affords holds fewer of them rather than
/// dying, and the same film on a device with more headroom holds more, with
/// nobody editing a constant: 8K costs four times 4K and the arithmetic does
/// not care which it was handed.
struct PipelineBudget {
    /// What share of what is available the pipeline may claim.
    ///
    /// The rest of the process does not stop while a film plays: the screens
    /// that browsed to here and the image cache they filled are all still
    /// resident, and none of them announce themselves to this code. Half is
    /// also the margin on `picturesHeldOutsideTheQueue` below, which is
    /// measured at one resolution and applied at every other. This is the one
    /// figure here that is a judgement rather than a
    /// measurement, and it is deliberately the only one.
    static let claimedShareOfAvailable = 0.5

    /// How many pictures the pipeline holds outside the sample queue:
    /// VideoToolbox's own decoded pool, the tone mapper's output pool, the
    /// reorder window, and whatever the renderer is still holding until each
    /// picture's time comes due. None of them can be bounded from here, so
    /// the budget pays for them before it hands anything to the queues.
    ///
    /// Measured, not guessed: on a 1920x1080 PQ fixture paced to 30 fps the
    /// process peak tracked the sample queue's ceiling one for one - 32 MB of
    /// ceiling gave a 137 MB peak, 128 MB gave 232 MB - over a floor of
    /// 105 MB that did not move with it. That floor is 6.6 pictures of that
    /// stream, rounded up.
    static let picturesHeldOutsideTheQueue = 7

    /// What share of the pipeline's own allowance the picture queue may take.
    ///
    /// A picture queue absorbs decode jitter and nothing else. A dip in the
    /// network is the packet queue's business, and it does that job eight
    /// seconds deep for a four-hundredth of the price: on a 3 Mbps film the
    /// two cost 3 MiB and 759 MiB respectively for the same playback. A queue
    /// that swallows the whole allowance has therefore bought no protection,
    /// it has only left nothing for everything the budget cannot see - and on
    /// the upscaled path that is what jetsam takes the process for.
    ///
    /// A share and not a picture count, deliberately. A count bites at every
    /// picture size, including the ones where a deep queue costs nothing and
    /// existing behaviour relies on it; a share binds only where pictures are
    /// expensive, which is where the defect is. The elasticity the rest of
    /// this type is built on survives it: a device with more to give still
    /// holds more.
    ///
    /// Sized for the queue's remaining job. With submission bounded ahead of
    /// it and the renderer's runway bounded behind it, this queue is slack
    /// between decode and display and nothing more: a handful of pictures.
    /// Measured on device at 0.4 the steady state ran 1.4 GiB and a burst of
    /// seeks was enough to reach jetsam from there.
    static let mostOfAllowanceForPictures = 0.15

    /// How many pictures the queue holds where the share above would give
    /// fewer: a 4K picture weighs enough that the share alone leaves a quarter
    /// second of slack, which one slow GPU pass or one late decode spends.
    static let fewestPicturesQueued = 12

    /// What those pictures may take of the allowance at most. Twice the share,
    /// and still short of the 0.4 measured to reach jetsam under a burst of
    /// seeks: past this the queue holds fewer pictures rather than risk it.
    static let mostOfAllowanceForFewestPictures = 0.3

    /// How few seconds of read-ahead the demux thread may be cut back to,
    /// where the caller states none. `BufferPolicy.lowWatermarkSeconds` is
    /// where the engine already declares a buffer starved and pauses playback
    /// to refill it, so a budget that left less than that would be budgeting
    /// for a permanent rebuffer - which is why the engine passes its own, and
    /// why this figure is the standard policy's.
    static let minimumReadAheadSeconds = 2.0

    /// How far over its mean rate a scene may run and still fit the seconds of
    /// read-ahead asked for. The ceiling is a guard against unbounded memory,
    /// not the limit: sized at the mean, a busy scene filled it with two
    /// seconds of video, parked the demux thread and starved the audio
    /// interleaved behind it.
    static let packetPeakOverMean = 3

    /// What one decoded picture of this film costs on the path it takes, kept
    /// so a device can report the figure every other number here is derived
    /// from: a film jetsam took is one whose queue and whose pools have to be
    /// told apart afterwards, and the process footprint alone cannot do it.
    let pictureBytes: Int
    let videoPacketBytes: Int
    let audioPacketBytes: Int
    /// What the video sample queue may hold. Compressed samples on the
    /// passthrough path, where a second is cheap and this never binds;
    /// pictures on the tone-mapped and software paths, where this is what
    /// stops one second from being a gigabyte.
    let videoSampleBytes: Int
    let audioSampleBytes: Int
    /// The pictures the pipeline is entitled to outside the sample queue:
    /// what the software decoder's pool may have out at once, and what the
    /// tone mapper's reorder window may hold.
    let pictureReserveBytes: Int
    /// What the window the engine keeps of each unselected audio track may
    /// hold, so a track chosen later starts at the clock rather than at the
    /// read-ahead's far end. 0 where the film has no other track.
    let retainedAudioWindowBytes: Int
    /// nil when the film fits.
    let shortfall: MemoryShortfall?

    /// The software decode pool's ceiling: everything the pipeline may hold
    /// in pictures at once, since every picture in the queue came from it and
    /// every picture on its way to the renderer is still out of it.
    var poolCeilingBytes: Int { videoSampleBytes + pictureReserveBytes }

    /// - Parameters:
    ///   - pictureBytes: what one decoded picture of this film costs, or 0 on
    ///     the passthrough path, where the queue holds no pictures at all.
    ///   - videoBytesPerSecond: what the video track costs on the wire.
    ///   - audioBytesPerSecond: what the audio track costs on the wire.
    ///   - decodedAudioBytesPerSecond: what it costs once decoded.
    ///   - retainedAudioTracks: the audio tracks not playing, each of which
    ///     the engine keeps a read-ahead window of.
    ///   - retainedAudioBytesPerSecond: what the costliest of them costs on
    ///     the wire.
    init(
        available: Int,
        pictureBytes: Int,
        frameRate: Double?,
        videoDelay: Int,
        videoBytesPerSecond: Int,
        audioBytesPerSecond: Int,
        decodedAudioBytesPerSecond: Int,
        readAheadSeconds: Double,
        videoTargetSeconds: Double,
        audioTargetSeconds: Double,
        minimumReadAheadSeconds: Double = PipelineBudget.minimumReadAheadSeconds,
        retainedAudioTracks: Int = 0,
        retainedAudioBytesPerSecond: Int = 0
    ) {
        let allowance = Int(Double(max(available, 0)) * PipelineBudget.claimedShareOfAvailable)
        self.pictureBytes = pictureBytes
        pictureReserveBytes = PipelineBudget.picturesHeldOutsideTheQueue * pictureBytes

        // Every want is a span of content times a rate measured off this film,
        // never a size chosen in advance. nil is what a container that stated
        // no rate leaves behind: there is nothing to convert the span with, so
        // that claim takes what is left rather than a figure invented for it.
        let audioSampleWant = Int(audioTargetSeconds * Double(decodedAudioBytesPerSecond))
        let audioPacketWant = Int(readAheadSeconds * Double(audioBytesPerSecond))
        let videoPacketWant: Int? = videoBytesPerSecond > 0
            ? Int(readAheadSeconds * Double(videoBytesPerSecond))
            : nil
        let videoSampleWant: Int? = pictureBytes > 0
            ? frameRate.map { Int(videoTargetSeconds * $0 * Double(pictureBytes)) }
            : videoPacketWant.map { Int(videoTargetSeconds / readAheadSeconds * Double($0)) }

        // The floors, in the same terms. A picture queue shallower than the
        // reorder depth cannot put frames back in order at all, and one with
        // nothing to hand on while the next is decoding starves the renderer
        // on every frame.
        let floorPictures = pictureBytes > 0 ? (max(videoDelay, 0) + 2) * pictureBytes : 0
        let floorVideoPackets = Int(minimumReadAheadSeconds * Double(videoBytesPerSecond))
        let floorAudioPackets = Int(minimumReadAheadSeconds * Double(audioBytesPerSecond))

        let required = pictureReserveBytes + floorPictures + floorVideoPackets
            + floorAudioPackets + audioSampleWant
        guard allowance >= required else {
            videoPacketBytes = floorVideoPackets
            audioPacketBytes = floorAudioPackets
            videoSampleBytes = max(floorPictures, 1)
            audioSampleBytes = audioSampleWant
            retainedAudioWindowBytes = 0
            shortfall = MemoryShortfall(requiredBytes: required, allowedBytes: allowance)
            return
        }
        shortfall = nil

        // Claimed in order of how little each can give: the decoded audio
        // queue is two seconds of PCM and is taken whole, the reserve is what
        // the pipeline holds whether or not the budget agrees, and what
        // survives goes to the two elastic queues.
        audioSampleBytes = audioSampleWant
        audioPacketBytes = min(audioPacketWant, allowance - required + floorAudioPackets)
        var left = allowance - pictureReserveBytes - audioSampleBytes - audioPacketBytes

        // Read-ahead before depth: seconds of read-ahead are what a network
        // source spends to absorb a stall, where depth in the picture queue
        // only absorbs decode jitter. Half of what is left where the file
        // stated no rate at all - the picture queue needs the other half, and
        // neither can be sized against a rate nobody measured.
        let meanPackets = max(
            floorVideoPackets, min(videoPacketWant ?? (left / 2), left - floorPictures))
        left -= meanPackets

        // The other audio tracks' windows have no floor: one cut short only
        // starts a later selection a little later. Never out of the pictures'.
        let retainedAudioWant = retainedAudioTracks
            * Int(readAheadSeconds * Double(retainedAudioBytesPerSecond))
        let retainedAudioBytes = max(0, min(retainedAudioWant, left - floorPictures))
        retainedAudioWindowBytes = retainedAudioTracks > 0 ? retainedAudioBytes / retainedAudioTracks : 0
        left -= retainedAudioWindowBytes * retainedAudioTracks

        // Whatever survives is the picture queue's, capped at the second it
        // was asked for and at the depth past which a deeper queue absorbs no
        // more jitter. The floor still wins over both: a queue shallower than
        // the reorder window cannot put frames back in order at all.
        let shareCeiling = max(
            Int(Double(allowance) * PipelineBudget.mostOfAllowanceForPictures),
            min(
                PipelineBudget.fewestPicturesQueued * pictureBytes,
                Int(Double(allowance) * PipelineBudget.mostOfAllowanceForFewestPictures)))
        videoSampleBytes = max(
            floorPictures, min(videoSampleWant ?? left, left, shareCeiling))
        left -= videoSampleBytes

        // The room for a busy scene comes last, out of what nothing else took.
        let peakRoom = (videoPacketWant ?? 0) * (PipelineBudget.packetPeakOverMean - 1)
        videoPacketBytes = meanPackets + max(0, min(peakRoom, left))
    }
}

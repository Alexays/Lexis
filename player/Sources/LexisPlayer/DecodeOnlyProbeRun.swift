import CoreMedia
import Foundation

/// One clip's answer to the bench's headline question - hardware or
/// software, how many frames, how fast - measured with nothing on screen,
/// through the bench's own `PassthroughDecodeProbe` session, never the
/// player's. The probe never runs while the film does: only this run can read
/// back decode timing and the hardware answer for a passthrough file, since
/// the display layer owns that session during real playback, not the app.
public struct DecodeOnlyResult: Equatable {
    /// Read from the session, never inferred from what was asked for.
    public let hardwareAccelerated: Bool
    /// False until at least one frame came back from the session - the same
    /// discipline `LexisPlayer.hardwareAccelerationKnown` already keeps, so
    /// a session that never decoded anything cannot read as a confident
    /// "software".
    public let hardwareAccelerationKnown: Bool
    public let framesDecoded: Int
    public let wallMilliseconds: Double
    public let decodeMillisecondsMean: Double
    public let decodeMillisecondsWorst: Double
    /// nil when nothing decoded or the container gave no frame rate: a
    /// ratio against an unknown or zero content time is not a measurement.
    public let decodeToContentRatio: Double?
    /// The tvOS simulator decodes every codec in software, always: read
    /// once, honestly, so a report can say what produced these numbers
    /// rather than let a simulator run pass as the owner's hardware.
    public let isSimulator: Bool
}

public enum DecodeOnlyRunError: Error, Equatable {
    case noVideoStream
    /// Could not even build the request VideoToolbox would be asked to
    /// honor: missing or malformed extradata, or (VP9) a first packet whose
    /// uncompressed header this run could not read. This is "never asked",
    /// not a refusal - the clip stays unmeasured.
    case formatDescriptionUnavailable(String)
    /// VideoToolbox refused to create a session for a format description
    /// this run built correctly: a real, confident "this device cannot
    /// decode this codec at all", never "we did not ask" and never folded
    /// into the same unmeasured bucket as `formatDescriptionUnavailable`.
    case deviceRefused(DecodeError)
}

public enum DecodeOnlyProbeRun {
    /// How long the run waits, after every packet has been fed, for
    /// VideoToolbox's async callbacks to catch up: bounded, so a session
    /// that never calls back cannot hang the bench forever.
    private static let decodeTimeout: TimeInterval = 10

    /// Decodes every video packet of `url` through a throwaway
    /// `PassthroughDecodeProbe`, bounded by its own frame limit, and reports
    /// what came back. Throws `PlaybackActivityGate.Busy.playbackRunning`
    /// rather than decode alongside an open `LexisPlayer` - the two must
    /// never run at once, in either order, and this is the refusal from the
    /// probe's side; `LexisPlayer.open` is the refusal from the film's.
    ///
    /// Blocking: run this off the caller's own serial queue, the same way
    /// every other player entry point is.
    public static func run(url: URL) throws -> DecodeOnlyResult {
        try PlaybackActivityGate.shared.beginProbe()
        defer { PlaybackActivityGate.shared.endProbe() }

        let demuxer = try Demuxer(url: url)
        guard let stream = demuxer.streams.first(where: { $0.kind == .video }) else {
            throw DecodeOnlyRunError.noVideoStream
        }
        // VP9 needs the first video packet before a format description can
        // even be built (BenchFormatDescription.swift): it carries no
        // CodecPrivate in Matroska, so its profile and chroma layout come
        // from the bitstream's own uncompressed header instead.
        func readFirstVideoPacket() throws -> Packet {
            while true {
                guard let packet = try demuxer.readPacket() else {
                    throw DecodeOnlyRunError.noVideoStream
                }
                if packet.streamIndex == stream.index { return packet }
            }
        }
        let firstPacket = try readFirstVideoPacket()

        let format: CMVideoFormatDescription
        do {
            format = try benchFormatDescription(for: stream, firstKeyframe: firstPacket.copiedBytes)
        } catch {
            throw DecodeOnlyRunError.formatDescriptionUnavailable(String(describing: error))
        }
        let probe: PassthroughDecodeProbe
        do {
            probe = try PassthroughDecodeProbe(formatDescription: format)
        } catch let error as DecodeError {
            throw DecodeOnlyRunError.deviceRefused(error)
        }

        let started = Date()
        var fed = 0
        func feed(_ packet: Packet) throws {
            let sample = try makeSampleBuffer(
                packet: packet, formatDescription: format,
                timeBaseNum: stream.timeBaseNum, timeBaseDen: stream.timeBaseDen
            )
            probe.decode(sample)
            fed += 1
        }
        try feed(firstPacket)
        while let packet = try demuxer.readPacket() {
            guard packet.streamIndex == stream.index else { continue }
            try feed(packet)
        }
        let expected = min(fed, PassthroughDecodeProbe.frameLimit)
        let deadline = Date(timeIntervalSinceNow: decodeTimeout)
        while probe.decodeSampleCount < expected, Date() < deadline {
            usleep(10_000)
        }
        let wallMilliseconds = Date().timeIntervalSince(started) * 1000
        let framesDecoded = probe.decodeSampleCount

        var ratio: Double?
        if framesDecoded > 0, let frameRate = stream.frameRate, frameRate > 0 {
            let contentMilliseconds = Double(framesDecoded) / frameRate * 1000
            ratio = wallMilliseconds / contentMilliseconds
        }

        return DecodeOnlyResult(
            hardwareAccelerated: probe.isHardwareAccelerated,
            hardwareAccelerationKnown: framesDecoded > 0,
            framesDecoded: framesDecoded,
            wallMilliseconds: wallMilliseconds,
            decodeMillisecondsMean: probe.decodeMillisecondsMean,
            decodeMillisecondsWorst: probe.decodeMillisecondsWorst,
            decodeToContentRatio: ratio,
            isSimulator: isSimulator
        )
    }

    /// True on every run built for the tvOS simulator, which decodes every
    /// codec in software, always: what a caller reports alongside a refusal
    /// too, so even an unmeasured clip's row says what device it came from.
    #if targetEnvironment(simulator)
    public static let isSimulator = true
    #else
    public static let isSimulator = false
    #endif
}

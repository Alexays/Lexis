import Foundation

/// What the sound output takes, as the app reads it from its audio session:
/// the package itself builds on macOS, where there is no such session.
public struct AudioRoute: Equatable, Sendable {
    /// The PCM channels the route carries: a decoded track with more is
    /// folded down to this many by the system.
    public var channels: Int32
    /// Whether an AC-3 or E-AC-3 bitstream reaches a decoder past the
    /// device, a receiver on HDMI, rather than being decoded here.
    public var takesDolby: Bool

    public init(channels: Int32, takesDolby: Bool) {
        self.channels = channels
        self.takesDolby = takesDolby
    }

    /// What is assumed until the app reads the real one: a route that limits
    /// nothing.
    public static let unlimited = AudioRoute(channels: 8, takesDolby: true)
}

/// The audio track a file opens on. The container's first, unless the route
/// takes a Dolby bitstream and the first is a track that leaves worse than a
/// Dolby one in the same language would: a TrueHD or DTS decoded to PCM
/// here, or any other track with more channels than the route carries as
/// PCM. The Dolby track then leaves as the bitstream the receiver decodes
/// itself, Atmos included on E-AC-3, and in surround where PCM would be
/// folded to stereo. A route that decodes every track keeps the first, a
/// lossless one included. A different language is never traded for a
/// format, nor surround for a stereo downmix or a commentary, and a viewer's
/// own choice still overrides this.
public func preferredAudioStream(among streams: [MediaStream], route: AudioRoute = .unlimited) -> MediaStream? {
    let audio = streams.filter { $0.kind == .audio }
    guard let first = audio.first else { return nil }
    let dolby = ["ac3", "eac3"]
    guard route.takesDolby, !dolby.contains(first.codecName),
        first.codecName == "truehd" || first.codecName == "dts" || first.channels > route.channels
    else { return first }
    return audio.filter {
        dolby.contains($0.codecName) && $0.language == first.language
            && $0.channels >= min(first.channels, 6)
            && !["comment", "descri"].contains(where: $0.title.lowercased().contains)
    }.max { $0.channels < $1.channels } ?? first
}

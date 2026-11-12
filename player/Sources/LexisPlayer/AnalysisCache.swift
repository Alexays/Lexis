import Foundation

/// A container probe's result and its keyframe table. The first open of a
/// file pays the probe once; every later open, and every seek in a container
/// without cues, reads this back instead.
///
/// Nothing here names the file. What keys one of these, and where it is kept,
/// belongs to the stream it was probed from (`MediaStreamIO`): the player
/// holds a file's bytes and never its identity.
public struct MediaAnalysis: Sendable, Equatable, Codable {
    /// What the file measured when this was probed. Whatever keys the store
    /// is a scan's own reading of the file and a scan can be behind, so this
    /// is checked before the probe is trusted: a cached open that no longer
    /// describes the container fails outright rather than falling back, and
    /// the stream it failed on is spent.
    public var sizeBytes: Int64
    public var duration: Double
    public var streams: [MediaStream]
    /// Presentation seconds of every keyframe of the video stream, read
    /// from avformat_index_get_entry after open.
    public var keyframeSeconds: [Double]

    public init(
        sizeBytes: Int64, duration: Double, streams: [MediaStream], keyframeSeconds: [Double]
    ) {
        self.sizeBytes = sizeBytes
        self.duration = duration
        self.streams = streams
        self.keyframeSeconds = keyframeSeconds
    }
}

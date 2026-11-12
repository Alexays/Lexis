import Foundation

/// A seekable byte stream the player reads through, as plain C function
/// pointers over an opaque handle. The core's streams are one implementation;
/// the player never learns what is behind the handle, and nothing here can
/// throw or unwind, which is what FFmpeg's I/O callbacks require.
///
/// Unchecked because a raw pointer and four C function pointers carry no
/// guarantee the compiler can see. The invariant they do hold: a handle may
/// move between threads, but it must never be used from two at once. The
/// player honours that by handing a stream to exactly one demuxer, which reads
/// it from exactly one thread at a time.
public struct MediaStreamIO: @unchecked Sendable {
    /// Bytes read, 0 at the end of the stream, negative on failure.
    public typealias Read = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<UInt8>?, Int32) -> Int64
    /// The new position, or negative on failure. `whence`: 0 start, 1 current, 2 end.
    public typealias Seek = @convention(c) (UnsafeMutableRawPointer?, Int64, Int32) -> Int64
    /// The total length, or negative when it is not known.
    public typealias Size = @convention(c) (UnsafeMutableRawPointer?) -> Int64
    public typealias Close = @convention(c) (UnsafeMutableRawPointer?) -> Void
    /// The JSON's full length, or negative when nothing is stored for this
    /// file. `buffer` may be null with a capacity of 0 to measure first.
    public typealias AnalysisLoad = @convention(c) (
        UnsafeMutableRawPointer?, UnsafeMutablePointer<UInt8>?, Int32
    ) -> Int32
    public typealias AnalysisStore = @convention(c) (
        UnsafeMutableRawPointer?, UnsafePointer<CChar>?
    ) -> Int32

    public let handle: UnsafeMutableRawPointer
    public let read: Read
    public let seek: Seek
    public let size: Size
    public let close: Close
    /// Where this file's probe is kept, when whoever opened the stream keeps
    /// one. Both nil for a stream that does not: the analysis is keyed by a
    /// file identity the player never learns, so the stream is what carries
    /// it, and a player handed one that keeps none simply probes cold.
    public let analysisLoad: AnalysisLoad?
    public let analysisStore: AnalysisStore?

    public init(
        handle: UnsafeMutableRawPointer,
        read: @escaping Read,
        seek: @escaping Seek,
        size: @escaping Size,
        close: @escaping Close,
        analysisLoad: AnalysisLoad? = nil,
        analysisStore: AnalysisStore? = nil
    ) {
        self.handle = handle
        self.read = read
        self.seek = seek
        self.size = size
        self.close = close
        self.analysisLoad = analysisLoad
        self.analysisStore = analysisStore
    }

    /// The probe result stored for this file, when it is still the file that
    /// was probed. Two calls: the first measures, the second fills.
    public func cachedAnalysis() -> MediaAnalysis? {
        guard let analysisLoad else { return nil }
        let length = analysisLoad(handle, nil, 0)
        guard length > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: Int(length))
        let filled = bytes.withUnsafeMutableBufferPointer {
            analysisLoad(handle, $0.baseAddress, length)
        }
        guard filled == length else { return nil }
        guard let stored = try? JSONDecoder().decode(MediaAnalysis.self, from: Data(bytes))
        else { return nil }
        return stored.sizeBytes == size(handle) ? stored : nil
    }

    /// Keeps `analysis` for the next open of this file. Does nothing at all
    /// for a stream that keeps none.
    public func store(_ analysis: MediaAnalysis) {
        guard let analysisStore, let json = try? JSONEncoder().encode(analysis) else { return }
        String(decoding: json, as: UTF8.self).withCString { _ = analysisStore(handle, $0) }
    }
}

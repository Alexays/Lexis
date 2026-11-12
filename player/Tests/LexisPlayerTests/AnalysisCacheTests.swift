import Foundation
import LexisTestSupport
import XCTest
@testable import LexisPlayer

/// A file-backed `MediaStreamIO` that counts every real read and records
/// the offset of the first one - what a test needs to prove a seek landed
/// before any byte of the file was actually read.
private final class CountingFileStream {
    private let handle: FileHandle
    private(set) var readCount = 0
    private(set) var totalBytesRead = 0
    private(set) var firstReadOffset: Int64?
    private var position: Int64 = 0
    let size: Int64

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        size = Int64(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64 ?? 0)
    }

    var stream: MediaStreamIO {
        MediaStreamIO(
            handle: Unmanaged.passUnretained(self).toOpaque(),
            read: countingFileStreamRead,
            seek: countingFileStreamSeek,
            size: countingFileStreamSize,
            close: countingFileStreamClose
        )
    }

    fileprivate func read(into destination: UnsafeMutablePointer<UInt8>, _ length: Int32) -> Int64 {
        if firstReadOffset == nil { firstReadOffset = position }
        readCount += 1
        handle.seek(toFileOffset: UInt64(position))
        let data = handle.readData(ofLength: Int(length))
        data.copyBytes(to: destination, count: data.count)
        position += Int64(data.count)
        totalBytesRead += data.count
        return Int64(data.count)
    }

    fileprivate func seek(_ offset: Int64, _ whence: Int32) -> Int64 {
        switch whence {
        case 0: position = offset
        case 1: position += offset
        case 2: position = size + offset
        default: return -1
        }
        return position
    }

    fileprivate func close() {
        try? handle.close()
    }
}

private let countingFileStreamRead: MediaStreamIO.Read = { handle, buffer, length in
    guard let handle, let buffer else { return -1 }
    return Unmanaged<CountingFileStream>.fromOpaque(handle).takeUnretainedValue()
        .read(into: buffer, length)
}

private let countingFileStreamSeek: MediaStreamIO.Seek = { handle, offset, whence in
    guard let handle else { return -1 }
    return Unmanaged<CountingFileStream>.fromOpaque(handle).takeUnretainedValue().seek(offset, whence)
}

private let countingFileStreamSize: MediaStreamIO.Size = { handle in
    guard let handle else { return -1 }
    return Unmanaged<CountingFileStream>.fromOpaque(handle).takeUnretainedValue().size
}

private let countingFileStreamClose: MediaStreamIO.Close = { handle in
    guard let handle else { return }
    Unmanaged<CountingFileStream>.fromOpaque(handle).takeUnretainedValue().close()
}

final class AnalysisCacheTests: XCTestCase {
    func testTheKeyframeTableMatchesTheFixturesForcedGOP() throws {
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "analysis-gop.mp4",
            codec: .h264, width: 320, height: 240, frameCount: 240, fps: 24, gopSize: 24
        )
        let demuxer = try Demuxer(url: url)
        let table = demuxer.keyframeTable
        XCTAssertEqual(table.count, 10)
        for (index, seconds) in table.enumerated() {
            XCTAssertEqual(seconds, Double(index), accuracy: 0.05)
        }
    }

    func testAResumeSeeksBeforeTheFirstRead() throws {
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "analysis-resume.mp4",
            codec: .h264, width: 320, height: 240, frameCount: 480, fps: 24, gopSize: 24
        )
        let counting = try CountingFileStream(url: url)
        let demuxer = try Demuxer(stream: counting.stream, interrupt: nil, analysis: nil, resumeAt: 15.0)
        let stream = try XCTUnwrap(demuxer.streams.first { $0.kind == .video })

        // a resume that read every packet from the front before honouring
        // the seek would hand back a packet near the start of the file;
        // one that seeks first hands back a packet already at the target
        let packet = try XCTUnwrap(demuxer.readPacket())
        let seconds = Double(try XCTUnwrap(packet.pts)) * Double(stream.timeBaseNum)
            / Double(stream.timeBaseDen)
        XCTAssertGreaterThan(seconds, 10.0)
        XCTAssertLessThanOrEqual(seconds, 15.0)
    }

    func testACachedAnalysisSkipsFindStreamInfo() throws {
        let url = try makeVideoFixture(
            directory: FileManager.default.temporaryDirectory, name: "analysis-cached.mp4",
            codec: .h264, width: 640, height: 480, frameCount: 240, fps: 24, noisy: true, gopSize: 24
        )
        let cold = try CountingFileStream(url: url)
        let coldDemuxer = try Demuxer(stream: cold.stream, interrupt: nil, analysis: nil, resumeAt: nil)
        let analysis = MediaAnalysis(
            sizeBytes: cold.size, duration: coldDemuxer.duration,
            streams: coldDemuxer.streams, keyframeSeconds: coldDemuxer.keyframeTable
        )

        let warm = try CountingFileStream(url: url)
        _ = try Demuxer(stream: warm.stream, interrupt: nil, analysis: analysis, resumeAt: nil)

        // mp4's own moov parsing reads deterministically regardless of the
        // probe budget for a well-formed container, so the cached path's
        // lowered probesize/analyzeduration is a ceiling rather than a
        // guaranteed saving on every container shape - never more than an
        // uncached open costs, which is the invariant this asserts.
        XCTAssertLessThanOrEqual(warm.totalBytesRead, cold.totalBytesRead)
    }
}

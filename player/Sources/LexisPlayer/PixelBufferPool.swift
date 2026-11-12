import CoreVideo
import Foundation

enum PixelBufferPoolError: Error, Equatable {
    case creationFailed(CVReturn)
}

/// `CVPixelBufferPool` wrapper the software decode path draws from; the pool
/// is created once per format, and steady state asks the allocator for
/// nothing. Buffers are IOSurface-backed, which is what makes them zero-copy
/// to the screen.
///
/// `warmCount` is how many buffers it keeps ready. The ceiling is a separate
/// figure and is expressed in BYTES, never in buffers: what the pipeline
/// holds at once is a span of content, so the count that healthy playback
/// reaches follows the frame size. A ceiling counted in buffers is either far
/// below what a small picture's pipeline holds - eight was, and refused 125
/// of 180 frames on a 320x240 file, each refusal a frame the film lost - or
/// far above what a 4K one can afford. `capacity` divides the byte ceiling by
/// what one picture of this size actually measures, so the same policy gives
/// a small stream thousands of buffers and a 4K stream twenty.
final class PixelBufferPool {
    private let pool: CVPixelBufferPool
    private let bufferAttributes: [String: Any]
    private let width: Int32
    private let height: Int32
    private let pixelFormat: OSType
    /// How many buffers `take` will hand out at once, derived at init from
    /// `ceilingBytes` and one real buffer's measured size.
    let capacity: Int
    /// The ceiling as CoreVideo takes it. Built once: it never changes, and
    /// `take` runs on every decoded picture.
    private let auxAttributes: CFDictionary
    private let lock = NSLock()
    private var beyond = 0
    private var misses = 0

    /// - Parameter reserveBuffers: pictures the holder keeps that
    ///   `ceilingBytes` does not describe - a frame-threaded decoder's own
    ///   in-flight and reference pictures - handed out on top of the ceiling
    ///   rather than out of it.
    /// - Parameter rendererAttributes: what the renderer these pictures are
    ///   for would like them allocated with, resolved against this pool's
    ///   own. A set the two cannot agree on leaves the pool's own standing:
    ///   a picture the renderer copies is still a picture.
    init(
        width: Int32, height: Int32, pixelFormat: OSType, warmCount: Int, ceilingBytes: Int,
        reserveBuffers: Int = 0, rendererAttributes: [String: Any] = [:]
    ) throws {
        let ownAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        var bufferAttributes = ownAttributes
        if !rendererAttributes.isEmpty {
            var resolved: CFDictionary?
            let status = CVPixelBufferCreateResolvedAttributesDictionary(
                kCFAllocatorDefault, [ownAttributes, rendererAttributes] as CFArray, &resolved
            )
            if status == kCVReturnSuccess, let merged = resolved as? [String: Any] {
                bufferAttributes = merged
            }
        }
        let poolAttributes: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: warmCount,
        ]
        var created: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault, poolAttributes as CFDictionary,
            bufferAttributes as CFDictionary, &created
        )
        guard status == kCVReturnSuccess, let created else {
            throw PixelBufferPoolError.creationFailed(status)
        }
        pool = created
        // Measured off a real buffer rather than computed from the format:
        // only CoreVideo knows the row padding it chose, and the ceiling is
        // meant to bound what the process actually pays.
        var probe: CVPixelBuffer?
        let probeStatus = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, created, &probe)
        guard probeStatus == kCVReturnSuccess, let probe else {
            throw PixelBufferPoolError.creationFailed(probeStatus)
        }
        let frameBytes = max(CVPixelBufferGetDataSize(probe), 1)
        // Never below the warm count: a pool that refuses what it was told to
        // keep ready is a pool sized wrong, not a runaway being caught.
        capacity = max(warmCount, ceilingBytes / frameBytes + reserveBuffers)
        auxAttributes = [
            kCVPixelBufferPoolAllocationThresholdKey as String: capacity,
        ] as CFDictionary
        self.bufferAttributes = bufferAttributes
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat
    }

    /// A recycled buffer, or a freshly allocated one while fewer than
    /// `capacity` are still out. nil, counted in `poolMisses`, at the ceiling
    /// or when CoreVideo itself could not allocate.
    func take() -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            kCFAllocatorDefault, pool, auxAttributes, &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            lock.lock()
            misses += 1
            lock.unlock()
            return nil
        }
        return buffer
    }

    /// A buffer from outside the pool, for a picture the pool refused. What
    /// it costs is one allocation the pool cannot recycle; what refusing
    /// costs is the picture itself, and a film that stops at the frame the
    /// ceiling was reached on.
    func takeBeyondCapacity() -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, Int(width), Int(height), pixelFormat,
            bufferAttributes as CFDictionary, &buffer
        )
        guard status == kCVReturnSuccess else { return nil }
        lock.lock()
        beyond += 1
        lock.unlock()
        return buffer
    }

    /// How many pictures had to be allocated outside the pool: what a refusal
    /// cost once a flush of the texture cache and a second ask did not cover it.
    var allocatedBeyond: Int {
        lock.lock()
        defer { lock.unlock() }
        return beyond
    }

    var poolMisses: Int {
        lock.lock()
        defer { lock.unlock() }
        return misses
    }

    /// Frees the buffers the pool is holding for reuse and nobody is using.
    /// A pool keeps whatever its busiest moment needed for as long as it
    /// lives, which is the right trade while memory is there and the wrong
    /// one the moment the system asks for some back: the pictures in flight
    /// are untouched, and what this costs is one allocation each the next
    /// time the pipeline is that busy again.
    func releaseSpareBuffers() {
        CVPixelBufferPoolFlush(pool, [.excessBuffers])
    }
}

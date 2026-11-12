import Foundation
import Metal

/// How long a stage's passes take, each read off its own command buffer,
/// or off the clock for a pass the system runs: what the rendering costs on
/// the device it runs on.
final class GPUTiming {
    struct Reading: Sendable, Equatable {
        var passes = 0
        var meanMilliseconds = 0.0
        var worstMilliseconds = 0.0
    }

    private static let tracedEvery = 240
    private let label: String
    private let lock = NSLock()
    private var reading = Reading()
    private var totalMilliseconds = 0.0
    /// The passes since the last trace, whose mean is what a drift over the
    /// film shows in: the running mean moves ever slower as passes add up.
    private var windowMilliseconds = 0.0
    private var windowWorstMilliseconds = 0.0

    init(label: String) {
        self.label = label
    }

    var current: Reading {
        lock.lock()
        defer { lock.unlock() }
        return reading
    }

    /// Once a pass has run, with how long it took and how many pictures the
    /// stage has had to allocate outside its pool so far. Traced every
    /// `tracedEvery` passes, ten seconds of a 24 frame film, so a device run
    /// shows it.
    func record(_ milliseconds: Double, beyondPool: Int) {
        guard milliseconds > 0 else { return }
        lock.lock()
        reading.passes += 1
        totalMilliseconds += milliseconds
        reading.meanMilliseconds = totalMilliseconds / Double(reading.passes)
        reading.worstMilliseconds = max(reading.worstMilliseconds, milliseconds)
        windowMilliseconds += milliseconds
        windowWorstMilliseconds = max(windowWorstMilliseconds, milliseconds)
        var report: (reading: Reading, windowMean: Double, windowWorst: Double)?
        if reading.passes % GPUTiming.tracedEvery == 0 {
            report = (reading, windowMilliseconds / Double(GPUTiming.tracedEvery), windowWorstMilliseconds)
            windowMilliseconds = 0
            windowWorstMilliseconds = 0
        }
        lock.unlock()
        // Off the caller's thread: this runs in a pass's completion handler,
        // ahead of the picture being handed on, and the trace writes a file.
        if let report {
            let label = label
            DispatchQueue.global(qos: .utility).async {
                traceLine(String(
                    format: "[lexis.gpu] %@: %d passes, last %d mean %.2f ms worst %.2f ms,"
                        + " overall mean %.2f ms worst %.2f ms, allocated past the pool %d",
                    label, report.reading.passes, GPUTiming.tracedEvery, report.windowMean, report.windowWorst,
                    report.reading.meanMilliseconds, report.reading.worstMilliseconds, beyondPool))
            }
        }
    }
}

/// Which pass of a command buffer costs what on the device: each encoder's
/// start and end read off the GPU's timestamp counters, where the buffer's own
/// span covers every pass at once. Only under LEXIS_TRACE_FILE=1, and nil
/// wherever the GPU cannot sample at an encoder's boundaries.
final class PassTimer {
    private static let tracedEvery = 240
    /// Frames in flight each get their own samples, or one frame's would
    /// land over another's before either is read.
    private static let slots = 8
    private let label: String
    private let passes: [String]
    /// Passes timed from the end of another to their own start: an empty
    /// encoder behind work someone else encodes, which leaves no samples.
    private let gaps: [Int: Int]
    private let counters: MTLCounterSampleBuffer
    private let scratch: MTLBuffer
    private let device: MTLDevice
    private let lock = NSLock()
    private var totals: [Double]
    private var remainder = 0.0
    private var frames = 0
    /// The first CPU and GPU readings taken together, and the latest: GPU
    /// ticks become seconds through the two clocks' own rates.
    private var firstClocks: (cpu: MTLTimestamp, gpu: MTLTimestamp)?
    private var ticksToMilliseconds = 0.0
    private var nextSlot = 0

    init?(device: MTLDevice, label: String, passes: [String], gaps: [Int: Int] = [:]) {
        guard ProcessInfo.processInfo.environment["LEXIS_TRACE_FILE"] == "1",
            device.supportsCounterSampling(.atStageBoundary),
            let timestamps = device.counterSets?.first(where: { $0.name == MTLCommonCounterSet.timestamp.rawValue })
        else { return nil }
        let descriptor = MTLCounterSampleBufferDescriptor()
        descriptor.counterSet = timestamps
        descriptor.storageMode = .shared
        descriptor.sampleCount = passes.count * 2 * PassTimer.slots
        guard let counters = try? device.makeCounterSampleBuffer(descriptor: descriptor),
            let scratch = device.makeBuffer(length: 4, options: .storageModePrivate)
        else { return nil }
        self.scratch = scratch
        self.device = device
        self.label = label
        self.passes = passes
        self.gaps = gaps
        self.counters = counters
        totals = Array(repeating: 0, count: passes.count)
    }

    /// The samples one command buffer's passes write to, taken before its
    /// first encoder and handed back to `record`.
    func slot() -> Int {
        lock.lock()
        defer { lock.unlock() }
        nextSlot = (nextSlot + 1) % PassTimer.slots
        return nextSlot
    }

    /// The encoder for pass `index` of the buffer holding `slot`, its start
    /// and end sampled.
    func encoder(_ index: Int, slot: Int, on command: MTLCommandBuffer) -> MTLComputeCommandEncoder? {
        let descriptor = MTLComputePassDescriptor()
        let first = (slot * passes.count + index) * 2
        descriptor.sampleBufferAttachments[0].sampleBuffer = counters
        descriptor.sampleBufferAttachments[0].startOfEncoderSampleIndex = first
        descriptor.sampleBufferAttachments[0].endOfEncoderSampleIndex = first + 1
        return command.makeComputeCommandEncoder(descriptor: descriptor)
    }

    /// A pass for `index` that copies one pixel of `texture`, four bytes a
    /// pixel: it waits for whatever writes it and holds back whatever writes
    /// it next, which fences work someone else encodes for a gap to time.
    func marker(_ index: Int, slot: Int, on command: MTLCommandBuffer, reading texture: MTLTexture) {
        let descriptor = MTLBlitPassDescriptor()
        let first = (slot * passes.count + index) * 2
        descriptor.sampleBufferAttachments[0].sampleBuffer = counters
        descriptor.sampleBufferAttachments[0].startOfEncoderSampleIndex = first
        descriptor.sampleBufferAttachments[0].endOfEncoderSampleIndex = first + 1
        guard let blit = command.makeBlitCommandEncoder(descriptor: descriptor) else { return }
        blit.copy(
            from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
            sourceSize: MTLSize(width: 1, height: 1, depth: 1), to: scratch, destinationOffset: 0,
            destinationBytesPerRow: 4, destinationBytesPerImage: 4)
        blit.endEncoding()
    }

    /// From the buffer's completion: the time of each pass in `encoded`, the
    /// ones this buffer really held, and what of the buffer's span no timed
    /// pass covers, which is a pass someone else encoded, the upscaler's. Traced
    /// every 240 buffers.
    func record(_ command: MTLCommandBuffer, slot: Int, encoded: [Int]) {
        let first = slot * passes.count * 2
        guard let data = try? counters.resolveCounterRange(first..<first + passes.count * 2) else { return }
        let (cpu, gpu) = device.sampleTimestamps()
        let stamps = data.withUnsafeBytes { Array($0.bindMemory(to: MTLCounterResultTimestamp.self)) }
        lock.lock()
        defer { lock.unlock() }
        if let firstClocks {
            // the CPU reading is in nanoseconds already
            if gpu > firstClocks.gpu {
                ticksToMilliseconds = Double(cpu - firstClocks.cpu) / Double(gpu - firstClocks.gpu) / 1e6
            }
        } else {
            firstClocks = (cpu, gpu)
            return
        }
        guard ticksToMilliseconds > 0 else { return }
        var timed = 0.0
        for index in encoded {
            let end = stamps[index * 2 + (gaps[index] == nil ? 1 : 0)].timestamp
            let start = gaps[index].map { stamps[$0 * 2 + 1].timestamp } ?? stamps[index * 2].timestamp
            guard end > start, start != MTLCounterErrorValue, end != MTLCounterErrorValue else { continue }
            let milliseconds = Double(end - start) * ticksToMilliseconds
            totals[index] += milliseconds
            timed += milliseconds
        }
        remainder += max((command.gpuEndTime - command.gpuStartTime) * 1000 - timed, 0)
        frames += 1
        guard frames == PassTimer.tracedEvery else { return }
        let line = zip(passes, totals).map { String(format: "%@ %.2f", $0, $1 / Double(frames)) }
            + [String(format: "other %.2f", remainder / Double(frames))]
        totals = Array(repeating: 0, count: passes.count)
        remainder = 0
        frames = 0
        let label = label
        DispatchQueue.global(qos: .utility).async {
            traceLine("[lexis.pass] \(label), ms a frame: " + line.joined(separator: ", "))
        }
    }
}

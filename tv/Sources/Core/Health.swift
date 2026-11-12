import Foundation
import LexisPlayer
import QuartzCore
import os

/// What the app costs while it runs, so a freeze or a slowdown can be placed:
/// main thread stalls, late frames, the threads burning the CPU, memory and
/// heat, as `[lexis.health]` lines on the player's trace channels and as
/// signposts for Instruments. Only under LEXIS_TRACE_FILE=1, the way
/// `tv/scripts/trace-tv.sh` launches the app: a viewer's app runs none of it.
@MainActor
final class Health: NSObject {
    static let shared = Health()
    nonisolated static let enabled = ProcessInfo.processInfo.environment["LEXIS_TRACE_FILE"] == "1"
    /// Also marks the screens' own moments, so a hitch in Instruments sits
    /// next to the focus move that caused it.
    nonisolated static let signposter = OSSignposter(subsystem: "org.lexis.app", category: "health")
    /// A main thread that has not answered for this long is a freeze.
    nonisolated private static let hangSeconds = 0.25
    nonisolated private static let windowSeconds = 5.0
    /// The system id of the main thread, which has no name of its own, its
    /// port and its stack's bounds. Written once by `start`, before the
    /// watching thread reads them.
    nonisolated(unsafe) private static var mainThread: UInt64 = 0
    nonisolated(unsafe) private static var mainPort: mach_port_t = 0
    nonisolated(unsafe) private static var mainStackBounds: (top: UInt, bottom: UInt) = (0, 0)

    /// Where the viewer is and what runs behind them, said by the shell.
    var place: () -> String = { "" }
    private var link: CADisplayLink?
    private var lastFrame: CFTimeInterval = 0
    private var frames = 0
    private var late = 0
    private var worstGap: CFTimeInterval = 0

    func start() {
        guard Health.enabled, link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(frame(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        pthread_threadid_np(nil, &Health.mainThread)
        Health.mainPort = mach_thread_self()
        let top = UInt(bitPattern: pthread_get_stackaddr_np(pthread_self()))
        Health.mainStackBounds = (top, top - UInt(pthread_get_stacksize_np(pthread_self())))
        Thread.detachNewThread { Health.watch() }
        NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { _ in traceLine("[lexis.health] thermal now \(Health.thermal)") }
    }

    /// A gap over one and a half refreshes is a frame the screen repeated:
    /// with the main thread free, the render server or the GPU was late. Two
    /// repeated in a row is a stutter the eye catches, and is written out.
    @objc private func frame(_ link: CADisplayLink) {
        defer { lastFrame = link.timestamp }
        guard lastFrame > 0 else { return }
        let gap = link.timestamp - lastFrame
        frames += 1
        worstGap = max(worstGap, gap)
        let refresh = link.targetTimestamp - link.timestamp
        guard gap > 1.5 * refresh else { return }
        late += 1
        if gap > 2.5 * refresh {
            Health.signposter.emitEvent("hitch", "\(Int(gap * 1000)) ms")
            traceLine("[lexis.health] hitch \(Int(gap * 1000)) ms at \(place())")
        }
    }

    /// The frame counts since the last window, reset.
    private func takeFrames() -> String {
        defer { frames = 0; late = 0; worstGap = 0 }
        return "frames \(frames) late \(late) worst \(Int(worstGap * 1000)) ms"
    }

    /// Pings the main thread every tenth of a second from a thread of its own,
    /// and writes a window's reading every five seconds.
    nonisolated private static func watch() {
        Thread.current.name = "lexis.health"
        var before = threadTimes()
        var windowStart = Date()
        while true {
            let sent = Date()
            let answered = DispatchSemaphore(value: 0)
            DispatchQueue.main.async { answered.signal() }
            if answered.wait(timeout: .now() + hangSeconds) == .timedOut {
                let atHang = threadTimes()
                let stack = mainStack()
                let state = signposter.beginInterval("hang")
                answered.wait()
                signposter.endInterval("hang", state)
                let held = Date().timeIntervalSince(sent)
                let busiest = busiest(atHang, threadTimes(), over: held - hangSeconds)
                DispatchQueue.main.async {
                    traceLine("[lexis.health] hang \(Int(held * 1000)) ms at \(Health.shared.place()), busiest \(busiest)")
                    traceLine("[lexis.health] hang stack \(stack)")
                }
            }
            let elapsed = Date().timeIntervalSince(windowStart)
            if elapsed >= windowSeconds {
                let now = threadTimes()
                let cpu = busiest(before, now, over: elapsed)
                let total = now.reduce(0.0) { sum, entry in
                    sum + Double(entry.value.nanoseconds - min(entry.value.nanoseconds, before[entry.key]?.nanoseconds ?? 0))
                } / elapsed / 1e7
                let memory = footprintBytes() / 1_048_576
                before = now
                windowStart = Date()
                DispatchQueue.main.async {
                    let health = Health.shared
                    traceLine("[lexis.health] cpu \(Int(total))% (\(cpu)), mem \(memory) MiB,"
                        + " thermal \(thermal), \(health.takeFrames()), at \(health.place())")
                }
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    /// Where the main thread is stuck: the return addresses down its frame
    /// pointers, read while it is suspended, each named by symbol and image.
    nonisolated private static func mainStack() -> String {
        #if arch(arm64)
        let depth = 24
        let pcs = UnsafeMutablePointer<UInt>.allocate(capacity: depth)
        defer { pcs.deallocate() }
        var taken = 0
        let (top, bottom) = mainStackBounds
        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        // nothing may allocate or take a lock until the resume: the main
        // thread may be suspended holding the malloc or the dyld lock
        guard thread_suspend(mainPort) == KERN_SUCCESS else { return "" }
        let read = withUnsafeMutablePointer(to: &state) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
                thread_get_state(mainPort, ARM_THREAD_STATE64, $0, &count)
            }
        }
        if read == KERN_SUCCESS {
            pcs[0] = UInt(state.__pc)
            pcs[1] = UInt(state.__lr)
            taken = 2
            var fp = UInt(state.__fp)
            while taken < depth, fp >= bottom, fp + 16 <= top, fp & 7 == 0 {
                let frame = UnsafePointer<UInt>(bitPattern: fp)!
                pcs[taken] = frame[1]
                taken += 1
                guard frame[0] > fp else { break }
                fp = frame[0]
            }
        }
        thread_resume(mainPort)
        var names: [String] = []
        for index in 0..<taken {
            // a return address an arm64e framework signed carries its code in the top bits
            let pc = pcs[index] & 0x7F_FFFF_FFFF
            var info = Dl_info()
            guard pc != 0, dladdr(UnsafeRawPointer(bitPattern: pc), &info) != 0 else { continue }
            let image = info.dli_fname.map { String(cString: $0).split(separator: "/").last.map(String.init) ?? "" } ?? "?"
            let symbol = info.dli_sname.map { String(cString: $0) } ?? "?"
            names.append("\(symbol) (\(image)+0x\(String(pc - UInt(bitPattern: info.dli_fbase), radix: 16)))")
        }
        return names.joined(separator: " < ")
        #else
        return ""
        #endif
    }

    nonisolated private static var thermal: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    /// The five threads that ran the most between two readings, as a share
    /// of one core over `seconds`.
    nonisolated private static func busiest(
        _ from: [UInt64: (name: String, nanoseconds: UInt64)],
        _ to: [UInt64: (name: String, nanoseconds: UInt64)], over seconds: Double
    ) -> String {
        to.map { id, thread in (thread.name, thread.nanoseconds - min(thread.nanoseconds, from[id]?.nanoseconds ?? 0)) }
            .sorted { $0.1 > $1.1 }
            .prefix(5)
            .filter { $0.1 > 0 }
            .map { "\($0.0) \(Int(Double($0.1) / max(seconds, 0.001) / 1e7))%" }
            .joined(separator: ", ")
    }

    /// Every thread of the process, by its system id: its name, or its id
    /// when it has none, and the CPU time it has used so far.
    nonisolated private static func threadTimes() -> [UInt64: (name: String, nanoseconds: UInt64)] {
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return [:] }
        defer {
            for index in 0..<Int(count) { mach_port_deallocate(mach_task_self_, list[index]) }
            vm_deallocate(
                mach_task_self_, vm_address_t(UInt(bitPattern: list)),
                vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
        }
        var times: [UInt64: (name: String, nanoseconds: UInt64)] = [:]
        times.reserveCapacity(Int(count))
        for index in 0..<Int(count) {
            var identifier = thread_identifier_info_data_t()
            var identifierCount = mach_msg_type_number_t(
                MemoryLayout<thread_identifier_info_data_t>.size / MemoryLayout<natural_t>.size)
            var extended = thread_extended_info_data_t()
            var extendedCount = mach_msg_type_number_t(
                MemoryLayout<thread_extended_info_data_t>.size / MemoryLayout<natural_t>.size)
            let read = withUnsafeMutablePointer(to: &identifier) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(identifierCount)) {
                    thread_info(list[index], thread_flavor_t(THREAD_IDENTIFIER_INFO), $0, &identifierCount)
                }
            } == KERN_SUCCESS && withUnsafeMutablePointer(to: &extended) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(extendedCount)) {
                    thread_info(list[index], thread_flavor_t(THREAD_EXTENDED_INFO), $0, &extendedCount)
                }
            } == KERN_SUCCESS
            guard read else { continue }
            let name = withUnsafeBytes(of: extended.pth_name) {
                String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
            }
            times[identifier.thread_id] = (
                identifier.thread_id == mainThread ? "main" : name.isEmpty ? "tid \(identifier.thread_id)" : name,
                extended.pth_user_time + extended.pth_system_time
            )
        }
        return times
    }
}

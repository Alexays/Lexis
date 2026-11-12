import Foundation
import LexisCore
import Observation

/// The core's link session, named apart from SwiftUI's own Link.
typealias CoreLink = Link

/// How far the scan in flight has gotten, and whether one is in flight at all.
struct ScanStatus: Equatable {
    var running = false
    var sourcesDone: UInt32 = 0
    var sourcesTotal: UInt32 = 0
    var currentSource = ""
}

/// The work the core does on threads of its own, as the screens draw it: the
/// metadata pass and the library scan. The core runs them; this only asks
/// where they have got to, at a redraw rate, and only while one is going.
@MainActor
@Observable
final class BackgroundWork {
    static let shared = BackgroundWork()

    /// The pass's counters, moving at the poll rate while it runs.
    private(set) var pass = PassRun(
        phase: .idle, described: 0, linked: 0, embedded: 0, semantic: 0, note: nil)
    /// The pass's phase and note on their own, for a view that draws only
    /// where the pass is and not how far.
    private(set) var phase = PassPhase.idle
    private(set) var note: PassNote?
    private(set) var scan = ScanStatus()
    /// Whether anyone has asked for a pass this launch, so a screen mounting
    /// later does not ask for what the shell already did.
    private(set) var passStarted = false

    private var passTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    /// Callers awaiting the scan in flight: the core runs one scan at a time
    /// and they all wait on it.
    private var scanWaiters = 0
    private var paused = false

    private init() {}

    var passRunning: Bool {
        switch phase {
        case .describing, .linking, .embedding, .semantic: true
        case .idle, .done: false
        }
    }

    /// The core's reason for stopping, in the viewer's words; nil when the
    /// pass has nothing to say.
    var passMessage: String? {
        switch note {
        case nil: nil
        case .noModel: t("settings.passNoModel")
        case .tmdbSilent: t("settings.passTmdbSilent")
        case .modelUnusable(let msg): t("error.embedModel", ["detail": msg])
        case .failed(let msg): t("settings.passFailed", ["detail": msg])
        }
    }

    /// Wakes the core's pass thread and follows it: describe, link, embed,
    /// sweep. A pass already running is not doubled; the core decides that.
    func startPass() {
        passStarted = true
        Task {
            // The first touch of the core opens its database and migrates
            // it: at launch this is that touch, so it happens off main.
            let run = await CoreClient.run {
                let core = CoreClient.shared
                core.startPass()
                core.refreshTrending()
                return core.passNow()
            }
            publish(run)
            watchPass()
        }
    }

    /// Holds the pass while something else owns the device, playback above
    /// all, and stops asking after it until it resumes.
    func pausePass(_ value: Bool) {
        guard value != paused else { return }
        paused = value
        CoreClient.calls.async { CoreClient.shared.pausePass(paused: value) }
        if value {
            passTask?.cancel()
            passTask = nil
        } else {
            watchPass()
        }
    }

    private func publish(_ run: PassRun) {
        if run != pass { pass = run }
        if run.phase != phase { phase = run.phase }
        if run.note != note { note = run.note }
    }

    private func watchPass() {
        guard passTask == nil, !paused, passRunning else { return }
        passTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                if Task.isCancelled { break }
                publish(await CoreClient.run { CoreClient.shared.passNow() })
                if !passRunning { break }
            }
            passTask = nil
        }
    }

    /// Scans the sources, or waits on the scan already running, and follows
    /// its progress in `scan` while it runs, so anything that only wants a
    /// spinner can watch `scan` without awaiting a report of its own.
    func scan(full: Bool) async throws -> ScanReport {
        scanWaiters += 1
        if scanWaiters == 1 {
            scan = ScanStatus(running: true)
            scanTask = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled,
                        let progress = await CoreClient.run({ CoreClient.shared.currentScan() })
                    else { continue }
                    let next = ScanStatus(
                        running: true, sourcesDone: progress.sourcesDone,
                        sourcesTotal: progress.sourcesTotal, currentSource: progress.currentSource)
                    if next != scan { scan = next }
                }
            }
        }
        defer {
            scanWaiters -= 1
            if scanWaiters == 0 {
                scanTask?.cancel()
                scanTask = nil
                scan = ScanStatus()
            }
        }
        let report = try await CoreClient.shared.scan(full: full)
        // A sweep that found nothing leaves the home and the pass alone: it
        // runs every few minutes. The flag is taken once, by the first waiter.
        if await CoreClient.run({ CoreClient.shared.takeLibraryChanged() }) {
            // The titles the scan indexed carry no metadata row, and whoever
            // started the scan is not always on screen to ask.
            startPass()
            NotificationCenter.default.post(name: .libraryScanned, object: nil)
        }
        return report
    }

    /// How fresh the last scan has to be to stand as the current answer.
    nonisolated static let rescanAfter: TimeInterval = 5 * 60

    /// Scans the sources when a viewer is about to go looking for what they
    /// added: opening the app, coming back to it, out of a film, or every few
    /// minutes left on it. Left alone while a scan runs, with nothing to scan,
    /// or when the last one is recent unless `force`; a source never scanned
    /// forces one.
    func rescanIfStale(force: Bool = false) {
        guard !scan.running else { return }
        Task {
            let stale = await CoreClient.run { () -> Bool in
                let sources = CoreClient.shared.listSources()
                guard !sources.isEmpty else { return false }
                // The newest of them: sources are scanned together, and one
                // that keeps failing must not put every wake back on the wire.
                var newest: Int64?
                for source in sources {
                    guard let last = source.lastScan else {
                        newest = nil
                        break
                    }
                    newest = max(newest ?? last, last)
                }
                return force || newest.map { Date().timeIntervalSince1970 - Double($0) >= Self.rescanAfter } ?? true
            }
            if stale { _ = try? await scan(full: false) }
        }
    }
}

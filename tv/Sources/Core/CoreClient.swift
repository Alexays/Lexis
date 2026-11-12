import Foundation
import LexisCore

/// The durable store the core keeps its small state in: UserDefaults, the
/// one store that survives a tvOS cache purge. Bytes in, bytes out, under
/// the core's own keys; an empty value reads back as absent.
final class DefaultsHostStore: HostStore {
    func get(key: String) -> Data? {
        let data = UserDefaults.standard.data(forKey: key)
        return data?.isEmpty == false ? data : nil
    }

    func set(key: String, value: Data) {
        UserDefaults.standard.set(value, forKey: key)
    }
}

extension Notification.Name {
    static let watchStateChanged = Notification.Name("watchStateChanged")
    /// The trio moved and nothing else did; the object is the new trio.
    static let tonightChanged = Notification.Name("tonightChanged")
    /// A scan of the sources ended having changed the library.
    static let libraryScanned = Notification.Name("libraryScanned")
}

/// The one core for the app, built on first use: the index, the sources,
/// the passes. Its plain methods block, so callers run them off the main
/// actor through `run`; its async ones work on threads of their own and are
/// awaited directly.
enum CoreClient {
    /// Core calls block on SQLite locks and the network, so they never run on
    /// Swift's cooperative pool: a few stuck there stall every task in the app.
    static let calls = DispatchQueue(label: "org.lexis.core.calls", qos: .userInitiated, attributes: .concurrent)
    /// The same for long background work: scans, polls on a timer.
    static let slow = DispatchQueue(label: "org.lexis.core.slow", qos: .utility, attributes: .concurrent)

    /// Runs a blocking core call on `queue` and resumes with its answer. The
    /// call itself cannot be interrupted: cancelling the caller only stops
    /// what it would do with the answer.
    static func run<T, E: Error>(
        on queue: DispatchQueue = calls, _ work: @escaping @Sendable () throws(E) -> T
    ) async throws(E) -> T {
        try await withCheckedContinuation { (continuation: CheckedContinuation<Result<T, E>, Never>) in
            queue.async { continuation.resume(returning: Result(catching: work)) }
        }.get()
    }

    static let shared: LexisCore = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let core = open(caches, store: DefaultsHostStore())
        // The repo ships no token of its own; a build can bake its own in,
        // seeded here once. A token the core refuses is the build's mistake
        // and nothing the viewer can act on: the library works without TMDB.
        if !core.hasTmdbKey(),
            let builtIn = Bundle.main.object(forInfoDictionaryKey: "LexisTMDBToken") as? String,
            !builtIn.isEmpty
        {
            try? core.setTmdbKey(key: builtIn)
        }
        // The first Plex connection costs seconds to resolve and establish;
        // spent here, while the viewer is still choosing something to watch.
        core.keepSourcesWarm()
        return core
    }()

    /// A core that starts whatever the disk holds. A source list this build
    /// cannot read is cleared, the one thing the viewer redoes. An index from
    /// a newer build stays as it is for that build, and this one keeps its
    /// own beside it.
    private static func open(_ caches: URL, store: HostStore, dir: String = "lexis") -> LexisCore {
        do {
            return try LexisCore(cacheDir: caches.appendingPathComponent(dir).path, store: store)
        } catch CoreError.InvalidConfig(let msg) {
            NSLog("[lexis] source list cleared: %@", msg)
            resetSources(store: store)
            return open(caches, store: store, dir: dir)
        } catch CoreError.SchemaTooNew(let msg) where dir == "lexis" {
            NSLog("[lexis] index left for a newer build: %@", msg)
            return open(caches, store: store, dir: "lexis-compat")
        } catch {
            fatalError("the core cannot open: \(error)")
        }
    }
}

import Foundation

private let namePrefix = "lexis-fixtures-"
private let cachePrefix = "lexis-fixture-cache-"

/// How long a cache directory for some other version of the fixture code is
/// left alone before it is swept. Long enough that a run in a worktree on a
/// different revision, however slow, is never sweeping the files another run
/// is reading.
private let staleCacheAge: TimeInterval = 24 * 60 * 60

/// A digest of the code that writes fixtures, so a cache that outlives the run
/// cannot serve a clip built by a version of that code which no longer exists.
///
/// The sources are read rather than the built binary stamped: the binary is
/// relinked for any test edit at all, and throwing away every encode on an
/// unrelated one-line change is the whole cost this cache exists to avoid.
/// Falls back to the pid, which is what the cache was keyed by before it was
/// kept between runs, where the sources are not beside the build.
private let fixtureCodeVersion: String = {
    let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
        .filter { $0.hasSuffix(".swift") }
        .sorted()
    var hash: UInt64 = 0xCBF2_9CE4_8422_2325
    var read = 0
    for name in names {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name))
        else { continue }
        read += 1
        for byte in name.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01B3 }
        for byte in data { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01B3 }
    }
    guard read > 0 else { return "pid\(getpid())" }
    return String(hash, radix: 16)
}()

/// Runs once, against the first directory a fixture is asked for: everything an
/// earlier run left behind whose process is gone is nobody's, and fixtures are
/// large enough (tens of megabytes each) that keeping every run's would fill the
/// temporary directory within a day.
private func sweepAbandonedFixtures(in directory: URL) {
    let existing = (try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil
    )) ?? []
    for url in existing {
        let name = url.lastPathComponent
        if name.hasPrefix(cachePrefix) {
            // Encodes for a revision nobody is on any more. Swept on age
            // alone: a cache directory has no owning process to ask after,
            // and every run sharing this version is entitled to it.
            guard name != "\(cachePrefix)\(fixtureCodeVersion)",
                let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[
                    .modificationDate] as? Date,
                Date().timeIntervalSince(modified) > staleCacheAge
            else { continue }
            try? FileManager.default.removeItem(at: url)
            continue
        }
        guard name.hasPrefix(namePrefix), let pid = pid_t(name.dropFirst(namePrefix.count)),
            pid != getpid()
        else { continue }
        // ESRCH is the only answer that means gone: EPERM says it is alive and
        // owned by someone else, and removing that one's fixtures mid-run is
        // the very thing this directory exists to prevent.
        guard kill(pid, 0) != 0, errno == ESRCH else { continue }
        try? FileManager.default.removeItem(at: url)
    }
}

/// Where a fixture of `name` belongs, under a directory belonging to this
/// process alone.
///
/// Every fixture is asked for by a fixed name, and every test asks for it in
/// the shared temporary directory. Two `swift test` processes on one machine -
/// a checkout and a worktree, say - therefore write and read the same paths at
/// the same time, and each truncates the other's file mid-read: the symptom is
/// a scatter of "Invalid data found when processing input" across whichever
/// tests happened to be reading. Nesting by pid keeps concurrent runs off each
/// other's files without any test having to name a unique one.
public func fixtureURL(in directory: URL, named name: String) -> URL {
    let owned = directory.appendingPathComponent("\(namePrefix)\(getpid())")
    if !FileManager.default.fileExists(atPath: owned.path) {
        sweepAbandonedFixtures(in: directory)
        try? FileManager.default.createDirectory(at: owned, withIntermediateDirectories: true)
    }
    return owned.appendingPathComponent(name)
}

/// Where the encode for `key` is kept, so the second caller wanting the same
/// clip copies it instead of encoding it again.
///
/// The suite asks for a hundred-odd video fixtures and only about half as many
/// distinct ones, and every one of them is a hardware encode: `AVAssetWriter`
/// is the video encoder on the other side of the IOMMU, and opening and
/// tearing that many sessions down is both most of what the fixtures cost and
/// what has taken the machine down under concurrent runs.
///
/// The caller still gets its OWN file at the name it asked for, copied from
/// the cache: several tests patch a byte in the fixture they were handed (a
/// Dolby Vision profile, a corrupted sample) and would otherwise be editing
/// every later test's copy. On APFS the copy is a clone and costs no space.
///
/// Kept between runs, in a directory of its own named for the version of the
/// fixture code that filled it, so a second `swift test` encodes nothing at
/// all. Runs on the same version share it: the entry is built under a unique
/// name and moved into place, so a reader either sees a whole file or no file.
public func cachedFixture(
    key: String, at destination: URL, build: (URL) throws -> Void
) throws -> URL {
    var hash: UInt64 = 0xCBF2_9CE4_8422_2325
    for byte in key.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01B3 }
    // Up out of this process's own directory, which `fixtureURL` put the
    // destination in, and back down into the one shared by every run.
    let directory = destination.deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("\(cachePrefix)\(fixtureCodeVersion)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let cached = directory
        .appendingPathComponent("cache-\(String(hash, radix: 16)).\(destination.pathExtension)")
    if !FileManager.default.fileExists(atPath: cached.path) {
        // Built beside it and moved into place, never written at the cached
        // path directly: a build that threw half way would otherwise leave a
        // truncated file every later caller would trust.
        // Same extension as the real thing: AVAssetWriter is told its file
        // type outright, but nothing else that writes a fixture promises to.
        let pending = cached.deletingLastPathComponent()
            .appendingPathComponent(
                "pending-\(UInt64.random(in: 0..<UInt64.max)).\(destination.pathExtension)")
        try build(pending)
        // Another run on this same version can have finished the identical
        // encode in the meantime. Its file is as good as this one, so the
        // loser of that race keeps neither the error nor its own copy.
        do {
            try FileManager.default.moveItem(at: pending, to: cached)
        } catch {
            try? FileManager.default.removeItem(at: pending)
            guard FileManager.default.fileExists(atPath: cached.path) else { throw error }
        }
    }
    try? FileManager.default.removeItem(at: destination)
    try FileManager.default.copyItem(at: cached, to: destination)
    return destination
}

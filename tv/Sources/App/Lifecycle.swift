import Foundation
import LexisCore

/// What the app does around its screens: the shelf the Top Shelf reads,
/// and the link a shelf press launches it with.
enum Lifecycle {
    static let appGroup = "group.io.github.alexays.lexis"

    /// Writes the shelf into the app group container, where the extension
    /// can read it. Nothing when the build carries no group.
    static func writeShelf() {
        let names = ShelfTitles(tonight: t("tonight.title"), upNext: t("row.upNext"))
        CoreClient.slow.async {
            // the container lookup is a round trip to a system daemon
            guard let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
            else { return }
            _ = try? CoreClient.shared.writeShelfSnapshot(
                dir: dir.path, titles: names, tzOffsetSecs: Format.tzOffsetSecs)
        }
    }

    /// A shelf tile names its title by kind, name and year:
    /// `lexis://title?kind=movie&name=<percent encoded>&year=1999`, and
    /// `&play=1` starts it rather than opening its page, and `&resume=1`
    /// starts it where it was left off.
    struct ShelfLink: Equatable {
        let kind: ApiMediaKind
        let name: String
        let year: UInt16
        var play = false
        var resume = false
    }

    static func shelfLink(_ url: URL) -> ShelfLink? {
        guard url.scheme == "lexis", url.host == "title",
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return nil }
        var fields: [String: String] = [:]
        for item in items { fields[item.name] = item.value ?? "" }
        guard let name = fields["name"], !name.isEmpty,
            let kind = fields["kind"].flatMap({ $0 == "movie" ? ApiMediaKind.movie : $0 == "show" ? .show : nil }),
            let year = fields["year"].flatMap(UInt16.init)
        else { return nil }
        return ShelfLink(
            kind: kind, name: name, year: year, play: fields["play"] == "1", resume: fields["resume"] == "1")
    }

    /// The title a shelf link names, or nil for one the index no longer holds.
    static func title(for link: ShelfLink) -> TitleItem? {
        try? CoreClient.shared.titleByShelfKey(kind: link.kind, name: link.name, year: link.year)
    }
}

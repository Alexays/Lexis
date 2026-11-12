import Foundation
import TVServices

/// The shelf tvOS draws above the app on the home screen.
///
/// This process cannot ask the app anything and cannot open the index: the
/// index is a WAL database the app may be writing to, in a directory tvOS
/// purges, behind a schema that migrates on open. It reads one file the app
/// left in the group container and nothing else, so the worst a malformed or
/// outdated one can do is leave the shelf empty.
///
/// Empty is a real answer here, not a failure: returning nil makes tvOS fall
/// back to the static Top Shelf image in the asset catalog, which is the right
/// thing to show for an app that has nothing to say yet.
final class ContentProvider: TVTopShelfContentProvider {
    override func loadTopShelfContent() async -> (any TVTopShelfContent)? {
        guard let root = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)
        else {
            return nil
        }
        return content(in: root)
    }

    private func content(in root: URL) -> (any TVTopShelfContent)? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(snapshotName)),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              // A shape this build does not know is a shelf it must not guess
              // at. The app and the extension ship in one bundle and so always
              // agree, except across an update, where the file on disk is
              // still the one the previous version wrote until that version's
              // successor replaces it.
              snapshot.version == snapshotVersion
        else {
            return nil
        }

        let sections = snapshot.sections.enumerated()
            .compactMap { index, section -> TVTopShelfItemCollection<TVTopShelfSectionedItem>? in
                let items = section.items.compactMap { item in
                    tile(for: item, in: root, section: index)
                }
                guard !items.isEmpty else { return nil }
                let collection = TVTopShelfItemCollection(items: items)
                collection.title = section.title
                return collection
            }
        return sections.isEmpty ? nil : TVTopShelfSectionedContent(sections: sections)
    }

    /// One tile, or nothing when its image is not there.
    ///
    /// The app copies each image it names beside the snapshot and prunes the
    /// rest, so a missing one means the two writes crossed. A tile with no
    /// image draws as a grey rectangle with a caption under it, which reads as
    /// a broken shelf rather than a short one - so it is dropped, and a
    /// section left empty by that is dropped with it.
    private func tile(for item: Item, in root: URL, section: Int) -> TVTopShelfSectionedItem? {
        let image = root.appendingPathComponent(item.image)
        guard FileManager.default.fileExists(atPath: image.path) else { return nil }

        // tvOS requires the identifier to be unique across every item handed
        // back, so the section is part of it: the three the app writes hold
        // disjoint titles today, and nothing here should depend on that.
        let identifier = "\(section)/\(item.kind)/\(item.year)/\(item.name)"
        let tile = TVTopShelfSectionedItem(identifier: identifier)
        tile.title = item.name
        tile.imageShape = .hdtv
        tile.playbackProgress = item.progress
        tile.setImageURL(image, for: .screenScale1x)
        tile.setImageURL(image, for: .screenScale2x)
        if let url = item.url {
            tile.displayAction = TVTopShelfAction(url: url)
            // the play button on the remote starts the title where it stands:
            // the app reads where it was left, or its next episode
            if let resume = URL(string: url.absoluteString + "&resume=1") {
                tile.playAction = TVTopShelfAction(url: resume)
            }
        }
        return tile
    }
}

/// The container both processes can see. The app writes into it, this reads,
/// and neither reaches the other's own container at all.
private let appGroup = "group.io.github.alexays.lexis"

private let snapshotName = "shelf.json"

/// Must match `SNAPSHOT_VERSION` in core/src/api/shelf.rs.
private let snapshotVersion = 1

private extension CharacterSet {
    /// What may stand unencoded in one query value. `urlQueryAllowed` minus
    /// the characters that would end the value or start another one.
    static let lexisQueryValue: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=+?#")
        return set
    }()
}

private struct Snapshot: Decodable {
    let version: Int
    let sections: [Section]
}

private struct Section: Decodable {
    let title: String
    let items: [Item]
}

private struct Item: Decodable {
    let kind: String
    let name: String
    let year: Int
    let image: String
    let progress: Double

    /// What the app is launched with. The title is named the way the index is
    /// UNIQUE on it rather than by row id, which a purged and rescanned
    /// library reissues - a shelf outlives the index it was written from, and
    /// a tile must never open some other film that inherited a number.
    var url: URL? {
        // Encoded here rather than through URLComponents.queryItems, which
        // percent-encodes with urlQueryAllowed and so leaves "&" and "=" in a
        // value untouched: one film called "Les Chiens & Les Loups" would
        // otherwise arrive at the app as two half-parameters.
        guard let kind = kind.addingPercentEncoding(withAllowedCharacters: .lexisQueryValue),
              let name = name.addingPercentEncoding(withAllowedCharacters: .lexisQueryValue)
        else {
            return nil
        }
        return URL(string: "lexis://title?kind=\(kind)&name=\(name)&year=\(year)")
    }

    /// Unique across the shelf, which is what tvOS requires of it. A title can
    /// appear in two sections - what is running is also what is new, on a
    /// library that was just scanned - so the section cannot be left out of it.
    var identifier: String { "\(kind)/\(year)/\(name)" }
}

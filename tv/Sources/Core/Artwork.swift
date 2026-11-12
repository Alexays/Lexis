import CoreImage
import ImageIO
import LexisCore
import Observation
import SwiftUI
import UIKit

/// Which of a title's pictures a tile wants.
enum ArtworkKind: Hashable {
    case poster(titleId: Int64)
    /// The poster at the size a mood tile fans it out.
    case smallPoster(titleId: Int64)
    case thumb(titleId: Int64)
    case backdrop(titleId: Int64)
    case still(fileId: Int64)
    /// An episode's frame blurred, for an episode nobody has started.
    case veiledStill(fileId: Int64)
    case face(personId: Int64)

    /// The longest side, in pixels, the kind is drawn at: its largest frame
    /// at 2x, the scale tvOS draws a 4K panel at.
    fileprivate var maxPixels: Int {
        switch self {
        case .poster: 768
        case .smallPoster: 264
        // the hero shows it across the screen until the backdrop lands
        case .thumb: 1280
        case .backdrop: 3840
        case .still: 720
        case .veiledStill: 64
        case .face: 384
        }
    }
}

/// One picture, observed on its own: a picture landing redraws the tiles
/// that show it and no other.
@MainActor
@Observable
final class ArtworkSlot {
    /// Nil while the fetch is out, for a picture the core has none of, and
    /// for one dropped from memory while nothing showed it.
    fileprivate(set) var image: UIImage?
}

/// Blurs are drawn on the GPU; one context for every veiled still.
private let veilContext = CIContext()

/// The pictures on screen, asked for the way the core answers them: what
/// the cache already holds comes back at once, and a fetch the core queued
/// behind a `fetching` answer is waited for by watching the core's own
/// counter of finished fetches rather than by asking for each tile again.
/// One instance for the app.
@MainActor
final class Artwork {
    static let shared = Artwork()

    /// Decoded bytes kept for pictures nothing shows; a picture on screen is
    /// never dropped, whatever the total.
    private static let budget = 192 << 20

    private var slots: [ArtworkKind: ArtworkSlot] = [:]
    /// Kinds with a question or a decode out, so a redraw does not ask twice.
    private var inFlight: Set<ArtworkKind> = []
    /// Kinds the core answered `fetching` for.
    private var waiting: Set<ArtworkKind> = []
    /// Kinds whose answer is final: a picture decoded, none to have, or a
    /// fetch that kept failing.
    private var answered: Set<ArtworkKind> = []
    /// Failed fetches so far, per kind. The core queues a failed picture
    /// again on the next ask and leaves the backoff to the caller: without
    /// one, a server that was slow for a moment leaves a tile blank until the
    /// app restarts.
    private var failures: [ArtworkKind: Int] = [:]

    /// Asks after a failure, 4, 8 and 16 seconds apart, and no more: past
    /// that the picture is not coming this session.
    private static let retries = 3
    /// How many tiles show each kind; a kind nobody shows is not waited on
    /// and its picture may be dropped.
    private var users: [ArtworkKind: Int] = [:]
    /// Decoded pictures, oldest first, with the bytes each holds.
    private var decoded: [(kind: ArtworkKind, cost: Int)] = []
    private var decodedCost = 0
    private var settledSeen: UInt64 = 0
    private var watching = false

    private init() {}

    /// The core's answers and the decodes run here rather than on the shared
    /// pool, two at a time: a screen of tiles asking at once would otherwise
    /// hold every pool thread in blocking calls.
    nonisolated private static let decoder: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "lexis.artwork"
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .userInitiated
        return queue
    }()

    /// The picture's slot, asked for on first use and again after its
    /// picture was dropped. With `asking` false a picture nobody has asked
    /// for yet has no slot.
    func slot(_ kind: ArtworkKind, asking: Bool = true) -> ArtworkSlot? {
        let slot: ArtworkSlot
        if let known = slots[kind] {
            slot = known
        } else {
            guard asking else { return nil }
            slot = ArtworkSlot()
            slots[kind] = slot
        }
        if asking, !answered.contains(kind), !inFlight.contains(kind), !waiting.contains(kind) {
            inFlight.insert(kind)
            Artwork.decoder.addOperation {
                let state = Artwork.state(of: kind)
                Task { @MainActor in Artwork.shared.decodeIfShown(kind, state) }
            }
        }
        return slot
    }

    /// A tile that left the screen before its turn is not worth its decode;
    /// showing it again asks anew.
    private func decodeIfShown(_ kind: ArtworkKind, _ state: ArtworkState) {
        guard case .ready = state else { return landed(kind, state, nil) }
        guard users[kind] != nil else {
            inFlight.remove(kind)
            return
        }
        Artwork.decoder.addOperation {
            let image = Artwork.decode(kind, state)
            Task { @MainActor in Artwork.shared.landed(kind, state, image) }
        }
    }

    /// A tile showing the kind came on screen.
    func show(_ kind: ArtworkKind) {
        users[kind, default: 0] += 1
        // a backdrop asked for in the frame before its tile appeared may have
        // been skipped as unwatched
        if slots[kind]?.image == nil { _ = slot(kind) }
    }

    /// A tile showing the kind left the screen.
    func hide(_ kind: ArtworkKind) {
        guard let count = users[kind] else { return }
        users[kind] = count > 1 ? count - 1 : nil
    }

    nonisolated private static func state(of kind: ArtworkKind) -> ArtworkState {
        let core = CoreClient.shared
        do {
            switch kind {
            case .poster(let id), .smallPoster(let id): return core.posterNow(titleId: id)
            case .thumb(let id): return core.thumbNow(titleId: id)
            case .backdrop(let id): return core.backdropNow(titleId: id)
            case .still(let id), .veiledStill(let id): return try core.stillNow(fileId: id)
            case .face(let id): return try core.faceNow(personId: id)
            }
        } catch {
            return .missing
        }
    }

    /// The picture a ready answer points at, decoded here rather than at
    /// first draw on the main thread, and no larger than the kind is drawn.
    nonisolated private static func decode(_ kind: ArtworkKind, _ state: ArtworkState) -> UIImage? {
        guard case .ready(let path) = state, let image = decode(path, maxPixels: kind.maxPixels) else { return nil }
        guard case .veiledStill = kind else { return UIImage(cgImage: image) }
        // Blurred at a few dozen pixels and stretched by the tile: the blur
        // costs nothing at draw time, where a live one runs an offscreen pass.
        let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let sigma = Double(Theme.Unseen.still) * Double(image.width) / Double(Theme.Episode.stillWidth)
        let blurred = CIImage(cgImage: image).clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: extent)
        return veilContext.createCGImage(blurred, from: extent).map { UIImage(cgImage: $0) }
    }

    /// A picture on disk, decoded now and downsampled to `maxPixels` on its
    /// longest side.
    nonisolated static func decode(_ path: String, maxPixels: Int) -> CGImage? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private func landed(_ kind: ArtworkKind, _ state: ArtworkState, _ image: UIImage?) {
        inFlight.remove(kind)
        switch state {
        case .ready:
            answered.insert(kind)
            guard let image, let slot = slots[kind] else { return }
            slot.image = image
            let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
            decoded.append((kind, cost))
            decodedCost += cost
            trim()
        case .missing:
            answered.insert(kind)
        case .failed:
            let tries = failures[kind, default: 0] + 1
            failures[kind] = tries
            guard tries <= Artwork.retries else {
                answered.insert(kind)
                return
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2 << tries))
                // not shown any more: the next tile that shows it asks anew
                guard users[kind] != nil else { return }
                _ = slot(kind)
            }
        case .fetching:
            // asked again once the core reports a fetch finished
            waiting.insert(kind)
            watchSettled()
        }
    }

    /// Drops the oldest pictures nothing shows until the total fits; a
    /// dropped one is asked for again when a tile shows it.
    private func trim() {
        var index = 0
        while decodedCost > Artwork.budget, index < decoded.count {
            let (kind, cost) = decoded[index]
            guard users[kind] == nil else {
                index += 1
                continue
            }
            decoded.remove(at: index)
            decodedCost -= cost
            answered.remove(kind)
            slots[kind]?.image = nil
        }
    }

    /// Polls the core's counter while something is waiting on a fetch: one
    /// call a beat whether ten tiles are waiting or two hundred, and one
    /// task asking again for all of them.
    private func watchSettled() {
        guard !watching else { return }
        watching = true
        Task { @MainActor in
            while !waiting.isEmpty {
                try? await Task.sleep(for: .milliseconds(400))
                // A tile scrolled away stops the wait; showing it again asks anew.
                waiting = waiting.filter { users[$0] != nil }
                if waiting.isEmpty { break }
                let settled = await CoreClient.run { CoreClient.shared.artworkSettled() }
                guard settled != settledSeen else { continue }
                settledSeen = settled
                let kinds = waiting
                waiting.removeAll()
                inFlight.formUnion(kinds)
                await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                    Artwork.decoder.addOperation {
                        for kind in kinds {
                            let state = Artwork.state(of: kind)
                            let image = Artwork.decode(kind, state)
                            Task { @MainActor in Artwork.shared.landed(kind, state, image) }
                        }
                        done.resume()
                    }
                }
            }
            watching = false
        }
    }
}

/// A picture from the core, or the plate behind it while there is none.
struct ArtworkImage<Plate: View>: View {
    let kind: ArtworkKind
    @ViewBuilder let plate: () -> Plate

    var body: some View {
        let image = Artwork.shared.slot(kind)?.image
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                plate()
            }
        }
        // a picture that lands after its frame is drawn fades in over the
        // plate rather than popping into it
        .animation(.easeOut(duration: Theme.Motion.dim), value: image != nil)
        .onAppear { Artwork.shared.show(kind) }
        .onDisappear { Artwork.shared.hide(kind) }
        .onChange(of: kind) { old, new in
            Artwork.shared.hide(old)
            Artwork.shared.show(new)
        }
    }
}

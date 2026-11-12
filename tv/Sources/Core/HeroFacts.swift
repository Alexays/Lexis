import LexisCore
import SwiftUI

/// Everything the hero says about one title.
@MainActor @Observable
final class HeroSlot {
    fileprivate(set) var detail: TitleDetail?
    /// Nil for a title already watched, and for one the last taste pass did
    /// not place: the hero then shows no band at all rather than an empty one.
    fileprivate(set) var taste: TitleTasteInfo?
    /// The strongest thing the index can say about this title to this
    /// viewer, when it can say anything.
    fileprivate(set) var evidence: TitleEvidence?
}

/// The facts behind the title under the remote, fetched once per title and
/// kept for the session.
///
/// Focus moves at the speed of a thumb and both reads block, so neither may
/// run on the main actor and neither may run twice for the same title. The
/// hero fills in as they land, which is why it is laid out on declared
/// heights: the band does not jump when the numbers arrive.
@MainActor
final class HeroFacts {
    static let shared = HeroFacts()

    private var slots: [Int64: HeroSlot] = [:]
    private var asked: Set<Int64> = []

    private init() {
        // A mark or a list change anywhere leaves every slot stale: each is
        // read again, in place, the next time it is asked for.
        NotificationCenter.default.addObserver(forName: .watchStateChanged, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { HeroFacts.shared.asked.removeAll() }
        }
    }

    func slot(_ titleId: Int64) -> HeroSlot {
        let slot: HeroSlot
        if let known = slots[titleId] {
            slot = known
        } else {
            slot = HeroSlot()
            slots[titleId] = slot
        }
        ask(titleId, slot)
        return slot
    }

    private func ask(_ titleId: Int64, _ slot: HeroSlot) {
        guard asked.insert(titleId).inserted else { return }
        Task {
            let facts = await CoreClient.run {
                (
                    try? CoreClient.shared.titleDetail(titleId: titleId),
                    try? CoreClient.shared.titleTaste(titleId: titleId),
                    try? CoreClient.shared.titleEvidence(titleId: titleId)
                )
            }
            slot.detail = facts.0
            slot.taste = facts.1 ?? nil
            slot.evidence = facts.2 ?? nil
        }
    }
}

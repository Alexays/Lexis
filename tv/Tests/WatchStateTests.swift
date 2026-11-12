import LexisCore
import XCTest
@testable import Lexis

final class WatchStateTests: XCTestCase {
    @MainActor
    func testMarkingWatchedPublishesTheLocallySavedState() async {
        for failsWriteback in [false, true] {
            let core = WatchStateCore(noPointer: .init())
            core.failsWriteback = failsWriteback
            let item = TitleItem(id: 1, kind: .movie, name: "Movie", year: nil, fileCount: 1, firstFileId: 2)
            let model = TitleDetailModel(item: item, core: core)
            model.detail = core.saved
            let changed = expectation(forNotification: .watchStateChanged, object: nil) { _ in
                XCTAssertTrue(core.saved.watched)
                XCTAssertNil(core.saved.resumeFileId)
                XCTAssertEqual(core.saved.resumePositionSecs, 0)
                return true
            }

            model.toggleWatched()

            await fulfillment(of: [changed], timeout: 2)
        }
    }
}

private final class WatchStateCore: LexisCore, @unchecked Sendable {
    var failsWriteback = false
    var saved = TitleDetail(
        overview: nil, genres: [], cast: [], hasPoster: false, tmdbId: nil,
        watched: false, plays: 0, inWatchlist: false, resumeFileId: 2, resumePositionSecs: 120,
        resumeDurationSecs: 600, runtimeSecs: 600, directors: [], writers: [], composers: [],
        critics: nil, audience: nil, media: nil, verdict: nil, tones: [], versions: [])

    override func markWatched(titleId: Int64, watched: Bool) throws {
        saved.watched = watched
        saved.resumeFileId = nil
        saved.resumePositionSecs = 0
        if failsWriteback { throw NSError(domain: "Writeback", code: 1) }
    }

    override func titleDetail(titleId: Int64) throws -> TitleDetail {
        saved
    }

    override func upNext(titleId: Int64) throws -> EpisodeRef? {
        nil
    }

    override func episodes(titleId: Int64) throws -> [EpisodeRef] {
        []
    }
}

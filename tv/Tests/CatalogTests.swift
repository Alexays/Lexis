import LexisCore
import XCTest
@testable import Lexis

final class CatalogTests: XCTestCase {
    func testEveryEnglishKeyHasAFrenchMessage() {
        XCTAssertEqual(Set(Catalog.en.keys), Set(Catalog.fr.keys))
        XCTAssertFalse(Catalog.en.isEmpty)
    }

    func testPlaceholdersAreFilled() {
        XCTAssertEqual(I18n.shared.t("home.resume", ["time": "1:02"]).contains("1:02"), true)
    }

    /// A count takes the form its language gives it: English's singular is
    /// one alone, French's is zero and one.
    func testACountTakesItsLanguagesForm() {
        let before = I18n.shared.choice
        defer { I18n.shared.choose(before) }
        I18n.shared.choose(.pinned(.en))
        XCTAssertEqual(t("settings.minutesAgo", ["n": "1"]), "1 minute ago")
        XCTAssertEqual(t("settings.minutesAgo", ["n": "0"]), "0 minutes ago")
        XCTAssertEqual(t("settings.minutesAgo", ["n": "2"]), "2 minutes ago")
        I18n.shared.choose(.pinned(.fr))
        XCTAssertEqual(t("settings.minutesAgo", ["n": "0"]), "il y a 0 minute")
        XCTAssertEqual(t("settings.playbackDecodeFailures", ["count": "3"]), "3 images illisibles")
    }

    /// A shelf of one title counts it as one, in both languages.
    func testATitleCountAgreesWithItsNumber() {
        let before = I18n.shared.choice
        defer { I18n.shared.choose(before) }
        I18n.shared.choose(.pinned(.en))
        XCTAssertEqual(t("settings.titlesCount", ["n": "1"]), "1 title")
        XCTAssertEqual(t("settings.titlesCount", ["n": "12"]), "12 titles")
        XCTAssertEqual(t("library.count.movie", ["n": "1"]), "1 movie")
        I18n.shared.choose(.pinned(.fr))
        XCTAssertEqual(t("settings.titlesCount", ["n": "0"]), "0 titre")
        XCTAssertEqual(t("hold.notTonight", ["count": "1"]), "Pas ce soir (1 restant)")
        XCTAssertEqual(t("settings.holds", ["titles": "2", "files": "1"]), "2 titres, 1 fichier")
    }

    /// French elides "de" before a vowel, and only there.
    func testFrenchElidesDeBeforeAVowel() {
        let before = I18n.shared.choice
        defer { I18n.shared.choose(before) }
        I18n.shared.choose(.pinned(.fr))
        XCTAssertEqual(t("row.byDirector", ["name": "Alfred Hitchcock"]), "Les films d'Alfred Hitchcock")
        XCTAssertEqual(t("row.byDirector", ["name": "Jacques Audiard"]), "Les films de Jacques Audiard")
        XCTAssertEqual(t("row.thread", ["title": "Astérix"]), "Autour d'Astérix")
        I18n.shared.choose(.pinned(.en))
        XCTAssertEqual(t("row.thread", ["title": "Astérix"]), "Around Astérix")
    }

    /// A saga's place reads like a French ordinal, and its count agrees.
    func testASagaPlaceIsSaidInFrench() {
        let before = I18n.shared.choice
        defer { I18n.shared.choose(before) }
        I18n.shared.choose(.pinned(.fr))
        XCTAssertEqual(SagaPlace(name: "Dune", position: 1, size: 3, watched: 1).said, "1er sur 3, 1 vu")
        XCTAssertEqual(SagaPlace(name: "Dune", position: 5, size: 6, watched: 4).said, "5e sur 6, 4 vus")
    }
}

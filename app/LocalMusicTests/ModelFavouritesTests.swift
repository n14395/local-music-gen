import XCTest
@testable import LocalMusic

@MainActor
final class ModelFavouritesTests: XCTestCase {
    private func entry(_ id: String, favourite: Bool = false,
                       name: String? = nil) -> ModelChooser.Entry {
        ModelChooser.Entry(id: id, name: name ?? id, description: "",
                           family: "", isFavourite: favourite, badges: [])
    }

    // MARK: ordering

    func testFavouritesComeFirst() {
        let ordered = ModelChooser.ordered([
            entry("a"), entry("b", favourite: true), entry("c"),
            entry("d", favourite: true),
        ])
        XCTAssertEqual(ordered.map(\.id), ["b", "d", "a", "c"])
    }

    /// A stable partition, not a sort: within each group the catalog's own
    /// order survives, so nothing shuffles for a reason the user cannot see.
    func testOrderWithinEachGroupIsPreserved() {
        let ordered = ModelChooser.ordered([
            entry("z", favourite: true), entry("m"), entry("a", favourite: true),
            entry("b"),
        ])
        XCTAssertEqual(ordered.map(\.id), ["z", "a", "m", "b"])
    }

    func testNoFavouritesLeavesTheListExactlyAsItWas() {
        let input = [entry("a"), entry("b"), entry("c")]
        XCTAssertEqual(ModelChooser.ordered(input).map(\.id), ["a", "b", "c"])
    }

    func testEveryModelFavouritedIsAlsoIdentity() {
        let input = [entry("a", favourite: true), entry("b", favourite: true)]
        XCTAssertEqual(ModelChooser.ordered(input).map(\.id), ["a", "b"])
    }

    /// Search and favourites compose: a query narrows the list, and what
    /// survives is still favourites-first.
    func testSearchResultsAreStillFavouritesFirst() {
        let entries = [
            entry("plain-ace", name: "ACE-Step Base"),
            entry("fav-musicgen", favourite: true, name: "MusicGen Small"),
            entry("fav-ace", favourite: true, name: "ACE-Step Turbo"),
        ]
        let hits = ModelChooser.ordered(ModelChooser.filter(entries, query: "ace"))
        XCTAssertEqual(hits.map(\.id), ["fav-ace", "plain-ace"],
                       "the MusicGen favourite is filtered out, not floated up")
    }

    // MARK: the store

    /// Round-trips through UserDefaults. The key is saved and restored so a
    /// test run cannot leave favourites in the real app's preferences — the
    /// test host *is* the app bundle, so its defaults are the user's.
    func testTogglePersistsAndIsIndependentOfLicences() {
        let key = "favouriteModels"
        let saved = UserDefaults.standard.stringArray(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)

        let store = ModelCatalogStore()
        XCTAssertFalse(store.isFavourite("musicgen-small"))
        store.toggleFavourite("musicgen-small")
        XCTAssertTrue(store.isFavourite("musicgen-small"))

        // A second store reads what the first wrote.
        XCTAssertTrue(ModelCatalogStore().isFavourite("musicgen-small"))

        store.toggleFavourite("musicgen-small")
        XCTAssertFalse(store.isFavourite("musicgen-small"))
        XCTAssertFalse(ModelCatalogStore().isFavourite("musicgen-small"))
    }

    // MARK: the constraint

    /// **Models must never appear in the Library's Favourites.** That scope is
    /// music and parts, and it is counted from the database; model favourites
    /// are a local preference with no row anywhere. Hearting every model in
    /// sight must leave the Library's count at zero.
    func testHeartingModelsDoesNotTouchTheLibraryFavourites() throws {
        let key = "favouriteModels"
        let saved = UserDefaults.standard.stringArray(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)

        let db = try DatabaseManager.inMemory()
        let library = LibraryRepository(db: db)
        let parts = PartsRepository(db: db)
        XCTAssertEqual(try library.favoriteCount(), 0)

        let store = ModelCatalogStore()
        for id in ["ace-step", "musicgen-small", "stable-audio"] {
            store.toggleFavourite(id)
        }
        XCTAssertEqual(store.favouriteModelIds.count, 3)

        XCTAssertEqual(try library.favoriteCount(), 0,
                       "a hearted model is not a hearted song")
        XCTAssertTrue(try parts.favorites().isEmpty,
                      "a hearted model is not a hearted part")
    }
}

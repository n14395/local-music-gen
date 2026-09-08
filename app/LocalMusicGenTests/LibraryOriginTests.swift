import GRDB
import XCTest
@testable import LocalMusicGen

/// The Library's shelves are two disjoint reads of one table. These pin the
/// split itself — the regression that matters is an imported track showing up
/// under Generated, which is exactly what the old `origin != "recombined"`
/// definition did.
///
/// There are three origins and two shelves: a render shares the Generated shelf
/// with the takes, because both are audio the app made and a second sidebar
/// entry for one of them only asked the user to guess which list a mix went
/// into. The origin survives on the row — see `SongOrigin.rowMark`.
final class LibraryOriginTests: XCTestCase {
    private func makeRepo() throws -> LibraryRepository {
        LibraryRepository(db: try DatabaseManager.inMemory())
    }

    private func song(id: String, origin: SongOrigin,
                      title: String? = nil, artist: String? = nil)
        -> SongRecord {
        SongRecord(id: id, title: title ?? id, prompt: "lofi beat",
                   lyrics: nil, modelId: "m", modelName: "M", groupId: nil,
                   paramsJSON: "{}", durationS: 10, sampleRate: 32000,
                   fileName: id + ".wav", seedUsed: nil, createdAt: Date(),
                   rating: 0, notes: "", favorite: false,
                   origin: origin.rawValue, artist: artist)
    }

    private func seeded() throws -> LibraryRepository {
        let repo = try makeRepo()
        try repo.insert(song(id: "g1", origin: .generated))
        try repo.insert(song(id: "g2", origin: .generated))
        try repo.insert(song(id: "i1", origin: .imported))
        try repo.insert(song(id: "r1", origin: .recombined))
        return repo
    }

    private func ids(_ repo: LibraryRepository, _ origin: SongOrigin) throws
        -> Set<String> {
        var filters = LibraryRepository.Filters()
        filters.origin = .only(origin.rawValue)
        return Set(try repo.search(filters).map(\.id))
    }

    // MARK: scopes

    func testEachOriginFilterSeesOnlyItsOwnRows() throws {
        let repo = try seeded()
        XCTAssertEqual(try ids(repo, .generated), ["g1", "g2"])
        XCTAssertEqual(try ids(repo, .imported), ["i1"])
        XCTAssertEqual(try ids(repo, .recombined), ["r1"])
    }

    /// The three origins partition the table: nothing is in two of them, and
    /// nothing falls between them into no origin at all.
    func testOriginsArePartition() throws {
        let repo = try seeded()
        let generated = try ids(repo, .generated)
        let imported = try ids(repo, .imported)
        let renders = try ids(repo, .recombined)
        XCTAssertTrue(generated.isDisjoint(with: imported))
        XCTAssertTrue(generated.isDisjoint(with: renders))
        XCTAssertTrue(imported.isDisjoint(with: renders))

        let all = Set(try repo.search(.init()).map(\.id))
        XCTAssertEqual(generated.union(imported).union(renders), all)
    }

    /// The old Songs scope was "not a render", so an import landed in it. This
    /// is the behaviour change, stated as a test.
    func testImportedIsNotAGeneratedSong() throws {
        let repo = try seeded()
        XCTAssertFalse(try ids(repo, .generated).contains("i1"))
    }

    func testCountsByOriginMatchTheRows() throws {
        let repo = try seeded()
        let counts = try repo.countsByOrigin()
        XCTAssertEqual(counts[SongOrigin.generated.rawValue], 2)
        XCTAssertEqual(counts[SongOrigin.imported.rawValue], 1)
        XCTAssertEqual(counts[SongOrigin.recombined.rawValue], 1)
    }

    /// Every scope maps to the shelf its list is meant to show. Guards the
    /// wiring between the sidebar enum and the query.
    func testScopeShelfMapping() {
        XCTAssertEqual(LibraryScope.songs.shelf, .made)
        XCTAssertEqual(LibraryScope.imported.shelf, .imported)
        XCTAssertNil(LibraryScope.all.shelf)
        XCTAssertNil(LibraryScope.parts.shelf)
        XCTAssertNil(LibraryScope.favourites.shelf)
    }

    /// The Generated scope asks for both of its origins, and All asks for no
    /// narrowing at all — the two ends of the fold, stated as a query.
    func testScopeOriginFilters() {
        XCTAssertEqual(LibraryScope.songs.originFilter,
                       .anyOf(["generated", "recombined"]))
        XCTAssertEqual(LibraryScope.imported.originFilter, .only("imported"))
        XCTAssertEqual(LibraryScope.all.originFilter, .any)
        XCTAssertEqual(LibraryScope.favourites.originFilter, .any)
    }

    /// The shelf a render is on, which is the behaviour change: a Workbench mix
    /// and a Studio take are found in the same list.
    func testARenderSharesTheGeneratedShelf() throws {
        let repo = try seeded()
        var filters = LibraryRepository.Filters()
        filters.origin = LibraryScope.songs.originFilter
        XCTAssertEqual(Set(try repo.search(filters).map(\.id)),
                       ["g1", "g2", "r1"])
        XCTAssertEqual(SongShelf(origin: .recombined), .made)
        XCTAssertEqual(SongShelf(origin: .generated), .made)
        XCTAssertEqual(SongShelf(origin: .imported), .imported)
    }

    /// …and the shelves still partition the table: nothing is on both, nothing
    /// is on neither.
    func testShelvesArePartition() throws {
        let repo = try seeded()
        func ids(_ shelf: SongShelf) throws -> Set<String> {
            var filters = LibraryRepository.Filters()
            filters.origin = .anyOf(Set(shelf.origins.map(\.rawValue)))
            return Set(try repo.search(filters).map(\.id))
        }
        let made = try ids(.made)
        let imported = try ids(.imported)
        XCTAssertTrue(made.isDisjoint(with: imported))
        XCTAssertEqual(made.union(imported),
                       Set(try repo.search(.init()).map(\.id)))
    }

    func testGeneratedScopeIsLabelledAsSuch() {
        XCTAssertEqual(LibraryScope.songs.title, "Generated")
        XCTAssertEqual(LibraryScope.imported.title, "Imported")
    }

    /// The Library row is a place, not a lid: `all` is a scope of its own and
    /// deliberately absent from the rows drawn under it.
    func testAllIsTheLibraryRowAndNotASubRow() {
        XCTAssertTrue(LibraryScope.allCases.contains(.all))
        XCTAssertFalse(LibraryScope.sidebarScopes.contains(.all))
        XCTAssertEqual(LibraryScope.sidebarScopes,
                       [.songs, .imported, .parts, .edited, .favourites])
    }

    /// Both scopes that list tracks *and* parts have to say so — the composed
    /// list, the either-kind selection and the two-store search all hang off it.
    func testTheSpanningScopesAreAllAndFavourites() {
        XCTAssertEqual(LibraryScope.allCases.filter(\.spansBothTables),
                       [.all, .favourites])
    }

    /// A render is marked on its row, which is what is left of the scope it
    /// used to have. Nothing else is: a mark on every second row would be
    /// labelling the list from inside it.
    func testOnlyARenderMarksItsRow() {
        XCTAssertEqual(SongOrigin.recombined.rowMark, "Render")
        XCTAssertNil(SongOrigin.generated.rowMark)
        XCTAssertNil(SongOrigin.imported.rowMark)
    }

    @MainActor
    func testTheMetaLineLeadsWithTheRenderMark() {
        let render = LibrarySongRow.metaLine(
            for: song(id: "r", origin: .recombined), partCount: 0)
        let take = LibrarySongRow.metaLine(
            for: song(id: "g", origin: .generated), partCount: 0)
        XCTAssertTrue(render.hasPrefix("RENDER · M · "), render)
        XCTAssertTrue(take.hasPrefix("M · "), take)
    }

    // MARK: origin typing

    func testOriginKindReadsTheColumn() {
        XCTAssertEqual(song(id: "a", origin: .imported).originKind, .imported)
        XCTAssertEqual(song(id: "b", origin: .recombined).originKind,
                       .recombined)
    }

    /// A row written by a later build carrying an origin this one has never
    /// heard of still has to appear somewhere rather than vanishing.
    func testUnknownOriginFallsBackToGenerated() {
        var row = song(id: "x", origin: .generated)
        row.origin = "from-the-future"
        XCTAssertEqual(row.originKind, .generated)
    }

    // MARK: artist

    func testArtistFilterNarrowsToOnePerformer() throws {
        let repo = try makeRepo()
        try repo.insert(song(id: "i1", origin: .imported, artist: "Aurora Halo"))
        try repo.insert(song(id: "i2", origin: .imported, artist: "Aurora Halo"))
        try repo.insert(song(id: "i3", origin: .imported, artist: "Other Band"))

        var filters = LibraryRepository.Filters()
        filters.artist = "Aurora Halo"
        XCTAssertEqual(Set(try repo.search(filters).map(\.id)), ["i1", "i2"])
    }

    func testDistinctArtistsSkipsUntaggedAndBlankRows() throws {
        let repo = try makeRepo()
        try repo.insert(song(id: "i1", origin: .imported, artist: "Zephyr"))
        try repo.insert(song(id: "i2", origin: .imported, artist: "Aurora"))
        try repo.insert(song(id: "i3", origin: .imported, artist: "Aurora"))
        try repo.insert(song(id: "i4", origin: .imported, artist: "   "))
        try repo.insert(song(id: "i5", origin: .imported))

        XCTAssertEqual(try repo.distinctArtists(), ["Aurora", "Zephyr"])
    }

    /// The meta line leads with the artist for an import and the model for a
    /// generation, so one label serves both kinds of row.
    func testSourceLabelPrefersTheArtist() {
        XCTAssertEqual(
            song(id: "i", origin: .imported, artist: "Aurora Halo").sourceLabel,
            "Aurora Halo")
        XCTAssertEqual(song(id: "g", origin: .generated).sourceLabel, "M")
    }

    func testSourceLabelIgnoresABlankArtist() {
        XCTAssertEqual(
            song(id: "i", origin: .imported, artist: "  ").sourceLabel, "M")
    }
}

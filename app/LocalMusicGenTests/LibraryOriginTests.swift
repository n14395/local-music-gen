import GRDB
import XCTest
@testable import LocalMusicGen

/// The Library's scopes are three disjoint reads of one table. These pin the
/// split itself — the regression that matters is an imported track showing up
/// under Generated Songs, which is exactly what the old
/// `origin != "recombined"` definition did.
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

    func testEachScopeSeesOnlyItsOwnOrigin() throws {
        let repo = try seeded()
        XCTAssertEqual(try ids(repo, .generated), ["g1", "g2"])
        XCTAssertEqual(try ids(repo, .imported), ["i1"])
        XCTAssertEqual(try ids(repo, .recombined), ["r1"])
    }

    /// The three scopes partition the table: nothing is in two of them, and
    /// nothing falls between them into no scope at all.
    func testScopesArePartition() throws {
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

    func testCountsByOriginMatchTheScopes() throws {
        let repo = try seeded()
        let counts = try repo.countsByOrigin()
        XCTAssertEqual(counts[SongOrigin.generated.rawValue], 2)
        XCTAssertEqual(counts[SongOrigin.imported.rawValue], 1)
        XCTAssertEqual(counts[SongOrigin.recombined.rawValue], 1)
    }

    /// Every scope maps to the origin its list is meant to show. Guards the
    /// wiring between the sidebar enum and the query.
    func testScopeOriginMapping() {
        XCTAssertEqual(LibraryScope.songs.origin, .generated)
        XCTAssertEqual(LibraryScope.imported.origin, .imported)
        XCTAssertEqual(LibraryScope.renders.origin, .recombined)
        XCTAssertNil(LibraryScope.parts.origin)
        XCTAssertNil(LibraryScope.favourites.origin)
    }

    func testGeneratedScopeIsLabelledAsSuch() {
        XCTAssertEqual(LibraryScope.songs.title, "Generated")
        XCTAssertEqual(LibraryScope.imported.title, "Imported")
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

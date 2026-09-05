import XCTest
@testable import LocalMusicGen

final class PartsRepositoryTests: XCTestCase {
    private struct Fixture {
        let library: LibraryRepository
        let parts: PartsRepository
    }

    private func makeFixture() throws -> Fixture {
        let db = try DatabaseManager.inMemory()
        return Fixture(library: LibraryRepository(db: db),
                       parts: PartsRepository(db: db))
    }

    private func song(id: String, title: String) -> SongRecord {
        SongRecord(id: id, title: title, prompt: "p", lyrics: nil,
                   modelId: "m", modelName: "M", groupId: nil, paramsJSON: "{}",
                   durationS: 10, sampleRate: 32000, fileName: id + ".wav",
                   seedUsed: nil, createdAt: Date(), rating: 0, notes: "",
                   favorite: false)
    }

    private func part(id: String, songId: String, kind: String,
                      name: String) -> PartRecord {
        PartRecord(id: id, songId: songId, kind: kind, name: name,
                   fileName: id + ".wav", format: "wav", previewFileName: nil,
                   modelId: "sep", modelName: "Separator", jobId: "job_1",
                   splitParamsJSON: "{}", durationS: 10, sampleRate: 44100,
                   createdAt: Date())
    }

    func testFiltersByKindPrefixAndSong() throws {
        let fx = try makeFixture()
        try fx.library.insert(song(id: "s1", title: "Alpha"))
        try fx.library.insert(song(id: "s2", title: "Beta"))
        try fx.parts.insert(part(id: "p1", songId: "s1", kind: "stem.vocals",
                                 name: "Vocals"))
        try fx.parts.insert(part(id: "p2", songId: "s1", kind: "notes.piano",
                                 name: "Piano"))
        try fx.parts.insert(part(id: "p3", songId: "s2", kind: "stem.drums",
                                 name: "Drums"))

        var filters = PartsRepository.Filters()
        filters.kindPrefix = "stem."
        XCTAssertEqual(try fx.parts.parts(filters).count, 2)
        filters.songId = "s1"
        XCTAssertEqual(try fx.parts.parts(filters).map(\.id), ["p1"])

        filters = PartsRepository.Filters()
        filters.query = "Beta"      // matches via the source song's title
        XCTAssertEqual(try fx.parts.parts(filters).map(\.id), ["p3"])
    }

    func testBpmAndCamelotFilterViaAnalysisJoin() throws {
        let fx = try makeFixture()
        try fx.library.insert(song(id: "s1", title: "Alpha"))
        try fx.parts.insert(part(id: "p1", songId: "s1", kind: "stem.vocals",
                                 name: "Vocals"))
        try fx.parts.insert(part(id: "p2", songId: "s1", kind: "stem.drums",
                                 name: "Drums"))
        try fx.parts.upsertAnalysis(AnalysisRecord(
            ownerId: "p1", ownerType: "part", bpm: 128, keyName: "A minor",
            camelot: "8A", analysisJSON: "{}", modelId: "an", createdAt: Date()))
        try fx.parts.upsertAnalysis(AnalysisRecord(
            ownerId: "p2", ownerType: "part", bpm: 90, keyName: "C major",
            camelot: "8B", analysisJSON: "{}", modelId: "an", createdAt: Date()))

        var filters = PartsRepository.Filters()
        filters.bpmRange = 120...140
        XCTAssertEqual(try fx.parts.parts(filters).map(\.id), ["p1"])
        filters = PartsRepository.Filters()
        filters.camelot = "8B"
        XCTAssertEqual(try fx.parts.parts(filters).map(\.id), ["p2"])
    }

    func testUpsertAnalysisReplaces() throws {
        let fx = try makeFixture()
        try fx.library.insert(song(id: "s1", title: "Alpha"))
        try fx.parts.upsertAnalysis(AnalysisRecord(
            ownerId: "s1", ownerType: "song", bpm: 100, keyName: nil,
            camelot: nil, analysisJSON: "{}", modelId: "an", createdAt: Date()))
        try fx.parts.upsertAnalysis(AnalysisRecord(
            ownerId: "s1", ownerType: "song", bpm: 124, keyName: "E minor",
            camelot: "9A", analysisJSON: "{}", modelId: "an", createdAt: Date()))
        let record = try fx.parts.analysis(ownerId: "s1")
        XCTAssertEqual(record?.bpm, 124)
        XCTAssertEqual(record?.camelot, "9A")
    }

    func testDeletePartAlsoRemovesAnalysis() throws {
        let fx = try makeFixture()
        try fx.library.insert(song(id: "s1", title: "Alpha"))
        try fx.parts.insert(part(id: "p1", songId: "s1", kind: "stem.vocals",
                                 name: "Vocals"))
        try fx.parts.upsertAnalysis(AnalysisRecord(
            ownerId: "p1", ownerType: "part", bpm: 128, keyName: nil,
            camelot: nil, analysisJSON: "{}", modelId: "an", createdAt: Date()))
        try fx.parts.delete(id: "p1")
        XCTAssertNil(try fx.parts.part(id: "p1"))
        XCTAssertNil(try fx.parts.analysis(ownerId: "p1"))
    }

    func testIngredientsRoundTrip() throws {
        let fx = try makeFixture()
        try fx.library.insert(song(id: "s1", title: "Mix"))
        let rows = [
            SongIngredientRecord(songId: "s1", slotId: "vocals", partId: "p1",
                                 sourceSongTitle: "Alpha",
                                 transformJSON: #"{"gain_db":-1.5}"#),
            SongIngredientRecord(songId: "s1", slotId: "backing", partId: nil,
                                 sourceSongTitle: "Beta", transformJSON: "{}"),
        ]
        try fx.parts.setIngredients(rows, songId: "s1")
        // Fetch order is by slotId.
        XCTAssertEqual(try fx.parts.ingredients(songId: "s1"), [rows[1], rows[0]])
        // Replacement, not accumulation.
        try fx.parts.setIngredients([rows[0]], songId: "s1")
        XCTAssertEqual(try fx.parts.ingredients(songId: "s1").count, 1)
    }

    // MARK: - favourites (the Library's cross-cutting scope)

    /// Parts arrive unhearted, and the flag survives a write/read round trip.
    func testPartsStartUnfavouritedAndCanBeHearted() throws {
        let fx = try makeFixture()
        try fx.library.insert(song(id: "s1", title: "Alpha"))
        var p = part(id: "p1", songId: "s1", kind: "stem.vocals", name: "Vocals")
        try fx.parts.insert(p)
        XCTAssertFalse(try XCTUnwrap(fx.parts.part(id: "p1")).favorite,
                       "a fresh part is not a favourite")

        p.favorite = true
        try fx.parts.update(p)
        XCTAssertTrue(try XCTUnwrap(fx.parts.part(id: "p1")).favorite)
    }

    func testFavouritesReadBothWaysAgree() throws {
        let fx = try makeFixture()
        try fx.library.insert(song(id: "s1", title: "Alpha"))
        var hearted = part(id: "p1", songId: "s1", kind: "stem.vocals",
                           name: "Vocals")
        hearted.favorite = true
        try fx.parts.insert(hearted)
        try fx.parts.insert(part(id: "p2", songId: "s1", kind: "stem.drums",
                                 name: "Drums"))

        XCTAssertEqual(try fx.parts.favorites().map(\.id), ["p1"])
        var filters = PartsRepository.Filters()
        filters.favoritesOnly = true
        XCTAssertEqual(try fx.parts.parts(filters).map(\.id), ["p1"],
                       "the filter and the direct query must agree")
        XCTAssertEqual(try fx.parts.parts(.init()).count, 2,
                       "the default filter still shows everything")
    }

    /// The song half of the same scope, counted across origins — a hearted
    /// render belongs in Favourites as much as a hearted generation.
    func testFavouriteSongCountSpansOrigins() throws {
        let fx = try makeFixture()
        var generated = song(id: "s1", title: "Alpha")
        generated.favorite = true
        var render = song(id: "s2", title: "Mix")
        render.origin = "recombined"
        render.favorite = true
        try fx.library.insert(generated)
        try fx.library.insert(render)
        try fx.library.insert(song(id: "s3", title: "Not hearted"))

        XCTAssertEqual(try fx.library.favoriteCount(), 2)
        var filters = LibraryRepository.Filters()
        filters.favoritesOnly = true
        XCTAssertEqual(Set(try fx.library.search(filters).map(\.id)),
                       ["s1", "s2"])
    }
}

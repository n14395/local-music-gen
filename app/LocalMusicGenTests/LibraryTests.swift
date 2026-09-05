import XCTest
@testable import LocalMusicGen

final class LibraryTests: XCTestCase {
    private func makeRepo() throws -> LibraryRepository {
        LibraryRepository(db: try DatabaseManager.inMemory())
    }

    private func song(id: String = UUID().uuidString, title: String,
                      prompt: String, model: String = "musicgen-small",
                      rating: Int = 0, group: String? = nil) -> SongRecord {
        SongRecord(id: id, title: title, prompt: prompt, lyrics: nil,
                   modelId: model, modelName: model, groupId: group,
                   paramsJSON: "{}", durationS: 10, sampleRate: 32000,
                   fileName: id + ".wav", seedUsed: 7, createdAt: Date(),
                   rating: rating, notes: "", favorite: false)
    }

    func testInsertAndFetch() throws {
        let repo = try makeRepo()
        try repo.insert(song(id: "a", title: "First", prompt: "warm lo-fi"))
        let fetched = try repo.song(id: "a")
        XCTAssertEqual(fetched?.title, "First")
        XCTAssertEqual(try repo.recent().count, 1)
    }

    func testFTSSearch() throws {
        let repo = try makeRepo()
        try repo.insert(song(title: "Synthwave dream", prompt: "dreamy synthwave with saxophone"))
        try repo.insert(song(title: "Lo-fi", prompt: "warm vinyl crackle beat"))

        var filters = LibraryRepository.Filters()
        filters.query = "saxo"
        XCTAssertEqual(try repo.search(filters).count, 1, "prefix match")
        filters.query = "vinyl crackle"
        XCTAssertEqual(try repo.search(filters).count, 1)
        filters.query = "nothing-matches"
        XCTAssertEqual(try repo.search(filters).count, 0)
    }

    func testSearchReflectsEdits() throws {
        let repo = try makeRepo()
        var record = song(id: "e", title: "Edit me", prompt: "plain prompt")
        try repo.insert(record)
        record.notes = "glorious trumpet solo"
        try repo.update(record)

        var filters = LibraryRepository.Filters()
        filters.query = "trumpet"
        XCTAssertEqual(try repo.search(filters).count, 1,
                       "FTS index must follow updates")
    }

    func testFiltersAndRating() throws {
        let repo = try makeRepo()
        try repo.insert(song(title: "A", prompt: "x", model: "m1", rating: 5))
        try repo.insert(song(title: "B", prompt: "y", model: "m2", rating: 2))

        var filters = LibraryRepository.Filters()
        filters.modelId = "m1"
        XCTAssertEqual(try repo.search(filters).map(\.title), ["A"])
        filters = .init()
        filters.minRating = 3
        XCTAssertEqual(try repo.search(filters).map(\.title), ["A"])
    }

    func testTags() throws {
        let repo = try makeRepo()
        try repo.insert(song(id: "t", title: "Tagged", prompt: "p"))
        try repo.setTags(["chill", "demo"], for: "t")
        XCTAssertEqual(try repo.tags(for: "t"), ["chill", "demo"])
        try repo.setTags(["chill"], for: "t")
        XCTAssertEqual(try repo.tags(for: "t"), ["chill"])

        var filters = LibraryRepository.Filters()
        filters.tag = "chill"
        XCTAssertEqual(try repo.search(filters).count, 1)
        filters.tag = "demo"
        XCTAssertEqual(try repo.search(filters).count, 0)
    }

    func testDelete() throws {
        let repo = try makeRepo()
        try repo.insert(song(id: "g1", title: "One", prompt: "p", group: "grp_x"))
        try repo.insert(song(id: "g2", title: "Two", prompt: "p", group: "grp_x"))
        try repo.delete(id: "g1")
        XCTAssertNil(try repo.song(id: "g1"))
        XCTAssertNotNil(try repo.song(id: "g2"))
    }
}

/// Where a library list was scrolled to, and the two ways that has to survive:
/// the trip to another screen and back, and something else asking for a row.
@MainActor
final class LibraryScrollMemoryTests: XCTestCase {

    // MARK: which row is "where the list is"

    private func anchor(_ id: String, _ y: CGFloat) -> LibraryScrollAnchor {
        LibraryScrollAnchor(id: id, y: y)
    }

    /// The row covering the top edge is the one you are looking at, however
    /// many rows are on screen below it.
    func testTopmostIsTheRowCoveringTheTopEdge() {
        var value: LibraryScrollAnchor?
        for row in [anchor("a", -120), anchor("b", -18), anchor("c", 44),
                    anchor("d", 106)] {
            LibraryScrollAnchorKey.reduce(value: &value) { row }
        }
        XCTAssertEqual(value, anchor("b", -18))
    }

    /// Scrolled right to the top there is no row past the edge, so the first
    /// one below it is the answer rather than nothing at all.
    func testTopmostFallsBackToTheFirstRowBelowTheEdge() {
        var value: LibraryScrollAnchor?
        for row in [anchor("a", 8), anchor("b", 70), anchor("c", 132)] {
            LibraryScrollAnchorKey.reduce(value: &value) { row }
        }
        XCTAssertEqual(value, anchor("a", 8))
    }

    /// The reduce runs over the rows in whatever order the lazy stack holds
    /// them, so the answer must not depend on that order.
    func testTopmostIsOrderIndependent() {
        let rows = [anchor("a", -120), anchor("b", -18), anchor("c", 44)]
        for permutation in [rows, rows.reversed(), [rows[2], rows[0], rows[1]]] {
            var value: LibraryScrollAnchor?
            for row in permutation {
                LibraryScrollAnchorKey.reduce(value: &value) { row }
            }
            XCTAssertEqual(value, anchor("b", -18))
        }
    }

    // MARK: what is remembered

    /// The bug the recording gate exists for: a list is built at the top and
    /// reports row 0 before the restore has had a frame to run, which would
    /// overwrite the very anchor it is on its way back to.
    func testReportsBeforeTheRestoreAreIgnored() {
        let memory = LibraryScrollMemory()
        memory.beginRecording(.songs)
        memory.record("row-40", for: .songs)
        memory.endRecording(.songs)

        memory.record("row-0", for: .songs)
        XCTAssertEqual(memory.anchor(for: .songs), "row-40")

        memory.beginRecording(.songs)
        memory.record("row-12", for: .songs)
        XCTAssertEqual(memory.anchor(for: .songs), "row-12")
    }

    /// Each scope is scrolled where it is scrolled. Coming back to Parts must
    /// not land where Generated was left.
    func testScopesAreRememberedApart() {
        let memory = LibraryScrollMemory()
        for scope in [LibraryScope.songs, .parts] { memory.beginRecording(scope) }
        memory.record("song-9", for: .songs)
        memory.record("part-3", for: .parts)
        XCTAssertEqual(memory.anchor(for: .songs), "song-9")
        XCTAssertEqual(memory.anchor(for: .parts), "part-3")
        XCTAssertNil(memory.anchor(for: .imported))
    }

    /// A reveal outranks the memory — you pressed a button to see that row —
    /// and it lands even though no list is recording at the time.
    func testAPinnedRowOutranksWhatWasRecorded() {
        let memory = LibraryScrollMemory()
        memory.beginRecording(.songs)
        memory.record("row-40", for: .songs)
        memory.endRecording(.songs)
        memory.pin("revealed", for: .songs)
        XCTAssertEqual(memory.anchor(for: .songs), "revealed")
    }

    /// Nothing to restore before anything has been scrolled: a first visit
    /// starts at the top, not at a row picked by accident.
    func testAFreshMemoryRestoresNothing() {
        XCTAssertNil(LibraryScrollMemory().anchor(for: .songs))
    }
}


import GRDB
import XCTest
@testable import LocalMusic

/// Renaming a track, and the two things that depend on a track's name being
/// worth something.
///
/// A part does not store its source's title — it stores `songId`, and every
/// readout that names the source resolves it at the point of drawing. That is
/// what makes a rename show up on the parts, and the first group of tests pins
/// it, because the alternative (denormalising the title onto `part`) is an
/// easy-looking change that would silently break it.
///
/// The second group is the reason names have to be unique: those same readouts
/// print a title alone, with no id beside it, so two tracks called the same
/// thing make the Parts list unreadable.
final class SongRenameTests: XCTestCase {
    private func song(id: String, title: String) -> SongRecord {
        SongRecord(id: id, title: title, prompt: "", lyrics: nil,
                   modelId: "m", modelName: "M", groupId: nil,
                   paramsJSON: "{}", durationS: 10, sampleRate: 32000,
                   fileName: id + ".wav", seedUsed: nil, createdAt: Date(),
                   rating: 0, notes: "", favorite: false,
                   origin: SongOrigin.generated.rawValue, artist: nil)
    }

    private func part(id: String, songId: String) -> PartRecord {
        PartRecord(id: id, songId: songId, kind: "stem.vocals", name: "Vocals",
                   fileName: id + ".wav", format: "wav", previewFileName: nil,
                   modelId: "demucs", modelName: "Demucs 4-stem", jobId: nil,
                   splitParamsJSON: "{}", durationS: 10, sampleRate: 44100,
                   createdAt: Date())
    }

    // MARK: - A part follows its source's name

    /// The regression the user reported: rename the track, and the name the
    /// parts are filed under has to move with it.
    func testPartsReportTheRenamedTitle() throws {
        let db = try DatabaseManager.inMemory()
        let library = LibraryRepository(db: db)
        let parts = PartsRepository(db: db)
        try library.insert(song(id: "s1", title: "track01"))
        try parts.insert(part(id: "p1", songId: "s1"))

        var stored = try XCTUnwrap(library.song(id: "s1"))
        stored.title = "track01-test"
        try library.update(stored)

        // What the Parts list and the inspector's "From" row both do.
        let part = try XCTUnwrap(parts.allParts(forSong: "s1").first)
        XCTAssertEqual(try library.song(id: part.songId)?.title, "track01-test")
    }

    /// Nothing on the part row carries a name that could go stale. Written as
    /// an assertion about the record rather than a comment so that adding one
    /// fails here.
    func testAPartStoresNoCopyOfItsSourceTitle() throws {
        let encoded = try JSONEncoder().encode(part(id: "p1", songId: "s1"))
        let keys = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]).keys
        XCTAssertFalse(keys.contains { $0.lowercased().contains("songtitle") })
        XCTAssertEqual(part(id: "p1", songId: "s1").songId, "s1")
    }

    // MARK: - Names are unique

    func testATitleAnotherSongHasIsTaken() throws {
        let repo = LibraryRepository(db: try DatabaseManager.inMemory())
        try repo.insert(song(id: "s1", title: "track01"))
        try repo.insert(song(id: "s2", title: "track02"))
        XCTAssertTrue(try repo.titleIsTaken("track01", excluding: "s2"))
        XCTAssertFalse(try repo.titleIsTaken("track03", excluding: "s2"))
    }

    /// A song never collides with itself — otherwise committing a name
    /// unchanged, which `flush` does on every navigation, would refuse it.
    func testASongDoesNotCollideWithItself() throws {
        let repo = LibraryRepository(db: try DatabaseManager.inMemory())
        try repo.insert(song(id: "s1", title: "track01"))
        XCTAssertFalse(try repo.titleIsTaken("track01", excluding: "s1"))
    }

    /// Case is not a difference anyone reading the list can act on.
    func testTheCheckIgnoresCase() throws {
        let repo = LibraryRepository(db: try DatabaseManager.inMemory())
        try repo.insert(song(id: "s1", title: "Track01"))
        XCTAssertTrue(try repo.titleIsTaken("track01", excluding: "s2"))
        XCTAssertTrue(try repo.titleIsTaken("TRACK01", excluding: "s2"))
    }

    // MARK: - What the editor does with a refusal

    @MainActor
    private func store() throws -> (LibraryStore, LibraryRepository) {
        let db = try DatabaseManager.inMemory()
        let repo = LibraryRepository(db: db)
        return (LibraryStore(repo: repo), repo)
    }

    @MainActor
    func testRenamingToATakenNameIsRefusedAndExplained() throws {
        let (library, repo) = try store()
        try repo.insert(song(id: "s1", title: "track01"))
        try repo.insert(song(id: "s2", title: "track02"))

        let editor = SongEditor()
        editor.load(try XCTUnwrap(library.song(id: "s2")), in: library)
        editor.title = "track01"
        editor.commitTitle(in: library)

        XCTAssertEqual(library.song(id: "s2")?.title, "track02",
                       "the stored name must not have moved")
        XCTAssertEqual(editor.title, "track02",
                       "the field springs back to the stored name")
        XCTAssertNotNil(editor.titleError,
                        "and says why, or the revert reads as dropped input")
    }

    @MainActor
    func testAFreeNameIsAcceptedAndClearsTheError() throws {
        let (library, repo) = try store()
        try repo.insert(song(id: "s1", title: "track01"))
        try repo.insert(song(id: "s2", title: "track02"))

        let editor = SongEditor()
        editor.load(try XCTUnwrap(library.song(id: "s2")), in: library)
        editor.title = "track01"
        editor.commitTitle(in: library)
        XCTAssertNotNil(editor.titleError)

        editor.title = "track02-test"
        editor.commitTitle(in: library)
        XCTAssertEqual(library.song(id: "s2")?.title, "track02-test")
        XCTAssertNil(editor.titleError)
    }

    /// Re-casing your own track is a rename, not a collision.
    @MainActor
    func testASongCanChangeItsOwnCase() throws {
        let (library, repo) = try store()
        try repo.insert(song(id: "s1", title: "track01"))

        let editor = SongEditor()
        editor.load(try XCTUnwrap(library.song(id: "s1")), in: library)
        editor.title = "Track01"
        editor.commitTitle(in: library)

        XCTAssertEqual(library.song(id: "s1")?.title, "Track01")
        XCTAssertNil(editor.titleError)
    }

    /// The blank case still behaves as it did, and does not leave a stale
    /// refusal on screen.
    @MainActor
    func testABlankNameStillFallsBackWithoutAnError() throws {
        let (library, repo) = try store()
        try repo.insert(song(id: "s1", title: "track01"))

        let editor = SongEditor()
        editor.load(try XCTUnwrap(library.song(id: "s1")), in: library)
        editor.title = "   "
        editor.commitTitle(in: library)

        XCTAssertEqual(editor.title, "track01")
        XCTAssertNil(editor.titleError)
    }
}

/// The two places a song's name was copied rather than resolved.
///
/// `songIngredient.sourceSongTitle` is written when a mix renders and is what
/// the "Ingredients" list on a render prints. It has to stay — it is the only
/// thing left to print once the source part has been deleted — but while the
/// source *is* still there, the current name is the right one to show.
final class IngredientTitleTests: XCTestCase {
    private func song(id: String, title: String) -> SongRecord {
        SongRecord(id: id, title: title, prompt: "", lyrics: nil,
                   modelId: "m", modelName: "M", groupId: nil,
                   paramsJSON: "{}", durationS: 10, sampleRate: 32000,
                   fileName: id + ".wav", seedUsed: nil, createdAt: Date(),
                   rating: 0, notes: "", favorite: false,
                   origin: SongOrigin.generated.rawValue, artist: nil)
    }

    private func part(id: String, songId: String) -> PartRecord {
        PartRecord(id: id, songId: songId, kind: "stem.vocals", name: "Vocals",
                   fileName: id + ".wav", format: "wav", previewFileName: nil,
                   modelId: "demucs", modelName: "Demucs 4-stem", jobId: nil,
                   splitParamsJSON: "{}", durationS: 10, sampleRate: 44100,
                   createdAt: Date())
    }

    private func ingredient(sourceId: String?, storedTitle: String)
        -> SongIngredientRecord {
        SongIngredientRecord(songId: "render1", slotId: "vocals-1",
                             partId: sourceId, sourceSongTitle: storedTitle,
                             transformJSON: "{}")
    }

    @MainActor
    private func store() throws
        -> (LibraryStore, LibraryRepository, PartsRepository) {
        let db = try DatabaseManager.inMemory()
        let library = LibraryRepository(db: db)
        let parts = PartsRepository(db: db)
        return (LibraryStore(repo: library, partsRepo: parts), library, parts)
    }

    /// The reported bug: rename the track a render was built from, and the
    /// render kept naming it whatever it was called on the day it rendered.
    @MainActor
    func testAPartIngredientReportsTheRenamedTitle() throws {
        let (store, library, parts) = try store()
        try library.insert(song(id: "s1", title: "track01"))
        try parts.insert(part(id: "p1", songId: "s1"))

        var stored = try XCTUnwrap(library.song(id: "s1"))
        stored.title = "track01-test"
        try library.update(stored)

        XCTAssertEqual(
            store.sourceTitle(for: ingredient(sourceId: "p1",
                                              storedTitle: "track01")),
            "track01-test")
    }

    /// An ingredient can name a whole song rather than a part —
    /// `JobsStore.resolveIngredient` accepts either.
    @MainActor
    func testAWholeSongIngredientAlsoResolvesLive() throws {
        let (store, library, _) = try store()
        try library.insert(song(id: "s1", title: "track01"))

        var stored = try XCTUnwrap(library.song(id: "s1"))
        stored.title = "track01-test"
        try library.update(stored)

        XCTAssertEqual(
            store.sourceTitle(for: ingredient(sourceId: "s1",
                                              storedTitle: "track01")),
            "track01-test")
    }

    /// The tombstone still has to work: once the source is gone the stored
    /// copy is all there is, and a render that names a deleted take reads far
    /// better than one that names nothing.
    @MainActor
    func testADeletedSourceFallsBackToTheStoredName() throws {
        let (store, _, _) = try store()
        XCTAssertEqual(
            store.sourceTitle(for: ingredient(sourceId: "gone",
                                              storedTitle: "deleted take")),
            "deleted take")
    }

    @MainActor
    func testAnIngredientWithNoSourceIdUsesTheStoredName() throws {
        let (store, _, _) = try store()
        XCTAssertEqual(
            store.sourceTitle(for: ingredient(sourceId: nil,
                                              storedTitle: "whatever it was")),
            "whatever it was")
    }
}

/// Export copies the file, so the name it offers has to match what is actually
/// written.
final class ExportNameTests: XCTestCase {
    func testTheRealExtensionIsKept() {
        XCTAssertEqual(
            SongDetailView.exportName(title: "Midnight Drive",
                                      fileName: "abc123.mp3"),
            "Midnight Drive.mp3")
        XCTAssertEqual(
            SongDetailView.exportName(title: "track01", fileName: "abc.flac"),
            "track01.flac")
    }

    /// A slash in a title is a path separator in a filename.
    func testSlashesInTheTitleAreNeutralised() {
        XCTAssertEqual(
            SongDetailView.exportName(title: "AC/DC bootleg",
                                      fileName: "abc.wav"),
            "AC-DC bootleg.wav")
    }

    func testAnExtensionlessFileGetsNoDot() {
        XCTAssertEqual(
            SongDetailView.exportName(title: "track01", fileName: "abc"),
            "track01")
    }
}

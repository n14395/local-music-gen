// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import GRDB
import XCTest
@testable import LocalMusicGen

/// A part is a thing in the library, so it has a name.
///
/// It used to have a label instead — every stem called "Vocals" or "Drums",
/// repeated once per song — which named a kind rather than a part. These
/// tests pin the four rules that replaced it: what the automatic name is, that
/// it is unique, that renaming refuses a duplicate the way a track's title
/// does, and that a name follows its song unless the user has typed one.
final class PartNamingTests: XCTestCase {

    // MARK: - The name itself

    func testASongTitleBecomesASlug() {
        XCTAssertEqual(PartNaming.slug("track042"), "track042")
        XCTAssertEqual(PartNaming.slug("Warehouse jam"), "warehouse-jam")
        XCTAssertEqual(PartNaming.slug("Midnight Drive (2)"), "midnight-drive-2")
        // Runs of punctuation collapse, and never leave a trailing hyphen.
        XCTAssertEqual(PartNaming.slug("  ...Hello -- World!  "), "hello-world")
        XCTAssertEqual(PartNaming.slug("   "), "")
    }

    /// Letters outside ASCII are letters. Folding "Café" to "caf" would make
    /// two differently-named songs produce one part name.
    func testNonASCIILettersSurvive() {
        XCTAssertEqual(PartNaming.slug("Café Sessions"), "café-sessions")
    }

    /// A prompt pasted into the title field makes a legal title and a useless
    /// name, so the slug is cut — on a word boundary, so what is left reads as
    /// a short name rather than a typo.
    func testALongTitleIsCutAtAWordBoundary() {
        let long = "a lonely trumpet over rain slicked neon streets at dawn"
        let slug = PartNaming.slug(long, limit: 40)
        XCTAssertLessThanOrEqual(slug.count, 40)
        XCTAssertFalse(slug.hasSuffix("-"))
        XCTAssertEqual(slug, "a-lonely-trumpet-over-rain-slicked-neon")
    }

    /// A single word longer than the limit has no boundary to cut at, so it is
    /// cut where the limit falls rather than returned whole.
    func testAWordWithNoBoundaryIsCutAnyway() {
        let slug = PartNaming.slug(String(repeating: "x", count: 60), limit: 40)
        XCTAssertEqual(slug.count, 40)
    }

    func testTheLabelSaysWhatTheKindIs() {
        XCTAssertEqual(PartNaming.label(kind: "stem.vocals"), "Vocals")
        XCTAssertEqual(PartNaming.label(kind: "notes.piano"), "Piano")
        XCTAssertEqual(PartNaming.label(kind: "layer.lead-synth"), "Lead Synth")
        // Separation jargon for the residual, spelled out — the one label the
        // old names carried that a slug could not.
        XCTAssertEqual(PartNaming.label(kind: "stem.other"),
                       "Other (keys, synths, rest)")
        XCTAssertEqual(PartNaming.qualifier(kind: "stem.other"),
                       "keys, synths, rest")
        XCTAssertNil(PartNaming.qualifier(kind: "stem.vocals"))
    }

    /// What it is, then where it came from — the kind leads, because it is
    /// the short bounded half and the half that tells one row from its
    /// neighbour.
    func testAStemIsNamedForWhatItIsThenWhereItCameFrom() {
        XCTAssertEqual(
            PartNaming.defaultName(songTitle: "track042", kind: "stem.vocals"),
            "vocals-track042")
        XCTAssertEqual(
            PartNaming.defaultName(songTitle: "Warehouse jam",
                                   kind: "stem.other"),
            "other-warehouse-jam")
    }

    /// The MIDI notes of a piano part and the audio rendered from them are two
    /// parts of one song, and must not want one name.
    func testNotesAndTheLayerRenderedFromThemDoNotCollide() {
        let notes = PartNaming.defaultName(songTitle: "track042",
                                           kind: "notes.piano")
        let layer = PartNaming.defaultName(songTitle: "track042",
                                           kind: "layer.piano")
        XCTAssertEqual(notes, "piano-notes-track042")
        XCTAssertEqual(layer, "piano-layer-track042")
        XCTAssertNotEqual(notes, layer)
    }

    /// Degenerate inputs still produce a name. A part with no name at all
    /// would be a row you cannot refer to.
    func testThereIsAlwaysAName() {
        XCTAssertEqual(PartNaming.defaultName(songTitle: "", kind: "stem.bass"),
                       "bass")
        XCTAssertFalse(PartNaming.defaultName(songTitle: "", kind: "").isEmpty)
    }

    // MARK: - Automatic or typed

    func testAnAutomaticNameIsRecognised() {
        XCTAssertTrue(PartNaming.isDefault("vocals-track042",
                                           songTitle: "track042",
                                           kind: "stem.vocals"))
        // …including the suffix a collision added.
        XCTAssertTrue(PartNaming.isDefault("vocals-track042-2",
                                           songTitle: "track042",
                                           kind: "stem.vocals"))
    }

    func testATypedNameIsNot() {
        XCTAssertFalse(PartNaming.isDefault("The hook",
                                            songTitle: "track042",
                                            kind: "stem.vocals"))
        // Right shape, wrong song: this part belongs to a different track's
        // automatic naming, so this song's rename must not claim it.
        XCTAssertFalse(PartNaming.isDefault("vocals-track099",
                                            songTitle: "track042",
                                            kind: "stem.vocals"))
        // A suffix that is not the collision counter.
        XCTAssertFalse(PartNaming.isDefault("vocals-track042-live",
                                            songTitle: "track042",
                                            kind: "stem.vocals"))
    }

    // MARK: - Uniqueness

    private func fixture() throws -> (LibraryRepository, PartsRepository) {
        let db = try DatabaseManager.inMemory()
        return (LibraryRepository(db: db), PartsRepository(db: db))
    }

    private func song(id: String, title: String) -> SongRecord {
        SongRecord(id: id, title: title, prompt: "", lyrics: nil, modelId: "m",
                   modelName: "M", groupId: nil, paramsJSON: "{}",
                   durationS: 10, sampleRate: 32000, fileName: id + ".wav",
                   seedUsed: nil, createdAt: Date(), rating: 0, notes: "",
                   favorite: false)
    }

    private func part(id: String, songId: String, name: String,
                      kind: String = "stem.vocals") -> PartRecord {
        PartRecord(id: id, songId: songId, kind: kind, name: name,
                   fileName: id + ".wav", format: "wav", previewFileName: nil,
                   modelId: "demucs", modelName: "Demucs 4-stem", jobId: nil,
                   splitParamsJSON: "{}", durationS: 10, sampleRate: 44100,
                   createdAt: Date())
    }

    /// One song split by two separators has two parts with a fair claim to
    /// `vocals-track042`. Ingest cannot refuse — the audio already exists — so
    /// it makes one free instead.
    func testASecondClaimOnANameGetsTheNextOne() throws {
        let (library, parts) = try fixture()
        try library.insert(song(id: "s1", title: "track042"))
        try parts.insert(part(id: "p1", songId: "s1", name: "vocals-track042"))

        XCTAssertEqual(try parts.uniqueName("vocals-track042"),
                       "vocals-track042-2")
        // And the one after that, so a third split does not collide either.
        try parts.insert(part(id: "p2", songId: "s1", name: "vocals-track042-2"))
        XCTAssertEqual(try parts.uniqueName("vocals-track042"),
                       "vocals-track042-3")
    }

    func testTakenIgnoresCaseAndExcludesTheRowItself() throws {
        let (library, parts) = try fixture()
        try library.insert(song(id: "s1", title: "track042"))
        try parts.insert(part(id: "p1", songId: "s1", name: "vocals-track042"))

        XCTAssertTrue(try parts.nameIsTaken("VOCALS-TRACK042", excluding: ""))
        XCTAssertFalse(try parts.nameIsTaken("vocals-track042", excluding: "p1"),
                       "committing your own name unchanged is not a collision")
    }

    /// Names reserved earlier in one batch are not in the table yet, so the
    /// caller has to be able to say so.
    func testReservedNamesCount() throws {
        let (_, parts) = try fixture()
        XCTAssertEqual(try parts.uniqueName("vocals-track042",
                                            reserved: ["vocals-track042"]),
                       "vocals-track042-2")
    }

    // MARK: - Following a rename

    func testAutomaticNamesFollowTheSong() throws {
        let (library, parts) = try fixture()
        try library.insert(song(id: "s1", title: "track042"))
        try parts.insert(part(id: "p1", songId: "s1", name: "vocals-track042"))
        try parts.insert(part(id: "p2", songId: "s1", name: "drums-track042",
                              kind: "stem.drums"))

        let moved = try parts.renameDefaults(ofSong: "s1", from: "track042",
                                             to: "Warehouse jam")
        XCTAssertEqual(moved, 2)
        let names = Set(try parts.allParts(forSong: "s1").map(\.name))
        XCTAssertEqual(names, ["vocals-warehouse-jam", "drums-warehouse-jam"])
    }

    /// The rule the user asked for: a name they typed is theirs, and renaming
    /// the song is not permission to overwrite it.
    func testATypedNameStaysPut() throws {
        let (library, parts) = try fixture()
        try library.insert(song(id: "s1", title: "track042"))
        try parts.insert(part(id: "p1", songId: "s1", name: "The hook"))
        try parts.insert(part(id: "p2", songId: "s1", name: "drums-track042",
                              kind: "stem.drums"))

        let moved = try parts.renameDefaults(ofSong: "s1", from: "track042",
                                             to: "Warehouse jam")
        XCTAssertEqual(moved, 1)
        XCTAssertEqual(try parts.part(id: "p1")?.name, "The hook")
        XCTAssertEqual(try parts.part(id: "p2")?.name, "drums-warehouse-jam")
    }

    /// Renaming into a name another song's part already holds still has to
    /// leave every part with a name of its own.
    func testFollowingARenameStillResolvesCollisions() throws {
        let (library, parts) = try fixture()
        try library.insert(song(id: "s1", title: "track042"))
        try library.insert(song(id: "s2", title: "Warehouse jam"))
        try parts.insert(part(id: "p1", songId: "s1", name: "vocals-track042"))
        try parts.insert(part(id: "p2", songId: "s2",
                              name: "vocals-warehouse-jam"))

        try parts.renameDefaults(ofSong: "s1", from: "track042",
                                 to: "Warehouse jam")
        XCTAssertEqual(try parts.part(id: "p1")?.name, "vocals-warehouse-jam-2")
        XCTAssertEqual(try parts.part(id: "p2")?.name, "vocals-warehouse-jam")
    }

    /// The cascade runs from the one place a title is written, and only when
    /// the store has a parts repository to write through.
    @MainActor
    func testTheEditorCarriesTheRenameOntoTheParts() throws {
        let db = try DatabaseManager.inMemory()
        let repo = LibraryRepository(db: db)
        let partsRepo = PartsRepository(db: db)
        let library = LibraryStore(repo: repo, partsRepo: partsRepo)
        try repo.insert(song(id: "s1", title: "track042"))
        try partsRepo.insert(part(id: "p1", songId: "s1",
                                  name: "vocals-track042"))

        var republished = 0
        library.onPartsRenamed = { republished += 1 }

        let editor = SongEditor()
        editor.load(try XCTUnwrap(library.song(id: "s1")), in: library)
        editor.title = "Warehouse jam"
        editor.commitTitle(in: library)

        XCTAssertEqual(try partsRepo.part(id: "p1")?.name,
                       "vocals-warehouse-jam")
        XCTAssertEqual(republished, 1,
                       "the parts list has to be told, it is another store")
    }

    /// A refused rename must not move the parts either — the track kept its
    /// name, so its parts keep theirs.
    @MainActor
    func testARefusedRenameLeavesThePartsAlone() throws {
        let db = try DatabaseManager.inMemory()
        let repo = LibraryRepository(db: db)
        let partsRepo = PartsRepository(db: db)
        let library = LibraryStore(repo: repo, partsRepo: partsRepo)
        try repo.insert(song(id: "s1", title: "track042"))
        try repo.insert(song(id: "s2", title: "Warehouse jam"))
        try partsRepo.insert(part(id: "p1", songId: "s1",
                                  name: "vocals-track042"))

        let editor = SongEditor()
        editor.load(try XCTUnwrap(library.song(id: "s1")), in: library)
        editor.title = "Warehouse jam"
        editor.commitTitle(in: library)

        XCTAssertNotNil(editor.titleError)
        XCTAssertEqual(try partsRepo.part(id: "p1")?.name, "vocals-track042")
    }

    // MARK: - Renaming a part

    @MainActor
    func testRenamingAPartSticks() throws {
        let db = try DatabaseManager.inMemory()
        let repo = LibraryRepository(db: db)
        let partsRepo = PartsRepository(db: db)
        try repo.insert(song(id: "s1", title: "track042"))
        try partsRepo.insert(part(id: "p1", songId: "s1",
                                  name: "vocals-track042"))
        let store = PartsStore(repo: partsRepo)
        // The store seeds itself off the actor, so a test that acts on it in
        // the same turn it was built has to ask for the cache synchronously —
        // this asserts on the cached row, which is what `refresh` fills.
        store.refresh()

        XCTAssertNil(store.rename(id: "p1", to: "  The hook  "),
                     "a free name is accepted, whitespace and all")
        XCTAssertEqual(try partsRepo.part(id: "p1")?.name, "The hook")
        XCTAssertEqual(store.results.first(where: { $0.id == "p1" })?.name,
                       "The hook", "the cached row moves with it")
    }

    /// Refused rather than made unique: the user is looking at the field and
    /// can pick again, which is the split `LibraryRepository.uniqueTitle`
    /// documents for songs.
    @MainActor
    func testRenamingAPartToATakenNameIsRefusedAndExplained() throws {
        let db = try DatabaseManager.inMemory()
        let repo = LibraryRepository(db: db)
        let partsRepo = PartsRepository(db: db)
        try repo.insert(song(id: "s1", title: "track042"))
        try partsRepo.insert(part(id: "p1", songId: "s1",
                                  name: "vocals-track042"))
        try partsRepo.insert(part(id: "p2", songId: "s1",
                                  name: "drums-track042", kind: "stem.drums"))
        let store = PartsStore(repo: partsRepo)

        let message = store.rename(id: "p2", to: "vocals-track042")
        XCTAssertNotNil(message)
        XCTAssertEqual(try partsRepo.part(id: "p2")?.name, "drums-track042")
    }

    /// A blank field is someone changing their mind, not a request. It is
    /// dropped without an error, the way a track's title field behaves.
    @MainActor
    func testABlankNameIsDroppedQuietly() throws {
        let db = try DatabaseManager.inMemory()
        let repo = LibraryRepository(db: db)
        let partsRepo = PartsRepository(db: db)
        try repo.insert(song(id: "s1", title: "track042"))
        try partsRepo.insert(part(id: "p1", songId: "s1",
                                  name: "vocals-track042"))
        let store = PartsStore(repo: partsRepo)

        XCTAssertNil(store.rename(id: "p1", to: "   "))
        XCTAssertEqual(try partsRepo.part(id: "p1")?.name, "vocals-track042")
    }

    // MARK: - The migration

    /// A library that predates part names comes out the far end of both
    /// migrations with a name per part. Every row is rewritten, because until
    /// v7 there was nowhere in the app to type a part name — so there is no
    /// user intent in the old values to preserve.
    func testAPreV7LibraryEndsUpWithANamePerPart() throws {
        let queue = try DatabaseQueue()
        try DatabaseManager.migrator.migrate(queue, upTo: "v6")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO song (id, title, prompt, modelId, modelName,
                                  paramsJSON, durationS, sampleRate, fileName,
                                  createdAt, rating, notes, favorite, origin)
                VALUES ('s1', 'Warehouse jam', '', 'm', 'M', '{}', 10, 32000,
                        's1.wav', '2026-08-01T00:00:00Z', 0, '', 0, 'generated')
                """)
            for (id, kind, name, made) in [
                ("p1", "stem.vocals", "Vocals", "2026-08-01T00:00:01Z"),
                ("p2", "stem.other", "Other (keys, synths, rest)",
                 "2026-08-01T00:00:02Z"),
                ("p3", "notes.piano", "Piano", "2026-08-01T00:00:03Z"),
                // A second separator's take on the same stem: the collision
                // the ordering rule exists for.
                ("p4", "stem.vocals", "Vocals", "2026-08-01T00:00:04Z"),
            ] {
                try db.execute(sql: """
                    INSERT INTO part (id, songId, kind, name, fileName, format,
                                      modelId, modelName, splitParamsJSON,
                                      createdAt, favorite)
                    VALUES (?, 's1', ?, ?, ?, 'wav', 'sep', 'Sep', '{}', ?, 0)
                    """, arguments: [id, kind, name, id + ".wav", made])
            }
        }

        try DatabaseManager.migrator.migrate(queue)

        let names = try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT id, name FROM part")
                .reduce(into: [String: String]()) { out, row in
                    out[row["id"] ?? ""] = row["name"]
                }
        }
        XCTAssertEqual(names["p1"], "vocals-warehouse-jam")
        XCTAssertEqual(names["p2"], "other-warehouse-jam")
        XCTAssertEqual(names["p3"], "piano-notes-warehouse-jam")
        // The later of the two takes the suffix: it is the one that reads as
        // the duplicate.
        XCTAssertEqual(names["p4"], "vocals-warehouse-jam-2")
        XCTAssertEqual(Set(names.values).count, 4, "every part keeps its own")
    }

    /// Rows written into a database that has already reached a given version.
    private func seed(_ queue: DatabaseQueue,
                      parts: [(String, String, String)]) throws {
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO song (id, title, prompt, modelId, modelName,
                                  paramsJSON, durationS, sampleRate, fileName,
                                  createdAt, rating, notes, favorite, origin)
                VALUES ('s1', 'Warehouse jam', '', 'm', 'M', '{}', 10, 32000,
                        's1.wav', '2026-08-01T00:00:00Z', 0, '', 0, 'generated')
                """)
            for (index, row) in parts.enumerated() {
                let (id, kind, name) = row
                try db.execute(sql: """
                    INSERT INTO part (id, songId, kind, name, fileName, format,
                                      modelId, modelName, splitParamsJSON,
                                      createdAt, favorite)
                    VALUES (?, 's1', ?, ?, ?, 'wav', 'sep', 'Sep', '{}', ?, 0)
                    """, arguments: [id, kind, name, id + ".wav",
                                     "2026-08-01T00:00:0\(index + 1)Z"])
            }
        }
    }

    private func names(in queue: DatabaseQueue) throws -> [String: String] {
        try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT id, name FROM part")
                .reduce(into: [String: String]()) { out, row in
                    out[row["id"] ?? ""] = row["name"]
                }
        }
    }

    /// A library that stopped at v7 has the song first in every part name.
    ///
    /// v8 turns those round — and only those. By v7 the inspector had a Name
    /// field in it, so a name typed since is the user's and stays exactly
    /// where it is. Editing v7 in place instead of adding v8 would have left
    /// these libraries on the old order forever, because GRDB records a
    /// migration as applied by name and never looks at it again.
    func testV8ReordersV7sNamesAndLeavesTypedOnesAlone() throws {
        let queue = try DatabaseQueue()
        try DatabaseManager.migrator.migrate(queue, upTo: "v7")
        try seed(queue, parts: [
            ("p1", "stem.vocals", "warehouse-jam-vocals"),
            ("p2", "stem.drums", "The backbeat"),
            ("p3", "stem.vocals", "warehouse-jam-vocals-2"),
            ("p4", "notes.piano", "warehouse-jam-piano-notes"),
        ])

        try DatabaseManager.migrator.migrate(queue)

        let names = try names(in: queue)
        XCTAssertEqual(names["p1"], "vocals-warehouse-jam")
        XCTAssertEqual(names["p2"], "The backbeat", "a typed name is not v7's")
        XCTAssertEqual(names["p3"], "vocals-warehouse-jam-2",
                       "the collision suffix survives the reorder")
        XCTAssertEqual(names["p4"], "piano-notes-warehouse-jam")
    }

    /// The reorder must not land on top of a name the user chose — even when
    /// the user chose exactly the name the reorder wants.
    func testV8YieldsToATypedNameItWouldHaveCollidedWith() throws {
        let queue = try DatabaseQueue()
        try DatabaseManager.migrator.migrate(queue, upTo: "v7")
        try seed(queue, parts: [
            ("p1", "stem.vocals", "warehouse-jam-vocals"),
            // Typed, and happens to be what p1's reorder is reaching for.
            ("p2", "stem.drums", "vocals-warehouse-jam"),
        ])

        try DatabaseManager.migrator.migrate(queue)

        let names = try names(in: queue)
        XCTAssertEqual(names["p2"], "vocals-warehouse-jam",
                       "the name the user typed does not move")
        XCTAssertEqual(names["p1"], "vocals-warehouse-jam-2",
                       "the reorder takes the next one instead")
    }
}

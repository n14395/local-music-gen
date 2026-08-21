import GRDB
import XCTest
@testable import LocalMusic

final class MigrationTests: XCTestCase {
    /// A database created at schema v1 with data migrates to v2 in place:
    /// existing songs pick up origin "generated", new tables appear.
    func testV1DataSurvivesV2() throws {
        let queue = try DatabaseQueue()
        try DatabaseManager.migrator.migrate(queue, upTo: "v1")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO song (id, title, prompt, modelId, modelName,
                                  paramsJSON, durationS, sampleRate, fileName,
                                  createdAt, rating, notes, favorite)
                VALUES ('s1', 'Old song', 'lofi', 'm', 'M', '{}', 10, 32000,
                        's1.wav', '2026-08-01T00:00:00Z', 0, '', 0)
                """)
        }
        try DatabaseManager.migrator.migrate(queue)

        let song = try queue.read { try SongRecord.fetchOne($0, key: "s1") }
        XCTAssertEqual(song?.origin, "generated")
        XCTAssertNil(song?.recipeId)

        // New tables accept rows.
        try queue.write { db in
            try PartRecord(
                id: "p1", songId: "s1", kind: "stem.vocals", name: "Vocals",
                fileName: "p1.wav", format: "wav", previewFileName: nil,
                modelId: "sep", modelName: "Sep", jobId: nil,
                splitParamsJSON: "{}", durationS: 10, sampleRate: 44100,
                createdAt: Date()).insert(db)
            try AnalysisRecord(
                ownerId: "p1", ownerType: "part", bpm: 120, keyName: "A minor",
                camelot: "8A", analysisJSON: "{}", modelId: "an",
                createdAt: Date()).insert(db)
            try SongIngredientRecord(
                songId: "s1", slotId: "vocals", partId: "p1",
                sourceSongTitle: "Old song", transformJSON: "{}").insert(db)
        }

        // Cascade: deleting the song removes its parts and ingredients.
        _ = try queue.write { try SongRecord.deleteOne($0, key: "s1") }
        let partCount = try queue.read { try PartRecord.fetchCount($0) }
        let ingredientCount = try queue.read {
            try SongIngredientRecord.fetchCount($0)
        }
        XCTAssertEqual(partCount, 0)
        XCTAssertEqual(ingredientCount, 0)
    }

    /// v4 rebuilds the FTS index to add `artist`. Rebuilding it is the risky
    /// part — the old table's synchronization triggers outlive it — so this
    /// pins that existing rows survive and that writes still reach the index.
    func testV3DataSurvivesV4() throws {
        let queue = try DatabaseQueue()
        try DatabaseManager.migrator.migrate(queue, upTo: "v3")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO song (id, title, prompt, modelId, modelName,
                                  paramsJSON, durationS, sampleRate, fileName,
                                  createdAt, rating, notes, favorite, origin)
                VALUES ('s1', 'Old song', 'dreamy saxophone', 'm', 'M', '{}',
                        10, 32000, 's1.wav', '2026-08-01T00:00:00Z', 0, '', 0,
                        'generated')
                """)
        }
        try DatabaseManager.migrator.migrate(queue)

        let song = try queue.read { try SongRecord.fetchOne($0, key: "s1") }
        XCTAssertEqual(song?.title, "Old song")
        XCTAssertNil(song?.artist)

        // Asserted against the index itself rather than through
        // `LibraryRepository`, because what is under test is what the rebuild
        // left behind: the repopulated rows and the fresh triggers.
        func matches(_ pattern: String) throws -> Int {
            try queue.read { db in
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM songFts WHERE songFts MATCH ?",
                    arguments: [pattern]) ?? 0
            }
        }

        // The rebuilt index carries the pre-migration row over…
        XCTAssertEqual(try matches("saxo*"), 1)

        // …and the new triggers still index what is written after it.
        try queue.write { db in
            try SongRecord(
                id: "s2", title: "Midnight Drive", prompt: "", lyrics: nil,
                modelId: "imported", modelName: "Imported", groupId: nil,
                paramsJSON: "{}", durationS: 200, sampleRate: 44100,
                fileName: "s2.wav", seedUsed: nil, createdAt: Date(),
                rating: 0, notes: "", favorite: false,
                origin: SongOrigin.imported.rawValue,
                artist: "Aurora Halo").insert(db)
        }
        XCTAssertEqual(try matches("Midnight*"), 1)
        // The column the rebuild existed to add.
        XCTAssertEqual(try matches("Aurora*"), 1)
    }

    /// The point of rebuilding the index: an imported record is findable by
    /// who played it, the way a generated one is findable by its prompt.
    func testFTSMatchesTheArtistAfterV4() throws {
        let repo = LibraryRepository(db: try DatabaseManager.inMemory())
        try repo.insert(SongRecord(
            id: "a", title: "Midnight Drive", prompt: "", lyrics: nil,
            modelId: "imported", modelName: "Imported", groupId: nil,
            paramsJSON: "{}", durationS: 200, sampleRate: 44100,
            fileName: "a.wav", seedUsed: nil, createdAt: Date(), rating: 0,
            notes: "", favorite: false, origin: SongOrigin.imported.rawValue,
            artist: "Aurora Halo"))
        var filters = LibraryRepository.Filters()
        filters.query = "aurora"
        XCTAssertEqual(try repo.search(filters).map(\.id), ["a"])
    }

    /// v5 adds the Editor's columns. Existing rows read back with nil edits,
    /// and a written program round-trips on both tables.
    func testV4DataSurvivesV5() throws {
        let queue = try DatabaseQueue()
        try DatabaseManager.migrator.migrate(queue, upTo: "v4")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO song (id, title, prompt, modelId, modelName,
                                  paramsJSON, durationS, sampleRate, fileName,
                                  createdAt, rating, notes, favorite, origin)
                VALUES ('s1', 'Old song', 'lofi', 'm', 'M', '{}', 10, 32000,
                        's1.wav', '2026-08-01T00:00:00Z', 0, '', 0, 'generated')
                """)
        }
        try DatabaseManager.migrator.migrate(queue)

        var song = try XCTUnwrap(
            try queue.read { try SongRecord.fetchOne($0, key: "s1") })
        XCTAssertNil(song.editsJSON)
        XCTAssertNil(song.editedAt)

        var document = EditDocument()
        document.ops = [EditOp(kind: .delete(EditRange(start: 1, end: 2)))]
        song.editsJSON = String(
            decoding: try JSONEncoder().encode(document), as: UTF8.self)
        song.editedAt = Date(timeIntervalSince1970: 1_766_000_000)
        try queue.write { [song] in try song.update($0) }
        let back = try queue.read { try SongRecord.fetchOne($0, key: "s1") }
        let decoded = try JSONDecoder().decode(
            EditDocument.self, from: Data((back?.editsJSON ?? "").utf8))
        XCTAssertEqual(decoded.ops, document.ops)
        XCTAssertNotNil(back?.editedAt)

        try queue.write { db in
            var part = PartRecord(
                id: "p1", songId: "s1", kind: "stem.drums", name: "Drums",
                fileName: "p1.wav", format: "wav", previewFileName: nil,
                modelId: "sep", modelName: "Sep", jobId: nil,
                splitParamsJSON: "{}", durationS: 10, sampleRate: 44100,
                createdAt: Date())
            part.editsJSON = "{}"
            try part.insert(db)
        }
        let part = try queue.read { try PartRecord.fetchOne($0, key: "p1") }
        XCTAssertEqual(part?.editsJSON, "{}")
    }

    func testFTSStillMatchesAfterV2() throws {
        let repo = LibraryRepository(db: try DatabaseManager.inMemory())
        try repo.insert(SongRecord(
            id: "a", title: "Synthwave", prompt: "dreamy saxophone",
            lyrics: nil, modelId: "m", modelName: "M", groupId: nil,
            paramsJSON: "{}", durationS: 5, sampleRate: 32000,
            fileName: "a.wav", seedUsed: nil, createdAt: Date(), rating: 0,
            notes: "", favorite: false))
        var filters = LibraryRepository.Filters()
        filters.query = "saxo"
        XCTAssertEqual(try repo.search(filters).count, 1)
    }
}

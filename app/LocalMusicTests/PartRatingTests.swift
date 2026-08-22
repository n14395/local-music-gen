import GRDB
import XCTest
@testable import LocalMusic

/// Parts can be rated, and their row says what a song row says.
///
/// The Parts list draws the same row as every other library scope now, which
/// means five stars and a heart on every part — so there has to be a column
/// behind the stars, and the second line has to carry what the badges used to.
@MainActor
final class PartRatingTests: XCTestCase {
    private func fixture() throws -> (LibraryRepository, PartsRepository) {
        let db = try DatabaseManager.inMemory()
        return (LibraryRepository(db: db), PartsRepository(db: db))
    }

    private func song(id: String = "s1", title: String = "track042") -> SongRecord {
        SongRecord(id: id, title: title, prompt: "", lyrics: nil, modelId: "m",
                   modelName: "M", groupId: nil, paramsJSON: "{}",
                   durationS: 10, sampleRate: 32000, fileName: id + ".wav",
                   seedUsed: nil, createdAt: Date(), rating: 0, notes: "",
                   favorite: false)
    }

    private func part(id: String = "p1", kind: String = "stem.vocals",
                      name: String = "vocals-track042",
                      format: String = "wav",
                      rating: Int = 0) -> PartRecord {
        PartRecord(id: id, songId: "s1", kind: kind, name: name,
                   fileName: id + "." + format, format: format,
                   previewFileName: nil, modelId: "demucs",
                   modelName: "Demucs 4-stem", jobId: nil,
                   splitParamsJSON: "{}", durationS: 201, sampleRate: 44100,
                   createdAt: Date(), favorite: false, rating: rating)
    }

    // MARK: - The column

    func testARatingSurvivesTheRoundTrip() throws {
        let (library, parts) = try fixture()
        try library.insert(song())
        try parts.insert(part(rating: 4))
        XCTAssertEqual(try parts.part(id: "p1")?.rating, 4)
    }

    func testStoreRatingClampsToTheFiveStarsTheRowDraws() throws {
        let (library, parts) = try fixture()
        try library.insert(song())
        try parts.insert(part())
        let store = PartsStore(repo: parts)
        let stored = try XCTUnwrap(parts.part(id: "p1"))

        store.setRating(stored, to: 9)
        XCTAssertEqual(try parts.part(id: "p1")?.rating, 5)
        store.setRating(try XCTUnwrap(parts.part(id: "p1")), to: -2)
        XCTAssertEqual(try parts.part(id: "p1")?.rating, 0)
    }

    /// Rating is its own axis: hearting something is not rating it, and the
    /// row draws both.
    func testRatingAndFavouriteAreIndependent() throws {
        let (library, parts) = try fixture()
        try library.insert(song())
        try parts.insert(part(rating: 3))
        let store = PartsStore(repo: parts)

        store.setFavorite(try XCTUnwrap(parts.part(id: "p1")), to: true)
        let after = try XCTUnwrap(parts.part(id: "p1"))
        XCTAssertTrue(after.favorite)
        XCTAssertEqual(after.rating, 3, "hearting must not disturb the stars")
    }

    /// A library that predates the column comes forward unrated rather than
    /// inventing a judgement the user never made.
    func testV9LeavesExistingPartsUnrated() throws {
        let queue = try DatabaseQueue()
        try DatabaseManager.migrator.migrate(queue, upTo: "v8")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO song (id, title, prompt, modelId, modelName,
                                  paramsJSON, durationS, sampleRate, fileName,
                                  createdAt, rating, notes, favorite, origin)
                VALUES ('s1', 'track042', '', 'm', 'M', '{}', 10, 32000,
                        's1.wav', '2026-08-01T00:00:00Z', 0, '', 0, 'generated')
                """)
            try db.execute(sql: """
                INSERT INTO part (id, songId, kind, name, fileName, format,
                                  modelId, modelName, splitParamsJSON,
                                  createdAt, favorite)
                VALUES ('p1', 's1', 'stem.vocals', 'vocals-track042',
                        'p1.wav', 'wav', 'sep', 'Sep', '{}',
                        '2026-08-01T00:00:01Z', 1)
                """)
        }

        try DatabaseManager.migrator.migrate(queue)

        let row = try queue.read { db in
            try Row.fetchOne(db, sql: "SELECT rating, favorite FROM part WHERE id='p1'")
        }
        XCTAssertEqual(row?["rating"], 0)
        XCTAssertEqual(row?["favorite"], 1, "the heart it already had stays set")
    }

    // MARK: - The second line

    /// What it is, what made it, how long, then what was measured — the same
    /// order and the same units as `LibrarySongRow.metaLine`.
    func testMetaLineReadsLikeASongsDoes() {
        let line = LibraryPartRow.metaLine(
            for: part(),
            analysis: AnalysisRecord(ownerId: "p1", ownerType: "part",
                                     bpm: 124.4, keyName: "A minor",
                                     camelot: "5A", analysisJSON: "{}",
                                     modelId: "an", createdAt: Date()))
        XCTAssertEqual(line, "STEM · DEMUCS 4-STEM · 201 S · 124 BPM · 5A")
    }

    /// Nothing measured yet, so nothing claimed.
    func testMetaLineOmitsWhatItDoesNotKnow() {
        XCTAssertEqual(LibraryPartRow.metaLine(for: part(), analysis: nil),
                       "STEM · DEMUCS 4-STEM · 201 S")
    }

    /// The two things the *name* stopped saying when part names became
    /// `other-track042`: what the residual actually holds, and that a notes
    /// part is symbols rather than sound.
    func testMetaLineCarriesWhatTheNameNoLongerDoes() {
        XCTAssertEqual(
            LibraryPartRow.metaLine(for: part(kind: "stem.other",
                                              name: "other-track042"),
                                    analysis: nil),
            "STEM · KEYS, SYNTHS, REST · DEMUCS 4-STEM · 201 S")
        XCTAssertEqual(
            LibraryPartRow.metaLine(for: part(kind: "notes.piano",
                                              name: "piano-notes-track042",
                                              format: "midi"),
                                    analysis: nil),
            "NOTES · MIDI · DEMUCS 4-STEM · 201 S")
    }
}

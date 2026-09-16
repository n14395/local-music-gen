import Foundation
import GRDB

/// GRDB database: schema, migrations, FTS5 search index.
final class DatabaseManager: Sendable {
    let queue: DatabaseQueue

    init(path: URL) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        queue = try DatabaseQueue(path: path.path)
        try Self.migrator.migrate(queue)
    }

    static func inMemory() throws -> DatabaseManager {
        try DatabaseManager(queue: DatabaseQueue())
    }

    /// Open the library, falling back to a scratch in-memory database when the
    /// file will not open. `failure` is non-nil exactly when the manager
    /// handed back is NOT the library — the caller has to say so, visibly and
    /// for the whole session.
    ///
    /// Non-throwing because its one caller — the app's dependency container —
    /// has nowhere to report a failure to, and used to spell the fallback
    /// `(try? .inMemory())!`: a force-unwrap that crashed on launch if the
    /// fallback failed too, next to an `assertionFailure` that says nothing at
    /// all in a release build. A user with a corrupt `library.sqlite` got an
    /// empty library, no message, and every write of the session thrown away
    /// at quit.
    ///
    /// The broken file is deliberately left where it is: a database that will
    /// not open today may only be locked, or on a volume mounted read-only,
    /// and moving someone's whole library aside to make room for an empty one
    /// is not a repair.
    static func openLibrary(path: URL) -> (db: DatabaseManager, failure: String?) {
        do {
            return (try DatabaseManager(path: path), nil)
        } catch {
            let reason = (error as NSError).localizedDescription
            log("could not open \(path.path): \(error)")
            if let memory = try? inMemory() { return (memory, reason) }
            // SQLite refusing an in-memory database as well is not something
            // the app can work around or the user can fix, and an environment
            // with no storage at all would fail in a different place on every
            // screen. Stop here instead, the way `SingleInstance` does, having
            // said why. 74 is EX_IOERR.
            log("no database could be opened at all: \(error)")
            FileHandle.standardError.write(Data(
                "local-music-gen: no database could be opened (\(reason))\n".utf8))
            exit(74)
        }
    }

    /// One line into `Logs/app-<date>.log`. Best-effort: the failure being
    /// logged is quite often the disk itself.
    private static func log(_ message: String) {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let dir = StoragePaths.appLogs
        try? FileManager.default.createDirectory(at: dir,
                                                 withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("app-\(df.string(from: Date())).log")
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = Data("\(stamp) database: \(message)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
            try? handle.close()
        } else {
            try? line.write(to: url)
        }
    }

    private init(queue: DatabaseQueue) throws {
        self.queue = queue
        try Self.migrator.migrate(queue)
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "song") { t in
                t.primaryKey("id", .text)
                t.column("title", .text).notNull()
                t.column("prompt", .text).notNull()
                t.column("lyrics", .text)
                t.column("modelId", .text).notNull().indexed()
                t.column("modelName", .text).notNull()
                t.column("groupId", .text).indexed()
                t.column("paramsJSON", .text).notNull()
                t.column("durationS", .double).notNull()
                t.column("sampleRate", .integer).notNull()
                t.column("fileName", .text).notNull()
                t.column("seedUsed", .integer)
                t.column("createdAt", .datetime).notNull().indexed()
                t.column("rating", .integer).notNull().defaults(to: 0)
                t.column("notes", .text).notNull().defaults(to: "")
                t.column("favorite", .boolean).notNull().defaults(to: false)
            }
            try db.create(table: "tag") { t in
                t.primaryKey("name", .text)
            }
            try db.create(table: "songTag") { t in
                t.column("songId", .text).notNull()
                    .references("song", onDelete: .cascade)
                t.column("tagName", .text).notNull()
                    .references("tag", onDelete: .cascade)
                t.primaryKey(["songId", "tagName"])
            }
            try db.create(virtualTable: "songFts", using: FTS5()) { t in
                t.synchronize(withTable: "song")
                t.column("title")
                t.column("prompt")
                t.column("lyrics")
                t.column("notes")
            }
        }
        // Split & Recombine: parts library, analysis attachments, recombination
        // provenance. Beat grids/segments live in analysisJSON — the contract a
        // future timeline view builds on (no schema rework needed).
        migrator.registerMigration("v2") { db in
            try db.alter(table: "song") { t in
                t.add(column: "origin", .text).notNull().defaults(to: "generated")
                t.add(column: "recipeId", .text)
            }
            try db.create(table: "part") { t in
                t.primaryKey("id", .text)
                t.column("songId", .text).notNull().indexed()
                    .references("song", onDelete: .cascade)
                t.column("kind", .text).notNull().indexed()   // "stem.vocals", "notes.piano", …
                t.column("name", .text).notNull()
                t.column("fileName", .text).notNull()         // relative to Library/Parts
                t.column("format", .text).notNull()           // wav | midi | json
                t.column("previewFileName", .text)            // rendered WAV for MIDI parts
                t.column("modelId", .text).notNull()
                t.column("modelName", .text).notNull()
                t.column("jobId", .text)
                t.column("splitParamsJSON", .text).notNull().defaults(to: "{}")
                t.column("durationS", .double)
                t.column("sampleRate", .integer)
                t.column("createdAt", .datetime).notNull().indexed()
            }
            // One row per audio entity (song or part), replaced on re-analysis.
            // No FK: two possible parents; cleanup rides the delete paths.
            try db.create(table: "analysis") { t in
                t.primaryKey("ownerId", .text)
                t.column("ownerType", .text).notNull()        // "song" | "part"
                t.column("bpm", .double)
                t.column("keyName", .text)
                t.column("camelot", .text).indexed()
                t.column("analysisJSON", .text).notNull()
                t.column("modelId", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            // Recombined-song provenance; partId deliberately un-constrained so
            // provenance stays readable after a part is deleted.
            try db.create(table: "songIngredient") { t in
                t.column("songId", .text).notNull().indexed()
                    .references("song", onDelete: .cascade)
                t.column("slotId", .text).notNull()
                t.column("partId", .text)
                t.column("sourceSongTitle", .text).notNull()
                t.column("transformJSON", .text).notNull().defaults(to: "{}")
                t.primaryKey(["songId", "slotId"])
            }
        }
        // Parts can be hearted too: the Library's Favourites scope is one view
        // over everything you marked, and a stem you liked belongs in it as
        // much as the song it came from.
        migrator.registerMigration("v3") { db in
            try db.alter(table: "part") { t in
                t.add(column: "favorite", .boolean).notNull().defaults(to: false)
            }
        }
        // Imported songs carry the performer from their own tags, and it has to
        // be searchable: "who was that Aphex track called?" is the same question
        // as searching a prompt, asked of music that arrived with a name on it.
        //
        // `songFts` is an external-content FTS5 table, so a column cannot be
        // added to it — it is dropped and rebuilt. Its synchronization triggers
        // outlive the table and would fire against the missing index on the next
        // write, so they come off explicitly first (GRDB's documented order);
        // re-creating with `synchronize` repopulates from `song`.
        migrator.registerMigration("v4") { db in
            try db.alter(table: "song") { t in
                t.add(column: "artist", .text)
            }
            try db.drop(table: "songFts")
            try db.dropFTS5SynchronizationTriggers(forTable: "songFts")
            try db.create(virtualTable: "songFts", using: FTS5()) { t in
                t.synchronize(withTable: "song")
                t.column("title")
                t.column("artist")
                t.column("prompt")
                t.column("lyrics")
                t.column("notes")
            }
        }
        // The Editor's non-destructive edit program, one JSON document per
        // track (or stem). The document alone is not "this track is edited" —
        // it exists from the first pending op — so `editedAt` records the
        // moment a program was last *applied*, which is what the Library's
        // badge, filter and sort read. The backup file's presence on disk is
        // what makes Revert offerable; no column mirrors it.
        migrator.registerMigration("v5") { db in
            try db.alter(table: "song") { t in
                t.add(column: "editsJSON", .text)
                t.add(column: "editedAt", .datetime)
            }
            try db.alter(table: "part") { t in
                t.add(column: "editsJSON", .text)
                t.add(column: "editedAt", .datetime)
            }
        }
        // Where the Editor stashed a track's pristine original. Recorded
        // rather than derived: applying always renders WAV, so an imported
        // mp3's `fileName` changes at the first apply — and a backup path
        // computed from the *current* name stopped finding the file the
        // moment it did, stranding the only untouched copy the user had.
        migrator.registerMigration("v6") { db in
            try db.alter(table: "song") { t in
                t.add(column: "backupFileName", .text)
            }
            try db.alter(table: "part") { t in
                t.add(column: "backupFileName", .text)
            }
        }
        // Parts get names of their own.
        //
        // `part.name` held the separator's label — "Vocals", "Drums" — so a
        // library with a dozen split songs showed a dozen rows called Vocals,
        // and not one of them identified anything. Songs of every origin have
        // had a real name since v1; parts now get the same, in the same
        // identifier style: `track042-vocals`. (v8 puts the two halves the
        // other way round; this one is left as it was written.)
        //
        // Every existing row is rewritten rather than only the ones that look
        // automatic, because until this migration there was no field anywhere
        // in the app to type a part name into. There is no user intent here to
        // preserve — after it, `PartNaming.isDefault` is what protects one.
        //
        // Ordered by creation so that when two parts want one name, the `-2`
        // lands on the later one, which is the one that reads as the duplicate.
        migrator.registerMigration("v7") { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT part.id AS id, part.kind AS kind, song.title AS title
                FROM part JOIN song ON song.id = part.songId
                ORDER BY part.createdAt, part.id
                """)
            // Seeded empty because every row is about to be rewritten, so
            // nothing in the table is a name anyone still holds.
            var taken: Set<String> = []
            for row in rows {
                let id: String = row["id"] ?? ""
                guard !id.isEmpty else { continue }
                let wanted = PartNaming.defaultName(
                    songTitle: row["title"] ?? "", kind: row["kind"] ?? "")
                let name = PartNaming.firstFree(wanted) {
                    taken.contains($0.lowercased())
                }
                taken.insert(name.lowercased())
                try db.execute(sql: "UPDATE part SET name = ? WHERE id = ?",
                               arguments: [name, id])
            }
        }
        // The two halves of a part's name change places: `vocals-track042`
        // rather than `track042-vocals`.
        //
        // A separate migration rather than an edit to v7, because a database
        // that already reached v7 will never run it again — GRDB records
        // migrations by name, not by content — and editing it in place would
        // leave those libraries on the old order forever while every new part
        // took the new one.
        //
        // Unlike v7 this does NOT rewrite everything. v7 could, because until
        // it ran there was nowhere in the app to type a part name; by now
        // there is, so only names still in v7's own shape are moved and
        // anything the user has typed since is left exactly where it is.
        migrator.registerMigration("v8") { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT part.id AS id, part.kind AS kind, part.name AS name,
                       song.title AS title
                FROM part JOIN song ON song.id = part.songId
                ORDER BY part.createdAt, part.id
                """)
            // Seeded with the names that are staying put, so a reorder can
            // never land on top of one the user chose.
            var taken = Set(rows.compactMap { row -> String? in
                let name: String = row["name"] ?? ""
                let stale = PartNaming.isSongFirst(name,
                                                   songTitle: row["title"] ?? "",
                                                   kind: row["kind"] ?? "")
                return stale ? nil : name.lowercased()
            })
            for row in rows {
                let id: String = row["id"] ?? ""
                let name: String = row["name"] ?? ""
                let kind: String = row["kind"] ?? ""
                let title: String = row["title"] ?? ""
                guard !id.isEmpty,
                      PartNaming.isSongFirst(name, songTitle: title, kind: kind)
                else { continue }
                let wanted = PartNaming.defaultName(songTitle: title, kind: kind)
                let free = PartNaming.firstFree(wanted) {
                    taken.contains($0.lowercased())
                }
                taken.insert(free.lowercased())
                try db.execute(sql: "UPDATE part SET name = ? WHERE id = ?",
                               arguments: [free, id])
            }
        }
        // Parts can be rated, like the tracks they came out of.
        //
        // The Parts list draws the same row as every other library scope now,
        // and that row has five stars in it; without a column behind them they
        // would be five stars you cannot fill. Defaulted rather than
        // backfilled: 0 means unrated, and inventing a rating for material the
        // user has never judged would be worse than an empty row of stars.
        migrator.registerMigration("v9") { db in
            try db.alter(table: "part") { t in
                t.add(column: "rating", .integer).notNull().defaults(to: 0)
            }
        }
        // Text documents: what the music-to-text models write about a track —
        // descriptions, transcribed lyrics, Q&A answers, tags, ABC notation —
        // and what the user writes in the same slots by hand.
        //
        // One table with a `kind` column rather than one per kind, because
        // every kind is the same shape: an owner, attributed editable text, a
        // model, a date. "Several description slots" is simply several rows
        // with kind "description" — which is why this is NOT a column on
        // `song` and NOT a row in `analysis` (whose ownerId is a primary key:
        // one row per owner, replaced on re-run — the opposite of slots).
        //
        // Its own FTS table rather than a rebuild of `songFts`: song-row
        // writes keep exactly the trigger cost they have today, and the
        // library search unions the two indexes instead. No FK on ownerId for
        // the same reason `analysis` has none — two possible parents; cleanup
        // rides the delete paths.
        migrator.registerMigration("v10") { db in
            try db.create(table: "textDoc") { t in
                t.primaryKey("id", .text)
                t.column("ownerId", .text).notNull().indexed()
                t.column("ownerType", .text).notNull()   // "song" | "part"
                // description | lyrics | caption | qa | abc | tags
                t.column("kind", .text).notNull().indexed()
                t.column("text", .text).notNull()
                t.column("segmentsJSON", .text)          // timed lyric lines
                t.column("question", .text)              // what a QA doc asked
                t.column("language", .text)
                t.column("modelId", .text).notNull()     // "" = user-written
                t.column("modelName", .text).notNull()   // "You" when written
                t.column("jobId", .text)
                t.column("edited", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull().indexed()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(virtualTable: "textDocFts", using: FTS5()) { t in
                t.synchronize(withTable: "textDoc")
                t.column("text")
                t.column("question")
            }
        }
        return migrator
    }
}

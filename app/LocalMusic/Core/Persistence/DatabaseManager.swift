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
        return migrator
    }
}

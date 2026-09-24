// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import Foundation
import GRDB

/// Query layer over the library database.
struct LibraryRepository: Sendable {
    let db: DatabaseManager

    struct Filters: Equatable, Sendable {
        var query = ""
        var modelId: String?
        /// Imported songs are filtered by who performed them, where generated
        /// songs are filtered by what made them.
        var artist: String?
        var minRating = 0
        var tag: String?
        var favoritesOnly = false
        /// Songs that have been split at least once. Cheap: one indexed
        /// `SELECT DISTINCT songId FROM part`.
        var hasParts = false
        /// Songs whose file has had an edit program applied. `editedAt` is
        /// the mark, not `editsJSON` — a pending program is not an edit the
        /// track carries yet.
        var hasEdits = false
        /// Generated and Imported are the same table read two ways — see
        /// `Origin`.
        var origin: Origin = .any
        var sort: Sort = .newest
    }

    /// The library screen shows Generated and Imported as separate scopes, but
    /// they are one table split on `origin`. Expressed as a filter rather than
    /// two queries so every scope shares the rest of the filter set.
    ///
    /// A *set* of origins rather than one, because a scope is a `SongShelf` and
    /// the made shelf spans two of them — a generated take and a render are
    /// both audio this app produced, and asking the user which list a mix went
    /// into was the point of folding them together.
    enum Origin: Equatable, Sendable {
        case any
        case anyOf(Set<String>)

        /// The one-origin case, kept as a name because that is how most callers
        /// read: `.only("imported")`.
        static func only(_ origin: String) -> Origin { .anyOf([origin]) }
    }

    enum Sort: String, CaseIterable, Equatable, Sendable {
        case newest, oldest, rating, title, longest, recentlyEdited
    }

    func insert(_ song: SongRecord) throws {
        try db.queue.write { try song.insert($0) }
    }

    func update(_ song: SongRecord) throws {
        try db.queue.write { try song.update($0) }
    }

    func delete(id: String) throws {
        _ = try db.queue.write { try SongRecord.deleteOne($0, key: id) }
    }

    func song(id: String) throws -> SongRecord? {
        try db.queue.read { try SongRecord.fetchOne($0, key: id) }
    }

    /// Several songs by id, in one round trip.
    ///
    /// The sibling above, called in a loop, is what the parts list did to
    /// title its groups: a list drawn from fifty songs was fifty synchronous
    /// queries, on the main actor, every time either store published — which
    /// is once per settled keystroke while searching. Same shape and same
    /// reason as `PartsRepository.analyses(ownerIds:)`.
    func songs(ids: [String]) throws -> [String: SongRecord] {
        guard !ids.isEmpty else { return [:] }
        let rows = try db.queue.read { database in
            try SongRecord.filter(ids.contains(Column("id"))).fetchAll(database)
        }
        return Dictionary(rows.map { ($0.id, $0) }) { _, last in last }
    }

    /// Highest `trackNNN` number currently in the library, 0 when there is
    /// none. Names are allocated from the high-water mark rather than from a
    /// count, so deleting or renaming a track never hands its number to a
    /// later one.
    func highestTrackNumber() throws -> Int {
        try db.queue.read { database in
            let titles = try String.fetchAll(
                database, sql: "SELECT title FROM song WHERE title LIKE 'track%'")
            return titles.compactMap(SongRecord.trackNumber(in:)).max() ?? 0
        }
    }

    /// The newest rows, for the rails and panels that show "what just landed".
    ///
    /// Bounded on purpose, and therefore never the answer to "what is in the
    /// library": the batch pages asked it that question and could only ever
    /// see twenty tracks. `search(.init())` is the whole table.
    func recent(limit: Int = 20) throws -> [SongRecord] {
        try db.queue.read {
            try SongRecord.order(Column("createdAt").desc).limit(limit).fetchAll($0)
        }
    }

    func search(_ filters: Filters) throws -> [SongRecord] {
        try db.queue.read { database in
            var request = SongRecord.all()
            let query = filters.query.trimmingCharacters(in: .whitespaces)
            // `matchingAllPrefixesIn:` is failable: a query FTS5 finds no
            // token in at all — "!!!", "--", a lone quote — yields nil, which
            // bound as SQL NULL, and `MATCH NULL` is an FTS5 syntax error. The
            // throw reached `(try? repo.search(filters)) ?? []` in every call
            // site, so typing punctuation emptied the whole library. A query
            // with no searchable word in it narrows nothing, so it is the same
            // answer as an empty field rather than "nothing matched".
            if !query.isEmpty,
               let pattern = FTS5Pattern(matchingAllPrefixesIn: query) {
                let ids = try Row.fetchAll(
                    database,
                    sql: "SELECT rowid FROM songFts WHERE songFts MATCH ?",
                    arguments: [pattern]
                ).map { $0["rowid"] as Int64 }
                // Text documents index separately (see the v10 migration): a
                // song whose only match is in a model-written description or
                // transcribed lyric still belongs in the results, so the two
                // indexes union here rather than sharing a table.
                let docOwnerIds = try String.fetchAll(
                    database,
                    sql: """
                        SELECT DISTINCT textDoc.ownerId FROM textDocFts
                        JOIN textDoc ON textDoc.rowid = textDocFts.rowid
                        WHERE textDoc.ownerType = 'song'
                          AND textDocFts MATCH ?
                        """,
                    arguments: [pattern])
                request = request.filter(
                    ids.contains(Column.rowID)
                        || docOwnerIds.contains(Column("id")))
            }
            if let modelId = filters.modelId {
                request = request.filter(Column("modelId") == modelId)
            }
            if let artist = filters.artist {
                request = request.filter(Column("artist") == artist)
            }
            if filters.minRating > 0 {
                request = request.filter(Column("rating") >= filters.minRating)
            }
            if filters.favoritesOnly {
                request = request.filter(Column("favorite") == true)
            }
            if let tag = filters.tag {
                // As a subselect rather than a fetched id list: the list was
                // materialised into Swift and then spliced back into the
                // statement as an `IN (...)` of every song carrying the tag,
                // so a popular tag rebuilt and re-planned a statement that
                // grew with it, once per keystroke.
                request = request.filter(
                    sql: "EXISTS (SELECT 1 FROM songTag"
                       + " WHERE songTag.songId = song.id"
                       + " AND songTag.tagName = ?)",
                    arguments: [tag])
            }
            switch filters.origin {
            case .any:
                break
            case .anyOf(let origins):
                // Sorted so one shelf produces one statement whatever order the
                // set happens to iterate in — the same reason the ticked ids in
                // `LibrarySelection` are sorted before they are used.
                request = request.filter(origins.sorted()
                    .contains(Column("origin")))
            }
            if filters.hasEdits {
                request = request.filter(Column("editedAt") != nil)
            }
            if filters.hasParts {
                // The worst of the materialised lists: it fetched *every*
                // distinct song id in the part table — a list bounded by the
                // library rather than by the answer — to ask a question
                // `EXISTS` answers per row without leaving the database.
                request = request.filter(
                    sql: "EXISTS (SELECT 1 FROM part"
                       + " WHERE part.songId = song.id)")
            }
            switch filters.sort {
            case .newest: request = request.order(Column("createdAt").desc)
            case .oldest: request = request.order(Column("createdAt").asc)
            // Ties inside a rating band are still most-recent-first, otherwise
            // "4 stars and up" reads as an arbitrary shuffle.
            case .rating: request = request.order(Column("rating").desc,
                                                  Column("createdAt").desc)
            case .title: request = request.order(Column("title").asc)
            case .longest: request = request.order(Column("durationS").desc)
            // Unedited rows have no `editedAt` at all, so they sort last
            // rather than leading the list as "oldest edit".
            case .recentlyEdited:
                request = request.order(
                    sql: "editedAt IS NULL, editedAt DESC, createdAt DESC")
            }
            return try request.fetchAll(database)
        }
    }

    /// How many songs carry each `origin`, for the library's scope counts.
    /// One grouped count rather than a fetch-and-count of every row.
    func countsByOrigin() throws -> [String: Int] {
        try db.queue.read { database in
            var out: [String: Int] = [:]
            let rows = try Row.fetchAll(
                database,
                sql: "SELECT origin, COUNT(*) AS n FROM song GROUP BY origin")
            for row in rows {
                let origin: String = row["origin"] ?? "generated"
                let count: Int = row["n"] ?? 0
                out[origin] = count
            }
            return out
        }
    }

    /// Every performer the library knows, for the Imported scope's artist menu.
    /// Blank tags are dropped rather than offered as an unnamed row.
    func distinctArtists() throws -> [String] {
        try db.queue.read { database in
            try String.fetchAll(database, sql: """
                SELECT DISTINCT artist FROM song
                WHERE artist IS NOT NULL AND TRIM(artist) <> ''
                ORDER BY artist COLLATE NOCASE
                """)
        }
    }

    /// Whether another song already answers to `title`.
    ///
    /// Case-insensitively, because "Test01" and "test01" are the same name to
    /// anyone reading the list, and the point of the check is that a name
    /// identifies one track. `excluding` is the song being renamed: committing
    /// a title unchanged, or changed only in case, must not collide with
    /// itself.
    func titleIsTaken(_ title: String, excluding songId: String) throws -> Bool {
        try db.queue.read { database in
            try Bool.fetchOne(
                database,
                sql: "SELECT EXISTS(SELECT 1 FROM song "
                    + "WHERE title = ? COLLATE NOCASE AND id <> ?)",
                arguments: [title, songId]) ?? false
        }
    }

    /// Write just the Editor's columns. The Editor stores its program as it
    /// is typed, and routing that through a full row update re-indexes the
    /// track through the FTS triggers and re-queries the whole library —
    /// several times a second while a slider moves.
    func setEdits(id: String, editsJSON: String?, editedAt: Date?,
                  backupFileName: String?) throws {
        try db.queue.write { database in
            try database.execute(sql: """
                UPDATE song SET editsJSON = ?, editedAt = ?,
                                backupFileName = ? WHERE id = ?
                """, arguments: [editsJSON, editedAt, backupFileName, id])
        }
    }

    /// How many tracks carry applied edits — the sidebar's Edited count.
    func editedCount() throws -> Int {
        try db.queue.read { database in
            try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM song WHERE editedAt IS NOT NULL")
                ?? 0
        }
    }

    /// Total bytes of the stashed originals, and how many there are — the
    /// Backups card. Read from disk rather than a column: the file's
    /// existence is what makes Revert offerable, so it is also the truth
    /// about what is being kept.
    /// A named `Equatable` type rather than a tuple, so the sidebar can hold
    /// the answer in `@State` and only redraw when it actually moves.
    struct BackupUsage: Equatable, Sendable {
        var count = 0
        var bytes: Int64 = 0
    }

    /// Enumerates the backups folder and `stat`s every file — call it off the
    /// main thread, and never from a view body.
    static func backupUsage() -> BackupUsage {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: StoragePaths.libraryBackups,
            includingPropertiesForKeys: [.fileSizeKey])
        else { return BackupUsage() }
        var bytes: Int64 = 0
        for file in files {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?
                .fileSize ?? 0
            bytes += Int64(size)
        }
        return BackupUsage(count: files.count, bytes: bytes)
    }

    /// `title`, or the first `title (2)`, `title (3)`… that no other song
    /// answers to.
    ///
    /// The rename path REFUSES a duplicate, because there the user is looking
    /// at the field and can pick again. Ingest cannot refuse: the audio
    /// already exists, and throwing it away because a name was taken while it
    /// rendered would be losing work over bookkeeping. So the name is made
    /// free instead, the way a file manager does it.
    ///
    /// `reserved` covers the names allocated earlier in the same batch, which
    /// are not in the database yet.
    func uniqueTitle(_ title: String, reserved: Set<String> = []) throws -> String {
        let lowerReserved = Set(reserved.map { $0.lowercased() })
        func isFree(_ candidate: String) throws -> Bool {
            if lowerReserved.contains(candidate.lowercased()) { return false }
            return try !titleIsTaken(candidate, excluding: "")
        }
        if try isFree(title) { return title }
        var suffix = 2
        while true {
            let candidate = "\(title) (\(suffix))"
            if try isFree(candidate) { return candidate }
            suffix += 1
            // A library cannot hold this many collisions; the bound is here
            // so a bug upstream cannot spin forever.
            if suffix > 9999 { return "\(title) (\(UUID().uuidString.prefix(4)))" }
        }
    }

    /// Hearted songs of any origin — the song half of the Favourites scope.
    func favoriteCount() throws -> Int {
        try db.queue.read { database in
            try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM song WHERE favorite = 1") ?? 0
        }
    }

    // MARK: tags

    func tags(for songId: String) throws -> [String] {
        try db.queue.read {
            try SongTagRecord.filter(Column("songId") == songId)
                .fetchAll($0).map(\.tagName).sorted()
        }
    }

    /// Ids of every song carrying no tags at all — the batch tagger's
    /// "Untagged only" sweep.
    ///
    /// One `NOT EXISTS` rather than a `tags(for:)` per row. The sweep asks
    /// this of the entire library, so answering it song by song turned a
    /// tickbox into one query per track — repeated on every redraw of the
    /// screen that reads it.
    func untaggedSongIds() throws -> Set<String> {
        try db.queue.read { database in
            Set(try String.fetchAll(database, sql: """
                SELECT id FROM song WHERE NOT EXISTS (
                    SELECT 1 FROM songTag WHERE songTag.songId = song.id)
                """))
        }
    }

    func allTags() throws -> [String] {
        try db.queue.read { try TagRecord.order(Column("name")).fetchAll($0).map(\.name) }
    }

    func setTags(_ tags: [String], for songId: String) throws {
        try db.queue.write { database in
            try SongTagRecord.filter(Column("songId") == songId).deleteAll(database)
            for name in Set(tags.map { $0.trimmingCharacters(in: .whitespaces) })
            where !name.isEmpty {
                try TagRecord(name: name).upsert(database)
                try SongTagRecord(songId: songId, tagName: name).insert(database)
            }
            // Nothing else ever deleted a `tag` row, so a name typed once
            // stayed in the Library's tag menu forever — including after the
            // last song carrying it was untagged, where picking it showed an
            // empty library. In the same write as the replace above, so the
            // menu and the join rows can never disagree.
            try database.execute(sql: """
                DELETE FROM tag WHERE NOT EXISTS (
                    SELECT 1 FROM songTag WHERE songTag.tagName = tag.name)
                """)
        }
    }
}

import Foundation
import GRDB

/// Query layer over the parts library (stems / notes / features), their
/// analysis attachments, and recombination provenance.
struct PartsRepository: Sendable {
    let db: DatabaseManager

    struct Filters: Equatable, Sendable {
        var query = ""
        var kindPrefix: String?      // "stem." | "notes." | "features."
        var songId: String?
        var bpmRange: ClosedRange<Double>?
        var camelot: String?
        var favoritesOnly = false
    }

    // MARK: parts

    func insert(_ part: PartRecord) throws {
        try db.queue.write { try part.insert($0) }
    }

    func delete(id: String) throws {
        _ = try db.queue.write { database in
            try AnalysisRecord.filter(Column("ownerId") == id).deleteAll(database)
            try TextDocRecord.filter(Column("ownerId") == id).deleteAll(database)
            return try PartRecord.deleteOne(database, key: id)
        }
    }

    /// Several parts by id, in one round trip — the sibling below, for the
    /// paths that hold a whole list of ids at once.
    func parts(ids: [String]) throws -> [String: PartRecord] {
        guard !ids.isEmpty else { return [:] }
        let rows = try db.queue.read { database in
            try PartRecord.filter(ids.contains(Column("id"))).fetchAll(database)
        }
        return Dictionary(rows.map { ($0.id, $0) }) { _, last in last }
    }

    func part(id: String) throws -> PartRecord? {
        try db.queue.read { try PartRecord.fetchOne($0, key: id) }
    }

    /// Narrow write for the Editor's columns — see
    /// `LibraryRepository.setEdits`.
    func setEdits(id: String, editsJSON: String?, editedAt: Date?,
                  backupFileName: String?) throws {
        try db.queue.write { database in
            try database.execute(sql: """
                UPDATE part SET editsJSON = ?, editedAt = ?,
                                backupFileName = ? WHERE id = ?
                """, arguments: [editsJSON, editedAt, backupFileName, id])
        }
    }

    func update(_ part: PartRecord) throws {
        try db.queue.write { try part.update($0) }
    }

    // MARK: names

    /// Whether another part already answers to `name`.
    ///
    /// The same rule songs have had since v1 (`LibraryRepository
    /// .titleIsTaken`), case-insensitively for the same reason: two rows a
    /// reader cannot tell apart are the same name. `excluding` is the part
    /// being renamed, so committing a name unchanged — or changed only in
    /// case — does not collide with itself.
    func nameIsTaken(_ name: String, excluding partId: String) throws -> Bool {
        try db.queue.read { database in
            try Bool.fetchOne(
                database,
                sql: "SELECT EXISTS(SELECT 1 FROM part "
                    + "WHERE name = ? COLLATE NOCASE AND id <> ?)",
                arguments: [name, partId]) ?? false
        }
    }

    /// `name`, or the first `name-2`, `name-3`… no other part answers to.
    ///
    /// Ingest cannot refuse a duplicate: the stem already exists on disk, and
    /// throwing it away because a name was taken while it rendered would be
    /// losing work over bookkeeping. So it makes a free one instead. The
    /// inspector's rename field refuses, because there the user is looking at
    /// the field and can pick again — the same split `LibraryRepository
    /// .uniqueTitle` documents for songs.
    ///
    /// `reserved` covers names handed out earlier in the same batch that are
    /// not in the database yet.
    func uniqueName(_ name: String, reserved: Set<String> = []) throws -> String {
        let lowerReserved = Set(reserved.map { $0.lowercased() })
        var thrown: (any Error)?
        let free = PartNaming.firstFree(name) { candidate in
            if lowerReserved.contains(candidate.lowercased()) { return true }
            do { return try nameIsTaken(candidate, excluding: "") }
            // A failed read must not read as "free": that would hand out a
            // name already in use and fail again, less legibly, at insert.
            catch { thrown = error; return true }
        }
        if let thrown { throw thrown }
        return free
    }

    /// Narrow write for the one column the inspector's Name field owns — as
    /// `setEdits`, and for the same reason: a full row update re-queries the
    /// parts list on every keystroke that commits.
    func setName(id: String, to name: String) throws {
        try db.queue.write { database in
            try database.execute(
                sql: "UPDATE part SET name = ? WHERE id = ?",
                arguments: [name, id])
        }
    }

    /// Re-derive the names of a song's parts after the song itself was
    /// renamed, and report how many moved.
    ///
    /// Only the parts still answering to the name they were given. A part the
    /// user has typed a name into is theirs, and renaming the song is not
    /// permission to overwrite it — `PartNaming.isDefault` is what tells the
    /// two apart.
    ///
    /// Without this a part's name would keep pointing at a title that no
    /// longer exists, while the meta line beside it — which resolves the
    /// source live — showed the new one. Two names for one song, in one row.
    @discardableResult
    func renameDefaults(ofSong songId: String, from oldTitle: String,
                        to newTitle: String) throws -> Int {
        var moved = 0
        for part in try allParts(forSong: songId)
        where PartNaming.isDefault(part.name, songTitle: oldTitle,
                                   kind: part.kind) {
            let wanted = PartNaming.defaultName(songTitle: newTitle,
                                                kind: part.kind)
            guard wanted != part.name else { continue }
            try setName(id: part.id, to: try uniqueName(wanted))
            moved += 1
        }
        return moved
    }

    /// Hearted parts, for the Library's Favourites scope. Ordered like the
    /// parts list itself so the two read the same way.
    func favorites() throws -> [PartRecord] {
        try db.queue.read {
            try PartRecord.filter(Column("favorite") == true)
                .order(Column("createdAt").desc).fetchAll($0)
        }
    }

    /// How many parts are hearted.
    ///
    /// A `COUNT(*)`, not `favorites().count`: the sidebar's badge fetched
    /// every hearted row — whole records, every column — and then threw all
    /// of them away but the number.
    func favoriteCount() throws -> Int {
        try db.queue.read { database in
            try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM part WHERE favorite = 1") ?? 0
        }
    }

    func allParts(forSong songId: String) throws -> [PartRecord] {
        try db.queue.read {
            try PartRecord.filter(Column("songId") == songId)
                .order(Column("createdAt").desc).fetchAll($0)
        }
    }

    /// Parts per song, for the library's `6 PARTS` row metadata and its Parts
    /// scope count. One grouped count, not one query per row: the songs list
    /// asks for this on every redraw.
    func partCounts() throws -> [String: Int] {
        try db.queue.read { database in
            var out: [String: Int] = [:]
            let rows = try Row.fetchAll(
                database,
                sql: "SELECT songId, COUNT(*) AS n FROM part GROUP BY songId")
            for row in rows {
                let songId: String = row["songId"] ?? ""
                let count: Int = row["n"] ?? 0
                guard !songId.isEmpty else { continue }
                out[songId] = count
            }
            return out
        }
    }

    func parts(_ filters: Filters) throws -> [PartRecord] {
        try db.queue.read { database in
            var sql = """
                SELECT part.* FROM part
                JOIN song ON song.id = part.songId
                LEFT JOIN analysis ON analysis.ownerId = part.id
                WHERE 1=1
                """
            var args: [any DatabaseValueConvertible] = []
            let query = filters.query.trimmingCharacters(in: .whitespaces)
            if !query.isEmpty {
                sql += " AND (part.name LIKE ? OR song.title LIKE ?)"
                args += ["%\(query)%", "%\(query)%"]
            }
            if let prefix = filters.kindPrefix {
                sql += " AND part.kind LIKE ?"
                args.append(prefix + "%")
            }
            if let songId = filters.songId {
                sql += " AND part.songId = ?"
                args.append(songId)
            }
            if let range = filters.bpmRange {
                sql += " AND analysis.bpm BETWEEN ? AND ?"
                args += [range.lowerBound, range.upperBound]
            }
            if let camelot = filters.camelot {
                sql += " AND analysis.camelot = ?"
                args.append(camelot)
            }
            if filters.favoritesOnly {
                sql += " AND part.favorite = 1"
            }
            sql += " ORDER BY part.createdAt DESC"
            return try PartRecord.fetchAll(database, sql: sql,
                                           arguments: StatementArguments(args))
        }
    }

    // MARK: analysis

    func analysis(ownerId: String) throws -> AnalysisRecord? {
        try db.queue.read { try AnalysisRecord.fetchOne($0, key: ownerId) }
    }

    /// Analyses for many owners in one query.
    ///
    /// `PartsStore.refresh()` used to ask for these one part at a time, which
    /// made republishing the parts list N+1 queries — two hundred parts were
    /// two hundred and one round trips through the database, on the main
    /// actor, for every filter change and every write.
    func analyses(ownerIds: [String]) throws -> [String: AnalysisRecord] {
        guard !ownerIds.isEmpty else { return [:] }
        let rows = try db.queue.read { database in
            try AnalysisRecord
                .filter(ownerIds.contains(Column("ownerId")))
                .fetchAll(database)
        }
        return Dictionary(rows.map { ($0.ownerId, $0) }) { _, last in last }
    }

    func upsertAnalysis(_ record: AnalysisRecord) throws {
        try db.queue.write { try record.upsert($0) }
    }

    func deleteAnalysis(ownerId: String) throws {
        _ = try db.queue.write { try AnalysisRecord.deleteOne($0, key: ownerId) }
    }

    // MARK: text documents

    /// Every text document on one song or part, newest first inside each
    /// kind so "the latest description" is always the first of its group.
    func textDocs(ownerId: String) throws -> [TextDocRecord] {
        try db.queue.read {
            try TextDocRecord.filter(Column("ownerId") == ownerId)
                .order(Column("kind"), Column("createdAt").desc)
                .fetchAll($0)
        }
    }

    /// The whole table, in the same order — `TextStore` mirrors it entire,
    /// the way `PartsStore.refresh` re-reads its results, because a handful
    /// of rows per song never justifies incremental cache surgery.
    func allTextDocs() throws -> [TextDocRecord] {
        try db.queue.read {
            try TextDocRecord
                .order(Column("kind"), Column("createdAt").desc)
                .fetchAll($0)
        }
    }

    /// The auto-run idempotence guard: has some model already written this
    /// kind onto this owner? User-written docs count too — a description the
    /// user typed is exactly as much a reason not to auto-describe.
    func hasTextDoc(ownerId: String, kind: String) throws -> Bool {
        try db.queue.read {
            try TextDocRecord.filter(Column("ownerId") == ownerId)
                .filter(Column("kind") == kind)
                .fetchCount($0) > 0
        }
    }

    func insertTextDoc(_ record: TextDocRecord) throws {
        try db.queue.write { try record.insert($0) }
    }

    func updateTextDoc(_ record: TextDocRecord) throws {
        try db.queue.write { try record.update($0) }
    }

    func deleteTextDoc(id: String) throws {
        _ = try db.queue.write { try TextDocRecord.deleteOne($0, key: id) }
    }

    /// Rides the owner's delete path, like `deleteAnalysis`.
    func deleteTextDocs(ownerId: String) throws {
        _ = try db.queue.write {
            try TextDocRecord.filter(Column("ownerId") == ownerId)
                .deleteAll($0)
        }
    }

    // MARK: recombination provenance

    func ingredients(songId: String) throws -> [SongIngredientRecord] {
        try db.queue.read {
            try SongIngredientRecord.filter(Column("songId") == songId)
                .order(Column("slotId")).fetchAll($0)
        }
    }

    func setIngredients(_ rows: [SongIngredientRecord], songId: String) throws {
        try db.queue.write { database in
            try SongIngredientRecord.filter(Column("songId") == songId)
                .deleteAll(database)
            for row in rows {
                try row.insert(database)
            }
        }
    }
}

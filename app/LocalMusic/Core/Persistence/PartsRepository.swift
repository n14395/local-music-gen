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
            return try PartRecord.deleteOne(database, key: id)
        }
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

    /// Hearted parts, for the Library's Favourites scope. Ordered like the
    /// parts list itself so the two read the same way.
    func favorites() throws -> [PartRecord] {
        try db.queue.read {
            try PartRecord.filter(Column("favorite") == true)
                .order(Column("createdAt").desc).fetchAll($0)
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

    func upsertAnalysis(_ record: AnalysisRecord) throws {
        try db.queue.write { try record.upsert($0) }
    }

    func deleteAnalysis(ownerId: String) throws {
        _ = try db.queue.write { try AnalysisRecord.deleteOne($0, key: ownerId) }
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

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
        /// Songs and Renders are the same table read two ways — see `Origin`.
        var origin: Origin = .any
        var sort: Sort = .newest
    }

    /// The library screen shows Generated Songs, Imported and Renders as
    /// separate scopes, but they are one table split on `origin`. Expressed as
    /// a filter rather than three queries so every scope shares the rest of the
    /// filter set.
    enum Origin: Equatable, Sendable {
        case any
        case only(String)
        case excluding(String)
    }

    enum Sort: String, CaseIterable, Equatable, Sendable {
        case newest, oldest, rating, title, longest
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

    func recent(limit: Int = 20) throws -> [SongRecord] {
        try db.queue.read {
            try SongRecord.order(Column("createdAt").desc).limit(limit).fetchAll($0)
        }
    }

    func search(_ filters: Filters) throws -> [SongRecord] {
        try db.queue.read { database in
            var request = SongRecord.all()
            let query = filters.query.trimmingCharacters(in: .whitespaces)
            if !query.isEmpty {
                let pattern = FTS5Pattern(matchingAllPrefixesIn: query)
                let ids = try Row.fetchAll(
                    database,
                    sql: "SELECT rowid FROM songFts WHERE songFts MATCH ?",
                    arguments: [pattern]
                ).map { $0["rowid"] as Int64 }
                request = request.filter(ids.contains(Column.rowID))
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
                let ids = try SongTagRecord
                    .filter(Column("tagName") == tag)
                    .fetchAll(database).map(\.songId)
                request = request.filter(ids.contains(Column("id")))
            }
            switch filters.origin {
            case .any:
                break
            case .only(let origin):
                request = request.filter(Column("origin") == origin)
            case .excluding(let origin):
                request = request.filter(Column("origin") != origin)
            }
            if filters.hasParts {
                let ids = try String.fetchAll(
                    database, sql: "SELECT DISTINCT songId FROM part")
                request = request.filter(ids.contains(Column("id")))
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
        }
    }
}

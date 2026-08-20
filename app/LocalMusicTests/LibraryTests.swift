import XCTest
@testable import LocalMusic

final class LibraryTests: XCTestCase {
    private func makeRepo() throws -> LibraryRepository {
        LibraryRepository(db: try DatabaseManager.inMemory())
    }

    private func song(id: String = UUID().uuidString, title: String,
                      prompt: String, model: String = "musicgen-small",
                      rating: Int = 0, group: String? = nil) -> SongRecord {
        SongRecord(id: id, title: title, prompt: prompt, lyrics: nil,
                   modelId: model, modelName: model, groupId: group,
                   paramsJSON: "{}", durationS: 10, sampleRate: 32000,
                   fileName: id + ".wav", seedUsed: 7, createdAt: Date(),
                   rating: rating, notes: "", favorite: false)
    }

    func testInsertAndFetch() throws {
        let repo = try makeRepo()
        try repo.insert(song(id: "a", title: "First", prompt: "warm lo-fi"))
        let fetched = try repo.song(id: "a")
        XCTAssertEqual(fetched?.title, "First")
        XCTAssertEqual(try repo.recent().count, 1)
    }

    func testFTSSearch() throws {
        let repo = try makeRepo()
        try repo.insert(song(title: "Synthwave dream", prompt: "dreamy synthwave with saxophone"))
        try repo.insert(song(title: "Lo-fi", prompt: "warm vinyl crackle beat"))

        var filters = LibraryRepository.Filters()
        filters.query = "saxo"
        XCTAssertEqual(try repo.search(filters).count, 1, "prefix match")
        filters.query = "vinyl crackle"
        XCTAssertEqual(try repo.search(filters).count, 1)
        filters.query = "nothing-matches"
        XCTAssertEqual(try repo.search(filters).count, 0)
    }

    func testSearchReflectsEdits() throws {
        let repo = try makeRepo()
        var record = song(id: "e", title: "Edit me", prompt: "plain prompt")
        try repo.insert(record)
        record.notes = "glorious trumpet solo"
        try repo.update(record)

        var filters = LibraryRepository.Filters()
        filters.query = "trumpet"
        XCTAssertEqual(try repo.search(filters).count, 1,
                       "FTS index must follow updates")
    }

    func testFiltersAndRating() throws {
        let repo = try makeRepo()
        try repo.insert(song(title: "A", prompt: "x", model: "m1", rating: 5))
        try repo.insert(song(title: "B", prompt: "y", model: "m2", rating: 2))

        var filters = LibraryRepository.Filters()
        filters.modelId = "m1"
        XCTAssertEqual(try repo.search(filters).map(\.title), ["A"])
        filters = .init()
        filters.minRating = 3
        XCTAssertEqual(try repo.search(filters).map(\.title), ["A"])
    }

    func testTags() throws {
        let repo = try makeRepo()
        try repo.insert(song(id: "t", title: "Tagged", prompt: "p"))
        try repo.setTags(["chill", "demo"], for: "t")
        XCTAssertEqual(try repo.tags(for: "t"), ["chill", "demo"])
        try repo.setTags(["chill"], for: "t")
        XCTAssertEqual(try repo.tags(for: "t"), ["chill"])

        var filters = LibraryRepository.Filters()
        filters.tag = "chill"
        XCTAssertEqual(try repo.search(filters).count, 1)
        filters.tag = "demo"
        XCTAssertEqual(try repo.search(filters).count, 0)
    }

    func testDelete() throws {
        let repo = try makeRepo()
        try repo.insert(song(id: "g1", title: "One", prompt: "p", group: "grp_x"))
        try repo.insert(song(id: "g2", title: "Two", prompt: "p", group: "grp_x"))
        try repo.delete(id: "g1")
        XCTAssertNil(try repo.song(id: "g1"))
        XCTAssertNotNil(try repo.song(id: "g2"))
    }
}

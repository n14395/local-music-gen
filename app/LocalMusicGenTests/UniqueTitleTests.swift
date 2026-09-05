import XCTest
@testable import LocalMusicGen

/// A name identifies one track. The rename path refuses a duplicate; ingest
/// cannot refuse — the audio already exists — so it makes the name free.
@MainActor
final class UniqueTitleTests: XCTestCase {

    private func makeLibrary() throws -> (LibraryStore, LibraryRepository) {
        let db = try DatabaseManager.inMemory()
        let repo = LibraryRepository(db: db)
        return (LibraryStore(repo: repo, partsRepo: PartsRepository(db: db)),
                repo)
    }

    private func song(_ id: String, _ title: String) -> SongRecord {
        SongRecord(id: id, title: title, prompt: "", lyrics: nil,
                   modelId: "m", modelName: "M", groupId: nil,
                   paramsJSON: "{}", durationS: 1, sampleRate: 44100,
                   fileName: "\(id).wav", seedUsed: nil, createdAt: Date(),
                   rating: 0, notes: "", favorite: false)
    }

    func testAFreeNameIsLeftAlone() throws {
        let (library, repo) = try makeLibrary()
        library.insert(song("a", "warehouse jam"))
        XCTAssertEqual(try repo.uniqueTitle("something else"),
                       "something else")
    }

    func testATakenNameGetsTheFirstFreeSuffix() throws {
        let (library, repo) = try makeLibrary()
        library.insert(song("a", "warehouse jam"))
        XCTAssertEqual(try repo.uniqueTitle("warehouse jam"),
                       "warehouse jam (2)")
        library.insert(song("b", "warehouse jam (2)"))
        XCTAssertEqual(try repo.uniqueTitle("warehouse jam"),
                       "warehouse jam (3)")
    }

    /// Case-insensitively, matching `titleIsTaken` — "Test01" and "test01"
    /// are the same name to anyone reading the list.
    func testCollisionIsCaseInsensitive() throws {
        let (library, repo) = try makeLibrary()
        library.insert(song("a", "Warehouse Jam"))
        XCTAssertEqual(try repo.uniqueTitle("warehouse jam"),
                       "warehouse jam (2)")
    }

    /// Names allocated earlier in the same batch are not in the database yet,
    /// so they have to be reserved explicitly or four takes all become "(2)".
    func testReservedNamesInTheSameBatchDoNotCollide() throws {
        let (_, repo) = try makeLibrary()
        var reserved: Set<String> = []
        var allocated: [String] = []
        for _ in 0..<3 {
            let name = try repo.uniqueTitle("take", reserved: reserved)
            reserved.insert(name)
            allocated.append(name)
        }
        XCTAssertEqual(allocated, ["take", "take (2)", "take (3)"])
    }

    /// The whole point: two generations under one typed name end up as two
    /// distinguishable tracks rather than two rows reading the same.
    func testIngestingTheSameNameTwiceProducesTwoNames() throws {
        let (library, repo) = try makeLibrary()
        let first = try repo.uniqueTitle("warehouse jam")
        library.insert(song("a", first))
        let second = try repo.uniqueTitle("warehouse jam")
        library.insert(song("b", second))
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(Set([first, second]).count, 2)
    }

    /// A batch's take letters already disambiguate, so they are not renamed
    /// unless they genuinely clash with something stored.
    func testTakeLettersAreLeftAloneWhenFree() throws {
        let (_, repo) = try makeLibrary()
        var reserved: Set<String> = []
        let names = SongRecord.takeNames(base: "warehouse jam", count: 3)
            .map { name -> String in
                let unique = try! repo.uniqueTitle(name, reserved: reserved)
                reserved.insert(unique)
                return unique
            }
        XCTAssertEqual(names, ["warehouse jam (a)", "warehouse jam (b)",
                               "warehouse jam (c)"])
    }
}

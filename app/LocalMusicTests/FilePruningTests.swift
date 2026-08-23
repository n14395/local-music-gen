import XCTest
@testable import LocalMusic

/// Selection logic for the launch-time housekeeping: age pruning for the
/// daily engine logs, size capping for the Editor's stashed originals.
final class FilePruningTests: XCTestCase {
    private func entry(_ name: String, daysOld: Double,
                       bytes: Int64 = 1) -> FilePruning.Entry {
        FilePruning.Entry(
            url: URL(fileURLWithPath: "/tmp/\(name)"),
            modifiedAt: Date(timeIntervalSinceNow: -daysOld * 86400),
            bytes: bytes)
    }

    func testExpiryIsByAgeAndZeroDisables() {
        let entries = [entry("old.log", daysOld: 20),
                       entry("edge.log", daysOld: 13.9),
                       entry("new.log", daysOld: 1)]
        let gone = FilePruning.expired(entries, olderThanDays: 14)
        XCTAssertEqual(gone.map(\.lastPathComponent), ["old.log"])
        XCTAssertTrue(FilePruning.expired(entries, olderThanDays: 0).isEmpty)
    }

    /// Oldest-first eviction, stopping the moment the rest fits — the newest
    /// backups always survive a cap, however small.
    func testOverflowEvictsOldestFirstUntilItFits() {
        let entries = [entry("newest", daysOld: 1, bytes: 400),
                       entry("middle", daysOld: 5, bytes: 400),
                       entry("oldest", daysOld: 9, bytes: 400)]
        XCTAssertEqual(
            FilePruning.overflow(entries, capBytes: 800)
                .map(\.lastPathComponent),
            ["oldest"])
        XCTAssertEqual(
            FilePruning.overflow(entries, capBytes: 100)
                .map(\.lastPathComponent),
            ["oldest", "middle"],
            "even an undersized cap keeps the newest file")
        XCTAssertTrue(FilePruning.overflow(entries, capBytes: 0).isEmpty)
        XCTAssertTrue(FilePruning.overflow(entries, capBytes: 1200).isEmpty)
    }
}

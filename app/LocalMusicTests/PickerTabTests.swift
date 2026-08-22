import XCTest
@testable import LocalMusic

/// The picker's strip: which tabs exist, and what each one counts. Pure, so
/// the rules can be read without a library, a sheet or a slot behind them.
final class PickerTabTests: XCTestCase {
    private func strip(_ counts: [SongOrigin: Int], songs: Bool = true,
                       parts: Int?) -> [(tab: PickerTab, count: Int)] {
        PickerTab.strip(songCounts: counts, showsSongs: songs, partCount: parts)
    }

    private let library: [SongOrigin: Int] = [.generated: 96, .imported: 30,
                                              .recombined: 2]

    func testPartsJoinsTheOriginsWhenTheSlotTakesThem() {
        let tabs = strip(library, parts: 4).map(\.tab)
        XCTAssertEqual(tabs, [.all, .songs(.generated), .songs(.imported),
                              .songs(.recombined), .parts])
    }

    /// A slot that would never take a part gets no tab for them — as opposed
    /// to a tab reading 0, which means "none yet".
    func testNoPartsTabWhereTheSlotTakesNone() {
        XCTAssertEqual(strip(library, parts: nil).map(\.tab),
                       [.all, .songs(.generated), .songs(.imported),
                        .songs(.recombined)])
    }

    func testAPartsTabSurvivesHavingNothingInIt() {
        let tabs = strip(library, parts: 0)
        XCTAssertEqual(tabs.last?.tab, .parts)
        XCTAssertEqual(tabs.last?.count, 0)
    }

    /// All counts what All lists, which is both halves of the sheet.
    func testAllCountsSongsAndParts() {
        XCTAssertEqual(strip(library, parts: 4).first?.count, 132)
        XCTAssertEqual(strip(library, parts: nil).first?.count, 128)
    }

    /// The origins are fixed rather than earned: a strip that reshuffles as
    /// the library fills up is one you cannot learn.
    func testEmptyOriginsStillGetTheirTab() {
        let tabs = strip([.generated: 3], parts: nil)
        XCTAssertEqual(tabs.map(\.tab), [.all, .songs(.generated),
                                         .songs(.imported), .songs(.recombined)])
        XCTAssertEqual(tabs.map(\.count), [3, 3, 0, 0])
    }

    /// With no songs listed the only tabs left would be All and Parts — one
    /// list and a synonym for it — so there is no strip at all.
    func testNoStripWithoutSongs() {
        XCTAssertTrue(strip([:], songs: false, parts: 7).isEmpty)
        XCTAssertTrue(strip([:], songs: false, parts: nil).isEmpty)
    }

    func testWhatEachTabShows() {
        XCTAssertTrue(PickerTab.all.showsSongs)
        XCTAssertTrue(PickerTab.all.showsParts)
        XCTAssertTrue(PickerTab.songs(.imported).showsSongs)
        XCTAssertFalse(PickerTab.songs(.imported).showsParts)
        XCTAssertFalse(PickerTab.parts.showsSongs)
        XCTAssertTrue(PickerTab.parts.showsParts)
    }

    func testTitlesMatchTheLibraryScopes() {
        XCTAssertEqual(PickerTab.songs(.generated).title, LibraryScope.songs.title)
        XCTAssertEqual(PickerTab.songs(.imported).title, LibraryScope.imported.title)
        XCTAssertEqual(PickerTab.songs(.recombined).title, LibraryScope.renders.title)
        XCTAssertEqual(PickerTab.parts.title, LibraryScope.parts.title)
    }
}

import XCTest
@testable import LocalMusic

/// The picker's strip: which tabs exist, and what each one counts. Pure, so
/// the rules can be read without a library, a sheet or a slot behind them.
final class PickerTabTests: XCTestCase {
    private func strip(_ counts: [SongOrigin: Int], songs: Bool = true,
                       parts: Int?, edited: Int = 0,
                       loved: Int = 0) -> [(tab: PickerTab, count: Int)] {
        PickerTab.strip(songCounts: counts, showsSongs: songs, partCount: parts,
                        editedCount: edited, lovedCount: loved)
    }

    private let library: [SongOrigin: Int] = [.generated: 96, .imported: 30,
                                              .recombined: 2]

    func testPartsJoinsTheOriginsWhenTheSlotTakesThem() {
        let tabs = strip(library, parts: 4).map(\.tab)
        XCTAssertEqual(tabs, [.all, .songs(.generated), .songs(.imported),
                              .songs(.recombined), .parts, .edited, .loved])
    }

    /// A slot that would never take a part gets no tab for them — as opposed
    /// to a tab reading 0, which means "none yet".
    func testNoPartsTabWhereTheSlotTakesNone() {
        XCTAssertEqual(strip(library, parts: nil).map(\.tab),
                       [.all, .songs(.generated), .songs(.imported),
                        .songs(.recombined), .edited, .loved])
    }

    func testAPartsTabSurvivesHavingNothingInIt() {
        let tabs = strip(library, parts: 0)
        XCTAssertEqual(tabs[4].tab, .parts)
        XCTAssertEqual(tabs[4].count, 0)
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
                                         .songs(.imported), .songs(.recombined),
                                         .edited, .loved])
        XCTAssertEqual(tabs.map(\.count), [3, 3, 0, 0, 0, 0])
    }

    /// With no songs listed the only tabs left would be All and Parts — one
    /// list and a synonym for it — so there is no strip at all.
    func testNoStripWithoutSongs() {
        XCTAssertTrue(strip([:], songs: false, parts: 7, edited: 3,
                            loved: 2).isEmpty)
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

    // MARK: - the merged list

    private func song(_ id: String, _ origin: SongOrigin, minutesAgo: Double,
                      editedMinutesAgo: Double? = nil,
                      loved: Bool = false) -> SongRecord {
        var record = SongRecord(
            id: id, title: id, prompt: "p", lyrics: nil, modelId: "m",
            modelName: "M", groupId: nil, paramsJSON: "{}", durationS: 10,
            sampleRate: 44100, fileName: id + ".wav", seedUsed: nil,
            createdAt: Date(timeIntervalSince1970: 100_000 - minutesAgo * 60),
            rating: 0, notes: "", favorite: loved)
        record.origin = origin.rawValue
        record.editedAt = editedMinutesAgo.map {
            Date(timeIntervalSince1970: 100_000 - $0 * 60)
        }
        return record
    }

    private func part(_ id: String, minutesAgo: Double,
                      editedMinutesAgo: Double? = nil,
                      loved: Bool = false) -> PartRecord {
        var record = PartRecord(
            id: id, songId: "s1", kind: "stem.drums", name: id,
            fileName: id + ".wav", format: "wav", previewFileName: nil,
            modelId: "sep", modelName: "Demucs", jobId: "j",
            splitParamsJSON: "{}", durationS: 10, sampleRate: 44100,
            createdAt: Date(timeIntervalSince1970: 100_000 - minutesAgo * 60))
        record.favorite = loved
        record.editedAt = editedMinutesAgo.map {
            Date(timeIntervalSince1970: 100_000 - $0 * 60)
        }
        return record
    }

    private func merge(parts: [PartRecord] = [], songs: [SongRecord] = [],
                       pickable: Bool = true) -> [PartPickerSheet.Listed] {
        PartPickerSheet.merge(parts: parts, sourceTitle: { _ in "A Song" },
                              songs: songs, songsArePickable: pickable)
    }

    /// Newest first, whichever table it came from — which is the whole point:
    /// the origins have always been mixed together, and parts were the one
    /// kind kept in their own aisle.
    func testTheListInterleavesPartsAndSongsByAge() {
        let rows = merge(parts: [part("drums", minutesAgo: 0.5),
                                 part("bass", minutesAgo: 120)],
                         songs: [song("recent", .generated, minutesAgo: 1),
                                 song("old", .imported, minutesAgo: 60)])
        XCTAssertEqual(rows.map(\.id), ["drums", "recent", "old", "bass"])
    }

    /// An edit is a touch. Without this a song you trimmed a minute ago sits
    /// wherever it was made, which for something from last month is a long
    /// way down a list you are scrolling to find it in.
    func testEditingLiftsARowUpTheList() {
        let rows = merge(parts: [part("fresh", minutesAgo: 5)],
                         songs: [song("ancient", .generated, minutesAgo: 90_000,
                                      editedMinutesAgo: 1)])
        XCTAssertEqual(rows.map(\.id), ["ancient", "fresh"])
    }

    /// …and only lifts it. A row edited long after it was made sorts by the
    /// edit; one never edited still sorts by when it was made.
    func testAnUneditedRowKeepsItsOwnPlace() {
        let rows = merge(songs: [song("a", .generated, minutesAgo: 10),
                                 song("b", .generated, minutesAgo: 20,
                                      editedMinutesAgo: 5)])
        XCTAssertEqual(rows.map(\.id), ["b", "a"])
    }

    /// A part came out of a song but is of no origin itself, so it carries no
    /// mark; a song carries its own.
    func testOnlySongsCarryAnOriginMark() {
        let rows = merge(parts: [part("drums", minutesAgo: 0)],
                         songs: [song("render", .recombined, minutesAgo: 1)])
        XCTAssertNil(rows[0].origin)
        XCTAssertEqual(rows[1].origin, .recombined)
    }

    /// Where the slot takes no whole song, its rows are offered for splitting
    /// instead of picking — and the parts beside them stay pickable.
    func testUnpickableSongsCarryTheRecordTheSplitButtonNeeds() {
        let rows = merge(parts: [part("drums", minutesAgo: 0)],
                         songs: [song("s", .generated, minutesAgo: 1)],
                         pickable: false)
        XCTAssertNil(rows[0].splittable)
        XCTAssertEqual(rows[1].splittable?.id, "s")
    }

    // MARK: - the two filter tabs

    /// Both span every origin *and* the parts, which is exactly why they are
    /// not slices: a hearted stem and a hearted import belong to the same tab.
    func testEditedAndLovedSpanBothTables() {
        let rows = merge(parts: [part("editedPart", minutesAgo: 1,
                                      editedMinutesAgo: 0),
                                 part("lovedPart", minutesAgo: 2, loved: true),
                                 part("plainPart", minutesAgo: 3)],
                         songs: [song("lovedSong", .imported, minutesAgo: 4,
                                      loved: true),
                                 song("plainSong", .generated, minutesAgo: 5)])
        func on(_ tab: PickerTab) -> [String] {
            rows.filter { tab.admits(edited: $0.isEdited, loved: $0.isLoved) }
                .map(\.id)
        }
        XCTAssertEqual(on(.edited), ["editedPart"])
        XCTAssertEqual(on(.loved), ["lovedPart", "lovedSong"])
        XCTAssertEqual(on(.all).count, 5)
        XCTAssertEqual(on(.parts).count, 5, "the slice tabs admit every row; "
                       + "which list a row is on is decided elsewhere")
    }

    /// The strip is five places and two adjectives, so All is the union of the
    /// slices and not the sum of every tab. The marks are what say so.
    func testTheFilterTabsAreMarkedAndTheSlicesAreNot() {
        XCTAssertNil(PickerTab.all.symbol)
        XCTAssertNil(PickerTab.songs(.generated).symbol)
        XCTAssertNil(PickerTab.parts.symbol)
        XCTAssertEqual(PickerTab.edited.symbol, LibraryScope.edited.symbol)
        XCTAssertEqual(PickerTab.loved.symbol, LibraryScope.favourites.symbol)
    }

    func testTheFilterTabsDrawOneMergedList() {
        XCTAssertTrue(PickerTab.all.isMerged)
        XCTAssertTrue(PickerTab.edited.isMerged)
        XCTAssertTrue(PickerTab.loved.isMerged)
        XCTAssertFalse(PickerTab.parts.isMerged)
        XCTAssertFalse(PickerTab.songs(.imported).isMerged)
    }

    func testTitlesMatchTheLibraryScopes() {
        XCTAssertEqual(PickerTab.songs(.generated).title, LibraryScope.songs.title)
        XCTAssertEqual(PickerTab.songs(.imported).title, LibraryScope.imported.title)
        XCTAssertEqual(PickerTab.songs(.recombined).title, LibraryScope.renders.title)
        XCTAssertEqual(PickerTab.parts.title, LibraryScope.parts.title)
    }
}

import XCTest
@testable import LocalMusic

/// What the library's tick boxes add up to, and what may honestly be done to
/// all of it at once.
final class LibrarySelectionTests: XCTestCase {

    private func song(_ id: String, favourite: Bool = false, rating: Int = 0,
                      durationS: Double = 10) -> SongRecord {
        SongRecord(id: id, title: id, prompt: "", lyrics: nil, modelId: "m",
                   modelName: "M", groupId: nil, paramsJSON: "{}",
                   durationS: durationS, sampleRate: 44100,
                   fileName: "\(id).wav", seedUsed: nil, createdAt: Date(),
                   rating: rating, notes: "", favorite: favourite,
                   origin: "generated")
    }

    private func part(_ id: String, favourite: Bool = false, rating: Int = 0,
                      durationS: Double? = 5) -> PartRecord {
        var record = PartRecord(
            id: id, songId: "s", kind: "stem.vocals", name: id,
            fileName: "\(id).wav", format: "wav", previewFileName: nil,
            modelId: "sep", modelName: "Demucs", jobId: nil,
            splitParamsJSON: "{}", durationS: durationS, sampleRate: 44100,
            createdAt: Date())
        record.favorite = favourite
        record.rating = rating
        return record
    }

    private func selection(_ ids: [String], songs: [SongRecord] = [],
                           parts: [PartRecord] = []) -> LibrarySelection {
        LibrarySelection.of(ids: Set(ids), songs: songs, parts: parts)
    }

    // MARK: resolution

    func testItResolvesAcrossBothTables() {
        let out = selection(["a", "p1"], songs: [song("a"), song("b")],
                            parts: [part("p1")])
        XCTAssertEqual(out.songs.map(\.id), ["a"])
        XCTAssertEqual(out.parts.map(\.id), ["p1"])
        XCTAssertEqual(out.count, 2)
        XCTAssertTrue(out.isMultiple)
    }

    /// A row deleted in another pane leaves its id ticked. Counting it as
    /// missing rather than dropping it is the difference between a panel that
    /// says "3 selected" over three files and one that says it over two.
    func testAnIdWithNoRowIsCountedAsMissing() {
        let out = selection(["a", "ghost"], songs: [song("a")])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.unresolved, 1)
    }

    /// One row is not a selection — the single-row pane is better at it in
    /// every way, because it can rename, rate and explain.
    func testOneRowIsNotAMultipleSelection() {
        XCTAssertFalse(selection(["a"], songs: [song("a")]).isMultiple)
        XCTAssertFalse(LibrarySelection().isMultiple)
    }

    func testKindLineNamesBothKinds() {
        XCTAssertEqual(selection(["a", "b"], songs: [song("a"), song("b")])
            .kindLine, "2 SONGS")
        XCTAssertEqual(selection(["p1"], parts: [part("p1")]).kindLine,
                       "1 PART")
        XCTAssertEqual(selection(["a", "p1", "p2"], songs: [song("a")],
                                 parts: [part("p1"), part("p2")]).kindLine,
                       "1 SONG · 2 PARTS")
    }

    // MARK: totals

    func testDurationAddsUp() {
        let out = selection(["a", "p1"], songs: [song("a", durationS: 30)],
                            parts: [part("p1", durationS: 12)])
        XCTAssertEqual(out.durationS ?? 0, 42, accuracy: 1e-9)
    }

    /// A part whose length was never measured contributes nothing to an
    /// addition, so a total quietly missing one row looks exactly like a
    /// correct one. Nil says so instead.
    func testAnUnmeasuredRowMakesTheTotalUnknown() {
        let out = selection(["p1", "p2"],
                            parts: [part("p1"), part("p2", durationS: nil)])
        XCTAssertNil(out.durationS)
    }

    // MARK: favourite + rating

    /// The direction that matters: a mixed selection fills in rather than
    /// emptying out, so one press never silently un-hearts the ones that were.
    func testFavouriteOnlyReadsAsRemoveWhenEveryOneIsAlready() {
        XCTAssertFalse(selection(["a", "b"],
                                 songs: [song("a", favourite: true),
                                         song("b")]).allFavourite)
        XCTAssertTrue(selection(["a", "b"],
                                songs: [song("a", favourite: true),
                                        song("b", favourite: true)])
            .allFavourite)
    }

    func testFavouriteSpansKinds() {
        XCTAssertFalse(selection(["a", "p1"],
                                 songs: [song("a", favourite: true)],
                                 parts: [part("p1")]).allFavourite)
        XCTAssertTrue(selection(["a", "p1"],
                                songs: [song("a", favourite: true)],
                                parts: [part("p1", favourite: true)])
            .allFavourite)
    }

    /// Stars filled from one row's rating over a selection that disagrees
    /// would invite a press that overwrites the rest with a number nobody
    /// chose.
    func testRatingIsSharedOnlyWhenTheyAgree() {
        XCTAssertEqual(selection(["a", "b"], songs: [song("a", rating: 4),
                                                     song("b", rating: 4)])
            .sharedRating, 4)
        XCTAssertNil(selection(["a", "b"], songs: [song("a", rating: 4),
                                                   song("b", rating: 2)])
            .sharedRating)
    }

    // MARK: what applies

    /// A song does not go on the bench as one lane — it goes on as its
    /// separated parts — so a mixed selection cannot offer it.
    func testTheBenchTakesPartsAndOnlyParts() {
        XCTAssertTrue(selection(["p1", "p2"],
                                parts: [part("p1"), part("p2")])
            .canAddToWorkbench)
        XCTAssertFalse(selection(["a", "p1"], songs: [song("a")],
                                 parts: [part("p1")]).canAddToWorkbench)
        XCTAssertFalse(LibrarySelection().canAddToWorkbench)
    }

    /// The A/B switch plays whole takes against each other; two parts are not
    /// a comparison.
    func testComparingNeedsTwoSongs() {
        XCTAssertTrue(selection(["a", "b"], songs: [song("a"), song("b")])
            .canCompare)
        XCTAssertFalse(selection(["p1", "p2"],
                                 parts: [part("p1"), part("p2")]).canCompare)
        XCTAssertFalse(selection(["a", "p1"], songs: [song("a")],
                                 parts: [part("p1")]).canCompare)
    }

    func testRevealCollectsEveryFile() {
        let out = selection(["a", "p1"], songs: [song("a")],
                            parts: [part("p1")])
        XCTAssertEqual(out.fileURLs.count, 2)
    }

    // MARK: export naming

    /// Two songs called `track042` from different batches, or a song and its
    /// own stem, land on the same name. Overwriting the file written a moment
    /// ago is the one outcome an export may not have.
    func testExportNamesNeverCollide() {
        var taken: Set<String> = []
        XCTAssertEqual(
            LibrarySelectionInspector.unique("track042.wav", taken: &taken),
            "track042.wav")
        XCTAssertEqual(
            LibrarySelectionInspector.unique("track042.wav", taken: &taken),
            "track042-2.wav")
        XCTAssertEqual(
            LibrarySelectionInspector.unique("track042.wav", taken: &taken),
            "track042-3.wav")
        XCTAssertEqual(
            LibrarySelectionInspector.unique("no-extension", taken: &taken),
            "no-extension")
        XCTAssertEqual(
            LibrarySelectionInspector.unique("no-extension", taken: &taken),
            "no-extension-2")
    }
}

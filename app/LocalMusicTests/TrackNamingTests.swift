import XCTest
@testable import LocalMusic

/// Default `trackNNN` naming for generated tracks, and the rules that decide
/// when a list row appends the prompt after the name.
final class TrackNamingTests: XCTestCase {
    private func makeRepo() throws -> LibraryRepository {
        LibraryRepository(db: try DatabaseManager.inMemory())
    }

    private func song(title: String, prompt: String = "a prompt") -> SongRecord {
        let id = UUID().uuidString
        return SongRecord(id: id, title: title, prompt: prompt, lyrics: nil,
                          modelId: "musicgen-small", modelName: "MusicGen Small",
                          groupId: nil, paramsJSON: "{}", durationS: 10,
                          sampleRate: 32000, fileName: id + ".wav",
                          seedUsed: 7, createdAt: Date(), rating: 0,
                          notes: "", favorite: false)
    }

    func testNameFormatIsPaddedAndGrows() {
        XCTAssertEqual(SongRecord.trackName(number: 1), "track001")
        XCTAssertEqual(SongRecord.trackName(number: 42), "track042")
        XCTAssertEqual(SongRecord.trackName(number: 999), "track999")
        XCTAssertEqual(SongRecord.trackName(number: 1000), "track1000")
    }

    func testNumberParsedOnlyFromDefaultNames() {
        XCTAssertEqual(SongRecord.trackNumber(in: "track007"), 7)
        XCTAssertEqual(SongRecord.trackNumber(in: "track1000"), 1000)
        XCTAssertNil(SongRecord.trackNumber(in: "track"))
        XCTAssertNil(SongRecord.trackNumber(in: "trackish"))
        XCTAssertNil(SongRecord.trackNumber(in: "track007 remix"))
        XCTAssertNil(SongRecord.trackNumber(in: "My track"))
    }

    // MARK: - takes of one submission

    /// The whole point: one submission, one number, a letter per take.
    func testTakesOfOneSubmissionShareANumber() {
        XCTAssertEqual(SongRecord.trackNames(number: 42, count: 3),
                       ["track042a", "track042b", "track042c"])
    }

    /// A lone take has nothing to be told apart from, so it stays plain.
    func testSingleTakeGetsNoLetter() {
        XCTAssertEqual(SongRecord.trackNames(number: 42, count: 1), ["track042"])
        XCTAssertEqual(SongRecord.trackNames(number: 42, count: 0), ["track042"])
    }

    /// Bijective base 26 — no two takes can collide however many are asked for.
    func testLettersKeepGoingPastZ() {
        XCTAssertEqual(SongRecord.takeSuffix(0), "a")
        XCTAssertEqual(SongRecord.takeSuffix(25), "z")
        XCTAssertEqual(SongRecord.takeSuffix(26), "aa")
        XCTAssertEqual(SongRecord.takeSuffix(27), "ab")
        XCTAssertEqual(SongRecord.takeSuffix(51), "az")
        XCTAssertEqual(SongRecord.takeSuffix(52), "ba")
        let many = SongRecord.trackNames(number: 7, count: 60)
        XCTAssertEqual(Set(many).count, 60, "every take needs its own name")
    }

    /// Lettered names must read back as their number, or the high-water mark
    /// ignores the batch just written and the next one collides with it.
    func testLetteredNamesStillParseAsTheirNumber() {
        XCTAssertEqual(SongRecord.trackNumber(in: "track042a"), 42)
        XCTAssertEqual(SongRecord.trackNumber(in: "track042c"), 42)
        XCTAssertEqual(SongRecord.trackNumber(in: "track007aa"), 7)
        // Still nothing but a number and its letters.
        XCTAssertNil(SongRecord.trackNumber(in: "track042 a"))
        XCTAssertNil(SongRecord.trackNumber(in: "track042A"))
        XCTAssertNil(SongRecord.trackNumber(in: "tracka"))
    }

    // MARK: - names you type

    /// A typed name is prose, so its letter goes in brackets — running it onto
    /// the end would make a different word ("Warehouse jama").
    func testTypedNamesTakeTheirLetterInBrackets() {
        XCTAssertEqual(
            SongRecord.takeNames(base: "Warehouse jam", count: 3),
            ["Warehouse jam (a)", "Warehouse jam (b)", "Warehouse jam (c)"])
    }

    /// One take of a typed name is just the name.
    func testSingleTypedTakeGetsNoBracket() {
        XCTAssertEqual(SongRecord.takeNames(base: "Warehouse jam", count: 1),
                       ["Warehouse jam"])
    }

    /// The default name keeps the bare-suffix form: the letter is part of the
    /// identifier, and `trackNumber(in:)` has to keep reading it back.
    func testDefaultNamesKeepTheBareSuffix() {
        XCTAssertEqual(SongRecord.takeNames(base: "track042", count: 3),
                       ["track042a", "track042b", "track042c"])
        XCTAssertEqual(SongRecord.trackNumber(in: "track042c"), 42)
        // A bracketed name is not a default name and must not move the mark.
        XCTAssertNil(SongRecord.trackNumber(in: "Warehouse jam (c)"))
    }

    func testTypedNamesAreTrimmed() {
        XCTAssertEqual(SongRecord.takeNames(base: "  Late night  ", count: 2),
                       ["Late night (a)", "Late night (b)"])
        XCTAssertEqual(SongRecord.takeNames(base: " track007 ", count: 2),
                       ["track007a", "track007b"])
    }

    /// Past 26 the letters keep going, in either form.
    func testBracketedLettersAlsoGoPastZ() {
        let names = SongRecord.takeNames(base: "Set", count: 27)
        XCTAssertEqual(names[25], "Set (z)")
        XCTAssertEqual(names[26], "Set (aa)")
        XCTAssertEqual(Set(names).count, 27)
    }

    /// End to end through the repository: a lettered batch moves the mark, so
    /// the batch after it starts at the next number.
    func testBatchAdvancesTheHighWaterMark() throws {
        let repo = try makeRepo()
        for title in SongRecord.trackNames(number: 42, count: 3) {
            try repo.insert(song(title: title))
        }
        XCTAssertEqual(try repo.highestTrackNumber(), 42)
        XCTAssertEqual(SongRecord.trackNames(number: try repo.highestTrackNumber() + 1,
                                             count: 2),
                       ["track043a", "track043b"])
    }

    func testHighestIgnoresUserNamedTracks() throws {
        let repo = try makeRepo()
        try repo.insert(song(title: "track003"))
        try repo.insert(song(title: "track011"))
        try repo.insert(song(title: "trackside jam"))   // not a default name
        try repo.insert(song(title: "Best one yet"))
        XCTAssertEqual(try repo.highestTrackNumber(), 11)
    }

    func testEmptyLibraryStartsAtOne() throws {
        let repo = try makeRepo()
        XCTAssertEqual(try repo.highestTrackNumber(), 0)
        XCTAssertEqual(SongRecord.trackName(number: try repo.highestTrackNumber() + 1),
                       "track001")
    }

    /// Deleting or renaming must not hand a live number to a later track.
    func testNumbersAreNotReusedAfterDelete() throws {
        let repo = try makeRepo()
        let third = song(title: "track003")
        try repo.insert(song(title: "track001"))
        try repo.insert(song(title: "track002"))
        try repo.insert(third)
        try repo.delete(id: third.id)
        XCTAssertEqual(try repo.highestTrackNumber(), 2)

        var renamed = song(title: "track009")
        try repo.insert(renamed)
        renamed.title = "Keeper"
        try repo.update(renamed)
        XCTAssertEqual(try repo.highestTrackNumber(), 2)
    }

    // MARK: - what the list rows show

    func testPromptShownAfterDefaultName() {
        let view = TrackTitle(song: song(title: "track007", prompt: "warm lo-fi beat"))
        XCTAssertEqual(view.promptSuffix, " - warm lo-fi beat")
    }

    func testNoPromptSuffixWhenThereIsNoPrompt() {
        // imported and recombined tracks carry an empty prompt
        let view = TrackTitle(song: song(title: "track007", prompt: ""))
        XCTAssertNil(view.promptSuffix)
    }

    /// Tracks generated before this change were titled with the prompt itself;
    /// repeating it would read as "warm lo-fi beat - warm lo-fi beat".
    func testNoPromptSuffixWhenTitleIsThePrompt() {
        let legacy = song(title: "warm lo-fi beat", prompt: "warm lo-fi beat")
        XCTAssertNil(TrackTitle(song: legacy).promptSuffix)

        // old titles were truncated to 60 characters, so the prompt merely
        // starts with the title
        let long = String(repeating: "a very long prompt ", count: 6)
        let truncated = song(title: String(long.prefix(60)), prompt: long)
        XCTAssertNil(TrackTitle(song: truncated).promptSuffix)
    }

    func testMetadataLineIsModelLengthThenWhen() {
        var track = song(title: "track007")
        track.durationS = 9.6      // rounds rather than truncates
        let line = TrackRow.metadata(for: track)
        XCTAssertTrue(line.hasPrefix("MusicGen Small · 10 s · "), line)
        XCTAssertEqual(line.components(separatedBy: " · ").count, 3, line)
    }

    func testNewlinesFlattenedIntoOneLine() {
        let view = TrackTitle(song: song(title: "track007",
                                         prompt: "verse one\nverse two"))
        XCTAssertEqual(view.promptSuffix, " - verse one verse two")
    }
}

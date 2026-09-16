import XCTest
@testable import LocalMusicGen

/// The menubar's arithmetic.
///
/// A `Commands` body cannot be instantiated in a test, so what is checked here
/// is everything a menu item *decides* before it draws itself: which key opens
/// which destination, and which track the Track menu is aimed at. The items
/// themselves are left holding a title and a closure, which is the point of
/// having put the decisions in `ShellCommandRouting`.
@MainActor
final class MenuCommandTests: XCTestCase {

    private func freshShell() -> ShellState {
        ShellState(defaults: UserDefaults(
            suiteName: "menu-tests-\(UUID().uuidString)")!)
    }

    // MARK: - Shortcut mapping

    /// Declaration order *is* sidebar order — the enum's own comments say so —
    /// and the digits have to follow it, or ⌘1 would open whichever case
    /// happened to be written first.
    func testDestinationsTakeDigitsInSidebarOrder() {
        XCTAssertEqual(Destination.actions.menuIndex, 1)
        XCTAssertEqual(Destination.generate.menuIndex, 2)
        XCTAssertEqual(Destination.styleTransfer.menuIndex, 3)
        XCTAssertEqual(Destination.workbench.menuIndex, 4)
        XCTAssertEqual(Destination.editor.menuIndex, 5)
        XCTAssertEqual(Destination.library.menuIndex, 6)
        XCTAssertEqual(Destination.models.menuIndex, 7)
    }

    /// Seven of them, so none falls past the ninth — but the mapping is
    /// derived rather than written out, and an eighth destination arriving
    /// should not quietly lose its shortcut without this failing first.
    func testEveryDestinationGetsItsOwnKey() {
        for destination in Destination.allCases {
            XCTAssertNotNil(destination.menuKey,
                            "\(destination.title) has no menu key")
        }
        XCTAssertEqual(Set(Destination.allCases.compactMap(\.menuKey)).count,
                       Destination.allCases.count,
                       "two destinations share a shortcut")
    }

    func testLibraryScopesTakeTheirOwnDigits() {
        // All leads: it is the Library row itself, and the row heads the column
        // the rest of them are drawn in.
        XCTAssertEqual(LibraryScope.all.menuIndex, 1)
        XCTAssertEqual(LibraryScope.songs.menuIndex, 2)
        XCTAssertEqual(LibraryScope.favourites.menuIndex, 6)
        XCTAssertEqual(Set(LibraryScope.allCases.compactMap(\.menuKey)).count,
                       LibraryScope.allCases.count)
    }

    // MARK: - What the Track menu is aimed at

    /// It holds exactly one thing and that thing is in front of you.
    func testEditorWinsWhileItIsTheScreenYouAreOn() {
        let target = ShellCommandRouting.target(
            destination: .editor, scope: .songs,
            selectedSongId: "picked-in-library", selectedPartId: nil,
            editorMaterialId: "open-in-editor", editorMaterialIsPart: false)
        XCTAssertEqual(target, .song(id: "open-in-editor"))
    }

    func testEditorCarriesItsKind() {
        let target = ShellCommandRouting.target(
            destination: .editor, scope: .songs,
            selectedSongId: nil, selectedPartId: nil,
            editorMaterialId: "stem-7", editorMaterialIsPart: true)
        XCTAssertEqual(target, .part(id: "stem-7"))
        XCTAssertTrue(target.isPart)
    }

    /// The Editor is the destination but has no material — the menu must dim,
    /// not act on a library row the user cannot see.
    func testEmptyEditorClaimsNothing() {
        let target = ShellCommandRouting.target(
            destination: .editor, scope: .songs,
            selectedSongId: "track042", selectedPartId: nil,
            editorMaterialId: nil, editorMaterialIsPart: false)
        XCTAssertEqual(target, .none)
    }

    /// Both selections are kept, deliberately, so a scope round-trip does not
    /// lose your place — which is exactly why the scope has to decide which of
    /// them the menu means.
    func testLibraryPicksTheKindItsScopeIsListing() {
        let songs = ShellCommandRouting.target(
            destination: .library, scope: .songs,
            selectedSongId: "track042", selectedPartId: "stem-7",
            editorMaterialId: nil, editorMaterialIsPart: false)
        XCTAssertEqual(songs, .song(id: "track042"))

        let parts = ShellCommandRouting.target(
            destination: .library, scope: .parts,
            selectedSongId: "track042", selectedPartId: "stem-7",
            editorMaterialId: nil, editorMaterialIsPart: false)
        XCTAssertEqual(parts, .part(id: "stem-7"))
    }

    /// A scope that lists one kind means that kind, whatever else is lying
    /// around from the last list you were in.
    func testEverySingleKindScopeMeansTheSongSelection() {
        for scope in LibraryScope.allCases
        where scope != .parts && !scope.spansBothTables {
            let target = ShellCommandRouting.target(
                destination: .library, scope: scope,
                selectedSongId: "track042", selectedPartId: "stem-7",
                editorMaterialId: nil, editorMaterialIsPart: false)
            XCTAssertEqual(target, .song(id: "track042"),
                           "\(scope.title) aimed at the wrong kind")
        }
    }

    /// All and Favourites list both kinds, and picking one clears the other —
    /// so the menu takes whichever is picked. Without this the Track menu was
    /// dead over every part in Favourites: it fell through to a song selection
    /// that choosing the part had just cleared.
    func testASpanningScopeTakesWhicheverKindIsPicked() {
        for scope in LibraryScope.allCases where scope.spansBothTables {
            XCTAssertEqual(
                ShellCommandRouting.target(
                    destination: .library, scope: scope,
                    selectedSongId: nil, selectedPartId: "stem-7",
                    editorMaterialId: nil, editorMaterialIsPart: false),
                .part(id: "stem-7"), "\(scope.title) lost the part")
            XCTAssertEqual(
                ShellCommandRouting.target(
                    destination: .library, scope: scope,
                    selectedSongId: "track042", selectedPartId: nil,
                    editorMaterialId: nil, editorMaterialIsPart: false),
                .song(id: "track042"), "\(scope.title) lost the song")
        }
    }

    /// Not a fallback to the song: acting on a row from a list that is not on
    /// screen is worse than a greyed-out menu.
    func testScopeWithNothingPickedAimsAtNothing() {
        let target = ShellCommandRouting.target(
            destination: .library, scope: .parts,
            selectedSongId: "track042", selectedPartId: nil,
            editorMaterialId: nil, editorMaterialIsPart: false)
        XCTAssertEqual(target, .none)
    }

    func testOtherScreensAimAtNothing() {
        for destination in Destination.allCases
        where destination != .library && destination != .editor {
            let target = ShellCommandRouting.target(
                destination: destination, scope: .songs,
                selectedSongId: "track042", selectedPartId: "stem-7",
                editorMaterialId: "open", editorMaterialIsPart: false)
            XCTAssertEqual(target, .none,
                           "\(destination.title) claimed a track it is not "
                           + "showing")
        }
    }

    // MARK: - Item titles

    func testRatingTitlesCountStars() {
        XCTAssertEqual(ShellCommandRouting.ratingTitle(0), "No Rating")
        XCTAssertEqual(ShellCommandRouting.ratingTitle(3), "\u{2605}\u{2605}\u{2605}")
        XCTAssertEqual(ShellCommandRouting.ratingTitle(5).count, 5)
    }

    func testToggleTitlesSayWhatWillHappenNext() {
        XCTAssertEqual(
            ShellCommandRouting.sidebarItemTitle(isCollapsed: true),
            "Show Sidebar")
        XCTAssertEqual(
            ShellCommandRouting.sidebarItemTitle(isCollapsed: false),
            "Hide Sidebar")
        XCTAssertEqual(ShellCommandRouting.queueItemTitle(isOpen: true),
                       "Hide Queue")
        XCTAssertEqual(ShellCommandRouting.queueItemTitle(isOpen: false),
                       "Show Queue")
    }

    func testLongTrackNamesAreTrimmedForTheMenu() {
        XCTAssertEqual(ShellActions.short("track042"), "track042")
        let long = ShellActions.short(String(repeating: "a", count: 60))
        XCTAssertEqual(long.count, 28)
        XCTAssertTrue(long.hasSuffix("\u{2026}"))
    }

    // MARK: - Shell state

    /// The point of the `didSet` pattern is that the write actually lands — a
    /// computed pass-through to `UserDefaults` would not publish under
    /// Observation, and a stored one that forgot to write would lose the
    /// preference on the next launch.
    func testShellPersistsOnlyThePanelPreferences() {
        let defaults = UserDefaults(
            suiteName: "menu-tests-\(UUID().uuidString)")!
        let shell = ShellState(defaults: defaults)
        XCTAssertFalse(shell.queuePinned)
        XCTAssertFalse(shell.sidebarCollapsed)

        shell.queuePinned = true
        shell.sidebarCollapsed = true

        let reopened = ShellState(defaults: defaults)
        XCTAssertTrue(reopened.queuePinned)
        XCTAssertTrue(reopened.sidebarCollapsed)
        // The destination deliberately does not persist — coming back to where
        // the app *starts* is steadier than to wherever you happened to stop.
        XCTAssertEqual(reopened.destination, Destination.launch)
    }

    func testCrampedOverrulesThePreferenceWithoutErasingIt() {
        let shell = freshShell()
        shell.sidebarCramped = true
        XCTAssertTrue(shell.sidebarIsCollapsed)
        // The preference is untouched, so the sidebar comes back when the
        // window grows — the same contract `SidebarFit` keeps.
        XCTAssertFalse(shell.sidebarCollapsed)
    }

    func testGoingToAScopeAlsoGoesToTheLibrary() {
        let shell = freshShell()
        shell.go(to: LibraryScope.favourites)
        XCTAssertEqual(shell.libraryScope, .favourites)
        XCTAssertEqual(shell.destination, .library)
    }

    /// Always assigned — including nil — so an errand from one screen cannot
    /// leave its filter behind for the next visit from another.
    func testOpeningModelsAlwaysAssignsTheRequirement() {
        let shell = freshShell()
        shell.openModels(for: .task("separate"))
        XCTAssertEqual(shell.modelRequirement, .task("separate"))
        shell.openModels(for: nil)
        XCTAssertNil(shell.modelRequirement)
        XCTAssertEqual(shell.destination, .models)
    }

    // MARK: - The shortcut table

    /// The failure this table was built to make impossible.
    ///
    /// Two menus claiming one key is silent at runtime — whichever loads last
    /// wins, and the other item simply never fires. The ranges (⌘1–7, ⌥⌘1–6,
    /// ⌃⌘0–5) are checked against the same set below, since they are built
    /// from `menuKey` rather than declared here.
    func testNoTwoMenuItemsClaimTheSameKey() {
        var seen: [String: String] = [:]
        for shortcut in ShortcutCatalog.installed {
            if let owner = seen[shortcut.display] {
                XCTFail("\(shortcut.display) is claimed by both “\(owner)” "
                        + "and “\(shortcut.title)”")
            }
            seen[shortcut.display] = shortcut.title
        }
    }

    /// The three generated ranges are not in `installed` — they are built from
    /// `Destination.menuKey` and friends — so they get their own collision
    /// check against everything that is.
    func testGeneratedRangesDoNotCollideWithTheTable() {
        let claimed = Set(ShortcutCatalog.installed.map(\.display))
        for destination in Destination.allCases {
            guard let key = destination.menuKey else { continue }
            XCTAssertFalse(claimed.contains("\u{2318}\(key)"),
                           "\u{2318}\(key) is both a destination and an item")
        }
        for scope in LibraryScope.allCases {
            guard let key = scope.menuKey else { continue }
            XCTAssertFalse(claimed.contains("\u{2325}\u{2318}\(key)"),
                           "\u{2325}\u{2318}\(key) is both a scope and an item")
        }
        for stars in 0...5 {
            XCTAssertFalse(claimed.contains("\u{2303}\u{2318}\(stars)"),
                           "\u{2303}\u{2318}\(stars) is both a rating and an "
                           + "item")
        }
    }

    /// Modifiers print in the order macOS prints them, and the keys that are
    /// not characters print as their glyphs rather than as control codes.
    func testShortcutsAreWrittenTheWayAMenuWritesThem() {
        XCTAssertEqual(ShortcutCatalog.export.display, "\u{21E7}\u{2318}E")
        XCTAssertEqual(ShortcutCatalog.skipBack.display,
                       "\u{2303}\u{2318}\u{2190}")
        XCTAssertEqual(ShortcutCatalog.playPause.display, "\u{2303}Space")
        XCTAssertEqual(ShortcutCatalog.run.display, "\u{2318}\u{23CE}")
        // ⇧⌘⌫, not ⌘⌫: the latter is AppKit's `deleteToBeginningOfLine:`, and
        // a menu key equivalent beats the field editor to it — see
        // `ShortcutCatalog.delete`.
        XCTAssertEqual(ShortcutCatalog.delete.display,
                       "\u{21E7}\u{2318}\u{232B}")
        // The transport bar's A/B tooltip renders this one rather than naming
        // a key of its own — it used to say "Tab", and pressing Tab moves
        // focus.
        XCTAssertEqual(ShortcutCatalog.switchSide.display, "\u{2325}\u{21E5}")
    }

    /// Keys AppKit has already given to the field editor.
    ///
    /// A menu key equivalent is resolved by `NSApplication` before the event
    /// reaches the responder chain, so claiming one of these takes it away from
    /// every text field in the app — and File ▸ Delete… claimed ⌘⌫, which
    /// `StandardKeyBinding.dict` maps to `deleteToBeginningOfLine:`. Clearing
    /// the line while renaming a track deleted the track.
    func testNoMenuItemClaimsAStandardTextEditingKey() {
        let reserved: [String: String] = [
            "\u{2318}\u{232B}": "deleteToBeginningOfLine:",
            "\u{2325}\u{232B}": "deleteWordBackward:",
            "\u{2303}\u{232B}": "deleteBackwardByDecomposingPreviousCharacter:",
            "\u{2318}\u{2190}": "moveToLeftEndOfLine:",
            "\u{2318}\u{2192}": "moveToRightEndOfLine:",
            "\u{2318}\u{2191}": "moveToBeginningOfDocument:",
            "\u{2318}\u{2193}": "moveToEndOfDocument:",
        ]
        for shortcut in ShortcutCatalog.installed {
            if let binding = reserved[shortcut.display] {
                XCTFail("\u{201C}\(shortcut.title)\u{201D} claims "
                        + "\(shortcut.display), which AppKit binds to "
                        + "\(binding) in every text field")
            }
        }
    }

    /// Every binding the menubar installs is in the sheet, because the sheet
    /// is drawn from the same table. The test is that nobody has added a
    /// section without its rows — an entry in `installed` that no section
    /// lists would be a key with no reference line.
    func testEveryInstalledShortcutIsInTheReferenceSheet() {
        let listed = Set(ShortcutCatalog.sections
            .flatMap(\.lines)
            .map(\.keys))
        for shortcut in ShortcutCatalog.installed {
            XCTAssertTrue(listed.contains(shortcut.display),
                          "\(shortcut.title) (\(shortcut.display)) is not in "
                          + "the shortcuts sheet")
        }
    }

    // MARK: - Volume

    /// Stepping lands on the step, not merely inside the range: adding a tenth
    /// to 0.35 repeatedly must reach 1.0 exactly rather than walking half a
    /// step out of alignment and stopping at 0.95.
    func testVolumeStepsLandOnTheStep() {
        XCTAssertEqual(PlaybackController.stepped(0.35, by: 0.1), 0.4,
                       accuracy: 1e-9)
        XCTAssertEqual(PlaybackController.stepped(0.4, by: -0.1), 0.3,
                       accuracy: 1e-9)
        var level = 0.35
        for _ in 0..<20 { level = PlaybackController.stepped(level, by: 0.1) }
        XCTAssertEqual(level, 1.0, accuracy: 1e-9)
    }

    func testVolumeIsClampedAtBothEnds() {
        XCTAssertEqual(PlaybackController.stepped(1, by: 0.1), 1)
        XCTAssertEqual(PlaybackController.stepped(0, by: -0.1), 0)
        XCTAssertEqual(PlaybackController.stepped(0.05, by: -0.1), 0)
    }

    // MARK: - Copy Track Details

    private func makeSong(title: String = "track042",
                          prompt: String = "warm rhodes, slow",
                          seed: Int64? = 7) -> SongRecord {
        SongRecord(id: "s1", title: title, prompt: prompt, lyrics: nil,
                   modelId: "m", modelName: "MusicGen Small", groupId: nil,
                   paramsJSON: "{}", durationS: 187, sampleRate: 44_100,
                   fileName: "track042.wav", seedUsed: seed,
                   createdAt: Date(), rating: 4, notes: "", favorite: false)
    }

    func testDetailsNamesWhatTheTrackKnows() {
        let text = ShellCommandRouting.details(
            song: makeSong(), part: nil,
            analysis: AnalysisRecord(ownerId: "s1", ownerType: "song",
                                     bpm: 92.4, keyName: "A minor",
                                     camelot: "8A", analysisJSON: "{}",
                                     modelId: "analyzer", createdAt: Date()))
        let unwrapped = try? XCTUnwrap(text)
        XCTAssertTrue(unwrapped?.contains("Title: track042") ?? false)
        XCTAssertTrue(unwrapped?.contains("Duration: 3:07") ?? false)
        XCTAssertTrue(unwrapped?.contains("Seed: 7") ?? false)
        XCTAssertTrue(unwrapped?.contains("Rating: 4/5") ?? false)
        XCTAssertTrue(unwrapped?.contains("Tempo: 92 BPM") ?? false)
        XCTAssertTrue(unwrapped?.contains("Key: A minor (8A)") ?? false)
    }

    /// A field nobody has filled is left out rather than printed empty: a
    /// block half full of blanks reads as a broken export rather than as a
    /// track nothing has measured.
    func testDetailsLeaveOutWhatIsNotKnown() {
        let text = ShellCommandRouting.details(
            song: makeSong(prompt: "  ", seed: nil), part: nil, analysis: nil)
        XCTAssertNotNil(text)
        XCTAssertFalse(text?.contains("Prompt:") ?? true)
        XCTAssertFalse(text?.contains("Seed:") ?? true)
        XCTAssertFalse(text?.contains("Tempo:") ?? true)
    }

    func testDetailsAreNilWithNothingPicked() {
        XCTAssertNil(ShellCommandRouting.details(song: nil, part: nil,
                                                 analysis: nil))
    }

    func testDurationsAreMinutesAndSeconds() {
        XCTAssertEqual(ShellCommandRouting.duration(0), "0:00")
        XCTAssertEqual(ShellCommandRouting.duration(9.6), "0:10")
        XCTAssertEqual(ShellCommandRouting.duration(605), "10:05")
    }

    // MARK: - Show Notation

    /// Notation is filed on songs, so the item aims at the song a picked
    /// part came from — and at nothing when nothing is picked. It carries no
    /// key on purpose: the shortcut table is deliberately small, and it is
    /// not in `installed`, which is what the collision test walks.
    func testShowNotationAimsAtTheSongOfThePickedRow() {
        XCTAssertEqual(
            ShellCommandRouting.notationSongId(song: makeSong(), part: nil),
            "s1")
        let part = PartRecord(
            id: "p1", songId: "s1", kind: "notes.piano", name: "piano",
            fileName: "p1.mid", format: "midi", previewFileName: nil,
            modelId: "bp", modelName: "Basic Pitch", jobId: "job_1",
            splitParamsJSON: "{}", durationS: nil, sampleRate: nil,
            createdAt: Date())
        XCTAssertEqual(ShellCommandRouting.notationSongId(song: nil, part: part),
                       "s1")
        XCTAssertNil(ShellCommandRouting.notationSongId(song: nil, part: nil))
        XCTAssertFalse(ShortcutCatalog.installed.contains {
            $0.title == "Show Notation"
        })
    }

    // MARK: - Shell mailboxes

    /// The Settings pane, the notes field and the shortcuts sheet are all
    /// one-shot requests, and the window that consumes one clears it. What is
    /// checked here is that they start empty — a mailbox with a default would
    /// fire on launch.
    func testTheNewMailboxesStartEmpty() {
        let shell = freshShell()
        XCTAssertNil(shell.settingsPane)
        XCTAssertNil(shell.notesRequest)
        XCTAssertNil(shell.notationRequest)
        XCTAssertNil(shell.pendingBatchDelete)
        XCTAssertFalse(shell.showShortcuts)
        // Not a mailbox: a display preference the View menu toggles, and the
        // Library groups parts by default.
        XCTAssertTrue(shell.libraryGroupsParts)
    }
}

import XCTest
@testable import LocalMusic

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
        XCTAssertEqual(LibraryScope.songs.menuIndex, 1)
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

    func testEveryNonPartsScopeMeansTheSongSelection() {
        for scope in LibraryScope.allCases where scope != .parts {
            let target = ShellCommandRouting.target(
                destination: .library, scope: scope,
                selectedSongId: "track042", selectedPartId: "stem-7",
                editorMaterialId: nil, editorMaterialIsPart: false)
            XCTAssertEqual(target, .song(id: "track042"),
                           "\(scope.title) aimed at the wrong kind")
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
}

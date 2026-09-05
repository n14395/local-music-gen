import XCTest
@testable import LocalMusicGen

/// The library's text fields commit late — a macOS field commits on focus loss
/// and notes save on a timer — so a write can arrive after the selection has
/// already moved to the next row. The bug being pinned here: a rename typed
/// for one track landing on the track underneath it.
@MainActor
final class SongEditorTests: XCTestCase {
    private func makeStore() throws -> LibraryStore {
        LibraryStore(repo: LibraryRepository(db: try DatabaseManager.inMemory()))
    }

    private func song(_ id: String, title: String) -> SongRecord {
        SongRecord(id: id, title: title, prompt: "", lyrics: nil,
                   modelId: "m", modelName: "M", groupId: nil, paramsJSON: "{}",
                   durationS: 10, sampleRate: 44100, fileName: "\(id).wav",
                   seedUsed: nil, createdAt: Date(), rating: 0, notes: "",
                   favorite: false, origin: "generated")
    }

    private func loaded() throws -> (LibraryStore, SongEditor) {
        let store = try makeStore()
        store.insert(song("a", title: "First"))
        store.insert(song("b", title: "Second"))
        let editor = SongEditor()
        editor.load(store.song(id: "a")!, in: store)
        return (store, editor)
    }

    func testRenameOfTheSelectedTrack() throws {
        let (store, editor) = try loaded()
        editor.title = "  Renamed  "
        editor.commitTitle(in: store)
        XCTAssertEqual(store.song(id: "a")?.title, "Renamed", "trimmed")
        XCTAssertEqual(store.song(id: "b")?.title, "Second")
    }

    /// The reported bug: the field committed against whatever the pane showed
    /// at commit time, so the new name landed on the next track down.
    func testLateCommitRenamesTheTrackTheNameWasTypedFor() throws {
        let (store, editor) = try loaded()
        editor.title = "Renamed"
        editor.load(store.song(id: "b")!, in: store)   // selection moves first
        editor.commitTitle(in: store)                  // …field commits after
        XCTAssertEqual(store.song(id: "a")?.title, "Renamed")
        XCTAssertEqual(store.song(id: "b")?.title, "Second",
                       "the neighbour must keep its own name")
        XCTAssertEqual(editor.title, "Second", "field shows the new selection")
    }

    func testBlankRenameIsRefused() throws {
        let (store, editor) = try loaded()
        editor.title = "   "
        editor.commitTitle(in: store)
        XCTAssertEqual(store.song(id: "a")?.title, "First")
        XCTAssertEqual(editor.title, "First", "field falls back to the stored name")
    }

    func testTagsFollowTheTrackTheyWereTypedFor() throws {
        let (store, editor) = try loaded()
        editor.tagsText = "chill, demo"
        editor.load(store.song(id: "b")!, in: store)
        editor.commitTags(in: store)
        XCTAssertEqual(store.tags(for: "a"), ["chill", "demo"])
        XCTAssertEqual(store.tags(for: "b"), [])
    }

    /// Switching tracks flushes the pending notes save rather than cancelling
    /// it — the debounce timer would otherwise be reset by the new selection.
    func testNotesFollowTheTrackTheyWereTypedFor() throws {
        let (store, editor) = try loaded()
        editor.notes = "glorious trumpet solo"
        editor.notesEdited(in: store)
        editor.load(store.song(id: "b")!, in: store)
        XCTAssertEqual(store.song(id: "a")?.notes, "glorious trumpet solo")
        XCTAssertEqual(store.song(id: "b")?.notes, "")
    }

    /// Fields write to the row as it stands, so a late commit can't revert a
    /// rating set after the text was typed.
    func testCommitKeepsEditsMadeElsewhere() throws {
        let (store, editor) = try loaded()
        editor.title = "Renamed"
        var rated = store.song(id: "a")!
        rated.rating = 4
        store.update(rated)
        editor.commitTitle(in: store)
        XCTAssertEqual(store.song(id: "a")?.title, "Renamed")
        XCTAssertEqual(store.song(id: "a")?.rating, 4)
    }
}

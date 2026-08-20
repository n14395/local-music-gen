import Foundation
import Observation

/// Edit buffer behind the detail pane's text fields.
///
/// A macOS text field commits on Return *and* when it loses focus, and notes
/// save on a timer — so a write can land after the list selection has already
/// moved to another track. Writing to "the song the pane is showing now" put
/// the typed name on the neighbouring row; every write here targets `songId`,
/// the track the text was actually typed for, and switching tracks flushes
/// what is still pending before the fields are refilled.
///
/// Writes re-read the stored row rather than saving back a snapshot, so an
/// edit to one field can't revert a rating or heart set in the meantime.
@MainActor @Observable
final class SongEditor {
    /// The song the buffered text belongs to; empty before the first load.
    private(set) var songId = ""
    var title = ""
    var notes = ""
    var tagsText = ""

    private var notesSaveTask: Task<Void, Never>?

    /// Fill the fields from `song`, flushing edits left pending on the track
    /// being navigated away from.
    func load(_ song: SongRecord, in library: LibraryStore) {
        if songId != song.id { flush(in: library) }
        songId = song.id
        title = song.title
        notes = song.notes
        tagsText = library.tags(for: song.id).joined(separator: ", ")
    }

    /// Write everything still buffered, for the song it was typed for.
    func flush(in library: LibraryStore) {
        commitTitle(in: library)
        commitTags(in: library)
        flushNotes(in: library)
    }

    /// Store the buffered title. A blank name is refused — the field falls back
    /// to the stored one.
    func commitTitle(in library: LibraryStore) {
        guard var stored = library.song(id: songId) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { title = stored.title; return }
        guard trimmed != stored.title else { return }
        stored.title = trimmed
        library.update(stored)
    }

    func commitTags(in library: LibraryStore) {
        guard !songId.isEmpty else { return }
        let typed = tagsText.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard Set(typed) != Set(library.tags(for: songId)) else { return }
        library.setTags(typed, for: songId)
    }

    /// Notes have no commit gesture, so they save a second after typing stops —
    /// with the target id captured alongside the text.
    func notesEdited(in library: LibraryStore) {
        notesSaveTask?.cancel()
        let value = notes
        let target = songId
        notesSaveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { return }
            Self.writeNotes(value, songId: target, in: library)
        }
    }

    private func flushNotes(in library: LibraryStore) {
        notesSaveTask?.cancel()
        notesSaveTask = nil
        Self.writeNotes(notes, songId: songId, in: library)
    }

    private static func writeNotes(_ value: String, songId: String,
                                   in library: LibraryStore) {
        guard var stored = library.song(id: songId), stored.notes != value else {
            return
        }
        stored.notes = value
        library.update(stored)
    }
}

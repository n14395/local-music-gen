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
    /// Why the last rename was refused, cleared as soon as one succeeds or the
    /// pane moves to another track. The field reverts on refusal, so without
    /// this the name would simply spring back with no explanation.
    private(set) var titleError: String?

    private var notesSaveTask: Task<Void, Never>?

    /// Fill the fields from `song`, flushing edits left pending on the track
    /// being navigated away from.
    func load(_ song: SongRecord, in library: LibraryStore) {
        if songId != song.id { flush(in: library) }
        songId = song.id
        title = song.title
        titleError = nil
        notes = song.notes
        tagsText = library.tags(for: song.id).joined(separator: ", ")
    }

    /// Write everything still buffered, for the song it was typed for.
    func flush(in library: LibraryStore) {
        commitTitle(in: library)
        commitTags(in: library)
        flushNotes(in: library)
    }

    /// Store the buffered title. Two names are refused, both by putting the
    /// stored one back in the field: a blank one, and one another song already
    /// has.
    ///
    /// The duplicate rule is not house-keeping. A part names its source by
    /// title — the Parts list groups under it and the inspector's "From" row
    /// prints it — so two tracks sharing a name makes those readouts point at
    /// nothing in particular, and the parts of one look like the parts of the
    /// other.
    func commitTitle(in library: LibraryStore) {
        guard var stored = library.song(id: songId) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            title = stored.title
            titleError = nil
            return
        }
        guard trimmed != stored.title else { titleError = nil; return }
        if library.titleIsTaken(trimmed, excluding: songId) {
            title = stored.title
            titleError = "Another track is already called \u{201C}\(trimmed)\u{201D}."
            return
        }
        titleError = nil
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

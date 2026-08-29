import Foundation
import Observation

/// The parts library: split products (stems / notes / features) across songs.
@MainActor @Observable
final class PartsStore {
    private let repo: PartsRepository
    private(set) var results: [PartRecord] = []
    /// Analysis attachments for the current results, keyed by part id.
    private(set) var analyses: [String: AnalysisRecord] = [:]
    /// The ids `analyses` was bulk-read for.
    ///
    /// What makes a miss in that dictionary mean something. The read covers
    /// every row in `results`, so for an id in this set an absent entry is the
    /// whole answer, and the single-row query in `analysis(for:)` can do
    /// nothing but confirm it — which it was doing on every body pass of every
    /// view showing a part with no analysis, forever. Held as a set rather
    /// than as nil entries in `analyses` because it is rebuilt with the
    /// dictionary, so a measurement that lands later still arrives with the
    /// publish that carries it.
    private var analysedIds: Set<String> = []
    /// How many parts are hearted — the sidebar's "Favourites" count, which
    /// spans both tables and so cannot be read off `results`. Cached for the
    /// reason `LibraryStore.editedCount` is: the sidebar was running the
    /// query from inside its body.
    private(set) var favouriteCount = 0
    var filters = PartsRepository.Filters() {
        didSet { filtersChanged(from: oldValue) }
    }
    var lastError: String?

    private var searchTask: Task<Void, Never>?
    /// The coalesced ingest-driven read — see `refreshSoon`.
    private var refreshTask: Task<Void, Never>?

    /// As `LibraryStore.filtersChanged(from:)`, and for the same reason: a
    /// chip is a click and lands at once, the search text is a keystroke and
    /// settles first. Worse here than there, historically — this refresh was
    /// N+1 queries deep, so a typed word cost five round trips per part in
    /// the list.
    private func filtersChanged(from oldValue: PartsRepository.Filters) {
        guard filters != oldValue else { return }
        var exceptQuery = filters
        exceptQuery.query = oldValue.query
        if exceptQuery == oldValue {
            scheduleRefresh()
        } else {
            searchTask?.cancel()
            searchTask = nil
            refresh()
        }
    }

    private func scheduleRefresh() {
        searchTask?.cancel()
        let wanted = filters
        let repo = self.repo
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: LibraryStore.searchDebounce)
            guard !Task.isCancelled else { return }
            let answer = await Task.detached(priority: .userInitiated) {
                Self.read(filters: wanted, from: repo)
            }.value
            guard !Task.isCancelled, let self, self.filters == wanted else {
                return
            }
            self.publish(answer)
        }
    }

    /// The list and its analyses, in two queries rather than one per row.
    ///
    /// `nonisolated` so the debounced path can run it off this actor; the
    /// repository is a `Sendable` value over a serial database queue, so
    /// there is nothing here that wanted the main thread in the first place.
    nonisolated private static func read(filters: PartsRepository.Filters,
                                         from repo: PartsRepository)
        -> (parts: [PartRecord], analyses: [String: AnalysisRecord],
            favourites: Int) {
        let parts = (try? repo.parts(filters)) ?? []
        let analyses = (try? repo.analyses(ownerIds: parts.map(\.id))) ?? [:]
        let favourites = (try? repo.favoriteCount()) ?? 0
        return (parts, analyses, favourites)
    }

    /// Whether deletions send the user's files to the Trash — see
    /// `LibraryStore.usesTrash`.
    var usesTrash: @MainActor () -> Bool = { true }

    init(repo: PartsRepository) {
        self.repo = repo
        // Off the actor, as in `LibraryStore.init` and for the same reason:
        // every part plus an analysis lookup for each of them, before the
        // first frame exists.
        refreshSoon()
    }

    var repository: PartsRepository { repo }

    func refresh() {
        searchTask?.cancel()
        searchTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        publish(Self.read(filters: filters, from: repo))
    }

    /// Re-read because rows changed underneath us — the counterpart to
    /// `LibraryStore.refreshRecentSoon`, and for the same reason.
    ///
    /// `refresh()` is synchronous and unbounded: every part, every analysis
    /// attachment for them, and the favourites count. It runs on init, on
    /// every star, rating, rename, delete and update, and on every parts
    /// ingest — so a split landing six stems used to pay for the whole list
    /// six times over on the main actor. Ingest paths use this instead;
    /// clicks keep the synchronous one, which should land on the row before
    /// the click finishes.
    func refreshSoon() {
        searchTask?.cancel()
        searchTask = nil
        refreshTask?.cancel()
        let wanted = filters
        let repo = self.repo
        refreshTask = Task { [weak self] in
            let answer = await Task.detached(priority: .userInitiated) {
                Self.read(filters: wanted, from: repo)
            }.value
            guard !Task.isCancelled, let self, self.filters == wanted else {
                return
            }
            self.publish(answer)
        }
    }

    private func publish(_ answer: (parts: [PartRecord],
                                    analyses: [String: AnalysisRecord],
                                    favourites: Int)) {
        results = answer.parts
        analyses = answer.analyses
        analysedIds = Set(answer.parts.map(\.id))
        if favouriteCount != answer.favourites {
            favouriteCount = answer.favourites
        }
    }

    /// As `LibraryStore.noteEdits` — keep the cached rows in step with the
    /// Editor's narrow column write.
    func noteEdits(id: String, editsJSON: String?) {
        for index in results.indices where results[index].id == id {
            results[index].editsJSON = editsJSON
        }
    }

    /// Rename a part, or say why not.
    ///
    /// Returns the message the field should show, and nil when there is
    /// nothing to say. A blank name is dropped without comment — it reads as
    /// "I have changed my mind", not as a request — and a taken one is
    /// refused, which is the choice `SongEditor.commitTitle` makes for a
    /// track's title and for the same reason: the user is looking at the field
    /// and can pick again.
    /// Takes an id and re-reads the stored row rather than taking a record,
    /// because the pane that calls it may have moved on to another part
    /// between the keystroke and the commit — see `PartInspector`.
    func rename(id: String, to name: String) -> String? {
        guard let part = (try? repo.part(id: id)) ?? nil else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != part.name else { return nil }
        if (try? repo.nameIsTaken(trimmed, excluding: part.id)) ?? false {
            return "Another part is already called \u{201C}\(trimmed)\u{201D}."
        }
        do {
            try repo.setName(id: part.id, to: trimmed)
        } catch {
            return "Could not rename: \(error.localizedDescription)"
        }
        // Patched in place rather than re-queried, as `noteEdits` does: the
        // row's position in the list has not changed, and a refresh here would
        // re-read every analysis attachment to move one string.
        for index in results.indices where results[index].id == part.id {
            results[index].name = trimmed
        }
        return nil
    }

    /// The analysis for a part, or for anything else the caller keys on it.
    ///
    /// Only ids the bulk read never covered — a song's, or a part outside the
    /// current filters — are worth a query; see `analysedIds`.
    func analysis(for partId: String) -> AnalysisRecord? {
        if let known = analyses[partId] { return known }
        guard !analysedIds.contains(partId) else { return nil }
        return (try? repo.analysis(ownerId: partId)) ?? nil
    }

    /// Heart / unheart a part. The Library's Favourites scope reads both this
    /// and the song flag, so a stem you liked sits beside the tracks you liked.
    func setFavorite(_ part: PartRecord, to favorite: Bool) {
        var updated = part
        updated.favorite = favorite
        do {
            try repo.update(updated)
        } catch {
            lastError = "Could not update part: \(error.localizedDescription)"
        }
        refresh()
    }

    /// Rate a part 0–5. Mirrors `setFavorite` exactly, because from the
    /// list's point of view they are the same gesture on the same row.
    func setRating(_ part: PartRecord, to rating: Int) {
        var updated = part
        updated.rating = max(0, min(5, rating))
        do {
            try repo.update(updated)
        } catch {
            lastError = "Could not rate part: \(error.localizedDescription)"
        }
        refresh()
    }

    func favorites() -> [PartRecord] {
        (try? repo.favorites()) ?? []
    }

    func delete(_ part: PartRecord) {
        deleteWithoutRefresh(part, index: StoragePaths.backupIndex())
        refresh()
    }

    /// Delete several, republishing once — see `LibraryStore.delete(_:)` for
    /// why one refresh rather than one per row.
    func delete(_ parts: [PartRecord]) {
        guard !parts.isEmpty else { return }
        // Listed once for the whole batch — see `removeEditorLeftovers`.
        let index = StoragePaths.backupIndex()
        for part in parts { deleteWithoutRefresh(part, index: index) }
        refresh()
    }

    private func deleteWithoutRefresh(_ part: PartRecord,
                                      index: [String: [URL]]) {
        let toTrash = usesTrash()
        FileDisposal.dispose(part.fileURL, toTrash: toTrash)
        if let preview = part.previewURL {
            try? FileManager.default.removeItem(at: preview)
        }
        try? FileManager.default.removeItem(at: part.waveformURL)
        LibraryStore.removeEditorLeftovers(id: part.id, toTrash: toTrash,
                                           index: index)
        do {
            try repo.delete(id: part.id)
        } catch {
            lastError = "Could not delete part: \(error.localizedDescription)"
        }
    }

    func update(_ parts: [PartRecord]) {
        guard !parts.isEmpty else { return }
        for part in parts { try? repo.update(part) }
        refresh()
    }

    /// Export the payload (MIDI parts export the .mid, audio parts the audio).
    func export(_ part: PartRecord, to destination: URL) {
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: part.fileURL, to: destination)
        } catch {
            lastError = "Export failed: \(error.localizedDescription)"
        }
    }
}

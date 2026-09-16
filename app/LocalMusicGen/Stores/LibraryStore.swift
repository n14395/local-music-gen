import Foundation
import Observation

@MainActor @Observable
final class LibraryStore {
    private let repo: LibraryRepository
    /// Present when the parts library exists (nil in some legacy tests).
    var partsRepo: PartsRepository?
    private(set) var recent: [SongRecord] = []
    private(set) var results: [SongRecord] = []
    private(set) var allTags: [String] = []
    /// How many tracks carry an applied edit — the sidebar's "Edited" count.
    ///
    /// Cached here because the sidebar drew it by calling
    /// `repository.editedCount()` from inside its own body, which is a
    /// synchronous `SELECT COUNT(*)` on every render pass of the window's
    /// navigation column. Unfiltered on purpose: it counts the scope, not the
    /// list currently on screen.
    private(set) var editedCount = 0
    var filters = LibraryRepository.Filters() {
        didSet { filtersChanged(from: oldValue) }
    }
    var lastError: String?

    /// How long the search text settles for before the database is asked.
    /// Long enough that a typed word is one query rather than five, short
    /// enough that stopping typing and reading the list feels immediate.
    static let searchDebounce = Duration.milliseconds(140)

    private var searchTask: Task<Void, Never>?
    /// The coalesced ingest-driven read — see `refreshRecentSoon`.
    private var recentTask: Task<Void, Never>?

    /// A filter moved. Which one decides whether the database is asked now or
    /// in a moment.
    ///
    /// Everything except the search text is a click — a chip, a sort, a scope
    /// — and a click should land at once, so those still run the query inline.
    /// `query` is bound to a text field, and running it inline meant one FTS5
    /// MATCH, one FTS join over the text documents and an `allTags()` between
    /// one keystroke and the next, all synchronously on the actor drawing the
    /// results. That one is debounced, and the query itself runs off this
    /// actor.
    private func filtersChanged(from oldValue: LibraryRepository.Filters) {
        guard filters != oldValue else { return }
        var exceptQuery = filters
        exceptQuery.query = oldValue.query
        if exceptQuery == oldValue {
            scheduleSearch()
        } else {
            searchTask?.cancel()
            searchTask = nil
            refreshSearch()
        }
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let wanted = filters
        let repo = self.repo
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: Self.searchDebounce)
            guard !Task.isCancelled else { return }
            let answer = await Task.detached(priority: .userInitiated) {
                (results: (try? repo.search(wanted)) ?? [],
                 tags: (try? repo.allTags()) ?? [],
                 edited: (try? repo.editedCount()) ?? 0)
            }.value
            guard !Task.isCancelled, let self else { return }
            // The filters may have moved on while this was in the database —
            // only the newest question's answer may be published, or a slow
            // query would overwrite a faster one that came after it.
            guard self.filters == wanted else { return }
            self.results = answer.results
            self.allTags = answer.tags
            if self.editedCount != answer.edited {
                self.editedCount = answer.edited
            }
        }
    }

    init(repo: LibraryRepository, partsRepo: PartsRepository? = nil) {
        self.repo = repo
        self.partsRepo = partsRepo
        // Seeded off the actor. This runs inside `AppEnvironment.init`, which
        // is built as a property of the app delegate — so before there is a
        // window, let alone a frame — and the read behind it is five unbounded
        // queries that grow with the library. The screens all draw from
        // observable state and fill in when it lands, which is the same thing
        // they do when a take arrives.
        refreshRecentSoon()
    }

    var onSongsImported: ([SongRecord]) -> Void = { _ in }

    /// Whether deletions send the user's files to the Trash. A closure into
    /// Settings rather than a copied flag, so flipping the toggle applies to
    /// the very next delete.
    var usesTrash: @MainActor () -> Bool = { true }

    /// Import external audio files as library songs (origin "imported").
    @discardableResult
    func importSongs(urls: [URL]) async -> [SongRecord] {
        var imported: [SongRecord] = []
        // Names allocated earlier in this batch are not in the database yet —
        // the same bookkeeping `JobsStore.landTake` keeps across a batch of
        // takes. Importing one file twice, or two files whose tags agree, used
        // to put two rows under one title, which is exactly what the rename
        // path refuses and what part naming assumes cannot happen.
        var reserved: Set<String> = []
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let songId = UUID().uuidString.lowercased()
            do {
                let file = try await AudioImporter.shared.importFile(
                    at: url, songId: songId, into: StoragePaths.libraryAudio)
                // The file's own title wins over its filename: "Midnight Drive"
                // reads, "03 midnight_drive_final_v3" does not.
                let wanted = file.title
                    ?? url.deletingPathExtension().lastPathComponent
                let title = uniqueTitle(wanted, reserved: reserved)
                reserved.insert(title)
                let song = SongRecord(
                    id: songId,
                    title: title,
                    prompt: "", lyrics: nil, modelId: "imported",
                    modelName: "Imported", groupId: nil, paramsJSON: "{}",
                    durationS: file.durationS, sampleRate: file.sampleRate,
                    fileName: file.fileName, seedUsed: nil, createdAt: Date(),
                    rating: 0, notes: "", favorite: false,
                    origin: SongOrigin.imported.rawValue, artist: file.artist)
                try repo.insert(song)
                imported.append(song)
            } catch {
                lastError = "Could not import \(url.lastPathComponent): "
                    + error.localizedDescription
            }
        }
        refreshRecent()
        onSongsImported(imported)
        return imported
    }

    var repository: LibraryRepository { repo }

    /// The `trackNNN` a submission made right now would be named — what the
    /// Studio's Name field offers by default. Kept here rather than read on
    /// demand so the field moves on by itself as tracks land, without the
    /// composer polling the database on every keystroke.
    private(set) var nextTrackName = SongRecord.trackName(number: 1)

    func refreshRecent() {
        searchTask?.cancel()
        searchTask = nil
        recentTask?.cancel()
        recentTask = nil
        publish(Self.readEverything(repo: repo, filters: filters))
    }

    /// Re-read the library because rows changed underneath us, without
    /// blocking whatever is on screen.
    ///
    /// The synchronous sibling above runs five unbounded queries — `recent`,
    /// the highest track number, the FTS search behind `results`, `allTags`
    /// and the edited count — and it is called once per take as a render
    /// lands. On the main actor. While the next take is rendering. That is
    /// the hitch you feel exactly when takes arrive, and it is why this
    /// exists: the reads happen off the actor, and takes landing close
    /// together collapse into one of them, because each request cancels the
    /// last before it reaches the database.
    ///
    /// User actions keep using `refreshRecent` — a delete or a rename should
    /// land on the row before the click finishes, and there is no burst of
    /// them to coalesce.
    func refreshRecentSoon() {
        searchTask?.cancel()
        searchTask = nil
        recentTask?.cancel()
        let wanted = filters
        let repo = self.repo
        recentTask = Task { [weak self] in
            let answer = await Task.detached(priority: .userInitiated) {
                Self.readEverything(repo: repo, filters: wanted)
            }.value
            guard !Task.isCancelled, let self else { return }
            // Same rule as `scheduleSearch`: a slow answer must not overwrite
            // a fresher one that was asked for after it.
            guard self.filters == wanted else { return }
            self.publish(answer)
        }
    }

    /// One `Snapshot` is everything the two refresh paths publish, so they
    /// cannot drift apart — and reading it is `nonisolated`, so it is the
    /// same code whether it runs here or on a background executor.
    struct Snapshot {
        var recent: [SongRecord] = []
        var highestTrackNumber = 0
        var results: [SongRecord] = []
        var tags: [String] = []
        var edited = 0
    }

    nonisolated static func readEverything(
        repo: LibraryRepository,
        filters: LibraryRepository.Filters) -> Snapshot {
        Snapshot(recent: (try? repo.recent()) ?? [],
                 highestTrackNumber: (try? repo.highestTrackNumber()) ?? 0,
                 results: (try? repo.search(filters)) ?? [],
                 tags: (try? repo.allTags()) ?? [],
                 edited: (try? repo.editedCount()) ?? 0)
    }

    private func publish(_ snapshot: Snapshot) {
        recent = snapshot.recent
        let name = SongRecord.trackName(number: snapshot.highestTrackNumber + 1)
        if name != nextTrackName { nextTrackName = name }
        results = snapshot.results
        allTags = snapshot.tags
        if editedCount != snapshot.edited { editedCount = snapshot.edited }
    }

    func refreshSearch() {
        searchTask?.cancel()
        searchTask = nil
        results = (try? repo.search(filters)) ?? []
        allTags = (try? repo.allTags()) ?? []
        let edited = (try? repo.editedCount()) ?? 0
        if editedCount != edited { editedCount = edited }
    }

    /// Re-read one song. Editors target an id rather than the snapshot they
    /// were handed, so they need the current row to write back.
    func song(id: String) -> SongRecord? { try? repo.song(id: id) }

    /// What an ingredient's source track is called *now*.
    ///
    /// `songIngredient.sourceSongTitle` is a copy taken at the moment the mix
    /// was rendered. It exists so a row still reads sensibly after its source
    /// has been deleted — it is a tombstone, not the current name — so a mix
    /// went on naming a track by whatever it was called on the day it was
    /// built. Resolve it live while the source is still there, and fall back
    /// to the stored copy only when it is not.
    ///
    /// The id may be a part or a whole song: `JobsStore.resolveIngredient`
    /// accepts either, so this looks for both, in the same order.
    func sourceTitle(for ingredient: SongIngredientRecord) -> String {
        guard let sourceId = ingredient.partId else {
            return ingredient.sourceSongTitle
        }
        if let part = try? partsRepo?.part(id: sourceId) ?? nil,
           let song = try? repo.song(id: part.songId) {
            return song.title
        }
        if let song = try? repo.song(id: sourceId) { return song.title }
        return ingredient.sourceSongTitle
    }

    /// Whether another song already has this name. Renames are refused on it —
    /// see `SongEditor.commitTitle`.
    func titleIsTaken(_ title: String, excluding songId: String) -> Bool {
        (try? repo.titleIsTaken(title, excluding: songId)) ?? false
    }

    /// `title` made free of collisions — see `LibraryRepository.uniqueTitle`.
    func uniqueTitle(_ title: String, reserved: Set<String> = []) -> String {
        (try? repo.uniqueTitle(title, reserved: reserved)) ?? title
    }

    func tags(for songId: String) -> [String] {
        (try? repo.tags(for: songId)) ?? []
    }

    func setTags(_ tags: [String], for songId: String) {
        try? repo.setTags(tags, for: songId)
        refreshSearch()
    }

    /// Record an Editor program against the cached rows without re-querying.
    ///
    /// The Editor writes `editsJSON` through a narrow column update, so the
    /// snapshots in `recent`/`results` would otherwise still hold the value
    /// from before the edit — and every other writer in the app builds its
    /// whole-row `update(_:)` from those snapshots, which would put the
    /// stale program back.
    func noteEdits(id: String, editsJSON: String?) {
        for index in recent.indices where recent[index].id == id {
            recent[index].editsJSON = editsJSON
        }
        for index in results.indices where results[index].id == id {
            results[index].editsJSON = editsJSON
        }
    }

    func insert(_ song: SongRecord) {
        try? repo.insert(song)
        refreshRecent()
    }

    func update(_ song: SongRecord) {
        try? repo.update(song)
        refreshRecent()
    }

    /// Announced when a song's rename moved its parts' names with it, so the
    /// parts store can republish. A callback rather than a return value
    /// because the two caches belong to different stores.
    var onPartsRenamed: () -> Void = {}

    /// Carry a track's rename onto the parts cut from it.
    ///
    /// Parts are named after their source — `vocals-track042` — while the meta
    /// line beside them resolves that source live, so leaving the names behind
    /// would put two different names for one song in one row. Parts the user
    /// has renamed themselves are left alone; `PartsRepository.renameDefaults`
    /// draws that line.
    func renameParts(ofSong songId: String, from old: String, to new: String) {
        guard let partsRepo else { return }
        let moved = (try? partsRepo.renameDefaults(ofSong: songId,
                                                   from: old, to: new)) ?? 0
        if moved > 0 { onPartsRenamed() }
    }

    /// The Editor's own files for a track: the stashed original and the
    /// peak cache drawn from it. Matched on the id prefix rather than a
    /// recomputed name — an applied track's file has been renamed, and the
    /// backup that outlives it must still be found.
    /// The backup is the pre-edit original — user content, so it follows the
    /// same Trash policy as the file it backs; the peak cache is derived and
    /// always goes outright.
    ///
    /// `index`, when given, is a `StoragePaths.backupIndex()` the caller has
    /// already built — a batch delete builds one and reuses it rather than
    /// listing the backups folder once per row.
    static func removeEditorLeftovers(id: String, toTrash: Bool = false,
                                      index: [String: [URL]]? = nil) {
        let backups = index.map { $0[id] ?? [] }
            ?? StoragePaths.backups(forId: id)
        for backup in backups {
            FileDisposal.dispose(backup, toTrash: toTrash)
        }
        try? FileManager.default.removeItem(
            at: StoragePaths.libraryWaveforms
                .appendingPathComponent(id + ".original.peaks"))
    }

    func delete(_ song: SongRecord) {
        deleteWithoutRefresh(song, index: StoragePaths.backupIndex())
        refreshRecent()
    }

    /// Delete several, republishing once.
    ///
    /// `delete(_:)` refreshes on its way out, which is right for one row and
    /// wrong for twenty: the list would be rebuilt from the database twenty
    /// times while the user watched it shrink a row at a time.
    func delete(_ songs: [SongRecord]) {
        guard !songs.isEmpty else { return }
        // Listed once for the whole batch — see `removeEditorLeftovers`.
        let index = StoragePaths.backupIndex()
        for song in songs { deleteWithoutRefresh(song, index: index) }
        refreshRecent()
    }

    private func deleteWithoutRefresh(_ song: SongRecord,
                                      index: [String: [URL]]) {
        let toTrash = usesTrash()
        // Parts are derivatives: their rows cascade with the song row, so the
        // files must go first.
        if let partsRepo {
            for part in (try? partsRepo.allParts(forSong: song.id)) ?? [] {
                FileDisposal.dispose(part.fileURL, toTrash: toTrash)
                if let preview = part.previewURL {
                    try? FileManager.default.removeItem(at: preview)
                }
                try? FileManager.default.removeItem(at: part.waveformURL)
                LibraryStore.removeEditorLeftovers(id: part.id,
                                                   toTrash: toTrash,
                                                   index: index)
                try? partsRepo.deleteAnalysis(ownerId: part.id)
                try? partsRepo.deleteTextDocs(ownerId: part.id)
            }
            try? partsRepo.deleteAnalysis(ownerId: song.id)
            try? partsRepo.deleteTextDocs(ownerId: song.id)
        }
        FileDisposal.dispose(song.fileURL, toTrash: toTrash)
        try? FileManager.default.removeItem(at: song.waveformURL)
        LibraryStore.removeEditorLeftovers(id: song.id, toTrash: toTrash,
                                           index: index)
        try? repo.delete(id: song.id)
    }

    /// Write several rows, republishing once — the same reason as above.
    func update(_ songs: [SongRecord]) {
        guard !songs.isEmpty else { return }
        for song in songs { try? repo.update(song) }
        refreshRecent()
    }
}

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
    var filters = LibraryRepository.Filters() {
        didSet { refreshSearch() }
    }
    var lastError: String?

    init(repo: LibraryRepository, partsRepo: PartsRepository? = nil) {
        self.repo = repo
        self.partsRepo = partsRepo
        refreshRecent()
    }

    var onSongsImported: ([SongRecord]) -> Void = { _ in }

    /// Import external audio files as library songs (origin "imported").
    @discardableResult
    func importSongs(urls: [URL]) async -> [SongRecord] {
        var imported: [SongRecord] = []
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let songId = UUID().uuidString.lowercased()
            do {
                let file = try await AudioImporter.shared.importFile(
                    at: url, songId: songId, into: StoragePaths.libraryAudio)
                // The file's own title wins over its filename: "Midnight Drive"
                // reads, "03 midnight_drive_final_v3" does not.
                let song = SongRecord(
                    id: songId,
                    title: file.title
                        ?? url.deletingPathExtension().lastPathComponent,
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
        recent = (try? repo.recent()) ?? []
        nextTrackName = SongRecord.trackName(
            number: ((try? repo.highestTrackNumber()) ?? 0) + 1)
        refreshSearch()
    }

    func refreshSearch() {
        results = (try? repo.search(filters)) ?? []
        allTags = (try? repo.allTags()) ?? []
    }

    /// Re-read one song. Editors target an id rather than the snapshot they
    /// were handed, so they need the current row to write back.
    func song(id: String) -> SongRecord? { try? repo.song(id: id) }

    /// Whether another song already has this name. Renames are refused on it —
    /// see `SongEditor.commitTitle`.
    func titleIsTaken(_ title: String, excluding songId: String) -> Bool {
        (try? repo.titleIsTaken(title, excluding: songId)) ?? false
    }

    func tags(for songId: String) -> [String] {
        (try? repo.tags(for: songId)) ?? []
    }

    func setTags(_ tags: [String], for songId: String) {
        try? repo.setTags(tags, for: songId)
        refreshSearch()
    }

    func insert(_ song: SongRecord) {
        try? repo.insert(song)
        refreshRecent()
    }

    func update(_ song: SongRecord) {
        try? repo.update(song)
        refreshRecent()
    }

    func delete(_ song: SongRecord) {
        // Parts are derivatives: their rows cascade with the song row, so the
        // files must go first.
        if let partsRepo {
            for part in (try? partsRepo.allParts(forSong: song.id)) ?? [] {
                try? FileManager.default.removeItem(at: part.fileURL)
                if let preview = part.previewURL {
                    try? FileManager.default.removeItem(at: preview)
                }
                try? FileManager.default.removeItem(at: part.waveformURL)
                try? partsRepo.deleteAnalysis(ownerId: part.id)
            }
            try? partsRepo.deleteAnalysis(ownerId: song.id)
        }
        try? FileManager.default.removeItem(at: song.fileURL)
        try? FileManager.default.removeItem(at: song.waveformURL)
        try? repo.delete(id: song.id)
        refreshRecent()
    }
}

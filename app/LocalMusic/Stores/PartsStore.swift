import Foundation
import Observation

/// The parts library: split products (stems / notes / features) across songs.
@MainActor @Observable
final class PartsStore {
    private let repo: PartsRepository
    private(set) var results: [PartRecord] = []
    /// Analysis attachments for the current results, keyed by part id.
    private(set) var analyses: [String: AnalysisRecord] = [:]
    var filters = PartsRepository.Filters() {
        didSet { refresh() }
    }
    var lastError: String?

    init(repo: PartsRepository) {
        self.repo = repo
        refresh()
    }

    var repository: PartsRepository { repo }

    func refresh() {
        results = (try? repo.parts(filters)) ?? []
        var map: [String: AnalysisRecord] = [:]
        for part in results {
            if let record = try? repo.analysis(ownerId: part.id) {
                map[part.id] = record
            }
        }
        analyses = map
    }

    /// As `LibraryStore.noteEdits` — keep the cached rows in step with the
    /// Editor's narrow column write.
    func noteEdits(id: String, editsJSON: String?) {
        for index in results.indices where results[index].id == id {
            results[index].editsJSON = editsJSON
        }
    }

    func analysis(for partId: String) -> AnalysisRecord? {
        analyses[partId] ?? (try? repo.analysis(ownerId: partId)) ?? nil
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

    func favorites() -> [PartRecord] {
        (try? repo.favorites()) ?? []
    }

    func delete(_ part: PartRecord) {
        try? FileManager.default.removeItem(at: part.fileURL)
        if let preview = part.previewURL {
            try? FileManager.default.removeItem(at: preview)
        }
        try? FileManager.default.removeItem(at: part.waveformURL)
        LibraryStore.removeEditorLeftovers(id: part.id)
        do {
            try repo.delete(id: part.id)
        } catch {
            lastError = "Could not delete part: \(error.localizedDescription)"
        }
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

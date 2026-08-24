import Foundation
import Observation

/// The text documents attached to songs and parts — descriptions, transcribed
/// lyrics, Q&A answers, tags, notation — cached by owner the way `PartsStore`
/// caches analyses, so every pane that shows a slot reads one dictionary
/// instead of running its own query.
///
/// The mirror is whole and eager: `refresh()` re-reads the entire table, and
/// every mutation writes through and refreshes. A handful of rows per song
/// never justifies incremental cache surgery, and a read path that lazily
/// filled the cache would be a view-body mutation waiting to be reported.
@MainActor @Observable
final class TextStore {
    private let repo: PartsRepository
    /// Every text document, keyed by owner id, newest first per kind.
    private(set) var docs: [String: [TextDocRecord]] = [:]
    var lastError: String?

    init(repo: PartsRepository) {
        self.repo = repo
        refresh()
    }

    var repository: PartsRepository { repo }

    func refresh() {
        let rows = (try? repo.allTextDocs()) ?? []
        docs = Dictionary(grouping: rows, by: \.ownerId)
    }

    /// Docs for one owner, optionally narrowed to a kind.
    func docs(for ownerId: String, kind: TextDocKind? = nil) -> [TextDocRecord] {
        let all = docs[ownerId] ?? []
        guard let kind else { return all }
        return all.filter { $0.kindValue == kind }
    }

    /// Whether this owner already carries a document of this kind — the
    /// auto-run idempotence question, answered off the cache.
    func hasDoc(ownerId: String, kind: TextDocKind) -> Bool {
        !docs(for: ownerId, kind: kind).isEmpty
    }

    func insert(_ record: TextDocRecord) {
        do {
            try repo.insertTextDoc(record)
            refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func save(_ record: TextDocRecord) {
        do {
            try repo.updateTextDoc(record)
            refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func delete(_ record: TextDocRecord) {
        do {
            try repo.deleteTextDoc(id: record.id)
            refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Ingest landed documents (JobsStore's `onTextIngested` hands them
    /// here): the rows are already written, so only the mirror moves.
    func noteIngested(_ records: [TextDocRecord]) {
        guard !records.isEmpty else { return }
        refresh()
    }
}

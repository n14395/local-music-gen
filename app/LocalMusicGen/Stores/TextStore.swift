// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Observation

/// The text documents attached to songs and parts — descriptions, transcribed
/// lyrics, Q&A answers, tags, notation — cached by owner the way `PartsStore`
/// caches analyses, so every pane that shows a slot reads one dictionary
/// instead of running its own query.
///
/// The mirror is whole: `refresh()` re-reads the entire table, and every
/// mutation writes through and refreshes. A handful of rows per song never
/// justifies incremental cache surgery, and a read path that lazily filled the
/// cache would be a view-body mutation waiting to be reported. Ingest goes
/// through `refreshSoon` instead — same whole read, off the actor and
/// coalesced, because that one arrives in bursts.
@MainActor @Observable
final class TextStore {
    private let repo: PartsRepository
    /// Every text document, keyed by owner id, newest first per kind.
    private(set) var docs: [String: [TextDocRecord]] = [:]
    var lastError: String?

    init(repo: PartsRepository) {
        self.repo = repo
        // Off the actor, as in `LibraryStore.init` — this one mirrors the
        // whole table, and it grows about three rows per track for as long as
        // the auto-runs stay on.
        refreshSoon()
    }

    var repository: PartsRepository { repo }

    func refresh() {
        refreshTask?.cancel()
        refreshTask = nil
        publish((try? repo.allTextDocs()) ?? [])
    }

    /// Re-read the mirror because rows landed underneath us, without blocking
    /// what is on screen.
    ///
    /// The synchronous sibling re-reads the *whole* table, and with the
    /// auto-describe, auto-tag and auto-lyrics runs enabled that happens
    /// about three times per track as a render lands — on the main actor,
    /// inside the same burst that is already moving files and writing rows.
    /// The cost grows with everything the library has ever produced, so it is
    /// the one that gets worse the longer the app is used.
    ///
    /// Edits keep the synchronous path: a rename or a delete should land on
    /// the pane before the click finishes, and there is no burst of them to
    /// collapse.
    func refreshSoon() {
        refreshTask?.cancel()
        let repo = self.repo
        refreshTask = Task { [weak self] in
            let rows = await Task.detached(priority: .userInitiated) {
                (try? repo.allTextDocs()) ?? []
            }.value
            guard !Task.isCancelled, let self else { return }
            self.publish(rows)
        }
    }

    private func publish(_ rows: [TextDocRecord]) {
        docs = Dictionary(grouping: rows, by: \.ownerId)
    }

    /// The coalesced ingest-driven read — see `refreshSoon`.
    private var refreshTask: Task<Void, Never>?

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
        refreshSoon()
    }
}

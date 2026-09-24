// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Observation

@MainActor @Observable
final class DownloadsStore {
    /// Active downloads by download_id; fed by SSE, reconciled on (re)connect.
    /// Includes the ones still waiting their turn — transfers run one at a time
    /// (contract §4.2) and a queued download announces itself on arrival.
    private(set) var downloads: [String: DownloadInfo] = [:] {
        didSet {
            refreshTransfers()
            refreshModelDownloads()
        }
    }
    var client: BackendClient?

    /// What the shell needs to know about transfers, as a small value.
    ///
    /// The transport bar used to derive this by scanning `downloads.values`
    /// in `MainWindow.body`, which subscribed the root view to a dictionary
    /// the engine rewrites several times a second while bytes move — and the
    /// percentage it drew changed on maybe one in a hundred of those. The
    /// percent is rounded here instead, and the whole struct is `Equatable`,
    /// so the shell redraws when the *number on screen* changes rather than
    /// when a byte count does.
    struct Transfers: Equatable, Sendable {
        /// Transfers moving or waiting.
        var active = 0
        /// Stopped rows still on the list, of which `failed` are failures.
        var finished = 0
        var failed = 0
        /// Whole percent of the transfer the transport bar names, nil when
        /// none is moving or none has reported a total yet.
        var leadPercent: Int?
    }

    private(set) var transfers = Transfers()

    /// Is there no transfer row at all, moving or stopped.
    ///
    /// Separate from `transfers` for the same reason `JobsStore.queueEmpty`
    /// is separate from `load`: the shell's "is there a panel to open" test
    /// must not be subscribed to `leadPercent`, which moves right through a
    /// download.
    private(set) var transfersEmpty = true

    private func refreshTransfers() {
        var next = Transfers()
        next.active = downloads.count
        next.finished = finished.count
        next.failed = finished.count(where: \.isFailure)
        if let lead = downloads.values.first(where: { $0.state == .downloading }),
           lead.bytesTotal > 0 {
            next.leadPercent = Int(Double(lead.bytesDone)
                                   / Double(lead.bytesTotal) * 100)
        }
        if next != transfers { transfers = next }
        let empty = next.active == 0 && next.finished == 0
        if empty != transfersEmpty { transfersEmpty = empty }
    }

    // MARK: - What a model row prints

    /// The live download of each model, keyed by model id, republished only
    /// when something a Models row *draws* has moved.
    ///
    /// The same argument as `transfers`, one screen further in. The Models
    /// screen has to read a downloads dependency inside `body`: its rows are
    /// built in a `LazyVStack`'s closure, outside the tracking scope, so each
    /// one is handed its download as a value rather than reading for itself.
    /// Reading the raw dictionary there subscribed the *whole screen* to a
    /// byte counter the engine rewrites twice a second — and every one of
    /// those frames refiltered sixty-four models, replanned the list and
    /// recounted the actions of every row in it, to redraw numbers that had
    /// not changed.
    ///
    /// So this is published when the rendered form of a transfer changes: the
    /// state, the whole percent the bar is drawn at, the `18.1 / 53.4 GB`
    /// pair, the rate and the ETA. The values are the engine's own, except for
    /// `speedBps` — see `rates`.
    private(set) var modelDownloads: [String: DownloadInfo] = [:]

    /// The models with a transfer in flight.
    ///
    /// Separate from `modelDownloads` for the reason `transfersEmpty` is
    /// separate from `transfers`: *which* models are downloading decides which
    /// rows the Models screen plans and whether its long tail is held open,
    /// and neither of those answers may be invalidated by a percentage.
    private(set) var downloadingModelIds: Set<String> = []

    /// The smoothed rate of each live transfer, by download id.
    ///
    /// The row prints a rate and an ETA, so both have to take part in the test
    /// above — and a test on the raw `speedBps` would be the raw dictionary
    /// again, because the engine measures speed by re-walking the model cache
    /// and consecutive samples swing around the true rate (see `DownloadRate`).
    /// The smoother therefore runs here and `speedBps` is published smoothed,
    /// which leaves the row's own smoother a near-constant input rather than a
    /// contradictory one.
    ///
    /// Keyed by download id, not model id, so a second attempt at a model
    /// starts from nothing instead of inheriting the average of the attempt
    /// that failed.
    private var rates: [String: DownloadRate] = [:]

    /// One transfer as the row would print it. Compared, never shown.
    private struct RenderedTransfer: Equatable {
        let downloadId: String
        let state: DownloadState
        let isRuntimeOnly: Bool
        /// Drawn in place of the bar while a runtime is being built.
        let message: String?
        /// Whole percent — the width the progress bar is drawn at.
        let percent: Int
        /// The three segments of the mono line, kept apart so that a segment
        /// the row cannot state honestly compares as the nil it draws as.
        let progress: String
        let rate: String?
        let eta: String?
    }

    private var rendered: [String: RenderedTransfer] = [:]

    private func refreshModelDownloads() {
        var nextRendered: [String: RenderedTransfer] = [:]
        var nextShown: [String: DownloadInfo] = [:]
        // Rebuilt rather than pruned: a finished download's average has
        // nowhere to go — its id never comes back — and carrying only the
        // live ones over is one pass instead of two.
        var nextRates: [String: DownloadRate] = [:]
        var ids: Set<String> = []
        for info in downloads.values {
            ids.insert(info.modelId)
            var rate = rates[info.downloadId] ?? DownloadRate()
            rate.ingest(info.speedBps)
            nextRates[info.downloadId] = rate
            nextRendered[info.modelId] = RenderedTransfer(
                downloadId: info.downloadId,
                state: info.state,
                isRuntimeOnly: info.isRuntimeOnly,
                message: info.message,
                percent: info.bytesTotal > 0
                    ? Int(Double(info.bytesDone) / Double(info.bytesTotal) * 100)
                    : 0,
                // Asked of the formatters the row itself uses, so the test
                // cannot drift from the strings it is standing in for.
                progress: DownloadFormat.progress(done: info.bytesDone,
                                                  total: info.bytesTotal),
                rate: DownloadFormat.rate(rate.bytesPerSecond),
                eta: DownloadFormat.eta(
                    rate.secondsRemaining(bytesDone: info.bytesDone,
                                          bytesTotal: info.bytesTotal)))
            nextShown[info.modelId] = DownloadInfo(
                downloadId: info.downloadId, modelId: info.modelId,
                state: info.state, bytesDone: info.bytesDone,
                bytesTotal: info.bytesTotal,
                speedBps: Int64(rate.bytesPerSecond ?? 0),
                stage: info.stage, message: info.message,
                runtimeOnly: info.runtimeOnly)
        }
        rates = nextRates
        if nextRendered != rendered {
            rendered = nextRendered
            modelDownloads = nextShown
        }
        if ids != downloadingModelIds { downloadingModelIds = ids }
    }

    /// Why the last download of a model stopped, kept until that model is
    /// downloaded again.
    ///
    /// A failure used to be handled exactly like a completion — the row was
    /// removed and nothing else happened. The engine's diagnosis went nowhere,
    /// and a download that vanished without a word read as one that had
    /// finished; the model only admitted otherwise on the next visit to the
    /// screen, by offering "Resume download" again. Held here because the
    /// failure outlives the download it belongs to: the id is gone, the model
    /// remains, and the model is what the user is looking at.
    private(set) var failures: [String: DownloadFailure] = [:]

    struct DownloadFailure: Equatable, Sendable {
        let modelId: String
        let code: String
        let message: String

        /// The repo is gated and this machine has no access to it. Worth
        /// distinguishing because it is the one failure a retry cannot fix —
        /// the fix is a licence, accepted elsewhere.
        var needsAccess: Bool { code == "UNAUTHORIZED" }
    }

    /// Transfers that have stopped and have not been waved away yet, newest
    /// first.
    ///
    /// A download used to leave the list the instant it landed, which made it
    /// the one kind of work in this queue that answered "did that finish?" by
    /// vanishing — nine gigabytes and a transfer that never started looked
    /// identical a second later, and the only surviving evidence was a state
    /// change on a model row on another screen. Renders have always waited to
    /// be dismissed; these wait with them.
    ///
    /// Separate from `downloads` rather than a fourth `DownloadState`, because
    /// everything else that reads that dictionary — the sidebar card, the
    /// transport capsule, the Models screen's "downloading now" section — is
    /// asking what the machine is *doing*, and a row kept for the reader is
    /// not part of that answer.
    private(set) var finished: [FinishedDownload] = [] {
        didSet { refreshTransfers() }
    }

    /// One stopped transfer, kept after the download it describes is gone.
    struct FinishedDownload: Identifiable, Equatable, Sendable {
        /// The download id it had while it was running, so the row it leaves
        /// behind is dismissed by the same handle everything else used.
        let id: String
        let modelId: String
        /// No weights were fetched (contract §4.2) — the row has to say what
        /// was installed rather than name a download nobody started.
        let isRuntimeOnly: Bool
        /// What the transfer amounted to, from the last progress event: the
        /// total on a completed one, whatever arrived on a failed one. Zero
        /// when the download finished without this app ever seeing it move.
        let bytes: Int64
        let outcome: Outcome
        let finishedAt: Date

        enum Outcome: Equatable, Sendable {
            case completed
            /// The engine's diagnosis, as the row prints it. Cancelling is not
            /// here: the engine reports neither event for it (it emits only
            /// `models.changed`), and a row the user just cancelled is one
            /// they have already dealt with.
            case failed(String)
        }

        var isFailure: Bool { failureMessage != nil }

        /// The engine's diagnosis, or nil on one that finished.
        var failureMessage: String? {
            if case .failed(let message) = outcome { return message }
            return nil
        }
    }

    /// Downloads this store paused as part of a "pause everything", so
    /// releasing does not also restart one the user had paused on its own row
    /// beforehand — that one was paused for its own reasons.
    private var heldByPauseAll: Set<String> = []

    func info(forModel modelId: String) -> DownloadInfo? {
        downloads.values.first { $0.modelId == modelId }
    }

    func failure(forModel modelId: String) -> DownloadFailure? {
        failures[modelId]
    }

    /// Dismiss a reported failure. The row keeps it until it is either read and
    /// waved away or superseded by another attempt.
    func clearFailure(forModel modelId: String) {
        failures.removeValue(forKey: modelId)
    }

    func apply(_ event: EngineEvent) {
        switch event {
        case .downloadProgress(let info):
            downloads[info.downloadId] = info
            // A fresh attempt supersedes whatever the last one said, so the
            // old complaint does not sit under a running progress bar — nor
            // does the row the last attempt left behind, which would make one
            // model two rows.
            failures.removeValue(forKey: info.modelId)
            // Guarded. `finished` has a `didSet` that recomputes the whole
            // transfers summary, so an unconditional `removeAll` ran it a
            // second time on every progress frame — and it can only match on
            // the first frame after a retry.
            if finished.contains(where: { $0.modelId == info.modelId }) {
                finished.removeAll { $0.modelId == info.modelId }
            }
        case .downloadCompleted(let id, let modelId, let runtimeOnly):
            let last = downloads.removeValue(forKey: id)
            failures.removeValue(forKey: modelId)
            heldByPauseAll.remove(id)
            record(id: id, modelId: modelId,
                   // The event is the authority on which half was installed;
                   // the progress it replaces is the fallback for an engine
                   // too old to say (the field is optional on the wire).
                   runtimeOnly: runtimeOnly || (last?.isRuntimeOnly ?? false),
                   bytes: last?.bytesTotal ?? 0, outcome: .completed)
        case .downloadFailed(let id, let modelId, let error):
            let last = downloads.removeValue(forKey: id)
            heldByPauseAll.remove(id)
            failures[modelId] = DownloadFailure(modelId: modelId,
                                                code: error.code,
                                                message: error.message)
            record(id: id, modelId: modelId,
                   runtimeOnly: last?.isRuntimeOnly ?? false,
                   bytes: last?.bytesDone ?? 0,
                   outcome: .failed(error.message))
        default:
            break
        }
    }

    /// Did what this transfer was fetching actually arrive — asked of the
    /// catalog, per model.
    ///
    /// `reconcile()` needs it because the engine pops a finished download out
    /// of its own table (`downloader.py`'s `finally`), so `GET /v1/downloads`
    /// lists only live transfers and a completion is indistinguishable from a
    /// failure by absence alone. Injected as a closure rather than a reference
    /// so this store keeps no dependency on `ModelCatalogStore`;
    /// `AppEnvironment` refreshes the catalog immediately before reconciling.
    /// The default cannot tell, and "cannot tell" settles as a failure — a
    /// transfer whose weights nobody can confirm did not finish.
    var installCompleted: @MainActor (_ modelId: String,
                                      _ runtimeOnly: Bool) -> Bool = { _, _ in
        false
    }

    func reconcile() async {
        guard let client else { return }
        guard let list = try? await client.downloads() else { return }
        applyListing(list)
    }

    /// Adopt the engine's live list, settling whatever is no longer on it.
    ///
    /// Internal rather than private so the gap this exists for — a transfer
    /// that ended while the stream was down — can be tested without an engine.
    func applyListing(_ list: [DownloadInfo]) {
        let live = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
        // Replacing the dictionary wholesale, as this used to, made those
        // transfers vanish with no finished row and no `failures` entry — the
        // very "a download that vanished without a word read as one that had
        // finished" this machinery exists to prevent.
        let vanished = downloads.values.filter { live[$0.downloadId] == nil }
        downloads = live
        for info in vanished { settleVanished(info) }
    }

    /// Give a transfer that disappeared from the engine's list the finished
    /// row it never got an event for.
    private func settleVanished(_ info: DownloadInfo) {
        heldByPauseAll.remove(info.downloadId)
        if installCompleted(info.modelId, info.isRuntimeOnly) {
            failures.removeValue(forKey: info.modelId)
            record(id: info.downloadId, modelId: info.modelId,
                   runtimeOnly: info.isRuntimeOnly,
                   bytes: info.bytesTotal, outcome: .completed)
        } else {
            let message = "The download stopped while the app was not "
                + "listening, and the files are not installed."
            failures[info.modelId] = DownloadFailure(
                modelId: info.modelId, code: "INTERRUPTED", message: message)
            record(id: info.downloadId, modelId: info.modelId,
                   runtimeOnly: info.isRuntimeOnly,
                   bytes: info.bytesDone, outcome: .failed(message))
        }
    }

    func pause(_ id: String) async { try? await client?.pauseDownload(id) }

    func resume(_ id: String) async {
        heldByPauseAll.remove(id)
        try? await client?.resumeDownload(id)
    }

    func cancel(_ id: String) async {
        heldByPauseAll.remove(id)
        try? await client?.cancelDownload(id)
        downloads.removeValue(forKey: id)
    }

    /// Stop every transfer. Queued downloads are left alone: a paused download
    /// keeps its slot (contract §4.2), so nothing behind it starts either, and
    /// pausing something that was never transferring would be a no-op the
    /// engine documents as such.
    func pauseAll() async {
        for info in downloads.values where info.state == .downloading {
            heldByPauseAll.insert(info.id)
            try? await client?.pauseDownload(info.id)
        }
    }

    func resumeAll() async {
        for id in heldByPauseAll { try? await client?.resumeDownload(id) }
        heldByPauseAll.removeAll()
    }

    // MARK: finished rows

    /// Put a stopped transfer at the head of the list. Newest first is the
    /// order a record reads in, and inserting rather than sorting means two
    /// downloads that stop in the same millisecond cannot swap places between
    /// redraws.
    private func record(id: String, modelId: String, runtimeOnly: Bool,
                        bytes: Int64, outcome: FinishedDownload.Outcome,
                        at now: Date = Date()) {
        // One row per model, and per id: a completion that arrives twice (a
        // reconnect replaying the ring buffer) must not draw twice.
        finished.removeAll { $0.id == id || $0.modelId == modelId }
        finished.insert(FinishedDownload(id: id, modelId: modelId,
                                         isRuntimeOnly: runtimeOnly,
                                         bytes: bytes, outcome: outcome,
                                         finishedAt: now),
                        at: 0)
        ensureAutoClearRunning()
    }

    /// Take one finished row off the list.
    func dismissFinished(_ id: String) {
        finished.removeAll { $0.id == id }
    }

    /// Clear every finished row — the transfer half of the rail's "Clear done".
    func dismissAllFinished() {
        finished.removeAll()
    }

    // MARK: auto-clear

    /// How long a finished row stays before being dismissed on the user's
    /// behalf; nil (the default) keeps rows until dismissed by hand. The same
    /// closure into Settings that `JobsStore` reads, because the setting is
    /// about the queue and the queue has both halves in it.
    var autoClearAfterS: @MainActor () -> TimeInterval? = { nil }

    private var autoClearTask: Task<Void, Never>?

    /// Kick the sweeper. Cheap when the timer is already running, the policy is
    /// off, or there is nothing finished to clear.
    func ensureAutoClearRunning() {
        guard autoClearTask == nil, autoClearAfterS() != nil,
              !finished.isEmpty else { return }
        // Inherits the store's MainActor context; only the sleeps yield.
        autoClearTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, self.sweepFinished() else { break }
            }
            self?.autoClearTask = nil
        }
    }

    /// One tick: drop the rows that have outstayed the grace period, and say
    /// whether there is anything left to watch.
    ///
    /// Unlike a render's, a download's finish time is known exactly — the
    /// event that ends it is the event that makes the row — so there is no
    /// first-seen stamp to keep.
    @discardableResult
    func sweepFinished(now: Date = Date()) -> Bool {
        // False, not `!finished.isEmpty`: this answer is the 5-second loop's
        // only exit, so returning true with the policy switched off kept the
        // timer waking for as long as one undismissed row sat on the list.
        // `JobsStore.sweepFinished` has always returned false here.
        guard let after = autoClearAfterS() else { return false }
        finished.removeAll { now.timeIntervalSince($0.finishedAt) >= after }
        return !finished.isEmpty
    }
}

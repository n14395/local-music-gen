import Foundation
import Observation

@MainActor @Observable
final class DownloadsStore {
    /// Active downloads by download_id; fed by SSE, reconciled on (re)connect.
    /// Includes the ones still waiting their turn — transfers run one at a time
    /// (contract §4.2) and a queued download announces itself on arrival.
    private(set) var downloads: [String: DownloadInfo] = [:]
    var client: BackendClient?

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
            // old complaint does not sit under a running progress bar.
            failures.removeValue(forKey: info.modelId)
        case .downloadCompleted(let id, let modelId, _):
            downloads.removeValue(forKey: id)
            failures.removeValue(forKey: modelId)
        case .downloadFailed(let id, let modelId, let error):
            downloads.removeValue(forKey: id)
            failures[modelId] = DownloadFailure(modelId: modelId,
                                                code: error.code,
                                                message: error.message)
        default:
            break
        }
    }

    func reconcile() async {
        guard let client else { return }
        if let list = try? await client.downloads() {
            downloads = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
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
}

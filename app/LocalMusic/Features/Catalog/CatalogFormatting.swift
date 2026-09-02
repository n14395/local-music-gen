import Foundation

// Number formatting for the Models screen. All of it lives outside the views
// because every one of these strings is a *number*, the design renders numbers
// in mono all-caps, and getting them wrong is the kind of thing a unit test
// should catch rather than a screenshot.

// MARK: - Bytes

enum ByteFormat {
    /// `9.4 GB`. Binary gigabytes, which is what the rest of the app and the
    /// engine's `size_bytes` agree on.
    static func gb(_ bytes: Int64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
    }

    /// `36` — no unit, because the caller prints it once at the end of a
    /// sentence (`NEEDS 48 GB · YOU HAVE 36`). Memory is quoted in whole
    /// gigabytes: a Mac is sold as "36 GB", never as "35.8 GB".
    static func wholeGB(_ bytes: Int64) -> String {
        String(Int((Double(bytes) / 1_073_741_824).rounded()))
    }

    /// `412 KB` · `2.1 MB` · `9.4 GB` — the unit that suits the number.
    ///
    /// Models are always gigabytes, so `gb` is right for them and says so in
    /// its name. Amp captures are kilobytes to a few megabytes, and a library
    /// of forty of them rendered as "0.0 GB" forty times is the reason this
    /// exists.
    static func compact(_ bytes: Int64) -> String {
        let value = Double(bytes)
        if value >= 1_073_741_824 {
            return String(format: "%.1f GB", value / 1_073_741_824)
        }
        if value >= 1_048_576 {
            return String(format: "%.1f MB", value / 1_048_576)
        }
        return String(format: "%.0f KB", (value / 1024).rounded(.up))
    }
}

// MARK: - Readiness

/// What a model row is actually offering, once *both* halves of an install are
/// accounted for: the weights, and the family runtime that has to exist before
/// they can be loaded.
///
/// The two used to be conflated under one "Installed" label, which is how a
/// model could sit there with a green tick and then spend the first four
/// minutes of the first generation installing PyTorch. The row now says which
/// of the two it has.
enum ModelReadiness: Equatable {
    /// Neither half is here.
    case download
    /// A download of this model was started and interrupted.
    case resumeDownload
    /// The catalog says it is downloading but no progress event has arrived,
    /// so there is no download to pause or cancel yet.
    case starting
    /// Weights on disk, runtime not — the row offers to fetch the runtime.
    case runtimeMissing
    /// The runtime is being built right now, by this row's own install or by
    /// any other download of the same family.
    case runtimeInstalling
    /// Weights and runtime both here: this model will start rendering when
    /// asked, with nothing left to fetch.
    case ready

    static func of(_ model: ModelInfo) -> ModelReadiness {
        switch model.installState {
        case .notInstalled: return .download
        case .partial: return .resumeDownload
        case .downloading: return .starting
        case .installed:
            switch model.runtime {
            case .installed: return .ready
            case .installing: return .runtimeInstalling
            case .notInstalled: return .runtimeMissing
            }
        }
    }

    /// The word on the trailing state control. "Downloaded" means everything;
    /// "Model downloaded" means the weights and nothing else — the distinction
    /// is the whole point of the state, so it is in the label rather than in a
    /// tooltip nobody opens.
    var controlLabel: String? {
        switch self {
        case .ready: "Downloaded"
        case .runtimeMissing, .runtimeInstalling: "Model downloaded"
        case .download, .resumeDownload, .starting: nil
        }
    }

    /// Whether the model can be run right now without a wait nobody asked for.
    var isRunnable: Bool { self == .ready }
}

// MARK: - Deletion

/// What deleting a model actually frees.
///
/// The family runtime goes with the last model of its family (contract §4.1) —
/// for ACE-Step that is 1.4 GB of PyTorch, more than some of the models — so
/// the confirmation says when a delete is about to take one, and when the next
/// download of that family will have to build it again.
enum ModelDeletion {
    static func removesRuntime(_ model: ModelInfo, in catalog: [ModelInfo]) -> Bool {
        guard model.runtime != .notInstalled else { return false }
        return !catalog.contains {
            $0.id != model.id && $0.family == model.family
                && $0.installState == .installed
        }
    }

    static func message(for model: ModelInfo, in catalog: [ModelInfo]) -> String {
        var text = "Frees \(ByteFormat.gb(model.sizeBytes))."
        if removesRuntime(model, in: catalog) {
            text += " The \(model.family) runtime goes too — no other "
                + "downloaded model uses it."
        }
        return text + " Songs you generated are kept."
    }
}

// MARK: - Download rate

/// Exponentially-smoothed download throughput, and the ETA derived from it.
///
/// The engine measures speed by re-walking the model cache once a second, so
/// a raw `speedBps` sample still swings around the true rate from one event
/// to the next. Printed straight through, the `MB/S` readout strobes and an
/// ETA built on it jumps between "4 min" and "3 hours" with every sample.
/// Every sample folds into an EMA instead, and the ETA is computed here
/// because the wire carries none.
struct DownloadRate: Equatable {
    /// Half weight on the newest sample: at one sample a second that is
    /// roughly a two-second window — long enough to swallow the cache-walk
    /// jitter (each sample is already a 1 s average), short enough that a
    /// throttled connection shows up while you are still looking at the row.
    let smoothing: Double
    private(set) var bytesPerSecond: Double?

    init(smoothing: Double = 0.5) {
        self.smoothing = smoothing
    }

    mutating func ingest(_ sample: Int64) {
        let value = max(0, Double(sample))
        bytesPerSecond = bytesPerSecond.map { $0 + smoothing * (value - $0) } ?? value
    }

    /// Nil when the rate is unknown or has collapsed to nothing. A stalled
    /// download divided by ~0 bytes/s claims an ETA of several years, which is
    /// worse than admitting we do not know.
    func secondsRemaining(bytesDone: Int64, bytesTotal: Int64) -> Double? {
        guard let bytesPerSecond, bytesPerSecond >= 1024 else { return nil }
        let remaining = Double(bytesTotal - bytesDone)
        guard remaining > 0 else { return nil }
        return remaining / bytesPerSecond
    }
}

/// The mono line under a download's progress bar:
/// `18.1 / 53.4 GB · 12 MB/S · 48 MIN LEFT`.
enum DownloadFormat {
    /// `18.1 / 53.4 GB` — the unit is printed once, at the end of the pair.
    static func progress(done: Int64, total: Int64) -> String {
        guard total > 0 else { return ByteFormat.gb(done).uppercased() }
        return String(format: "%.1f / %.1f GB",
                      Double(done) / 1_073_741_824,
                      Double(total) / 1_073_741_824)
    }

    /// `12 MB/S`, or `740 KB/S` on a slow link. Decimal megabytes, because
    /// that is the unit every network readout in the world uses.
    static func rate(_ bytesPerSecond: Double?) -> String? {
        guard let bytesPerSecond, bytesPerSecond >= 1000 else { return nil }
        if bytesPerSecond >= 1_000_000 {
            return "\(Int((bytesPerSecond / 1_000_000).rounded())) MB/S"
        }
        return "\(Int((bytesPerSecond / 1000).rounded())) KB/S"
    }

    /// `48 MIN LEFT`. Rounds to whatever unit keeps the number small; never
    /// says "0 MIN LEFT", which reads as finished when it is not.
    static func eta(_ seconds: Double?) -> String? {
        guard let seconds, seconds > 0, seconds.isFinite else { return nil }
        if seconds < 90 {
            return "\(max(1, Int(seconds.rounded()))) S LEFT"
        }
        if seconds < 3600 {
            return "\(max(1, Int((seconds / 60).rounded()))) MIN LEFT"
        }
        let hours = Int(seconds) / 3600
        let minutes = Int((seconds - Double(hours) * 3600) / 60)
        return minutes == 0 ? "\(hours) H LEFT" : "\(hours) H \(minutes) MIN LEFT"
    }

    /// The whole line, dropping any segment we cannot state honestly.
    static func line(done: Int64, total: Int64, rate: DownloadRate) -> String {
        var parts = [progress(done: done, total: total)]
        if let speed = Self.rate(rate.bytesPerSecond) { parts.append(speed) }
        if let left = eta(rate.secondsRemaining(bytesDone: done, bytesTotal: total)) {
            parts.append(left)
        }
        return parts.joined(separator: " · ")
    }

    /// The whole line for a transfer in any of its three moving-or-not states.
    ///
    /// Shared by every place that draws a download — the Models row, the queue
    /// row and the sidebar card — because three hand-written copies of this
    /// branch is three chances for two of them to describe one download
    /// differently. The runtime-install state is deliberately not here: it has
    /// no bytes, and each site words that for its own shape.
    static func transferLine(_ info: DownloadInfo, rate: DownloadRate) -> String {
        let progress = progress(done: info.bytesDone, total: info.bytesTotal)
        if info.state == .paused { return progress + " · PAUSED" }
        // A queued download has real bytes — whatever is already cached — and
        // no rate, because nothing is transferring. `line` would print the tail
        // of the smoother's last window as this download's speed.
        if info.state == .queued { return progress + " · WAITING" }
        return line(done: info.bytesDone, total: info.bytesTotal, rate: rate)
    }

    /// The mono line under a transfer that has stopped: what it left behind,
    /// or why it did not.
    ///
    /// Deliberately not "ready to use": the weights arriving is one half of an
    /// install, and a model whose family runtime is still missing is not
    /// something you can render with yet (§4.1). The row says what happened,
    /// and the Models screen — which knows about both halves — says what the
    /// model can do.
    static func finishedLine(bytes: Int64, runtimeOnly: Bool,
                             failure: String?) -> String {
        if let failure {
            let text = failure.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "FAILED" : "FAILED · " + text.uppercased()
        }
        if runtimeOnly { return "RUNTIME INSTALLED" }
        // Zero bytes means the completion arrived without this app ever seeing
        // the transfer move — an app started mid-download, or a model already
        // cached. There is no size to quote, so none is quoted.
        guard bytes > 0 else { return "DOWNLOADED" }
        return ByteFormat.gb(bytes).uppercased() + " · DOWNLOADED"
    }

    /// Why Pause is offered but dead, or nil when it works. Two states have no
    /// transfer to suspend and the engine accepts pause over both and does
    /// nothing (contract §4.2) — a button that silently no-ops is worse than one
    /// that is dimmed and says why. Shared by both rows that draw a download,
    /// so the two cannot drift into different explanations.
    static func pauseBlockedReason(_ state: DownloadState) -> String? {
        switch state {
        case .downloading, .paused: nil
        case .provisioning: "Setting up the runtime — this step can't be paused"
        case .queued: "Waiting for the download ahead of it — nothing is transferring yet"
        }
    }
}

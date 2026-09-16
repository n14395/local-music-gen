import Foundation
import Observation

enum BackendPhase: Equatable, Sendable {
    case stopped
    case launching
    case ready
    case degraded
    case restarting
    case failed(reason: String)

    var label: String {
        switch self {
        case .stopped: "Stopped"
        case .launching: "Starting…"
        case .ready: "Ready"
        case .degraded: "Degraded"
        case .restarting: "Restarting…"
        case .failed: "Failed"
        }
    }
}

/// MainActor mirror of the process manager's state, observed by the UI.
@MainActor @Observable
final class BackendStatusStore {
    var phase: BackendPhase = .stopped
    var port: Int?
    var engineVersion: String?
    var eventStreamConnected = false
    var restartCount = 0
    /// Which engine process this is: bumped every time a new one becomes
    /// ready, whether it replaced a crash, a deliberate Restart Engine, or
    /// nothing at all (first launch).
    ///
    /// Deliberately not `restartCount`, which counts *crashes* and is shown
    /// to the user as such. This one is identity: uploads never outlive the
    /// engine process that took them (api-contract §7 — the engine purges
    /// them at startup), so anything caching an upload id has to be able to
    /// tell one engine from the next. See `EditorStore.uploadSource`.
    private(set) var engineGeneration = 0

    func noteEngineReady() { engineGeneration += 1 }
    var stderrTail: [String] = []
    /// What the warm worker holds, from worker.state events ("loading"/"loaded").
    var workerModelId: String?
    var workerModelState: String?
    /// The Settings-derived config the running engine was spawned with; nil
    /// for attach mode and for engines launched before Settings had a say.
    var launchedEngineConfig: EngineLaunchConfig?

    /// One chunk off the pipe, appended as one mutation.
    ///
    /// A chunk is usually several lines, and appending them one at a time was
    /// one observable publish *per line* — plus, once the 200-line buffer was
    /// full, an array shift per line, and a fresh scan of all 200 for
    /// `setupLine` per line. That is precisely the first-launch path, where
    /// the shim narrates itself while it fetches a Python and the log level
    /// may be `debug`.
    func appendStderr(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        stderrLineCount += lines.count
        stderrTail.append(contentsOf: lines)
        if stderrTail.count > Self.stderrCap {
            stderrTail = Array(stderrTail.suffix(Self.stderrCap))
        }
        // Kept in step here rather than scanned on read — see `setupLine`.
        let marker = "engine-setup: "
        if let last = lines.last(where: { $0.hasPrefix(marker) }) {
            setupLine = String(last.dropFirst(marker.count))
        }
    }

    func appendStderr(_ line: String) { appendStderr([line]) }

    private static let stderrCap = 200

    /// Every line ever read off the child's stderr, not just the ones still in
    /// the capped tail. `BackendProcessManager.connect` watches it to tell
    /// "still provisioning" from "wedged" while it waits for the handshake:
    /// a first run can legitimately take minutes, but it is never silent.
    private(set) var stderrLineCount = 0

    /// What the launcher shim says it is doing, if it has said anything.
    ///
    /// A first launch spends most of its time inside `engine-shim.sh` fetching
    /// a Python and building a venv, long before there is a port to ask
    /// anything about. `.launching` is the only phase the app has for all of
    /// it, which is why the shim narrates itself — this is the app end of
    /// that.
    ///
    /// Stored, not a `last(where:)` over the tail: onboarding reads it, and
    /// reading it re-scanned up to 200 strings for every line printed.
    private(set) var setupLine: String?
}

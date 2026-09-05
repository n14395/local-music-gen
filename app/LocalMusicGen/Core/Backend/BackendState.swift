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

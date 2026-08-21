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

    func appendStderr(_ line: String) {
        stderrTail.append(line)
        if stderrTail.count > 200 { stderrTail.removeFirst(stderrTail.count - 200) }
    }

    /// What the launcher shim says it is doing, if it has said anything.
    ///
    /// A first launch spends most of its time inside `engine-shim.sh` fetching
    /// a Python and building a venv, long before there is a port to ask
    /// anything about. `.launching` is the only phase the app has for all of
    /// it, which is why the shim narrates itself — this is the app end of
    /// that.
    var setupLine: String? {
        let marker = "engine-setup: "
        guard let line = stderrTail.last(where: { $0.hasPrefix(marker) })
        else { return nil }
        return String(line.dropFirst(marker.count))
    }
}

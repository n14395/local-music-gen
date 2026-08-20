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
}

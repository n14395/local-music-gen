import SwiftUI

/// The window's bottom strip: the player, the compare toggle, the engine
/// readout, and the queue capsule.
///
/// A view of its own for the same reason `ShellSidebar` is. The capsule's text
/// comes from `JobsStore.load` and `DownloadsStore.transfers`, and while it was
/// computed in `MainWindow.body` those two reads subscribed the window — and
/// therefore the whole screen inside it — to every take that advanced and every
/// whole percent of every download. Now they reach a 44 pt strip.
struct ShellTransport: View {
    let env: AppEnvironment
    let slot: TransportBar.Slot
    let isQueueOpen: Bool
    let onToggleQueue: () -> Void
    let onToggleCompare: () -> Void

    var body: some View {
        TransportBar(playback: env.playback, slot: slot,
                     queue: queue,
                     engine: env.engineStatus,
                     isQueueOpen: isQueueOpen,
                     onToggleQueue: onToggleQueue,
                     onToggleCompare: onToggleCompare)
    }

    /// A transfer beats a render in the capsule, because a download is the
    /// slower and less visible of the two — both are in the panel it opens, so
    /// the one that loses here is not hidden, only unmentioned.
    private var queue: TransportBar.Queue {
        // The percent is rounded inside the store, so this reads a number that
        // changes a hundred times over a transfer rather than a byte count
        // that changes a hundred times a second — see `DownloadsStore.Transfers`.
        if let percent = env.downloadsStore.transfers.leadPercent {
            return .downloading(percent: percent)
        }
        // Takes, not jobs: one submission of four takes is four tracks being
        // made, and reading "QUEUE 1" beside it was the counter disagreeing
        // with the number the user typed.
        let load = env.jobsStore.load
        if load.jobs > 0 { return .working(takes: load.takesLeft) }
        // Running work outranks a failure, because the render in front of you
        // is the more useful thing to watch — but with nothing running, a
        // failure nobody has dismissed is the truth about the queue and
        // "QUEUE EMPTY" is not.
        if load.failed > 0 { return .failed(count: load.failed) }
        return .idle
    }
}

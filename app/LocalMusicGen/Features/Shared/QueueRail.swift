// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// The queue with its own chrome: the header that counts it, the pause-all
/// control, the hold note, and the list itself.
///
/// This was private to Studio's rendering pane, where it was the right rail of
/// one screen. It is the shell's panel now — the same rail, reachable from the
/// transport bar wherever you are — because the queue was never a Studio fact.
/// A separation started from Actions and a model downloading from Models are
/// both in it, and a list you can only see from the screen that filled it is a
/// list you check by navigating away from your work.
struct QueueRail: View {
    let jobs: JobsStore
    let downloads: DownloadsStore
    let catalog: ModelCatalogStore
    /// Whether the panel is holding its own column rather than floating over
    /// the screen behind it.
    var isPinned = false
    /// Collapses the panel. Optional so the rail can still be embedded
    /// somewhere permanent without growing a button that would do nothing.
    var onClose: (() -> Void)?
    /// Swaps between floating and taking a column of its own. Optional for the
    /// same reason as `onClose`.
    var onTogglePin: (() -> Void)?
    /// Show a track a finished row produced. Optional: where the rail is only
    /// a status readout there is nowhere to send anyone.
    var onShowInLibrary: ((String) -> Void)?

    private var load: QueueLoad {
        QueueLoad.of(jobs: jobs.displayJobs, downloads: downloads)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if jobs.queueHeld { holdNote }
                    if load.isEmpty {
                        emptyNote
                    } else {
                        JobQueueSection(jobs: jobs, downloads: downloads,
                                        modelName: { id in
                                            catalog.model(id: id)?.displayName ?? id
                                        },
                                        reorderable: true,
                                        onShowInLibrary: onShowInLibrary)
                    }
                    Text("Downloads and renders share one queue so the Mac is never "
                         + "asked for two big jobs at once.")
                        .font(Bench.Typo.caption)
                        .foregroundStyle(Bench.Palette.textFaintest)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                }
                .padding(14)
            }
        }
    }

    // MARK: - Header

    /// Five controls in 340 pt, and "12 TAKES · 3 DOWNLOADS" is wide enough to
    /// push the buttons off the end — so the count is the part that goes when
    /// there is no room for all of it. It is the one thing here the rest of
    /// the panel repeats.
    private var header: some View {
        BenchPanelHeader {
            ViewThatFits(in: .horizontal) {
                headerRow(showsCount: true)
                headerRow(showsCount: false)
            }
        }
    }

    private func headerRow(showsCount: Bool) -> some View {
        HStack(spacing: 8) {
            Text("Queue")
                .font(Bench.Typo.sectionTitle)
                .foregroundStyle(Bench.Palette.textPrimary)
            if showsCount {
                // "3 TAKES · 1 DOWNLOAD" — a four-take render is four pieces
                // of work, however few jobs carry them.
                Text(load.headerLabel)
                    .font(Bench.Typo.mono(11))
                    .foregroundStyle(Bench.Palette.textFaintest)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            clearFinishedButton
            pauseAllButton
            if let onTogglePin {
                Button(action: onTogglePin) {
                    Image(systemName: isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(isPinned ? Bench.Palette.accent
                                                  : Bench.Palette.textFaint)
                        .padding(.horizontal, 3).padding(.vertical, 2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isPinned
                      ? "Unpin — let the queue float over the screen"
                      : "Pin the queue beside the screen instead of over it")
            }
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Bench.Palette.textFaint)
                        .padding(.horizontal, 3).padding(.vertical, 2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Hide the queue")
            }
        }
    }

    /// One control over both halves of the queue: the engine's render hold
    /// (§5.7) and every transfer (§4.2). Holding only one of them would leave
    /// the Mac just as busy as before, which is the thing the button is for.
    /// The circled glyph, against the rows' filled one: this is the same verb
    /// aimed at everything rather than at one row, and the two have to be
    /// tellable apart at a glance in the same 340 pt.
    private var pauseAllButton: some View {
        QueueIconButton(
            symbol: jobs.queueHeld ? "play.circle" : "pause.circle",
            help: jobs.queueHeld
                ? "Start the queue again"
                : "Hold the queue and pause every transfer — the render "
                  + "already running finishes",
            label: jobs.queueHeld ? "Resume all" : "Pause all",
            tone: jobs.queueHeld ? .accent : .quiet) {
            let held = jobs.queueHeld
            Task {
                await jobs.holdQueue(!held)
                // Only touch the transfers once the engine has taken the hold:
                // half a pause is worse than none, and a refusal is already on
                // jobs.lastError.
                guard jobs.queueHeld == !held else { return }
                if held { await downloads.resumeAll() }
                else { await downloads.pauseAll() }
            }
        }
    }

    /// Finished rows wait to be dismissed now rather than vanishing on a
    /// timer, which is the point of them — but a day's work is fifty rows, and
    /// "dismiss it yourself" should not have to mean fifty clicks. Absent
    /// rather than dimmed when there is nothing to clear: the header is five
    /// controls in 340 pt and a permanent dead button is the one that can go.
    @ViewBuilder
    private var clearFinishedButton: some View {
        if load.finished > 0 {
            // An eraser, not a bin: this clears rows off a list, it does not
            // delete anything that was made.
            QueueIconButton(symbol: "eraser",
                            help: "Dismiss every row that has finished",
                            label: "Clear done") {
                // Both halves: the button counts the transfers that have
                // stopped as rows to clear, so it had better clear them.
                jobs.dismissFinished()
                downloads.dismissAllFinished()
            }
        }
    }

    /// Said plainly rather than left as a blank panel: the queue is now
    /// something you open on purpose from any screen, so "there is nothing in
    /// it" and "it failed to draw" have to look different.
    private var emptyNote: some View {
        Text("Nothing queued. Renders and downloads appear here as you start them.")
            .font(Bench.Typo.secondary)
            .foregroundStyle(Bench.Palette.textFaint)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
    }

    /// What a hold actually did. The running take cannot be suspended (there is
    /// no engine verb for it and SIGSTOP inside a Metal command buffer is not
    /// something that resumes), so this says which of the two situations the
    /// user is in rather than letting "Paused" imply the render stopped.
    private var holdNote: some View {
        let running = jobs.runningWhileHeld
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: "pause.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Bench.Palette.warn)
            VStack(alignment: .leading, spacing: 3) {
                Text("QUEUE PAUSED")
                    .font(Bench.Typo.mono(10, .semibold))
                    .foregroundStyle(Bench.Palette.warn)
                // "No new renders" rather than "nothing": the engine's hold is
                // over the job queue, and a download started from Models after
                // this point still transfers.
                Text(running == nil
                     ? "No new renders will start until you resume."
                     : "Finishing the current render — cancel it to stop now.")
                    .font(Bench.Typo.caption)
                    .foregroundStyle(Bench.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .benchCard(fill: Bench.Palette.warn.opacity(0.08),
                   stroke: Bench.Palette.warn.opacity(0.22), radius: 11)
    }
}

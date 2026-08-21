import SwiftUI

/// The 66 pt bar across the bottom of the window.
///
/// Two changes from the old player bar that the design is explicit about: the
/// scrubber is the track's own waveform rather than a `Slider` (you can see
/// where the drop is before you drag to it), and the right-hand corner carries
/// whatever the app is busy with, so background work is visible from every
/// screen instead of only from the screen that started it.
///
/// That corner is two things, not one. The **queue** readout is always drawn,
/// because it is also the button that opens the queue panel and a control that
/// comes and goes is not somewhere you can learn to look. Anything else the
/// bar has to say — the A/B switch, the workbench level meter — sits beside it
/// rather than in its place, which it used to: comparing two takes hid whether
/// anything was rendering at all.
///
/// It spans the full window width, under the sidebar as well as the content.
struct TransportBar: View {
    let playback: PlaybackController
    /// What the *user* is doing. Exactly one at a time, decided by the shell.
    let slot: Slot
    /// What the *machine* is doing.
    let queue: Queue
    /// What the *engine* is doing. The bar is the only chrome on screen from
    /// every screen, which is the whole argument for it being here.
    let engine: EngineStatus
    var isQueueOpen = false

    enum Slot: Equatable {
        /// Nothing to add — the queue readout has the corner to itself.
        case none
        /// Two library rows are ticked: the bar becomes an A/B switch.
        case compare(isB: Bool)
        /// The workbench rough preview shows level.
        case level(db: Double)
    }

    /// The queue capsule's three faces, in the shell's priority order: a
    /// transfer beats a render, because a download is the slower and less
    /// visible of the two. Both are in the panel the capsule opens.
    enum Queue: Equatable {
        case idle
        /// Takes, not jobs: one submission of four takes is four tracks being
        /// made, and reading "QUEUE 1" beside it was the counter disagreeing
        /// with the number the user typed.
        case working(takes: Int)
        case downloading(percent: Int)
        /// Nothing is running, and something that ran did not work. Distinct
        /// from `idle` because this capsule is the only always-visible report
        /// on background work: a render that fails while you are on another
        /// screen otherwise leaves the window saying QUEUE EMPTY, which is
        /// how a failure came to look like a queue that quietly drained.
        case failed(count: Int)
    }

    var onToggleQueue: (() -> Void)?
    var onToggleCompare: (() -> Void)?

    var body: some View {
        HStack(spacing: 18) {
            BenchTransportButton(isPlaying: playback.isPlaying) {
                playback.toggle()
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(playback.currentTitle)
                    .font(Bench.Typo.secondaryEmphasis)
                    .foregroundStyle(Bench.Palette.textPrimary)
                    .lineLimit(1).truncationMode(.tail)
                if !playback.currentSubtitle.isEmpty {
                    Text(playback.currentSubtitle.uppercased())
                        .metaLine()
                        .lineLimit(1)
                }
            }
            .frame(width: 190, alignment: .leading)

            scrubber

            Text("\(time(playback.currentTime)) / \(time(playback.duration))")
                .font(Bench.Typo.mono(12))
                .foregroundStyle(Bench.Palette.textTertiary)
                .fixedSize()

            slotView
            engineButton
            queueButton
        }
        .padding(.horizontal, 20)
        .frame(height: Bench.Metrics.transportHeight)
        .frame(maxWidth: .infinity)
        .background(Bench.Palette.panel)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
        }
    }

    @ViewBuilder
    private var scrubber: some View {
        if let url = playback.currentURL, let songId = playback.currentSongId {
            BenchWaveformLoader(
                audioURL: url,
                cacheURL: StoragePaths.libraryWaveforms
                    .appendingPathComponent(songId + ".peaks"),
                playedFraction: playback.playedFraction,
                barPitch: 3,
                onSeek: { fraction in
                    guard playback.duration > 0 else { return }
                    playback.seek(to: fraction * playback.duration)
                })
                .frame(height: 34)
                .frame(maxWidth: .infinity)
        } else {
            // No file to draw — keep the geometry so the bar does not jump.
            Color.clear.frame(height: 34).frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var slotView: some View {
        switch slot {
        case .none:
            EmptyView()
        case .compare(let isB):
            HStack(spacing: 4) {
                compareKey("A", active: !isB)
                compareKey("B", active: isB)
            }
            .padding(4)
            .background(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.button,
                                         style: .continuous)
                .fill(Bench.Palette.raised))
            .overlay(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.button,
                                      style: .continuous)
                .strokeBorder(Bench.Palette.cardStrokeSoft, lineWidth: 1))
            .fixedSize()
        case .level(let db):
            HStack(spacing: 8) {
                LevelMeter(db: db)
                Text(String(format: "%.1f dB", db))
                    .font(Bench.Typo.mono(10, .semibold))
                    .foregroundStyle(Bench.Palette.textQuaternary)
            }
            .fixedSize()
        }
    }

    private func compareKey(_ letter: String, active: Bool) -> some View {
        Button {
            onToggleCompare?()
        } label: {
            Text(letter)
                .font(Bench.Typo.mono(11, .bold))
                .foregroundStyle(active ? Bench.Palette.onAccent
                                        : Bench.Palette.textQuaternary)
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.badge,
                                             style: .continuous)
                    .fill(active ? Bench.Palette.accent : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(active ? "Playing \(letter)" : "Switch to \(letter) — Tab")
    }

    // MARK: - Engine

    /// Engine state, beside the queue readout rather than in Studio's top bar
    /// where it used to live. Both are the machine talking rather than the
    /// user, and "why is nothing happening" is a question you ask from
    /// whatever screen you are on — which was rarely the one screen that
    /// answered it.
    private var engineButton: some View {
        EngineStatusButton(engine: engine, arrowEdge: .top) {
            capsule(tinted: false) {
                StatusDot(color: engineColor, size: 7, glows: false)
                Text(engine.status.phase.label.uppercased())
                    .font(Bench.Typo.mono(11, .semibold))
                    .foregroundStyle(engineTextColor)
                EngineStatusHint()
            }
        }
    }

    private var engineColor: Color {
        switch engine.status.phase {
        case .ready: engine.status.eventStreamConnected ? Bench.Palette.ok
                                                        : Bench.Palette.warn
        case .launching, .restarting, .degraded: Bench.Palette.warn
        case .failed: Bench.Palette.danger
        case .stopped: Bench.Palette.textMuted
        }
    }

    /// Quiet as "QUEUE EMPTY" is quiet when there is nothing to say, and the
    /// status colour when there is. A healthy engine should not compete with
    /// the track title for attention; a stalled one should win.
    private var engineTextColor: Color {
        if case .ready = engine.status.phase, engine.status.eventStreamConnected {
            return Bench.Palette.textFaintest
        }
        return engineColor
    }

    // MARK: - Queue

    /// The queue readout, which is also the panel's switch. It used to be a
    /// label, and clicking the one part of the window that names background
    /// work and having nothing happen is the bug this answers.
    private var queueButton: some View {
        Button { onToggleQueue?() } label: { queueLabel }
            .buttonStyle(.plain)
            .help(isQueueOpen ? "Hide the queue" : queueHelp)
    }

    private var queueHelp: String {
        switch queue {
        case .idle: "Show the queue"
        case .working: "Show what is rendering"
        case .downloading: "Show the queue and the transfer"
        case .failed: "Show what went wrong"
        }
    }

    @ViewBuilder
    private var queueLabel: some View {
        switch queue {
        case .idle:
            capsule(tinted: false, open: isQueueOpen) {
                Text("QUEUE EMPTY")
                    .font(Bench.Typo.mono(11, .semibold))
                    .foregroundStyle(Bench.Palette.textFaintest)
                panelChevron(Bench.Palette.textFaintest)
            }
        case .working(let takes):
            capsule(tinted: true, open: isQueueOpen) {
                BenchSpinner(size: 16)
                Text("QUEUE \(takes)")
                    .font(Bench.Typo.mono(11, .semibold))
                    .foregroundStyle(Bench.Palette.accent)
                panelChevron(Bench.Palette.accent.opacity(0.7))
            }
        case .downloading(let percent):
            capsule(tinted: true, open: isQueueOpen) {
                BenchSpinner(size: 16)
                Text("DOWNLOAD \(percent)%")
                    .font(Bench.Typo.mono(11, .semibold))
                    .foregroundStyle(Bench.Palette.accent)
                panelChevron(Bench.Palette.accent.opacity(0.7))
            }
        case .failed(let count):
            capsule(tinted: true, open: isQueueOpen,
                    tone: Bench.Palette.danger) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Bench.Palette.danger)
                Text(count == 1 ? "1 FAILED" : "\(count) FAILED")
                    .font(Bench.Typo.mono(11, .semibold))
                    .foregroundStyle(Bench.Palette.danger)
                panelChevron(Bench.Palette.danger.opacity(0.7))
            }
        }
    }

    /// Says which way the panel goes, and which way it would go next. Without
    /// it the capsule is a readout that happens to be clickable.
    private func panelChevron(_ color: Color) -> some View {
        Image(systemName: isQueueOpen ? "chevron.right" : "chevron.left")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(color)
    }

    /// `open` is drawn rather than left to a press highlight: the panel it
    /// opens is at the far side of the window from the button, so the button
    /// has to say whether it is the thing that put it there.
    private func capsule<Content: View>(tinted: Bool, open: Bool = false,
                                        tone: Color = Bench.Palette.accent,
                                        @ViewBuilder content: () -> Content) -> some View {
        let fill: Color = if tinted { tone.opacity(open ? 0.2 : 0.12) }
                          else if open { Bench.Palette.control }
                          else { Bench.Palette.raised }
        let stroke: Color = if tinted { tone.opacity(open ? 0.5 : 0.26) }
                            else if open { Bench.Palette.cardStroke }
                            else { Bench.Palette.cardStrokeSoft }
        return HStack(spacing: 9) { content() }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.button,
                                         style: .continuous)
                .fill(fill))
            .overlay(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.button,
                                      style: .continuous)
                .strokeBorder(stroke, lineWidth: 1))
            .fixedSize()
    }

    private func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Four bars that go amber near clipping — the workbench preview neither
/// normalises nor limits, so this is the only warning that a stack of parts
/// has summed past full scale.
struct LevelMeter: View {
    let db: Double
    var barCount = 4

    private var fraction: Double {
        // −40 dB floor, 0 dB ceiling.
        ((db + 40) / 40).clamped(to: 0...1)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<barCount, id: \.self) { index in
                let threshold = Double(index + 1) / Double(barCount)
                let lit = fraction >= threshold - 0.25
                RoundedRectangle(cornerRadius: 1)
                    .fill(lit ? (threshold > 0.85 ? Bench.Palette.warn : Bench.Palette.ok)
                              : Bench.Palette.segmentedSelected)
                    .frame(width: 3, height: 9 + CGFloat(index) * 4)
            }
        }
        .frame(height: 22, alignment: .bottom)
    }
}

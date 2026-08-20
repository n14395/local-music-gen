import SwiftUI

/// The 66 pt bar across the bottom of the window.
///
/// Two changes from the old player bar that the design is explicit about: the
/// scrubber is the track's own waveform rather than a `Slider` (you can see
/// where the drop is before you drag to it), and the right-hand slot carries
/// whatever the app is busy with — the queue, a download, or the A/B switch —
/// so background work is visible from every screen instead of only from the
/// screen that started it.
///
/// It spans the full window width, under the sidebar as well as the content.
struct TransportBar: View {
    let playback: PlaybackController
    let slot: Slot

    /// What occupies the right-hand corner. Exactly one thing at a time, in
    /// this priority order, decided by the shell.
    enum Slot: Equatable {
        case idle
        case queue(count: Int)
        case download(percent: Int)
        /// Two library rows are ticked: the bar becomes an A/B switch.
        case compare(isB: Bool)
        /// The workbench rough preview shows level rather than a queue.
        case level(db: Double)
    }

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
        case .idle:
            capsule(tinted: false) {
                Text("QUEUE EMPTY")
                    .font(Bench.Typo.mono(11, .semibold))
                    .foregroundStyle(Bench.Palette.textFaintest)
            }
        case .queue(let count):
            capsule(tinted: true) {
                BenchSpinner(size: 16)
                Text("QUEUE \(count)")
                    .font(Bench.Typo.mono(11, .semibold))
                    .foregroundStyle(Bench.Palette.accent)
            }
        case .download(let percent):
            capsule(tinted: true) {
                BenchSpinner(size: 16)
                Text("DOWNLOAD \(percent)%")
                    .font(Bench.Typo.mono(11, .semibold))
                    .foregroundStyle(Bench.Palette.accent)
            }
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

    private func capsule<Content: View>(tinted: Bool,
                                        @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 9) { content() }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.button,
                                         style: .continuous)
                .fill(tinted ? Bench.Palette.accent.opacity(0.12) : Bench.Palette.raised))
            .overlay(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.button,
                                      style: .continuous)
                .strokeBorder(tinted ? Bench.Palette.accent.opacity(0.26)
                                     : Bench.Palette.cardStrokeSoft, lineWidth: 1))
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

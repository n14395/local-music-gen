import SwiftUI

/// The edit preview's transport, as it sits in the seek row under the
/// overview strip.
///
/// It used to be the left two-thirds of the app's bottom bar, which made the
/// Editor the one screen where the shared player was not the shared player.
/// Moving it here puts the controls against the waveform they act on and gives
/// every screen the same bar back.
///
/// Icons rather than the old `LOOP SELECTION` / `PLAY SELECTION` / `A / B
/// ORIGINAL` chips: those measured 118, 138 and 118 pt against 30 pt here, and
/// the row has to share its width with the seek bar, the meter and the clock.
/// Nothing is lost that was only in the label — each one names itself on
/// hover, and the two with key equivalents say so there.
struct EditorTransportControls: View {
    @Bindable var store: EditorStore

    /// Matches the old bar's stop button, which is the size every square
    /// control here inherits.
    static let buttonSize: CGFloat = 30

    var body: some View {
        HStack(spacing: 6) {
            BenchTransportButton(isPlaying: store.isPlaying) {
                store.togglePlayback()
            }
            .help(store.isPlaying ? "Pause — Space" : "Play — Space")

            square("stop.fill", active: false, enabled: true,
                   help: "Stop and rewind") {
                store.stopPreview()
            }

            Rectangle().fill(Color.white.opacity(0.09))
                .frame(width: 1, height: 18)
                .padding(.horizontal, 2)

            square("repeat", active: store.loopSelection,
                   enabled: store.selection != nil,
                   help: "Loop the selection while playing") {
                store.loopSelection.toggle()
                if store.loopSelection, store.selection != nil {
                    store.playSelection()
                }
            }

            square("play.rectangle", active: false,
                   enabled: store.selection != nil,
                   help: "Play just the selection — ⌥Space") {
                store.playSelection()
            }

            // Not a glyph: there is no A/B symbol, and the two letters are the
            // name of the thing. Still 30 pt, so the row stays a row of keys.
            key("A/B", active: store.auditioningOriginal,
                enabled: !store.document.isEmpty,
                help: "Switch between the edit and the untouched original at "
                    + "the same position") {
                store.toggleOriginalAudition()
            }
        }
    }

    private func square(_ symbol: String, active: Bool, enabled: Bool,
                        help: String,
                        action: @escaping () -> Void) -> some View {
        button(active: active, enabled: enabled, help: help, action: action) {
            Image(systemName: symbol).font(.system(size: 11))
        }
    }

    private func key(_ text: String, active: Bool, enabled: Bool, help: String,
                     action: @escaping () -> Void) -> some View {
        button(active: active, enabled: enabled, help: help, action: action) {
            Text(text).font(Bench.Typo.mono(10, .bold))
        }
    }

    private func button<Label: View>(active: Bool, enabled: Bool, help: String,
                                     action: @escaping () -> Void,
                                     @ViewBuilder label: () -> Label)
        -> some View {
        Button(action: action) {
            label()
                .foregroundStyle(active ? Bench.Palette.accent
                                        : Bench.Palette.textSecondary)
                .frame(width: Self.buttonSize, height: Self.buttonSize)
                .background(RoundedRectangle(cornerRadius: 8,
                                             style: .continuous)
                    .fill(active ? Bench.Palette.accent.opacity(0.12)
                                 : Bench.Palette.raised))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(active ? Bench.Palette.accent.opacity(0.28)
                                         : Bench.Palette.cardStrokeSoft,
                                  lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .help(help)
    }
}

/// The preview's real level, from the tap on its mixer.
///
/// The preview neither normalises nor limits, so this is the only notice that
/// a stack of segments has summed past full scale.
struct EditorPreviewMeter: View {
    let db: (left: Double, right: Double)?

    var body: some View {
        HStack(spacing: 9) {
            VStack(alignment: .leading, spacing: 3) {
                bar("L", db: db?.left)
                bar("R", db: db?.right)
            }
            Text(db.map { String(format: "%.1f dB", max($0.left, $0.right)) }
                 ?? "— dB")
                .font(Bench.Typo.mono(10, .semibold))
                .foregroundStyle(Bench.Palette.textQuaternary)
                .frame(width: 52, alignment: .leading)
        }
        .fixedSize()
    }

    private func bar(_ label: String, db: Double?) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(Bench.Typo.mono(8, .semibold))
                .foregroundStyle(Bench.Palette.textFaintest)
                .frame(width: 6)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule().fill(Bench.Palette.ok)
                    .frame(width: 62 * CGFloat(((db ?? -80) + 60) / 60)
                        .clamped(to: 0...62))
                Rectangle().fill(Bench.Palette.danger)
                    .frame(width: 1.5)
                    .offset(x: 62 * 59 / 60)
            }
            .frame(width: 62, height: 5)
            .clipShape(Capsule())
        }
    }
}

/// Playhead over duration, ticking only while something is playing.
struct EditorTransportClock: View {
    @Bindable var store: EditorStore

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.25,
                                paused: !store.isPlaying)) { _ in
            Text("\(EditorClock.full(store.playheadS)) / "
                 + "\(EditorClock.full(store.timelineDurationS))")
                .font(Bench.Typo.mono(12))
                .foregroundStyle(Bench.Palette.textTertiary)
                .fixedSize()
        }
    }
}

/// The whole-track seek bar: `BenchSlider`'s exact vocabulary — the 4 pt
/// track, the 14 pt knob, the accent fill — carrying playhead semantics.
/// Clicking or dragging anywhere is a seek, and only ever a seek: the strip
/// above already means "move the view", and holding the two meanings on
/// separate rows is what keeps both unambiguous.
///
/// Wrapped in a `TimelineView` because the playhead advances outside
/// observation while playing: `currentPosition()` is a live query on the
/// player, not a published property, so nothing else invalidates this view
/// between frames.
struct EditorSeekBar: View {
    @Bindable var store: EditorStore

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30,
                                paused: !store.isPlaying)) { _ in
            BenchSlider(value: Binding(
                get: { store.playheadS },
                set: { store.seekPreview(to: $0) }),
                range: 0...max(0.001, store.timelineDurationS))
        }
    }
}

/// The row between the overview strip and the well: the preview's transport,
/// the whole-track seek bar, the clock and the level meter — the bottom bar's
/// old editor anatomy, rebuilt against the timeline it plays. Shaped like the
/// app's player on purpose, so it reads as "the editor's player" on sight
/// while the bar at the bottom of the window is the app's player again.
struct EditorSeekRow: View {
    @Bindable var store: EditorStore

    var body: some View {
        HStack(spacing: 12) {
            EditorTransportControls(store: store)
            EditorSeekBar(store: store)
                .frame(minWidth: 140, maxWidth: .infinity)
            EditorTransportClock(store: store)
            EditorPreviewMeter(db: store.player.meterDb)
        }
    }
}

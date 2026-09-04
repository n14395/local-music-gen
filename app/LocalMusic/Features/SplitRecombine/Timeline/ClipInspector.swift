import SwiftUI

/// Controls for the selected clip, lifted from the Rows lens so nothing the
/// list could do is lost on the timeline: gain, mute, trim, fades, and the
/// exact placement as a number for when dragging isn't precise enough.
///
/// A 74 pt bar under the lanes rather than a side panel — the clip you are
/// editing stays where you dropped it, and the controls line up under the
/// track headers they belong to.
struct ClipInspector: View {
    @Binding var clip: WorkbenchModel.Clip
    /// Which placement of this part it is, within its lane. Two clips of the
    /// same stem are otherwise indistinguishable in this bar.
    let clipNumber: Int
    let beatsPerBar: Double
    let lengthBeats: Double
    let lengthSeconds: Double
    let onDuplicate: () -> Void
    let onRemove: () -> Void
    /// Snapshot for undo. Called *before* the mutation, never after — an undo
    /// step registered after the write restores the value you just typed.
    let onBeforeEdit: () -> Void

    private var stem: Color { Bench.Palette.stem(clip.material.kind) }

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 9) {
                StemBar(kind: clip.material.kind, height: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(clip.material.name)
                        .font(Bench.Typo.sectionTitle)
                        .foregroundStyle(Bench.Palette.textPrimary)
                        .lineLimit(1)
                    Text("CLIP \(clipNumber) · FROM \(clip.material.sourceTitle)")
                        .metaLine()
                        .lineLimit(1)
                }
            }
            .frame(width: 170, alignment: .leading)

            HStack(spacing: 9) {
                Text("Gain")
                    .font(Bench.Typo.small)
                    .foregroundStyle(Bench.Palette.textQuaternary)
                BenchSlider(value: $clip.gainDb, range: -24...6, tint: stem,
                            knobSize: Bench.Metrics.Slider.knobSmall,
                            onEditingBegan: onBeforeEdit)
                Text(String(format: "%+.1f dB", clip.gainDb))
                    .font(Bench.Typo.mono(11, .semibold))
                    .foregroundStyle(Bench.Palette.textSecondary)
                    .frame(width: 48, alignment: .trailing)
            }
            .frame(width: 224)

            HStack(spacing: 9) {
                Text("Pan")
                    .font(Bench.Typo.small)
                    .foregroundStyle(Bench.Palette.textQuaternary)
                BenchSlider(value: $clip.pan, range: -1...1, tint: stem,
                            knobSize: Bench.Metrics.Slider.knobSmall,
                            onEditingBegan: onBeforeEdit)
                Text(Bench.panLabel(clip.pan))
                    .font(Bench.Typo.mono(11, .semibold))
                    .foregroundStyle(Bench.Palette.textSecondary)
                    .frame(width: 44, alignment: .trailing)
            }
            .frame(width: 190)

            WorkbenchToggleBadge(kind: .mute, isOn: $clip.muted,
                                 onBeforeEdit: onBeforeEdit)

            HStack(spacing: 8) {
                Text("Bar")
                    .font(Bench.Typo.small)
                    .foregroundStyle(Bench.Palette.textQuaternary)
                BenchNumberField(value: Binding(
                    get: { clip.startBeats / beatsPerBar + 1 },
                    set: {
                        onBeforeEdit()
                        clip.startBeats = TimelineMath.clampStart(
                            ($0 - 1) * beatsPerBar)
                    }),
                                 format: .number.precision(.fractionLength(0...2)),
                                 width: 58)
            }

            HStack(spacing: 8) {
                Text("Fades")
                    .font(Bench.Typo.small)
                    .foregroundStyle(Bench.Palette.textQuaternary)
                fadeField($clip.fadeInS, help: "Fade in (ms)")
                fadeField($clip.fadeOutS, help: "Fade out (ms)")
                Text("ms")
                    .font(Bench.Typo.mono(10))
                    .foregroundStyle(Bench.Palette.textMuted)
            }

            sectionMenu

            Text(lengthText)
                .metaLine()
                .lineSpacing(2)
                .fixedSize()

            Spacer(minLength: 8)

            Button("Duplicate", action: onDuplicate)
                .buttonStyle(BenchSecondaryButtonStyle(
                    tone: .neutral,
                    padding: EdgeInsets(top: 9, leading: 13,
                                        bottom: 9, trailing: 13)))
                .help("Duplicate (⌘D)")
            Button("Delete clip", action: onRemove)
                .buttonStyle(BenchSecondaryButtonStyle(
                    tone: .destructive,
                    padding: EdgeInsets(top: 9, leading: 13,
                                        bottom: 9, trailing: 13)))
                .help("Remove clip (⌫)")
        }
        .padding(.horizontal, 20)
        .frame(height: 74)
        .background(Bench.Palette.panel)
        .overlay(alignment: .top) {
            Rectangle().fill(Bench.Palette.cardStrokeSoft).frame(height: 1)
        }
    }

    /// Fades are typed in milliseconds — at 40 ms, seconds is three characters
    /// of leading zero. Clamped to the clip so a fade can never be longer than
    /// the audio it applies to.
    private func fadeField(_ value: Binding<Double>, help: String) -> some View {
        BenchNumberField(value: Binding(
            get: { (value.wrappedValue * 1000).rounded() },
            set: {
                onBeforeEdit()
                value.wrappedValue = max(0, min($0 / 1000, lengthSeconds))
            }),
                         format: .number.precision(.fractionLength(0)),
                         width: 56)
            .help(help)
    }

    private var lengthText: String {
        String(format: "%.1f BARS\n%.1f S", lengthBeats / beatsPerBar,
               lengthSeconds)
    }

    @ViewBuilder
    private var sectionMenu: some View {
        if clip.sections.isEmpty {
            BenchValueField(text: "Whole part", width: nil, alignment: .leading,
                            font: Bench.Typo.secondary,
                            foreground: Bench.Palette.textMuted)
                .opacity(0.45)
                .help("Run Musical analysis on this part to trim it to a section")
        } else {
            BenchMenu(label: sectionLabel,
                      fill: Bench.Palette.windowBackground,
                      stroke: Bench.Palette.cardStroke,
                      radius: Bench.Metrics.Radius.control) {
                Button("Whole part") {
                    onBeforeEdit()
                    clip.sectionStartS = nil
                    clip.sectionEndS = nil
                }
                ForEach(Array(clip.sections.enumerated()), id: \.offset) { i, s in
                    Button("\(s.label ?? s.group ?? "Section \(i + 1)")  "
                           + "\(clock(s.startS))–\(clock(s.endS))") {
                        onBeforeEdit()
                        clip.sectionStartS = s.startS
                        clip.sectionEndS = s.endS
                    }
                }
            }
        }
    }

    private var sectionLabel: String {
        guard let start = clip.sectionStartS, let end = clip.sectionEndS else {
            return "Whole part"
        }
        return "Trim \(clock(start))–\(clock(end))"
    }

    private func clock(_ t: Double) -> String {
        String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
    }
}

import SwiftUI

// Status in this design is always a *badge* — a small mono all-caps token —
// never a colour alone. These are the pieces that carry it.

// MARK: - Badge

/// `INSTRUMENTAL`, `≤ 30 S`, `EXACT`, `DOWNLOADING`, `NEEDS 48 GB · YOU HAVE 36`.
struct BenchBadge: View {
    let text: String
    var tone: Tone = .neutral
    var emphasised = false

    init(_ text: String, tone: Tone = .neutral, emphasised: Bool = false) {
        self.text = text
        self.tone = tone
        self.emphasised = emphasised
    }

    enum Tone {
        case neutral, accent, ok, warn, danger, violet, cyan

        var color: Color {
            switch self {
            case .neutral: Bench.Palette.textTertiary
            case .accent: Bench.Palette.accent
            case .ok: Bench.Palette.ok
            case .warn: Bench.Palette.warn
            case .danger: Bench.Palette.dangerText
            case .violet: Bench.Palette.violet
            case .cyan: Bench.Palette.cyan
            }
        }

        var fill: Color {
            switch self {
            case .neutral: Bench.Palette.raised
            case .danger: Bench.Palette.danger.opacity(0.10)
            default: color.opacity(0.10)
            }
        }
    }

    var body: some View {
        Text(text)
            .font(emphasised ? Bench.Typo.mono(9, .semibold) : Bench.Typo.badge)
            .tracking(emphasised ? 0.9 : 0)
            .foregroundStyle(tone.color)
            .padding(.horizontal, emphasised ? 6 : 8)
            .padding(.vertical, emphasised ? 4 : 5)
            .background(RoundedRectangle(cornerRadius: emphasised ? 4
                                                                  : Bench.Metrics.Radius.badge,
                                         style: .continuous)
                .fill(tone.fill))
            .fixedSize()
    }
}

/// The softer, sentence-case tag: `chill`, `demo`, `Piano`. Used for song tags
/// and sibling-part links.
struct BenchTag: View {
    let text: String
    var color: Color = Bench.Palette.textSecondary
    var fill: Color = Bench.Palette.control

    var body: some View {
        Text(text)
            .font(Bench.Typo.caption)
            .foregroundStyle(color)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.control,
                                         style: .continuous)
                .fill(fill))
            .fixedSize()
    }
}

/// A filter chip with a count: `All 21`, `Recombine 8`. Selected chips invert
/// to the accent.
struct BenchFilterChip: View {
    let label: String
    var count: Int?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(label)
                if let count {
                    Text("\(count)")
                        .foregroundStyle(isSelected ? Bench.Palette.onAccent.opacity(0.65)
                                                    : Bench.Palette.textFaintest)
                }
            }
            .font(isSelected ? Bench.Typo.secondaryEmphasis : Bench.Typo.secondary)
            .foregroundStyle(isSelected ? Bench.Palette.onAccent : Bench.Palette.textSecondary)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.controlLarge,
                                         style: .continuous)
                .fill(isSelected ? Bench.Palette.accent : Bench.Palette.raised))
            .overlay(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.controlLarge,
                                      style: .continuous)
                .strokeBorder(isSelected ? .clear : Bench.Palette.cardStrokeSoft, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.controlLarge,
                                           style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Status

/// The 7 pt dot with a matching glow that heads every status card.
struct StatusDot: View {
    let color: Color
    var size: CGFloat = 7
    var glows = true

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .shadow(color: glows ? color.opacity(0.6) : .clear, radius: 4)
    }
}

/// The indeterminate accent ring used wherever something is running. Drawn
/// rather than `ProgressView` so the stroke width and colour match the design
/// at 13–16 pt, where the system spinner is a different shape entirely.
struct BenchSpinner: View {
    var size: CGFloat = 14
    var color: Color = Bench.Palette.accent
    var lineWidth: CGFloat = 2

    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.45)
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .background(Circle().strokeBorder(color.opacity(0.25), lineWidth: lineWidth))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: 1).repeatForever(autoreverses: false),
                       value: spinning)
            .onAppear { spinning = true }
    }
}

/// Thin progress bar — 3 pt in sidebar cards, 5 pt in download rows.
struct BenchProgressBar: View {
    let fraction: Double
    var height: CGFloat = 3
    var tint: Color = Bench.Palette.accent
    var track: Color = Color.white.opacity(0.08)

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule().fill(tint)
                    .frame(width: geo.size.width * fraction.clamped(to: 0...1))
            }
        }
        .frame(height: height)
    }
}

/// Two-segment bar, used by the storage card to split models from audio.
struct BenchSplitBar: View {
    let segments: [(fraction: Double, color: Color)]
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    Rectangle().fill(segment.color)
                        .frame(width: geo.size.width * segment.fraction.clamped(to: 0...1))
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: height)
        .background(Color.white.opacity(0.08))
        .clipShape(Capsule())
    }
}

// MARK: - Rating

/// Five stars. `onRate` makes it interactive; without it the control is a
/// read-only display (which is what list rows want).
///
/// The stars carry `.fixedSize()` deliberately: in a row where the title has
/// no prompt suffix to give way, a long title used to squeeze this control
/// until the stars wrapped one-per-line and then vanished entirely.
struct RatingStars: View {
    let rating: Int
    var size: CGFloat = 12
    var spacing: CGFloat = 1.5
    var onRate: ((Int) -> Void)?

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(1...5, id: \.self) { index in
                let filled = index <= rating
                Image(systemName: "star.fill")
                    .font(.system(size: size))
                    .foregroundStyle(filled ? Bench.Palette.star : Bench.Palette.starEmpty)
                    .onTapGesture {
                        // Tapping the only filled star clears the rating.
                        onRate?(rating == index ? 0 : index)
                    }
            }
        }
        .lineLimit(1)
        .fixedSize()
        .allowsHitTesting(onRate != nil)
    }
}

// MARK: - Stems

/// The rounded colour bar that identifies a stem. 5–8 pt wide depending on
/// context; always the same colour as that stem's waveform and clip.
struct StemBar: View {
    let kind: String?
    var width: CGFloat = 5
    var height: CGFloat = 18

    var body: some View {
        RoundedRectangle(cornerRadius: Bench.Metrics.Radius.swatch, style: .continuous)
            .fill(Bench.Palette.stem(kind))
            .frame(width: width, height: height)
    }
}

// MARK: - Play button

/// The round transport button. Filled lime when this is the thing currently
/// playing, neutral otherwise — the design uses that contrast to say "you are
/// hearing this row" without a separate indicator.
struct BenchPlayButton: View {
    let isPlaying: Bool
    var isCurrent = false
    var size: CGFloat = 26
    var tint: Color = Bench.Palette.accent
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
                    .fill(isCurrent ? tint : Bench.Palette.control)
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: size * 0.38, weight: .bold))
                    .foregroundStyle(isCurrent ? Bench.Palette.onAccent
                                               : Bench.Palette.textSecondary)
            }
            .frame(width: size, height: size)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The big circular transport button in the player bar — white fill, dark
/// glyph, always high contrast because it is the app's primary control.
struct BenchTransportButton: View {
    let isPlaying: Bool
    var size: CGFloat = 34
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Bench.Palette.textPrimary)
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: size * 0.36, weight: .bold))
                    .foregroundStyle(Bench.Palette.windowBackground)
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Inspector rows

/// `Model    MusicGen Small` — the metadata grid used by every inspector, with
/// a fixed label column so values line up down the panel.
struct BenchInfoRow<Value: View>: View {
    let label: String
    var labelWidth: CGFloat = 86
    @ViewBuilder var value: () -> Value

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(Bench.Typo.secondary)
                .foregroundStyle(Bench.Palette.textMuted)
                .frame(width: labelWidth, alignment: .leading)
            value()
                .font(Bench.Typo.secondary)
                .foregroundStyle(Bench.Palette.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension BenchInfoRow where Value == Text {
    init(_ label: String, _ text: String, mono: Bool = false,
         labelWidth: CGFloat = 86, color: Color = Bench.Palette.textPrimary) {
        self.init(label: label, labelWidth: labelWidth) {
            Text(text)
                .font(mono ? Bench.Typo.mono(12) : Bench.Typo.secondary)
                .foregroundStyle(color)
        }
    }
}

/// `Steps  ──●────  8` — a labelled slider with its value always visible.
/// The 112 pt label column is what makes the parameter panel line up.
struct BenchSliderRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double?
    var tint: Color = Bench.Palette.accent
    var labelWidth: CGFloat = 112
    var valueWidth: CGFloat = 52
    var format: (Double) -> String = { String(format: "%g", $0) }
    var isEnabled = true
    var help: String?
    var onEditingBegan: (() -> Void)?
    var onEditingEnded: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(Bench.Typo.secondary)
                .foregroundStyle(Bench.Palette.textSecondary)
                .frame(width: labelWidth, alignment: .leading)
            BenchSlider(value: $value, range: range, step: step, tint: tint,
                        isEnabled: isEnabled, onEditingBegan: onEditingBegan,
                        onEditingEnded: onEditingEnded)
            BenchValueField(text: format(value), width: valueWidth)
        }
        .opacity(isEnabled ? 1 : 0.45)
        .help(help ?? "")
    }
}

// MARK: - Drop target

/// The dashed "Drop audio here" tile. Lights up accent while a drag is over it.
struct BenchDropTarget: View {
    let title: String
    let subtitle: String
    var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(Bench.Typo.secondaryEmphasis)
                .foregroundStyle(isTargeted ? Bench.Palette.accent
                                            : Bench.Palette.textSecondary)
            Text(subtitle)
                .font(Bench.Typo.small)
                .foregroundStyle(Bench.Palette.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.card,
                                     style: .continuous)
            .fill(isTargeted ? Bench.Palette.accent.opacity(0.06)
                             : Color(hex: 0x131820)))
        .overlay(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.card,
                                  style: .continuous)
            .strokeBorder(isTargeted ? Bench.Palette.accent.opacity(0.5)
                                     : Color.white.opacity(0.12),
                          style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }
}

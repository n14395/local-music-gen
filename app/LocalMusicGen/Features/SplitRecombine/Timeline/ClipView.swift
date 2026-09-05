import SwiftUI

/// One clip on the timeline: a waveform slice, its name, and the mono summary
/// of what the mix will do to it.
///
/// Real views rather than one big Canvas for all clips — clips need selection,
/// hit-testing, context menus and drag handles, none of which a Canvas gives
/// you.
///
/// The fill is the part's stem colour at low alpha with the same hue as its
/// stroke, so a lane reads as one instrument from across the room; the title
/// and waveform are white because they sit *on* that colour and have to stay
/// legible over all seven of them.
struct ClipView: View {
    let clip: WorkbenchModel.Clip
    let plan: MatchPlan?
    let selected: Bool
    let muted: Bool
    let peaks: PeaksStore.Handle?
    /// The transport's Waveforms switch. Off, the clips are plain blocks —
    /// which is what you want when you are placing rather than trimming.
    var showsWaveform = true
    /// Fade lengths as a fraction of the clip's drawn width — the parent owns
    /// the geometry, so it converts.
    var fadeInFraction: Double = 0
    var fadeOutFraction: Double = 0

    private static let radius: CGFloat = 7

    private var tint: Color {
        clip.isMissing ? Bench.Palette.textQuaternary
                       : Bench.Palette.stem(clip.material.kind)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if clip.isMissing {
                    Image(systemName: "questionmark.square.dashed")
                        .font(.system(size: 9))
                        .foregroundStyle(.white)
                }
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(muted ? 0.55 : 1))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let summary = transformSummary {
                    Text(summary)
                        .font(Bench.Typo.mono(9.5, .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.horizontal, 9)
            .padding(.top, 6).padding(.bottom, 3)
            if let peaks, !clip.isMissing, showsWaveform {
                ClipWaveform(handle: peaks,
                             sourceDurationS: clip.sourceDurationS,
                             sectionStartS: clip.sectionStartS,
                             sectionEndS: clip.sectionEndS)
                    .padding(.horizontal, 8).padding(.bottom, 8)
            } else {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Self.radius,
                                     style: .continuous)
            .fill(tint.opacity(clip.isMissing ? 0.16 : 0.32)))
        .overlay(RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
            .strokeBorder(selected ? Bench.Palette.textPrimary
                                   : tint.opacity(0.6),
                          lineWidth: selected ? 1.5 : 1))
        .overlay { fades }
        .clipShape(RoundedRectangle(cornerRadius: Self.radius,
                                    style: .continuous))
        // The parent attaches the drag gesture to this whole view, and
        // `ClipDrag.grab` measures from its leading edge — so the entire
        // rectangle has to take hits, not just the text and the waveform.
        .contentShape(RoundedRectangle(cornerRadius: Self.radius,
                                       style: .continuous))
        .shadow(color: selected ? .black.opacity(0.55) : .clear,
                radius: 13, y: 12)
        .opacity(muted ? 0.45 : 1)
        .help(tooltip)
    }

    private var title: String {
        if clip.isMissing { return "Missing: \(clip.material.sourceTitle)" }
        return clip.sectionLabel.map { "\($0) · \(clip.material.name)" }
            ?? clip.material.name
    }

    /// `AI · −25.0% · +2 st` — everything the render will change about this
    /// clip, in the order the design states it. Nil when it is left alone.
    private var transformSummary: String? {
        var parts: [String] = []
        if clip.material.kind.hasPrefix("layer.") { parts.append("AI") }
        if let tempo = plan?.badges.tempo,
           abs(tempo.stretchRatio - 1) > 0.005 {
            parts.append(String(format: "%+.1f%%",
                                (tempo.stretchRatio - 1) * 100))
        }
        if let shift = plan?.pitchShiftSt, shift != 0 {
            parts.append(String(format: "%+d st", Int(shift)))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Fades are drawn as the ramps they are, so a crossfade is visible rather
    /// than something you have to remember having set.
    @ViewBuilder
    private var fades: some View {
        if fadeInFraction > 0 || fadeOutFraction > 0 {
            GeometryReader { geo in
                Canvas { context, size in
                    var path = Path()
                    if fadeInFraction > 0 {
                        let w = size.width * CGFloat(min(1, fadeInFraction))
                        path.move(to: CGPoint(x: 0, y: size.height))
                        path.addLine(to: CGPoint(x: w, y: 0))
                        path.addLine(to: CGPoint(x: 0, y: 0))
                        path.closeSubpath()
                    }
                    if fadeOutFraction > 0 {
                        let w = size.width * CGFloat(min(1, fadeOutFraction))
                        path.move(to: CGPoint(x: size.width, y: size.height))
                        path.addLine(to: CGPoint(x: size.width - w, y: 0))
                        path.addLine(to: CGPoint(x: size.width, y: 0))
                        path.closeSubpath()
                    }
                    context.fill(path, with: .color(.black.opacity(0.35)))
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .clipShape(RoundedRectangle(cornerRadius: Self.radius,
                                        style: .continuous))
            .allowsHitTesting(false)
        }
    }

    private var tooltip: String {
        var parts = [clip.material.name, clip.material.sourceTitle]
        if let start = clip.sectionStartS, let end = clip.sectionEndS {
            parts.append(String(format: "trimmed %.1f–%.1f s", start, end))
        }
        if clip.fadeInS > 0 || clip.fadeOutS > 0 {
            parts.append(String(format: "fades %.2f/%.2f s",
                                clip.fadeInS, clip.fadeOutS))
        }
        return parts.joined(separator: " · ")
    }
}

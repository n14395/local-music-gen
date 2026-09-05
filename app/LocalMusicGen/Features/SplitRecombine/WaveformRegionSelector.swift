import SwiftUI

/// Pixel↔seconds mapping for the region selector — pure and unit-testable.
struct RegionMath: Equatable {
    var durationS: Double
    var width: CGFloat

    func seconds(atX x: CGFloat) -> Double {
        guard width > 0, durationS > 0 else { return 0 }
        return max(0, min(durationS, Double(x / width) * durationS))
    }

    func x(atSeconds s: Double) -> CGFloat {
        guard durationS > 0 else { return 0 }
        return width * CGFloat(max(0, min(durationS, s)) / durationS)
    }

    /// Clamp a dragged (start, end) pair: ordered, ≥ minLength apart, in range.
    func clamped(start: Double, end: Double,
                 minLength: Double = 0.5) -> (start: Double, end: Double) {
        let lo = max(0, min(start, end))
        let hi = min(durationS, max(start, end))
        if hi - lo < minLength {
            let mid = (lo + hi) / 2
            // Pull the window back off the end rather than truncating it —
            // collapsing a selection at the very end of the file used to yield
            // half the minimum length.
            var s = max(0, mid - minLength / 2)
            s = max(0, min(s, durationS - minLength))
            return (s, min(durationS, s + minLength))
        }
        return (lo, hi)
    }
}

/// A waveform with a draggable selected region (repaint window). The waveform
/// itself is the shared `BenchWaveform`, so a region selector and a list row
/// draw the same bars; the selection is an overlay with two handles.
struct WaveformRegionSelector: View {
    let audioURL: URL
    let cacheURL: URL
    let durationS: Double
    @Binding var startS: Double
    @Binding var endS: Double

    private enum Handle { case start, end }
    @State private var dragging: Handle?

    var body: some View {
        GeometryReader { geo in
            let math = RegionMath(durationS: durationS, width: geo.size.width)
            ZStack(alignment: .topLeading) {
                BenchWaveformLoader(audioURL: audioURL, cacheURL: cacheURL)
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .allowsHitTesting(false)
                // shaded selection
                Rectangle()
                    .fill(Bench.Palette.accent.opacity(0.18))
                    .frame(width: max(0, math.x(atSeconds: endS)
                                      - math.x(atSeconds: startS)))
                    .offset(x: math.x(atSeconds: startS))
                handle(at: math.x(atSeconds: startS), height: geo.size.height)
                handle(at: math.x(atSeconds: endS), height: geo.size.height)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let t = math.seconds(atX: value.location.x)
                    if dragging == nil {
                        // grab whichever handle is nearer
                        dragging = abs(t - startS) <= abs(t - endS)
                            ? .start : .end
                    }
                    var s = startS, e = endS
                    if dragging == .start { s = t } else { e = t }
                    (startS, endS) = math.clamped(start: s, end: e)
                }
                .onEnded { _ in dragging = nil })
        }
        .frame(height: 56)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Bench.Palette.well))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            Text(String(format: "%.1f S – %.1f S", startS, endS))
                .metaLine(Bench.Palette.textMuted)
                .padding(6)
        }
    }

    private func handle(at x: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Bench.Palette.accent)
            .frame(width: 4, height: height)
            .offset(x: x - 2)
    }
}

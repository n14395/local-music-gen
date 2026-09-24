// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

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

    /// The horizontal padding under the waveform, which the region math has
    /// to share.
    ///
    /// `BenchWaveform` draws edge to edge inside whatever width it is given,
    /// and it is given the well minus this inset — so mapping 0…duration
    /// across the *full* width put the shading and the handles 8 pt right of
    /// the audio at the head and 8 pt left of it at the tail. On a 60 s track
    /// in a 400 pt well that is over a second, while the readout underneath
    /// printed the correct number: the picture and the text disagreed.
    private static let inset: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            let inset = Self.inset
            let math = RegionMath(durationS: durationS,
                                  width: max(0, geo.size.width - inset * 2))
            ZStack(alignment: .topLeading) {
                BenchWaveformLoader(audioURL: audioURL, cacheURL: cacheURL)
                    .padding(.horizontal, inset).padding(.vertical, 6)
                    .allowsHitTesting(false)
                // shaded selection
                Rectangle()
                    .fill(Bench.Palette.accent.opacity(0.18))
                    .frame(width: max(0, math.x(atSeconds: endS)
                                      - math.x(atSeconds: startS)))
                    .offset(x: inset + math.x(atSeconds: startS))
                handle(at: inset + math.x(atSeconds: startS),
                       height: geo.size.height)
                handle(at: inset + math.x(atSeconds: endS),
                       height: geo.size.height)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let t = math.seconds(atX: value.location.x - inset)
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

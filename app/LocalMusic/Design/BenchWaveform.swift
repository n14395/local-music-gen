import SwiftUI

/// The waveform the redesign puts in *every* row.
///
/// Drawn as discrete centred bars with a 1 pt gap and rounded caps, not as a
/// filled min/max envelope: at row height (24–26 pt) an envelope reads as a
/// solid blob, and the whole point of putting a waveform in every row is that
/// you can tell two takes apart at a glance. Bars survive that size.
///
/// One magnitude per bin — `max(|min|, |max|)` — because the design's bars are
/// symmetric about the centre line.
struct BenchWaveform: View {
    let peaks: WaveformExtractor.Peaks?
    var playedFraction: Double = 0
    var tint: Color = Bench.Palette.accent
    var rest: Color = Color.white.opacity(0.13)
    /// Target bar pitch in points. The design draws roughly 96 bars across a
    /// row and 200+ across a hero strip; deriving the count from width keeps
    /// bar weight constant instead of stretching with the container.
    var barPitch: CGFloat = 3
    var minBarHeight: CGFloat = 1.5
    var onSeek: ((Double) -> Void)?

    var body: some View {
        GeometryReader { geo in
            Canvas(rendersAsynchronously: false) { context, size in
                draw(in: context, size: size)
            }
            .contentShape(Rectangle())
            .gesture(seekGesture(width: geo.size.width))
        }
    }

    private func seekGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0).onChanged { value in
            guard let onSeek, width > 0 else { return }
            onSeek(Double(value.location.x / width).clamped(to: 0...1))
        }
    }

    private func draw(in context: GraphicsContext, size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let bars = max(1, Int(size.width / max(barPitch, 1)))
        let pitch = size.width / CGFloat(bars)
        let barWidth = max(1, pitch - 1)
        let mid = size.height / 2
        let playedX = size.width * playedFraction.clamped(to: 0...1)
        let radius = min(1, barWidth / 2)

        var played = Path()
        var unplayed = Path()

        for i in 0..<bars {
            let magnitude = amplitude(bar: i, of: bars)
            let height = max(minBarHeight, CGFloat(magnitude) * size.height * 0.96)
            let x = CGFloat(i) * pitch
            let rect = CGRect(x: x, y: mid - height / 2, width: barWidth, height: height)
            let path = Path(roundedRect: rect, cornerRadius: radius)
            if x + barWidth / 2 <= playedX { played.addPath(path) } else { unplayed.addPath(path) }
        }

        context.fill(unplayed, with: .color(rest))
        if playedFraction > 0 { context.fill(played, with: .color(tint)) }
    }

    /// Resample the cached peaks (a fixed 2000 bins per file) down to the bar
    /// count this width wants, taking the max over each span so transients
    /// survive the downsample instead of averaging away.
    private func amplitude(bar: Int, of bars: Int) -> Float {
        guard let peaks, !peaks.maxs.isEmpty else { return 0.12 }
        let bins = peaks.maxs.count
        let lo = bins * bar / bars
        let hi = max(lo + 1, bins * (bar + 1) / bars)
        var peak: Float = 0
        for i in lo..<min(hi, bins) {
            peak = max(peak, max(abs(peaks.maxs[i]), abs(peaks.mins[i])))
        }
        return peak
    }
}

/// `BenchWaveform` that loads its own peaks. This is the row-level strip —
/// one file, one loader. Timeline clips share peaks through `PeaksStore`
/// instead, so forty clips over six sources open six files.
struct BenchWaveformLoader: View {
    let audioURL: URL
    let cacheURL: URL
    var playedFraction: Double = 0
    var tint: Color = Bench.Palette.accent
    var rest: Color = Color.white.opacity(0.13)
    var barPitch: CGFloat = 3
    var onSeek: ((Double) -> Void)?

    @State private var peaks: WaveformExtractor.Peaks?
    @State private var loaded = false

    var body: some View {
        ZStack {
            BenchWaveform(peaks: peaks, playedFraction: playedFraction, tint: tint,
                          rest: rest, barPitch: barPitch, onSeek: onSeek)
                // Before the peaks arrive the bars are a flat placeholder rather
                // than a spinner: a row that pops from spinner to waveform makes
                // a list of forty rows flicker on every scroll.
                .opacity(loaded ? 1 : 0.35)
        }
        .task(id: audioURL) {
            loaded = false
            peaks = try? await WaveformExtractor.shared
                .peaks(for: audioURL, cacheURL: cacheURL)
            loaded = true
        }
    }
}

/// The dark inset the design puts hero waveforms in (`#0D1013`, r10).
///
/// No playhead line. It used to draw one over the waveform inside it, which
/// said the same thing twice: `BenchWaveform` already tints every bar left of
/// the play position, so the boundary between the tinted bars and the grey
/// ones *is* the playhead — drawn at bar resolution, where a 1.5 pt rule
/// landing mid-bar only ever disagreed with it.
///
/// This is not the timeline's playhead, which stays: that one is a control
/// (draggable, and what "play from the playhead" plays from) rather than a
/// readout of where playback has got to.
struct BenchWaveformWell<Content: View>: View {
    var height: CGFloat = 96
    var padding: CGFloat = 11
    var radius: CGFloat = 10
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Bench.Palette.well))
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

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
    /// What to file this strip's resampled bars under, so the same track drawn
    /// again — next tick, next scroll, next screen — reuses them. Nil for a
    /// caller with no stable name for its material; see `WaveformBars`.
    var barsID: String?
    var onSeek: ((Double) -> Void)?

    var body: some View {
        GeometryReader { geo in
            // Resolved here rather than inside the draw, so a redraw that
            // changed neither the width nor the peaks — a transport tick, a
            // selection ring, a republished list — reads the answer instead of
            // working it out again. See `WaveformBars`.
            let bars = WaveformBars.bars(
                id: barsID, count: Self.barCount(width: geo.size.width,
                                                 pitch: barPitch),
                peaks: peaks)
            let canvas = Canvas(rendersAsynchronously: false) { context, size in
                draw(bars, in: context, size: size)
            }
            // Only where there is somewhere to seek to. A hit region and a
            // gesture that does nothing still swallow the click, which in a
            // row that is itself clickable means a dead stripe down it.
            if let onSeek {
                canvas
                    .contentShape(Rectangle())
                    // High priority because the waveform is usually *inside*
                    // something clickable — a selectable row in the library, a
                    // pick button in the material sheet — and scrubbing has to
                    // beat that reliably rather than by whichever gesture
                    // SwiftUI happens to resolve first. Nothing else in the app
                    // wants a click on a waveform to mean anything else.
                    .highPriorityGesture(seekGesture(width: geo.size.width,
                                                     onSeek: onSeek))
            } else {
                canvas
            }
        }
    }

    /// How many bars a strip this wide draws. The design's bar pitch is fixed,
    /// so the count follows the width rather than the other way round.
    static func barCount(width: CGFloat, pitch: CGFloat) -> Int {
        max(1, Int(width / max(pitch, 1)))
    }

    private func seekGesture(width: CGFloat,
                             onSeek: @escaping (Double) -> Void) -> some Gesture {
        DragGesture(minimumDistance: 0).onChanged { value in
            guard width > 0 else { return }
            onSeek(Double(value.location.x / width).clamped(to: 0...1))
        }
    }

    private func draw(_ bars: [Float], in context: GraphicsContext,
                      size: CGSize) {
        guard size.width > 0, size.height > 0, !bars.isEmpty else { return }
        let count = bars.count
        let pitch = size.width / CGFloat(count)
        let barWidth = max(1, pitch - 1)
        let mid = size.height / 2
        let playedX = size.width * playedFraction.clamped(to: 0...1)
        let radius = min(1, barWidth / 2)

        var played = Path()
        var unplayed = Path()

        for i in 0..<count {
            let height = max(minBarHeight,
                             CGFloat(bars[i]) * size.height * 0.96)
            let x = CGFloat(i) * pitch
            let rect = CGRect(x: x, y: mid - height / 2, width: barWidth, height: height)
            let path = Path(roundedRect: rect, cornerRadius: radius)
            if x + barWidth / 2 <= playedX { played.addPath(path) } else { unplayed.addPath(path) }
        }

        context.fill(unplayed, with: .color(rest))
        if playedFraction > 0 { context.fill(played, with: .color(tint)) }
    }
}

/// One bar magnitude per bar, resampled from a track's cached peaks and kept.
///
/// The strip in a library row is redrawn far more often than it changes: the
/// transport ticks four times a second, a selection ring lands, the list
/// republishes after a rating — and each of those used to walk all 2000 cached
/// bins again to produce the same hundred-odd numbers, once per visible row.
/// The answer depends on nothing but the peaks and how many bars fit, so it is
/// worked out once and read from then on.
///
/// Keyed on the caller's id and the bar count, and *checked* against the peaks
/// it was made from rather than trusted: `Array`'s `==` returns in constant
/// time when both sides share a buffer, which is the case every time the same
/// cached peaks come round again. So a hit costs a dictionary lookup, and
/// bytes changing under a path — an apply, a revert — recompute rather than
/// serve the drawing of a file that no longer exists.
@MainActor
enum WaveformBars {
    /// Under a real magnitude, so an unloaded strip reads as a flat line
    /// rather than as silence.
    static let placeholder: Float = 0.12

    private struct Key: Hashable {
        var id: String
        var count: Int
    }

    private struct Entry {
        var peaks: WaveformExtractor.Peaks
        var bars: [Float]
    }

    /// Enough for every row, clip and hero strip a screen can hold, at several
    /// widths each. Past it the memo starts over rather than growing for the
    /// rest of the session.
    private static let capacity = 512
    private static var entries: [Key: Entry] = [:]

    /// The bars for one strip. `id` is what makes an answer reusable — a
    /// caller with nothing stable to name its material by passes nil and gets
    /// the arithmetic unmemoised, which is what every draw used to do.
    static func bars(id: String?, count: Int,
                     peaks: WaveformExtractor.Peaks?) -> [Float] {
        guard let peaks, !peaks.maxs.isEmpty else {
            return [Float](repeating: placeholder, count: max(1, count))
        }
        guard let id else { return resample(peaks, to: count) }
        let key = Key(id: id, count: count)
        if let hit = entries[key], hit.peaks == peaks { return hit.bars }
        let bars = resample(peaks, to: count)
        if entries.count >= capacity { entries.removeAll(keepingCapacity: true) }
        entries[key] = Entry(peaks: peaks, bars: bars)
        return bars
    }

    /// Resample the cached peaks (a fixed 2000 bins per file) down to the bar
    /// count this width wants, taking the max over each span so transients
    /// survive the downsample instead of averaging away.
    ///
    /// One magnitude per bin — `max(|min|, |max|)` — because the design's bars
    /// are symmetric about the centre line.
    static func resample(_ peaks: WaveformExtractor.Peaks,
                         to count: Int) -> [Float] {
        let bins = peaks.maxs.count
        let count = max(1, count)
        var bars = [Float](repeating: 0, count: count)
        for bar in 0..<count {
            let lo = bins * bar / count
            let hi = min(max(lo + 1, bins * (bar + 1) / count), bins)
            var peak: Float = 0
            for i in lo..<hi {
                peak = max(peak, max(abs(peaks.maxs[i]), abs(peaks.mins[i])))
            }
            bars[bar] = peak
        }
        return bars
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
            BenchWaveform(peaks: peaks, playedFraction: playedFraction,
                          tint: tint, rest: rest, barPitch: barPitch,
                          // The peaks file's path names the material: it is
                          // one per track, it is what the extractor keys its
                          // own caches on, and it survives this view being
                          // rebuilt — which a row scrolled out and back in is.
                          barsID: cacheURL.path, onSeek: onSeek)
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

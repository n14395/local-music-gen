import CoreGraphics
import Foundation

/// Pixels ↔ seconds ↔ beats ↔ bars for the workbench timeline — pure and
/// unit-testable, the same posture as `RegionMath`.
///
/// Everything is expressed against the TARGET grid, because that is the grid
/// `offset_s = offsetBeats × 60/targetBpm` lands on (JobsStore.planMix).
struct TimelineMath: Equatable {
    var bpm: Double
    var beatsPerBar: Double
    var pxPerSecond: CGFloat

    static let minZoom: CGFloat = 2
    static let maxZoom: CGFloat = 200

    init(bpm: Double?, beatsPerBar: Double = 4, pxPerSecond: CGFloat = 20) {
        // A timeline with no analyzed material still has to draw something;
        // 120 is the same fallback the preview uses.
        self.bpm = (bpm ?? 120) > 0 ? (bpm ?? 120) : 120
        self.beatsPerBar = beatsPerBar > 0 ? beatsPerBar : 4
        self.pxPerSecond = pxPerSecond
    }

    // MARK: conversions

    func seconds(beats: Double) -> Double { beats * 60.0 / bpm }
    func beats(seconds: Double) -> Double { seconds * bpm / 60.0 }
    func beats(bars: Double) -> Double { bars * beatsPerBar }
    func bars(beats: Double) -> Double { beats / beatsPerBar }

    func x(beats: Double) -> CGFloat { CGFloat(seconds(beats: beats)) * pxPerSecond }
    func width(beats: Double) -> CGFloat { max(0, x(beats: beats)) }

    func beats(atX x: CGFloat) -> Double {
        guard pxPerSecond > 0 else { return 0 }
        return beats(seconds: Double(x / pxPerSecond))
    }

    var pxPerBeat: CGFloat { x(beats: 1) }

    // MARK: snapping & clamping

    enum Snap: String, CaseIterable, Identifiable {
        case bar = "Bar"
        case beat = "Beat"
        case off = "Off"
        var id: String { rawValue }
    }

    func snapped(_ beats: Double, to snap: Snap) -> Double {
        switch snap {
        case .off: return beats
        case .beat: return (beats).rounded()
        case .bar: return (beats / beatsPerBar).rounded() * beatsPerBar
        }
    }

    /// The engine rejects a negative `offset_s` outright, so nothing may leave
    /// the timeline below zero.
    static func clampStart(_ beats: Double) -> Double { max(0, beats) }

    /// Shift every start so the earliest sits at zero, preserving the spacing
    /// the user drew. This is the affordance for "make room at the front" —
    /// negative offsets are not an option (see `clampStart`).
    static func normalizedToZero(_ starts: [Double]) -> [Double] {
        guard let lowest = starts.min(), lowest < 0 else { return starts }
        return starts.map { $0 - lowest }
    }

    // MARK: zoom

    static func fitZoom(contentSeconds: Double, width: CGFloat) -> CGFloat {
        guard contentSeconds > 0, width > 0 else { return 20 }
        return clampZoom(width / CGFloat(contentSeconds))
    }

    static func clampZoom(_ zoom: CGFloat) -> CGFloat {
        min(maxZoom, max(minZoom, zoom))
    }

    // MARK: grid

    /// Bar numbers and their x positions covering a pixel window, so the ruler
    /// and grid only draw what is on screen.
    func barTicks(fromX: CGFloat, toX: CGFloat) -> [(bar: Int, x: CGFloat)] {
        let barWidth = x(beats: beatsPerBar)
        guard barWidth > 0.5, toX > fromX else { return [] }
        let first = max(0, Int((fromX / barWidth).rounded(.down)))
        let last = Int((toX / barWidth).rounded(.up))
        guard last >= first else { return [] }
        return (first...last).map { ($0 + 1, CGFloat($0) * barWidth) }
    }

    // MARK: layout

    struct Placement: Equatable {
        var id: String
        var laneIndex: Int
        var startBeats: Double
        var lengthBeats: Double
    }

    /// Beat extent of the arrangement plus a little air, so the scroll view can
    /// reach past the last clip.
    static func contentBeats(_ placements: [Placement],
                             trailingBars: Double = 2,
                             beatsPerBar: Double = 4) -> Double {
        let end = placements.map { $0.startBeats + $0.lengthBeats }.max() ?? 0
        return end + trailingBars * beatsPerBar
    }

    /// Clip rectangles. One place computes geometry; the `Layout` just places
    /// what this returns.
    func frames(_ placements: [Placement],
                laneHeight: CGFloat, laneSpacing: CGFloat = 0,
                clipInset: CGFloat = 2) -> [(id: String, rect: CGRect)] {
        placements.map { p in
            let originX = x(beats: p.startBeats)
            let originY = CGFloat(p.laneIndex) * (laneHeight + laneSpacing)
            return (p.id, CGRect(x: originX, y: originY + clipInset,
                                 width: max(6, width(beats: p.lengthBeats)),
                                 height: laneHeight - clipInset * 2))
        }
    }

    /// Beat ranges where clips in one lane cover each other. Overlap is legal
    /// (the engine sums), but it is worth drawing — an accidental overlap and a
    /// deliberate crossfade look identical until you mark them.
    static func overlaps(inLane clips: [(start: Double, length: Double)])
        -> [(start: Double, end: Double)] {
        let spans = clips.map { ($0.start, $0.start + $0.length) }
            .sorted { $0.0 < $1.0 }
        var out: [(start: Double, end: Double)] = []
        for i in spans.indices.dropLast() {
            for j in (i + 1)..<spans.count {
                let lo = max(spans[i].0, spans[j].0)
                let hi = min(spans[i].1, spans[j].1)
                if hi > lo { out.append((lo, hi)) }
            }
        }
        return out
    }

    // MARK: trim

    /// Clamp a dragged trim inside the source. Delegates to `RegionMath` so
    /// there is one clamp in the app, not two that drift apart.
    static func trimmed(startS: Double, endS: Double, sourceDurationS: Double,
                        minLengthS: Double = 0.25) -> (start: Double, end: Double) {
        RegionMath(durationS: sourceDurationS, width: 1)
            .clamped(start: startS, end: endS, minLength: minLengthS)
    }
}

/// Which slice of a whole-file peak cache a clip shows, and whether the cache
/// is fine enough for the current zoom.
enum PeakSlice {
    /// Bin window covering [startS, endS) of a file. Always non-empty so a
    /// degenerate clip still draws something.
    static func range(startS: Double, endS: Double, durationS: Double,
                      binCount: Int) -> Range<Int> {
        guard binCount > 0 else { return 0..<0 }
        guard durationS > 0 else { return 0..<binCount }
        let lo = max(0, min(binCount - 1,
                            Int((startS / durationS) * Double(binCount))))
        let hi = max(lo + 1, min(binCount,
                                 Int((endS / durationS * Double(binCount)).rounded(.up))))
        return lo..<hi
    }

    /// On-screen pixels per cached bin — above ~2 the waveform reads as blocks.
    static func pxPerBin(sourceDurationS: Double, pxPerSecond: CGFloat,
                         binCount: Int) -> CGFloat {
        guard binCount > 0, sourceDurationS > 0 else { return 0 }
        return pxPerSecond * CGFloat(sourceDurationS) / CGFloat(binCount)
    }

    /// Zoom beyond which the cached peaks are visibly blocky. The timeline caps
    /// zoom here rather than drawing a lie at high magnification.
    static func usefulZoomCap(sourceDurationS: Double, binCount: Int,
                              maxPxPerBin: CGFloat = 2) -> CGFloat {
        guard sourceDurationS > 0 else { return TimelineMath.maxZoom }
        let cap = maxPxPerBin * CGFloat(binCount) / CGFloat(sourceDurationS)
        return min(TimelineMath.maxZoom, max(TimelineMath.minZoom, cap))
    }
}

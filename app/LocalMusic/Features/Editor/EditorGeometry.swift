import CoreGraphics
import Foundation

/// Pixels ↔ seconds for the Editor's main well, plus snapping — pure and
/// unit-testable, the same posture as `TimelineMath` and `RegionMath`.
///
/// Everything is in *edited-timeline* seconds (post-cuts, pre-speed): the
/// well draws the program's result, so its geometry lives in the program's
/// time base. Grid candidates arrive already mapped from source time by
/// `EditProgram.sourceToTimeline`.
struct EditorGeometry: Equatable {
    /// Left edge of the view, in timeline seconds.
    var visibleStartS: Double
    var pxPerSecond: CGFloat
    var width: CGFloat
    var durationS: Double

    static let maxZoom: CGFloat = 400

    /// Fit-to-width is the zoom floor: zooming out past "the whole track in
    /// view" only adds dead space.
    static func fitZoom(durationS: Double, width: CGFloat) -> CGFloat {
        guard durationS > 0, width > 0 else { return 20 }
        return width / CGFloat(durationS)
    }

    static func clampZoom(_ zoom: CGFloat, durationS: Double,
                          width: CGFloat) -> CGFloat {
        min(maxZoom, max(fitZoom(durationS: durationS, width: width), zoom))
    }

    var visibleSeconds: Double {
        pxPerSecond > 0 ? Double(width / pxPerSecond) : 0
    }

    var visibleEndS: Double { visibleStartS + visibleSeconds }

    func x(at seconds: Double) -> CGFloat {
        CGFloat(seconds - visibleStartS) * pxPerSecond
    }

    func seconds(atX x: CGFloat) -> Double {
        guard pxPerSecond > 0 else { return 0 }
        return (visibleStartS + Double(x / pxPerSecond))
            .clamped(to: 0...max(0, durationS))
    }

    /// Keep the viewport inside the track, shrinking to the front when the
    /// track is shorter than the window.
    func clampedStart(_ start: Double) -> Double {
        let maxStart = max(0, durationS - visibleSeconds)
        return start.clamped(to: 0...maxStart)
    }

    /// The viewport after the well is laid out at a new width.
    ///
    /// Zoom is stored as pixels-per-second, so leaving it alone across a
    /// resize means the *time* in view changes with the window: widening the
    /// window scrolled more of the track into the well and the overview
    /// strip's window grew under the pointer, which reads as the editor
    /// moving your view rather than the window changing size.
    ///
    /// So the seconds are what is held and the scale is what gives: the same
    /// span stays in the well, drawn larger or smaller. Both limits still
    /// apply — a window widened far enough to demand more than `maxZoom`
    /// takes the extra seconds it cannot magnify away, and `clampedStart`
    /// keeps the result inside the track.
    func resized(toWidth newWidth: CGFloat) -> EditorGeometry {
        guard newWidth > 0, width > 0, pxPerSecond > 0 else {
            var out = self
            out.width = newWidth
            return out
        }
        let span = visibleSeconds
        var out = self
        out.width = newWidth
        out.pxPerSecond = Self.clampZoom(newWidth / CGFloat(max(0.001, span)),
                                         durationS: durationS, width: newWidth)
        out.visibleStartS = out.clampedStart(visibleStartS)
        return out
    }

    /// A zoom change that keeps the moment under `anchorX` under it — the
    /// difference between zooming *into* the playhead and lurching past it.
    func zoomed(to newZoom: CGFloat, anchorX: CGFloat) -> EditorGeometry {
        let anchorSeconds = visibleStartS + Double(anchorX / max(1, pxPerSecond))
        var out = self
        out.pxPerSecond = Self.clampZoom(newZoom, durationS: durationS,
                                         width: width)
        out.visibleStartS = out.clampedStart(
            anchorSeconds - Double(anchorX / out.pxPerSecond))
        return out
    }

    /// The on-screen span of a time range, clipped to what is actually in
    /// view: `(x, width)` for a frame, or nil when none of it is visible.
    ///
    /// Not the same thing as two calls to `x(at:)`, and the difference is a
    /// real bug rather than a nicety. A block drawn as
    /// `.frame(width: x(at: end) - x(at: start)).offset(x: x(at: start))`
    /// *looks* right, because the offset cancels the overhang — but the frame
    /// is still as wide as the whole range, most of it off-screen, and a
    /// SwiftUI stack sizes itself to its widest child. One section a minute
    /// long, zoomed in, was enough to make the editor's whole column wider
    /// than its well and shove the waveform sideways.
    func clipped(from startS: Double, to endS: Double)
        -> (x: CGFloat, width: CGFloat)? {
        guard width > 0 else { return nil }
        let lo = max(0, x(at: min(startS, endS)))
        let hi = min(width, x(at: max(startS, endS)))
        guard hi > lo else { return nil }
        return (lo, hi - lo)
    }

    // MARK: viewport edges

    /// Which side of the overview strip's window is being dragged.
    enum ViewportEdge: Equatable {
        case start, end
    }

    /// The viewport after dragging one of its edges to `seconds`.
    ///
    /// The dragged edge follows the pointer and the other one does not move —
    /// that is the whole difference between resizing a window and sliding it,
    /// and it is what makes the gesture read as zoom rather than scroll. The zoom
    /// is then simply whatever makes that window fill the well.
    ///
    /// Both limits are the ones the rest of the editor already keeps: the
    /// window cannot be squeezed past `maxZoom`, and it cannot be stretched
    /// past the whole track, because zooming out beyond fit only adds dead
    /// space. When a drag hits either limit the dragged edge stops and the
    /// pinned one still does not move.
    func draggingEdge(_ edge: ViewportEdge, to seconds: Double) -> EditorGeometry {
        guard width > 0, durationS > 0 else { return self }
        // The narrowest window `maxZoom` allows, and the widest the track
        // does. On a track shorter than the first, the two invert — hence the
        // ordered clamp below rather than a range literal, which would trap.
        let minSpan = Double(width / Self.maxZoom)
        let maxSpan = durationS
        var out = self

        switch edge {
        case .start:
            let pinned = visibleEndS.clamped(to: 0...durationS)
            let start = Self.clamp(seconds, pinned - maxSpan, pinned - minSpan)
            out.pxPerSecond = Self.clampZoom(width / CGFloat(max(0.001, pinned - start)),
                                             durationS: durationS, width: width)
            // Recomputed from the clamped zoom, not from `start`: if the zoom
            // hit a limit the two disagree, and the edge that must win is the
            // one the pointer is not holding.
            out.visibleStartS = out.clampedStart(pinned - out.visibleSeconds)
        case .end:
            let pinned = visibleStartS.clamped(to: 0...durationS)
            let end = Self.clamp(seconds, pinned + minSpan, pinned + maxSpan)
            out.pxPerSecond = Self.clampZoom(width / CGFloat(max(0.001, end - pinned)),
                                             durationS: durationS, width: width)
            out.visibleStartS = out.clampedStart(pinned)
        }
        return out
    }

    /// `clamped(to:)` on an ordered pair, tolerating a reversed one. A track
    /// shorter than the minimum window really does produce lower > upper, and
    /// a `ClosedRange` built from that traps.
    private static func clamp(_ value: Double, _ a: Double, _ b: Double) -> Double {
        value.clamped(to: min(a, b)...max(a, b))
    }

    // MARK: snap

    enum SnapMode: String, CaseIterable, Identifiable, Codable {
        case off, beats, bars, sections, zeroX
        var id: String { rawValue }

        var label: String {
            switch self {
            case .off: "Off"
            case .beats: "Beats"
            case .bars: "Bars"
            case .sections: "Sections"
            case .zeroX: "Zero-x"
            }
        }
    }

    /// Snap `t` to the nearest candidate within `radiusPx` on screen, or
    /// return it untouched. Screen-radius rather than time-radius so snap
    /// feels the same at every zoom.
    func snapped(_ t: Double, candidates: [Double],
                 radiusPx: CGFloat = 8) -> Double {
        guard pxPerSecond > 0, !candidates.isEmpty else { return t }
        let radius = Double(radiusPx / pxPerSecond)
        var best = t
        var bestDistance = Double.infinity
        for candidate in candidates {
            let distance = abs(candidate - t)
            if distance < bestDistance {
                bestDistance = distance
                best = candidate
            }
        }
        return bestDistance <= radius ? best : t
    }
}

/// The source's musical landmarks, mapped onto the edited timeline. Built
/// once per program change, read by the ruler, the grid, the section chips
/// and the snap.
struct EditorGrid: Equatable {
    /// (source bar number, timeline seconds) — numbering stays source-
    /// anchored, so a cut reads as a jump in the numbers, which is the truth.
    var barTicks: [BarTick] = []
    var beats: [Double] = []
    var sections: [SectionSpan] = []

    /// Nothing mapped — either there is no analysis, or the grid has not been
    /// built yet. `EditorStore.rebuild` uses it to tell "a gain edit, so the
    /// grid cannot have moved" from "first build".
    var isEmpty: Bool {
        barTicks.isEmpty && beats.isEmpty && sections.isEmpty
    }

    struct BarTick: Equatable {
        var number: Int
        var timelineS: Double
    }

    /// A structure span that survived the edit (clamped to what did).
    struct SectionSpan: Equatable {
        var label: String
        var group: String
        var startS: Double
        var endS: Double
    }

    static func make(analysis: AnalysisPayload?,
                     segments: [EditSegment]) -> EditorGrid {
        var grid = EditorGrid()
        guard let analysis else { return grid }
        for beat in analysis.beats ?? [] {
            if let t = EditProgram.sourceToTimeline(beat, in: segments) {
                grid.beats.append(t)
            }
        }
        for (index, downbeat) in (analysis.downbeats ?? []).enumerated() {
            if let t = EditProgram.sourceToTimeline(downbeat, in: segments) {
                grid.barTicks.append(BarTick(number: index + 1, timelineS: t))
            }
        }
        grid.beats = collapse(grid.beats.sorted())
        // A cut lands two downbeats on the same instant: the one that was
        // deleted (the last kept moment) and the one that now plays there.
        // What you hear from that instant is the later bar, so it is the one
        // the ruler keeps — otherwise the numbers claim material that is gone.
        grid.barTicks.sort { $0.timelineS < $1.timelineS }
        var deduped: [BarTick] = []
        for tick in grid.barTicks {
            if let last = deduped.last,
               abs(last.timelineS - tick.timelineS) < 1e-6 {
                deduped[deduped.count - 1] = tick
            } else {
                deduped.append(tick)
            }
        }
        grid.barTicks = deduped
        let duration = EditProgram.timelineDuration(segments)
        for section in analysis.sections ?? [] {
            // A section survives as the mapped extent of whatever part of it
            // is still present. Probe its edges inward: the exact edge may
            // have been the cut point itself.
            let step = max(0.05, (section.endS - section.startS) / 40)
            var mappedStart: Double?
            var mappedEnd: Double?
            var probe = section.startS
            while probe <= section.endS {
                if let t = EditProgram.sourceToTimeline(probe, in: segments) {
                    mappedStart = mappedStart.map { min($0, t) } ?? t
                    mappedEnd = mappedEnd.map { max($0, t) } ?? t
                }
                probe += step
            }
            if let start = mappedStart, let end = mappedEnd, end - start > 0.2 {
                grid.sections.append(SectionSpan(
                    label: (section.label ?? section.group ?? "")
                        .uppercased(),
                    group: section.group ?? section.label ?? "",
                    startS: max(0, start),
                    endS: min(duration, end)))
            }
        }
        return grid
    }

    /// Beats that landed on the same instant through a cut collapse to one.
    private static func collapse(_ values: [Double]) -> [Double] {
        var out: [Double] = []
        for value in values {
            if let last = out.last, abs(last - value) < 1e-6 { continue }
            out.append(value)
        }
        return out
    }

    /// What the snap control snaps to in each mode. Section edges include
    /// both bounds, so "snap to section" lands a selection exactly on one.
    func candidates(for mode: EditorGeometry.SnapMode) -> [Double] {
        switch mode {
        case .off, .zeroX: return []
        case .beats: return beats
        case .bars: return barTicks.map(\.timelineS)
        case .sections:
            return sections.flatMap { [$0.startS, $0.endS] }
        }
    }
}

/// Sample-level helpers that stay pure: the store reads a small window of
/// samples around a point; this finds the crossing.
enum ZeroCross {
    /// Index of the sample nearest `center` where the signal crosses zero,
    /// or nil if the window never does.
    static func nearest(in samples: [Float], around center: Int) -> Int? {
        guard samples.count >= 2 else { return nil }
        let center = center.clamped(to: 0...(samples.count - 1))
        var best: Int?
        var bestDistance = Int.max
        for i in 0..<(samples.count - 1) {
            let a = samples[i], b = samples[i + 1]
            guard a == 0 || (a < 0) != (b < 0) else { continue }
            let distance = abs(i - center)
            if distance < bestDistance {
                bestDistance = distance
                best = i
            }
        }
        return best
    }
}

/// Clock formatting shared by every Editor readout: `0:38.42`.
enum EditorClock {
    static func full(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00.00" }
        let minutes = Int(seconds) / 60
        let rest = seconds - Double(minutes * 60)
        return String(format: "%d:%05.2f", minutes, rest)
    }

    static func short(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

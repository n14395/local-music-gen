import CoreGraphics
import Foundation

/// What a drag on a clip means, resolved from where it started and how far it
/// has moved. Pure so the gesture arithmetic is testable — the view only has to
/// decide when to commit.
enum ClipDrag {
    /// Which handle a press at `x` grabs. Handles shrink with the clip so a
    /// narrow clip can still be moved rather than being all handle.
    enum Grab: Equatable { case body, leadingEdge, trailingEdge }

    static func grab(atX x: CGFloat, width: CGFloat,
                     handleWidth: CGFloat = 8) -> Grab {
        let handle = min(handleWidth, max(3, width / 4))
        if x <= handle { return .leadingEdge }
        if x >= width - handle { return .trailingEdge }
        return .body
    }

    /// New start for a moved clip: snapped, then clamped — in that order, so a
    /// snap can never push a clip before zero.
    static func movedStart(originalBeats: Double, deltaX: CGFloat,
                           math: TimelineMath, snap: TimelineMath.Snap)
        -> Double {
        let moved = originalBeats + math.beats(atX: deltaX)
        return TimelineMath.clampStart(math.snapped(moved, to: snap))
    }

    /// Trim from a handle drag, in SOURCE seconds.
    ///
    /// Dragging the leading edge shortens the head of the clip, which must also
    /// push its start on the timeline by the same amount — otherwise the audio
    /// slides against everything else, which is never what trimming means.
    struct Trim: Equatable {
        var sectionStartS: Double
        var sectionEndS: Double
        var startBeats: Double
    }

    static func trim(grab: Grab, deltaX: CGFloat, math: TimelineMath,
                     clipStartBeats: Double,
                     sectionStartS: Double?, sectionEndS: Double?,
                     sourceDurationS: Double,
                     stretchFactor: Double) -> Trim? {
        guard grab != .body, sourceDurationS > 0 else { return nil }
        let currentStart = sectionStartS ?? 0
        let currentEnd = sectionEndS ?? sourceDurationS
        // Pixels are target-time; the section is source-time. One conversion,
        // and it has to include the stretch or the edge runs away from the
        // pointer on stretched clips.
        let deltaSourceS = Double(deltaX / math.pxPerSecond) * stretchFactor

        var start = currentStart
        var end = currentEnd
        switch grab {
        case .leadingEdge: start += deltaSourceS
        case .trailingEdge: end += deltaSourceS
        case .body: break
        }
        let clamped = TimelineMath.trimmed(startS: start, endS: end,
                                           sourceDurationS: sourceDurationS)
        // Both bounds always: planMix only emits a section when start AND end
        // are set, so a head-only trim would silently vanish on the wire.
        let headMovedS = (clamped.start - currentStart) / stretchFactor
        let startBeats = grab == .leadingEdge
            ? TimelineMath.clampStart(clipStartBeats
                                      + math.beats(seconds: headMovedS))
            : clipStartBeats
        return Trim(sectionStartS: clamped.start, sectionEndS: clamped.end,
                    startBeats: startBeats)
    }

    /// Lane a clip lands on after a vertical drag.
    static func laneIndex(originalIndex: Int, deltaY: CGFloat,
                          laneHeight: CGFloat, laneCount: Int) -> Int {
        guard laneCount > 0, laneHeight > 0 else { return originalIndex }
        let moved = originalIndex + Int((deltaY / laneHeight).rounded())
        return min(laneCount - 1, max(0, moved))
    }
}

// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// Places clips at (start, lane) inside a canvas whose size is the arrangement.
///
/// A `Layout` rather than a `ZStack` + `.offset`: offsets do not contribute to
/// layout bounds, so the enclosing horizontal `ScrollView` would never learn
/// how wide the arrangement is and could not scroll to the end of it.
struct ClipTimelineLayout: Layout {
    var frames: [String: CGRect]
    var contentSize: CGSize

    struct ClipID: LayoutValueKey {
        static let defaultValue: String = ""
    }

    func sizeThatFits(proposal: ProposedViewSize,
                      subviews: Subviews, cache: inout ()) -> CGSize {
        contentSize
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            guard let rect = frames[subview[ClipID.self]] else {
                // Nothing sensible to place it at; park it off-canvas rather
                // than stacking mystery views at the origin.
                subview.place(at: CGPoint(x: -10000, y: 0), proposal: .zero)
                continue
            }
            subview.place(
                at: CGPoint(x: bounds.minX + rect.minX,
                            y: bounds.minY + rect.minY),
                proposal: ProposedViewSize(width: rect.width,
                                           height: rect.height))
        }
    }
}

extension View {
    func clipTimelineID(_ id: String) -> some View {
        layoutValue(key: ClipTimelineLayout.ClipID.self, value: id)
    }
}

/// Lane stripes, bar/beat lines and overlap hatching — one Canvas for the whole
/// grid, because at any useful zoom this is hundreds of lines and none of them
/// are interactive.
///
/// The bar lines are the design's lane background: a repeating rule every bar,
/// brighter every fourth, so a phrase is countable without reading the ruler.
struct ClipTimelineGrid: View {
    /// A named type, not the tuple this used to be.
    ///
    /// Tuples cannot conform to `Equatable`, so SwiftUI could never prove
    /// this view unchanged and redrew the whole grid — every beat line across
    /// the entire arrangement — on every pass of its parent, which during a
    /// clip drag is every gesture event.
    struct Overlap: Equatable {
        var lane: Int
        var start: Double
        var end: Double
    }

    let math: TimelineMath
    let laneCount: Int
    let laneHeight: CGFloat
    let width: CGFloat
    let overlaps: [Overlap]

    var body: some View {
        Canvas { context, size in
            let beatWidth = math.pxPerBeat
            if beatWidth >= 9 {
                var beats = Path()
                var beat = 0.0
                while math.x(beats: beat) <= size.width {
                    let x = math.x(beats: beat)
                    beats.move(to: CGPoint(x: x, y: 0))
                    beats.addLine(to: CGPoint(x: x, y: size.height))
                    beat += 1
                }
                context.stroke(beats, with: .color(.white.opacity(0.03)),
                               lineWidth: 1)
            }
            var bars = Path()
            var phrases = Path()
            for tick in math.barTicks(fromX: 0, toX: size.width) {
                let start = CGPoint(x: tick.x, y: 0)
                let end = CGPoint(x: tick.x, y: size.height)
                if (tick.bar - 1) % 4 == 0 {
                    phrases.move(to: start)
                    phrases.addLine(to: end)
                } else {
                    bars.move(to: start)
                    bars.addLine(to: end)
                }
            }
            context.stroke(bars, with: .color(.white.opacity(0.055)),
                           lineWidth: 1)
            context.stroke(phrases, with: .color(.white.opacity(0.1)),
                           lineWidth: 1)

            // Lane separators last so they sit over the vertical rules.
            var separators = Path()
            for lane in 1...max(laneCount, 1) {
                let y = CGFloat(lane) * laneHeight
                separators.move(to: CGPoint(x: 0, y: y))
                separators.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(separators, with: .color(.white.opacity(0.05)),
                           lineWidth: 1)

            for overlap in overlaps {
                let x = math.x(beats: overlap.start)
                let w = math.x(beats: overlap.end) - x
                let rect = CGRect(x: x,
                                  y: CGFloat(overlap.lane) * laneHeight,
                                  width: w, height: laneHeight)
                context.fill(Path(rect),
                             with: .color(Bench.Palette.warn.opacity(0.14)))
            }
        }
        .frame(width: width, height: CGFloat(max(laneCount, 1)) * laneHeight)
        .drawingGroup()
    }
}

/// Bar numbers above the lanes; click to move the playhead.
struct ClipTimelineRuler: View {
    let math: TimelineMath
    let width: CGFloat
    var onScrub: ((Double) -> Void)?

    static let height: CGFloat = Bench.Metrics.timelineRulerHeight

    var body: some View {
        Canvas { context, size in
            var bars = Path()
            var phrases = Path()
            for tick in math.barTicks(fromX: 0, toX: size.width) {
                let start = CGPoint(x: tick.x, y: 0)
                let end = CGPoint(x: tick.x, y: size.height)
                if (tick.bar - 1) % 4 == 0 {
                    phrases.move(to: start)
                    phrases.addLine(to: end)
                } else {
                    bars.move(to: start)
                    bars.addLine(to: end)
                }
                // Numbering every bar turns to mush when bars are narrow.
                let stride = math.x(beats: math.beatsPerBar) < 44 ? 4 : 1
                guard (tick.bar - 1) % stride == 0 else { continue }
                context.draw(
                    Text("\(tick.bar)")
                        .font(Bench.Typo.metaLine)
                        .foregroundStyle(Bench.Palette.textFaintest),
                    at: CGPoint(x: tick.x + 5, y: size.height / 2),
                    anchor: .leading)
            }
            context.stroke(bars, with: .color(.white.opacity(0.06)),
                           lineWidth: 1)
            context.stroke(phrases, with: .color(.white.opacity(0.1)),
                           lineWidth: 1)
        }
        .frame(width: width, height: Self.height)
        .background(Bench.Palette.panel)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Bench.Palette.hairline).frame(height: 1)
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            onScrub?(max(0, math.beats(atX: value.location.x)))
        })
    }
}

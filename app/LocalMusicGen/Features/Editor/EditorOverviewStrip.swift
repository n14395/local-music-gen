import AppKit
import SwiftUI

/// The whole-track strip above the main well: the full edited timeline at a
/// glance, the viewport window, the selection tint, and a red mark at every
/// cut — E01/E02's "WHOLE TRACK" band.
///
/// The window is the well's viewport drawn against the whole track, and it is
/// handled the way a window is: drag its middle to move it, drag either edge
/// to resize it. Resizing it *is* zooming — the well shows whatever the window
/// contains — so the strip is a zoom control you aim rather than a slider you
/// guess with, and the edge you are not holding stays exactly where it was.
struct EditorOverviewStrip: View {
    @Bindable var store: EditorStore

    @State private var peaks: WaveformExtractor.Peaks?
    @State private var loadedFor: URL?
    /// What the drag in progress is doing. Decided once, from where it
    /// started, and held for the rest of the gesture: a resize that reverted
    /// to a scroll halfway through because the pointer wandered over the other
    /// edge would be unusable.
    @State private var drag: DragMode?
    /// Which edge the pointer is over, for the cursor and the highlight.
    @State private var hoveredEdge: EditorGeometry.ViewportEdge?

    private enum DragMode: Equatable {
        /// Sliding the window: how far into it the grab landed, so it moves
        /// with the pointer instead of jumping to centre on it.
        case scroll(grabOffsetS: Double)
        case resize(EditorGeometry.ViewportEdge)
    }

    /// Half the width of an edge's grab zone. The edge is drawn 2 pt wide,
    /// which is a target nobody can hit; this makes it a 14 pt band without
    /// making it look like one.
    private static let edgeGrabPx: CGFloat = 7

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 9) {
                Text(store.material?.isPart == true ? "WHOLE PART"
                                                    : "WHOLE TRACK")
                    .eyebrow()
                if cutCount > 0 {
                    Text(cutCount == 1 ? "1 REGION REMOVED"
                                       : "\(cutCount) REGIONS REMOVED")
                        .font(Bench.Typo.mono(10))
                        .tracking(0.4)
                        .foregroundStyle(Bench.Palette.dangerText)
                } else {
                    Text("DRAG THE WINDOW TO SCROLL · ITS EDGES TO ZOOM")
                        .font(Bench.Typo.mono(10))
                        .tracking(0.4)
                        .foregroundStyle(Bench.Palette.textFaintest)
                }
                Spacer(minLength: 8)
                Text("0:00 — \(EditorClock.short(store.timelineDurationS))")
                    .font(Bench.Typo.mono(10))
                    .foregroundStyle(Bench.Palette.textFaintest)
            }
            GeometryReader { geo in
                strip(width: geo.size.width)
            }
            .frame(height: 58)
        }
    }

    private var cutCount: Int { store.joinTimes.count }

    private func strip(width: CGFloat) -> some View {
        let duration = max(0.001, store.timelineDurationS)
        func x(_ t: Double) -> CGFloat { CGFloat(t / duration) * width }
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Bench.Palette.well)
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Bench.Palette.hairline, lineWidth: 1)
            EditorOverviewWave(peaks: peaks, segments: store.segments,
                               timelineDurationS: store.timelineDurationS,
                               sourceDurationS: store.sourceDurationS)
                .padding(.horizontal, 8).padding(.vertical, 7)
            // selection tint
            if let selection = store.selection {
                Rectangle()
                    .fill(Bench.Palette.accent.opacity(0.18))
                    .frame(width: max(0, x(selection.end) - x(selection.start)))
                    .offset(x: x(selection.start))
            }
            // cut markers
            ForEach(Array(cutPositions.enumerated()), id: \.offset) { _, cut in
                Rectangle()
                    .fill(Bench.Palette.danger)
                    .frame(width: 2)
                    .offset(x: x(cut))
                Text("CUT")
                    .font(Bench.Typo.mono(9, .semibold))
                    .tracking(0.7)
                    .foregroundStyle(Bench.Palette.danger)
                    .offset(x: x(cut) + 5, y: 4)
            }
            // viewport window
            viewportWindow(width: width)
            // Playhead — display only; the seek row beneath is where you
            // grab it, and the line running into that row's knob is what
            // says the two bands are one position. Drawn over the window so
            // it stays visible inside it, and polled rather than observed:
            // the position is a live query on the player while it plays.
            TimelineView(.animation(minimumInterval: 1.0 / 30,
                                    paused: !store.isPlaying)) { _ in
                Rectangle()
                    .fill(Bench.Palette.accent)
                    .frame(width: 1.5)
                    .offset(x: x(store.playheadS))
            }
            .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { value in
                let mode = drag ?? mode(grabbedAt: value.startLocation.x,
                                        width: width)
                drag = mode
                let at = Double(value.location.x / max(1, width)) * duration
                switch mode {
                case .scroll(let grabOffsetS):
                    store.visibleStartS = (at - grabOffsetS)
                        .clamped(to: 0...max(0, duration - visibleSeconds))
                case .resize(let edge):
                    let resized = wellGeometry.draggingEdge(edge, to: at)
                    store.pxPerSecond = resized.pxPerSecond
                    store.visibleStartS = resized.visibleStartS
                }
            }
            .onEnded { _ in drag = nil })
        // The edges are 2 pt of accent on a dark strip; without the cursor
        // changing over them, nothing says they are handles rather than the
        // window's outline.
        .onContinuousHover { phase in
            switch phase {
            case .active(let point):
                let edge = self.edge(near: point.x, width: width)
                if edge != hoveredEdge {
                    hoveredEdge = edge
                    (edge == nil ? NSCursor.arrow
                                 : NSCursor.resizeLeftRight).set()
                }
            case .ended:
                hoveredEdge = nil
                NSCursor.arrow.set()
            }
        }
        .task(id: store.sourceURL) { await loadPeaks() }
        .onChange(of: store.applyStage) {
            if !store.applyStage.isBusy { Task { await loadPeaks() } }
        }
    }

    private var cutPositions: [Double] { store.joinTimes }

    /// The well's viewport as geometry, which is what the edge drag operates
    /// on. Note the width: the strip's own pixels map the *whole track*, but
    /// the zoom being changed is the well's, so the arithmetic has to be done
    /// in the well's width or a resize would land at the wrong magnification.
    ///
    /// A `pxPerSecond` of zero means "fit, decided at first layout" and is
    /// substituted here — it is a sentinel, not a scale, and dividing by it
    /// would be dividing by nothing.
    private var wellGeometry: EditorGeometry {
        let duration = max(0.001, store.timelineDurationS)
        let width = max(1, store.wellWidth)
        return EditorGeometry(
            visibleStartS: store.visibleStartS,
            pxPerSecond: store.pxPerSecond > 0 ? store.pxPerSecond
                : EditorGeometry.fitZoom(durationS: duration, width: width),
            width: width, durationS: duration)
    }

    /// Where the strip draws the window's two edges.
    private func edgeXs(width: CGFloat) -> (start: CGFloat, end: CGFloat) {
        let duration = max(0.001, store.timelineDurationS)
        let x0 = CGFloat(store.visibleStartS / duration) * width
        return (x0, x0 + max(6, CGFloat(min(1, visibleSeconds / duration)) * width))
    }

    /// The edge within grabbing distance of `x`, if any.
    ///
    /// Deeply zoomed in, the window is only a few points wide and both grab
    /// zones cover the same pixels — so the nearer edge wins rather than
    /// whichever is tested first. Zoomed in that far, resizing is what the
    /// strip is for anyway.
    private func edge(near x: CGFloat,
                      width: CGFloat) -> EditorGeometry.ViewportEdge? {
        let edges = edgeXs(width: width)
        let toStart = abs(x - edges.start)
        let toEnd = abs(x - edges.end)
        guard min(toStart, toEnd) <= Self.edgeGrabPx else { return nil }
        return toStart <= toEnd ? .start : .end
    }

    private func mode(grabbedAt x: CGFloat, width: CGFloat) -> DragMode {
        if let edge = edge(near: x, width: width) { return .resize(edge) }
        let duration = max(0.001, store.timelineDurationS)
        let visible = visibleSeconds
        let grabbed = Double(x / max(1, width)) * duration
        let inside = grabbed >= store.visibleStartS
            && grabbed <= store.visibleStartS + visible
        // Grabbing the window slides it; clicking outside it still jumps
        // there, centred.
        return .scroll(grabOffsetS: inside ? grabbed - store.visibleStartS
                                           : visible / 2)
    }

    private var visibleSeconds: Double {
        guard store.pxPerSecond > 0, store.wellWidth > 0 else {
            return store.timelineDurationS
        }
        return Double(store.wellWidth / store.pxPerSecond)
    }

    private func viewportWindow(width: CGFloat) -> some View {
        let duration = max(0.001, store.timelineDurationS)
        let visible = visibleSeconds
        let x0 = CGFloat(store.visibleStartS / duration) * width
        let w = CGFloat(min(1, visible / duration)) * width
        return Rectangle()
            .fill(Bench.Palette.accent.opacity(0.08))
            .overlay(alignment: .leading) { handle(.start) }
            .overlay(alignment: .trailing) { handle(.end) }
            .frame(width: max(6, w))
            .offset(x: x0)
    }

    /// One edge of the window. It thickens under the pointer — the only
    /// visual difference between an outline and a handle, on a control with
    /// no room for a grip.
    private func handle(_ edge: EditorGeometry.ViewportEdge) -> some View {
        let held = drag == .resize(edge)
        let lit = held || (drag == nil && hoveredEdge == edge)
        return Rectangle()
            .fill(lit ? Bench.Palette.accentHover : Bench.Palette.accent)
            .frame(width: lit ? 3 : 2)
            .animation(.easeOut(duration: 0.12), value: lit)
    }

    private func loadPeaks() async {
        guard let url = store.sourceURL,
              let cache = store.sourcePeaksCacheURL else { return }
        guard loadedFor != url || peaks == nil else { return }
        peaks = try? await WaveformExtractor.shared.peaks(for: url,
                                                          cacheURL: cache)
        loadedFor = url
    }
}

/// The overview's waveform.
///
/// Its own view because the strip's body reads `visibleStartS` and
/// `pxPerSecond` to place the viewport window, so dragging or zooming that
/// window re-ran this `Canvas` on every event — resampling a few hundred bars
/// through the segment map and rebuilding the path — to move a rectangle that
/// sits on top of it. Given only values, it is skipped unless the audio or
/// the cut actually changed.
///
/// The overview draws the *edited* timeline by resampling the source's cached
/// whole-file peaks through the segment map — cheap, and honest about what was
/// cut, pasted or reversed.
private struct EditorOverviewWave: View, Equatable {
    let peaks: WaveformExtractor.Peaks?
    let segments: [EditSegment]
    let timelineDurationS: Double
    let sourceDurationS: Double

    var body: some View {
        Canvas { context, size in
            guard let peaks, !peaks.maxs.isEmpty else { return }
            let duration = max(0.001, timelineDurationS)
            let sourceDuration = max(0.001, sourceDurationS)
            let bars = max(1, Int(size.width / 3))
            let pitch = size.width / CGFloat(bars)
            let mid = size.height / 2
            var path = Path()
            for i in 0..<bars {
                let t = (Double(i) + 0.5) / Double(bars) * duration
                guard let s = EditProgram.timelineToSource(t, in: segments)
                else { continue }
                let bin = Int(s / sourceDuration * Double(peaks.maxs.count))
                    .clamped(to: 0...(peaks.maxs.count - 1))
                let magnitude = max(abs(peaks.maxs[bin]), abs(peaks.mins[bin]))
                let height = max(1.5, CGFloat(magnitude) * size.height * 0.94)
                path.addRoundedRect(
                    in: CGRect(x: CGFloat(i) * pitch, y: mid - height / 2,
                               width: max(1, pitch - 1), height: height),
                    cornerSize: CGSize(width: 1, height: 1))
            }
            context.fill(path, with: .color(.white.opacity(0.24)))
        }
    }
}

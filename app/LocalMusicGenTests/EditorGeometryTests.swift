import XCTest
@testable import LocalMusicGen

/// Viewport, zoom and snap maths — pure, in the style of
/// `TimelineMathTests`.
final class EditorGeometryTests: XCTestCase {

    private func geo(start: Double = 0, px: CGFloat = 10,
                     width: CGFloat = 800,
                     duration: Double = 200) -> EditorGeometry {
        EditorGeometry(visibleStartS: start, pxPerSecond: px, width: width,
                       durationS: duration)
    }

    func testSecondsAndPixelsRoundTrip() {
        let g = geo(start: 20)
        XCTAssertEqual(g.x(at: 20), 0)
        XCTAssertEqual(g.x(at: 30), 100)
        XCTAssertEqual(g.seconds(atX: 100), 30, accuracy: 1e-9)
        XCTAssertEqual(g.visibleSeconds, 80, accuracy: 1e-9)
        XCTAssertEqual(g.visibleEndS, 100, accuracy: 1e-9)
    }

    func testSecondsClampToTheTrack() {
        let g = geo(start: 190, duration: 200)
        XCTAssertEqual(g.seconds(atX: 5000), 200)
        XCTAssertEqual(g.seconds(atX: -5000), 0)
    }

    /// Fit is the zoom floor: zooming out past "the whole track" only adds
    /// dead space.
    func testZoomClampsToFit() {
        let fit = EditorGeometry.fitZoom(durationS: 200, width: 800)
        XCTAssertEqual(fit, 4, accuracy: 1e-9)
        XCTAssertEqual(EditorGeometry.clampZoom(1, durationS: 200, width: 800),
                       fit)
        XCTAssertEqual(EditorGeometry.clampZoom(9999, durationS: 200,
                                                width: 800),
                       EditorGeometry.maxZoom)
    }

    func testZoomKeepsTheAnchorUnderThePointer() {
        let before = geo(start: 20, px: 10)
        let anchorX: CGFloat = 200          // 40 s in
        let after = before.zoomed(to: 40, anchorX: anchorX)
        XCTAssertEqual(after.seconds(atX: anchorX), 40, accuracy: 1e-6)
    }

    func testClampedStartKeepsTheWindowInside() {
        let g = geo(px: 10, width: 800, duration: 200)   // 80 s in view
        XCTAssertEqual(g.clampedStart(500), 120, accuracy: 1e-9)
        XCTAssertEqual(g.clampedStart(-5), 0)
        // Shorter than the window: pinned to the front.
        let short = geo(px: 10, width: 800, duration: 20)
        XCTAssertEqual(short.clampedStart(15), 0)
    }

    /// Snap radius is in *pixels*, so it feels the same at every zoom.
    // MARK: clipping a block to the viewport

    /// The invariant the editor's layout depends on: a block's frame is never
    /// wider than the well it is drawn in.
    ///
    /// It used to be. A section band was framed at its *true* width and
    /// offset back into place, which looks identical on screen and is not the
    /// same thing at all — a SwiftUI stack sizes itself to its widest child,
    /// so one minute-long section, zoomed in, made the editor's column wider
    /// than its well and shoved the waveform sideways. The gap down the left
    /// grew the further in you scrolled.
    func testAClippedBlockNeverExceedsTheViewport() {
        let g = geo(start: 100, px: 49, width: 980, duration: 222)
        for (start, end) in [(0.0, 222.0), (0.0, 120.0), (90.0, 300.0),
                             (105.0, 110.0)] {
            let span = g.clipped(from: start, to: end)
            XCTAssertNotNil(span, "\(start)…\(end)")
            XCTAssertLessThanOrEqual(span!.width, g.width, "\(start)…\(end)")
            XCTAssertGreaterThanOrEqual(span!.x, 0, "\(start)…\(end)")
            XCTAssertLessThanOrEqual(span!.x + span!.width, g.width + 0.001)
        }
    }

    /// A range that is wholly in view is untouched — clipping must not shrink
    /// what already fits.
    func testARangeInsideTheViewportIsUnchanged() {
        let g = geo(start: 20, px: 10, width: 800, duration: 200)
        let span = g.clipped(from: 30, to: 50)
        XCTAssertEqual(span?.x ?? -1, 100, accuracy: 1e-9)
        XCTAssertEqual(span?.width ?? -1, 200, accuracy: 1e-9)
    }

    func testARangeEntirelyOffScreenIsNotDrawn() {
        let g = geo(start: 100, px: 10, width: 800, duration: 400)
        XCTAssertNil(g.clipped(from: 0, to: 90))       // ends before the left
        XCTAssertNil(g.clipped(from: 200, to: 300))    // starts past the right
        XCTAssertNil(g.clipped(from: 50, to: 50))      // no length at all
    }

    /// Half in view: only the half that is in view has a width.
    func testARangeStraddlingAnEdgeIsCutAtIt() {
        let g = geo(start: 100, px: 10, width: 800, duration: 400)
        let left = g.clipped(from: 50, to: 120)
        XCTAssertEqual(left?.x ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(left?.width ?? -1, 200, accuracy: 1e-9)
        let right = g.clipped(from: 150, to: 400)
        XCTAssertEqual(right?.x ?? -1, 500, accuracy: 1e-9)
        XCTAssertEqual(right?.width ?? -1, 300, accuracy: 1e-9)
    }

    /// Backwards ranges happen — a selection dragged right to left — and are
    /// the same span either way round.
    func testABackwardsRangeIsTheSameSpan() {
        let g = geo(start: 20, px: 10, width: 800, duration: 200)
        XCTAssertEqual(g.clipped(from: 50, to: 30)?.x,
                       g.clipped(from: 30, to: 50)?.x)
        XCTAssertEqual(g.clipped(from: 50, to: 30)?.width,
                       g.clipped(from: 30, to: 50)?.width)
    }

    func testNoWidthMeansNothingToDraw() {
        XCTAssertNil(geo(width: 0).clipped(from: 0, to: 10))
    }

    // MARK: dragging the overview window's edges

    /// The gesture's whole premise: the edge you are holding moves, the other
    /// one does not. Anything else is a scroll wearing a zoom's clothes.
    func testDraggingTheStartEdgePinsTheEnd() {
        let g = geo(start: 20, px: 10)          // 20…100 s of a 200 s track
        let out = g.draggingEdge(.start, to: 60)
        XCTAssertEqual(out.visibleStartS, 60, accuracy: 1e-6)
        XCTAssertEqual(out.visibleEndS, 100, accuracy: 1e-6)
        XCTAssertEqual(out.pxPerSecond, 20, accuracy: 1e-6)
    }

    func testDraggingTheEndEdgePinsTheStart() {
        let g = geo(start: 20, px: 10)
        let out = g.draggingEdge(.end, to: 60)
        XCTAssertEqual(out.visibleStartS, 20, accuracy: 1e-6)
        XCTAssertEqual(out.visibleEndS, 60, accuracy: 1e-6)
        XCTAssertEqual(out.pxPerSecond, 20, accuracy: 1e-6)
    }

    /// Dragging an edge outwards is zooming out, and it stops where every
    /// other zoom control in the editor stops.
    func testDraggingOutwardsStopsAtTheWholeTrack() {
        let g = geo(start: 100, px: 10)         // 100…180 s
        let out = g.draggingEdge(.start, to: -500)
        XCTAssertEqual(out.visibleStartS, 0, accuracy: 1e-6)
        XCTAssertEqual(out.pxPerSecond,
                       EditorGeometry.fitZoom(durationS: 200, width: 800),
                       accuracy: 1e-6)
    }

    /// And inwards it stops at `maxZoom`, with the pinned edge still pinned —
    /// the failure worth pinning is a window that collapses to nothing and
    /// takes the viewport somewhere else on the way.
    func testDraggingPastTheOppositeEdgeStopsAtMaxZoom() {
        let g = geo(start: 20, px: 10)          // 20…100 s
        let out = g.draggingEdge(.start, to: 500)
        XCTAssertEqual(out.pxPerSecond, EditorGeometry.maxZoom, accuracy: 1e-6)
        XCTAssertEqual(out.visibleEndS, 100, accuracy: 1e-6)
        XCTAssertEqual(out.visibleSeconds,
                       Double(800 / EditorGeometry.maxZoom), accuracy: 1e-6)
    }

    func testDraggingTheEndPastTheStartStopsAtMaxZoom() {
        let g = geo(start: 20, px: 10)
        let out = g.draggingEdge(.end, to: -500)
        XCTAssertEqual(out.pxPerSecond, EditorGeometry.maxZoom, accuracy: 1e-6)
        XCTAssertEqual(out.visibleStartS, 20, accuracy: 1e-6)
    }

    /// A window already showing the whole track cannot be dragged wider, and
    /// must not drift while failing to.
    func testAFullWidthWindowDoesNotMoveWhenDraggedWider() {
        let fit = EditorGeometry.fitZoom(durationS: 200, width: 800)
        let g = geo(start: 0, px: fit)
        let out = g.draggingEdge(.end, to: 9999)
        XCTAssertEqual(out.visibleStartS, 0, accuracy: 1e-6)
        XCTAssertEqual(out.pxPerSecond, fit, accuracy: 1e-6)
    }

    /// A track shorter than the narrowest window `maxZoom` allows inverts the
    /// clamp bounds. The arithmetic has to survive that — a `ClosedRange`
    /// built from a reversed pair traps, and this is a real case: an 800 pt
    /// well at 400 px/s cannot show less than two seconds.
    func testAVeryShortTrackDoesNotTrap() {
        let g = geo(start: 0, px: 800, width: 800, duration: 1)
        XCTAssertEqual(g.draggingEdge(.start, to: 0.5).visibleStartS, 0,
                       accuracy: 1e-6)
        XCTAssertNotEqual(g.draggingEdge(.end, to: 0.5).pxPerSecond, 0)
    }

    /// Before the well has been laid out there is no width to divide by, and
    /// a drag has nothing to mean yet.
    func testNoWidthOrNoTrackIsIdentity() {
        let noWidth = geo(width: 0)
        XCTAssertEqual(noWidth.draggingEdge(.start, to: 10), noWidth)
        let noTrack = geo(duration: 0)
        XCTAssertEqual(noTrack.draggingEdge(.end, to: 10), noTrack)
    }

    // MARK: resize

    /// The bug this exists to stop: resizing the window used to leave
    /// pixels-per-second alone, so the seconds in view moved with the window
    /// and the overview strip's window grew or shrank on its own.
    func testResizingKeepsTheSecondsInView() {
        let g = geo(start: 20, px: 10, width: 800)   // 80 s in view, 20–100
        let wider = g.resized(toWidth: 1200)
        XCTAssertEqual(wider.visibleSeconds, 80, accuracy: 1e-6)
        XCTAssertEqual(wider.visibleStartS, 20, accuracy: 1e-6)
        XCTAssertEqual(wider.pxPerSecond, 15, accuracy: 1e-6)
        let narrower = g.resized(toWidth: 400)
        XCTAssertEqual(narrower.visibleSeconds, 80, accuracy: 1e-6)
        XCTAssertEqual(narrower.visibleStartS, 20, accuracy: 1e-6)
    }

    /// Fit is a span like any other, so it survives a resize as fit rather
    /// than as the pixel scale that happened to mean fit at the old width.
    func testResizingKeepsAFittedTrackFitted() {
        let g = geo(start: 0, px: EditorGeometry.fitZoom(durationS: 200,
                                                         width: 800))
        let out = g.resized(toWidth: 1200)
        XCTAssertEqual(out.pxPerSecond,
                       EditorGeometry.fitZoom(durationS: 200, width: 1200),
                       accuracy: 1e-6)
        XCTAssertEqual(out.visibleSeconds, 200, accuracy: 1e-6)
    }

    /// Widening at full magnification cannot hold the span — there is no zoom
    /// past `maxZoom` to spend on it — so the extra seconds arrive and the
    /// window still has to land inside the track.
    func testResizingAtMaxZoomTakesTheExtraSeconds() {
        let g = geo(start: 197, px: EditorGeometry.maxZoom, width: 800)
        let out = g.resized(toWidth: 1600)
        XCTAssertEqual(out.pxPerSecond, EditorGeometry.maxZoom, accuracy: 1e-6)
        XCTAssertEqual(out.visibleSeconds, 4, accuracy: 1e-6)
        // The window was 197–199 and cannot start at 197 now without running
        // off the end, so it slides back rather than overhanging.
        XCTAssertEqual(out.visibleStartS, 196, accuracy: 1e-6)
        XCTAssertEqual(out.visibleEndS, 200, accuracy: 1e-6)
    }

    /// Before the first layout there is no scale to preserve; the width is
    /// recorded and the fit sentinel left for the view to resolve.
    func testResizingFromNothingIsJustTheNewWidth() {
        let g = geo(px: 0, width: 0)
        let out = g.resized(toWidth: 800)
        XCTAssertEqual(out.width, 800)
        XCTAssertEqual(out.pxPerSecond, 0)
    }

    func testSnapUsesAScreenRadius() {
        let coarse = geo(px: 10)            // 8 px = 0.8 s
        XCTAssertEqual(coarse.snapped(10.5, candidates: [10, 12]), 10,
                       accuracy: 1e-9)
        XCTAssertEqual(coarse.snapped(11.0, candidates: [10, 12]), 11,
                       accuracy: 1e-9, "1 s away is beyond 8 px at this zoom")
        let fine = geo(px: 100)             // 8 px = 0.08 s
        XCTAssertEqual(fine.snapped(10.5, candidates: [10, 12]), 10.5,
                       accuracy: 1e-9, "zoomed in, 0.5 s is far away")
        XCTAssertEqual(fine.snapped(10.05, candidates: [10, 12]), 10,
                       accuracy: 1e-9)
    }

    func testSnapWithNoCandidatesIsIdentity() {
        XCTAssertEqual(geo().snapped(7.5, candidates: []), 7.5)
    }

    // MARK: grid

    private func payload() -> AnalysisPayload {
        var payload = AnalysisPayload()
        payload.beats = stride(from: 0.0, through: 8.0, by: 0.5).map { $0 }
        payload.downbeats = [0, 2, 4, 6, 8]
        payload.sections = [
            .init(startS: 0, endS: 4, group: "A", label: "verse"),
            .init(startS: 4, endS: 8, group: "B", label: "chorus"),
        ]
        return payload
    }

    /// Bar numbers stay source-anchored through a cut: the numbers jump,
    /// which is the truth about what was removed.
    func testGridMapsThroughACut() {
        let segments = EditProgram.segments(
            sourceDuration: 10,
            ops: [EditOp(kind: .delete(EditRange(start: 2, end: 4)))])
        let grid = EditorGrid.make(analysis: payload(), segments: segments)
        // Downbeat at source 4 is now at timeline 2; source 2–4 is gone.
        XCTAssertEqual(grid.barTicks.map(\.number), [1, 3, 4, 5])
        XCTAssertEqual(grid.barTicks[1].timelineS, 2, accuracy: 1e-9)
        XCTAssertFalse(grid.beats.contains { $0 > 8 })
    }

    /// A section that was half deleted survives as the part that is left.
    func testSectionsClampToWhatSurvived() {
        let segments = EditProgram.segments(
            sourceDuration: 8,
            ops: [EditOp(kind: .delete(EditRange(start: 5, end: 8)))])
        let grid = EditorGrid.make(analysis: payload(), segments: segments)
        let chorus = try? XCTUnwrap(grid.sections.first { $0.label == "CHORUS" })
        XCTAssertNotNil(chorus)
        XCTAssertEqual(chorus?.startS ?? -1, 4, accuracy: 0.3)
        XCTAssertEqual(chorus?.endS ?? -1, 5, accuracy: 0.3)
    }

    func testSnapCandidatesPerMode() {
        let segments = EditProgram.segments(sourceDuration: 10, ops: [])
        let grid = EditorGrid.make(analysis: payload(), segments: segments)
        XCTAssertEqual(grid.candidates(for: .off), [])
        XCTAssertEqual(grid.candidates(for: .zeroX), [])
        XCTAssertEqual(grid.candidates(for: .bars), [0, 2, 4, 6, 8])
        XCTAssertEqual(grid.candidates(for: .beats).count, 17)
        XCTAssertEqual(grid.candidates(for: .sections).count, 4)
    }

    // MARK: zero crossings

    func testZeroCrossingPicksTheNearestSignChange() {
        let samples: [Float] = [1, 1, -1, -1, 1, 1, 1, 1]
        XCTAssertEqual(ZeroCross.nearest(in: samples, around: 2), 1)
        XCTAssertEqual(ZeroCross.nearest(in: samples, around: 6), 3)
        XCTAssertNil(ZeroCross.nearest(in: [1, 1, 1], around: 1))
    }

    // MARK: clocks and names

    func testClockFormats() {
        XCTAssertEqual(EditorClock.full(38.42), "0:38.42")
        XCTAssertEqual(EditorClock.full(104.6), "1:44.60")
        XCTAssertEqual(EditorClock.short(104.6), "1:45")
        XCTAssertEqual(EditorClock.full(-1), "0:00.00")
    }

    /// Colons are path separators to AppKit, so the clock's colon becomes an
    /// underscore in a filename.
    func testExportNameCarriesTheSelectionAndFormat() {
        let name = EditorStore.exportName(
            title: "Drums", songTitle: "test01",
            selection: EditRange(start: 72.4, end: 81.3), format: "wav")
        XCTAssertEqual(name, "Drums — test01 (1_12–1_21).wav")
        XCTAssertFalse(name.contains(":"))

        let whole = EditorStore.exportName(title: "a/b", songTitle: nil,
                                           selection: nil, format: "flac")
        XCTAssertEqual(whole, "a-b.flac")
    }
}

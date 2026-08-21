import XCTest
@testable import LocalMusic

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

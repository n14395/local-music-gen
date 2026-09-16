import XCTest
@testable import LocalMusicGen

/// The timeline's coordinate system and the one clip-length formula the
/// drawing, the preview and the engine all have to agree on.
final class TimelineMathTests: XCTestCase {

    private func math(bpm: Double = 120, zoom: CGFloat = 20) -> TimelineMath {
        TimelineMath(bpm: bpm, beatsPerBar: 4, pxPerSecond: zoom)
    }

    // MARK: conversions

    func testBeatsAndSecondsRoundTrip() {
        let m = math()
        XCTAssertEqual(m.seconds(beats: 4), 2, accuracy: 1e-12)
        XCTAssertEqual(m.beats(seconds: 2), 4, accuracy: 1e-12)
        XCTAssertEqual(m.beats(bars: 3), 12)
        XCTAssertEqual(m.bars(beats: 12), 3)
    }

    func testPixelsRoundTripAtEveryZoom() {
        for zoom in [CGFloat(2), 20, 200] {
            let m = math(bpm: 124, zoom: zoom)
            for beats in [0.0, 1.5, 16, 137.25] {
                XCTAssertEqual(m.beats(atX: m.x(beats: beats)), beats,
                               accuracy: 1e-9, "zoom \(zoom) beats \(beats)")
            }
        }
    }

    func testMissingTempoFallsBackRatherThanDividingByZero() {
        let m = TimelineMath(bpm: nil)
        XCTAssertEqual(m.bpm, 120)
        XCTAssertEqual(TimelineMath(bpm: 0).bpm, 120)
    }

    // MARK: snapping and clamping

    func testSnapToBar() {
        let m = math()
        XCTAssertEqual(m.snapped(3.6, to: .bar), 4)
        XCTAssertEqual(m.snapped(5.2, to: .bar), 4)
        XCTAssertEqual(m.snapped(6.1, to: .bar), 8)
    }

    func testSnapToBeat() {
        let m = math()
        XCTAssertEqual(m.snapped(3.6, to: .beat), 4)
        XCTAssertEqual(m.snapped(5.2, to: .beat), 5)
    }

    func testSnapOffIsIdentity() {
        XCTAssertEqual(math().snapped(5.234, to: .off), 5.234)
    }

    /// The engine rejects a negative offset_s outright (adapter.py), so nothing
    /// may leave the timeline below zero.
    func testStartClampsAtZero() {
        XCTAssertEqual(TimelineMath.clampStart(-3), 0)
        XCTAssertEqual(TimelineMath.clampStart(2.5), 2.5)
    }

    func testNormalizeShiftsEveryoneAndKeepsSpacing() {
        XCTAssertEqual(TimelineMath.normalizedToZero([-4, 0, 8]), [0, 4, 12])
        XCTAssertEqual(TimelineMath.normalizedToZero([2, 6]), [2, 6])
    }

    // MARK: clip length (the formula the engine must agree with)

    func testStretchedClipKeepsItsBeatCount() {
        // 8 s at 120 BPM is 16 beats; on a 140 grid it must still be 16 beats
        let seconds = TimelineGeometry.timelineLengthS(
            sourceLengthS: 8, sourceBpm: 120, targetBpm: 140,
            autoMatchTempo: true)
        XCTAssertEqual(seconds, 8 * 120.0 / 140.0, accuracy: 1e-12)
        XCTAssertEqual(
            TimelineGeometry.timelineLengthBeats(
                sourceLengthS: 8, sourceBpm: 120, targetBpm: 140,
                autoMatchTempo: true),
            16, accuracy: 1e-9)
    }

    func testUnstretchedClipKeepsItsSeconds() {
        let seconds = TimelineGeometry.timelineLengthS(
            sourceLengthS: 8, sourceBpm: 120, targetBpm: 140,
            autoMatchTempo: false)
        XCTAssertEqual(seconds, 8)
        XCTAssertEqual(
            TimelineGeometry.timelineLengthBeats(
                sourceLengthS: 8, sourceBpm: 120, targetBpm: 140,
                autoMatchTempo: false),
            8 * 140.0 / 60.0, accuracy: 1e-9)
    }

    /// Pins the direction verified against a real render in verify_engine
    /// ("a stretched clip renders at source_bpm/target_bpm of its length").
    func testStretchDirectionMatchesTheEngine() {
        XCTAssertEqual(
            TimelineGeometry.timelineLengthS(sourceLengthS: 1.0,
                                             sourceBpm: 120, targetBpm: 150,
                                             autoMatchTempo: true),
            1.0 * 120.0 / 150.0, accuracy: 1e-12)
    }

    func testUnknownTempoNeverStretches() {
        XCTAssertFalse(TimelineGeometry.stretches(sourceBpm: nil, targetBpm: 120,
                                                  autoMatchTempo: true))
        XCTAssertFalse(TimelineGeometry.stretches(sourceBpm: 120, targetBpm: nil,
                                                  autoMatchTempo: true))
        XCTAssertEqual(
            TimelineGeometry.timelineLengthS(sourceLengthS: 5, sourceBpm: nil,
                                             targetBpm: 120,
                                             autoMatchTempo: true), 5)
    }

    func testSourceLengthUsesTheTrimOnlyWhenBothBoundsAreSet() {
        XCTAssertEqual(TimelineGeometry.sourceLengthS(sectionStartS: 10,
                                                      sectionEndS: 20,
                                                      sourceDurationS: 60), 10)
        // a one-sided trim never reaches the wire, so it must not shorten the
        // drawing either
        XCTAssertEqual(TimelineGeometry.sourceLengthS(sectionStartS: 10,
                                                      sectionEndS: nil,
                                                      sourceDurationS: 60), 60)
        XCTAssertNil(TimelineGeometry.sourceLengthS(sectionStartS: nil,
                                                    sectionEndS: nil,
                                                    sourceDurationS: nil))
    }

    // MARK: layout

    private func placements() -> [TimelineMath.Placement] {
        [.init(id: "a", laneIndex: 0, startBeats: 0, lengthBeats: 8),
         .init(id: "b", laneIndex: 1, startBeats: 16, lengthBeats: 8)]
    }

    func testFramesStackLanesAndPlaceClips() {
        let m = math(bpm: 120, zoom: 10)   // 1 beat = 0.5 s = 5 px
        let frames = m.frames(placements(), laneHeight: 60, clipInset: 2)
        XCTAssertEqual(frames[0].rect.minX, 0)
        XCTAssertEqual(frames[0].rect.minY, 2)
        XCTAssertEqual(frames[0].rect.width, 40, accuracy: 1e-9)
        XCTAssertEqual(frames[1].rect.minX, 80, accuracy: 1e-9)
        XCTAssertEqual(frames[1].rect.minY, 62)
        XCTAssertEqual(frames[0].rect.height, 56)
    }

    func testContentBeatsReachesPastTheLastClip() {
        XCTAssertEqual(TimelineMath.contentBeats(placements()), 24 + 8)
    }

    func testOverlapsWithinALane() {
        let out = TimelineMath.overlaps(inLane: [(0, 8), (6, 8), (32, 4)])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].start, 6, accuracy: 1e-9)
        XCTAssertEqual(out[0].end, 8, accuracy: 1e-9)
    }

    func testBarTicksCoverTheVisibleWindowOnly() {
        let m = math(bpm: 120, zoom: 10)     // bar = 2 s = 20 px
        let ticks = m.barTicks(fromX: 0, toX: 60)
        XCTAssertEqual(ticks.map(\.bar), [1, 2, 3, 4])
        XCTAssertEqual(ticks[1].x, 20, accuracy: 1e-9)
        // zoomed far out the ruler stops rather than drawing mush
        XCTAssertTrue(math(bpm: 120, zoom: 0.1).barTicks(fromX: 0, toX: 60)
            .isEmpty)
    }

    func testZoomFitAndClamp() {
        XCTAssertEqual(TimelineMath.fitZoom(contentSeconds: 60, width: 600), 10)
        XCTAssertEqual(TimelineMath.clampZoom(0.5), TimelineMath.minZoom)
        XCTAssertEqual(TimelineMath.clampZoom(9999), TimelineMath.maxZoom)
    }

    func testTrimDelegatesToRegionMath() {
        let (s, e) = TimelineMath.trimmed(startS: -5, endS: 90,
                                          sourceDurationS: 60)
        XCTAssertEqual(s, 0)
        XCTAssertEqual(e, 60)
        let (s2, e2) = TimelineMath.trimmed(startS: 30, endS: 30.05,
                                            sourceDurationS: 60)
        XCTAssertGreaterThanOrEqual(e2 - s2, 0.25 - 1e-9)
    }

    // MARK: peaks

    func testPeakSliceCoversTheTrimmedWindow() {
        let r = PeakSlice.range(startS: 10, endS: 20, durationS: 200,
                                binCount: 2000)
        XCTAssertEqual(r, 100..<200)
    }

    func testPeakSliceClampsAndNeverReturnsEmpty() {
        let past = PeakSlice.range(startS: 500, endS: 900, durationS: 200,
                                   binCount: 2000)
        XCTAssertFalse(past.isEmpty)
        XCTAssertLessThanOrEqual(past.upperBound, 2000)
        let degenerate = PeakSlice.range(startS: 5, endS: 5, durationS: 200,
                                         binCount: 2000)
        XCTAssertEqual(degenerate.count, 1)
        XCTAssertEqual(PeakSlice.range(startS: 0, endS: 1, durationS: 0,
                                       binCount: 2000), 0..<2000)
    }

    /// 2000 bins over a 4-minute source is 0.12 s per bin, so the cache runs
    /// out of detail around 16 px/s — the timeline caps zoom there instead of
    /// drawing blocks and calling them a waveform.
    func testUsefulZoomCapFollowsTheCacheResolution() {
        XCTAssertEqual(PeakSlice.usefulZoomCap(sourceDurationS: 240,
                                               binCount: 2000),
                       2 * 2000 / 240, accuracy: 1e-9)
        // a finer cache buys proportionally more zoom (16000 bins ≈ 133 px/s)
        XCTAssertEqual(PeakSlice.usefulZoomCap(sourceDurationS: 240,
                                               binCount: 16000),
                       2 * 16000 / 240, accuracy: 1e-9)
        XCTAssertGreaterThan(PeakSlice.usefulZoomCap(sourceDurationS: 240,
                                                     binCount: 16000),
                             PeakSlice.usefulZoomCap(sourceDurationS: 240,
                                                     binCount: 2000))
        // short sources are never capped below the global maximum
        XCTAssertEqual(PeakSlice.usefulZoomCap(sourceDurationS: 10,
                                               binCount: 2000),
                       TimelineMath.maxZoom)
        XCTAssertEqual(PeakSlice.pxPerBin(sourceDurationS: 240,
                                          pxPerSecond: 40, binCount: 2000),
                       4.8, accuracy: 1e-9)
    }

    // MARK: the unanalysed grid

    /// A bench with nothing analysed draws and previews on 120 BPM, and the
    /// render has to land on the same grid. `planMix` used to send
    /// `offset_s = 0` for every clip whenever no target tempo was known, so a
    /// mix arranged across eight bars rendered with every clip stacked at bar
    /// 1 — and with nothing analysed the align bar cannot offer a tempo to
    /// set, so there was no way out from the UI.
    func testUnanalysedBenchRendersOnTheGridItWasDrawnOn() {
        let drawn = TimelineMath(bpm: nil)
        XCTAssertEqual(drawn.bpm, TimelineMath.fallbackBpm)

        let item = JobsStore.ResolvedIngredient(
            submission: IngredientSubmission(
                slotId: "a", partId: "p1", gainDb: 0, muted: false,
                offsetBeats: 16, sectionStartS: nil, sectionEndS: nil),
            kind: "song.mix", role: "mix",
            fileURL: URL(fileURLWithPath: "/tmp/p1.wav"),
            sampleRate: 44100, sourceSongTitle: "Never analysed",
            summary: nil)
        let plan = JobsStore.planMix(resolved: [item],
                                     options: RecombineOptions())
        XCTAssertNil(plan.spec.target.bpm, "nothing analysed, nothing to match")
        XCTAssertEqual(plan.spec.tracks[0].offsetS, drawn.seconds(beats: 16),
                       accuracy: 1e-9)
    }
}

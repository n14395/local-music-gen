import XCTest
@testable import LocalMusic

/// The edit program's replay: ops → segments, in the style of the timeline's
/// math tests — pure inputs, exact expectations.
final class EditModelTests: XCTestCase {

    private func segs(_ duration: Double,
                      _ kinds: [EditOp.Kind]) -> [EditSegment] {
        EditProgram.segments(sourceDuration: duration,
                             ops: kinds.map { EditOp(kind: $0) })
    }

    func testDeleteMiddleClosesTheGap() {
        let segments = segs(100, [.delete(EditRange(start: 30, end: 40))])
        XCTAssertEqual(segments, [
            EditSegment(sourceStart: 0, sourceEnd: 30),
            EditSegment(sourceStart: 40, sourceEnd: 100),
        ])
        XCTAssertEqual(EditProgram.timelineDuration(segments), 90)
    }

    func testTrimKeepsOnlyTheSelection() {
        let segments = segs(100, [.trim(EditRange(start: 20, end: 50))])
        XCTAssertEqual(segments, [EditSegment(sourceStart: 20, sourceEnd: 50)])
    }

    func testSilenceKeepsTheDuration() {
        let segments = segs(60, [.silence(EditRange(start: 10, end: 20))])
        XCTAssertEqual(segments.count, 3)
        XCTAssertTrue(segments[1].silent)
        XCTAssertEqual(segments[1].length, 10)
        XCTAssertEqual(EditProgram.timelineDuration(segments), 60)
    }

    func testInsertGapShiftsWhatFollows() {
        let segments = segs(30, [.insertGap(at: 10, seconds: 5)])
        XCTAssertEqual(EditProgram.timelineDuration(segments), 35)
        XCTAssertTrue(segments[1].silent)
        XCTAssertEqual(segments[2].sourceStart, 10)
    }

    /// Later ops are timed against the timeline the earlier ops left — the
    /// contract that makes "reopen any row" meaningful.
    func testOpsReplayAgainstTheEditedTimeline() {
        // Delete 30–40, then delete "50–60" of the NEW timeline, which is
        // source 60–70.
        let segments = segs(100, [
            .delete(EditRange(start: 30, end: 40)),
            .delete(EditRange(start: 50, end: 60)),
        ])
        XCTAssertEqual(segments, [
            EditSegment(sourceStart: 0, sourceEnd: 30),
            EditSegment(sourceStart: 40, sourceEnd: 60),
            EditSegment(sourceStart: 70, sourceEnd: 100),
        ])
    }

    func testReverseSpanningACutFlipsOrderAndDirection() {
        let segments = segs(100, [
            .delete(EditRange(start: 40, end: 60)),
            // 20–60 of the edited timeline covers source 20–40 and 60–80.
            .reverse(EditRange(start: 20, end: 60)),
        ])
        XCTAssertEqual(segments, [
            EditSegment(sourceStart: 0, sourceEnd: 20),
            EditSegment(sourceStart: 60, sourceEnd: 80, reversed: true),
            EditSegment(sourceStart: 20, sourceEnd: 40, reversed: true),
            EditSegment(sourceStart: 80, sourceEnd: 100),
        ])
        XCTAssertEqual(EditProgram.timelineDuration(segments), 80)
    }

    /// Slicing a reversed segment indexes its source from the far end: the
    /// timeline's first half of a reversed [20,40] is source [30,40].
    func testExtractFromAReversedSegment() {
        let reversed = [EditSegment(sourceStart: 20, sourceEnd: 40,
                                    reversed: true)]
        let head = EditProgram.extract(reversed,
                                       range: EditRange(start: 0, end: 10))
        XCTAssertEqual(head, [EditSegment(sourceStart: 30, sourceEnd: 40,
                                          reversed: true)])
    }

    func testAmplifySplitsAndAddsGain() {
        let segments = segs(100, [
            .amplify(EditRange(start: 10, end: 20), db: 2.5),
            .amplify(EditRange(start: 15, end: 25), db: 1.0),
        ])
        XCTAssertEqual(EditProgram.timelineDuration(segments), 100)
        // 15–20 carries both amplifications.
        let stacked = segments.first {
            abs($0.sourceStart - 15) < 1e-9 && abs($0.sourceEnd - 20) < 1e-9
        }
        XCTAssertEqual(stacked?.gainDb ?? 0, 3.5, accuracy: 1e-9)
    }

    func testPasteInsertsResolvedSlices() {
        let base = segs(100, [.delete(EditRange(start: 50, end: 100))])
        let clipboard = EditProgram.extract(base,
                                            range: EditRange(start: 10, end: 20))
        let segments = segs(100, [
            .delete(EditRange(start: 50, end: 100)),
            .paste(at: 50, slices: clipboard),
        ])
        XCTAssertEqual(EditProgram.timelineDuration(segments), 60)
        XCTAssertEqual(segments.last, EditSegment(sourceStart: 10, sourceEnd: 20))
    }

    func testMappingThroughCutsAndGaps() {
        let segments = segs(100, [
            .delete(EditRange(start: 30, end: 40)),
            .insertGap(at: 50, seconds: 5),
        ])
        // Source 45 sits after the cut: timeline 35.
        XCTAssertEqual(EditProgram.sourceToTimeline(45, in: segments) ?? -1,
                       35, accuracy: 1e-9)
        // Source 35 was deleted.
        XCTAssertNil(EditProgram.sourceToTimeline(35, in: segments))
        // Timeline 52 is inside the gap.
        XCTAssertNil(EditProgram.timelineToSource(52, in: segments))
        // Timeline 60 is past the gap: source 65.
        XCTAssertEqual(EditProgram.timelineToSource(60, in: segments) ?? -1,
                       65, accuracy: 1e-9)
    }

    func testMappingThroughAReversedRange() {
        let segments = segs(100, [.reverse(EditRange(start: 20, end: 40))])
        // Source 25 plays at timeline 35 (reversed within 20–40).
        XCTAssertEqual(EditProgram.sourceToTimeline(25, in: segments) ?? -1,
                       35, accuracy: 1e-9)
        XCTAssertEqual(EditProgram.timelineToSource(35, in: segments) ?? -1,
                       25, accuracy: 1e-9)
    }

    func testResultDurationAppliesSpeed() {
        var document = EditDocument()
        document.ops = [
            EditOp(kind: .delete(EditRange(start: 0, end: 20))),
            EditOp(kind: .speed(rate: 2)),
        ]
        XCTAssertEqual(EditProgram.resultDuration(sourceDuration: 100,
                                                  document: document),
                       40, accuracy: 1e-9)
    }

    func testWholeTrackReadingsLastRowWins() {
        var document = EditDocument()
        document.ops = [
            EditOp(kind: .fadeOut(seconds: 2, curve: .linear)),
            EditOp(kind: .fadeOut(seconds: 6, curve: .scurve)),
            EditOp(kind: .normalize(lufs: -14)),
        ]
        XCTAssertEqual(document.fadeOut?.seconds, 6)
        XCTAssertEqual(document.fadeOut?.curve, .scurve)
        XCTAssertEqual(document.normalizeLufs, -14)
        XCTAssertNil(document.fadeIn)
    }

    func testDocumentRoundTripsThroughJSON() throws {
        var document = EditDocument()
        document.ops = [
            EditOp(kind: .delete(EditRange(start: 38.42, end: 52.79))),
            EditOp(kind: .fadeIn(seconds: 1.5, curve: .linear)),
            EditOp(kind: .paste(at: 3, slices: [
                EditSegment(sourceStart: 1, sourceEnd: 2, reversed: true,
                            gainDb: -3),
            ])),
        ]
        document.effects = [.fresh(.highpass), .fresh(.compressor)]
        document.appliedAt = Date(timeIntervalSince1970: 1_766_000_000)
        document.originalDurationS = 119
        document.originalFileName = "abc.mp3"
        let data = try JSONEncoder().encode(document)
        let back = try JSONDecoder().decode(EditDocument.self, from: data)
        XCTAssertEqual(back, document)
    }

    /// A document written by a future version with fields this build has
    /// never heard of still decodes — the lenient half of the round trip.
    func testDocumentDecodesWithMissingAndUnknownFields() throws {
        let json = #"{"ops": [], "someFutureField": 7}"#
        let document = try JSONDecoder().decode(
            EditDocument.self, from: Data(json.utf8))
        XCTAssertTrue(document.isEmpty)
        XCTAssertEqual(document.joinCrossfadeMs, 8)
    }
}

/// Edit document → one-track mix job, in the style of `MixSpecTests`.
final class EditMixPlanTests: XCTestCase {

    private func makePlan(_ document: EditDocument, duration: Double = 100,
                          sampleRate: Int = 44100,
                          bpm: Double? = nil) -> EditMixPlan.Plan {
        EditMixPlan.plan(document: document, source: "SRC",
                         sourceDuration: duration, sampleRate: sampleRate,
                         sourceBpm: bpm)
    }

    private func doc(_ kinds: [EditOp.Kind]) -> EditDocument {
        var document = EditDocument()
        document.ops = kinds.map { EditOp(kind: $0) }
        return document
    }

    func testDeleteBecomesTwoTracksWithAJoinCrossfade() {
        var document = doc([.delete(EditRange(start: 30, end: 40))])
        document.joinCrossfadeMs = 8
        let plan = makePlan(document)
        XCTAssertEqual(plan.spec.tracks.count, 2)
        let a = plan.spec.tracks[0], b = plan.spec.tracks[1]
        // The join at timeline 30 overlaps by 8 ms: A extends its source past
        // the cut, B starts its source earlier and its offset moves back.
        XCTAssertEqual(a.section?.startS ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(a.section?.endS ?? -1, 30.004, accuracy: 1e-9)
        XCTAssertEqual(b.section?.startS ?? -1, 39.996, accuracy: 1e-9)
        XCTAssertEqual(b.section?.endS ?? -1, 100, accuracy: 1e-9)
        XCTAssertEqual(b.offsetS, 29.996, accuracy: 1e-9)
        XCTAssertEqual(a.fadeOutS ?? 0, 0.008, accuracy: 1e-9)
        XCTAssertEqual(b.fadeInS ?? 0, 0.008, accuracy: 1e-9)
        // Crossfade ramps stay linear — no curve is written for them.
        XCTAssertNil(a.fadeOutCurve)
        XCTAssertNil(b.fadeInCurve)
        XCTAssertEqual(plan.spec.target.durationS ?? 0, 90, accuracy: 1e-9)
        XCTAssertFalse(plan.normalize)
        XCTAssertFalse(plan.limiter)
    }

    func testCrossfadeOffCutsButt() {
        var document = doc([.delete(EditRange(start: 30, end: 40))])
        document.joinCrossfadeMs = 0
        let plan = makePlan(document)
        let a = plan.spec.tracks[0], b = plan.spec.tracks[1]
        XCTAssertEqual(a.section?.endS ?? -1, 30, accuracy: 1e-9)
        XCTAssertEqual(b.offsetS, 30, accuracy: 1e-9)
        XCTAssertNil(a.fadeOutS)
        XCTAssertNil(b.fadeInS)
    }

    func testGapLeavesAnOffsetHoleAndNoCrossfade() {
        var document = doc([.silence(EditRange(start: 10, end: 15))])
        document.joinCrossfadeMs = 8
        let plan = makePlan(document, duration: 30)
        XCTAssertEqual(plan.spec.tracks.count, 2)
        // Second real track starts after the hole, un-crossfaded: the silent
        // segment sits between the two, so there is no join to mask.
        XCTAssertEqual(plan.spec.tracks[1].offsetS, 15, accuracy: 1e-9)
        XCTAssertNil(plan.spec.tracks[0].fadeOutS)
        XCTAssertEqual(plan.spec.target.durationS ?? 0, 30, accuracy: 1e-9)
    }

    func testFadesLandOnTheEndTracksWithCurves() {
        var document = doc([
            .delete(EditRange(start: 30, end: 40)),
            .fadeIn(seconds: 1.5, curve: .linear),
            .fadeOut(seconds: 6, curve: .scurve),
        ])
        document.joinCrossfadeMs = 0
        let plan = makePlan(document)
        XCTAssertEqual(plan.spec.tracks[0].fadeInS ?? 0, 1.5, accuracy: 1e-9)
        XCTAssertNil(plan.spec.tracks[0].fadeInCurve)   // linear is the default
        XCTAssertEqual(plan.spec.tracks[1].fadeOutS ?? 0, 6, accuracy: 1e-9)
        XCTAssertEqual(plan.spec.tracks[1].fadeOutCurve, "scurve")
    }

    /// A fade longer than the segment that carries it fades that whole
    /// segment — the engine's ramps cannot start mid-gain.
    func testFadeClampsToItsSegment() {
        let document = doc([
            .trim(EditRange(start: 0, end: 4)),
            .fadeOut(seconds: 10, curve: .linear),
        ])
        let plan = makePlan(document)
        XCTAssertEqual(plan.spec.tracks[0].fadeOutS ?? 0, 4, accuracy: 1e-9)
    }

    func testNormalizeAndAmplifyDriveTheParams() {
        let plan = makePlan(doc([.normalize(lufs: -12)]))
        XCTAssertTrue(plan.normalize)
        XCTAssertTrue(plan.limiter)
        XCTAssertEqual(plan.targetLufs, -12)

        let boosted = makePlan(doc([
            .amplify(EditRange(start: 0, end: 10), db: 2.5),
        ]))
        XCTAssertFalse(boosted.normalize)
        XCTAssertTrue(boosted.limiter)   // a raise can clip; the cut cannot
        XCTAssertEqual(boosted.spec.tracks.first?.gainDb ?? 0, 2.5,
                       accuracy: 1e-9)

        let cut = makePlan(doc([
            .amplify(EditRange(start: 0, end: 10), db: -2.5),
        ]))
        XCTAssertFalse(cut.limiter)
    }

    func testSpeedScalesOffsetsAndSetsUniformStretch() {
        var document = doc([
            .delete(EditRange(start: 30, end: 40)),
            .speed(rate: 2),
        ])
        document.joinCrossfadeMs = 0
        let plan = makePlan(document, bpm: 86)
        XCTAssertEqual(plan.spec.target.bpm ?? 0, 172, accuracy: 1e-9)
        XCTAssertEqual(plan.spec.tracks[0].stretch.mode, "uniform")
        XCTAssertEqual(plan.spec.tracks[0].sourceBpm ?? 0, 86, accuracy: 1e-9)
        // The second segment starts at edit-time 30 → target-time 15.
        XCTAssertEqual(plan.spec.tracks[1].offsetS, 15, accuracy: 1e-9)
        XCTAssertEqual(plan.spec.target.durationS ?? 0, 45, accuracy: 1e-9)
    }

    func testPitchAloneRidesWithoutStretch() {
        let plan = makePlan(doc([.pitch(semitones: 2)]))
        XCTAssertEqual(plan.spec.tracks[0].stretch.mode, "none")
        XCTAssertEqual(plan.spec.tracks[0].pitchShiftSt, 2, accuracy: 1e-9)
        XCTAssertNil(plan.spec.target.bpm)
    }

    func testReverseAndEffectsReachTheWire() {
        var document = doc([.reverse(EditRange(start: 0, end: 100))])
        document.effects = [.fresh(.highpass), .fresh(.eq3), .fresh(.gate)]
        document.effects[2].enabled = false
        let plan = makePlan(document)
        let track = plan.spec.tracks[0]
        XCTAssertEqual(track.reverse, true)
        XCTAssertEqual(track.effects?.map(\.type), ["highpass", "eq3"])
        XCTAssertEqual(track.effects?.first?.cutoffHz ?? 0, 80, accuracy: 1e-9)
    }

    func testResampleSetsTheTargetRate() {
        let plan = makePlan(doc([.resample(hz: 48000)]))
        XCTAssertEqual(plan.spec.target.sampleRate, 48000)
    }
}

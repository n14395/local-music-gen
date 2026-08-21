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

    /// Amplify SETS a region's level. Two rows over the same audio mean the
    /// later one won, not that the two add — the control is a slider
    /// reading the level the region is at.
    func testAmplifySetsTheLevelRatherThanAddingToIt() {
        let segments = segs(100, [
            .amplify(EditRange(start: 10, end: 20), db: 2.5),
            .amplify(EditRange(start: 15, end: 25), db: 1.0),
        ])
        XCTAssertEqual(EditProgram.timelineDuration(segments), 100)
        let overlap = segments.first {
            abs($0.sourceStart - 15) < 1e-9 && abs($0.sourceEnd - 20) < 1e-9
        }
        XCTAssertEqual(overlap?.gainDb ?? -1, 1.0, accuracy: 1e-9)
        // The part of the first region the second did not cover keeps its.
        let untouched = segments.first {
            abs($0.sourceStart - 10) < 1e-9 && abs($0.sourceEnd - 15) < 1e-9
        }
        XCTAssertEqual(untouched?.gainDb ?? -1, 2.5, accuracy: 1e-9)
    }

    /// The case a re-timed ruler used to break: an amplify, then a cut that
    /// moves the audio, then amplifying that same audio again at its new
    /// position. It must end at the level asked for, not at twice it.
    func testAmplifyingTheSameAudioAfterACutDoesNotDouble() {
        let segments = segs(100, [
            .amplify(EditRange(start: 30, end: 40), db: 6),
            .delete(EditRange(start: 0, end: 10)),
            // The same audio now sits at 20–30 on the ruler.
            .amplify(EditRange(start: 20, end: 30), db: 6),
        ])
        let region = segments.first {
            abs($0.sourceStart - 30) < 1e-9 && abs($0.sourceEnd - 40) < 1e-9
        }
        XCTAssertEqual(region?.gainDb ?? -1, 6, accuracy: 1e-9)
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

    /// Crossfade "off" is the shortest honest join, not none: the engine
    /// applies a 2 ms de-click to every section trim whatever the caller
    /// asks for, so butt-joining two sections puts their two ramps in
    /// disjoint windows and the sum dips to digital silence. The floor makes
    /// them overlap so they sum back to unity.
    func testCrossfadeOffStillLapsTheEngineDeclick() {
        var document = doc([.delete(EditRange(start: 30, end: 40))])
        document.joinCrossfadeMs = 0
        let plan = makePlan(document)
        let a = plan.spec.tracks[0], b = plan.spec.tracks[1]
        let floor = EditMixPlan.engineEdgeFadeS * 2
        XCTAssertEqual(a.fadeOutS ?? 0, floor, accuracy: 1e-9)
        XCTAssertEqual(b.fadeInS ?? 0, floor, accuracy: 1e-9)
        XCTAssertEqual(a.section?.endS ?? -1, 30 + floor / 2, accuracy: 1e-9)
        XCTAssertEqual(b.offsetS, 30 - floor / 2, accuracy: 1e-9)
    }

    /// A split is bookkeeping: the source runs straight through it, so it
    /// must render as ONE track. Two abutting tracks would each get the
    /// engine's de-click and leave a hole in audio nothing changed.
    func testSplitCoalescesIntoASingleTrack() {
        var document = doc([.splitAt(50)])
        document.joinCrossfadeMs = 8
        let plan = makePlan(document)
        XCTAssertEqual(plan.spec.tracks.count, 1)
        XCTAssertEqual(plan.spec.tracks[0].section?.startS ?? -1, 0,
                       accuracy: 1e-9)
        XCTAssertEqual(plan.spec.tracks[0].section?.endS ?? -1, 100,
                       accuracy: 1e-9)
        XCTAssertNil(plan.spec.tracks[0].fadeOutS)
    }

    /// The same holds for a delete whose two sides are then rejoined by a
    /// later trim — only genuine discontinuities become separate tracks.
    func testAdjacentSameGainRunsCoalesceButCutsDoNot() {
        var document = doc([
            .splitAt(20),
            .splitAt(40),
            .delete(EditRange(start: 60, end: 70)),
        ])
        document.joinCrossfadeMs = 8
        let plan = makePlan(document)
        XCTAssertEqual(plan.spec.tracks.count, 2,
                       "three splits are one run; the delete makes the second")
        XCTAssertEqual(plan.spec.tracks[0].section?.startS ?? -1, 0,
                       accuracy: 1e-9)
        XCTAssertEqual(plan.spec.tracks[1].section?.endS ?? -1, 100,
                       accuracy: 1e-9)
    }

    /// A run of REVERSED segments grows downward through the source. The
    /// merged section must cover everything the run played — growing the
    /// wrong end drops the material it started from, and the render comes
    /// back half the length it should be.
    func testReversedRunsCoalesceOverTheWholeSpan() {
        var document = doc([
            .splitAt(50),
            .reverse(EditRange(start: 0, end: 100)),
        ])
        document.joinCrossfadeMs = 8
        let plan = makePlan(document)
        XCTAssertEqual(plan.spec.tracks.count, 1,
                       "the two reversed halves are one unbroken run")
        let track = plan.spec.tracks[0]
        XCTAssertEqual(track.reverse, true)
        XCTAssertEqual(track.section?.startS ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(track.section?.endS ?? -1, 100, accuracy: 1e-9,
                       "the whole source, not just the half it began on")
        XCTAssertEqual(plan.spec.target.durationS ?? 0, 100, accuracy: 1e-9)
    }

    /// Every track's section must be a real slice of the source and cover
    /// what the timeline says it does — the property that both directions of
    /// the merge have to preserve.
    func testEverySectionCoversItsTimelineExtent() {
        for kinds in [
            [EditOp.Kind.splitAt(30), .splitAt(60)],
            [.reverse(EditRange(start: 20, end: 80))],
            [.splitAt(50), .reverse(EditRange(start: 0, end: 100))],
            [.delete(EditRange(start: 30, end: 40)), .splitAt(20)],
            [.reverse(EditRange(start: 0, end: 50)),
             .reverse(EditRange(start: 50, end: 100))],
        ] {
            let document = doc(kinds)
            let plan = makePlan(document)
            let timeline = EditProgram.timelineDuration(
                EditProgram.segments(sourceDuration: 100,
                                     ops: document.ops))
            let played = plan.spec.tracks.reduce(0.0) { total, track in
                total + max(0, (track.section?.endS ?? 0)
                            - (track.section?.startS ?? 0))
            }
            // Sections are lapped by the join crossfades, so the sum is the
            // timeline plus the overlaps — never less, and never wildly more.
            XCTAssertGreaterThanOrEqual(played, timeline - 1e-6, "\(kinds)")
            XCTAssertLessThanOrEqual(played, timeline + 0.5, "\(kinds)")
            for track in plan.spec.tracks {
                XCTAssertGreaterThanOrEqual(track.section?.startS ?? 0, 0)
                XCTAssertLessThanOrEqual(track.section?.endS ?? 0, 100)
                XCTAssertGreaterThanOrEqual(track.offsetS, 0)
            }
        }
    }

    /// Amplify splits a run by level, so its edges are real joins.
    func testAmplifiedRegionBecomesItsOwnTrack() {
        let plan = makePlan(doc([
            .amplify(EditRange(start: 30, end: 40), db: 3),
        ]))
        XCTAssertEqual(plan.spec.tracks.count, 3)
        XCTAssertEqual(plan.spec.tracks[1].gainDb, 3, accuracy: 1e-9)
    }

    /// The engine fails a job whose `offset_s` is negative, so lapping the
    /// second side earlier must never take it below zero.
    func testCrossfadeNeverProducesANegativeOffset() {
        var document = doc([.delete(EditRange(start: 0.001, end: 40))])
        document.joinCrossfadeMs = 200
        let plan = makePlan(document)
        for track in plan.spec.tracks {
            XCTAssertGreaterThanOrEqual(track.offsetS, 0)
            XCTAssertGreaterThanOrEqual(track.section?.startS ?? 0, 0)
            XCTAssertLessThanOrEqual(track.section?.endS ?? 0, 100)
        }
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
        XCTAssertEqual(boosted.spec.tracks.count, 2,
                       "the amplified region is its own track")

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
        // The second segment starts at edit-time 30 → target-time 15, less
        // half the join overlap.
        XCTAssertEqual(plan.spec.tracks[1].offsetS, 15, accuracy: 0.01)
        XCTAssertEqual(plan.spec.target.durationS ?? 0, 45, accuracy: 1e-9)
    }

    /// Fades are authored in timeline seconds but the engine applies them
    /// after stretching, so they go out in target time — a 6 s fade on a
    /// double-speed track is 3 s of rendered audio.
    func testFadesAreConvertedToTargetTime() {
        var document = doc([
            .fadeOut(seconds: 6, curve: .linear),
            .speed(rate: 2),
        ])
        document.joinCrossfadeMs = 0
        let plan = makePlan(document, bpm: 100)
        XCTAssertEqual(plan.spec.tracks[0].fadeOutS ?? 0, 3, accuracy: 1e-9)
    }

    /// Silencing everything leaves nothing to render; the engine fails such
    /// a job outright, so the plan says so before anything is submitted.
    func testAllSilentProgramIsNotRenderable() {
        let plan = makePlan(doc([.silence(EditRange(start: 0, end: 100))]))
        XCTAssertTrue(plan.spec.tracks.isEmpty)
        XCTAssertFalse(plan.isRenderable)

        XCTAssertTrue(makePlan(doc([])).isRenderable)
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

/// The join-crossfade floor, which exists so two of the engine's de-click
/// ramps can never land in disjoint windows and leave a hole.
final class EditJoinFloorTests: XCTestCase {

    private func plan(_ kinds: [EditOp.Kind], crossfadeMs: Double,
                      duration: Double = 100) -> EditMixPlan.Plan {
        var document = EditDocument()
        document.ops = kinds.map { EditOp(kind: $0) }
        document.joinCrossfadeMs = crossfadeMs
        return EditMixPlan.plan(document: document, source: "SRC",
                                sourceDuration: duration, sampleRate: 44100,
                                sourceBpm: nil)
    }

    /// Every real join carries complementary ramps of at least the engine's
    /// own de-click width — whatever the user set the chip to.
    func testEveryJoinIsLappedAtLeastToTheDeclickWidth() {
        let floor = EditMixPlan.engineEdgeFadeS * 2
        for crossfade in [0.0, 4.0, 8.0, 40.0] {
            let p = plan([.delete(EditRange(start: 30, end: 40))],
                         crossfadeMs: crossfade)
            XCTAssertEqual(p.spec.tracks.count, 2)
            let out = p.spec.tracks[0].fadeOutS ?? 0
            let into = p.spec.tracks[1].fadeInS ?? 0
            XCTAssertGreaterThanOrEqual(out, floor - 1e-9, "\(crossfade) ms")
            XCTAssertEqual(out, into, accuracy: 1e-9,
                           "the two ramps are complementary")
        }
    }

    /// A join at the source's own extremes — a tail spliced onto a head —
    /// has nothing beyond either side to lap into. The overlap comes out of
    /// the material instead, rather than leaving the hole.
    func testAJoinWithNoSourceBeyondItIsStillLapped() {
        // Keep the last 20 s, then paste the first 10 s after it: the join
        // is sourceDuration meeting source 0.
        var document = EditDocument()
        let head = [EditSegment(sourceStart: 0, sourceEnd: 10)]
        document.ops = [
            EditOp(kind: .trim(EditRange(start: 80, end: 100))),
            EditOp(kind: .paste(at: 20, slices: head)),
        ]
        document.joinCrossfadeMs = 0
        let p = EditMixPlan.plan(document: document, source: "SRC",
                                 sourceDuration: 100, sampleRate: 44100,
                                 sourceBpm: nil)
        XCTAssertEqual(p.spec.tracks.count, 2)
        let out = p.spec.tracks[0].fadeOutS ?? 0
        XCTAssertGreaterThanOrEqual(out, EditMixPlan.engineEdgeFadeS * 2 - 1e-9,
                                    "no source to extend into, so the "
                                        + "overlap comes from the material")
        XCTAssertEqual(p.spec.tracks[1].fadeInS ?? 0, out, accuracy: 1e-9)
        for track in p.spec.tracks {
            XCTAssertGreaterThanOrEqual(track.offsetS, 0)
            XCTAssertGreaterThanOrEqual(track.section?.startS ?? 0, 0)
            XCTAssertLessThanOrEqual(track.section?.endS ?? 0, 100)
        }
    }

    /// Borrowed overlap shortens the timeline, so everything after it has to
    /// move with it. Applied to one track and not the next, it just moves the
    /// hole one join along — which is what this pins.
    func testBorrowedOverlapShiftsEverythingAfterIt() {
        // Three copies of the whole track back to back: every join has the
        // source's end meeting the source's start, so no join has material
        // beyond it to lap into and all three must borrow.
        var document = EditDocument()
        let whole = [EditSegment(sourceStart: 0, sourceEnd: 100)]
        document.ops = [
            EditOp(kind: .paste(at: 100, slices: whole)),
            EditOp(kind: .paste(at: 200, slices: whole)),
        ]
        document.joinCrossfadeMs = 0
        let p = EditMixPlan.plan(document: document, source: "SRC",
                                 sourceDuration: 100, sampleRate: 44100,
                                 sourceBpm: nil)
        XCTAssertEqual(p.spec.tracks.count, 3)
        // Each track's real overlap with the one before it must equal the
        // fade both of them declare.
        for i in 0..<(p.spec.tracks.count - 1) {
            let a = p.spec.tracks[i], b = p.spec.tracks[i + 1]
            let aEnd = a.offsetS + (a.section.map { $0.endS - $0.startS } ?? 0)
            let declared = a.fadeOutS ?? 0
            XCTAssertEqual(b.fadeInS ?? 0, declared, accuracy: 1e-9)
            XCTAssertEqual(aEnd - b.offsetS, declared, accuracy: 1e-6,
                           "join \(i): the real overlap must be the declared "
                               + "one, not one shortfall less")
            XCTAssertGreaterThan(declared, 0)
        }
        // And the announced length matches where the last track actually ends.
        let last = p.spec.tracks[p.spec.tracks.count - 1]
        let end = last.offsetS
            + (last.section.map { $0.endS - $0.startS } ?? 0)
        XCTAssertEqual(p.spec.target.durationS ?? 0, end, accuracy: 1e-6)
    }

    /// A gap is not a join: silence between two runs must stay silent.
    func testAGapIsNotLapped() {
        let p = plan([.silence(EditRange(start: 30, end: 40))],
                     crossfadeMs: 8)
        XCTAssertEqual(p.spec.tracks.count, 2)
        XCTAssertNil(p.spec.tracks[0].fadeOutS)
        XCTAssertNil(p.spec.tracks[1].fadeInS)
        XCTAssertEqual(p.spec.tracks[1].offsetS, 40, accuracy: 1e-9)
    }
}

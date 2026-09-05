import XCTest
@testable import LocalMusicGen

@MainActor
final class WorkbenchLogicTests: XCTestCase {
    private func material(_ id: String, kind: String) -> PickedMaterial {
        var m = PickedMaterial(
            song: SongRecord(
                id: id, title: id, prompt: "", lyrics: nil, modelId: "m",
                modelName: "M", groupId: nil, paramsJSON: "{}", durationS: 10,
                sampleRate: 44100, fileName: "\(id).wav", seedUsed: nil,
                createdAt: Date(), rating: 0, notes: "", favorite: false,
                origin: "generated"))
        m.kind = kind
        return m
    }

    /// One lane holding one clip — the shape `add(material:)` produces.
    @discardableResult
    private func addLane(_ model: WorkbenchModel, _ id: String,
                         kind: String = "stem.vocals",
                         name: String? = nil) -> WorkbenchModel.Clip {
        let lane = WorkbenchModel.Lane(name: name ?? id)
        model.lanes.append(lane)
        var clip = WorkbenchModel.Clip(laneId: lane.id,
                                       material: material(id, kind: kind))
        clip.sourceDurationS = 10
        model.clips.append(clip)
        return clip
    }

    private func lastLane(_ model: WorkbenchModel) -> WorkbenchModel.Lane {
        model.lanes[model.lanes.count - 1]
    }

    // MARK: placement

    func testIngredientsCarryPlacement() {
        let model = WorkbenchModel()
        addLane(model, "a", name: "Vocals")
        model.clips[0].startBeats = 16
        model.clips[0].gainDb = -6
        model.clips[0].sectionStartS = 10
        model.clips[0].sectionEndS = 20
        let subs = model.ingredients()
        XCTAssertEqual(subs.count, 1)
        XCTAssertEqual(subs[0].offsetBeats, 16)
        XCTAssertEqual(subs[0].gainDb, -6)
        XCTAssertEqual(subs[0].sectionStartS, 10)
        XCTAssertEqual(subs[0].sectionEndS, 20)
        XCTAssertEqual(subs[0].slotId, "vocals-1")
    }

    /// Placement is fractional end to end: the wire field was always a Double
    /// and the engine now places to the sample, so half a beat survives.
    func testIngredientsCarryFractionalBeats() {
        let model = WorkbenchModel()
        addLane(model, "a")
        model.clips[0].startBeats = 6.5
        XCTAssertEqual(model.ingredients()[0].offsetBeats, 6.5)
    }

    /// The simple flow — stack two stems, hit Create Mix — must keep producing
    /// exactly what it did before lanes existed.
    func testTwoStemBenchProducesOneIngredientEach() {
        let model = WorkbenchModel()
        model.add(material: material("v", kind: "stem.vocals"), parts: nil)
        model.add(material: material("d", kind: "stem.drums"), parts: nil)
        let subs = model.ingredients()
        XCTAssertEqual(subs.count, 2)
        XCTAssertEqual(subs.map(\.partId), ["v", "d"])
        XCTAssertEqual(subs.map(\.offsetBeats), [0, 0])
        XCTAssertEqual(subs.map(\.gainDb), [0, 0])
        XCTAssertEqual(subs.map(\.muted), [false, false])
        XCTAssertEqual(model.lanes.count, 2, "one lane per added part")
    }

    // MARK: lane folding

    func testNoSoloRespectsMutes() {
        let model = WorkbenchModel()
        addLane(model, "a")
        model.lanes[0].muted = true
        addLane(model, "b")
        let map = WorkbenchModel.effectivelyMuted(lanes: model.lanes,
                                                  clips: model.clips)
        XCTAssertEqual(map[model.clips[0].id], true)
        XCTAssertEqual(map[model.clips[1].id], false)
    }

    func testLaneSoloSilencesEveryOtherLane() {
        let model = WorkbenchModel()
        addLane(model, "a")
        addLane(model, "b")
        addLane(model, "c")
        model.lanes[0].solo = true
        model.lanes[0].muted = true      // solo wins over the lane's own mute
        model.lanes[2].muted = true
        let map = WorkbenchModel.effectivelyMuted(lanes: model.lanes,
                                                  clips: model.clips)
        XCTAssertEqual(map[model.clips[0].id], false)
        XCTAssertEqual(map[model.clips[1].id], true)
        XCTAssertEqual(map[model.clips[2].id], true)
    }

    func testTwoSolosBothPlay() {
        let model = WorkbenchModel()
        addLane(model, "a")
        addLane(model, "b")
        addLane(model, "c")
        model.lanes[0].solo = true
        model.lanes[1].solo = true
        let map = WorkbenchModel.effectivelyMuted(lanes: model.lanes,
                                                  clips: model.clips)
        XCTAssertEqual(map[model.clips[0].id], false)
        XCTAssertEqual(map[model.clips[1].id], false)
        XCTAssertEqual(map[model.clips[2].id], true)
    }

    func testAClipsOwnMuteSurvivesItsLaneBeingAudible() {
        let model = WorkbenchModel()
        addLane(model, "a")
        model.clips[0].muted = true
        let map = WorkbenchModel.effectivelyMuted(lanes: model.lanes,
                                                  clips: model.clips)
        XCTAssertEqual(map[model.clips[0].id], true)
        XCTAssertTrue(model.ingredients()[0].muted)
    }

    /// Lane and clip faders are in series, like a desk.
    func testLaneGainAddsToClipGain() {
        let model = WorkbenchModel()
        addLane(model, "a")
        model.lanes[0].gainDb = -6
        model.clips[0].gainDb = -3
        XCTAssertEqual(model.ingredients()[0].gainDb, -9)
    }

    // MARK: multiple clips per lane

    func testDuplicateKeepsThePartAndLandsAfterItself() {
        let model = WorkbenchModel()
        let clip = addLane(model, "a", name: "Drums")
        model.targetBpm = 120                 // 10 s source = 20 beats
        let copy = model.duplicate(clip.id)
        XCTAssertEqual(model.clips.count, 2)
        XCTAssertEqual(copy?.material.id, "a", "same part, new placement")
        XCTAssertNotEqual(copy?.id, clip.id)
        XCTAssertEqual(copy?.laneId, clip.laneId)
        XCTAssertEqual(try XCTUnwrap(copy?.startBeats), 20, accuracy: 1e-9)
    }

    func testEveryAudibleClipBecomesExactlyOneIngredient() {
        let model = WorkbenchModel()
        let clip = addLane(model, "a", name: "Drums")
        model.duplicate(clip.id)
        model.duplicate(clip.id, atBeats: 64)
        let subs = model.ingredients()
        XCTAssertEqual(subs.count, 3)
        XCTAssertEqual(Set(subs.map(\.partId)), ["a"])
        XCTAssertEqual(Set(subs.map(\.slotId)).count, 3, "slotIds are unique")
    }

    /// slotId is the (songId, slotId) primary key AND what the provenance list
    /// shows, so it has to be both unique and readable.
    func testSlotIdsEncodeLaneAndOrder() {
        let model = WorkbenchModel()
        let vocals = addLane(model, "v", name: "Vocals")
        addLane(model, "d", name: "Drums")
        model.duplicate(vocals.id, atBeats: 32)
        XCTAssertEqual(model.ingredients().map(\.slotId),
                       ["vocals-1", "vocals-2", "drums-1"])
    }

    func testSlotIdSlugHandlesAwkwardLaneNames() {
        XCTAssertEqual(WorkbenchModel.slugged("Other (keys, synths)"),
                       "other-keys-synths")
        XCTAssertEqual(WorkbenchModel.slugged("  "), "clip")
    }

    func testOrderingIsLaneThenTime() {
        let model = WorkbenchModel()
        let a = addLane(model, "a", name: "A")
        addLane(model, "b", name: "B")
        model.duplicate(a.id, atBeats: 8)
        model.clips[0].startBeats = 16          // push the original later
        let subs = model.ingredients()
        XCTAssertEqual(subs.map(\.offsetBeats), [8, 16, 0])
    }

    // MARK: missing material

    func testMissingClipsNeverReachTheRender() {
        let model = WorkbenchModel()
        addLane(model, "a")
        addLane(model, "b")
        model.clips[1].isMissing = true
        XCTAssertTrue(model.hasMissingClips)
        XCTAssertEqual(model.ingredients().count, 1)
        XCTAssertEqual(model.ingredients()[0].partId, "a")
    }

    // MARK: target inference

    func testEffectiveTargetsFallBackToFirstAnalyzedClip() {
        let model = WorkbenchModel()
        addLane(model, "a")
        addLane(model, "b")
        model.clips[1].summary = AnalysisSummary(bpm: 124, camelot: "8A")
        XCTAssertEqual(model.effectiveTargetBpm, 124)
        XCTAssertEqual(model.effectiveTargetCamelot, "8A")
        model.targetBpm = 100
        XCTAssertEqual(model.effectiveTargetBpm, 100)
    }

    // MARK: clip length

    func testClipLengthFollowsTrimAndStretch() {
        let model = WorkbenchModel()
        let clip = addLane(model, "a")
        model.clips[0].summary = AnalysisSummary(bpm: 60)
        model.targetBpm = 120
        // 10 s at 60 BPM is 10 beats, and stretching preserves beats
        XCTAssertEqual(model.lengthBeats(of: model.clips[0]), 10,
                       accuracy: 1e-9)
        model.clips[0].sectionStartS = 0
        model.clips[0].sectionEndS = 5
        XCTAssertEqual(model.lengthBeats(of: model.clips[0]), 5, accuracy: 1e-9)
        _ = clip
    }

    func testShiftAllKeepsSpacingAndNeverGoesNegative() {
        let model = WorkbenchModel()
        addLane(model, "a")
        addLane(model, "b")
        model.clips[0].startBeats = 0
        model.clips[1].startBeats = 8
        model.shiftAll(byBeats: -4)
        XCTAssertEqual(model.clips.map(\.startBeats), [0, 8])
        model.shiftAll(byBeats: 4)
        XCTAssertEqual(model.clips.map(\.startBeats), [4, 12])
    }

    // MARK: narration

    private func tempo(_ ratio: Double, source: Double = 119) -> TempoMatch {
        TempoMatch(score: 1 - abs(ratio - 1) * 4,
                   stretchRatio: ratio, stretchPercent: abs(ratio - 1) * 100,
                   halfTimeFold: false, foldedSourceBpm: source)
    }

    func testNarrationDescribesThePlan() {
        let plan = MatchPlan(
            stretchRatio: 1.042, pitchShiftSt: -1,
            badges: MatchBadges(tempo: tempo(1.042), key: nil, harmonic: nil,
                                spectral: nil, stars: 4))
        let text = MatchNarrator.narrate([("Drums (Song B)", plan)])
        XCTAssertEqual(
            text, "Will stretch Drums (Song B) by +4.2% and shift "
                + "Drums (Song B) down 1 semitone.")
    }

    func testNarrationNilWhenNothingToDo() {
        let plan = MatchPlan(
            stretchRatio: 1.001, pitchShiftSt: 0,
            badges: MatchBadges(tempo: tempo(1.001), key: nil, harmonic: nil,
                                spectral: nil, stars: 5))
        XCTAssertNil(MatchNarrator.narrate([("Vocals", plan)]))
    }

    /// Mashability nils out red-quality ratios for its badges, but the mix
    /// stretches anyway — so the biggest stretches used to be the ones nobody
    /// was told about.
    func testNarrationCoversStretchesTooBigToRecommend() {
        let plan = MatchPlan(
            stretchRatio: nil, pitchShiftSt: 0,
            badges: MatchBadges(tempo: tempo(1.265, source: 98), key: nil,
                                harmonic: nil, spectral: nil, stars: 2))
        XCTAssertEqual(MatchNarrator.narrate([("Vocals", plan)]),
                       "Will stretch Vocals by +26.5%.")
    }
}

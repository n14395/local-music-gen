import XCTest
@testable import LocalMusic

/// Drag arithmetic and the clip operations behind the timeline's menus.
@MainActor
final class ClipEditingTests: XCTestCase {

    private let math = TimelineMath(bpm: 120, beatsPerBar: 4, pxPerSecond: 10)

    private func material(_ id: String, kind: String = "stem.vocals",
                          duration: Double = 60) -> PickedMaterial {
        var m = PickedMaterial(
            song: SongRecord(
                id: id, title: id, prompt: "", lyrics: nil, modelId: "m",
                modelName: "M", groupId: nil, paramsJSON: "{}",
                durationS: duration, sampleRate: 44100, fileName: "\(id).wav",
                seedUsed: nil, createdAt: Date(), rating: 0, notes: "",
                favorite: false, origin: "generated"))
        m.kind = kind
        return m
    }

    // MARK: grabbing

    func testEdgesGrabHandlesAndTheMiddleGrabsTheBody() {
        XCTAssertEqual(ClipDrag.grab(atX: 2, width: 200), .leadingEdge)
        XCTAssertEqual(ClipDrag.grab(atX: 100, width: 200), .body)
        XCTAssertEqual(ClipDrag.grab(atX: 197, width: 200), .trailingEdge)
    }

    /// A narrow clip must still be movable rather than being all handle.
    func testNarrowClipKeepsABody() {
        XCTAssertEqual(ClipDrag.grab(atX: 8, width: 16), .body)
    }

    // MARK: moving

    func testMoveSnapsThenClamps() {
        // 10 px/s at 120 BPM = 5 px per beat, 20 px per bar
        XCTAssertEqual(ClipDrag.movedStart(originalBeats: 0, deltaX: 43,
                                           math: math, snap: .bar),
                       8, accuracy: 1e-9)
        XCTAssertEqual(ClipDrag.movedStart(originalBeats: 0, deltaX: 43,
                                           math: math, snap: .beat),
                       9, accuracy: 1e-9)
        XCTAssertEqual(ClipDrag.movedStart(originalBeats: 0, deltaX: 43,
                                           math: math, snap: .off),
                       8.6, accuracy: 1e-9)
    }

    /// Snapping must not be able to push a clip before zero — the engine
    /// rejects a negative offset outright.
    func testMoveNeverGoesBeforeZero() {
        XCTAssertEqual(ClipDrag.movedStart(originalBeats: 4, deltaX: -500,
                                           math: math, snap: .bar), 0)
    }

    func testLaneChangeFollowsVerticalDistance() {
        XCTAssertEqual(ClipDrag.laneIndex(originalIndex: 0, deltaY: 70,
                                          laneHeight: 60, laneCount: 3), 1)
        XCTAssertEqual(ClipDrag.laneIndex(originalIndex: 2, deltaY: -200,
                                          laneHeight: 60, laneCount: 3), 0)
        XCTAssertEqual(ClipDrag.laneIndex(originalIndex: 2, deltaY: 500,
                                          laneHeight: 60, laneCount: 3), 2)
    }

    // MARK: trimming

    /// planMix only emits a section when BOTH bounds are set, so a trim must
    /// always write both or it silently vanishes on the wire.
    func testTrimAlwaysWritesBothBounds() throws {
        let trim = try XCTUnwrap(
            ClipDrag.trim(grab: .trailingEdge, deltaX: -100, math: math,
                          clipStartBeats: 0, sectionStartS: nil,
                          sectionEndS: nil, sourceDurationS: 60,
                          stretchFactor: 1))
        XCTAssertEqual(trim.sectionStartS, 0)
        XCTAssertEqual(trim.sectionEndS, 50)     // 100 px at 10 px/s = 10 s
    }

    /// Trimming the head moves the clip's start by the same amount, or the
    /// audio slides against everything else on the timeline.
    func testTrimmingTheHeadMovesTheClipToo() {
        let trim = ClipDrag.trim(grab: .leadingEdge, deltaX: 100, math: math,
                                 clipStartBeats: 8, sectionStartS: nil,
                                 sectionEndS: nil, sourceDurationS: 60,
                                 stretchFactor: 1)
        XCTAssertEqual(trim?.sectionStartS, 10)
        XCTAssertEqual(trim?.sectionEndS, 60)
        // 10 s later at 120 BPM is 20 beats later
        XCTAssertEqual(try XCTUnwrap(trim?.startBeats), 28, accuracy: 1e-9)
    }

    /// Pixels are target time, the section is source time — on a stretched clip
    /// the edge would run away from the pointer without the factor.
    func testTrimConvertsThroughTheStretchFactor() {
        let trim = ClipDrag.trim(grab: .trailingEdge, deltaX: -100, math: math,
                                 clipStartBeats: 0, sectionStartS: 0,
                                 sectionEndS: 60, sourceDurationS: 60,
                                 stretchFactor: 0.5)
        XCTAssertEqual(trim?.sectionEndS, 55)   // 10 target s = 5 source s
    }

    func testTrimStaysInsideTheSourceAndKeepsAMinimumLength() {
        let past = ClipDrag.trim(grab: .trailingEdge, deltaX: 10_000,
                                 math: math, clipStartBeats: 0,
                                 sectionStartS: nil, sectionEndS: nil,
                                 sourceDurationS: 60, stretchFactor: 1)
        XCTAssertEqual(past?.sectionEndS, 60)
        let collapsed = ClipDrag.trim(grab: .leadingEdge, deltaX: 10_000,
                                      math: math, clipStartBeats: 0,
                                      sectionStartS: nil, sectionEndS: nil,
                                      sourceDurationS: 60, stretchFactor: 1)
        XCTAssertGreaterThan(try XCTUnwrap(collapsed?.sectionEndS)
                             - (collapsed?.sectionStartS ?? 0), 0.2)
    }

    func testDraggingTheBodyIsNotATrim() {
        XCTAssertNil(ClipDrag.trim(grab: .body, deltaX: 40, math: math,
                                   clipStartBeats: 0, sectionStartS: nil,
                                   sectionEndS: nil, sourceDurationS: 60,
                                   stretchFactor: 1))
    }

    // MARK: explode into sections

    private func modelWithSections() -> (WorkbenchModel, String) {
        let model = WorkbenchModel()
        model.targetBpm = 120
        let clip = model.add(material: material("p1"), parts: nil)
        guard let index = model.clips.firstIndex(where: { $0.id == clip.id })
        else { return (model, clip.id) }
        model.clips[index].sourceDurationS = 60
        model.clips[index].summary = AnalysisSummary(bpm: 120)
        model.clips[index].sections = [
            .init(startS: 0, endS: 10, group: "A", label: nil),
            .init(startS: 10, endS: 30, group: "B", label: nil),
            .init(startS: 30, endS: 60, group: "A", label: nil),
        ]
        return (model, clip.id)
    }

    func testExplodeLaysSectionsBackToBackOnOneLane() {
        let (model, id) = modelWithSections()
        let made = model.explodeIntoSections(id)
        XCTAssertEqual(made.count, 3)
        XCTAssertEqual(model.clips.count, 3, "the source clip is replaced")
        XCTAssertEqual(Set(model.clips.map(\.laneId)).count, 1)
        // 120 BPM: 10 s = 20 beats, 20 s = 40 beats
        XCTAssertEqual(model.clips.map(\.startBeats), [0, 20, 60])
        XCTAssertEqual(model.clips.map { $0.sectionStartS ?? -1 },
                       [0, 10, 30])
        XCTAssertEqual(Set(model.clips.map(\.material.id)), ["p1"],
                       "every section is still the same part")
    }

    func testExplodeNeedsAtLeastTwoSections() {
        let model = WorkbenchModel()
        let clip = model.add(material: material("p1"), parts: nil)
        XCTAssertTrue(model.explodeIntoSections(clip.id).isEmpty)
        XCTAssertEqual(model.clips.count, 1)
    }

    // MARK: crossfade

    func testCrossfadeFadesExactlyTheOverlap() {
        let (model, id) = modelWithSections()
        let made = model.explodeIntoSections(id)
        // pull the second clip back so it overlaps the first by 4 beats
        guard let second = model.clips.firstIndex(where: {
            $0.id == made[1].id
        }) else { return XCTFail("missing clip") }
        model.clips[second].startBeats = 16
        model.crossfade(made[0].id, with: made[1].id)
        let a = model.clips.first { $0.id == made[0].id }
        let b = model.clips.first { $0.id == made[1].id }
        // 4 beats at 120 BPM = 2 s
        XCTAssertEqual(try XCTUnwrap(a?.fadeOutS), 2, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(b?.fadeInS), 2, accuracy: 1e-9)
    }

    func testCrossfadeDoesNothingWithoutAnOverlap() {
        let (model, id) = modelWithSections()
        let made = model.explodeIntoSections(id)
        model.crossfade(made[0].id, with: made[1].id)
        XCTAssertEqual(model.clips.first { $0.id == made[0].id }?.fadeOutS, 0)
    }

    // MARK: undo snapshots

    func testSnapshotRestoresLanesAndClips() {
        let model = WorkbenchModel()
        model.add(material: material("a"), parts: nil)
        let before = model.snapshot()
        model.add(material: material("b"), parts: nil)
        model.clips[0].startBeats = 32
        model.apply(before)
        XCTAssertEqual(model.clips.count, 1)
        XCTAssertEqual(model.lanes.count, 1)
        XCTAssertEqual(model.clips[0].startBeats, 0)
    }
}

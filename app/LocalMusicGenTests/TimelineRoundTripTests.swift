// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import LocalMusicGen

/// Reopening a finished mix: model → ingredients → planMix → provenance →
/// model. The placement a mix was rendered with has always been recorded; this
/// is what proves it is enough to get the arrangement back.
@MainActor
final class TimelineRoundTripTests: XCTestCase {

    private func material(_ id: String, kind: String = "stem.vocals",
                          duration: Double = 60) -> PickedMaterial {
        var m = PickedMaterial(
            song: SongRecord(
                id: id, title: "Song \(id)", prompt: "", lyrics: nil,
                modelId: "m", modelName: "M", groupId: nil, paramsJSON: "{}",
                durationS: duration, sampleRate: 44100, fileName: "\(id).wav",
                seedUsed: nil, createdAt: Date(), rating: 0, notes: "",
                favorite: false, origin: "generated"))
        m.kind = kind
        return m
    }

    private func resolved(_ sub: IngredientSubmission, kind: String,
                          role: String, bpm: Double?)
        -> JobsStore.ResolvedIngredient {
        JobsStore.ResolvedIngredient(
            submission: sub, kind: kind, role: role,
            fileURL: URL(fileURLWithPath: "/tmp/\(sub.partId).wav"),
            sampleRate: 44100, sourceSongTitle: "Song \(sub.partId)",
            summary: AnalysisSummary(bpm: bpm))
    }

    /// The full loop: build a bench, render it (planMix), then restore from
    /// exactly what would have been written to songIngredient.
    func testPlacementSurvivesTheRoundTrip() throws {
        let model = WorkbenchModel()
        model.targetBpm = 120
        let vocals = model.add(material: material("v"), parts: nil)
        let drums = model.add(material: material("d", kind: "stem.drums"),
                              parts: nil)
        model.lanes[0].name = "Vocals"
        model.lanes[1].name = "Drums"
        guard let vi = model.clips.firstIndex(where: { $0.id == vocals.id }),
              let di = model.clips.firstIndex(where: { $0.id == drums.id })
        else { return XCTFail("missing clips") }
        model.clips[vi].startBeats = 16.5
        model.clips[vi].gainDb = -3
        model.clips[vi].sectionStartS = 10
        model.clips[vi].sectionEndS = 30
        model.clips[vi].fadeInS = 0.5
        model.clips[vi].summary = AnalysisSummary(bpm: 120)
        model.clips[di].startBeats = 0
        model.clips[di].muted = true
        model.clips[di].summary = AnalysisSummary(bpm: 120)

        let subs = model.ingredients()
        let plan = JobsStore.planMix(
            resolved: [
                resolved(subs[0], kind: "stem.vocals", role: "vocals", bpm: 120),
                resolved(subs[1], kind: "stem.drums", role: "drums", bpm: 120),
            ],
            options: model.options())

        // provenance goes through JSON exactly as ingestRecombine writes it
        let stored = try plan.applied.map {
            try BackendClient.decoder.decode(
                AppliedIngredient.self,
                from: BackendClient.encoder.encode($0))
        }
        let restored = WorkbenchRestore.restore(
            applied: stored,
            materials: ["v": material("v"),
                        "d": material("d", kind: "stem.drums")],
            summaries: ["v": AnalysisSummary(bpm: 120),
                        "d": AnalysisSummary(bpm: 120)],
            sections: [:], fallbackBpm: nil)

        XCTAssertEqual(restored.lanes.map(\.name), ["Vocals", "Drums"])
        XCTAssertEqual(restored.clips.count, 2)
        let v = try XCTUnwrap(restored.clips.first { $0.material.id == "v" })
        XCTAssertEqual(v.startBeats, 16.5, "fractional placement is lossless")
        XCTAssertEqual(v.gainDb, -3)
        XCTAssertEqual(v.sectionStartS, 10)
        XCTAssertEqual(v.sectionEndS, 30)
        XCTAssertEqual(v.fadeInS, 0.5)
        XCTAssertTrue(try XCTUnwrap(
            restored.clips.first { $0.material.id == "d" }).muted)
        XCTAssertEqual(restored.targetBpm, 120, "recovered from stretchRatio")
    }

    /// A lane holding several clips of one part must come back as one lane,
    /// not N lanes — that is what the readable slotId buys.
    func testRepeatedClipsRestoreOntoOneLane() throws {
        let model = WorkbenchModel()
        model.targetBpm = 120
        let clip = model.add(material: material("v"), parts: nil)
        model.lanes[0].name = "Vocals"
        model.clips[0].summary = AnalysisSummary(bpm: 120)
        model.clips[0].sourceDurationS = 60
        model.duplicate(clip.id, atBeats: 64)
        model.duplicate(clip.id, atBeats: 128)

        let applied = model.ingredients().map {
            AppliedIngredient(submission: $0, sourceSongTitle: "Song v",
                              role: "vocals", stretchRatio: 1, pitchShiftSt: 0)
        }
        let restored = WorkbenchRestore.restore(
            applied: applied, materials: ["v": material("v")],
            summaries: ["v": AnalysisSummary(bpm: 120)], sections: [:],
            fallbackBpm: 120)
        XCTAssertEqual(restored.lanes.count, 1)
        XCTAssertEqual(restored.clips.count, 3)
        XCTAssertEqual(restored.clips.map(\.startBeats).sorted(), [0, 64, 128])
    }

    /// Mixes made before the timeline (and the old structure arranger's
    /// `sec-0-A1` slots) have no lane in their slotId, so they group by role.
    func testLegacySlotIdsGroupByRole() {
        XCTAssertEqual(WorkbenchRestore.laneName(slotId: "vocals-2",
                                                 role: "vocals"), "Vocals")
        XCTAssertEqual(WorkbenchRestore.laneName(slotId: "sec-0-A1",
                                                 role: "mix"), "Mix")
        XCTAssertEqual(
            WorkbenchRestore.laneName(slotId: "3f2a91c8-dead-beef",
                                      role: "drums"), "Drums")
    }

    func testTargetBpmIsRecoveredFromTheStretchRatio() {
        let applied = [
            AppliedIngredient(
                submission: IngredientSubmission(slotId: "v-1", partId: "v"),
                sourceSongTitle: "A", role: "vocals",
                stretchRatio: 1.25, pitchShiftSt: 0),
        ]
        XCTAssertEqual(
            WorkbenchRestore.targetBpm(applied: applied,
                                       sourceBpm: ["v": 96]) ?? 0,
            120, accuracy: 1e-9)
        XCTAssertNil(WorkbenchRestore.targetBpm(applied: applied,
                                                sourceBpm: [:]))
    }

    /// A deleted part becomes a tombstone that still shows where it sat — and
    /// blocks rendering, because quietly dropping a track would be worse.
    func testDeletedPartBecomesATombstoneAndBlocksTheRender() throws {
        let applied = [
            AppliedIngredient(
                submission: IngredientSubmission(slotId: "vocals-1",
                                                 partId: "gone",
                                                 offsetBeats: 32),
                sourceSongTitle: "Old Song", role: "vocals",
                stretchRatio: nil, pitchShiftSt: 0),
            AppliedIngredient(
                submission: IngredientSubmission(slotId: "drums-1",
                                                 partId: "d"),
                sourceSongTitle: "Song d", role: "drums",
                stretchRatio: nil, pitchShiftSt: 0),
        ]
        let restored = WorkbenchRestore.restore(
            applied: applied,
            materials: ["d": material("d", kind: "stem.drums")],
            summaries: [:], sections: [:], fallbackBpm: 120)

        let model = WorkbenchModel()
        model.lanes = restored.lanes
        model.clips = restored.clips
        let ghost = try XCTUnwrap(restored.clips.first { $0.isMissing })
        XCTAssertEqual(ghost.startBeats, 32, "it still shows where it sat")
        XCTAssertEqual(ghost.material.sourceTitle, "Old Song")
        XCTAssertTrue(model.hasMissingClips)
        XCTAssertEqual(model.ingredients().count, 1,
                       "missing clips never reach the render")
        XCTAssertTrue(restored.warnings.contains { $0.contains("missing") })
    }

    func testAutoMatchFlagsComeBackFromWhatWasApplied() {
        let plain = [
            AppliedIngredient(
                submission: IngredientSubmission(slotId: "a-1", partId: "a"),
                sourceSongTitle: "A", role: "a", stretchRatio: nil,
                pitchShiftSt: 0),
        ]
        let restored = WorkbenchRestore.restore(
            applied: plain, materials: ["a": material("a")], summaries: [:],
            sections: [:], fallbackBpm: 120)
        XCTAssertFalse(restored.autoMatchTempo)
        XCTAssertFalse(restored.autoMatchKey)
        XCTAssertTrue(restored.warnings.contains { $0.contains("Loudness") })
    }
}

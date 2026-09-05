import XCTest
@testable import LocalMusicGen

/// The pure planning half of submitRecombine: resolved ingredients + stored
/// analysis → mix_spec tracks and provenance transforms.
final class MixSpecTests: XCTestCase {

    private func resolved(_ slot: String, partId: String, kind: String,
                          role: String, bpm: Double? = nil,
                          camelot: String? = nil,
                          downbeats: [Double]? = nil,
                          offsetBeats: Double = 0,
                          section: (Double, Double)? = nil,
                          sampleRate: Int? = 44100)
        -> JobsStore.ResolvedIngredient {
        JobsStore.ResolvedIngredient(
            submission: IngredientSubmission(
                slotId: slot, partId: partId, gainDb: -3, muted: false,
                offsetBeats: offsetBeats,
                sectionStartS: section?.0, sectionEndS: section?.1),
            kind: kind, role: role,
            fileURL: URL(fileURLWithPath: "/tmp/\(partId).wav"),
            sampleRate: sampleRate, sourceSongTitle: "Song \(partId)",
            summary: AnalysisSummary(bpm: bpm, camelot: camelot,
                                     downbeats: downbeats))
    }

    func testMixSpecEncodesSnakeCaseContractShape() throws {
        let items = [
            resolved("vocals", partId: "p1", kind: "stem.vocals",
                     role: "vocals", bpm: 98, camelot: "8A",
                     downbeats: [0.5, 2.9], section: (10.0, 40.0)),
            resolved("drums", partId: "p2", kind: "stem.drums", role: "drums",
                     bpm: 124, camelot: "8A", offsetBeats: 4,
                     sampleRate: 48000),
        ]
        let plan = JobsStore.planMix(
            resolved: items,
            options: RecombineOptions(targetBpm: 124, targetCamelot: "8A"))
        let data = try BackendClient.encoder.encode(plan.spec)
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])

        let target = try XCTUnwrap(json["target"] as? [String: Any])
        XCTAssertEqual(target["bpm"] as? Double, 124)
        XCTAssertEqual(target["sample_rate"] as? Int, 48000)  // max of sources

        let tracks = try XCTUnwrap(json["tracks"] as? [[String: Any]])
        XCTAssertEqual(tracks.count, 2)

        let vocals = tracks[0]
        XCTAssertEqual(vocals["role"] as? String, "vocals")
        XCTAssertEqual(vocals["gain_db"] as? Double, -3)
        XCTAssertEqual(vocals["source_bpm"] as? Double, 98)
        let section = try XCTUnwrap(vocals["section"] as? [String: Any])
        XCTAssertEqual(section["start_s"] as? Double, 10.0)
        let stretch = try XCTUnwrap(vocals["stretch"] as? [String: Any])
        XCTAssertEqual(stretch["mode"] as? String, "beat")   // has downbeats
        XCTAssertEqual(stretch["transient_mode"] as? String, "smooth")
        XCTAssertEqual(stretch["preserve_formants"] as? Bool, true)

        let drums = tracks[1]
        let drumStretch = try XCTUnwrap(drums["stretch"] as? [String: Any])
        XCTAssertEqual(drumStretch["mode"] as? String, "uniform")  // no downbeats
        XCTAssertEqual(drumStretch["transient_mode"] as? String, "crisp")
        XCTAssertEqual(drumStretch["preserve_formants"] as? Bool, false)
        // offset_beats → seconds on the target grid: 4 × 60/124
        XCTAssertEqual(try XCTUnwrap(drums["offset_s"] as? Double),
                       4 * 60.0 / 124.0, accuracy: 1e-9)
    }

    func testAutoMatchOffAndUnknownAnalysis() throws {
        let items = [
            resolved("a", partId: "s1", kind: "song.mix", role: "mix"),
            resolved("b", partId: "s2", kind: "song.mix", role: "mix",
                     bpm: 100, offsetBeats: 8),
        ]
        let plan = JobsStore.planMix(
            resolved: items,
            options: RecombineOptions(autoMatchTempo: false,
                                      autoMatchKey: false))
        // target bpm inferred from the first analyzed ingredient
        XCTAssertEqual(plan.spec.target.bpm, 100)
        // auto-match off → no stretching, no shifting, but placement stands
        XCTAssertEqual(plan.spec.tracks[0].stretch.mode, "none")
        XCTAssertEqual(plan.spec.tracks[1].stretch.mode, "none")
        XCTAssertEqual(plan.spec.tracks[1].pitchShiftSt, 0)
        XCTAssertEqual(plan.spec.tracks[1].offsetS, 8 * 60.0 / 100.0,
                       accuracy: 1e-9)
        XCTAssertNil(plan.applied[1].stretchRatio)
    }

    func testAppliedTransformCarriesPlan() throws {
        // source 98 → target 124 grid is red (26%): plan drops the ratio but
        // key shift (+1 st: 8A → 3A) still applies
        let items = [
            resolved("v", partId: "p1", kind: "stem.vocals", role: "vocals",
                     bpm: 120, camelot: "8A", downbeats: [0, 2]),
        ]
        let plan = JobsStore.planMix(
            resolved: items,
            options: RecombineOptions(targetBpm: 124, targetCamelot: "3A"))
        XCTAssertEqual(plan.applied[0].pitchShiftSt, 1)
        XCTAssertEqual(plan.spec.tracks[0].pitchShiftSt, 1)
        XCTAssertEqual(try XCTUnwrap(plan.applied[0].stretchRatio),
                       124.0 / 120.0, accuracy: 1e-9)
        // transform round-trips through the provenance encoding
        let data = try BackendClient.encoder.encode(plan.applied[0])
        let back = try BackendClient.decoder.decode(AppliedIngredient.self,
                                                    from: data)
        XCTAssertEqual(back, plan.applied[0])
    }

    /// The engine recomputes target/source itself, so a half-time match has to
    /// ride the wire folded. Sending the raw 70 would render at double speed
    /// while every badge in the UI claims no stretch at all.
    func testHalfTimeMatchShipsTheFoldedTempo() throws {
        let items = [
            resolved("v", partId: "p1", kind: "stem.vocals", role: "vocals",
                     bpm: 70, camelot: "8A"),
        ]
        let plan = JobsStore.planMix(
            resolved: items,
            options: RecombineOptions(targetBpm: 140, targetCamelot: "8A"))
        XCTAssertEqual(plan.spec.tracks[0].sourceBpm, 140)
        XCTAssertEqual(try XCTUnwrap(plan.applied[0].stretchRatio), 1,
                       accuracy: 1e-9)
    }

    /// Auto-match on means aligned, even when the stretch is bigger than
    /// Mashability would recommend (it nils out red-quality ratios for its
    /// badges). Provenance must record what the engine actually applied, not
    /// the recommendation — it used to claim "no stretch" for a 26% stretch.
    func testRedQualityStretchIsStillRecordedAsApplied() throws {
        let items = [
            resolved("v", partId: "p1", kind: "stem.vocals", role: "vocals",
                     bpm: 98, downbeats: [0, 2]),
        ]
        let plan = JobsStore.planMix(
            resolved: items, options: RecombineOptions(targetBpm: 124))
        XCTAssertEqual(plan.spec.tracks[0].stretch.mode, "beat")
        XCTAssertEqual(plan.spec.tracks[0].sourceBpm, 98)
        XCTAssertEqual(try XCTUnwrap(plan.applied[0].stretchRatio),
                       124.0 / 98.0, accuracy: 1e-9)
    }

    func testFadesAndTargetDurationRideTheWire() throws {
        var item = resolved("v", partId: "p1", kind: "stem.vocals",
                            role: "vocals", bpm: 120)
        item.submission.fadeInS = 0.25
        item.submission.fadeOutS = 2.0
        let plan = JobsStore.planMix(
            resolved: [item],
            options: RecombineOptions(targetBpm: 120, targetDurationS: 96))
        let data = try BackendClient.encoder.encode(plan.spec)
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let track = try XCTUnwrap(
            (json["tracks"] as? [[String: Any]])?.first)
        XCTAssertEqual(track["fade_in_s"] as? Double, 0.25)
        XCTAssertEqual(track["fade_out_s"] as? Double, 2.0)
        XCTAssertEqual((json["target"] as? [String: Any])?["duration_s"]
                       as? Double, 96)
    }

    /// Absent rather than zero when unused, so a spec without fades is exactly
    /// the spec the determinism check has always rendered.
    func testNoFadeKeysWhenThereAreNoFades() throws {
        let plan = JobsStore.planMix(
            resolved: [resolved("v", partId: "p1", kind: "stem.vocals",
                                role: "vocals", bpm: 120)],
            options: RecombineOptions(targetBpm: 120))
        let data = try BackendClient.encoder.encode(plan.spec)
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let track = try XCTUnwrap((json["tracks"] as? [[String: Any]])?.first)
        XCTAssertNil(track["fade_in_s"])
        XCTAssertNil(track["fade_out_s"])
        XCTAssertNil((json["target"] as? [String: Any])?["duration_s"])
    }

    /// IngredientSubmission is nested in every stored AppliedIngredient, and
    /// Swift's synthesized decoder does not fall back to property defaults —
    /// so provenance written before fades existed must still decode.
    func testProvenanceWrittenBeforeFadesStillDecodes() throws {
        let legacy = """
        {"submission": {"slotId": "vocals-1", "partId": "p1", "gainDb": -3,
                        "muted": false, "offsetBeats": 16},
         "sourceSongTitle": "Song A", "role": "vocals", "pitchShiftSt": 0}
        """
        let back = try BackendClient.decoder.decode(
            AppliedIngredient.self, from: Data(legacy.utf8))
        XCTAssertEqual(back.submission.offsetBeats, 16)
        XCTAssertNil(back.submission.fadeInS)
    }

    /// keep_tracks writes one file per role, so repeated roles would overwrite
    /// each other's stems — routine once a lane can hold several clips.
    func testRepeatedRolesGetUniqueNames() throws {
        let items = (0..<3).map {
            resolved("v\($0)", partId: "p1", kind: "stem.vocals",
                     role: "vocals", offsetBeats: Double($0) * 4)
        }
        let plan = JobsStore.planMix(
            resolved: items, options: RecombineOptions(targetBpm: 120))
        XCTAssertEqual(plan.spec.tracks.map(\.role),
                       ["vocals", "vocals-2", "vocals-3"])
        XCTAssertEqual(plan.applied.map(\.role),
                       ["vocals", "vocals-2", "vocals-3"])
    }
}

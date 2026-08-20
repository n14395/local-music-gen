import XCTest
@testable import LocalMusic

/// SR5: structure arrangement, match ranking, and the CLAP timbre term.
///
/// The arrangement cases used to drive a standalone StructureArrangerView;
/// that screen is now "Split into sections" on the timeline, so they follow the
/// same behaviour through the workbench model.
@MainActor
final class SR5Tests: XCTestCase {

    // MARK: structure arrangement

    private func sections() -> [AnalysisPayload.Section] {
        [.init(startS: 0, endS: 10, group: "A", label: nil),
         .init(startS: 10, endS: 30, group: "B", label: nil),
         .init(startS: 30, endS: 40, group: "A", label: nil)]
    }

    private func exploded() -> (WorkbenchModel, [WorkbenchModel.Clip]) {
        let model = WorkbenchModel()
        model.targetBpm = 120
        var material = PickedMaterial(
            song: SongRecord(
                id: "src", title: "src", prompt: "", lyrics: nil, modelId: "m",
                modelName: "M", groupId: nil, paramsJSON: "{}", durationS: 40,
                sampleRate: 44100, fileName: "src.wav", seedUsed: nil,
                createdAt: Date(), rating: 0, notes: "", favorite: false,
                origin: "generated"))
        material.kind = "song.mix"
        let clip = model.add(material: material, parts: nil)
        guard let i = model.clips.firstIndex(where: { $0.id == clip.id })
        else { return (model, []) }
        model.clips[i].sections = sections()
        model.clips[i].sourceDurationS = 40
        model.clips[i].summary = AnalysisSummary(bpm: 120)
        return (model, model.explodeIntoSections(clip.id))
    }

    func testSectionClipsAreNamedByGroup() {
        let (model, made) = exploded()
        XCTAssertEqual(made.compactMap(\.sectionLabel), ["A1", "B1", "A2"])
        XCTAssertEqual(model.arrangementDurationS ?? 0, 40, accuracy: 1e-9)
    }

    func testDuplicatingAndRemovingSectionClips() throws {
        let (model, made) = exploded()
        let b1 = try XCTUnwrap(made.first { $0.sectionLabel == "B1" })
        model.duplicate(b1.id)
        XCTAssertEqual(model.clips.count, 4)
        XCTAssertEqual(model.clips.filter { $0.sectionLabel == "B1" }.count, 2)
        model.removeClip(made[0].id)
        XCTAssertEqual(model.clips.compactMap(\.sectionLabel).sorted(),
                       ["A2", "B1", "B1"])
    }

    func testSectionsAreLaidBackToBackAndSurviveReordering() throws {
        let (model, made) = exploded()
        // offsets in beats at 120 BPM (2 beats per second): 10 s = 20 beats
        XCTAssertEqual(made.map(\.startBeats), [0, 20, 60])
        // put A2 first, the arranger's signature move
        for (index, clip) in made.enumerated() {
            guard let i = model.clips.firstIndex(where: { $0.id == clip.id })
            else { continue }
            model.clips[i].startBeats = [20, 40, 0][index]
        }
        let subs = model.ingredients()
        XCTAssertEqual(subs.count, 3)
        XCTAssertTrue(subs.allSatisfy { $0.partId == "src" })
        XCTAssertEqual(subs.map(\.offsetBeats), [0, 20, 40])
        XCTAssertEqual(subs[0].sectionStartS, 30)
        XCTAssertEqual(subs[0].sectionEndS, 40)
        // beats → seconds against the target grid must round-trip exactly
        XCTAssertEqual(subs[1].offsetBeats * 60.0 / 120.0, 10, accuracy: 1e-9)
    }

    // MARK: timbre term

    private func summary(clap: [Double]? = nil) -> AnalysisSummary {
        AnalysisSummary(bpm: 120, camelot: "8A", clap: clap)
    }

    func testTimbreCosineOfIdenticalVectorsIsOne() {
        var unit = [Double](repeating: 0, count: 512)
        unit[0] = 1
        XCTAssertEqual(Mashability.timbre(source: unit, target: unit), 1.0)
    }

    func testTimbreOrthogonalVectorsScoreZero() {
        var a = [Double](repeating: 0, count: 512)
        var b = a
        a[0] = 1
        b[1] = 1
        XCTAssertEqual(Mashability.timbre(source: a, target: b), 0.0)
    }

    func testTimbreRejectsWrongDimensions() {
        XCTAssertNil(Mashability.timbre(source: [1, 0], target: [0, 1]))
    }

    func testPlanUnchangedWithoutClap() {
        // The CLAP term must be a pure refinement: absent embeddings leave
        // SR2-era scores bit-identical.
        let before = Mashability.plan(source: summary(), target: summary())
        XCTAssertNil(before.badges.timbre)
        var unit = [Double](repeating: 0, count: 512)
        unit[0] = 1
        let with = Mashability.plan(source: summary(clap: unit),
                                    target: summary(clap: unit))
        XCTAssertEqual(with.badges.timbre, 1.0)
        XCTAssertGreaterThanOrEqual(with.badges.stars, before.badges.stars)
    }

    func testSimilarTimbreOutranksDissimilar() {
        var base = [Double](repeating: 0, count: 512)
        base[0] = 1
        var far = [Double](repeating: 0, count: 512)
        far[1] = 1
        let close = Mashability.plan(source: summary(clap: base),
                                     target: summary(clap: base))
        let distant = Mashability.plan(source: summary(clap: far),
                                       target: summary(clap: base))
        XCTAssertGreaterThan(close.badges.stars, distant.badges.stars)
    }

    // MARK: match narration

    func testWhyLineMentionsAvailableSignals() {
        var unit = [Double](repeating: 0, count: 512)
        unit[0] = 1
        let plan = Mashability.plan(source: summary(clap: unit),
                                    target: summary(clap: unit))
        let why = MatchRanking.why(plan)
        XCTAssertTrue(why.contains("key ✓"))
        XCTAssertTrue(why.contains("timbre 100%"))
    }

    func testStarsText() {
        XCTAssertEqual(MatchRanking.starsText(3.5), "★★★½☆")
        XCTAssertEqual(MatchRanking.starsText(5), "★★★★★")
        XCTAssertEqual(MatchRanking.starsText(0), "☆☆☆☆☆")
    }

    // MARK: JSONValue containers (nested task-result meta)

    func testJobResultWithNestedMetaDecodes() throws {
        // Transcription jobs report per-track counts as a nested object —
        // this exact shape used to fail the whole JobInfo decode.
        let json = """
        {"artifacts": [{"kind": "midi", "label": "melody",
                        "path": "/x/melody.mid", "format": "mid",
                        "sample_rate": null, "duration_s": null}],
         "meta": {"tracks": {"melody": 4, "drums": 4}, "tempo_bpm": 120.5},
         "timings": {"total_s": 1.0}}
        """
        let result = try BackendClient.decoder.decode(
            JobResult.self, from: Data(json.utf8))
        XCTAssertEqual(result.artifacts?.count, 1)
        XCTAssertEqual(result.meta?["tempo_bpm"]?.doubleValue, 120.5)
        guard case .object(let tracks)? = result.meta?["tracks"] else {
            return XCTFail("nested meta object should decode as .object")
        }
        XCTAssertEqual(tracks["melody"], .int(4))
    }

    func testJSONValueContainerRoundTrip() throws {
        let value = JSONValue.object(
            ["list": .array([.int(1), .string("x"), .null]),
             "flag": .bool(true)])
        let data = try BackendClient.encoder.encode(value)
        let back = try BackendClient.decoder.decode(JSONValue.self, from: data)
        XCTAssertEqual(back, value)
    }
}

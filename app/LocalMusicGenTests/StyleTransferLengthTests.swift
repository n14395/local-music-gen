import XCTest
@testable import LocalMusicGen

/// How long a Style Transfer run comes out, which the workspace used not to ask
/// about at all.
///
/// `duration_s` is a top-level field of the submission rather than a model
/// param, so nothing in `capabilities` bounds it, the generic knob form cannot
/// show it, and no job ever fails for getting it wrong — the render simply
/// comes back the wrong length. That makes every rule here silent in the
/// running app, and silent in the most expensive way: two minutes of local GPU
/// for audio that stops early.
///
/// The three policies are read out of the adapters, not assumed, and each is
/// pinned here against a family that really behaves that way.
@MainActor
final class StyleTransferLengthTests: XCTestCase {

    // MARK: - Fixtures

    /// Built from contract JSON rather than the Swift initialisers, for the
    /// same reason `StyleTransferModeTests` does it: the fixtures then travel
    /// the decoding path the engine actually feeds.
    private func model(_ id: String, family: String, params: String,
                       minS: Double = 1, maxS: Double = 300,
                       defaultS: Double = 30) -> ModelInfo {
        let json = """
        {
          "id": "\(id)", "family": "\(family)",
          "display_name": "\(id)", "description": "", "hf_repos": [],
          "size_bytes": 1000000000, "install_state": "installed",
          "installed_bytes": 0,
          "capabilities": {
            "supports_lyrics": false, "instrumental_only": true,
            "duration": {"min_s": \(minS), "max_s": \(maxS),
                          "default_s": \(defaultS)},
            "sample_rate": 44100, "outputs_per_job_max": 1,
            "est_seconds_per_audio_second": 1, "tasks": null,
            "params": \(params)
          },
          "requirements": {"min_ram_bytes": 8589934592,
                            "disk_bytes": 1000000000,
                            "speed_tier": "fast"},
          "license": {"name": "MIT", "commercial_use": true,
                       "requires_hf_token": false, "url": null},
          "notes": null
        }
        """
        // swiftlint:disable:next force_try — fixture is a compile-time constant
        return try! BackendClient.decoder.decode(ModelInfo.self,
                                                 from: Data(json.utf8))
    }

    private func audioParam(_ key: String) -> String {
        """
        {"key": "\(key)", "type": "audio", "label": "\(key)",
         "default": null, "nullable": true}
        """
    }

    private func taskTypeParam(_ choices: [String]) -> String {
        let list = choices
            .map { #"{"value": "\#($0)", "label": "\#($0)"}"# }
            .joined(separator: ",")
        return """
        {"key": "task_type", "type": "enum", "label": "Task",
         "default": "text2music", "nullable": false, "choices": [\(list)]}
        """
    }

    /// An ACE-Step-shaped model: `src_audio` on a family whose adapter resolves
    /// the length from the source.
    private func ace(_ family: String = "acestep") -> ModelInfo {
        model("ace", family: family, params: """
        [\(taskTypeParam(["text2music", "cover", "repaint"])),
         \(audioParam("src_audio"))]
        """, minS: 10, maxS: 600, defaultS: 60)
    }

    /// Stable Audio 3: `init_audio` for a restyle, `extend_audio` for a
    /// continuation that keeps the source inside the output.
    private func stableAudio3() -> ModelInfo {
        model("sa3", family: "stableaudio3", params: """
        [\(audioParam("init_audio")), \(audioParam("extend_audio"))]
        """, minS: 1, maxS: 120, defaultS: 30)
    }

    /// InspireMusic: the same `extend_audio` key, and the source is *not* in
    /// the result — it conditions a ~5 s tail clip and nothing more.
    private func inspireMusic() -> ModelInfo {
        model("im", family: "inspiremusic",
              params: "[\(audioParam("extend_audio"))]",
              minS: 10, maxS: 180, defaultS: 30)
    }

    private func musicgenMelody() -> ModelInfo {
        model("mg", family: "musicgen",
              params: "[\(audioParam("melody_audio"))]",
              minS: 1, maxS: 30, defaultS: 10)
    }

    /// A style-reference model with nowhere to put a source track — the shape
    /// `reference` takes on MusicGen-Style, YuE, SongBloom and the rest.
    private func styleOnly() -> ModelInfo {
        model("style", family: "yue",
              params: "[\(audioParam("style_audio"))]",
              minS: 10, maxS: 180, defaultS: 60)
    }

    /// `durationS` is set after construction as well as through it: the record
    /// insists on a length, and "a source whose length is not known yet" — a
    /// just-imported file — is one of the cases the policy has to survive.
    private func source(_ seconds: Double?) -> PickedMaterial {
        var material = PickedMaterial(
            song: SongRecord(
                id: "s1", title: "Source", prompt: "", lyrics: nil,
                modelId: "m", modelName: "M", groupId: nil, paramsJSON: "{}",
                durationS: seconds ?? 0, sampleRate: 44100,
                fileName: "s1.wav", seedUsed: nil, createdAt: Date(),
                rating: 0, notes: "", favorite: false, origin: "generated"))
        material.durationS = seconds
        return material
    }

    private func configured(mode: StyleTransferMode,
                            sourceS: Double? = 180) -> StyleTransferModel {
        let workspace = StyleTransferModel()
        workspace.mode = mode
        if sourceS != nil { workspace.source = source(sourceS) }
        return workspace
    }

    // MARK: - Which policy applies

    /// The eight src-audio modes on the three ACE families: the adapter takes
    /// the length off the source and never reads `duration_s`.
    func testSrcAudioOnAceFamiliesIsPinnedToTheSource() {
        for family in ["acestep", "acestepcpp", "diffsynthace"] {
            XCTAssertEqual(
                StyleTransferMode.cover.lengthPolicy(for: ace(family),
                                                     hasSource: true),
                .pinnedToSource, "\(family) should pin")
        }
    }

    /// A `src_audio` family nobody has classified gets a live control rather
    /// than a pinned one. Documented, and guarded in `verify_engine` — the
    /// catalog growing such a family is what that check is for.
    func testUnknownSrcAudioFamilyFallsBackToALiveLength() {
        XCTAssertEqual(
            StyleTransferMode.cover.lengthPolicy(for: ace("somethingnew"),
                                                 hasSource: true),
            .total)
    }

    /// Conditioning is not content: a melody clip and an init clip steer the
    /// render without bounding it.
    func testConditioningKeysLeaveTheLengthFree() {
        XCTAssertEqual(
            StyleTransferMode.melody.lengthPolicy(for: musicgenMelody(),
                                                  hasSource: true),
            .total)
        XCTAssertEqual(
            StyleTransferMode.shape.lengthPolicy(for: stableAudio3(),
                                                 hasSource: true),
            .total)
    }

    /// The same wire key, two meanings. Stable Audio 3 inpaints past the
    /// source's end, so the source is in the output and the number is the
    /// total; InspireMusic returns the continuation alone.
    func testExtendAudioMeansDifferentThingsPerFamily() {
        XCTAssertEqual(
            StyleTransferMode.continueTrack.lengthPolicy(for: stableAudio3(),
                                                         hasSource: true),
            .extendsSource)
        XCTAssertEqual(
            StyleTransferMode.continueTrack.lengthPolicy(for: inspireMusic(),
                                                         hasSource: true),
            .total)
    }

    /// A source the model has nowhere to put is not sent at all — `wireParams`
    /// filters it and the screen says so — which makes the length the plain
    /// length of the output.
    func testASourceThatNeverReachesTheModelLeavesTheLengthFree() {
        XCTAssertEqual(
            StyleTransferMode.reference.lengthPolicy(for: styleOnly(),
                                                     hasSource: true),
            .total)
    }

    func testNoSourceMeansTheLengthIsJustTheLength() {
        XCTAssertEqual(
            StyleTransferMode.reference.lengthPolicy(for: ace(),
                                                     hasSource: false),
            .total)
    }

    // MARK: - What goes on the wire

    /// The bug this control exists to fix: a restyle used to ask for the
    /// model's nominal default, which on a pinned family made the *estimate*
    /// wrong and on a free one truncated the audio.
    func testAPinnedRunAsksForTheSourcesOwnLength() {
        let workspace = configured(mode: .cover, sourceS: 222)
        XCTAssertEqual(workspace.requestedDurationS(model: ace()), 222)
    }

    /// A source longer than the model's window still cannot ask past it.
    func testAPinnedRunStaysInsideTheModelsWindow() {
        let workspace = configured(mode: .cover, sourceS: 900)
        XCTAssertEqual(workspace.requestedDurationS(model: ace()), 600)
    }

    /// With no source to read, a pinned mode falls back to where it always
    /// was — the model's own default.
    func testAPinnedRunWithNoSourceFallsBackToTheModelDefault() {
        let workspace = configured(mode: .cover, sourceS: nil)
        XCTAssertEqual(workspace.requestedDurationS(model: ace()), 60)
    }

    /// The silent truncation, now visible and settable: ten seconds was the
    /// whole of what a three-minute track used to come back as.
    func testAFreeLengthDefaultsToTheModelsOwnAndThenObeysTheUser() {
        let workspace = configured(mode: .melody, sourceS: 180)
        let melody = musicgenMelody()
        XCTAssertEqual(workspace.requestedDurationS(model: melody), 10)
        workspace.lengthS = 25
        XCTAssertEqual(workspace.requestedDurationS(model: melody), 25)
    }

    func testAFreeLengthIsHeldInsideTheModelsRange() {
        let workspace = configured(mode: .melody, sourceS: 180)
        workspace.lengthS = 500
        XCTAssertEqual(workspace.requestedDurationS(model: musicgenMelody()), 30)
        workspace.lengthS = 0
        XCTAssertEqual(workspace.requestedDurationS(model: musicgenMelody()), 1)
    }

    /// The old hardcoded `+ 30` tail, preserved as the default so an untouched
    /// continuation runs exactly as it did before the control existed.
    func testAContinuationStillDefaultsToThirtySecondsOfTail() {
        let workspace = configured(mode: .continueTrack, sourceS: 60)
        XCTAssertEqual(workspace.requestedDurationS(model: stableAudio3()), 90)
    }

    /// What could not be asked for before: any tail but thirty seconds.
    func testAContinuationSendsSourcePlusTheChosenTail() {
        let workspace = configured(mode: .continueTrack, sourceS: 60)
        workspace.lengthS = 8
        XCTAssertEqual(workspace.requestedDurationS(model: stableAudio3()), 68)
        workspace.lengthS = 55
        XCTAssertEqual(workspace.requestedDurationS(model: stableAudio3()), 115)
    }

    /// On InspireMusic the same control is a total, because the source is not
    /// in the result.
    func testAnInspireMusicContinuationSendsTheTailAloneAsTheTotal() {
        let workspace = configured(mode: .continueTrack, sourceS: 60)
        workspace.lengthS = 45
        XCTAssertEqual(workspace.requestedDurationS(model: inspireMusic()), 45)
    }

    // MARK: - Bounds

    func testATailIsBoundedByWhatTheSourceLeavesOfTheWindow() {
        let workspace = configured(mode: .continueTrack, sourceS: 100)
        let bounds = workspace.lengthBounds(for: stableAudio3(),
                                            policy: .extendsSource)
        XCTAssertEqual(bounds?.lowerBound, StyleTransferModel.minTailS)
        XCTAssertEqual(bounds?.upperBound, 20)   // 120 s window − 100 s source
    }

    /// Upstream refuses this outright, minutes in. The workspace refuses it
    /// before the upload.
    func testASourceThatFillsTheWindowHasNoTailAndSaysSo() {
        let workspace = configured(mode: .continueTrack, sourceS: 118)
        let sa3 = stableAudio3()
        XCTAssertNil(workspace.lengthBounds(for: sa3, policy: .extendsSource))
        workspace.prompt = "keep going"
        let reason = workspace.blockedReason(in: [sa3])
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason?.contains("120") ?? false,
                      "the reason should name the window: \(reason ?? "nil")")
    }

    /// A pinned length has no control, which is the whole point: the slider
    /// would write a number the adapter throws away.
    func testAPinnedLengthOffersNoControl() {
        let workspace = configured(mode: .cover, sourceS: 180)
        XCTAssertNil(workspace.lengthBounds(for: ace(),
                                            policy: .pinnedToSource))
    }

    // MARK: - Document behaviour

    /// 30 s of tail and 30 s of total are not the same run, so the number
    /// cannot survive the mode that gave it its unit.
    func testChangingModeForgetsTheLength() {
        let workspace = configured(mode: .continueTrack, sourceS: 60)
        workspace.lengthS = 45
        workspace.mode = .melody
        XCTAssertNil(workspace.lengthS)
    }

    /// A model change keeps it — comparing two models at one length is the
    /// workspace's whole reason for existing — and the clamp does the rest.
    func testChangingModelKeepsTheLengthAndClampsIt() {
        let workspace = configured(mode: .melody, sourceS: 180)
        workspace.lengthS = 28
        XCTAssertEqual(workspace.requestedDurationS(model: musicgenMelody()), 28)
        XCTAssertEqual(workspace.lengthS, 28)
    }

    func testALengthCountsAsWorkAPresetWouldDestroy() {
        let workspace = configured(mode: .melody, sourceS: 180)
        XCTAssertFalse(workspace.hasUnsavedWork)
        workspace.lengthS = 20
        XCTAssertTrue(workspace.hasUnsavedWork)
        workspace.clearConfiguration()
        XCTAssertNil(workspace.lengthS)
    }
}

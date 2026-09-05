import XCTest
@testable import LocalMusicGen

/// The semantic layer of Style Transfer: intent in, engine params out.
///
/// Every one of these rules is invisible in the running app until it is wrong,
/// and then it is wrong in the most expensive way available — a job that runs
/// for two minutes on a local model and returns audio that is not what was
/// asked for. The wire mapping and the strength inversion in particular have no
/// other guard: the engine drops params it does not recognise without failing
/// the job, so a mistake here is silent by construction.
final class StyleTransferModeTests: XCTestCase {

    // MARK: - Fixtures

    /// A model built from raw contract JSON rather than from the Swift
    /// initialisers, so the fixtures exercise the same decoding path the engine
    /// feeds and cannot drift away from the wire format.
    private func model(_ id: String, params: String = "[]",
                       installState: String = "installed",
                       tasks: String = "null",
                       sizeBytes: Int64 = 1_000_000_000) -> ModelInfo {
        let json = """
        {
          "id": "\(id)", "family": "test",
          "display_name": "\(id)", "description": "", "hf_repos": [],
          "size_bytes": \(sizeBytes), "install_state": "\(installState)",
          "installed_bytes": 0,
          "capabilities": {
            "supports_lyrics": false, "instrumental_only": true,
            "duration": {"min_s": 1, "max_s": 300, "default_s": 30},
            "sample_rate": 44100, "outputs_per_job_max": 1,
            "est_seconds_per_audio_second": 1, "tasks": \(tasks),
            "params": \(params)
          },
          "requirements": {"min_ram_bytes": 8589934592,
                            "disk_bytes": \(sizeBytes),
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

    private func taskTypeParam(_ choices: [String]) -> String {
        let list = choices
            .map { #"{"value": "\#($0)", "label": "\#($0)"}"# }
            .joined(separator: ",")
        return """
        {"key": "task_type", "type": "enum", "label": "Task",
         "default": "text2music", "nullable": false, "choices": [\(list)]}
        """
    }

    private func audioParam(_ key: String) -> String {
        """
        {"key": "\(key)", "type": "audio", "label": "\(key)",
         "default": null, "nullable": true}
        """
    }

    private let coverStrengthParam = """
    {"key": "audio_cover_strength", "type": "float", "label": "Cover strength",
     "default": 0.7, "nullable": false, "min": 0.0, "max": 1.0, "step": 0.05}
    """

    private let noiseParam = """
    {"key": "init_noise_level", "type": "float", "label": "Noise",
     "default": 1.0, "nullable": false, "min": 0.1, "max": 10.0}
    """

    /// Stands in for `acestep-base`: turbo, so cover and repaint but no
    /// extract/lego/complete.
    private func aceTurbo(id: String = "ace-turbo",
                          installState: String = "installed") -> ModelInfo {
        model(id, params: """
        [\(taskTypeParam(["text2music", "cover", "repaint"])),
         \(audioParam("src_audio")), \(audioParam("reference_audio")),
         \(coverStrengthParam),
         {"key": "steps", "type": "int", "label": "Steps", "default": 8,
          "nullable": false, "min": 4, "max": 100}]
        """, installState: installState)
    }

    /// Stands in for `acestep-15-dit-base`: the full task set.
    private func aceBase(id: String = "ace-base",
                         installState: String = "installed") -> ModelInfo {
        model(id, params: """
        [\(taskTypeParam(["text2music", "cover", "repaint",
                          "extract", "lego", "complete"])),
         \(audioParam("src_audio")), \(audioParam("reference_audio")),
         \(coverStrengthParam),
         {"key": "track", "type": "enum", "label": "Track", "default": null,
          "nullable": true,
          "choices": [{"value": "vocals", "label": "Vocals"},
                      {"value": "drums", "label": "Drums"}]}]
        """, installState: installState, sizeBytes: 13_900_000_000)
    }

    private func stableAudio(id: String = "sao",
                             installState: String = "installed",
                             extendable: Bool = false) -> ModelInfo {
        let extra = extendable ? ",\(audioParam("extend_audio"))" : ""
        return model(id, params: """
        [\(audioParam("init_audio")), \(noiseParam)\(extra)]
        """, installState: installState)
    }

    private func melodyModel(id: String = "musicgen-melody",
                             installState: String = "installed") -> ModelInfo {
        model(id, params: "[\(audioParam("melody_audio"))]",
              installState: installState)
    }

    // MARK: - Wire mapping

    func testCoverSendsTaskTypeAndSourceOnSrcAudio() {
        let params = StyleTransferMode.cover
            .wireParams(.init(sourceUploadId: "up_1"))
        XCTAssertEqual(params["task_type"], .string("cover"))
        XCTAssertEqual(params["src_audio"], .string("up_1"))
        XCTAssertNil(params["init_audio"])
        XCTAssertNil(params["melody_audio"])
    }

    func testEachModeRoutesTheSourceToItsOwnKey() {
        // The single most consequential mapping in the feature: send the source
        // on the wrong key and the model generates from silence, cheerfully.
        let expected: [StyleTransferMode: String] = [
            .cover: "src_audio", .reference: "src_audio",
            .repaint: "src_audio", .complete: "src_audio",
            .layer: "src_audio", .extract: "src_audio",
            .morph: "src_audio", .stems: "src_audio",
            .shape: "init_audio",
            .continueTrack: "extend_audio",
            .melody: "melody_audio",
        ]
        XCTAssertEqual(Set(expected.keys), Set(StyleTransferMode.allCases),
                       "a new mode must declare where its source audio goes")
        for (mode, key) in expected {
            let params = mode.wireParams(.init(sourceUploadId: "up_1"))
            XCTAssertEqual(params[key], .string("up_1"),
                           "\(mode.rawValue) should carry its source on \(key)")
        }
    }

    func testReferenceModeChoosesItsTaskByWhetherASourceIsAttached() {
        // Upstream encodes reference_audio for every task, so a reference on a
        // bare text2music is a real shape and not a degenerate cover.
        let withSource = StyleTransferMode.reference.wireParams(
            .init(sourceUploadId: "up_1", referenceUploadId: "up_2"))
        XCTAssertEqual(withSource["task_type"], .string("cover"))
        XCTAssertEqual(withSource["src_audio"], .string("up_1"))
        XCTAssertEqual(withSource["reference_audio"], .string("up_2"))

        let referenceOnly = StyleTransferMode.reference.wireParams(
            .init(referenceUploadId: "up_2"))
        XCTAssertEqual(referenceOnly["task_type"], .string("text2music"))
        XCTAssertNil(referenceOnly["src_audio"])
        XCTAssertEqual(referenceOnly["reference_audio"], .string("up_2"))
    }

    func testModesWithNoTaskTypeSendNone() {
        // Stable Audio and MusicGen have no task_type param at all; sending one
        // would be dropped silently by the engine, but it would also be a lie
        // in the job record.
        for mode in [StyleTransferMode.shape, .continueTrack, .melody] {
            let params = mode.wireParams(.init(sourceUploadId: "up_1"))
            XCTAssertNil(params["task_type"], "\(mode.rawValue)")
        }
    }

    func testReferenceIsIgnoredByModesThatDoNotTakeOne() {
        // A reference left over from a previous mode must not ride along into
        // an extract, where it would change the result for no stated reason.
        let params = StyleTransferMode.extract.wireParams(
            .init(sourceUploadId: "up_1", referenceUploadId: "up_2",
                  track: "vocals"))
        XCTAssertNil(params["reference_audio"])
        XCTAssertEqual(params["track"], .string("vocals"))
    }

    func testTrackOnlyRidesWhenTheModeUsesIt() {
        XCTAssertEqual(
            StyleTransferMode.layer
                .wireParams(.init(sourceUploadId: "u", track: "drums"))["track"],
            .string("drums"))
        XCTAssertNil(
            StyleTransferMode.cover
                .wireParams(.init(sourceUploadId: "u", track: "drums"))["track"])
    }

    func testRepaintCarriesItsRegion() {
        let params = StyleTransferMode.repaint.wireParams(
            .init(sourceUploadId: "u", regionStartS: 12, regionEndS: 30))
        XCTAssertEqual(params["repainting_start"], .double(12))
        XCTAssertEqual(params["repainting_end"], .double(30))
    }

    func testMorphDeclaresItselfAndCarriesTheSourceCaption() {
        let params = StyleTransferMode.morph.wireParams(
            .init(sourceUploadId: "u", sourceCaption: "slow acoustic ballad"))
        XCTAssertEqual(params["task_type"], .string("text2music"))
        XCTAssertEqual(params["flow_edit_morph"], .bool(true))
        XCTAssertEqual(params["flow_edit_source_caption"],
                       .string("slow acoustic ballad"))
        // An empty caption is not a caption — sending "" would morph towards
        // silence rather than leaving the model to read the audio itself.
        let blank = StyleTransferMode.morph.wireParams(
            .init(sourceUploadId: "u", sourceCaption: ""))
        XCTAssertNil(blank["flow_edit_source_caption"])
    }

    // MARK: - The strength dial

    func testCoverStrengthIsInverted() {
        // The catalog's own help: "lower (0.2) is closer to pure style
        // transfer". The slider reads the other way round, so 1.0 on the slider
        // must be 0.0 on the wire.
        guard let dial = StyleTransferMode.cover.dial else {
            return XCTFail("cover has a strength dial")
        }
        XCTAssertEqual(dial.key, "audio_cover_strength")
        XCTAssertEqual(dial.wireValue(styleAmount: 0), 1.0, accuracy: 0.0001)
        XCTAssertEqual(dial.wireValue(styleAmount: 1), 0.0, accuracy: 0.0001)
        XCTAssertEqual(dial.wireValue(styleAmount: 0.3), 0.7, accuracy: 0.0001)
    }

    func testNoiseLevelIsLogarithmicSoTheModelDefaultLandsMidSlider() {
        // 0.1…10 spans two decades. Mapped linearly the model's own default of
        // 1.0 would sit at 9% of the travel and the top 90% of the slider would
        // be unusable noise.
        guard let dial = StyleTransferMode.shape.dial else {
            return XCTFail("shape has a strength dial")
        }
        XCTAssertEqual(dial.key, "init_noise_level")
        XCTAssertEqual(dial.wireValue(styleAmount: 0), 0.1, accuracy: 0.0001)
        XCTAssertEqual(dial.wireValue(styleAmount: 0.5), 1.0, accuracy: 0.0001)
        XCTAssertEqual(dial.wireValue(styleAmount: 1), 10.0, accuracy: 0.0001)
    }

    func testDialRoundTrips() {
        for mode in StyleTransferMode.allCases {
            guard let dial = mode.dial else { continue }
            for t in stride(from: 0.0, through: 1.0, by: 0.1) {
                let back = dial.styleAmount(wireValue:
                    dial.wireValue(styleAmount: t))
                XCTAssertEqual(back, t, accuracy: 0.0001, "\(mode.rawValue)")
            }
        }
    }

    func testDefaultSliderPositionComesFromTheModelsOwnDefault() {
        // "I didn't move it" and "the model's default" have to be the same run,
        // or every job silently carries a value the user never chose.
        let ace = aceTurbo()
        let spec = StyleTransferMode.cover.dialSpec(for: ace)
        XCTAssertNotNil(spec)
        XCTAssertEqual(
            StyleTransferMode.cover.dial?.defaultStyleAmount(spec: spec) ?? -1,
            0.3, accuracy: 0.0001)

        let sao = stableAudio()
        let noise = StyleTransferMode.shape.dialSpec(for: sao)
        XCTAssertEqual(
            StyleTransferMode.shape.dial?.defaultStyleAmount(spec: noise) ?? -1,
            0.5, accuracy: 0.0001)
    }

    func testDialHonoursACatalogThatWidensTheRange() {
        // The spec wins over the nominal bounds so a catalog change does not
        // need an app change.
        let widened = ParamSpec(key: "init_noise_level", type: .float,
                                label: "Noise", default: .double(1),
                                min: 0.01, max: 100)
        let dial = StyleTransferMode.shape.dial
        XCTAssertEqual(dial?.wireValue(styleAmount: 0.5, spec: widened) ?? -1,
                       1.0, accuracy: 0.0001)
        XCTAssertEqual(dial?.wireValue(styleAmount: 1, spec: widened) ?? -1,
                       100.0, accuracy: 0.0001)
    }

    func testStrengthIsOmittedWhenTheUserHasNotTouchedIt() {
        let params = StyleTransferMode.cover.wireParams(
            .init(sourceUploadId: "u", styleAmount: nil))
        XCTAssertNil(params["audio_cover_strength"])
    }

    func testStrengthIsClampedRatherThanTrusted() {
        guard let dial = StyleTransferMode.cover.dial else { return }
        XCTAssertEqual(dial.wireValue(styleAmount: 5), 0, accuracy: 0.0001)
        XCTAssertEqual(dial.wireValue(styleAmount: -3), 1, accuracy: 0.0001)
    }

    // MARK: - Where the source blend is and is not offered

    func testTheSourceBlendIsOfferedOnlyWhereMovingAwayIsThePoint() {
        // `audio_cover_strength` is honoured by ACE-Step on *any* task with a
        // source, and the catalog declared it non-nullable at 0.7 — so every
        // repaint, extract, layer and complete job used to ask for a 70 % blend
        // nobody chose, on tasks whose whole promise is that the rest survives.
        XCTAssertEqual(
            Set(StyleTransferMode.allCases.filter { $0.dial != nil }),
            [.cover, .reference, .stems, .shape])
        for mode in [StyleTransferMode.repaint, .complete, .layer, .extract,
                     .morph] {
            XCTAssertNil(mode.dial, mode.rawValue)
            let params = mode.wireParams(
                .init(sourceUploadId: "u", track: "vocals", styleAmount: 0.9))
            XCTAssertNil(params["audio_cover_strength"],
                         "\(mode.rawValue) must leave the source alone")
        }
    }

    func testLyricsAreOfferedOnlyWhereWordsAreSung() {
        // The stem chain's middle step re-performs the stems being *replaced* —
        // for "keep the vocal" that is the band, which sings nothing.
        XCTAssertFalse(StyleTransferMode.stems.allowsLyrics)
        XCTAssertTrue(StyleTransferMode.cover.allowsLyrics)
        XCTAssertFalse(StyleTransferMode.extract.allowsLyrics)
    }

    // MARK: - Eligibility

    func testTurboCannotServeTheBaseOnlyModes() {
        // The adapter raises rather than degrading, and the pipeline itself
        // does not refuse a wrong DiT — it just produces garbage. So the app
        // has to know.
        let models = [aceTurbo()]
        XCTAssertFalse(StyleTransferMode.cover.eligible(models).isEmpty)
        XCTAssertFalse(StyleTransferMode.repaint.eligible(models).isEmpty)
        XCTAssertTrue(StyleTransferMode.extract.eligible(models).isEmpty)
        XCTAssertTrue(StyleTransferMode.layer.eligible(models).isEmpty)
        XCTAssertTrue(StyleTransferMode.complete.eligible(models).isEmpty)
    }

    func testBaseServesEverythingTurboDoesAndMore() {
        let models = [aceBase()]
        for mode in [StyleTransferMode.cover, .repaint, .extract, .layer,
                     .complete, .reference] {
            XCTAssertFalse(mode.eligible(models).isEmpty, mode.rawValue)
        }
    }

    func testMelodyModelsServeTheMelodyMode() {
        // The old GenerativeModels.supports had no melody path at all, which is
        // why chroma conditioning was never reachable from an action.
        let models = [melodyModel(), aceTurbo()]
        XCTAssertEqual(StyleTransferMode.melody.eligible(models).map(\.id),
                       ["musicgen-melody"])
    }

    func testStableAudioServesShapeAndOnlyTheExtendableOneContinues() {
        let plain = stableAudio(id: "sao-small")
        let extendable = stableAudio(id: "sao3", extendable: true)
        let models = [plain, extendable]
        XCTAssertEqual(Set(StyleTransferMode.shape.eligible(models).map(\.id)),
                       ["sao-small", "sao3"])
        XCTAssertEqual(
            StyleTransferMode.continueTrack.eligible(models).map(\.id), ["sao3"])
    }

    func testMorphNeedsTheModelToDeclareIt() {
        // Expressed against a declared param, not against ids: FlowEdit is a
        // turbo-capable path, so "is it an ACE-Step base build" is the wrong
        // question and would exclude exactly the model it works on.
        XCTAssertTrue(StyleTransferMode.morph.eligible([aceTurbo()]).isEmpty)
        let withMorph = model("ace-morph", params: """
        [\(taskTypeParam(["text2music", "cover"])), \(audioParam("src_audio")),
         {"key": "flow_edit_morph", "type": "bool", "label": "Morph",
          "default": false, "nullable": false}]
        """)
        XCTAssertFalse(StyleTransferMode.morph.eligible([withMorph]).isEmpty)
    }

    func testUninstalledModelsAreCandidatesButNotEligible() {
        let models = [aceBase(installState: "not_installed")]
        XCTAssertTrue(StyleTransferMode.extract.eligible(models).isEmpty)
        XCTAssertEqual(StyleTransferMode.extract.candidates(models).map(\.id),
                       ["ace-base"])
        XCTAssertEqual(StyleTransferMode.extract.unavailableReason(models),
                       "Needs ace-base.")
        XCTAssertNil(StyleTransferMode.extract
            .unavailableReason([aceBase(installState: "installed")]))
    }

    func testCandidatesOfferTheCheapestModelFirst() {
        // "Which one do I download" almost always means "the smallest that
        // works".
        let big = aceBase(id: "ace-xl", installState: "not_installed")
        let small = aceTurbo(id: "ace-turbo", installState: "not_installed")
        // aceTurbo cannot cover-only... it can. Both serve cover.
        let ids = StyleTransferMode.cover.candidates([big, small]).map(\.id)
        XCTAssertEqual(ids, ["ace-turbo", "ace-xl"])
    }

    func testNonGenerativeModelsAreNeverEligible() {
        // A separation model declaring src_audio must not be offered as a way
        // to restyle.
        let separator = model("separation-htdemucs",
                              params: "[\(audioParam("source_audio"))]",
                              tasks: #"["separate"]"#)
        for mode in StyleTransferMode.allCases {
            XCTAssertTrue(mode.eligible([separator]).isEmpty, mode.rawValue)
        }
    }

    // MARK: - Knobs

    func testTheWorkspacesOwnKeysAreHiddenFromTheGenericForm() {
        // The bug this fixes: audio_cover_strength and init_noise_level were
        // not in the old programmaticKeys, so both appeared as anonymous
        // sliders under ADVANCED *as well as* being set by the flow — and the
        // form's copy won, silently discarding the mode's own dial.
        let knobs = StyleTransferMode.knobSpecs(for: aceTurbo()).map(\.key)
        XCTAssertEqual(knobs, ["steps"])
        XCTAssertFalse(knobs.contains("audio_cover_strength"))
        XCTAssertFalse(knobs.contains("task_type"))
        XCTAssertFalse(knobs.contains("src_audio"))

        XCTAssertEqual(StyleTransferMode.knobSpecs(for: stableAudio()).map(\.key),
                       [])
    }

    func testEveryKeyAnyModeWritesIsDeclaredProgrammatic() {
        // Otherwise the key appears twice — once as the mode's control and once
        // as a knob — and whichever is merged last wins by accident.
        let inputs = StyleTransferMode.Inputs(
            sourceUploadId: "u", referenceUploadId: "r", track: "vocals",
            regionStartS: 1, regionEndS: 2, styleAmount: 0.5,
            sourceCaption: "x")
        for mode in StyleTransferMode.allCases {
            for key in mode.wireParams(inputs).keys {
                XCTAssertTrue(
                    StyleTransferMode.programmaticKeys.contains(key),
                    "\(mode.rawValue) writes \(key), which the knob form would "
                        + "also render")
            }
        }
    }

    // MARK: - Model-aware wire mapping

    private func musicgenStyle(id: String = "musicgen-style",
                               installState: String = "installed") -> ModelInfo {
        model(id, params: """
        [\(audioParam("style_audio")),
         {"key": "style_excerpt_s", "type": "float", "label": "Excerpt",
          "default": 3.0, "nullable": false, "min": 1.5, "max": 4.5},
         {"key": "top_k", "type": "int", "label": "Top-K", "default": 250,
          "nullable": false, "min": 10, "max": 1000}]
        """, installState: installState)
    }

    func testMusicGenStyleServesTheReferenceModeUnderItsOwnKey() {
        // Two families, one capability, different key names. The mode names
        // what the user gets; the model picks the key.
        let models = [musicgenStyle()]
        XCTAssertFalse(StyleTransferMode.reference.eligible(models).isEmpty)
        XCTAssertEqual(
            StyleTransferMode.reference.referenceAudioKey(for: musicgenStyle()),
            "style_audio")
        XCTAssertEqual(
            StyleTransferMode.reference.referenceAudioKey(for: aceTurbo()),
            "reference_audio")
        // A mode that takes no reference names no key at all.
        XCTAssertNil(StyleTransferMode.repaint.referenceAudioKey(for: aceTurbo()))
    }

    func testAModelOnlyEverReceivesKeysItDeclares() {
        // The engine drops unrecognised keys *silently* — recorded as a job.log
        // line and nothing else — so a job carrying a task_type the model has
        // never heard of would run happily and ignore half its instructions.
        let params = StyleTransferMode.reference.wireParams(
            .init(sourceUploadId: "up_1", referenceUploadId: "up_2",
                  styleAmount: 0.5),
            model: musicgenStyle())
        XCTAssertEqual(params["style_audio"], .string("up_2"))
        XCTAssertNil(params["task_type"], "no task selector on this model")
        XCTAssertNil(params["src_audio"], "no source input on this model")
        XCTAssertNil(params["reference_audio"], "wrong key for this family")
        XCTAssertNil(params["audio_cover_strength"], "no such knob here")
    }

    func testTheSameModeOnACEStepKeepsEveryKey() {
        let params = StyleTransferMode.reference.wireParams(
            .init(sourceUploadId: "up_1", referenceUploadId: "up_2",
                  styleAmount: 0.5),
            model: aceTurbo(),
            spec: StyleTransferMode.reference.dialSpec(for: aceTurbo()))
        XCTAssertEqual(params["task_type"], .string("cover"))
        XCTAssertEqual(params["src_audio"], .string("up_1"))
        XCTAssertEqual(params["reference_audio"], .string("up_2"))
        XCTAssertEqual(params["audio_cover_strength"]?.doubleValue ?? -1, 0.5,
                       accuracy: 0.0001)
    }

    func testTheStrengthSliderHidesOnAModelWithNoSuchKnob() {
        // Better than a slider that silently writes into the void.
        XCTAssertTrue(StyleTransferMode.reference.hasDial(on: aceTurbo()))
        XCTAssertFalse(StyleTransferMode.reference.hasDial(on: musicgenStyle()))
        // Modes with no dial at all never claim one.
        XCTAssertFalse(StyleTransferMode.melody.hasDial(on: melodyModel()))
    }

    func testMorphIsFilteredOutOfAModelThatCannotMorph() {
        let params = StyleTransferMode.morph.wireParams(
            .init(sourceUploadId: "u", sourceCaption: "ballad"),
            model: aceTurbo())
        XCTAssertNil(params["flow_edit_morph"],
                     "aceTurbo fixture predates the FlowEdit params")
        XCTAssertEqual(params["src_audio"], .string("u"))
    }

    // MARK: - Bridging from the recipe table

    func testEveryGenerateRecipeTaskMapsToAMode() {
        // The nine Reimagine cards are being re-pointed at this type; each one
        // must land somewhere deliberate.
        let expected: [String: StyleTransferMode] = [
            "cover": .cover, "repaint": .repaint, "extract": .extract,
            "lego": .layer, "complete": .complete, "init_audio": .shape,
            "extend_audio": .continueTrack,
        ]
        for (task, mode) in expected {
            XCTAssertEqual(StyleTransferMode.forModelTask(task), mode, task)
        }
    }

    func testAnUnknownTaskFallsBackToCoverRatherThanFailing() {
        // GenerativeShape did the same. A catalog that grows a task the app has
        // not learned yet should degrade to something usable.
        XCTAssertEqual(StyleTransferMode.forModelTask("teleport"), .cover)
    }

    func testFirstAvailablePrefersTheRequestedModeThenFallsBack() {
        let turbo = [aceTurbo()]
        XCTAssertEqual(
            StyleTransferMode.firstAvailable(preferring: .cover, models: turbo),
            .cover)
        // extract needs a Base DiT; with only turbo installed the workspace
        // still has to show something that works.
        XCTAssertEqual(
            StyleTransferMode.firstAvailable(preferring: .extract,
                                             models: turbo),
            .cover)
        // Nothing installed at all: keep the requested mode so the screen can
        // explain what to install rather than silently choosing another job.
        XCTAssertEqual(
            StyleTransferMode.firstAvailable(preferring: .extract, models: []),
            .extract)
    }

    // MARK: - The shape of the mode set

    func testEveryModeAnswersEveryQuestionItIsAsked() {
        for mode in StyleTransferMode.allCases {
            XCTAssertFalse(mode.title.isEmpty, mode.rawValue)
            XCTAssertFalse(mode.survives.isEmpty, mode.rawValue)
            XCTAssertFalse(mode.icon.isEmpty, mode.rawValue)
            XCTAssertFalse(mode.promptLabel.isEmpty, mode.rawValue)
            XCTAssertFalse(mode.requirements.isEmpty, mode.rawValue)
            XCTAssertFalse(mode.sourceAudioKey.isEmpty, mode.rawValue)
        }
    }

    func testEveryModeBelongsToExactlyOneGroupAndEveryGroupHasModes() {
        let grouped = StyleTransferMode.Group.allCases
            .flatMap(StyleTransferMode.inGroup)
        XCTAssertEqual(Set(grouped), Set(StyleTransferMode.allCases))
        XCTAssertEqual(grouped.count, StyleTransferMode.allCases.count)
        for group in StyleTransferMode.Group.allCases {
            XCTAssertFalse(StyleTransferMode.inGroup(group).isEmpty,
                           group.rawValue)
        }
    }

    func testOnlyExtractSkipsThePromptAndOnlyPartsModesOutputParts() {
        XCTAssertEqual(
            StyleTransferMode.allCases.filter { !$0.needsPrompt }, [.extract])
        XCTAssertEqual(Set(StyleTransferMode.allCases.filter(\.outputsPart)),
                       [.extract, .layer])
        XCTAssertEqual(StyleTransferMode.allCases.filter(\.isChain), [.stems])
        XCTAssertEqual(StyleTransferMode.allCases.filter(\.needsRegion),
                       [.repaint])
    }

    func testOnlyReferenceMakesTheSourceOptional() {
        // The boundary against Studio: with no audio in front of it this screen
        // would just be a second prompt box.
        for mode in StyleTransferMode.allCases where mode != .reference {
            XCTAssertEqual(mode.sourceNeed, .required, mode.rawValue)
        }
        XCTAssertEqual(StyleTransferMode.reference.sourceNeed, .optional)
        XCTAssertEqual(StyleTransferMode.reference.referenceNeed, .required)
    }

    func testRawValuesAreStableBecauseTheyArePersisted() {
        // The mode is stored in the workspace and in preset routing; renaming a
        // case silently resets whatever it was pointing at.
        XCTAssertEqual(Set(StyleTransferMode.allCases.map(\.rawValue)),
                       ["cover", "reference", "melody", "morph", "shape",
                        "stems", "repaint", "complete", "continue", "layer",
                        "extract"])
    }
}

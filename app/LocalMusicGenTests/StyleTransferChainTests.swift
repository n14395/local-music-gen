import XCTest
@testable import LocalMusicGen

/// Split → restyle → remix, planned before anything runs.
///
/// The failure this suite exists to prevent is expensive rather than subtle:
/// separation takes minutes on a local machine, so re-running it to produce
/// stems that are already sitting in the Library is the worst thing the planner
/// can do, and it is invisible in code review.
final class StyleTransferChainTests: XCTestCase {

    // MARK: - Fixtures

    private func model(_ id: String, params: String = "[]",
                       tasks: String = "null",
                       installState: String = "installed") -> ModelInfo {
        let json = """
        {
          "id": "\(id)", "family": "test",
          "display_name": "\(id)", "description": "", "hf_repos": [],
          "size_bytes": 1000, "install_state": "\(installState)",
          "installed_bytes": 0,
          "capabilities": {
            "supports_lyrics": false, "instrumental_only": true,
            "duration": {"min_s": 1, "max_s": 300, "default_s": 30},
            "sample_rate": 44100, "outputs_per_job_max": 1,
            "est_seconds_per_audio_second": 1, "tasks": \(tasks),
            "params": \(params)
          },
          "requirements": {"min_ram_bytes": 8589934592, "disk_bytes": 1000,
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

    private func separator(installState: String = "installed") -> ModelInfo {
        model("separation-htdemucs",
              params: """
              [{"key": "source_audio", "type": "audio", "label": "Source",
                "default": null, "nullable": true}]
              """,
              tasks: #"["separate"]"#, installState: installState)
    }

    private func mixer(installState: String = "installed") -> ModelInfo {
        model("dsp-mixdown",
              params: """
              [{"key": "mix_spec", "type": "json", "label": "Mix",
                "default": null, "nullable": true}]
              """,
              tasks: #"["mix"]"#, installState: installState)
    }

    /// Token Splice also declares `mix` but consumes a splice_spec — picking it
    /// for a mixdown fails the job. The planner must not.
    private func splicer() -> ModelInfo {
        model("codec-tokensplice",
              params: """
              [{"key": "splice_spec", "type": "json", "label": "Splice",
                "default": null, "nullable": true}]
              """,
              tasks: #"["mix"]"#)
    }

    private func restyler(installState: String = "installed") -> ModelInfo {
        model("acestep-base", params: """
        [{"key": "task_type", "type": "enum", "label": "Task",
          "default": "text2music", "nullable": false,
          "choices": [{"value": "text2music", "label": "Generate"},
                      {"value": "cover", "label": "Cover"}]},
         {"key": "src_audio", "type": "audio", "label": "Source",
          "default": null, "nullable": true}]
        """, installState: installState)
    }

    private var fullCatalog: [ModelInfo] {
        [separator(), splicer(), mixer(), restyler()]
    }

    private func stems(_ labels: [String]) -> [StyleTransferChain.Stem] {
        labels.map {
            .init(id: "part-\($0)", kind: "stem.\($0)",
                  name: $0.capitalized, durationS: 180)
        }
    }

    // MARK: - The happy path

    func testKeepingOneStemOfFourPlansFoldRestyleRemix() {
        let chain = StyleTransferChain.make(
            stems: stems(["vocals", "drums", "bass", "other"]),
            keep: ["stem.vocals"], models: fullCatalog)

        XCTAssertTrue(chain.isRunnable)
        XCTAssertNil(chain.blockedReason)
        XCTAssertFalse(chain.needsSplitFirst)
        XCTAssertEqual(chain.steps.map(\.id), ["fold", "restyle", "remix"])
        XCTAssertEqual(chain.keptKinds, ["stem.vocals"])
        XCTAssertEqual(chain.replacedKinds,
                       ["stem.drums", "stem.bass", "stem.other"])
    }

    func testExistingStemsSkipTheSplitEntirely() {
        // Demucs takes minutes. This is the whole reason the planner reads the
        // Library before it plans.
        let chain = StyleTransferChain.make(
            stems: stems(["vocals", "instrumental"]),
            keep: ["stem.vocals"], models: fullCatalog)
        XCTAssertFalse(chain.steps.contains { $0.id == "split" })
    }

    func testASingleStemToReplaceNeedsNoFold() {
        // One file can go straight to the model; folding it would be a job that
        // rewrites a file into itself.
        let chain = StyleTransferChain.make(
            stems: stems(["vocals", "instrumental"]),
            keep: ["stem.vocals"], models: fullCatalog)
        XCTAssertEqual(chain.steps.map(\.id), ["restyle", "remix"])
    }

    func testKeepingSeveralStemsStillFoldsOnlyTheRemainder()  {
        let chain = StyleTransferChain.make(
            stems: stems(["vocals", "drums", "bass", "other"]),
            keep: ["stem.vocals", "stem.drums"], models: fullCatalog)
        XCTAssertEqual(chain.steps.map(\.id), ["fold", "restyle", "remix"])
        XCTAssertEqual(chain.replacedKinds, ["stem.bass", "stem.other"])
        XCTAssertEqual(chain.keptKinds, ["stem.vocals", "stem.drums"])
    }

    func testLayerPartsCountAsMaterialAlongsideStems() {
        // The house convention, enforced elsewhere by
        // testStemSlotsAlsoAcceptLayers: an AI layer is musically
        // interchangeable with a stem.
        let material = stems(["vocals"]) + [
            .init(id: "p-l", kind: "layer.strings", name: "Strings layer"),
        ]
        let chain = StyleTransferChain.make(
            stems: material, keep: ["stem.vocals"], models: fullCatalog)
        XCTAssertEqual(chain.replacedKinds, ["layer.strings"])
        XCTAssertTrue(chain.isRunnable)
    }

    func testNonAudioPartsAreIgnored() {
        // Notes and analysis parts share the taxonomy but cannot be mixed.
        let material = stems(["vocals", "drums"]) + [
            .init(id: "p-n", kind: "notes.piano", name: "Piano notes"),
            .init(id: "p-a", kind: "analysis.basic", name: "Analysis"),
        ]
        let chain = StyleTransferChain.make(
            stems: material, keep: ["stem.vocals"], models: fullCatalog)
        XCTAssertEqual(chain.replacedKinds, ["stem.drums"])
    }

    func testDuplicateKindsAreNotSubmittedTwice() {
        // A song can hold two `stem.vocals` parts — extract a vocal
        // generatively, then split the song, and it does. Selection is by kind,
        // so a duplicate would put the original vocal *and* the AI one into the
        // same mix, phasing against each other, off one ticked chip.
        let duplicated = stems(["vocals", "drums"]) + [
            .init(id: "part-vocals-ai", kind: "stem.vocals", name: "AI Vocals"),
        ]
        let chain = StyleTransferChain.make(
            stems: duplicated, keep: ["stem.vocals"], models: fullCatalog)
        XCTAssertEqual(chain.keptKinds, ["stem.vocals", "stem.vocals"],
                       "the planner reports what it was given")
        // The *store* is what de-duplicates, before the planner ever sees it —
        // see StyleTransferModel.availableStems. This test pins the shape the
        // planner is entitled to assume.
        let deduplicated = Array(
            Dictionary(grouping: duplicated, by: \.kind)
                .values.compactMap(\.first))
        let clean = StyleTransferChain.make(
            stems: deduplicated, keep: ["stem.vocals"], models: fullCatalog)
        XCTAssertEqual(clean.keptKinds.count, 1)
        XCTAssertEqual(clean.replacedKinds.count, 1)
    }

    // MARK: - Nothing split yet

    func testAnUnsplitSongPlansOnlyTheSplit() {
        // Which stems a song has is not knowable in advance: the catalog does
        // not declare a separation model's outputs, and the four-stem, six-stem
        // and vocals/instrumental builds all disagree. Offering checkboxes for
        // stems the chosen model will never produce would be worse than waiting.
        let chain = StyleTransferChain.make(
            stems: [], keep: [], models: fullCatalog)
        XCTAssertTrue(chain.needsSplitFirst)
        XCTAssertEqual(chain.steps.map(\.id), ["split"])
        XCTAssertTrue(chain.isRunnable)
        XCTAssertNil(chain.blockedReason)
        XCTAssertFalse(chain.warnings.isEmpty)
    }

    func testAnUnsplitSongIgnoresWhateverWasTickedBefore() {
        let chain = StyleTransferChain.make(
            stems: [], keep: ["stem.vocals"], models: fullCatalog)
        XCTAssertEqual(chain.steps.map(\.id), ["split"])
        XCTAssertTrue(chain.keptKinds.isEmpty)
    }

    // MARK: - Refusals

    func testKeepingNothingIsRefusedRatherThanRunAsAPlainRestyle() {
        // Silently degrading to "restyle the whole song" would run three jobs
        // to do what one mode already does better.
        let chain = StyleTransferChain.make(
            stems: stems(["vocals", "drums"]), keep: [], models: fullCatalog)
        XCTAssertFalse(chain.isRunnable)
        XCTAssertNotNil(chain.blockedReason)
        XCTAssertTrue(chain.steps.isEmpty)
    }

    func testKeepingEverythingIsRefused() {
        let chain = StyleTransferChain.make(
            stems: stems(["vocals", "drums"]),
            keep: ["stem.vocals", "stem.drums"], models: fullCatalog)
        XCTAssertFalse(chain.isRunnable)
        XCTAssertNotNil(chain.blockedReason)
    }

    func testEveryMissingModelIsReportedAtOnce() {
        // Told one at a time, the user installs a model, comes back, and is
        // told about the next one.
        let chain = StyleTransferChain.make(
            stems: [], keep: [],
            models: [separator(installState: "not_installed"),
                     mixer(installState: "not_installed"),
                     restyler(installState: "not_installed")])
        XCTAssertFalse(chain.isRunnable)
        let reason = chain.blockedReason ?? ""
        XCTAssertTrue(reason.contains("separation"), reason)
        XCTAssertTrue(reason.contains("cover"), reason)
        XCTAssertTrue(reason.contains("mixdown"), reason)
    }

    func testTokenSpliceIsNotMistakenForAMixdown() {
        // It declares `mix` but consumes a splice_spec; picking it fails the
        // job with "missing required input 'mix_spec'".
        let chain = StyleTransferChain.make(
            stems: stems(["vocals", "drums"]), keep: ["stem.vocals"],
            models: [separator(), splicer(), restyler()])
        XCTAssertFalse(chain.isRunnable)
        XCTAssertEqual(chain.blockedReason?.contains("mixdown"), true)
    }

    func testAnAlreadySplitSongNeedsNoSeparationModel() {
        // The stems are on disk; refusing to proceed because the model that
        // made them has since been uninstalled would be nonsense.
        let chain = StyleTransferChain.make(
            stems: stems(["vocals", "drums"]), keep: ["stem.vocals"],
            models: [separator(installState: "not_installed"),
                     mixer(), restyler()])
        XCTAssertTrue(chain.isRunnable)
        XCTAssertEqual(chain.steps.map(\.id), ["restyle", "remix"])
    }

    // MARK: - Model choice

    func testTheChosenRestyleModelIsHonoured() {
        let other = model("acestep-15-dit-base", params: """
        [{"key": "task_type", "type": "enum", "label": "Task",
          "default": "text2music", "nullable": false,
          "choices": [{"value": "cover", "label": "Cover"}]},
         {"key": "src_audio", "type": "audio", "label": "Source",
          "default": null, "nullable": true}]
        """)
        let chain = StyleTransferChain.make(
            stems: stems(["vocals", "drums"]), keep: ["stem.vocals"],
            models: [separator(), mixer(), restyler(), other],
            restyleModelId: "acestep-15-dit-base")
        let restyle = chain.steps.first { $0.id == "restyle" }
        XCTAssertEqual(restyle?.modelId, "acestep-15-dit-base")
    }

    func testAnUninstalledChoiceFallsBackRatherThanBlocking() {
        let chain = StyleTransferChain.make(
            stems: stems(["vocals", "drums"]), keep: ["stem.vocals"],
            models: fullCatalog, restyleModelId: "a-model-that-is-not-here")
        XCTAssertTrue(chain.isRunnable)
        XCTAssertEqual(chain.steps.first { $0.id == "restyle" }?.modelId,
                       "acestep-base")
    }

    // MARK: - Warnings

    func testAnUnanalysedSourceIsWarnedAboutRatherThanSilentlyUnaligned() {
        // planMix drops to stretch.mode = "none" with no analysis behind it, so
        // the mix still renders — just never beat-aligned. Quiet degradation
        // reads as "the feature is bad".
        let chain = StyleTransferChain.make(
            stems: stems(["vocals", "drums"]), keep: ["stem.vocals"],
            models: fullCatalog, sourceIsAnalyzed: false)
        XCTAssertTrue(chain.isRunnable)
        XCTAssertTrue(chain.warnings.contains { $0.contains("tempo") },
                      "\(chain.warnings)")
    }

    func testTheModelIsNotToldWhichInstrumentsItReplaces() {
        // Stated in the UI rather than papered over: stem-aware conditioning
        // would be a contract change.
        let chain = StyleTransferChain.make(
            stems: stems(["vocals", "drums"]), keep: ["stem.vocals"],
            models: fullCatalog)
        XCTAssertTrue(chain.warnings.contains { $0.contains("not told") },
                      "\(chain.warnings)")
    }

    // MARK: - Progress

    func testProgressReadsAsStepNOfM() {
        let chain = StyleTransferChain.make(
            stems: stems(["vocals", "drums", "bass"]), keep: ["stem.vocals"],
            models: fullCatalog)
        var progress = StyleTransferChain.Progress()
        XCTAssertEqual(chain.statusLine(progress),
                       "Step 1 of 3 — Fold the rest together")
        progress.stepIndex = 2
        XCTAssertEqual(chain.statusLine(progress),
                       "Step 3 of 3 — Mix it back together")
    }

    func testProgressSurvivesAnOutOfRangeIndex() {
        // The last step completing bumps the index past the end.
        let chain = StyleTransferChain.make(
            stems: stems(["vocals", "drums"]), keep: ["stem.vocals"],
            models: fullCatalog)
        var progress = StyleTransferChain.Progress()
        progress.stepIndex = 99
        XCTAssertFalse(chain.statusLine(progress).isEmpty)
    }

    func testAFailedStepSaysWhereItStopped() {
        let chain = StyleTransferChain.make(
            stems: stems(["vocals", "drums"]), keep: ["stem.vocals"],
            models: fullCatalog)
        var progress = StyleTransferChain.Progress()
        progress.stepIndex = 1
        progress.failure = "out of memory"
        XCTAssertEqual(chain.statusLine(progress),
                       "Stopped at step 2: out of memory")
        XCTAssertTrue(progress.isFailed)
    }

    func testPartialsAreCarriedRatherThanRolledBack() {
        // A half-finished chain still leaves usable stems in the Library;
        // discarding them to keep the state tidy would destroy the expensive
        // half of the work.
        var progress = StyleTransferChain.Progress()
        progress.producedPartIds = ["p1", "p2"]
        progress.failure = "cancelled"
        XCTAssertEqual(progress.producedPartIds, ["p1", "p2"])
    }

    // MARK: - Copy

    func testStemLabelsDropTheirNamespace() {
        XCTAssertEqual(stems(["vocals"])[0].label, "vocals")
        XCTAssertEqual(
            StyleTransferChain.Stem(id: "x", kind: "layer.strings",
                                    name: "n").label, "strings")
        // A kind with no namespace is passed through rather than truncated.
        XCTAssertEqual(
            StyleTransferChain.Stem(id: "x", kind: "mix", name: "n").label,
            "mix")
    }

    func testListsReadAsEnglish() {
        XCTAssertEqual(StyleTransferChain.list([]), "")
        XCTAssertEqual(StyleTransferChain.list(["vocals"]), "vocals")
        XCTAssertEqual(StyleTransferChain.list(["vocals", "drums"]),
                       "vocals and drums")
        XCTAssertEqual(StyleTransferChain.list(["vocals", "drums", "bass"]),
                       "vocals, drums and bass")
    }

    func testEveryStepPrintsSomething() {
        let chain = StyleTransferChain.make(
            stems: stems(["vocals", "drums", "bass"]), keep: ["stem.vocals"],
            models: fullCatalog)
        for step in chain.steps {
            XCTAssertFalse(step.title.isEmpty, step.id)
            XCTAssertFalse(step.detail.isEmpty, step.id)
            XCTAssertFalse(step.modelName.isEmpty, step.id)
            XCTAssertFalse(step.modelId.isEmpty, step.id)
        }
    }
}

/// What an Actions card handed to a workspace that is busy.
@MainActor
final class StyleTransferPresetHandoffTests: XCTestCase {

    private func running() -> StyleTransferModel {
        let workspace = StyleTransferModel()
        let plan = StyleTransferChain(
            steps: [.restyle(modelId: "m", modelName: "M",
                             kinds: ["stem.drums"])],
            keptKinds: ["stem.vocals"], replacedKinds: ["stem.drums"],
            blockedReason: nil, warnings: [], needsSplitFirst: false)
        workspace.chain = .init(id: "run-1", plan: plan, progress: .init())
        return workspace
    }

    /// A preset offered while a chain runs is held, not thrown away: the
    /// "Apply preset" button is bound to `pendingPreset`, so clearing it took
    /// away the only way to act on the notice's own advice.
    func testAPresetOfferedDuringAChainIsKept() {
        let workspace = running()
        XCTAssertTrue(workspace.isChainRunning)
        let preset = StylePreset(id: "restyle-this", mode: .cover,
                                 promptSeed: "brass band")

        let applied = workspace.seed(preset: preset, presetName: "Restyle",
                                     source: nil, models: [])
        XCTAssertFalse(applied, "nothing was applied, so do not say it was")
        XCTAssertNotNil(workspace.pendingPreset)
        XCTAssertEqual(workspace.prompt, "", "the chain still owns the setup")

        // …and it can be taken up once the chain is out of the way.
        workspace.dismissChain()
        workspace.applyPendingPreset(models: [])
        XCTAssertNil(workspace.pendingPreset)
        XCTAssertEqual(workspace.prompt, "brass band")
    }

    /// The offer survives a press that is still too early.
    func testApplyingTooEarlyKeepsTheOffer() {
        let workspace = running()
        workspace.seed(preset: StylePreset(id: "p", mode: .cover),
                       presetName: "P", source: nil, models: [])
        workspace.applyPendingPreset(models: [])
        XCTAssertNotNil(workspace.pendingPreset)
    }
}

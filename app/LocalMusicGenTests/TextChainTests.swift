import XCTest
@testable import LocalMusicGen

/// The music↔text pipeline planner. Pure, so the expensive discoveries — a
/// third stage that was never runnable, a round that loops forever — are made
/// here rather than after two model loads.
final class TextChainTests: XCTestCase {

    private func model(_ id: String, tasks: [String],
                       installed: Bool = true) -> ModelInfo {
        ModelFixtures.model(id: id, tasks: tasks, installed: installed)
    }

    private var everything: [ModelInfo] {
        [model("caption-lpmusiccaps", tasks: ["caption"]),
         model("lyrics-whisper-turbo", tasks: ["lyrics"]),
         model("transcribe-basicpitch", tasks: ["transcribe"]),
         model("compose-notagen", tasks: ["compose"]),
         model("separation-htdemucs", tasks: ["separate"]),
         model("musicgen-small", tasks: ["generate"])]
    }

    private func inputs(_ models: [ModelInfo]) -> TextChain.Inputs {
        var inputs = TextChain.Inputs()
        inputs.models = models
        return inputs
    }

    // MARK: - Blocking

    /// Every missing piece at once. Told about them one at a time, the user
    /// installs a model, comes back, and is told about the next.
    func testEveryMissingModelIsReportedTogether() {
        let plan = TextChain.make(kind: .abcRoundTrip, inputs: inputs([]))
        XCTAssertFalse(plan.isRunnable)
        let reason = plan.blockedReason ?? ""
        XCTAssertTrue(reason.contains("a note transcriber"), reason)
        XCTAssertTrue(reason.contains("a notation composer"), reason)
    }

    /// A round trip needs a generator as well as a describer, and says so.
    func testRoundTripReportsAMissingGenerator() {
        let plan = TextChain.make(
            kind: .roundTrip,
            inputs: inputs([model("caption-lpmusiccaps", tasks: ["caption"])]))
        XCTAssertFalse(plan.isRunnable)
        XCTAssertTrue(plan.blockedReason?
            .contains("a model that generates audio") ?? false,
                      plan.blockedReason ?? "")
    }

    /// An uninstalled model is not a model: the plan is blocked, not planned
    /// against something that is only in the catalog.
    func testUninstalledModelsDoNotCount() {
        let plan = TextChain.make(
            kind: .lyrics,
            inputs: inputs([model("lyrics-whisper-turbo", tasks: ["lyrics"],
                                  installed: false)]))
        XCTAssertFalse(plan.isRunnable)
    }

    // MARK: - Shapes

    func testLyricsPlanIsOneStageByDefault() {
        let plan = TextChain.make(kind: .lyrics, inputs: inputs(everything))
        XCTAssertEqual(plan.stages.map(\.id), ["lyrics"])
        XCTAssertEqual(plan.jobCount, 1)
    }

    /// The separation pre-step appears only when asked for AND needed.
    func testSeparationPreStepIsOptionalAndSkippedForAVocal() {
        var asked = inputs(everything)
        asked.separateVocalsFirst = true
        XCTAssertEqual(
            TextChain.make(kind: .lyrics, inputs: asked).stages.map(\.id),
            ["separate", "lyrics"])

        var alreadyVocal = asked
        alreadyVocal.hasVocalsStem = true
        let plan = TextChain.make(kind: .lyrics, inputs: alreadyVocal)
        XCTAssertEqual(plan.stages.map(\.id), ["lyrics"])
        XCTAssertTrue(plan.warnings.contains { $0.contains("already is a vocal") })
    }

    /// A missing separator does not block the run — transcribing the mix is
    /// worse, not impossible — but it is said out loud.
    func testAMissingSeparatorWarnsRatherThanBlocks() {
        var asked = inputs(everything.filter {
            !$0.capabilities.supportedTasks.contains("separate")
        })
        asked.separateVocalsFirst = true
        let plan = TextChain.make(kind: .lyrics, inputs: asked)
        XCTAssertTrue(plan.isRunnable)
        XCTAssertEqual(plan.stages.map(\.id), ["lyrics"])
        XCTAssertTrue(plan.warnings.contains { $0.contains("full mix") })
    }

    func testRoundTripIsCaptionThenGenerate() {
        let plan = TextChain.make(kind: .roundTrip, inputs: inputs(everything))
        XCTAssertEqual(plan.stages.map(\.id), ["caption", "generate"])
    }

    /// The edited variant parks between the two, exactly once.
    func testEditedRoundTripHasOneEditStage() {
        let plan = TextChain.make(kind: .roundTripEdited,
                                  inputs: inputs(everything))
        XCTAssertEqual(plan.stages.map(\.id), ["caption", "edit", "generate"])
        // The pause is a stage but never a job.
        XCTAssertEqual(plan.jobCount, 2)
    }

    /// Rounds are unrolled, so "step 4 of 6" is a fact about the plan.
    func testTelephoneUnrollsItsRounds() {
        var three = inputs(everything)
        three.rounds = 3
        let plan = TextChain.make(kind: .telephone, inputs: three)
        XCTAssertEqual(plan.rounds, 3)
        XCTAssertEqual(plan.stages.count, 6)
        XCTAssertEqual(plan.stages.map(\.id),
                       ["caption", "generate", "caption", "generate",
                        "caption", "generate"])
    }

    /// Rounds are clamped: one round is not a telephone game, and seven is a
    /// morning of model reloads.
    func testTelephoneRoundsAreClamped() {
        var one = inputs(everything)
        one.rounds = 1
        XCTAssertEqual(TextChain.make(kind: .telephone, inputs: one).rounds, 2)
        var many = inputs(everything)
        many.rounds = 99
        XCTAssertEqual(TextChain.make(kind: .telephone, inputs: many).rounds, 6)
    }

    func testAbcEditedPausesBeforeComposing() {
        let plan = TextChain.make(kind: .abcEdited, inputs: inputs(everything))
        XCTAssertEqual(plan.stages.map(\.id), ["abc", "edit", "compose"])
    }

    /// The telephone game's cost is a model swap per round, and the card says
    /// so rather than letting the user discover it in the queue.
    func testTelephoneWarnsAboutModelSwapping() {
        let plan = TextChain.make(kind: .telephone, inputs: inputs(everything))
        XCTAssertTrue(plan.warnings.contains { $0.contains("unloads") })
    }

    // MARK: - Model choice

    func testANamedModelWinsWhileInstalled() {
        var chosen = inputs(everything
            + [model("caption-qwen2audio", tasks: ["caption", "tag"])])
        chosen.captionerId = "caption-qwen2audio"
        let plan = TextChain.make(kind: .roundTrip, inputs: chosen)
        XCTAssertEqual(plan.stages.first?.modelId, "caption-qwen2audio")
    }

    func testANamedModelThatIsGoneFallsBack() {
        var chosen = inputs(everything)
        chosen.captionerId = "caption-uninstalled"
        let plan = TextChain.make(kind: .roundTrip, inputs: chosen)
        XCTAssertEqual(plan.stages.first?.modelId, "caption-lpmusiccaps")
    }

    // MARK: - Status copy

    func testStatusLineCountsStepsAndRounds() {
        let plan = TextChain.make(kind: .roundTripEdited,
                                  inputs: inputs(everything))
        var progress = TextChain.Progress()
        XCTAssertEqual(plan.statusLine(progress),
                       "Step 1 of 3 — Listen and describe")
        progress.stageIndex = 1
        XCTAssertEqual(plan.statusLine(progress),
                       "Step 2 of 3 — Your turn to edit")

        var telephone = inputs(everything)
        telephone.rounds = 3
        let looped = TextChain.make(kind: .telephone, inputs: telephone)
        var round = TextChain.Progress()
        round.round = 1
        round.stageIndex = 2
        XCTAssertTrue(looped.statusLine(round).hasPrefix("Round 2 of 3 · "))
    }

    func testAFailureIsWhatTheStatusLineSays() {
        let plan = TextChain.make(kind: .roundTrip, inputs: inputs(everything))
        var progress = TextChain.Progress()
        progress.stageIndex = 1
        progress.failure = "out of memory"
        XCTAssertEqual(plan.statusLine(progress),
                       "Stopped at step 2: out of memory")
    }

    /// The edited text is what the next stage reads; without one, the
    /// model's own words are.
    func testEditedTextWinsOverTheModelsOwn() {
        var progress = TextChain.Progress()
        progress.text = "what it heard"
        XCTAssertEqual(progress.effectiveText, "what it heard")
        progress.editedText = "what I meant"
        XCTAssertEqual(progress.effectiveText, "what I meant")
    }
}

/// Which models may serve which music-to-text card.
///
/// The engine drops params a model does not declare (contract §5.1), so a
/// question sent to a model that cannot take one is not refused — it is
/// silently ignored, and the user gets a general description with no sign
/// their question went nowhere. Declaring the task is therefore not enough
/// for the Ask card; the param is the test.
final class TextActionEligibilityTests: XCTestCase {
    private var captioner: ModelInfo {
        ModelFixtures.model(id: "caption-lpmusiccaps", tasks: ["caption"],
                            paramKeys: ["source_audio", "num_beams"])
    }

    private var answerer: ModelInfo {
        ModelFixtures.model(id: "caption-qwen2audio",
                            tasks: ["caption", "tag"],
                            paramKeys: ["source_audio", "question",
                                        "max_tokens"])
    }

    func testDescribingOnlyNeedsTheTask() {
        XCTAssertTrue(TextAction.describe.canRun(captioner))
        XCTAssertTrue(TextAction.describe.canRun(answerer))
        XCTAssertTrue(TextAction.freeCaption.canRun(captioner))
    }

    func testAskingNeedsAModelThatTakesAQuestion() {
        XCTAssertFalse(TextAction.ask.canRun(captioner),
                       "a captioner with no question param would ignore it")
        XCTAssertTrue(TextAction.ask.canRun(answerer))
    }

    func testTheWrongTaskIsNeverEligible() {
        let tagger = ModelFixtures.model(id: "tag-clap", tasks: ["tag"],
                                         paramKeys: ["source_audio"])
        XCTAssertFalse(TextAction.describe.canRun(tagger))
        XCTAssertTrue(TextAction.tags.canRun(tagger))
    }

    /// The Models screen's action count must agree with the picker, or a
    /// model advertises a card that will not offer it.
    func testActionCountAgreesWithEligibility() {
        let ask = RecipeCatalog.all.first { recipe in
            if case .textAction(.ask) = recipe.engine { return true }
            return false
        }
        let card = try? XCTUnwrap(ask)
        XCTAssertFalse(ModelActions.enables(captioner, card!))
        XCTAssertTrue(ModelActions.enables(answerer, card!))
    }
}

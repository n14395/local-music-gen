import XCTest
@testable import LocalMusicGen

/// The pure half of the writing assistant: what comes back off the wire, what
/// the analysis digest says, and which models are allowed to serve which card.
///
/// These are the pieces worth pinning because they are the pieces that decide
/// what the user sees. The views around them are assembled from components
/// tested elsewhere; the decoding is where a small model's sloppiness meets
/// this app, and it has to be lenient in exactly the ways it claims.
final class AssistantTests: XCTestCase {

    // MARK: - Decoding an answer

    private func meta(kind: String, ok: Bool = true, raw: String = "",
                      value: [String: JSONValue]) -> [String: JSONValue] {
        ["assist": .object(["kind": .string(kind), "ok": .bool(ok),
                            "raw": .string(raw), "value": .object(value),
                            "repaired": .bool(false)])]
    }

    func testDecodesAPromptAnswer() {
        let result = AssistResult(meta: meta(
            kind: "flesh_out",
            value: ["prompt": .string("warm rhodes, brushed drums"),
                    "added": .array([.string("tape saturation")])]))
        XCTAssertEqual(result?.kind, .fleshOut)
        XCTAssertEqual(result?.prompt, "warm rhodes, brushed drums")
        XCTAssertEqual(result?.addedDetails, ["tape saturation"])
    }

    /// An answer the adapter could not parse still decodes, carrying the words.
    /// The page shows them as editable text rather than an error, which is the
    /// whole reason `raw` is on the wire.
    func testAFailedAnswerStillCarriesItsWords() {
        let result = AssistResult(meta: meta(
            kind: "brief", ok: false,
            raw: "How about a slow waltz played on a detuned piano?",
            value: [:]))
        XCTAssertEqual(result?.ok, false)
        XCTAssertTrue(result?.raw.contains("detuned piano") ?? false)
    }

    /// Nothing recognisable at all is a nil result, not an empty one — the
    /// store turns that into a message rather than an empty page.
    func testGarbageDecodesToNothing() {
        XCTAssertNil(AssistResult(meta: nil))
        XCTAssertNil(AssistResult(meta: ["assist": .string("not an object")]))
        XCTAssertNil(AssistResult(meta: meta(kind: "no_such_kind", value: [:])))
    }

    /// A language model writes `8` and `8.0` interchangeably. Both have to read
    /// as the same number of seconds, or a plan section renders blank on the
    /// half of the runs where it chose the other spelling.
    func testWholeDoublesReadAsInts() {
        let result = AssistResult(meta: meta(
            kind: "plan_song",
            value: ["sections": .array([
                .object(["tag": .string("[intro]"), "seconds": .double(8.0),
                         "what": .string("solo piano")]),
                .object(["tag": .string("[verse]"), "seconds": .int(24),
                         "what": .string("drums enter")]),
            ])]))
        XCTAssertEqual(result?.sections.map(\.seconds), [8, 24])
    }

    /// Rows missing the one field that identifies them are dropped, not
    /// rendered as blanks.
    func testMalformedRowsAreDroppedNotRendered() {
        let result = AssistResult(meta: meta(
            kind: "more_like_this",
            value: ["variations": .array([
                .object(["prompt": .string("dubbier, more space"),
                         "differs": .string("more reverb")]),
                .object(["differs": .string("no prompt at all")]),
                .string("not even an object"),
            ])]))
        XCTAssertEqual(result?.variations.count, 1)
        XCTAssertEqual(result?.variations.first?.prompt, "dubbier, more space")
    }

    /// An interview with no questions left is an interview that is finished,
    /// whether or not the model remembered to say so.
    ///
    /// `ok` is passed explicitly here because it is the point: the adapter used
    /// to score an empty `questions` list as a malformed answer (`ok: false`)
    /// even though its own prompt asks for exactly that when it knows enough,
    /// and this test only passed because the `meta` helper defaults `ok: true`.
    /// `Kind.may_be_empty` on the engine side is what makes the true case real.
    func testEmptyQuestionListMeansReady() {
        let explicit = AssistResult(meta: meta(
            kind: "interview", ok: true,
            value: ["questions": .array([.object([
                        "question": .string("What mood?"),
                        "examples": .array([.string("calm")])])]),
                    "ready": .bool(true)]))
        XCTAssertEqual(explicit?.interviewIsDone, true)
        XCTAssertEqual(explicit?.questions.first?.examples, ["calm"])

        let implicit = AssistResult(meta: meta(
            kind: "interview", ok: true, value: ["questions": .array([])]))
        XCTAssertEqual(implicit?.interviewIsDone, true)
        XCTAssertEqual(implicit?.ok, true)
    }

    /// The router may only send you somewhere that exists. A hallucinated id
    /// resolves to no recipe, and the page then says nothing fits rather than
    /// navigating somewhere arbitrary.
    func testRouteOnlyResolvesRealRecipes() {
        let real = AssistResult(meta: meta(
            kind: "route_intent",
            value: ["action": .string("karaoke"),
                    "confidence": .double(0.9),
                    "reason": .string("they asked for a backing track")]))
        XCTAssertEqual(real?.route?.recipe?.id, "karaoke")

        let invented = AssistResult(meta: meta(
            kind: "route_intent",
            value: ["action": .string("make-it-sound-better"),
                    "reason": .string("")]))
        XCTAssertNotNil(invented?.route)
        XCTAssertNil(invented?.route?.recipe)
    }

    // MARK: - Eligibility

    private func model(id: String, tasks: [String],
                       params: [String] = []) -> ModelInfo {
        ModelFixtures.model(id: id, tasks: tasks, paramKeys: params)
    }

    /// Shape, never ids: a model qualifies by declaring the task.
    func testAssistantEligibilityIsTaskShaped() {
        let assistant = model(id: "anything-at-all", tasks: ["assist"])
        let musicgen = model(id: "musicgen-small", tasks: ["generate"])
        XCTAssertTrue(AssistantModels.canAssist(assistant))
        XCTAssertFalse(AssistantModels.canAssist(musicgen))
    }

    func testPlanEligibilityIsTaskShaped() {
        let planner = model(id: "acestep-base", tasks: ["generate", "plan"])
        let plain = model(id: "musicgen-small", tasks: ["generate"])
        XCTAssertTrue(PlanModels.canPlan(planner))
        XCTAssertFalse(PlanModels.canPlan(plain))
    }

    /// Being able to *write* a plan and being able to be *told* one are
    /// different capabilities, and the reroll card needs the second.
    func testAcceptingAPlanIsASeparateQuestion() {
        let both = model(id: "acestep-base", tasks: ["generate", "plan"],
                         params: ["audio_codes"])
        let writesOnly = model(id: "planner-only", tasks: ["generate", "plan"])
        XCTAssertTrue(PlanModels.acceptsPlan(both))
        XCTAssertFalse(PlanModels.acceptsPlan(writesOnly))
    }

    /// The Settings choice wins while it is installed, and quietly stops
    /// winning when it is not — rather than leaving the cards with nothing.
    func testPreferredAssistantFallsBackWhenUninstalled() {
        let chosen = ModelFixtures.model(id: "assistant-llama-1b",
                                         tasks: ["assist"], installed: false)
        let other = model(id: "assistant-qwen", tasks: ["assist"])
        let picked = AssistantModels.choose([other, chosen],
                                            preferring: "assistant-llama-1b")
        XCTAssertEqual(picked?.id, "assistant-qwen")
    }

    // MARK: - The plan itself

    func testPlanReadsTheFactsItWasGiven() {
        let plan = SongPlan(index: 0, metadata: [
            "bpm": .int(92), "keyscale": .string("F minor"),
            "timesignature": .string("3"), "duration": .int(184),
            "caption": .string("slow soul"),
        ], codes: "<|audio_code_1|>")
        XCTAssertTrue(plan.isRenderable)
        XCTAssertTrue(plan.summary.contains("92 BPM"))
        XCTAssertTrue(plan.summary.contains("F minor"))
        // A bare numerator is not a time signature anyone recognises.
        XCTAssertTrue(plan.facts.contains { $0.value == "3/4 (waltz)" })
    }

    /// A plan with no codes is readable but not re-renderable, and must say so
    /// — offering "render this one" would render something else.
    func testAPlanWithoutCodesIsNotRenderable() {
        let plan = SongPlan(index: 0, metadata: ["bpm": .int(120)], codes: "")
        XCTAssertFalse(plan.isRenderable)
        XCTAssertEqual(plan.facts.count, 1)
    }

    /// A model with no planning stage reports nothing, and that has to stay
    /// distinguishable from a plan full of blanks.
    func testNoPlanIsNilRatherThanEmpty() {
        XCTAssertNil(SongPlan.of(meta: nil))
        XCTAssertNil(SongPlan.of(meta: ["timings": .object([:])]))
        XCTAssertNotNil(SongPlan.of(meta: [
            "lm_metadata": .object(["bpm": .int(100)]),
            "audio_codes": .string("<|audio_code_2|>")]))
    }

    func testPlansDecodeFromATaskResult() {
        let plans = SongPlan.all(meta: ["plans": .array([
            .object(["index": .int(0),
                     "metadata": .object(["bpm": .int(120)]),
                     "audio_codes": .string("<|audio_code_1|>")]),
            .object(["index": .int(1),
                     "metadata": .object(["bpm": .int(75)]),
                     "audio_codes": .string("<|audio_code_9|>")]),
        ])])
        XCTAssertEqual(plans.count, 2)
        XCTAssertEqual(plans.map(\.bpm), [120, 75])
    }

    // MARK: - Analysis, in words

    /// The digest exists because a 1.5B model cannot act on "band 5 is 0.11".
    /// What it must never do is state a fact that was not measured.
    func testDigestOnlySaysWhatWasMeasured() {
        let sparse = AnalysisPayload(tempoBpm: 128, beats: nil, downbeats: nil,
                                     key: nil, camelot: nil, keyConfidence: nil,
                                     sections: nil, lufs: nil, chroma: nil,
                                     bandEnergy: nil, clap: nil,
                                     durationS: nil, sampleRate: nil)
        let text = SongDigest.text(payload: sparse, title: "Test")
        XCTAssertTrue(text.contains("Tempo:"))
        XCTAssertFalse(text.contains("Key:"))
        XCTAssertFalse(text.contains("Balance:"))
    }

    func testNothingMeasuredIsAnEmptyDigest() {
        XCTAssertTrue(SongDigest.text(payload: nil).isEmpty)
    }

    /// What a listening model wrote joins the digest — one description, the
    /// tags — and its absence leaves the digest exactly as it was.
    func testDigestQuotesAListenerAndTags() {
        let digest = SongDigest.text(
            payload: nil, title: "Nocturne",
            descriptions: ["dusty rhodes over swung drums",
                           "a second opinion, ignored"],
            tags: ["lo-fi", "hazy"])
        XCTAssertTrue(digest.contains(
            "A model that listened to it wrote: dusty rhodes over swung drums"))
        XCTAssertFalse(digest.contains("second opinion"))
        XCTAssertTrue(digest.contains("Tags: lo-fi, hazy"))

        let bare = SongDigest.text(payload: nil, title: "Nocturne")
        XCTAssertFalse(bare.contains("listened"))
        XCTAssertFalse(bare.contains("Tags:"))
    }

    /// Tempo words, so the model has something to reason with, and the number,
    /// so the next generation can be pinned to it.
    func testTempoIsBothAWordAndANumber() {
        XCTAssertTrue(SongDigest.tempo(60).contains("very slow"))
        XCTAssertTrue(SongDigest.tempo(124).contains("danceable"))
        XCTAssertTrue(SongDigest.tempo(124).contains("124"))
        XCTAssertTrue(SongDigest.tempo(190).contains("very fast"))
    }

    /// A nearly-even mix is "even". Naming whichever third won by a point
    /// would be a fact the listener would disagree with.
    func testBalanceCallsAnEvenMixEven() {
        let even = Array(repeating: 0.125, count: 8)
        XCTAssertTrue(SongDigest.balance(even).contains("even"))
        let bassy = [0.4, 0.3, 0.1, 0.06, 0.05, 0.04, 0.03, 0.02]
        XCTAssertTrue(SongDigest.balance(bassy).contains("bass"))
        let bright = [0.02, 0.03, 0.04, 0.05, 0.06, 0.1, 0.3, 0.4]
        XCTAssertTrue(SongDigest.balance(bright).contains("bright"))
    }

    /// Section letters read out as a form description, which is what the model
    /// actually reasons over.
    func testStructureReadsAsAShape() {
        let sections = ["A", "B", "A", "B", "C"].map {
            AnalysisPayload.Section(startS: 0, endS: 1, group: $0, label: nil)
        }
        let text = SongDigest.structure(sections)
        XCTAssertTrue(text.contains("A B A B C"))
        XCTAssertTrue(text.contains("3 distinct"))
    }

    func testLengthReadsInMinutes() {
        XCTAssertEqual(SongDigest.length(45), "45 seconds")
        XCTAssertEqual(SongDigest.length(120), "2 minutes")
        XCTAssertEqual(SongDigest.length(154), "2 min 34 sec")
    }
}

// MARK: - The sixteen cards

/// The cards themselves: that they exist, that they are reachable, and that
/// each one's model requirement matches the task it will actually submit.
final class AssistantCardTests: XCTestCase {

    private var assistCards: [Recipe] {
        RecipeCatalog.all.filter {
            if case .assistant = $0.engine { return true }
            return false
        }
    }

    private var planCards: [Recipe] {
        RecipeCatalog.all.filter {
            if case .songPlan = $0.engine { return true }
            return false
        }
    }

    func testAllTenCardsExist() {
        XCTAssertEqual(assistCards.count, 9)
        XCTAssertEqual(planCards.count, 1)
    }

    func testEveryNewCardIsAvailable() {
        for recipe in assistCards + planCards {
            XCTAssertTrue(recipe.isAvailable,
                          "\(recipe.id) is shown as coming soon")
        }
    }

    /// Ids are wire values — they travel into `actions.lastRuns` and, for the
    /// plan cards, into the provenance of what they render. This is the list;
    /// changing one orphans what is already recorded under it.
    func testCardIdsAreStable() {
        // Shrunk on purpose (2026-09-03): flesh-out folded into interview,
        // critique into more-like, describe cut for the Words shelf's
        // listening card, and three plan cards into plan-choose's page.
        // The removed ids stay retired — never reused for a new card.
        XCTAssertEqual(assistCards.map(\.id).sorted(), [
            "assist-brief", "assist-interview", "assist-lyrics",
            "assist-more-like", "assist-name", "assist-pick-model",
            "assist-plan-song", "assist-route", "assist-translate",
        ])
        XCTAssertEqual(planCards.map(\.id).sorted(), ["plan-choose"])
    }

    /// The whole shelf produces words, never audio. Badging any of it
    /// `GENERATE` would promise a render that never arrives.
    func testTheAssistShelfIsBadgedAsWriting() {
        for recipe in assistCards {
            XCTAssertEqual(recipe.mode, .write, recipe.id)
            XCTAssertEqual(recipe.category, .assist, recipe.id)
        }
    }

    /// Generate stays the first shelf; the assistant sits second, where you go
    /// when you cannot fill the first one in.
    func testShelfOrder() {
        XCTAssertEqual(RecipeCategory.allCases.first, .generate)
        XCTAssertEqual(RecipeCategory.allCases.dropFirst().first, .assist)
    }

    /// Only the source-reading cards ask for a track. The others would be
    /// asking for something they never look at.
    func testOnlyTheSourceReadingCardsHaveASlot() {
        let withSlots = assistCards.filter { !$0.slots.isEmpty }.map(\.id)
        XCTAssertEqual(withSlots.sorted(),
                       ["assist-more-like", "assist-name"])
    }

    /// `needsSource` and having a slot are two statements of one fact, and a
    /// card where they disagree either asks for audio it ignores or reads
    /// audio it never asked for.
    func testNeedsSourceAgreesWithTheSlots() {
        for recipe in assistCards {
            guard case .assistant(_, let needsSource) = recipe.engine else {
                return XCTFail("\(recipe.id) is not an assistant card")
            }
            XCTAssertEqual(needsSource, !recipe.slots.isEmpty, recipe.id)
        }
    }

    /// A model earns these cards by declaring the task, so the badge count on
    /// the Models screen moves with the catalog rather than with a list here.
    func testAssistantModelUnlocksExactlyTheAssistCards() {
        let assistant = ModelFixtures.model(id: "assistant-qwen",
                                            tasks: ["assist"])
        let unlocked = RecipeCatalog.all.filter {
            ModelActions.enables(assistant, $0)
        }
        XCTAssertEqual(unlocked.map(\.id).sorted(),
                       assistCards.map(\.id).sorted())
    }

    func testPlannerUnlocksThePlanCardsAndTheGenerateOnes() {
        let planner = ModelFixtures.model(
            id: "acestep-base", tasks: ["generate", "plan"],
            paramKeys: ["audio_codes"])
        let unlocked = Set(RecipeCatalog.all
            .filter { ModelActions.enables(planner, $0) }.map(\.id))
        for id in planCards.map(\.id) {
            XCTAssertTrue(unlocked.contains(id), "\(id) not unlocked")
        }
        // And none of the writing cards: it cannot write.
        for id in assistCards.map(\.id) {
            XCTAssertFalse(unlocked.contains(id), "\(id) wrongly unlocked")
        }
    }
}

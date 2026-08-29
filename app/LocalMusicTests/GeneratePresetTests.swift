import XCTest
@testable import LocalMusic

/// The Generate shelf: what its cards need, which model they land on, and the
/// two tables that have to stay in step.
final class GeneratePresetTests: XCTestCase {

    private func model(_ id: String, family: String = "musicgen",
                       lyrics: Bool = false, minS: Double = 1,
                       maxS: Double = 30,
                       state: InstallState = .installed) -> ModelInfo {
        ModelInfo(
            id: id, family: family, displayName: id, description: "",
            hfRepos: [], sizeBytes: 1, installState: state,
            installedBytes: 0, runtimeState: nil,
            capabilities: Capabilities(
                supportsLyrics: lyrics, instrumentalOnly: !lyrics,
                duration: DurationSpec(minS: minS, maxS: maxS,
                                       defaultS: minS),
                sampleRate: 44100, outputsPerJobMax: 4,
                estSecondsPerAudioSecond: 1, params: []),
            requirements: Requirements(minRamBytes: 1, diskBytes: 0,
                                       speedTier: .fast),
            license: LicenseInfo(name: "MIT", commercialUse: true,
                                 requiresHfToken: false, url: nil))
    }

    // MARK: needs

    func testALyricsCardWillNotRunOnAModelThatCannotSing() {
        let need = GenerateNeed(lyrics: true)
        XCTAssertFalse(need.canRun(model("musicgen")))
        XCTAssertTrue(need.canRun(model("acestep", lyrics: true,
                                        minS: 10, maxS: 300)))
    }

    /// A card offering a two-minute backing track cannot run on a model that
    /// stops at thirty seconds, and one offering a two-second one-shot cannot
    /// run on a model that starts at ten.
    func testLengthIsAGateInBothDirections() {
        let long = GenerateNeed(reaches: 120)
        XCTAssertFalse(long.canRun(model("musicgen", maxS: 30)))
        XCTAssertTrue(long.canRun(model("acestep", minS: 10, maxS: 300)))

        let short = GenerateNeed(goesAsShortAs: 4)
        XCTAssertTrue(short.canRun(model("stable", minS: 1, maxS: 11)))
        XCTAssertFalse(short.canRun(model("acestep", minS: 10, maxS: 300)))
    }

    func testAModelThatIsNotInstalledIsNotEligible() {
        let need = GenerateNeed()
        XCTAssertTrue(need.eligible([model("a")]).count == 1)
        XCTAssertTrue(need.eligible([model("a", state: .notInstalled)]).isEmpty)
    }

    /// Preference decides which model a card *arrives* on. It must never
    /// decide whether the card runs — a prompt asking for a door slam works on
    /// any of them, it just works better on one.
    func testPreferenceChoosesTheModelButNeverGatesTheCard() {
        let need = GenerateNeed(goesAsShortAs: 10,
                                prefers: ["diffusers", "stableaudio"])
        let installed = [model("musicgen", family: "musicgen"),
                         model("audioldm", family: "diffusers")]
        XCTAssertEqual(need.best(installed)?.id, "audioldm")
        // Preference unavailable: still runs, on whatever is left.
        XCTAssertEqual(need.best([model("musicgen", family: "musicgen")])?.id,
                       "musicgen")
        XCTAssertNil(need.best([]))
    }

    func testPreferenceIsOrdered() {
        let need = GenerateNeed(prefers: ["stableaudio", "musicgen"])
        let installed = [model("mg", family: "musicgen"),
                         model("sa", family: "stableaudio")]
        XCTAssertEqual(need.best(installed)?.id, "sa")
    }

    // MARK: the two tables

    /// `RecipeCatalog` force-unwraps its preset lookup, so a card whose preset
    /// is missing is a crash on first launch rather than a silent no-op. This
    /// is the test that fails first instead.
    func testEveryGenerateCardHasItsPreset() {
        for recipe in RecipeCatalog.all
        where recipe.category == .generate && recipe.id != "gen-compare-models"
            && !recipe.isPlanCard {
            guard case .generate(let preset) = recipe.engine else {
                XCTFail("\(recipe.id) is on the Generate shelf with a "
                        + "\(recipe.engine) engine")
                continue
            }
            XCTAssertEqual(preset.id, recipe.id,
                           "a card and its preset must share an id")
        }
    }

    func testEveryPresetHasItsCard() {
        for preset in GeneratePreset.all {
            XCTAssertNotNil(RecipeCatalog.recipe(id: preset.id),
                            "\(preset.id) is a preset no card opens")
        }
    }

    /// Ids are wire values — they land in provenance and in
    /// `actions.lastRuns` — so a duplicate would have two cards writing over
    /// each other's history.
    func testRecipeIdsAreUnique() {
        let ids = RecipeCatalog.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    /// The shelf's whole premise: these start from a sentence. A slot would be
    /// a source picker with nothing to pick.
    ///
    /// Stated against the preset rather than against a list of ids. It used to
    /// name `gen-fit-track` as the sole exception, which was true until
    /// `gen-my-voice` arrived — a card that generates a *new* song from words
    /// and takes the picked track as a voice reference, so it belongs on this
    /// shelf and genuinely uses what it asks for. An id list cannot tell those
    /// two cases apart; "does the preset consume a source" can, and cannot
    /// drift the way the list did.
    ///
    /// The plan cards are the exception the premise allows for: two of them
    /// read a *finished* take to show (or re-render) the plan behind it, which
    /// is material they genuinely use.
    func testGenerateCardsCarryNoSourceTheyCannotUse() {
        var examined = 0
        for recipe in RecipeCatalog.all
        where recipe.category == .generate && !recipe.isPlanCard {
            examined += 1
            // A card with no preset behind it — `gen-compare-models` runs its
            // own engine — has nothing that could read a source at all.
            guard case .generate(let preset) = recipe.engine else {
                XCTAssertTrue(recipe.slots.isEmpty,
                              "\(recipe.id) has no preset to read a source "
                              + "with, so it must not ask for one")
                continue
            }
            if preset.readsSource {
                XCTAssertEqual(recipe.slots.count, 1,
                               "\(recipe.id) reads a source, so it needs "
                               + "exactly one slot to pick it with")
            } else {
                XCTAssertTrue(recipe.slots.isEmpty,
                              "\(recipe.id) asks for material it cannot use")
            }
        }
        // A `where` clause that stopped matching would leave every assertion
        // above unrun and the test still green.
        XCTAssertEqual(examined, 15, "the Generate shelf changed size")
    }

    /// …and the converse, so a slot cannot be added to a card that would
    /// silently ignore what was picked.
    func testEveryGenerateSlotIsReadByItsPreset() {
        for recipe in RecipeCatalog.all
        where recipe.category == .generate && !recipe.isPlanCard
            && !recipe.slots.isEmpty {
            guard case .generate(let preset) = recipe.engine else {
                return XCTFail("\(recipe.id) opens a picker with no preset "
                               + "to hand the result to")
            }
            XCTAssertTrue(preset.readsSource,
                          "\(recipe.id) opens a picker and then drops the "
                          + "track that was picked")
        }
    }

    /// The plan cards that read a take read a whole song, never a stem: a
    /// plan belongs to the take it rendered, and a stem cut out of one
    /// afterwards has none of its own.
    func testPlanCardsThatReadATakeTakeOnlySongs() {
        for recipe in RecipeCatalog.all where recipe.isPlanCard {
            for slot in recipe.slots {
                XCTAssertEqual(slot.accepts,
                               [KindPattern(pattern: "song.mix")], recipe.id)
            }
        }
    }

    /// Only the fit card reads a track's *measurements* — its tempo and key,
    /// written into the prompt as words, with none of its audio used.
    ///
    /// This is what the assertion was always about. It was written against
    /// `readsSource`, which at the time meant only this; the audio doors then
    /// set the same flag to get themselves a picker, and the two meanings
    /// collapsed into one. They are separate properties now, and this pins
    /// the one it meant.
    func testOnlyTheFitCardReadsItsSourcesMeasurements() {
        let measuring = GeneratePreset.all.filter(\.readsMeasurements).map(\.id)
        XCTAssertEqual(measuring, ["gen-fit-track"])
    }

    /// A picker opens for the fit card and for every door that feeds the
    /// picked track into a model param — and for nothing else.
    func testTheCardsThatOpenAPickerAreTheOnesThatUseWhatIsPicked() {
        let picking = Set(GeneratePreset.all.filter(\.readsSource).map(\.id))
        XCTAssertEqual(picking, ["gen-fit-track", "gen-my-voice",
                                 "vocals2music", "edit-with-words",
                                 "vamp-loop", "style-morph"])
    }

    /// The implication `sourceParamKey` has always claimed, now that it is the
    /// type's job rather than five hand-written copies of it.
    func testFeedingAParamImpliesAPicker() {
        for preset in GeneratePreset.all where preset.sourceParamKey != nil {
            XCTAssertTrue(preset.readsSource, preset.id)
        }
    }

    /// The shelf is first in the gallery, because it is the only one that
    /// needs nothing to start from.
    func testGenerateIsTheFirstShelf() {
        XCTAssertEqual(RecipeCategory.allCases.first, .generate)
    }

    /// A prompt the user did not write is a prompt they will not read. Seeds
    /// start the sentence; they must not finish it.
    func testPromptSeedsStayShort() {
        for preset in GeneratePreset.all {
            XCTAssertLessThan(preset.promptSeed.count, 45, preset.id)
        }
    }

    // MARK: requirement plumbing

    /// A gated card routes to Models carrying what would ungate it, and the
    /// filter there has to narrow to models that actually would.
    func testTheRequirementFiltersToModelsThatCouldRunTheCard() {
        let need = GenerateNeed(lyrics: true, reaches: 120)
        let requirement = ModelRequirement.generate(need)
        let candidates = requirement.candidates([
            model("musicgen"),
            model("acestep", lyrics: true, minS: 10, maxS: 300),
        ])
        XCTAssertEqual(candidates.map(\.id), ["acestep"])
        XCTAssertEqual(requirement.id, "generate:lyrics-min120")
    }
}

/// The transform shelf: one track, one operation, no model.
final class TrackTransformTests: XCTestCase {

    /// The failure this guards is silent and expensive. `RecombineOptions`
    /// defaults auto-match *on*, which is right for a mashup and wrong for
    /// every card here: "Reverse it" would quietly stretch a track to a tempo
    /// nobody mentioned, and the only evidence would be that it came back the
    /// wrong length.
    func testNoTransformMatchesTempoOrKeyByAccident() {
        for transform in TrackTransform.allCases where transform != .conform {
            let options = transform.options(value: 1)
            XCTAssertFalse(options.autoMatchTempo, "\(transform)")
            XCTAssertFalse(options.autoMatchKey, "\(transform)")
        }
    }

    /// Conforming is the one that is *supposed* to match a grid — it is the
    /// whole card.
    func testConformingMatchesBoth() {
        let options = TrackTransform.conform.options(value: 0)
        XCTAssertTrue(options.autoMatchTempo)
        XCTAssertTrue(options.autoMatchKey)
    }

    func testEachTransformWritesOnlyItsOwnField() {
        XCTAssertTrue(TrackTransform.reverse.options(value: 0).reverse)
        XCTAssertEqual(TrackTransform.speed.options(value: 1.5).speedRate, 1.5)
        XCTAssertEqual(TrackTransform.key.options(value: -3).pitchShiftSt, -3)
        let fades = TrackTransform.fades.options(value: 2)
        XCTAssertEqual(fades.fadeInS, 2)
        XCTAssertEqual(fades.fadeOutS, 2)
        // Reverse must not arrive as a side effect of asking for a fade.
        XCTAssertFalse(fades.reverse)
        XCTAssertEqual(fades.speedRate, 1)
    }

    /// Rumble out, silence down, peaks in — and in that order, because the
    /// engine applies the chain in the order it is given.
    func testCleanUpIsAnOrderedChain() {
        let effects = TrackTransform.cleanUp.options(value: 0).effects
        XCTAssertEqual(effects.map(\.type),
                       ["highpass", "gate", "compressor"])
        XCTAssertEqual(effects[0].cutoffHz, 80)
        XCTAssertNotNil(effects[1].thresholdDb)
        XCTAssertNotNil(effects[2].ratio)
    }

    /// Only the two grid-aware cards may claim to need analysis; gating the
    /// others on it would make them unusable on anything unanalysed.
    func testOnlyTheGridAwareCardsNeedAnalysis() {
        let needing = TrackTransform.allCases.filter(\.needsAnalysis)
        XCTAssertEqual(Set(needing), [.loop, .conform])
        XCTAssertEqual(TrackTransform.allCases.filter(\.needsReference),
                       [.conform])
    }

    /// A control with no bounds is a control the page cannot draw, and a
    /// bounded one whose initial value sits outside its range is a slider
    /// that jumps the first time it is touched.
    func testEveryControlIsCoherent() {
        for transform in TrackTransform.allCases {
            guard let bounds = transform.bounds else {
                XCTAssertNil(transform.controlTitle, "\(transform)")
                continue
            }
            XCTAssertNotNil(transform.controlTitle, "\(transform)")
            XCTAssertTrue(bounds.range.contains(bounds.initial), "\(transform)")
            XCTAssertGreaterThan(bounds.step, 0, "\(transform)")
        }
    }

    /// Speed and key open on "unchanged", so a card opened and committed
    /// without touching anything is a no-op rather than a surprise.
    func testSpeedAndKeyOpenNeutral() {
        XCTAssertEqual(TrackTransform.speed.bounds?.initial, 1)
        XCTAssertEqual(TrackTransform.key.bounds?.initial, 0)
    }

    /// Every transform card reaches a page, and every transform has a card.
    func testTransformsAndCardsAreInStep() {
        var seen: Set<TrackTransform> = []
        for recipe in RecipeCatalog.all {
            if case .transform(let transform) = recipe.engine {
                XCTAssertFalse(seen.contains(transform),
                               "two cards run \(transform)")
                seen.insert(transform)
                XCTAssertFalse(recipe.slots.isEmpty,
                               "\(recipe.id) transforms nothing")
                if transform.needsReference {
                    XCTAssertEqual(recipe.slots.count, 2, recipe.id)
                }
            }
        }
        XCTAssertEqual(seen, Set(TrackTransform.allCases))
    }

    /// The specialists exist and are preferred by name. A typo here is a card
    /// that silently opens on the general transcriber — which works, and is
    /// wrong, and says nothing.
    ///
    /// Pinned rather than derived because the catalog is not visible from the
    /// app's tests; `scripts/verify_engine.py` cross-checks the same ids
    /// against `models.json`, which is where a typo can actually be caught.
    /// The three music-to-text ids are named here before their catalog
    /// entries ship — a card whose favourite is not installed opens on
    /// whatever else can do the job, which is the documented behaviour.
    func testTheSpecialistCardsNameRealModels() {
        let preferred = RecipeCatalog.all.flatMap(\.prefersModelIds)
        XCTAssertEqual(Set(preferred),
                       ["analysis-chords-btc",
                        "analysis-squim",
                        "caption-lpmusiccaps",
                        "cleanup-uvr-deecho-dereverb",
                        "cleanup-uvr-denoise",
                        "compose-anticipation",
                        "compose-anticipation-medium",
                        "lyrics-whisper-turbo",
                        "separation-uvr-karaoke",
                        "tag-clap",
                        "tag-essentia-discogs",
                        "transcribe-basicpitch",
                        "transcribe-bytedance-piano",
                        "transcribe-swiftf0",
                        "transcribe-transkun"])
    }
}

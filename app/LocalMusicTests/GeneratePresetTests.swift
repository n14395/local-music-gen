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
        where recipe.category == .generate && recipe.id != "gen-compare-models" {
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
    func testGenerateCardsCarryNoSourceExceptTheOneThatMeasuresOne() {
        for recipe in RecipeCatalog.all where recipe.category == .generate {
            if recipe.id == "gen-fit-track" {
                XCTAssertEqual(recipe.slots.count, 1)
            } else {
                XCTAssertTrue(recipe.slots.isEmpty,
                              "\(recipe.id) asks for material it cannot use")
            }
        }
    }

    /// Only the card that says it reads a track may open a picker.
    func testOnlyTheFitCardReadsItsSource() {
        let reading = GeneratePreset.all.filter(\.readsSource).map(\.id)
        XCTAssertEqual(reading, ["gen-fit-track"])
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

import XCTest
@testable import LocalMusic

/// How the Models screen arranges 64 catalog entries into two sections and a
/// disclosure.
///
/// The rules are all "don't lose a row" rules, which is exactly the kind that
/// looks fine until the one model you were downloading is the one that got
/// dropped — so they are pinned here rather than trusted to inspection.
final class ModelListLayoutTests: XCTestCase {

    private func model(_ id: String, variantOf: String? = nil,
                       installState: String = "not_installed",
                       format: String? = nil,
                       tasks: [String] = ["generate"],
                       params: [String] = []) -> ModelInfo {
        let variantJSON = variantOf.map { "\"variant_of\": \"\($0)\"," } ?? ""
        let formatJSON = format.map { "\"format\": \"\($0)\"," } ?? ""
        let taskList = tasks.map { "\"\($0)\"" }.joined(separator: ", ")
        let paramList = params.map {
            """
            {"key": "\($0)", "type": "json", "label": "\($0)",
             "default": null, "nullable": false, "internal": true}
            """
        }.joined(separator: ", ")
        let json = """
        {
          "id": "\(id)", "family": "test", \(variantJSON)\(formatJSON)
          "display_name": "\(id)", "description": "", "hf_repos": [],
          "size_bytes": 0, "install_state": "\(installState)",
          "installed_bytes": 0,
          "capabilities": {
            "supports_lyrics": false, "instrumental_only": true,
            "duration": {"min_s": 1, "max_s": 30, "default_s": 10},
            "sample_rate": 44100, "outputs_per_job_max": 1,
            "est_seconds_per_audio_second": 1,
            "tasks": [\(taskList)],
            "params": [\(paramList)]
          },
          "requirements": {"min_ram_bytes": 0, "disk_bytes": 0,
                            "speed_tier": "fast"},
          "license": {"name": "MIT", "commercial_use": true,
                       "requires_hf_token": false, "url": null},
          "notes": null
        }
        """
        // swiftlint:disable:next force_try — fixture is a compile-time constant
        return try! BackendClient.decoder.decode(ModelInfo.self, from: Data(json.utf8))
    }

    private func ids(_ rows: [ModelListRow]) -> [String] { rows.map(\.model.id) }

    // MARK: nesting

    func testVariantsNestUnderTheirBase() {
        let models = [model("base"), model("q4", variantOf: "base", format: "gguf")]
        let plan = ModelListLayout.plan(models: models,
                                        matching: ["base", "q4"],
                                        recommended: ["base"], expanded: true)
        XCTAssertEqual(ids(plan.recommended), ["base", "q4"])
        XCTAssertTrue(plan.recommended[1].isVariant)
        XCTAssertFalse(plan.recommended[0].isVariant)
    }

    /// Nesting a variant under an id nobody has would make it unreachable —
    /// no header would ever be drawn to hang it from.
    func testVariantWithAMissingBaseBecomesItsOwnBase() {
        let plan = ModelListLayout.plan(models: [model("q4", variantOf: "ghost")],
                                        matching: ["q4"], recommended: [],
                                        expanded: true)
        XCTAssertEqual(ids(plan.other), ["q4"])
        XCTAssertFalse(plan.other[0].isVariant)
    }

    /// When only a variant matches the filter, its base still draws as the
    /// group's header — otherwise the match is orphaned.
    func testBaseSurvivesWhenOnlyAVariantMatches() {
        let models = [model("base"), model("q4", variantOf: "base")]
        let plan = ModelListLayout.plan(models: models, matching: ["q4"],
                                        recommended: ["base"], expanded: true)
        XCTAssertEqual(ids(plan.recommended), ["base", "q4"])
    }

    func testGroupDisappearsWhenNothingInItMatches() {
        let models = [model("base"), model("q4", variantOf: "base")]
        let plan = ModelListLayout.plan(models: models, matching: [],
                                        recommended: ["base"], expanded: true)
        XCTAssertTrue(plan.recommended.isEmpty)
        XCTAssertTrue(plan.other.isEmpty)
    }

    // MARK: the disclosure

    /// Collapsed, a recommended group shows only the variants you already
    /// have — otherwise every quantisation of a family is on screen before you
    /// have asked for any of them.
    func testCollapsedGroupShowsOnlyOwnedVariants() {
        let models = [model("base"),
                      model("q4", variantOf: "base", installState: "installed"),
                      model("q8", variantOf: "base")]
        let plan = ModelListLayout.plan(models: models,
                                        matching: ["base", "q4", "q8"],
                                        recommended: ["base"], expanded: false)
        XCTAssertEqual(ids(plan.recommended), ["base", "q4"])
    }

    func testExpandedGroupShowsEveryVariant() {
        let models = [model("base"),
                      model("q4", variantOf: "base", installState: "installed"),
                      model("q8", variantOf: "base")]
        let plan = ModelListLayout.plan(models: models,
                                        matching: ["base", "q4", "q8"],
                                        recommended: ["base"], expanded: true)
        XCTAssertEqual(ids(plan.recommended), ["base", "q4", "q8"])
    }

    /// The `EVERYTHING ELSE · N` figure counts what the disclosure controls,
    /// which includes the un-installed variants tucked under a recommended
    /// base — not just the rows in `other`.
    func testHiddenCountIncludesCollapsedVariants() {
        let models = [model("base"),
                      model("q4", variantOf: "base", installState: "installed"),
                      model("q8", variantOf: "base"),
                      model("loner")]
        let plan = ModelListLayout.plan(models: models,
                                        matching: ["base", "q4", "q8", "loner"],
                                        recommended: ["base"], expanded: false)
        // Collapsed shows base + q4. Expanded would add q8 and loner.
        XCTAssertEqual(plan.hidden, 2)
    }

    func testNoRowIsLostBetweenTheTwoSections() {
        let models = [model("a"), model("b"), model("c", variantOf: "a")]
        let plan = ModelListLayout.plan(models: models,
                                        matching: ["a", "b", "c"],
                                        recommended: ["a"], expanded: true)
        let all = ids(plan.recommended) + ids(plan.other)
        XCTAssertEqual(all.sorted(), ["a", "b", "c"])
        XCTAssertEqual(all.count, Set(all).count, "a model appeared twice")
    }
}

/// How many of the app's actions a model unlocks — the `14 ACTIONS` badge.
final class ModelActionsTests: XCTestCase {

    private func model(_ id: String, tasks: [String],
                       paramKeys: [String] = []) -> ModelInfo {
        let taskList = tasks.map { "\"\($0)\"" }.joined(separator: ", ")
        let paramList = paramKeys.map {
            """
            {"key": "\($0)", "type": "json", "label": "\($0)",
             "default": null, "nullable": false, "internal": true}
            """
        }.joined(separator: ", ")
        let json = """
        {
          "id": "\(id)", "family": "test", "display_name": "\(id)",
          "description": "", "hf_repos": [], "size_bytes": 0,
          "install_state": "installed", "installed_bytes": 0,
          "capabilities": {
            "supports_lyrics": false, "instrumental_only": true,
            "duration": {"min_s": 1, "max_s": 30, "default_s": 10},
            "sample_rate": 44100, "outputs_per_job_max": 1,
            "est_seconds_per_audio_second": 1,
            "tasks": [\(taskList)], "params": [\(paramList)]
          },
          "requirements": {"min_ram_bytes": 0, "disk_bytes": 0,
                            "speed_tier": "fast"},
          "license": {"name": "MIT", "commercial_use": true,
                       "requires_hf_token": false, "url": null},
          "notes": null
        }
        """
        // swiftlint:disable:next force_try — fixture is a compile-time constant
        return try! BackendClient.decoder.decode(ModelInfo.self, from: Data(json.utf8))
    }

    func testAModelThatCanDoNothingCountsZero() {
        XCTAssertEqual(ModelActions.count(for: model("dud", tasks: [])), 0)
    }

    /// The same predicate `MixModels` uses: declaring task "mix" is not enough,
    /// because Token Splice declares it too and consumes a different spec.
    func testMixdownRecipesNeedTheMixSpecParamNotJustTheTask() {
        let splicer = model("splice", tasks: ["mix"], paramKeys: ["splice_spec"])
        let mixer = model("mixer", tasks: ["mix"], paramKeys: ["mix_spec"])
        XCTAssertGreaterThan(ModelActions.count(for: mixer),
                             ModelActions.count(for: splicer),
                             "a splicer must not claim the mixdown recipes")
    }

    func testASeparatorUnlocksTheSeparationRecipes() {
        let separator = model("demucs", tasks: ["separate"])
        XCTAssertGreaterThan(ModelActions.count(for: separator), 0)
    }

    /// The count is over the recipes actually shipped, so it can never exceed
    /// them — a badge reading more actions than the gallery has would be
    /// nonsense.
    func testCountNeverExceedsTheCatalog() {
        let everything = model("all", tasks: ["generate", "mix", "separate",
                                              "transcribe", "analyze", "render"],
                               paramKeys: ["mix_spec", "splice_spec"])
        XCTAssertLessThanOrEqual(ModelActions.count(for: everything),
                                 RecipeCatalog.all.count)
    }
}

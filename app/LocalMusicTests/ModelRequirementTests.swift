import XCTest
@testable import LocalMusic

/// A gated feature routes to Models carrying the predicate that dimmed it.
/// These pin that the predicate is the *same* one — a list that showed a model
/// which would not ungate the card, or hid one that would, is the failure this
/// type exists to make impossible.
final class ModelRequirementTests: XCTestCase {
    private func model(id: String, sizeBytes: Int64 = 1_000,
                       tasks: [String] = ["generate"],
                       params: [String] = []) -> ModelInfo {
        let taskList = tasks.map { "\"\($0)\"" }.joined(separator: ", ")
        let paramList = params.map {
            """
            {"key": "\($0)", "type": "string", "label": "\($0)",
             "default": null, "nullable": true}
            """
        }.joined(separator: ", ")
        let json = """
        {
          "id": "\(id)", "family": "f", "display_name": "\(id)",
          "description": "", "hf_repos": [], "size_bytes": \(sizeBytes),
          "install_state": "not_installed", "installed_bytes": 0,
          "capabilities": {
            "supports_lyrics": false, "instrumental_only": true,
            "duration": {"min_s": 1, "max_s": 30, "default_s": 10},
            "sample_rate": 44100, "outputs_per_job_max": 1,
            "est_seconds_per_audio_second": 1,
            "tasks": [\(taskList)], "params": [\(paramList)]
          },
          "requirements": {"min_ram_bytes": 1, "disk_bytes": 0,
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

    private var catalog: [ModelInfo] {
        [model(id: "sep-big", sizeBytes: 900, tasks: ["separate"]),
         model(id: "sep-small", sizeBytes: 100, tasks: ["separate"]),
         model(id: "transcriber", tasks: ["transcribe"]),
         model(id: "renderer", tasks: ["render"]),
         model(id: "mixdown", tasks: ["mix"], params: ["mix_spec"]),
         model(id: "splicer", tasks: ["mix"], params: ["splice_spec"]),
         model(id: "generator", tasks: ["generate"])]
    }

    private func ids(_ requirement: ModelRequirement) -> [String] {
        requirement.candidates(catalog).map(\.id)
    }

    func testTaskRequirementSelectsOnlyModelsDeclaringIt() {
        XCTAssertEqual(Set(ids(.task("separate"))), ["sep-big", "sep-small"])
        XCTAssertEqual(ids(.task("transcribe")), ["transcriber"])
        XCTAssertEqual(ids(.task("render")), ["renderer"])
    }

    /// The distinction `MixModels` exists for: both declare `mix`, and picking
    /// the wrong one fails the job on a missing input rather than in the UI.
    func testMixdownAndSplicerAreNotInterchangeable() {
        XCTAssertEqual(ids(.mixdown), ["mixdown"])
        XCTAssertEqual(ids(.splicer), ["splicer"])
    }

    /// "Which one do I download" is almost always answered by the cheapest one
    /// that works, so that is what the filtered list leads with.
    func testCandidatesAreSmallestFirst() {
        XCTAssertEqual(ids(.task("separate")), ["sep-small", "sep-big"])
    }

    func testAGenerateOnlyModelSatisfiesNoTaskGate() {
        let generator = model(id: "generator", tasks: ["generate"])
        XCTAssertFalse(ModelRequirement.task("separate").matches(generator))
        XCTAssertFalse(ModelRequirement.mixdown.matches(generator))
        XCTAssertFalse(ModelRequirement.splicer.matches(generator))
    }

    /// A style mode's eligibility is the mode's own `canRun`, which reads the
    /// params a model exposes — the reason tags could not have expressed this.
    func testStyleRequirementDefersToTheMode() {
        for mode in StyleTransferMode.allCases {
            for candidate in catalog {
                XCTAssertEqual(ModelRequirement.style(mode).matches(candidate),
                               mode.canRun(candidate),
                               "\(mode.rawValue) vs \(candidate.id)")
            }
        }
    }

    func testEmptyCatalogYieldsNoCandidatesRatherThanACrash() {
        XCTAssertTrue(ModelRequirement.task("separate").candidates([]).isEmpty)
    }

    /// The chip reads "NEEDED FOR <title>", so the title has to name the thing
    /// the user just clicked rather than the task id.
    func testTitlesReadAsTheThingYouWereDoing() {
        XCTAssertEqual(ModelRequirement.task("separate").title, "Separate stems")
        XCTAssertEqual(ModelRequirement.task("render").title,
                       "Render notes to audio")
        XCTAssertEqual(ModelRequirement.mixdown.title, "Create a mix")
        XCTAssertEqual(ModelRequirement.task("caption").title,
                       "Describe music by listening")
        XCTAssertEqual(ModelRequirement.task("lyrics").title,
                       "Transcribe lyrics")
        XCTAssertEqual(ModelRequirement.task("tag").title, "Tag genre & mood")
        XCTAssertEqual(ModelRequirement.task("compose").title,
                       "Compose from notation")
    }

    /// Distinct gates must stay distinguishable — the id is what the Models
    /// screen diffs on to know the errand changed.
    func testIdsAreDistinct() {
        let all: [ModelRequirement] = [
            .task("separate"), .task("transcribe"), .task("render"),
            .mixdown, .splicer, .style(.cover),
        ]
        XCTAssertEqual(Set(all.map(\.id)).count, all.count)
    }
}

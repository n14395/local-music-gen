import XCTest
@testable import LocalMusic

/// What a fresh install is offered, and which of it this Mac arrives ticked.
///
/// These rules only ever run once per user, on a machine the developer does not
/// have, at the moment the app makes its first impression — so none of them is
/// something to leave to inspection.
final class OnboardingPlanTests: XCTestCase {

    private let gib: Int64 = 1_073_741_824

    private func model(_ id: String, minRamGB: Int64 = 8,
                       sizeBytes: Int64 = 1_000_000_000,
                       installState: String = "not_installed") -> ModelInfo {
        let json = """
        {
          "id": "\(id)", "family": "test",
          "display_name": "\(id)", "description": "", "hf_repos": [],
          "size_bytes": \(sizeBytes), "install_state": "\(installState)",
          "installed_bytes": 0,
          "capabilities": {
            "supports_lyrics": false, "instrumental_only": true,
            "duration": {"min_s": 1, "max_s": 30, "default_s": 10},
            "sample_rate": 44100, "outputs_per_job_max": 1,
            "est_seconds_per_audio_second": 1, "params": []
          },
          "requirements": {"min_ram_bytes": \(minRamGB * gib),
                            "disk_bytes": \(sizeBytes),
                            "speed_tier": "fast"},
          "license": {"name": "MIT", "commercial_use": true,
                       "requires_hf_token": false, "url": null},
          "notes": null
        }
        """
        // swiftlint:disable:next force_try — fixture is a compile-time constant
        return try! BackendClient.decoder.decode(ModelInfo.self, from: Data(json.utf8))
    }

    /// The real recommended set, at whatever size each id claims here.
    private func catalog(installed: Set<String> = [],
                         ramFloors: [String: Int64] = [:]) -> [ModelInfo] {
        (OnboardingPlan.essentialIds + OnboardingPlan.generatorIds).map {
            model($0, minRamGB: ramFloors[$0] ?? 8,
                  installState: installed.contains($0) ? "installed"
                                                       : "not_installed")
        }
    }

    // MARK: - The set itself

    func testEssentialsCoverEveryAuxiliaryTask() {
        // The whole point of the essentials: no screen of the app is left
        // without a model behind it.
        XCTAssertTrue(OnboardingPlan.essentialIds.contains("analysis-basic"))
        XCTAssertTrue(OnboardingPlan.essentialIds.contains("separation-htdemucs"))
        XCTAssertTrue(OnboardingPlan.essentialIds.contains("dsp-mixdown"))
        XCTAssertTrue(OnboardingPlan.essentialIds.contains("render-soundfont"))
        XCTAssertTrue(OnboardingPlan.essentialIds
            .contains { $0.hasPrefix("transcribe-") })
        // The near-free enrichers: without these the chords, quality and
        // tagging cards sit dimmed on a fresh install.
        XCTAssertTrue(OnboardingPlan.essentialIds.contains("analysis-chords-btc"))
        XCTAssertTrue(OnboardingPlan.essentialIds.contains("analysis-squim"))
        XCTAssertTrue(OnboardingPlan.essentialIds.contains("tag-essentia-discogs"))
    }

    func testTheEditCapableGeneratorIsOffered() {
        // MelodyFlow is the one model that edits existing audio toward a
        // prompt — the "Edit with words" card is dimmed without it.
        XCTAssertTrue(OnboardingPlan.generatorIds.contains("melodyflow-t24"))
    }

    func testTheSetsDoNotOverlap() {
        XCTAssertTrue(Set(OnboardingPlan.essentialIds)
            .isDisjoint(with: OnboardingPlan.generatorIds))
    }

    // MARK: - Ticks

    func testEssentialsArriveTicked() {
        let plan = OnboardingPlan.make(models: catalog(), physicalRAM: 8 * gib)
        XCTAssertEqual(plan.essentials.count, OnboardingPlan.essentialIds.count)
        XCTAssertTrue(plan.essentials.allSatisfy(\.defaultsOn))
        XCTAssertTrue(plan.essentials.allSatisfy(\.isEssential))
    }

    func testAGeneratorTheMacCanRunArrivesTicked() {
        let plan = OnboardingPlan.make(models: catalog(ramFloors: ["acestep-base": 16]),
                                       physicalRAM: 32 * gib)
        let ace = plan.generators.first { $0.id == "acestep-base" }
        XCTAssertEqual(ace?.defaultsOn, true)
        XCTAssertNil(ace?.blockedReason)
    }

    func testAGeneratorBeyondThisMacArrivesUntickedWithAReason() {
        let plan = OnboardingPlan.make(models: catalog(ramFloors: ["acestep-base": 16]),
                                       physicalRAM: 8 * gib)
        let ace = plan.generators.first { $0.id == "acestep-base" }
        XCTAssertEqual(ace?.defaultsOn, false)
        // The number the user needs is the one they can act on: what it wants
        // against what they have.
        XCTAssertEqual(ace?.blockedReason, "Needs 16 GB — this Mac has 8 GB")
        XCTAssertFalse(plan.defaultSelection.contains("acestep-base"))
    }

    func testABlockedModelIsStillOfferedRatherThanHidden() {
        // "Fixed set, RAM-aware ticks": the row stays so the user knows the
        // model exists and why it is not ticked.
        let plan = OnboardingPlan.make(models: catalog(ramFloors: ["acestep-base": 64]),
                                       physicalRAM: 8 * gib)
        XCTAssertTrue(plan.generators.contains { $0.id == "acestep-base" })
    }

    // MARK: - Totals

    func testSelectedBytesSumOnlyWhatIsTicked() {
        let models = [model("analysis-basic", sizeBytes: 100),
                      model("acestep-base", sizeBytes: 900)]
        let plan = OnboardingPlan.make(models: models, physicalRAM: 32 * gib)
        XCTAssertEqual(plan.bytes(for: ["analysis-basic"]), 100)
        XCTAssertEqual(plan.bytes(for: ["analysis-basic", "acestep-base"]), 1000)
        XCTAssertEqual(plan.bytes(for: []), 0)
    }

    func testEssentialBytesCountOnlyEssentials() {
        let models = [model("analysis-basic", sizeBytes: 100),
                      model("acestep-base", sizeBytes: 900)]
        let plan = OnboardingPlan.make(models: models, physicalRAM: 32 * gib)
        XCTAssertEqual(plan.essentialBytes, 100)
    }

    // MARK: - What it leaves out

    func testAlreadyInstalledModelsAreNotOffered() {
        let plan = OnboardingPlan.make(models: catalog(installed: ["analysis-basic"]),
                                       physicalRAM: 32 * gib)
        XCTAssertFalse(plan.all.contains { $0.id == "analysis-basic" })
    }

    func testAFullyEquippedInstallHasNothingToOffer() {
        let everything = Set(OnboardingPlan.essentialIds
                             + OnboardingPlan.generatorIds)
        let plan = OnboardingPlan.make(models: catalog(installed: everything),
                                       physicalRAM: 32 * gib)
        XCTAssertTrue(plan.isEmpty)
    }

    func testAnIdMissingFromTheCatalogIsSkippedNotFatal() {
        // The catalog ships separately from the app: a renamed entry should
        // cost one model, not the launch.
        let plan = OnboardingPlan.make(models: [model("analysis-basic")],
                                       physicalRAM: 32 * gib)
        XCTAssertEqual(plan.all.map(\.id), ["analysis-basic"])
    }

    func testAnEmptyCatalogYieldsAnEmptyPlan() {
        let plan = OnboardingPlan.make(models: [], physicalRAM: 32 * gib)
        XCTAssertTrue(plan.isEmpty)
        XCTAssertTrue(plan.defaultSelection.isEmpty)
        XCTAssertEqual(plan.essentialBytes, 0)
    }
}

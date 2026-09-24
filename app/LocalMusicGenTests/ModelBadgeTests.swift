// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import LocalMusicGen

/// The row of tokens under a model's name, shared by the Models screen and
/// Studio.
///
/// They used to be built twice — Studio said modality and length, the Models
/// screen said size, speed, licence and what the model unlocks — so the same
/// model described itself differently depending on which screen you asked.
/// One list now, and these are the things it has to contain.
final class ModelBadgeTests: XCTestCase {

    private let ram: Int64 = 64 * 1_073_741_824

    private func model(lyrics: Bool = true, instrumental: Bool = false,
                       maxS: Double = 300, sizeBytes: Int64 = 10_092_115_558,
                       tier: String = "medium", gated: Bool = false,
                       tasks: [String] = ["generate"],
                       minRamBytes: Int64 = 1,
                       install: String = "installed",
                       diskBytes: Int64 = 0) -> ModelInfo {
        let taskList = tasks.map { "\"\($0)\"" }.joined(separator: ", ")
        let json = """
        {
          "id": "acestep-15", "family": "acestep", "display_name": "ACE-Step 1.5",
          "description": "", "hf_repos": [], "size_bytes": \(sizeBytes),
          "install_state": "\(install)", "installed_bytes": 0,
          "capabilities": {
            "supports_lyrics": \(lyrics), "instrumental_only": \(instrumental),
            "duration": {"min_s": 1, "max_s": \(maxS), "default_s": 60},
            "sample_rate": 48000, "outputs_per_job_max": 1,
            "est_seconds_per_audio_second": 1,
            "tasks": [\(taskList)], "params": []
          },
          "requirements": {"min_ram_bytes": \(minRamBytes),
                            "disk_bytes": \(diskBytes),
                            "speed_tier": "\(tier)"},
          "license": {"name": "MIT", "commercial_use": true,
                       "requires_hf_token": \(gated), "url": null},
          "notes": null
        }
        """
        // swiftlint:disable:next force_try — fixture is a compile-time constant
        return try! BackendClient.decoder.decode(ModelInfo.self, from: Data(json.utf8))
    }

    private func texts(_ badges: [ModelBadges.Badge]) -> [String] {
        badges.map(\.text)
    }

    /// The row in the screenshot the change came from.
    func testTheWholeRowInTheOrderTheDesignDrawsIt() {
        let badges = ModelBadges.list(for: model(), physicalMemory: ram,
                                      actionCount: 3)
        XCTAssertEqual(texts(badges),
                       ["VOCALS + LYRICS", "≤ 300 S", "9.4 GB", "MEDIUM",
                        "3 ACTIONS"])
    }

    /// Studio passes no disk reading and no download state, and must still get
    /// everything else the Models screen shows.
    func testStudiosCallGetsTheSameRowMinusTheDiskWarning() {
        let ids = ModelBadges.list(for: model(gated: true), physicalMemory: ram,
                                   hasHFToken: true, actionCount: 1).map(\.id)
        XCTAssertEqual(ids, ["modality", "duration", "size", "speed", "hf",
                             "actions"])
    }

    func testSingularAction() {
        let badges = ModelBadges.list(for: model(), physicalMemory: ram,
                                      actionCount: 1)
        XCTAssertTrue(texts(badges).contains("1 ACTION"))
        XCTAssertFalse(texts(badges).contains("1 ACTIONS"))
    }

    func testNoActionsNoBadge() {
        XCTAssertFalse(ModelBadges.list(for: model(), physicalMemory: ram)
            .contains { $0.id == "actions" })
    }

    /// A model that will not fit says so wherever it is drawn, and says it
    /// first.
    func testAnOversizeModelLeadsWithTheMemoryWarning() {
        let big = model(minRamBytes: 96 * 1_073_741_824)
        let badges = ModelBadges.list(for: big, physicalMemory: ram)
        XCTAssertEqual(badges.first?.id, "ram")
        XCTAssertEqual(badges.first?.tone, .danger)
        XCTAssertEqual(badges.first?.text, "NEEDS 96 GB · YOU HAVE 64")
    }

    /// The disk warning is about a download that has not happened, so it never
    /// appears on a model you already have — which is every model Studio can
    /// select.
    func testDiskWarningOnlyForAModelYouHaveNotGot() {
        let needsDisk = model(install: "not_installed", diskBytes: 200_000_000_000)
        XCTAssertTrue(ModelBadges.list(for: needsDisk, physicalMemory: ram,
                                       freeDiskBytes: 1_000_000_000)
            .contains { $0.id == "disk" })
        let installed = model(install: "installed", diskBytes: 200_000_000_000)
        XCTAssertFalse(ModelBadges.list(for: installed, physicalMemory: ram,
                                        freeDiskBytes: 1_000_000_000)
            .contains { $0.id == "disk" })
    }

    /// A gated model says whether the token it needs is already there.
    func testGatedModelReportsTheToken() {
        XCTAssertTrue(texts(ModelBadges.list(for: model(gated: true),
                                             physicalMemory: ram,
                                             hasHFToken: false))
            .contains("HF TOKEN NEEDED"))
        XCTAssertTrue(texts(ModelBadges.list(for: model(gated: true),
                                             physicalMemory: ram,
                                             hasHFToken: true))
            .contains("HF TOKEN ✓"))
    }

    /// Modality and length describe generation; a separator declares both
    /// fields with dummy values and must not have them quoted back at it.
    func testATaskModelIsNotDescribedAsAGenerator() {
        let separator = model(lyrics: false, instrumental: true, maxS: 1,
                              tasks: ["separate"])
        let ids = ModelBadges.list(for: separator, physicalMemory: ram).map(\.id)
        XCTAssertFalse(ids.contains("modality"))
        XCTAssertFalse(ids.contains("duration"))
        XCTAssertEqual(ids, ["size", "speed"])
    }

    func testInstrumentalModelSaysSo() {
        let instrumental = model(lyrics: false, instrumental: true, maxS: 30)
        XCTAssertTrue(texts(ModelBadges.list(for: instrumental,
                                             physicalMemory: ram))
            .contains("INSTRUMENTAL"))
    }

    /// The narrow-window fallback keeps what the model *is* and drops what it
    /// costs — including, always, the warning that it will not fit.
    func testTheNarrowFallbackKeepsWhatMattersMost() {
        let big = model(minRamBytes: 96 * 1_073_741_824)
        let essential = ModelBadges.essential(for: big, physicalMemory: ram)
        XCTAssertEqual(essential.map(\.id), ["ram", "modality", "duration"])
        // And it is always a subset of the full row, so the two can never
        // disagree about a model.
        let full = ModelBadges.list(for: big, physicalMemory: ram,
                                    actionCount: 4)
        XCTAssertTrue(essential.allSatisfy { badge in full.contains(badge) })
    }

    func testEveryBadgeHasADistinctIdSoForEachIsStable() {
        let ids = ModelBadges.list(for: model(gated: true), isVariant: true,
                                   physicalMemory: ram, hasHFToken: false,
                                   actionCount: 2).map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "duplicate badge id in \(ids)")
    }
}

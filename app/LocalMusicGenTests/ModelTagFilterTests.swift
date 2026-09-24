// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import LocalMusicGen

final class ModelTagFilterTests: XCTestCase {
    /// Built by decoding rather than the memberwise init so the fixture keeps
    /// compiling as ModelInfo gains fields.
    private func model(_ id: String, tags: [String]?) -> ModelInfo {
        let tagsJSON = tags.map { list in
            ", \"tags\": [" + list.map { "\"\($0)\"" }.joined(separator: ", ") + "]"
        } ?? ""
        let json = """
        {
          "id": "\(id)", "family": "test"\(tagsJSON),
          "display_name": "\(id)", "description": "",
          "hf_repos": [], "size_bytes": 0,
          "install_state": "not_installed", "installed_bytes": 0,
          "capabilities": {
            "supports_lyrics": false, "instrumental_only": true,
            "duration": {"min_s": 1, "max_s": 10, "default_s": 5},
            "sample_rate": 44100, "outputs_per_job_max": 1,
            "est_seconds_per_audio_second": 1, "params": []
          },
          "requirements": {"min_ram_bytes": 0, "disk_bytes": 0,
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

    private var fixture: [ModelInfo] {
        [model("a", tags: ["Songs with vocals", "Remix & restyle"]),
         model("b", tags: ["Instrumental & loops"]),
         model("c", tags: ["Songs with vocals"]),
         model("d", tags: ["Stem separation"]),
         model("e", tags: nil)]
    }

    func testTagsAreOptionalOnTheWire() {
        XCTAssertEqual(model("e", tags: nil).modelTags, [])
        XCTAssertEqual(model("a", tags: ["Songs with vocals", "Remix & restyle"]).modelTags,
                       ["Songs with vocals", "Remix & restyle"])
    }

    func testOrderedTagsAreUniqueInCatalogOrder() {
        XCTAssertEqual(ModelTagFilter.orderedTags(from: fixture),
                       ["Songs with vocals", "Remix & restyle",
                        "Instrumental & loops", "Stem separation"])
    }

    func testOrderedTagsIgnoresModelsWithoutTags() {
        XCTAssertTrue(ModelTagFilter.orderedTags(from: [model("x", tags: nil)]).isEmpty)
        XCTAssertTrue(ModelTagFilter.orderedTags(from: [model("x", tags: [])]).isEmpty)
    }

    func testCountsPerTag() {
        let counts = ModelTagFilter.counts(from: fixture)
        XCTAssertEqual(counts["Songs with vocals"], 2)
        XCTAssertEqual(counts["Remix & restyle"], 1)
        XCTAssertEqual(counts["Stem separation"], 1)
        XCTAssertNil(counts["Nonexistent"])
    }

    func testEmptySelectionMatchesEverything() {
        for candidate in fixture {
            XCTAssertTrue(ModelTagFilter.matches(candidate, selection: []))
        }
    }

    func testSelectionIsOrAcrossTags() {
        let selection: Set = ["Stem separation", "Instrumental & loops"]
        let matched = fixture.filter { ModelTagFilter.matches($0, selection: selection) }
        XCTAssertEqual(matched.map(\.id), ["b", "d"])
    }

    func testSingleTagMatchesModelsCarryingIt() {
        let matched = fixture.filter {
            ModelTagFilter.matches($0, selection: ["Songs with vocals"])
        }
        XCTAssertEqual(matched.map(\.id), ["a", "c"])
    }

    func testUntaggedModelNeverMatchesAnActiveSelection() {
        XCTAssertFalse(ModelTagFilter.matches(model("e", tags: nil),
                                              selection: ["Songs with vocals"]))
    }

    func testNoMatchYieldsEmptyResult() {
        let matched = fixture.filter {
            ModelTagFilter.matches($0, selection: ["Notes & MIDI"])
        }
        XCTAssertTrue(matched.isEmpty)
    }
}

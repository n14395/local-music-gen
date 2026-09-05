import XCTest
@testable import LocalMusicGen

/// Which section a model's row lives in, and when the disclosure is held open.
///
/// The rule these pin is that **section membership depends only on the
/// catalog**. Folding downloads into the recommended set kept a running
/// transfer visible, but did it by moving the row: clicking Download in the
/// long tail lifted the row — and the button under the pointer — into the
/// section above, then dropped it back when the transfer ended.
final class ModelListPlacementTests: XCTestCase {
    private func model(_ id: String, featured: Bool = false,
                       variantOf: String? = nil,
                       installState: String = "not_installed") -> ModelInfo {
        let variantJSON = variantOf.map { "\"variant_of\": \"\($0)\"," } ?? ""
        let json = """
        {
          "id": "\(id)", "family": "test", \(variantJSON)
          "featured": \(featured),
          "display_name": "\(id)", "description": "", "hf_repos": [],
          "size_bytes": 0, "install_state": "\(installState)",
          "installed_bytes": 0,
          "capabilities": {
            "supports_lyrics": false, "instrumental_only": true,
            "duration": {"min_s": 1, "max_s": 30, "default_s": 10},
            "sample_rate": 44100, "outputs_per_job_max": 1,
            "est_seconds_per_audio_second": 1,
            "tasks": ["generate"], "params": []
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

    private func ids(_ rows: [ModelListRow]) -> [String] { rows.map(\.model.id) }

    // MARK: - The regression

    /// The whole bug in one assertion: the row is in the same section, at the
    /// same index, before and after its download starts.
    func testARowDoesNotMoveWhenItsDownloadStarts() {
        func plan(_ tailState: String) -> ModelListPlan {
            let models = [model("aaa-featured", featured: true),
                          model("mmm-tail", installState: tailState),
                          model("zzz-tail")]
            return ModelListLayout.plan(
                models: models,
                matching: Set(models.map(\.id)),
                recommended: ModelListLayout.recommendedIds(in: models),
                expanded: true)
        }
        let before = plan("not_installed")
        let during = plan("downloading")

        XCTAssertEqual(ids(before.other), ["mmm-tail", "zzz-tail"])
        XCTAssertEqual(ids(during.other), ids(before.other))
        XCTAssertEqual(ids(during.recommended), ids(before.recommended))
    }

    func testRecommendedIsFeaturedOnly() {
        let models = [model("a", featured: true),
                      model("b", installState: "downloading"),
                      model("c", installState: "installed")]
        XCTAssertEqual(ModelListLayout.recommendedIds(in: models), ["a"])
    }

    // MARK: - Reachability, which is what the promotion was protecting

    /// A transfer in the long tail keeps its section open, because this list is
    /// the only place to pause or cancel it.
    func testTailIsHeldOpenForADownloadItContains() {
        let models = [model("featured", featured: true), model("tail")]
        XCTAssertTrue(ModelListLayout.holdsTailOpen(models: models,
                                                    downloadingBaseIds: ["tail"]))
    }

    /// A featured model is already on screen, so nothing has to be forced.
    func testTailIsNotHeldOpenForAFeaturedDownload() {
        let models = [model("featured", featured: true), model("tail")]
        XCTAssertFalse(
            ModelListLayout.holdsTailOpen(models: models,
                                          downloadingBaseIds: ["featured"]))
    }

    func testTailIsNotHeldOpenWithNothingRunning() {
        let models = [model("featured", featured: true), model("tail")]
        XCTAssertFalse(ModelListLayout.holdsTailOpen(models: models,
                                                     downloadingBaseIds: []))
    }

    // MARK: - Base resolution

    /// A variant is never a section of its own, so holding a section open for
    /// one has to name the base it hangs under.
    func testAVariantReportsItsBase() {
        let models = [model("base"), model("base-q4", variantOf: "base")]
        XCTAssertEqual(ModelListLayout.baseIds(of: ["base-q4"], in: models),
                       ["base"])
    }

    /// The layout promotes an orphaned variant to a base of its own, so the
    /// two have to agree or the section held open would be one nobody draws.
    func testAVariantWithNoKnownBaseStandsForItself() {
        let models = [model("orphan-q4", variantOf: "missing")]
        XCTAssertEqual(ModelListLayout.baseIds(of: ["orphan-q4"], in: models),
                       ["orphan-q4"])
    }

    /// The same agreement, one level deeper: the layout hangs a grandchild off
    /// the ROOT of its chain, so the section held open for its download has to
    /// be that one. Naming the immediate parent would hold open a section the
    /// row is not in — and, where the root is featured, hold the long tail
    /// open for a download sitting in the recommended section.
    func testAGrandchildReportsTheRootBase() {
        let models = [model("bsrnn"),
                      model("scnet", variantOf: "bsrnn"),
                      model("scnet-xl", variantOf: "scnet")]
        XCTAssertEqual(ModelListLayout.baseIds(of: ["scnet-xl"], in: models),
                       ["bsrnn"])
    }

    func testBaseIdsIgnoresModelsThatAreNotDownloading() {
        let models = [model("a"), model("b")]
        XCTAssertEqual(ModelListLayout.baseIds(of: ["a"], in: models), ["a"])
    }
}

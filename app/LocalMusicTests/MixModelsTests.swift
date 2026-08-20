import XCTest
@testable import LocalMusic

/// Choosing the model that renders a mixdown.
///
/// Regression: Token Splice also declares task "mix", so "first installed model
/// that supports mix" picked it whenever it sorted first, and Create Mix failed
/// the job with "missing required input 'splice_spec'".
final class MixModelsTests: XCTestCase {

    private func model(_ id: String, param: String,
                       installed: Bool = true) -> ModelInfo {
        let json = """
        {
          "id": "\(id)", "family": "test", "display_name": "\(id)",
          "description": "", "hf_repos": [], "size_bytes": 0,
          "install_state": "\(installed ? "installed" : "not_installed")",
          "installed_bytes": 0,
          "capabilities": {
            "supports_lyrics": false, "instrumental_only": true,
            "duration": {"min_s": 1, "max_s": 10, "default_s": 5},
            "sample_rate": 44100, "outputs_per_job_max": 1,
            "est_seconds_per_audio_second": 1,
            "tasks": ["mix"],
            "params": [{"key": "\(param)", "type": "json", "label": "Spec",
                        "default": null, "nullable": false, "internal": true}]
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

    func testSplicerIsNeverChosenForAMixdown() {
        let models = [model("token-splice", param: "splice_spec"),
                      model("dsp-mixdown", param: "mix_spec")]
        XCTAssertEqual(MixModels.mixdown(in: models)?.id, "dsp-mixdown")
        XCTAssertEqual(MixModels.splicer(in: models)?.id, "token-splice")
    }

    func testNoMixdownWhenOnlyASplicerIsInstalled() {
        XCTAssertNil(MixModels.mixdown(
            in: [model("token-splice", param: "splice_spec")]))
    }

    func testUninstalledModelsAreIgnored() {
        XCTAssertNil(MixModels.mixdown(
            in: [model("dsp-mixdown", param: "mix_spec", installed: false)]))
    }
}

import XCTest
@testable import LocalMusic

/// A model row has two halves to report, not one: the weights, and the family
/// runtime the adapter needs before those weights can be loaded.
///
/// The bug these pin down: "Installed" used to mean weights alone, so a model
/// could wear a green tick and then spend the first four minutes of the first
/// generation installing PyTorch. `runtime_state` (contract §4.1) is the other
/// half, and the row says which of the two it has.
final class ModelRuntimeStateTests: XCTestCase {

    private func model(id: String = "acestep-cpp-turbo",
                       family: String = "acestepcpp",
                       install: InstallState = .installed,
                       runtime: RuntimeState? = .installed) -> ModelInfo {
        ModelInfo(
            id: id, family: family, displayName: id, description: "",
            hfRepos: [], sizeBytes: 3_221_225_472,
            installState: install, installedBytes: 0, runtimeState: runtime,
            capabilities: Capabilities(
                supportsLyrics: true, instrumentalOnly: false,
                duration: DurationSpec(minS: 1, maxS: 300, defaultS: 60),
                sampleRate: 48000, outputsPerJobMax: 1,
                estSecondsPerAudioSecond: 1, params: []),
            requirements: Requirements(minRamBytes: 1, diskBytes: 0,
                                       speedTier: .fast),
            license: LicenseInfo(name: "MIT", commercialUse: true,
                                 requiresHfToken: false, url: nil))
    }

    // MARK: - Readiness

    func testWeightsAndRuntimeTogetherAreReady() {
        let ready = ModelReadiness.of(model())
        XCTAssertEqual(ready, .ready)
        XCTAssertEqual(ready.controlLabel, "Downloaded")
        XCTAssertTrue(ready.isRunnable)
    }

    /// The state the user hit: every byte of the model is on disk, and the
    /// first generation would still stop to build the runtime.
    func testWeightsWithoutRuntimeOffersTheRuntimeInstall() {
        let state = ModelReadiness.of(model(runtime: .notInstalled))
        XCTAssertEqual(state, .runtimeMissing)
        XCTAssertEqual(state.controlLabel, "Model downloaded")
        XCTAssertFalse(state.isRunnable)
    }

    func testRuntimeBeingBuiltIsNotOfferedAgain() {
        let state = ModelReadiness.of(model(runtime: .installing))
        XCTAssertEqual(state, .runtimeInstalling)
        // Still "model downloaded" — the weights half is unchanged, and only
        // the runtime is moving.
        XCTAssertEqual(state.controlLabel, "Model downloaded")
    }

    /// A missing runtime says nothing about a model nobody has downloaded: the
    /// Download button already installs both halves (contract §4.2).
    func testAnAbsentModelIsJustADownload() {
        for install in [InstallState.notInstalled, .partial, .downloading] {
            let state = ModelReadiness.of(model(install: install,
                                                runtime: .notInstalled))
            XCTAssertNotEqual(state, .runtimeMissing)
            XCTAssertNil(state.controlLabel, "\(install)")
        }
        XCTAssertEqual(ModelReadiness.of(model(install: .notInstalled)), .download)
        XCTAssertEqual(ModelReadiness.of(model(install: .partial)), .resumeDownload)
        XCTAssertEqual(ModelReadiness.of(model(install: .downloading)), .starting)
    }

    /// An engine that predates the field must not have every model accused of
    /// a missing runtime.
    func testAnEngineThatCannotSayIsTakenAsReady() {
        XCTAssertEqual(model(runtime: nil).runtime, .installed)
        XCTAssertEqual(ModelReadiness.of(model(runtime: nil)), .ready)
    }

    func testRuntimeStateDecodesFromTheWire() throws {
        let json = """
        {"id":"m","family":"acestep","display_name":"M","description":"",
         "hf_repos":[],"size_bytes":1,"install_state":"installed",
         "installed_bytes":1,"runtime_state":"not_installed","pinned":false,
         "capabilities":{"supports_lyrics":false,"instrumental_only":true,
           "duration":{"min_s":1,"max_s":2,"default_s":1},"sample_rate":44100,
           "outputs_per_job_max":1,"est_seconds_per_audio_second":1,"params":[]},
         "requirements":{"min_ram_bytes":1,"disk_bytes":1,"speed_tier":"fast"},
         "license":{"name":"MIT","commercial_use":true,"requires_hf_token":false,
           "url":null},"notes":null}
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let decoded = try decoder.decode(ModelInfo.self,
                                         from: Data(json.utf8))
        XCTAssertEqual(decoded.runtime, .notInstalled)
        XCTAssertEqual(ModelReadiness.of(decoded), .runtimeMissing)
    }

    // MARK: - Deletion

    /// Deleting the last model of a family takes its runtime with it, and the
    /// confirmation has to say so — for ACE-Step that venv is 1.4 GB, more than
    /// some of the models it serves.
    func testDeleteSaysWhenTheRuntimeGoesToo() {
        let solo = model(id: "acestep-cpp-turbo")
        XCTAssertTrue(ModelDeletion.removesRuntime(solo, in: [solo]))
        XCTAssertTrue(ModelDeletion.message(for: solo, in: [solo])
            .contains("acestepcpp runtime goes too"))
    }

    func testDeleteKeepsARuntimeAnotherModelStillNeeds() {
        let a = model(id: "acestep-cpp-turbo")
        let b = model(id: "acestep-cpp-xl-base")
        XCTAssertFalse(ModelDeletion.removesRuntime(a, in: [a, b]))
        XCTAssertFalse(ModelDeletion.message(for: a, in: [a, b])
            .contains("runtime"))
        // A sibling that is not downloaded is not a reason to keep it.
        let absent = model(id: "acestep-cpp-xl-sft", install: .notInstalled)
        XCTAssertTrue(ModelDeletion.removesRuntime(a, in: [a, absent]))
        // Nor is one from another family.
        let other = model(id: "musicgen-small", family: "musicgen")
        XCTAssertTrue(ModelDeletion.removesRuntime(a, in: [a, other]))
    }

    /// Nothing to promise when the runtime was never there.
    func testDeleteClaimsNothingWhenThereIsNoRuntime() {
        let bare = model(runtime: .notInstalled)
        XCTAssertFalse(ModelDeletion.removesRuntime(bare, in: [bare]))
        let message = ModelDeletion.message(for: bare, in: [bare])
        XCTAssertFalse(message.contains("runtime"))
        XCTAssertTrue(message.contains("Songs you generated are kept"))
    }

    // MARK: - Download rows

    func testARuntimeInstallSaysItCarriesNoWeights() throws {
        let json = """
        {"download_id":"dl_1","model_id":"m","state":"provisioning",
         "bytes_done":0,"bytes_total":0,"speed_bps":0,"stage":"provisioning",
         "message":"Installing acestep runtime…","runtime_only":true}
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let info = try decoder.decode(DownloadInfo.self, from: Data(json.utf8))
        XCTAssertTrue(info.isRuntimeOnly)
        XCTAssertEqual(info.state, .provisioning)
        // The engine documents pause over a runtime install as accepted and
        // ignored, so the row must not offer it as if it worked.
        XCTAssertNotNil(DownloadFormat.pauseBlockedReason(info.state))
    }

    func testAWeightsDownloadIsNotARuntimeInstall() throws {
        let json = """
        {"download_id":"dl_2","model_id":"m","state":"downloading",
         "bytes_done":1,"bytes_total":2,"speed_bps":3,"stage":"weights",
         "message":"fetching"}
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let info = try decoder.decode(DownloadInfo.self, from: Data(json.utf8))
        XCTAssertFalse(info.isRuntimeOnly)
    }
}

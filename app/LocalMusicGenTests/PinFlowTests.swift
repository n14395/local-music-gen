// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import LocalMusicGen

/// Keep-model-loaded pin against the stub: toggling the pin must round-trip
/// through the engine, mark the model in the catalog, and drive the
/// worker.state events that put the loaded model into the window title.
@MainActor
final class PinFlowTests: XCTestCase {
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func waitFor(_ what: String, timeout: TimeInterval = 90,
                         _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTFail("timed out waiting for \(what)")
        throw CancellationError()
    }

    func testPinReflectsInCatalogAndWorkerState() async throws {
        setenv("LOCALMUSICGEN_STUB_DOWNLOAD_S", "2", 1)
        setenv("LOCALMUSICGEN_STUB_PROVISION_S", "1", 1)
        defer {
            unsetenv("LOCALMUSICGEN_STUB_DOWNLOAD_S")
            unsetenv("LOCALMUSICGEN_STUB_PROVISION_S")
        }

        let script = Self.repoRoot.appendingPathComponent("stub-backend/run-stub.sh").path
        let env = AppEnvironment(
            modeOverride: .spawn(command: ["/bin/bash", "-lc",
                                           "exec \"\(script)\" \"$@\"",
                                           "local-music-gen-engine"]),
            database: try DatabaseManager.inMemory())
        env.startBackend()
        try await waitFor("catalog") { !env.catalog.models.isEmpty }

        let model = env.catalog.models.first { $0.id == "musicgen-small" }!
        await env.catalog.startDownload(model)
        try await waitFor("installed") {
            env.catalog.models.first { $0.id == "musicgen-small" }?
                .installState == .installed
        }

        await env.catalog.setPin(model, enabled: true)
        try await waitFor("catalog shows pinned") {
            env.catalog.models.first { $0.id == "musicgen-small" }?
                .isPinned == true
        }
        try await waitFor("worker.state drives titlebar state") {
            env.backendStatus.workerModelId == "musicgen-small"
                && env.backendStatus.workerModelState == "loaded"
        }

        await env.catalog.setPin(model, enabled: false)
        try await waitFor("catalog shows unpinned") {
            env.catalog.models.first { $0.id == "musicgen-small" }?
                .isPinned == false
        }
        // unpin only removes the reload guarantee — the model stays resident
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(env.backendStatus.workerModelId, "musicgen-small")

        env.unloadModel()
        try await waitFor("unload clears titlebar state") {
            env.backendStatus.workerModelId == nil
        }

        await env.shutdown()
    }
}

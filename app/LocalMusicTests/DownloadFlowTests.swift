import XCTest
@testable import LocalMusic

/// End-to-end store wiring against the stub: catalog refresh on connect, download
/// progress via SSE routing, pause/resume, completion → installed.
@MainActor
final class DownloadFlowTests: XCTestCase {
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func waitFor(_ what: String, timeout: TimeInterval = 60,
                         _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTFail("timed out waiting for \(what)")
        throw CancellationError()
    }

    func testCatalogAndDownloadFlow() async throws {
        // Speed up the stub's simulated download; env propagates through spawn.
        //
        // Not faster than this, though: the pause below has to land *during*
        // the weights transfer, so the whole assertion lives inside this
        // budget minus the ~1.5 s of provisioning ahead of it. At 3 s the
        // margin was about two seconds and a loaded machine ate it — the test
        // failed with "timed out waiting for paused state" because the
        // download had already finished, not because pause was broken.
        setenv("LOCALMUSIC_STUB_DOWNLOAD_S", "8", 1)
        setenv("LOCALMUSIC_STUB_PROVISION_S", "1", 1)
        defer {
            unsetenv("LOCALMUSIC_STUB_DOWNLOAD_S")
            unsetenv("LOCALMUSIC_STUB_PROVISION_S")
        }

        let script = Self.repoRoot.appendingPathComponent("stub-backend/run-stub.sh").path
        let env = AppEnvironment(modeOverride: .spawn(
            command: ["/bin/bash", "-lc", "exec \"\(script)\" \"$@\"",
                      "local-music-engine"]))
        env.startBackend()

        try await waitFor("catalog populated") { !env.catalog.models.isEmpty }
        XCTAssertNotNil(env.catalog.models.first { $0.id == "musicgen-small" })
        // Drives the empty-state choice: only now may the UI say "no models".
        XCTAssertTrue(env.catalog.hasLoaded)

        let model = env.catalog.models.first { $0.id == "musicgen-small" }!
        XCTAssertEqual(model.installState, .notInstalled)

        await env.catalog.startDownload(model)
        try await waitFor("download visible in store") {
            env.downloadsStore.info(forModel: "musicgen-small") != nil
        }

        let dl = env.downloadsStore.info(forModel: "musicgen-small")!

        // A download now begins by provisioning the family's runtime, and
        // pause is deliberately a no-op there — `uv sync` is not resumable, and
        // reporting "paused" over a subprocess that is still working would be a
        // lie (contract §4.2). So wait for the weights transfer before pausing;
        // before that stage existed this call landed immediately.
        try await waitFor("weights transfer started") {
            env.downloadsStore.info(forModel: "musicgen-small")?.stage == "weights"
        }
        await env.downloadsStore.pause(dl.id)
        try await waitFor("paused state") {
            env.downloadsStore.info(forModel: "musicgen-small")?.state == .paused
        }
        await env.downloadsStore.resume(dl.id)

        try await waitFor("model installed") {
            env.catalog.models.first { $0.id == "musicgen-small" }?
                .installState == .installed
        }
        XCTAssertNil(env.downloadsStore.info(forModel: "musicgen-small"),
                     "completed download should leave the store")

        await env.shutdown()
    }

    /// Contract §4.2: downloads transfer one at a time, and the ones behind say
    /// `queued` rather than reporting a transfer moving at 0 B/s.
    func testDownloadsRunOneAtATime() async throws {
        setenv("LOCALMUSIC_STUB_DOWNLOAD_S", "4", 1)
        setenv("LOCALMUSIC_STUB_PROVISION_S", "1", 1)
        defer {
            unsetenv("LOCALMUSIC_STUB_DOWNLOAD_S")
            unsetenv("LOCALMUSIC_STUB_PROVISION_S")
        }

        let script = Self.repoRoot.appendingPathComponent("stub-backend/run-stub.sh").path
        let env = AppEnvironment(modeOverride: .spawn(
            command: ["/bin/bash", "-lc", "exec \"\(script)\" \"$@\"",
                      "local-music-engine"]))
        env.startBackend()
        try await waitFor("catalog populated") { !env.catalog.models.isEmpty }

        for id in ["musicgen-small", "acestep-base"] {
            let model = try XCTUnwrap(env.catalog.models.first { $0.id == id })
            await env.catalog.startDownload(model)
        }
        try await waitFor("both downloads visible") {
            env.downloadsStore.downloads.count == 2
        }

        let waiting = try XCTUnwrap(
            env.downloadsStore.downloads.values.first { $0.state == .queued },
            "the second download waits its turn")
        XCTAssertEqual(env.downloadsStore.downloads.values.filter {
            $0.state == .queued
        }.count, 1, "exactly one of the two is transferring")
        XCTAssertEqual(waiting.speedBps, 0,
                       "a download that has not started invents no throughput")

        // And it does get its turn: either it is transferring by then, or it
        // already finished and left the store.
        try await waitFor("the waiting download is released") {
            env.downloadsStore.downloads[waiting.id]?.state != .queued
        }

        await env.shutdown()
    }
}

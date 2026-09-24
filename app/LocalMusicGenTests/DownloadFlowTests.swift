// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import LocalMusicGen

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

    /// Grant a waiting download `ticks` units of progress.
    ///
    /// Straight to the stub rather than through `BackendClient`: `_step` is a
    /// test fixture's control surface, not part of the contract, and it has no
    /// business on the client the app ships. `BackendClient` is an internal
    /// `Sendable` struct holding the base URL and the token the manager
    /// generated, so `@testable` is all the access this needs.
    private func step(_ env: AppEnvironment, _ downloadId: String,
                      ticks: Int = 1) async throws {
        // Hoisted out of XCTUnwrap: its argument is an autoclosure, which
        // cannot carry the `await` this actor-isolated read needs.
        let connected = await env.backendManager.client
        let client = try XCTUnwrap(connected,
                                   "no client — the stub never came up")
        var request = URLRequest(
            url: client.baseURL
                .appendingPathComponent("v1/downloads/\(downloadId)/_step")
                .appending(queryItems: [.init(name: "ticks", value: "\(ticks)")]))
        request.httpMethod = "POST"
        request.setValue("Bearer \(client.token)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 202,
                       "the stub is not in manual mode — is "
                       + "LOCALMUSICGEN_STUB_DOWNLOAD_S set to 0?")
    }

    /// Step until `condition` holds, or give up after `maxSteps`.
    ///
    /// Bounded by steps rather than by seconds, which is the whole point: how
    /// many ticks a phase takes is the stub's business, and nothing advances
    /// between them, so a slow machine makes this slower and never wrong.
    private func stepUntil(_ what: String, _ env: AppEnvironment,
                           _ downloadId: String, maxSteps: Int = 12,
                           _ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<maxSteps {
            if condition() { return }
            try await step(env, downloadId)
            // One short settle for the emitted event to cross the SSE stream.
            // Not a race: the transfer cannot move again until it is stepped.
            try await waitForBriefly(condition)
        }
        guard condition() else {
            XCTFail("still not true after \(maxSteps) steps: \(what)")
            throw CancellationError()
        }
    }

    /// Poll for up to two seconds. Used only after an action that has already
    /// happened engine-side, to let its event arrive.
    private func waitForBriefly(_ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline && !condition() {
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    func testCatalogAndDownloadFlow() async throws {
        // `0` puts the stub in manual mode: nothing advances until this test
        // says so. Env propagates through spawn.
        //
        // It used to be a timed transfer, widened once from 3 s to 8 s because
        // a loaded machine ate the margin. That was never a margin problem.
        // The test has to see the download appear, see it reach the weights
        // stage, pause it, and see `paused` land — all before the simulated
        // transfer ends, because a finished download leaves the store and its
        // id stops resolving. Four hops across a process boundary and an SSE
        // stream, racing a stopwatch, failing at a different assertion each
        // time ("download visible in store", "paused state", "model
        // installed") for one underlying reason.
        //
        // Now the transfer cannot finish behind the test's back, so a slow
        // machine makes this slower and never wrong.
        setenv("LOCALMUSICGEN_STUB_DOWNLOAD_S", "0", 1)
        defer { unsetenv("LOCALMUSICGEN_STUB_DOWNLOAD_S") }

        let script = Self.repoRoot.appendingPathComponent("stub-backend/run-stub.sh").path
        let env = AppEnvironment(modeOverride: .spawn(
            command: ["/bin/bash", "-lc", "exec \"\(script)\" \"$@\"",
                      "local-music-gen-engine"]))
        env.startBackend()

        try await waitFor("catalog populated") { !env.catalog.models.isEmpty }
        XCTAssertNotNil(env.catalog.models.first { $0.id == "musicgen-small" })
        // Drives the empty-state choice: only now may the UI say "no models".
        XCTAssertTrue(env.catalog.hasLoaded)

        // The transfer under test runs on a deliberately tiny model. The
        // engine refuses any download it cannot fit at 1.2x its declared size
        // (contract §4.2), so pointing this at a multi-gigabyte entry couples
        // a test about pause and resume to how full the machine's disk
        // happens to be — which is how its sibling came to fail outright on a
        // box with 7 GB free. Nothing here depends on the model's size.
        let smallModel = "separation-stub"
        let model = try XCTUnwrap(env.catalog.models.first { $0.id == smallModel })
        XCTAssertEqual(model.installState, .notInstalled)

        await env.catalog.startDownload(model)
        try await waitFor("download visible in store") {
            env.downloadsStore.info(forModel: smallModel) != nil
        }

        let dl = env.downloadsStore.info(forModel: smallModel)!
        XCTAssertEqual(dl.speedBps, 0,
                       "a stepped transfer moves at no rate between steps")

        // A download begins by provisioning the family's runtime, and pause is
        // deliberately a no-op there — `uv sync` is not resumable, and
        // reporting "paused" over a subprocess that is still working would be a
        // lie (contract §4.2). So reach the weights transfer before pausing.
        // `stage == "weights"` is NOT enough, and this is the bug the old
        // timed test kept hitting. A download is ANNOUNCED as
        // `state: queued, stage: weights` the moment it is accepted — the
        // stage only becomes "provisioning" when the dispatcher picks it up a
        // beat later. Waiting on the stage alone therefore returns while the
        // download is still queued, the pause below lands during provisioning
        // where it is a documented no-op, and the test waits out its full
        // minute for a `paused` that was never coming. That is what "timed out
        // waiting for paused state" always was; the clock was a red herring.
        try await stepUntil("the weights transfer to start", env, dl.id) {
            let info = env.downloadsStore.info(forModel: smallModel)
            return info?.state == .downloading && info?.stage == "weights"
        }

        await env.downloadsStore.pause(dl.id)
        try await waitFor("paused state") {
            env.downloadsStore.info(forModel: smallModel)?.state == .paused
        }

        // The transfer is held, so a granted tick is not spent: this is the
        // assertion the timed version could never make, because it could not
        // tell a download that refused to advance from one that had already
        // finished.
        let bytesWhenPaused = env.downloadsStore
            .info(forModel: smallModel)?.bytesDone
        try await step(env, dl.id)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(env.downloadsStore.info(forModel: smallModel)?.state,
                       .paused, "a step must not resume a paused transfer")
        XCTAssertEqual(env.downloadsStore.info(forModel: smallModel)?.bytesDone,
                       bytesWhenPaused, "a paused transfer moved no bytes")

        await env.downloadsStore.resume(dl.id)
        // Enough ticks to cover the rest of the transfer whatever the stub
        // divides it into; spare ones land on a download that has already gone.
        try await step(env, dl.id, ticks: 16)

        try await waitFor("model installed") {
            env.catalog.models.first { $0.id == smallModel }?
                .installState == .installed
        }
        XCTAssertNil(env.downloadsStore.info(forModel: smallModel),
                     "completed download should leave the store")

        await env.shutdown()
    }

    /// Contract §4.2: downloads transfer one at a time, and the ones behind say
    /// `queued` rather than reporting a transfer moving at 0 B/s.
    func testDownloadsRunOneAtATime() async throws {
        // Manual mode, for the same reason as above: the transfer in front
        // must not be able to finish while this test is inspecting the one
        // behind it.
        setenv("LOCALMUSICGEN_STUB_DOWNLOAD_S", "0", 1)
        defer { unsetenv("LOCALMUSICGEN_STUB_DOWNLOAD_S") }

        let script = Self.repoRoot.appendingPathComponent("stub-backend/run-stub.sh").path
        let env = AppEnvironment(modeOverride: .spawn(
            command: ["/bin/bash", "-lc", "exec \"\(script)\" \"$@\"",
                      "local-music-gen-engine"]))
        env.startBackend()
        try await waitFor("catalog populated") { !env.catalog.models.isEmpty }

        // Two models of different families, both deliberately tiny.
        //
        // This used to queue `acestep-base` behind `musicgen-small`, and the
        // engine refuses any download it cannot fit at 1.2x its declared size
        // (contract §4.2). So on a machine with less than ~9 GB free the
        // second POST came back 409, one download appeared instead of two, and
        // the test sat here for its full sixty seconds before failing with
        // "timed out waiting for both downloads visible": a message about
        // queueing, for a problem that was nothing to do with queueing. What
        // is under test is that transfers run ONE AT A TIME, which no model's
        // size has any bearing on.
        for id in ["separation-stub", "render-stub"] {
            let model = try XCTUnwrap(env.catalog.models.first { $0.id == id })
            await env.catalog.startDownload(model)
        }
        // Surfaced before the wait rather than after it: a refused download
        // never arrives, and sixty seconds of silence is a worse way to learn
        // that than the reason the engine already gave.
        // `lastActionError`, not `lastError`: every mutation ends with a catalog
        // refresh, and a successful refresh clears `lastError` — so this read
        // used to be vacuous, passing for a refusal it was written to catch.
        XCTAssertNil(env.catalog.lastActionError,
                     "the engine refused a download before any queueing happened")
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

        // And it does get its turn — once the one ahead is out of the way,
        // which is now something this test decides rather than waits out.
        let running = try XCTUnwrap(
            env.downloadsStore.downloads.values.first { $0.state != .queued })
        try await step(env, running.id, ticks: 16)
        try await waitFor("the download in front finishes") {
            env.downloadsStore.downloads[running.id] == nil
        }
        try await waitFor("the waiting download is released") {
            env.downloadsStore.downloads[waiting.id]?.state != .queued
        }

        await env.shutdown()
    }
}

// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import LocalMusicGen

/// Full generation loop against the stub: submit → SSE progress → completion →
/// ingest into the library with the audio file moved into place.
@MainActor
final class GenerationFlowTests: XCTestCase {
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

    func testGenerateAndIngest() async throws {
        setenv("LOCALMUSICGEN_STUB_DOWNLOAD_S", "2", 1)
        setenv("LOCALMUSICGEN_STUB_PROVISION_S", "1", 1)
        setenv("LOCALMUSICGEN_STUB_JOB_SPEED", "4", 1)
        defer {
            unsetenv("LOCALMUSICGEN_STUB_DOWNLOAD_S")
            unsetenv("LOCALMUSICGEN_STUB_PROVISION_S")
            unsetenv("LOCALMUSICGEN_STUB_JOB_SPEED")
        }

        let script = Self.repoRoot.appendingPathComponent("stub-backend/run-stub.sh").path
        let env = AppEnvironment(
            modeOverride: .spawn(command: ["/bin/bash", "-lc",
                                           "exec \"\(script)\" \"$@\"",
                                           "local-music-gen-engine"]),
            database: try DatabaseManager.inMemory())
        env.startBackend()
        try await waitFor("catalog") { !env.catalog.models.isEmpty }

        // install the stub's musicgen-small
        let model = env.catalog.models.first { $0.id == "musicgen-small" }!
        await env.catalog.startDownload(model)
        try await waitFor("installed") {
            env.catalog.models.first { $0.id == "musicgen-small" }?
                .installState == .installed
        }

        let before = env.library.recent.count
        await env.jobsStore.submit(modelId: "musicgen-small",
                                   prompt: "integration test tune",
                                   lyrics: nil, durationS: 4, count: 2,
                                   params: ["guidance_scale": .double(4.0)])
        try await waitFor("job appears") { !env.jobsStore.trackedJobs.isEmpty }
        try await waitFor("progress arrives") {
            env.jobsStore.displayJobs.first?.progress != nil
        }
        try await waitFor("ingest") { env.library.recent.count == before + 2 }

        let songs = env.library.recent.prefix(2)
        for song in songs {
            XCTAssertTrue(FileManager.default.fileExists(atPath: song.fileURL.path),
                          "audio moved into Library/Audio")
            XCTAssertEqual(song.modelId, "musicgen-small")
            XCTAssertEqual(song.prompt, "integration test tune")
            XCTAssertNotNil(song.groupId)
            try? FileManager.default.removeItem(at: song.fileURL)
        }
        // Takes asked for together share one number and differ by a letter —
        // track001a, track001b (the prompt identifies them in the UI, appended
        // after the name rather than baked into the title).
        let titles = songs.map(\.title).sorted()
        XCTAssertEqual(titles, ["track001a", "track001b"],
                       "one submission, one number, a letter per take")
        XCTAssertEqual(Set(titles.compactMap(SongRecord.trackNumber(in:))).count, 1,
                       "the lettered names must still read back as one number")

        // A name from the Studio's Name field replaces the default, and its
        // takes are lettered in brackets rather than run together.
        let named = env.library.recent.count
        await env.jobsStore.submit(modelId: "musicgen-small",
                                   prompt: "integration test tune",
                                   lyrics: nil, durationS: 4, count: 2,
                                   params: [:], name: "Warehouse jam")
        try await waitFor("named ingest") {
            env.library.recent.count == named + 2
        }
        let namedTitles = env.library.recent.prefix(2).map(\.title).sorted()
        XCTAssertEqual(namedTitles, ["Warehouse jam (a)", "Warehouse jam (b)"])
        // A typed name is not a trackNNN, so it must not move the high-water
        // mark — the next default is still the one after the batch above.
        XCTAssertEqual(try env.library.repository.highestTrackNumber(), 1)
        for song in env.library.recent.prefix(2) {
            try? FileManager.default.removeItem(at: song.fileURL)
        }

        await env.shutdown()
    }

    /// Contract 5.3: cancelling means the job produced no output — the row
    /// lands as `canceled` with a null result, and nothing reaches the
    /// library. (The "keep partial" preview path this test once covered was
    /// removed with the live-preview feature, 2026-09-03: only 15 of 129
    /// models could ever produce a frame, which broke uniform behavior.)
    func testCancelKeepsNothing() async throws {
        setenv("LOCALMUSICGEN_STUB_DOWNLOAD_S", "2", 1)
        setenv("LOCALMUSICGEN_STUB_PROVISION_S", "1", 1)
        setenv("LOCALMUSICGEN_STUB_JOB_SPEED", "4", 1)
        defer {
            unsetenv("LOCALMUSICGEN_STUB_DOWNLOAD_S")
            unsetenv("LOCALMUSICGEN_STUB_PROVISION_S")
            unsetenv("LOCALMUSICGEN_STUB_JOB_SPEED")
        }

        let script = Self.repoRoot.appendingPathComponent("stub-backend/run-stub.sh").path
        let env = AppEnvironment(
            modeOverride: .spawn(command: ["/bin/bash", "-lc",
                                           "exec \"\(script)\" \"$@\"",
                                           "local-music-gen-engine"]),
            database: try DatabaseManager.inMemory())
        env.startBackend()
        try await waitFor("catalog") { !env.catalog.models.isEmpty }

        let model = try XCTUnwrap(
            env.catalog.models.first { $0.id == "musicgen-small" })
        await env.catalog.startDownload(model)
        try await waitFor("installed") {
            env.catalog.models.first { $0.id == "musicgen-small" }?
                .installState == .installed
        }

        let before = env.library.recent.count
        let created = await env.jobsStore.submit(
            modelId: "musicgen-small", prompt: "cancel me", lyrics: nil,
            durationS: 30, count: 1, params: [:])
        let jobId = try XCTUnwrap(created?.jobs.first?.jobId,
                                  "submit failed: \(env.jobsStore.lastError ?? "-")")
        try await waitFor("the render is underway") {
            env.jobsStore.job(jobId)?.status == .generating
        }
        await env.jobsStore.cancel(jobId)
        try await waitFor("cancel lands") {
            env.jobsStore.job(jobId)?.status == .canceled
        }
        XCTAssertNil(env.jobsStore.job(jobId)?.info.result,
                     "a canceled job has no result")
        XCTAssertEqual(env.library.recent.count, before,
                       "a cancel keeps nothing")

        await env.shutdown()
    }
}

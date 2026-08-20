import XCTest
@testable import LocalMusic

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
        setenv("LOCALMUSIC_STUB_DOWNLOAD_S", "2", 1)
        setenv("LOCALMUSIC_STUB_PROVISION_S", "1", 1)
        setenv("LOCALMUSIC_STUB_JOB_SPEED", "4", 1)
        defer {
            unsetenv("LOCALMUSIC_STUB_DOWNLOAD_S")
            unsetenv("LOCALMUSIC_STUB_PROVISION_S")
            unsetenv("LOCALMUSIC_STUB_JOB_SPEED")
        }

        let script = Self.repoRoot.appendingPathComponent("stub-backend/run-stub.sh").path
        let env = AppEnvironment(
            modeOverride: .spawn(command: ["/bin/bash", "-lc",
                                           "exec \"\(script)\" \"$@\"",
                                           "local-music-engine"]),
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
        try await waitFor("job appears") { !env.jobsStore.active.isEmpty }
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

    /// Contract 5.3 + 5.6: cancelling still means the job produced no output.
    /// A take that was streaming previews leaves nothing behind either — unless
    /// the user explicitly keeps the partial, which is a decision about a file
    /// the app was already handed, not something inferred from the cancel.
    func testCancelKeepsNothingUnlessAskedToKeepThePartial() async throws {
        setenv("LOCALMUSIC_STUB_DOWNLOAD_S", "2", 1)
        setenv("LOCALMUSIC_STUB_PROVISION_S", "1", 1)
        setenv("LOCALMUSIC_STUB_JOB_SPEED", "4", 1)
        defer {
            unsetenv("LOCALMUSIC_STUB_DOWNLOAD_S")
            unsetenv("LOCALMUSIC_STUB_PROVISION_S")
            unsetenv("LOCALMUSIC_STUB_JOB_SPEED")
        }

        let script = Self.repoRoot.appendingPathComponent("stub-backend/run-stub.sh").path
        let env = AppEnvironment(
            modeOverride: .spawn(command: ["/bin/bash", "-lc",
                                           "exec \"\(script)\" \"$@\"",
                                           "local-music-engine"]),
            database: try DatabaseManager.inMemory())
        env.startBackend()
        try await waitFor("catalog") { !env.catalog.models.isEmpty }

        let model = try XCTUnwrap(
            env.catalog.models.first { $0.id == "musicgen-small" })
        XCTAssertTrue(model.capabilities.canPreview,
                      "fixture must be a model that can preview")
        await env.catalog.startDownload(model)
        try await waitFor("installed") {
            env.catalog.models.first { $0.id == "musicgen-small" }?
                .installState == .installed
        }

        func renderUntilFirstPreview() async throws -> String {
            let created = await env.jobsStore.submit(
                modelId: "musicgen-small", prompt: "cancel me", lyrics: nil,
                durationS: 30, count: 1, params: [:], preview: true)
            let jobId = try XCTUnwrap(created?.jobs.first?.jobId,
                                      "submit failed: \(env.jobsStore.lastError ?? "-")")
            try await waitFor("a preview frame") {
                env.jobsStore.active[jobId]?.preview != nil
            }
            return jobId
        }

        let before = env.library.recent.count
        let discarded = try await renderUntilFirstPreview()
        let frame = try XCTUnwrap(env.jobsStore.active[discarded]?.preview)
        XCTAssertTrue(FileManager.default.fileExists(atPath: frame.path),
                      "the engine wrote a real wav for the frame")
        await env.jobsStore.cancel(discarded)
        try await waitFor("cancel lands") {
            env.jobsStore.active[discarded]?.status == .canceled
        }
        XCTAssertNil(env.jobsStore.active[discarded]?.info.result,
                     "a canceled job has no result")
        XCTAssertEqual(env.library.recent.count, before,
                       "an ordinary cancel keeps nothing")

        let kept = try await renderUntilFirstPreview()
        let keptSong = await env.jobsStore.keepPartial(kept)
        let song = try XCTUnwrap(keptSong,
                                 "keep partial: \(env.jobsStore.lastError ?? "-")")
        try await waitFor("cancel lands") {
            env.jobsStore.active[kept]?.status == .canceled
        }
        XCTAssertEqual(env.library.recent.count, before + 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: song.fileURL.path),
                      "the partial moved into Library/Audio")
        XCTAssertGreaterThan(song.durationS, 0,
                             "duration comes from the frame, not the request")
        XCTAssertLessThan(song.durationS, 30,
                          "a partial is shorter than the take that was asked for")
        try? FileManager.default.removeItem(at: song.fileURL)

        await env.shutdown()
    }
}

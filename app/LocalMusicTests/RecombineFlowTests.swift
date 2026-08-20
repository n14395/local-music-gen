import XCTest
@testable import LocalMusic

/// Full recombine loop against the stub: two imported songs → mix job on
/// dsp-stub → recombined library song with ingredient provenance.
@MainActor
final class RecombineFlowTests: XCTestCase {
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

    private func makeWav(at url: URL, hz: Double, seconds: Double = 1.0,
                         rate: Int = 8000) throws {
        let n = Int(seconds * Double(rate))
        var samples = [Int16]()
        for i in 0..<n {
            let t = Double(i) / Double(rate)
            samples.append(Int16(sin(2 * .pi * hz * t) * 20000))
        }
        var data = Data()
        func put(_ s: String) { data.append(Data(s.utf8)) }
        func put32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func put16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        put("RIFF"); put32(UInt32(36 + n * 2)); put("WAVE")
        put("fmt "); put32(16); put16(1); put16(1)
        put32(UInt32(rate)); put32(UInt32(rate * 2)); put16(2); put16(16)
        put("data"); put32(UInt32(n * 2))
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        try data.write(to: url)
    }

    func testMashupOfTwoImportedSongs() async throws {
        setenv("LOCALMUSIC_STUB_DOWNLOAD_S", "1", 1)
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

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("recombine-flow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        try makeWav(at: dir.appendingPathComponent("one.wav"), hz: 440)
        try makeWav(at: dir.appendingPathComponent("two.wav"), hz: 220)
        let imported = await env.library.importSongs(
            urls: [dir.appendingPathComponent("one.wav"),
                   dir.appendingPathComponent("two.wav")])
        XCTAssertEqual(imported.count, 2)

        let model = try XCTUnwrap(
            env.catalog.models.first { $0.id == "dsp-stub" })
        XCTAssertTrue(model.capabilities.supportedTasks.contains("mix"))
        await env.catalog.startDownload(model)
        try await waitFor("dsp-stub installed") {
            env.catalog.models.first { $0.id == "dsp-stub" }?
                .installState == .installed
        }

        let ingredients = [
            IngredientSubmission(slotId: "a", partId: imported[0].id),
            IngredientSubmission(slotId: "b", partId: imported[1].id,
                                 gainDb: -6, offsetBeats: 4),
        ]
        let created = await env.jobsStore.submitRecombine(
            modelId: "dsp-stub", recipeId: "mashup", title: "Test Mashup",
            ingredients: ingredients)
        XCTAssertNotNil(created, env.jobsStore.lastError ?? "")

        // job row shows the mix title while running
        if let active = env.jobsStore.active.values.first(where: {
            ($0.info.task ?? "") == "mix"
        }) {
            XCTAssertEqual(env.jobsStore.displayTitle(for: active.info),
                           "Test Mashup")
        }

        try await waitFor("recombined song ingested") {
            (env.library.recent.first { $0.origin == "recombined" }) != nil
        }
        let song = try XCTUnwrap(
            env.library.recent.first { $0.origin == "recombined" })
        XCTAssertEqual(song.title, "Test Mashup")
        XCTAssertEqual(song.recipeId, "mashup")
        XCTAssertEqual(song.prompt, "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: song.fileURL.path),
                      "mixdown moved into Library/Audio")

        let rows = try env.partsRepo.ingredients(songId: song.id)
        XCTAssertEqual(Set(rows.map(\.slotId)), ["a", "b"])
        XCTAssertEqual(Set(rows.compactMap(\.partId)),
                       Set(imported.map(\.id)))
        for row in rows {
            XCTAssertFalse(row.sourceSongTitle.isEmpty)
            let applied = try BackendClient.decoder.decode(
                AppliedIngredient.self, from: Data(row.transformJSON.utf8))
            XCTAssertEqual(applied.submission.slotId, row.slotId)
        }

        // A timeline arrangement: one source placed three times with trims and
        // fades. Uploads dedupe by file, so repeats cost one upload — and the
        // (songId, slotId) primary key has to survive three rows of one part.
        let repeats = (0..<3).map { i in
            IngredientSubmission(
                slotId: "vocals-\(i + 1)", partId: imported[0].id,
                offsetBeats: Double(i) * 16.5,
                sectionStartS: 0.1, sectionEndS: 0.4,
                fadeInS: i == 0 ? nil : 0.05,
                fadeOutS: 0.05)
        }
        let arranged = await env.jobsStore.submitRecombine(
            modelId: "dsp-stub", recipeId: "workbench",
            title: "Timeline Arrangement", ingredients: repeats)
        XCTAssertNotNil(arranged, env.jobsStore.lastError ?? "")
        try await waitFor("arrangement ingested") {
            (env.library.recent.first { $0.title == "Timeline Arrangement" })
                != nil
        }
        let arrangement = try XCTUnwrap(
            env.library.recent.first { $0.title == "Timeline Arrangement" })
        let arrangedRows = try env.partsRepo.ingredients(songId: arrangement.id)
        XCTAssertEqual(arrangedRows.count, 3,
                       "three placements of one part are three rows")
        let restored = arrangedRows.compactMap { row in
            try? BackendClient.decoder.decode(
                AppliedIngredient.self, from: Data(row.transformJSON.utf8))
        }
        XCTAssertEqual(restored.count, 3)
        XCTAssertEqual(restored.map { $0.submission.offsetBeats }.sorted(),
                       [0, 16.5, 33])
        XCTAssertEqual(restored.compactMap { $0.submission.fadeOutS },
                       [0.05, 0.05, 0.05])
        // and it reopens as one lane of three clips
        let reopened = WorkbenchRestore.restore(
            applied: restored,
            materials: [imported[0].id: PickedMaterial(song: imported[0])],
            summaries: [:], sections: [:], fallbackBpm: 120)
        XCTAssertEqual(reopened.lanes.count, 1)
        XCTAssertEqual(reopened.clips.count, 3)

        env.library.delete(arrangement)
        env.library.delete(song)
        for song in imported { env.library.delete(song) }
        await env.shutdown()
    }
}

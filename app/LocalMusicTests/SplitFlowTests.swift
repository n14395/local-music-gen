import XCTest
@testable import LocalMusic

/// Full split loop against the stub: import a real file → split job →
/// stem parts ingested into Library/Parts, plus an explicit analyze job
/// landing an analysis attachment on the source song.
@MainActor
final class SplitFlowTests: XCTestCase {
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

    /// Minimal PCM16 mono WAV with a sine tone.
    private func makeWav(at url: URL, seconds: Double = 1.0,
                         rate: Int = 8000) throws {
        let n = Int(seconds * Double(rate))
        var samples = [Int16]()
        for i in 0..<n {
            let t = Double(i) / Double(rate)
            samples.append(Int16(sin(2 * .pi * 440 * t) * 20000))
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

    func testImportSplitAndAnalyze() async throws {
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

        // import a synthesized wav as a library song
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("split-flow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        let wav = dir.appendingPathComponent("field recording.wav")
        try makeWav(at: wav, seconds: 1.0)
        let imported = await env.library.importSongs(urls: [wav])
        XCTAssertEqual(imported.count, 1)
        let song = try XCTUnwrap(imported.first)
        XCTAssertEqual(song.origin, "imported")
        XCTAssertEqual(song.modelId, "imported")
        XCTAssertTrue(FileManager.default.fileExists(atPath: song.fileURL.path),
                      "imported audio copied into Library/Audio")

        // install the stub separation model
        let model = env.catalog.models.first { $0.id == "separation-stub" }!
        XCTAssertTrue(model.capabilities.supportedTasks.contains("separate"))
        await env.catalog.startDownload(model)
        try await waitFor("separation-stub installed") {
            env.catalog.models.first { $0.id == "separation-stub" }?
                .installState == .installed
        }

        // split
        await env.jobsStore.submitSplit(
            modelId: "separation-stub", songId: song.id,
            sourceTitle: song.title, sourceURL: song.fileURL, params: [:])
        try await waitFor("split job appears") { !env.jobsStore.active.isEmpty }
        try await waitFor("parts ingested") {
            ((try? env.partsStore.repository.allParts(forSong: song.id)) ?? [])
                .count >= 2
        }
        let parts = try env.partsStore.repository.allParts(forSong: song.id)
        XCTAssertTrue(parts.allSatisfy { $0.kind.hasPrefix("stem.") },
                      "stems carry the stem.* taxonomy: \(parts.map(\.kind))")
        XCTAssertTrue(parts.contains { $0.kind == "stem.vocals" })
        for part in parts {
            XCTAssertTrue(FileManager.default.fileExists(atPath: part.fileURL.path),
                          "part payload lives in Library/Parts")
            XCTAssertEqual(part.modelId, "separation-stub")
        }

        // job row title is action-shaped, not the (empty) prompt
        if let active = env.jobsStore.active.values.first(where: {
            ($0.info.task ?? "") == "separate"
        }) {
            XCTAssertEqual(env.jobsStore.displayTitle(for: active.info),
                           "Split: \(song.title)")
        }

        // analyze explicitly (auto-analyze is not wired in SR1)
        await env.jobsStore.submitAnalyze(
            modelId: "separation-stub", ownerId: song.id, ownerType: "song",
            title: song.title, sourceURL: song.fileURL)
        try await waitFor("analysis attached") {
            ((try? env.partsStore.repository.analysis(ownerId: song.id)) ?? nil) != nil
        }
        let analysis = try XCTUnwrap(
            (try? env.partsStore.repository.analysis(ownerId: song.id)) ?? nil)
        XCTAssertEqual(analysis.ownerType, "song")
        XCTAssertNotNil(analysis.bpm, "scalar bpm column filled from payload")
        XCTAssertNotNil(analysis.camelot)

        // parts store shows the results
        env.partsStore.refresh()
        XCTAssertGreaterThanOrEqual(env.partsStore.results.count, 2)

        // cleanup files created under real StoragePaths
        for part in parts { env.partsStore.delete(part) }
        env.library.delete(song)

        await env.shutdown()
    }
}

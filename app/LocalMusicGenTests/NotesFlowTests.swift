// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import LocalMusicGen

/// Notes loop against the stub: transcribe a song into midi parts (with
/// paired audition previews), then render one of them back to audio as a
/// layer part of the same song.
@MainActor
final class NotesFlowTests: XCTestCase {
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

    func testTranscribeAndRender() async throws {
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

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("notes-flow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        let wav = dir.appendingPathComponent("hummed idea.wav")
        try makeWav(at: wav, seconds: 1.0)
        let imported = await env.library.importSongs(urls: [wav])
        let song = try XCTUnwrap(imported.first)

        for id in ["transcription-stub", "render-stub"] {
            let model = try XCTUnwrap(env.catalog.models.first { $0.id == id })
            await env.catalog.startDownload(model)
            try await waitFor("\(id) installed") {
                env.catalog.models.first { $0.id == id }?
                    .installState == .installed
            }
        }

        // transcribe → midi parts with paired previews
        let created = await env.jobsStore.submitTranscribe(
            modelId: "transcription-stub", songId: song.id,
            sourceTitle: song.title, sourceURL: song.fileURL, params: [:])
        XCTAssertNotNil(created,
                        "submit failed: \(env.jobsStore.lastError ?? "-")")
        try await waitFor("notes parts ingested") {
            ((try? env.partsStore.repository.allParts(forSong: song.id)) ?? [])
                .contains { $0.kind.hasPrefix("notes.") }
        }
        let noteParts = try env.partsStore.repository
            .allParts(forSong: song.id).filter { $0.kind.hasPrefix("notes.") }
        XCTAssertEqual(Set(noteParts.map(\.kind)),
                       ["notes.melody", "notes.drums"])
        for part in noteParts {
            XCTAssertEqual(part.format, "midi")
            XCTAssertTrue(FileManager.default.fileExists(atPath: part.fileURL.path))
            XCTAssertNotNil(part.previewFileName,
                            "midi part paired with an audition preview")
            let audition = try XCTUnwrap(part.auditionURL,
                                         "midi part has an audition URL")
            XCTAssertTrue(FileManager.default.fileExists(atPath: audition.path),
                          "preview wav exists for audition")
        }

        // render one back to audio → a layer part of the same song
        let melody = try XCTUnwrap(noteParts.first { $0.kind == "notes.melody" })
        await env.jobsStore.submitRender(
            modelId: "render-stub", part: melody, sourceTitle: song.title)
        try await waitFor("rendered layer part ingested") {
            ((try? env.partsStore.repository.allParts(forSong: song.id)) ?? [])
                .contains { $0.kind.hasPrefix("layer.") }
        }
        let layer = try XCTUnwrap(
            try env.partsStore.repository.allParts(forSong: song.id)
                .first { $0.kind.hasPrefix("layer.") })
        XCTAssertEqual(layer.format, "wav")
        XCTAssertEqual(layer.modelId, "render-stub")
        XCTAssertTrue(FileManager.default.fileExists(atPath: layer.fileURL.path))

        // cleanup
        for part in try env.partsStore.repository.allParts(forSong: song.id) {
            env.partsStore.delete(part)
        }
        env.library.delete(song)
        await env.shutdown()
    }
}

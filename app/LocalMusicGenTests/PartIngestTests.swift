// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import LocalMusicGen

@MainActor
final class PartIngestTests: XCTestCase {
    private var createdFiles: [URL] = []

    override func tearDown() {
        for url in createdFiles {
            try? FileManager.default.removeItem(at: url)
        }
        createdFiles = []
        super.tearDown()
    }

    private func makeStores() throws -> (JobsStore, PartsRepository, LibraryRepository) {
        let db = try DatabaseManager.inMemory()
        let library = LibraryRepository(db: db)
        let parts = PartsRepository(db: db)
        return (JobsStore(repo: library, partsRepo: parts), parts, library)
    }

    private func writeTemp(_ name: String, _ data: Data,
                           in dir: URL) throws -> String {
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url.path
    }

    private func jobInfo(id: String, task: String,
                         result: JobResult) -> JobInfo {
        JobInfo(jobId: id, groupId: "grp_1", modelId: "separation-test",
                task: task, status: .succeeded, queuePosition: nil, prompt: "",
                lyrics: nil, durationS: nil, count: 1,
                params: ["source_audio": .string("/resolved/input.wav"),
                         "two_stems": .string("vocals")],
                createdAt: "2026-08-17T00:00:00Z", progress: nil,
                result: result, error: nil)
    }

    func testSplitArtifactsBecomeParts() throws {
        let (jobs, parts, library) = try makeStores()
        try library.insert(SongRecord(
            id: "song1", title: "Source", prompt: "p", lyrics: nil,
            modelId: "m", modelName: "M", groupId: nil, paramsJSON: "{}",
            durationS: 10, sampleRate: 44100, fileName: "song1.wav",
            seedUsed: nil, createdAt: Date(), rating: 0, notes: "",
            favorite: false))

        let outDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ingest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outDir,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outDir) }

        let junk = Data(repeating: 7, count: 128)
        let analysisJSON = Data("""
            {"tempo_bpm": 123.5, "beats": [0.1, 0.6], "downbeats": [0.1],
             "key": "F# minor", "camelot": "11A", "lufs": -14.2}
            """.utf8)
        let result = JobResult(
            outputs: nil,
            artifacts: [
                JobArtifact(kind: "stem", label: "vocals",
                            path: try writeTemp("vocals.wav", junk, in: outDir),
                            format: "wav", sampleRate: 44100, durationS: 10),
                JobArtifact(kind: "stem", label: "drums",
                            path: try writeTemp("drums.wav", junk, in: outDir),
                            format: "wav", sampleRate: 44100, durationS: 10),
                JobArtifact(kind: "midi", label: "piano",
                            path: try writeTemp("piano.mid", junk, in: outDir),
                            format: "mid", sampleRate: nil, durationS: nil),
                JobArtifact(kind: "audio", label: "preview:piano",
                            path: try writeTemp("piano-preview.wav", junk,
                                                in: outDir),
                            format: "wav", sampleRate: 44100, durationS: 10),
                JobArtifact(kind: "analysis", label: "analysis",
                            path: try writeTemp("analysis.json", analysisJSON,
                                                in: outDir),
                            format: "json", sampleRate: nil, durationS: nil),
            ],
            meta: ["tempo_bpm": .double(123.5)], timings: [:])

        jobs.pendingContext["job_1"] = .split(songId: "song1",
                                              sourceTitle: "Source")
        var ingested: [PartRecord] = []
        jobs.onPartsIngested = { ingested = $0 }
        jobs.ingestArtifacts(job: jobInfo(id: "job_1", task: "separate",
                                          result: result),
                             result: result)

        XCTAssertEqual(ingested.count, 3)
        createdFiles += ingested.map(\.fileURL)
        createdFiles += ingested.compactMap(\.previewURL)

        let vocal = ingested.first { $0.kind == "stem.vocals" }
        XCTAssertNotNil(vocal)
        // A part is named after the song it was cut from and what it is —
        // "Vocals" alone named a kind, and every song in the library had one.
        XCTAssertEqual(vocal?.name, "vocals-source")
        XCTAssertTrue(FileManager.default.fileExists(atPath: vocal!.fileURL.path))

        let piano = ingested.first { $0.kind == "notes.piano" }
        XCTAssertEqual(piano?.format, "midi")
        // Notes carry their family, so the audio a later render makes from
        // them has a name left to take.
        XCTAssertEqual(piano?.name, "piano-notes-source")
        XCTAssertEqual(Set(ingested.map(\.name)).count, ingested.count,
                       "one split must not hand out one name twice")
        XCTAssertNotNil(piano?.previewFileName, "preview must pair to the midi part")
        XCTAssertTrue(FileManager.default.fileExists(atPath: piano!.previewURL!.path))

        // Analysis attached to the source song and copied to audio stems.
        let songAnalysis = try parts.analysis(ownerId: "song1")
        XCTAssertEqual(songAnalysis?.bpm, 123.5)
        XCTAssertEqual(songAnalysis?.camelot, "11A")
        let stemAnalysis = try parts.analysis(ownerId: vocal!.id)
        XCTAssertEqual(stemAnalysis?.bpm, 123.5)
        XCTAssertEqual(stemAnalysis?.ownerType, "part")
        XCTAssertNil(try parts.analysis(ownerId: piano!.id),
                     "midi parts don't get the audio grid")

        // Provenance params keep scalars, drop resolved paths.
        XCTAssertTrue(vocal!.splitParamsJSON.contains("two_stems"))
        XCTAssertFalse(vocal!.splitParamsJSON.contains("/resolved"))
    }

    func testAnalyzeContextUpsertsOwnerAnalysis() throws {
        let (jobs, parts, library) = try makeStores()
        try library.insert(SongRecord(
            id: "song2", title: "Imported", prompt: "", lyrics: nil,
            modelId: "imported", modelName: "Imported", groupId: nil,
            paramsJSON: "{}", durationS: 10, sampleRate: 44100,
            fileName: "song2.wav", seedUsed: nil, createdAt: Date(), rating: 0,
            notes: "", favorite: false, origin: "imported"))
        let outDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ingest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outDir,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outDir) }
        let analysisJSON = Data(#"{"tempo_bpm": 98.0, "key": "C major"}"#.utf8)
        let result = JobResult(
            outputs: nil,
            artifacts: [JobArtifact(
                kind: "analysis", label: "analysis",
                path: try writeTemp("analysis.json", analysisJSON, in: outDir),
                format: "json", sampleRate: nil, durationS: nil)],
            meta: nil, timings: [:])

        jobs.pendingContext["job_2"] = .analyze(ownerId: "song2",
                                                ownerType: "song",
                                                title: "Imported")
        jobs.ingestArtifacts(job: jobInfo(id: "job_2", task: "analyze",
                                          result: result),
                             result: result)
        let record = try parts.analysis(ownerId: "song2")
        XCTAssertEqual(record?.bpm, 98.0)
        XCTAssertEqual(record?.keyName, "C major")
    }
}

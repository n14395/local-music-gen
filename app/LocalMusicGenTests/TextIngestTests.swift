// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import LocalMusicGen

/// Text-artifact ingest: a finished caption/lyrics/tag job becomes a
/// `textDoc` row, the temp file goes away, and the hook fires — the same
/// contract `PartIngestTests` pins for stems and analysis.
@MainActor
final class TextIngestTests: XCTestCase {
    private func makeStores() throws
        -> (JobsStore, PartsRepository, LibraryRepository) {
        let db = try DatabaseManager.inMemory()
        let library = LibraryRepository(db: db)
        let parts = PartsRepository(db: db)
        return (JobsStore(repo: library, partsRepo: parts), parts, library)
    }

    private func insertSong(_ library: LibraryRepository,
                            id: String = "song1") throws {
        try library.insert(SongRecord(
            id: id, title: "Source", prompt: "p", lyrics: nil,
            modelId: "m", modelName: "M", groupId: nil, paramsJSON: "{}",
            durationS: 10, sampleRate: 44100, fileName: "\(id).wav",
            seedUsed: nil, createdAt: Date(), rating: 0, notes: "",
            favorite: false))
    }

    private func writeTemp(_ name: String, _ json: String,
                           in dir: URL) throws -> String {
        let url = dir.appendingPathComponent(name)
        try Data(json.utf8).write(to: url)
        return url.path
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("text-ingest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func jobInfo(id: String, task: String, modelId: String = "cap",
                         result: JobResult) -> JobInfo {
        JobInfo(jobId: id, groupId: "grp_1", modelId: modelId,
                task: task, status: .succeeded, queuePosition: nil, prompt: "",
                lyrics: nil, durationS: nil, count: 1, params: [:],
                createdAt: "2026-08-24T00:00:00Z", progress: nil,
                result: result, error: nil)
    }

    func testCaptionArtifactBecomesADescriptionDoc() throws {
        let (jobs, parts, library) = try makeStores()
        try insertSong(library)
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = try writeTemp("caption.json", """
            {"text_version": 1, "kind": "caption",
             "text": "  dusty rhodes over swung drums  ",
             "model": "cap", "engine": "stub"}
            """, in: dir)
        var hooked: [TextDocRecord] = []
        jobs.onTextIngested = { hooked = $0 }
        jobs.pendingContext["job_c"] = .text(TextJobContext(
            ownerId: "song1", ownerType: "song", title: "Source",
            kind: .description))
        jobs.ingestArtifacts(
            job: jobInfo(id: "job_c", task: "caption",
                         result: JobResult(outputs: nil, artifacts: [],
                                           meta: nil, timings: [:])),
            result: JobResult(
                outputs: nil,
                artifacts: [JobArtifact(kind: "text", label: "caption",
                                        path: path, format: "json",
                                        sampleRate: nil, durationS: nil)],
                meta: nil, timings: [:]))

        let docs = try parts.textDocs(ownerId: "song1")
        XCTAssertEqual(docs.count, 1)
        XCTAssertEqual(docs.first?.kind, "description")
        // context kind wins over the payload's own "caption"
        XCTAssertEqual(docs.first?.kindValue, .description)
        XCTAssertEqual(docs.first?.text, "dusty rhodes over swung drums")
        XCTAssertEqual(docs.first?.jobId, "job_c")
        XCTAssertEqual(hooked.map(\.id), docs.map(\.id))
        // the artifact file is consumed, like an analysis artifact
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testEmptyTextInsertsNothing() throws {
        let (jobs, parts, library) = try makeStores()
        try insertSong(library)
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = try writeTemp("lyrics.json", """
            {"text_version": 1, "kind": "lyrics", "text": "  ",
             "language": "en"}
            """, in: dir)
        var hookFired = false
        jobs.onTextIngested = { _ in hookFired = true }
        jobs.pendingContext["job_e"] = .text(TextJobContext(
            ownerId: "song1", ownerType: "song", title: "Source",
            kind: .lyrics))
        jobs.ingestArtifacts(
            job: jobInfo(id: "job_e", task: "lyrics",
                         result: JobResult(outputs: nil, artifacts: [],
                                           meta: nil, timings: [:])),
            result: JobResult(
                outputs: nil,
                artifacts: [JobArtifact(kind: "text", label: "lyrics",
                                        path: path, format: "json",
                                        sampleRate: nil, durationS: nil)],
                meta: nil, timings: [:]))

        XCTAssertEqual(try parts.textDocs(ownerId: "song1").count, 0)
        // the hook still fires (with nothing) — the job itself succeeded
        XCTAssertTrue(hookFired)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testLyricsSegmentsSurviveTheRoundTrip() throws {
        let (jobs, parts, library) = try makeStores()
        try insertSong(library)
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = try writeTemp("lyrics.json", """
            {"kind": "lyrics", "text": "la la\\nooh", "language": "en",
             "segments": [{"start_s": 0.0, "end_s": 2.0, "text": "la la"},
                          {"start_s": 2.0, "end_s": 4.0, "text": "ooh"}]}
            """, in: dir)
        jobs.pendingContext["job_l"] = .text(TextJobContext(
            ownerId: "song1", ownerType: "song", title: "Source",
            kind: .lyrics))
        jobs.ingestArtifacts(
            job: jobInfo(id: "job_l", task: "lyrics",
                         result: JobResult(outputs: nil, artifacts: [],
                                           meta: nil, timings: [:])),
            result: JobResult(
                outputs: nil,
                artifacts: [JobArtifact(kind: "text", label: "lyrics",
                                        path: path, format: "json",
                                        sampleRate: nil, durationS: nil)],
                meta: nil, timings: [:]))

        let doc = try XCTUnwrap(parts.textDocs(ownerId: "song1").first)
        XCTAssertEqual(doc.language, "en")
        XCTAssertEqual(doc.segments.count, 2)
        XCTAssertEqual(doc.segments.first?.startS, 0.0)
        XCTAssertEqual(doc.segments.last?.text, "ooh")
    }

    func testTagJobMergesIntoSongTagsWithoutClobbering() throws {
        let (jobs, parts, library) = try makeStores()
        try insertSong(library)
        try library.setTags(["handmade", "techno"], for: "song1")
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = try writeTemp("tags.json", """
            {"kind": "tags",
             "tags": [{"label": "Techno", "score": 0.9, "group": "genre"},
                      {"label": "dark", "score": 0.7, "group": "mood"},
                      {"label": "maybe-flute", "score": 0.1,
                       "group": "instrument"},
                      {"label": "synth", "score": null, "group": null}]}
            """, in: dir)
        jobs.pendingContext["job_t"] = .text(TextJobContext(
            ownerId: "song1", ownerType: "song", title: "Source",
            kind: .tags, applyTags: true))
        jobs.ingestArtifacts(
            job: jobInfo(id: "job_t", task: "tag", modelId: "tag-clap",
                         result: JobResult(outputs: nil, artifacts: [],
                                           meta: nil, timings: [:])),
            result: JobResult(
                outputs: nil,
                artifacts: [JobArtifact(kind: "text", label: "tags",
                                        path: path, format: "json",
                                        sampleRate: nil, durationS: nil)],
                meta: nil, timings: [:]))

        // union: user tags stay untouched; "Techno" dedupes
        // case-insensitively; the 0.1 guess is dropped; null score passes.
        // (Storage returns tags sorted, so compare contents, not order.)
        let tags = try library.tags(for: "song1")
        XCTAssertEqual(tags, ["dark", "handmade", "synth", "techno"])
        // and the full scored list is kept as a document
        let doc = try XCTUnwrap(parts.textDocs(ownerId: "song1").first)
        XCTAssertEqual(doc.kindValue, .tags)
        XCTAssertTrue(doc.text.contains("maybe-flute"))
    }

    func testSplitContextSavesAnAbcDocBesideItsParts() throws {
        let (jobs, parts, library) = try makeStores()
        try insertSong(library)
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let junk = Data(repeating: 7, count: 128)
        let midiPath = dir.appendingPathComponent("melody.mid")
        try junk.write(to: midiPath)
        let abcPath = try writeTemp("abc-melody.json", """
            {"kind": "abc", "text": "X:1\\nT:Tune\\nK:C\\nCDEF|"}
            """, in: dir)
        var hooked: [TextDocRecord] = []
        jobs.onTextIngested = { hooked = $0 }
        jobs.pendingContext["job_a"] = .split(songId: "song1",
                                              sourceTitle: "Source")
        jobs.ingestArtifacts(
            job: jobInfo(id: "job_a", task: "transcribe",
                         result: JobResult(outputs: nil, artifacts: [],
                                           meta: nil, timings: [:])),
            result: JobResult(
                outputs: nil,
                artifacts: [
                    JobArtifact(kind: "midi", label: "melody",
                                path: midiPath.path, format: "mid",
                                sampleRate: nil, durationS: nil),
                    JobArtifact(kind: "text", label: "abc:melody",
                                path: abcPath, format: "json",
                                sampleRate: nil, durationS: nil),
                ],
                meta: nil, timings: [:]))

        let docs = try parts.textDocs(ownerId: "song1")
        XCTAssertEqual(docs.count, 1)
        XCTAssertEqual(docs.first?.kindValue, .abc)
        XCTAssertTrue(docs.first?.text.hasPrefix("X:1") ?? false)
        XCTAssertEqual(hooked.count, 1)
        // the midi still became a part, as in any transcription
        XCTAssertEqual(try parts.allParts(forSong: "song1").count, 1)
    }

    func testTextDocBuilderPrefersContextQuestion() throws {
        let payload = TextPayload(kind: "caption", text: "it is in A minor",
                                  language: nil, segments: nil, tags: nil,
                                  question: "model-echoed?", model: "cap",
                                  engine: "stub")
        let doc = JobsStore.textDoc(
            from: payload,
            context: TextJobContext(ownerId: "s", ownerType: "song",
                                    title: "T", kind: .qa,
                                    question: "What key is this in?"),
            modelId: "cap", modelName: "Cap", jobId: "job_q")
        XCTAssertEqual(doc?.question, "What key is this in?")
        XCTAssertEqual(doc?.kindValue, .qa)
    }
}

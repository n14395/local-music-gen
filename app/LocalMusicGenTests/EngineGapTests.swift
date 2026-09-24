// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import LocalMusicGen

/// What the stores say about work that finished while nobody was listening.
///
/// The app and the engine are separate processes, and the event stream between
/// them drops: on sleep, on a crash, and on every relaunch while the engine
/// keeps running. Each case here is a piece of news the app never received —
/// and used to paper over with silence or with a claim of success.
@MainActor
final class EngineGapTests: XCTestCase {

    // MARK: downloads that ended during the gap

    private func downloadsStore() -> DownloadsStore { DownloadsStore() }

    private func progress(_ id: String, _ modelId: String,
                          done: Int64 = 3_000, total: Int64 = 9_000,
                          runtimeOnly: Bool = false) -> EngineEvent {
        .downloadProgress(DownloadInfo(
            downloadId: id, modelId: modelId, state: .downloading,
            bytesDone: done, bytesTotal: total, speedBps: 100,
            stage: "downloading", message: nil, runtimeOnly: runtimeOnly))
    }

    /// The engine drops a finished download out of its own table, so all the
    /// listing can say is that it is gone; what is installed says which it was.
    func testACompletionMissedByTheStreamStillGetsARow() {
        let store = downloadsStore()
        store.installCompleted = { modelId, _ in modelId == "m1" }
        store.apply(progress("dl_1", "m1"))

        store.applyListing([])

        XCTAssertEqual(store.finished.count, 1)
        XCTAssertEqual(store.finished.first?.outcome, .completed)
        XCTAssertEqual(store.finished.first?.bytes, 9_000,
                       "a completed transfer is worth its total, not its "
                       + "last progress frame")
        XCTAssertNil(store.failure(forModel: "m1"))
        XCTAssertTrue(store.downloads.isEmpty)
    }

    func testAFailureMissedByTheStreamIsReportedAsOne() {
        let store = downloadsStore()
        store.installCompleted = { _, _ in false }
        store.apply(progress("dl_1", "m1"))

        store.applyListing([])

        XCTAssertEqual(store.finished.count, 1)
        XCTAssertEqual(store.finished.first?.isFailure, true)
        XCTAssertEqual(store.finished.first?.bytes, 3_000,
                       "a failure is worth whatever arrived")
        XCTAssertNotNil(store.failure(forModel: "m1"),
                        "the Models row has to be able to say why")
    }

    /// A runtime install finishes when the *runtime* is installed; its model's
    /// weights may never have been fetched at all (contract §4.2).
    func testARuntimeInstallIsJudgedOnItsRuntime() {
        let store = downloadsStore()
        store.installCompleted = { _, runtimeOnly in runtimeOnly }
        store.apply(progress("dl_1", "m1", runtimeOnly: true))

        store.applyListing([])

        XCTAssertEqual(store.finished.first?.outcome, .completed)
        XCTAssertEqual(store.finished.first?.isRuntimeOnly, true)
    }

    func testATransferStillRunningIsLeftAlone() {
        let store = downloadsStore()
        store.apply(progress("dl_1", "m1"))
        guard let live = store.downloads["dl_1"] else {
            return XCTFail("the progress frame was not adopted")
        }

        store.applyListing([live])

        XCTAssertTrue(store.finished.isEmpty)
        XCTAssertEqual(store.downloads.count, 1)
    }

    /// The 5-second auto-clear loop keeps running for as long as this says
    /// true, so with the policy off it has to say false — `JobsStore`'s
    /// sibling always has.
    func testTheSweepStopsWhenTheAutoClearPolicyIsOff() {
        let store = downloadsStore()
        store.apply(.downloadCompleted(downloadId: "dl_1", modelId: "m1",
                                       runtimeOnly: false))
        XCTAssertFalse(store.sweepFinished(),
                       "no policy means nothing left to watch for")
        XCTAssertEqual(store.finished.count, 1, "and the row stays put")

        store.autoClearAfterS = { 60 }
        XCTAssertTrue(store.sweepFinished(),
                      "with a policy there is a row to come back to")
    }

    // MARK: telemetry with no engine behind it

    func testTelemetryForgetsTheLiveReadingsOnDisconnect() throws {
        let telemetry = TelemetryStore()
        telemetry.apply(try SystemInfoFixture.make())
        XCTAssertNotNil(telemetry.gpuPercent)
        XCTAssertNotNil(telemetry.workerBytes)

        telemetry.reset()

        XCTAssertNil(telemetry.gpuPercent)
        XCTAssertNil(telemetry.workerBytes)
        XCTAssertNil(telemetry.acceleratorBytes)
        XCTAssertNil(telemetry.memoryFraction,
                     "nothing is using memory once the engine is gone")
        XCTAssertEqual(telemetry.machine, "Mac16,6",
                       "the Mac is still the Mac")
        XCTAssertNotNil(telemetry.ramBytes)
    }

    // MARK: a job whose routing context did not survive the gap

    private func jobInfo(id: String, task: String,
                         result: JobResult) -> JobInfo {
        JobInfo(jobId: id, groupId: "grp_1", modelId: "separation-test",
                task: task, status: .succeeded, queuePosition: nil, prompt: "",
                lyrics: nil, durationS: nil, count: 1, params: [:],
                createdAt: "2026-09-16T00:00:00Z", progress: nil,
                result: result, error: nil)
    }

    private func artifact(_ kind: String) -> JobArtifact {
        JobArtifact(kind: kind, label: kind, path: "/nonexistent/\(kind)",
                    format: "wav", sampleRate: 44100, durationS: 1)
    }

    /// `pendingContext` is in-memory only, so a split adopted after a relaunch
    /// has nowhere to put its stems. It used to be marked succeeded and its
    /// artifacts dropped: a green row over lost work.
    func testATaskJobWithNoRoutingContextFailsRatherThanClaimingSuccess()
        throws {
        let db = try DatabaseManager.inMemory()
        let jobs = JobsStore(repo: LibraryRepository(db: db),
                             partsRepo: PartsRepository(db: db))
        let result = JobResult(outputs: nil, artifacts: [artifact("stem")],
                               meta: nil, timings: [:])
        let info = jobInfo(id: "job_1", task: "separate", result: result)
        jobs.adopt(JobsStore.ActiveJob(info: info, progress: nil,
                                       status: .succeeded))

        jobs.ingestArtifacts(job: info, result: result)

        XCTAssertEqual(jobs.job("job_1")?.status, .failed)
        XCTAssertNotNil(jobs.job("job_1")?.error?.message)
        XCTAssertNil(jobs.lastError,
                     "an ingest failure is the row's news, not the Action "
                     + "screens' submit banner")
    }

    /// The other half: `assist` and `plan` answer in `result.meta`, which
    /// `MetaJobRunner` reads itself. Their rows are only in the queue because
    /// it adopts every job the engine announces, and they lose nothing.
    func testAMetaOnlyJobWithNoContextIsStillASuccess() throws {
        let db = try DatabaseManager.inMemory()
        let jobs = JobsStore(repo: LibraryRepository(db: db),
                             partsRepo: PartsRepository(db: db))
        let result = JobResult(outputs: nil, artifacts: [artifact("assist")],
                               meta: ["assist": .string("{}")], timings: [:])
        let info = jobInfo(id: "job_2", task: "assist", result: result)
        jobs.adopt(JobsStore.ActiveJob(info: info, progress: nil,
                                       status: .succeeded))

        jobs.ingestArtifacts(job: info, result: result)

        XCTAssertEqual(jobs.job("job_2")?.status, .succeeded)
    }

    // MARK: the upload the engine would refuse

    func testAnOversizedSourceIsRefusedBeforeItIsTransferred() throws {
        let cap = BackendClient.maxUploadBytes
        XCTAssertNil(JobsStore.uploadTooLargeMessage(fileName: "take.wav",
                                                     bytes: cap),
                     "exactly the cap still fits — the engine's test is `>`")
        let said = try XCTUnwrap(
            JobsStore.uploadTooLargeMessage(fileName: "take.wav",
                                            bytes: cap + 1))
        XCTAssertTrue(said.contains("take.wav"),
                      "name the file, not just the limit: \(said)")
        XCTAssertTrue(said.contains("MB"),
                      "say the sizes in units the user reads: \(said)")
    }
}

/// A `/v1/system` payload, decoded the way `BackendClient` decodes the real
/// one — the DTO's own key mapping is part of what these tests rely on.
enum SystemInfoFixture {
    static func make(json: String = defaultJSON) throws -> SystemInfo {
        try BackendClient.decoder.decode(SystemInfo.self, from: Data(json.utf8))
    }

    static let defaultJSON = """
        {"ram_bytes": 36000000000, "free_disk_bytes": 100000000000,
         "machine": "Mac16,6", "warm_family": null, "warm_model_id": null,
         "transient_model_ids": [], "pinned_model_id": null,
         "active_job_id": null, "engine_versions": {},
         "accelerator": {"name": "Apple M4 Pro", "backend": "mps",
                         "working_set_bytes": 25000000000},
         "usage": {"gpu_percent": 92.0, "worker_bytes": 11800000000,
                   "accelerator_bytes": 12000000000}}
        """
}

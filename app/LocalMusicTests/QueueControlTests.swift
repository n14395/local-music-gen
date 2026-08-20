import XCTest
@testable import LocalMusic

/// The one queue: what a drag does to the run order, what a waiting download is
/// allowed to claim, and — end to end against the stub — that a hold stops the
/// queue starting work and a reorder decides what runs when it is released.
@MainActor
final class QueueControlTests: XCTestCase {

    // MARK: - Where a dragged job lands

    func testDroppingDownwardsTakesThatRowsPlace() {
        XCTAssertEqual(QueueReorder.order(["a", "b", "c"], moving: "a", onto: "b"),
                       ["b", "a", "c"])
    }

    func testDroppingUpwardsTakesThatRowsPlace() {
        XCTAssertEqual(QueueReorder.order(["a", "b", "c"], moving: "c", onto: "a"),
                       ["c", "a", "b"])
    }

    func testADropOnItselfIsNotAReorder() {
        XCTAssertNil(QueueReorder.order(["a", "b"], moving: "a", onto: "a"))
    }

    /// The job at the top of the queue can legitimately start while the pointer
    /// is still down, which takes it out of the reorderable list.
    func testADropInvolvingAJobThatIsNoLongerQueuedIsNotAReorder() {
        XCTAssertNil(QueueReorder.order(["b", "c"], moving: "a", onto: "b"))
        XCTAssertNil(QueueReorder.order(["b", "c"], moving: "b", onto: "a"))
    }

    // MARK: - What a waiting download may claim

    func testTransfersSortAheadOfWhateverIsWaiting() {
        let waiting = Self.download(id: "dl_2", state: .queued)
        let moving = Self.download(id: "dl_9", state: .downloading)
        XCTAssertEqual(JobQueueSection.ordered([waiting, moving]).map(\.id),
                       ["dl_9", "dl_2"])
    }

    func testPauseIsDeadOverAnInstallOrAWait() {
        XCTAssertNil(DownloadFormat.pauseBlockedReason(.downloading))
        XCTAssertNil(DownloadFormat.pauseBlockedReason(.paused))
        XCTAssertNotNil(DownloadFormat.pauseBlockedReason(.provisioning))
        XCTAssertNotNil(DownloadFormat.pauseBlockedReason(.queued))
    }

    private static func download(id: String, state: DownloadState) -> DownloadInfo {
        let json = """
        {"download_id": "\(id)", "model_id": "m", "state": "\(state.rawValue)",
         "bytes_done": 0, "bytes_total": 100, "speed_bps": 0, "stage": "weights"}
        """
        return try! BackendClient.decoder.decode(DownloadInfo.self,
                                                 from: Data(json.utf8))
    }

    // MARK: - Hold and reorder, end to end

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

    /// Contract §5.7 + §5.8. The point of the pair: a hold buys the time to
    /// reorder, and the order the user leaves behind is the order that runs.
    func testHoldStopsTheQueueAndAReorderPicksWhatRunsFirst() async throws {
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

        let model = try XCTUnwrap(env.catalog.models.first { $0.id == "musicgen-small" })
        await env.catalog.startDownload(model)
        try await waitFor("installed") {
            env.catalog.models.first { $0.id == "musicgen-small" }?
                .installState == .installed
        }

        await env.jobsStore.holdQueue(true)
        XCTAssertTrue(env.jobsStore.queueHeld)

        var ids: [String] = []
        for take in 1...3 {
            let created = await env.jobsStore.submit(
                modelId: "musicgen-small", prompt: "queued take \(take)",
                lyrics: nil, durationS: 4, count: 1, params: [:])
            ids.append(try XCTUnwrap(created?.jobs.first?.jobId,
                                     "submit failed: \(env.jobsStore.lastError ?? "-")"))
        }
        try await waitFor("all three tracked") {
            env.jobsStore.reorderableJobs.count == 3
        }
        XCTAssertEqual(env.jobsStore.reorderableJobs.map(\.id), ids,
                       "submission order until someone says otherwise")

        // A held queue starts nothing: one job's worth of stub runtime passes
        // and all three are still where they were.
        try await Task.sleep(for: .seconds(3))
        XCTAssertEqual(env.jobsStore.reorderableJobs.count, 3,
                       "a hold stops the queue starting anything")
        XCTAssertNil(env.jobsStore.runningWhileHeld,
                     "nothing was running when the hold went on")

        let order = try XCTUnwrap(QueueReorder.order(ids, moving: ids[2],
                                                     onto: ids[0]))
        await env.jobsStore.reorder(order)
        // Positions arrive as job.queued for every queued job, not just the
        // dragged one — that re-announcement is what moves the rows.
        try await waitFor("the reorder is announced") {
            env.jobsStore.reorderableJobs.map(\.id) == order
        }

        await env.jobsStore.holdQueue(false)
        XCTAssertFalse(env.jobsStore.queueHeld)
        var started: String?
        try await waitFor("the queue releases") {
            started = env.jobsStore.displayJobs
                .first { $0.status != .queued && !$0.status.isTerminal }?.id
            return started != nil
        }
        XCTAssertEqual(started, ids[2], "the job dragged to the top runs first")

        for id in ids { await env.jobsStore.cancel(id) }
        await env.shutdown()
        // Anything that finished before the cancels landed was ingested for
        // real; the database is in memory but the audio is not.
        for song in env.library.recent {
            try? FileManager.default.removeItem(at: song.fileURL)
        }
    }
}

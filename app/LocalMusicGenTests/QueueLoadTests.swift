// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import LocalMusicGen

/// Every queue counter said "1 job" while a `count: 4` submission rendered four
/// tracks. The counters speak in takes now, and this is where that arithmetic
/// lives.
final class QueueLoadTests: XCTestCase {
    private func job(id: String = UUID().uuidString, count: Int,
                     status: JobStatus = .generating,
                     take: Int? = nil, group: String = "grp",
                     takeIndex: Int? = nil,
                     takeOf: Int? = nil) -> JobsStore.ActiveJob {
        let info = JobInfo(
            jobId: id, groupId: group, modelId: "acestep-base", task: "generate",
            status: status, prompt: "p", lyrics: nil, durationS: 10,
            count: count, params: [:], createdAt: "2026-08-19T10:00:00Z",
            progress: nil, result: nil, error: nil,
            takeIndex: takeIndex, takeOf: takeOf)
        let progress = take.map {
            JobProgress(stage: "generating", fraction: 0.5, etaS: 10,
                        message: "m", take: $0, phase: nil, step: nil,
                        steps: nil)
        }
        return JobsStore.ActiveJob(info: info, progress: progress,
                                   status: status, error: nil)
    }

    // MARK: counts

    func testOneJobOfFourTakesCountsAsFour() {
        let load = QueueLoad.of(jobs: [job(count: 4)])
        XCTAssertEqual(load.jobs, 1)
        XCTAssertEqual(load.takes, 4)
    }

    func testTakesLeftShrinksAsTheEngineAdvances() {
        XCTAssertEqual(QueueLoad.of(jobs: [job(count: 4, take: 0)]).takesLeft, 4)
        XCTAssertEqual(QueueLoad.of(jobs: [job(count: 4, take: 2)]).takesLeft, 2)
        XCTAssertEqual(QueueLoad.of(jobs: [job(count: 4, take: 3)]).takesLeft, 1)
    }

    /// A queued job, or an engine too old to report the take, must count the
    /// whole job rather than nothing.
    func testUnknownTakeCountsTheWholeJob() {
        XCTAssertEqual(QueueLoad.of(jobs: [job(count: 4, status: .queued)]).takesLeft, 4)
    }

    func testTerminalJobsAreNotWork() {
        let load = QueueLoad.of(jobs: [job(count: 3, status: .succeeded),
                                       job(count: 2, status: .canceled),
                                       job(count: 2, status: .generating)])
        XCTAssertEqual(load.jobs, 1)
        XCTAssertEqual(load.takes, 2)
    }

    /// Single-take jobs — and every task job, which is always count 1 — read
    /// exactly as they did before takes were counted.
    func testSingleTakeJobsAreUnchanged() {
        let load = QueueLoad.of(jobs: [job(count: 1), job(count: 1)])
        XCTAssertEqual(load.jobs, 2)
        XCTAssertEqual(load.takes, 2)
        XCTAssertEqual(load.takesLeft, 2)
    }

    /// A count of 0 or a negative one is not a job that does nothing.
    func testNonsenseCountStillCountsAsOneTake() {
        XCTAssertEqual(QueueLoad.of(jobs: [job(count: 0)]).takes, 1)
    }

    func testEmptyIsEmpty() {
        XCTAssertTrue(QueueLoad.of(jobs: []).isEmpty)
        XCTAssertFalse(QueueLoad.of(jobs: [], downloads: 1).isEmpty)
    }

    // MARK: labels

    func testRenderingLabelSpeaksInTakes() {
        XCTAssertEqual(QueueLoad.of(jobs: [job(count: 3)]).renderingLabel,
                       "Rendering 3 takes")
        XCTAssertEqual(QueueLoad.of(jobs: [job(count: 1)]).renderingLabel,
                       "Rendering 1 take")
    }

    /// Several submissions need both numbers — but one never says "1 render ·
    /// 3 takes", which makes the reader do arithmetic to learn nothing.
    func testRenderingLabelNamesBatchesOnlyWhenThereAreSeveral() {
        XCTAssertEqual(
            QueueLoad.of(jobs: [job(count: 3, group: "a"),
                                job(count: 2, group: "b")]).renderingLabel,
            "Rendering 2 renders · 5 takes")
        XCTAssertFalse(QueueLoad.of(jobs: [job(count: 3)]).renderingLabel
            .contains("render "))
    }

    /// The takes of one submission are separate jobs now, and three of them
    /// are still "3 takes" — not "3 renders · 3 takes", which says the same
    /// number twice and calls one press of Generate three things.
    func testOneBatchOfSingleTakeJobsReadsAsItsTakes() {
        let batch = (0..<3).map {
            job(count: 1, takeIndex: $0, takeOf: 3)
        }
        let load = QueueLoad.of(jobs: batch)
        XCTAssertEqual(load.takes, 3)
        XCTAssertEqual(load.batches, 1)
        XCTAssertEqual(load.renderingLabel, "Rendering 3 takes")
        XCTAssertEqual(load.headerLabel, "3 TAKES")
    }

    func testHeaderLabelCoversBothHalvesOfTheQueue() {
        XCTAssertEqual(QueueLoad.of(jobs: [job(count: 3)]).headerLabel, "3 TAKES")
        XCTAssertEqual(QueueLoad.of(jobs: [job(count: 1)]).headerLabel, "1 TAKE")
        XCTAssertEqual(QueueLoad.of(jobs: [job(count: 2)], downloads: 1).headerLabel,
                       "2 TAKES · 1 DOWNLOAD")
        XCTAssertEqual(QueueLoad.of(jobs: [], downloads: 2).headerLabel,
                       "2 DOWNLOADS")
        XCTAssertEqual(QueueLoad.of(jobs: []).headerLabel, "EMPTY")
    }

    // MARK: which take

    func testTakeLabelNamesThePosition() {
        XCTAssertEqual(job(count: 4, take: 0).takeLabel, "Take 1 of 4")
        XCTAssertEqual(job(count: 4, take: 3).takeLabel, "Take 4 of 4")
    }

    /// Nothing to say for a single take, and nothing to say before the engine
    /// has started one — guessing from `fraction` would be inventing it.
    func testTakeLabelSilentWhenThereIsNothingToDistinguish() {
        XCTAssertNil(job(count: 1, take: 0).takeLabel)
        XCTAssertNil(job(count: 4).takeLabel)
    }

    /// An out-of-range index must not print "take 5 of 4".
    func testTakeLabelClampsToTheJob() {
        XCTAssertEqual(job(count: 4, take: 9).takeLabel, "Take 4 of 4")
        XCTAssertEqual(job(count: 4, take: -1).takeLabel, "Take 1 of 4")
    }

    // MARK: which take, once a batch is one job per take

    /// The whole point of the fan-out: a QUEUED take already knows which take
    /// it is, where the old single-job row could not say until the engine was
    /// rendering it.
    func testTakeLabelComesOffAQueuedJob() {
        XCTAssertEqual(
            job(count: 1, status: .queued, takeIndex: 1, takeOf: 4).takeLabel,
            "Take 2 of 4")
    }

    func testTakeLabelSilentForASingleTakeSubmission() {
        XCTAssertNil(job(count: 1, takeIndex: 0, takeOf: 1).takeLabel)
    }

    func testTakeLabelClampsAStrayIndex() {
        XCTAssertEqual(job(count: 1, takeIndex: 9, takeOf: 4).takeLabel,
                       "Take 4 of 4")
        XCTAssertEqual(job(count: 1, takeIndex: -1, takeOf: 4).takeLabel,
                       "Take 1 of 4")
    }
}

/// How the queue's rows fall into batches — the header a fanned-out render is
/// drawn under, and the run of takes it covers.
final class QueueBatchesTests: XCTestCase {
    private func job(_ id: String, group: String = "grp",
                     takeIndex: Int? = nil, takeOf: Int? = nil,
                     status: JobStatus = .queued) -> JobsStore.ActiveJob {
        let info = JobInfo(
            jobId: id, groupId: group, modelId: "acestep-base", task: "generate",
            status: status, prompt: "p", lyrics: nil, durationS: 10,
            count: 1, params: [:], createdAt: "2026-08-19T10:00:00Z",
            progress: nil, result: nil, error: nil,
            takeIndex: takeIndex, takeOf: takeOf)
        return JobsStore.ActiveJob(info: info, progress: nil, status: status,
                                   error: nil)
    }

    func testTakesOfOneSubmissionGatherUnderOneGroup() {
        let groups = QueueBatches.of([
            job("a", takeIndex: 0, takeOf: 3),
            job("b", takeIndex: 1, takeOf: 3),
            job("c", takeIndex: 2, takeOf: 3),
        ])
        XCTAssertEqual(groups.count, 1)
        XCTAssertTrue(groups[0].isBatch)
        XCTAssertEqual(groups[0].jobs.map(\.id), ["a", "b", "c"])
    }

    /// A single-take render is one card with no header, exactly as before.
    func testSingleTakeJobsStandAlone() {
        let groups = QueueBatches.of([job("a", takeOf: 1), job("b", takeOf: 1)])
        XCTAssertEqual(groups.count, 2)
        XCTAssertFalse(groups[0].isBatch)
    }

    func testTwoSubmissionsAreTwoGroups() {
        let groups = QueueBatches.of([
            job("a", group: "one", takeIndex: 0, takeOf: 2),
            job("b", group: "one", takeIndex: 1, takeOf: 2),
            job("c", group: "two", takeIndex: 0, takeOf: 2),
            job("d", group: "two", takeIndex: 1, takeOf: 2),
        ])
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.map(\.groupId), ["one", "two"])
    }

    /// A batch really can be broken up — a job dragged into the middle of one
    /// runs in the middle of it (§5.8) — and the list must say so rather than
    /// quietly regrouping the takes and lying about the run order.
    func testAnInterleavedJobSplitsTheBatch() {
        let groups = QueueBatches.of([
            job("a", takeIndex: 0, takeOf: 3),
            job("other", group: "elsewhere", takeOf: 1),
            job("b", takeIndex: 1, takeOf: 3),
        ])
        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(groups.map(\.id), ["a", "other", "b"])
    }

    func testAGroupKnowsWhatIsLeftToCancel() {
        let done = QueueBatches.of([
            job("a", takeIndex: 0, takeOf: 2, status: .succeeded),
            job("b", takeIndex: 1, takeOf: 2, status: .canceled),
        ])
        XCTAssertFalse(done[0].hasUnfinished)
        XCTAssertFalse(done[0].isActive)
        let running = QueueBatches.of([
            job("a", takeIndex: 0, takeOf: 2, status: .succeeded),
            job("b", takeIndex: 1, takeOf: 2, status: .generating),
        ])
        XCTAssertTrue(running[0].hasUnfinished)
        XCTAssertTrue(running[0].isActive)
    }
}

/// The reported bug: a render fails, and the queue rail draws "Nothing queued"
/// over a failed card that is still in the store — so the failure is invisible
/// until a LATER submission makes the counter non-zero and the old card
/// reappears underneath the new one.
///
/// The counters and the emptiness test had been the same number. They are not
/// the same question: one is outstanding work, the other is how many rows
/// there are to draw.
final class QueueLoadFinishedTests: XCTestCase {
    private func job(id: String = UUID().uuidString, count: Int = 1,
                     status: JobStatus) -> JobsStore.ActiveJob {
        let info = JobInfo(
            jobId: id, groupId: "grp", modelId: "acestep-cpp-xl-sft",
            task: "generate", status: status, prompt: "p", lyrics: nil,
            durationS: 10, count: count, params: [:],
            createdAt: "2026-08-21T17:00:00Z", progress: nil, result: nil,
            error: nil)
        return JobsStore.ActiveJob(info: info, progress: nil, status: status,
                                   error: nil)
    }

    func testFailedJobIsNotAnEmptyQueue() {
        let load = QueueLoad.of(jobs: [job(status: .failed)])
        XCTAssertFalse(load.isEmpty, "a failed card still has to be drawn")
        XCTAssertEqual(load.finished, 1)
        XCTAssertEqual(load.failed, 1)
        // …and it is not outstanding work: nothing is rendering.
        XCTAssertEqual(load.jobs, 0)
        XCTAssertEqual(load.takes, 0)
        XCTAssertEqual(load.takesLeft, 0)
    }

    func testSucceededAndCancelledAlsoKeepTheListVisible() {
        for status in [JobStatus.succeeded, .canceled] {
            let load = QueueLoad.of(jobs: [job(status: status)])
            XCTAssertFalse(load.isEmpty, "\(status) row still needs drawing")
            XCTAssertEqual(load.finished, 1)
            // Only a failure is a failure — cancelling is something the user
            // did, and the transport must not shout about it.
            XCTAssertEqual(load.failed, 0)
        }
    }

    func testNothingAtAllIsStillEmpty() {
        XCTAssertTrue(QueueLoad.of(jobs: []).isEmpty)
        XCTAssertEqual(QueueLoad.of(jobs: []).headerLabel, "EMPTY")
    }

    /// A four-take job that failed contributes no takes to the header — the
    /// count is work still to do, and there is none.
    func testFailedMultiTakeJobContributesNoTakes() {
        let load = QueueLoad.of(jobs: [job(count: 4, status: .failed)])
        XCTAssertEqual(load.takes, 0)
        XCTAssertEqual(load.headerLabel, "1 FAILED")
    }

    func testHeaderCountsRunningAndFinishedTogether() {
        let load = QueueLoad.of(jobs: [job(count: 2, status: .generating),
                                       job(status: .failed),
                                       job(status: .succeeded)],
                                downloads: 1)
        XCTAssertEqual(load.headerLabel,
                       "2 TAKES · 1 DOWNLOAD · 1 FAILED · 1 FINISHED")
        XCTAssertFalse(load.isEmpty)
    }

    /// A finished transfer is a row like any other: the rail must not draw
    /// "Nothing queued" over a download waiting to be dismissed.
    func testAFinishedDownloadIsNotAnEmptyQueue() {
        let load = QueueLoad.of(jobs: [], downloads: 0, finishedDownloads: 1)
        XCTAssertFalse(load.isEmpty)
        XCTAssertEqual(load.finished, 1)
        XCTAssertEqual(load.headerLabel, "1 FINISHED")
    }

    func testFinishedDownloadsCountBesideFinishedRenders() {
        let load = QueueLoad.of(jobs: [job(status: .succeeded)],
                                downloads: 1, finishedDownloads: 2,
                                failedDownloads: 1)
        XCTAssertEqual(load.finished, 3)
        XCTAssertEqual(load.failed, 1)
        XCTAssertEqual(load.headerLabel, "1 DOWNLOAD · 1 FAILED · 2 FINISHED")
    }

    /// The transport capsule's priority: a render in flight is the more useful
    /// thing to watch, but with nothing running the failure is the truth.
    func testRunningWorkOutranksAFailureButIdleDoesNot() {
        let both = QueueLoad.of(jobs: [job(status: .generating),
                                       job(status: .failed)])
        XCTAssertEqual(both.jobs, 1)
        XCTAssertEqual(both.failed, 1)

        let onlyFailed = QueueLoad.of(jobs: [job(status: .failed),
                                             job(status: .failed)])
        XCTAssertEqual(onlyFailed.jobs, 0)
        XCTAssertEqual(onlyFailed.failed, 2)
    }
}

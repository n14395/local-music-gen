import XCTest
@testable import LocalMusic

/// Every queue counter said "1 job" while a `count: 4` submission rendered four
/// tracks. The counters speak in takes now, and this is where that arithmetic
/// lives.
final class QueueLoadTests: XCTestCase {
    private func job(id: String = UUID().uuidString, count: Int,
                     status: JobStatus = .generating,
                     take: Int? = nil) -> JobsStore.ActiveJob {
        let info = JobInfo(
            jobId: id, groupId: "grp", modelId: "acestep-base", task: "generate",
            status: status, prompt: "p", lyrics: nil, durationS: 10,
            count: count, params: [:], createdAt: "2026-08-19T10:00:00Z",
            progress: nil, result: nil, error: nil)
        let progress = take.map {
            JobProgress(stage: "generating", fraction: 0.5, etaS: 10,
                        message: "m", take: $0, phase: nil, step: nil,
                        steps: nil)
        }
        return JobsStore.ActiveJob(info: info, progress: progress,
                                   status: status, error: nil, preview: nil)
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

    /// Several jobs need both numbers — but one job never says "1 job · 3
    /// takes", which makes the reader do arithmetic to learn nothing.
    func testRenderingLabelNamesJobsOnlyWhenThereAreSeveral() {
        XCTAssertEqual(
            QueueLoad.of(jobs: [job(count: 3), job(count: 2)]).renderingLabel,
            "Rendering 2 jobs · 5 takes")
        XCTAssertFalse(QueueLoad.of(jobs: [job(count: 3)]).renderingLabel
            .contains("job"))
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
                                   error: nil, preview: nil)
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

import XCTest
@testable import LocalMusicGen

/// "Notify me when it lands" — the arming, and the ordering that made it a
/// no-op.
///
/// The button set a flag that was thrown away before anything read it:
/// `AppEnvironment.route` calls `jobsStore.apply(event)` and *then*
/// `notify(for:)`, while `apply` cleared the arming on `.jobCompleted`. So the
/// notifier's "was this armed?" check ran against a set that had just been
/// emptied, and always answered no. Pressing the button did nothing at all,
/// which is exactly how it was reported.
///
/// These tests reproduce that order rather than trusting a comment about it.
@MainActor
final class NotifyOnLandingTests: XCTestCase {
    private func store() throws -> JobsStore {
        let db = try DatabaseManager.inMemory()
        return JobsStore(repo: LibraryRepository(db: db),
                         partsRepo: PartsRepository(db: db))
    }

    func testArmingIsRememberedUntilSomethingSpendsIt() throws {
        let jobs = try store()
        jobs.setNotifyOnLanding("job_1", true)
        XCTAssertTrue(jobs.notifyOnLanding.contains("job_1"))
        jobs.setNotifyOnLanding("job_1", false)
        XCTAssertFalse(jobs.notifyOnLanding.contains("job_1"))
    }

    /// The regression. `apply` runs first in the real event path, so it must
    /// leave the arming alone for the notifier to find.
    func testCompletionDoesNotSpendTheArmingBeforeTheNotifierReadsIt() throws {
        let jobs = try store()
        jobs.setNotifyOnLanding("job_1", true)

        jobs.apply(.jobCompleted(jobId: "job_1"))

        XCTAssertTrue(jobs.takeNotifyOnLanding("job_1"),
                      "the notifier runs after apply and must still see it")
    }

    /// …and once spent, it stays spent: a set that only grew would carry every
    /// job id of a long session, and a second read must not re-notify.
    func testTheArmingIsSpentExactlyOnce() throws {
        let jobs = try store()
        jobs.setNotifyOnLanding("job_1", true)
        jobs.apply(.jobCompleted(jobId: "job_1"))

        XCTAssertTrue(jobs.takeNotifyOnLanding("job_1"))
        XCTAssertFalse(jobs.takeNotifyOnLanding("job_1"))
        XCTAssertTrue(jobs.notifyOnLanding.isEmpty)
    }

    /// A take that failed still landed, for someone who walked away — so the
    /// arming survives to the notifier there too.
    func testAFailedTakeStillCarriesItsArming() throws {
        let jobs = try store()
        jobs.setNotifyOnLanding("job_1", true)

        jobs.apply(.jobFailed(jobId: "job_1",
                              error: APIErrorBody(code: "X", message: "boom")))

        XCTAssertTrue(jobs.takeNotifyOnLanding("job_1"))
    }

    /// Cancelling is not landing. Nothing notifies, so `apply` is the only
    /// thing that can clear it and it has to.
    func testCancellingDropsTheArming() throws {
        let jobs = try store()
        jobs.setNotifyOnLanding("job_1", true)

        jobs.apply(.jobCanceled(jobId: "job_1"))

        XCTAssertFalse(jobs.takeNotifyOnLanding("job_1"))
        XCTAssertTrue(jobs.notifyOnLanding.isEmpty)
    }

    /// Arming one take says nothing about the others in the batch.
    func testArmingIsPerJob() throws {
        let jobs = try store()
        jobs.setNotifyOnLanding("job_1", true)
        jobs.apply(.jobCompleted(jobId: "job_2"))
        XCTAssertFalse(jobs.takeNotifyOnLanding("job_2"))
        XCTAssertTrue(jobs.takeNotifyOnLanding("job_1"))
    }
}

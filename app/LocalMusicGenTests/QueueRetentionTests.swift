import AppKit
import SwiftUI
import XCTest
@testable import LocalMusicGen

/// Finished work stays in the queue until it is dismissed, and the list reads
/// in an order that survives it doing so.
///
/// Rows used to disappear eight seconds after they succeeded, which meant the
/// only place the app said what it had just made was gone before you looked at
/// it. Now they stay — which makes the ordering load-bearing, because a queue
/// that keeps everything and appends to the bottom buries the thing you came
/// to see under everything you made this morning.
@MainActor
final class QueueRetentionTests: XCTestCase {
    private var createdFiles: [URL] = []

    override func tearDown() {
        for url in createdFiles { try? FileManager.default.removeItem(at: url) }
        createdFiles = []
        super.tearDown()
    }

    /// `createdAt` is the engine's ISO-8601 string, not a Date, and the sort
    /// compares it as one — which is ordered for this format because the
    /// fields run most-significant first and the width is fixed.
    private func job(_ id: String, _ status: JobStatus, at made: String,
                     position: Int? = nil,
                     produced: [String] = []) -> JobsStore.ActiveJob {
        let info = JobInfo(
            jobId: id, groupId: "grp", modelId: "m", task: nil, status: status,
            queuePosition: position, prompt: id, lyrics: nil, durationS: 4,
            count: 1, params: [:], createdAt: made, progress: nil,
            result: nil, error: nil)
        return JobsStore.ActiveJob(info: info, status: status,
                                   producedSongIds: produced)
    }

    private func ids(_ jobs: [JobsStore.ActiveJob]) -> [String] {
        jobs.map(\.id)
    }

    // MARK: - Order

    /// Work at the top in the order it will run, then the record underneath
    /// with the newest first.
    func testWorkSitsAboveTheRecordAndTheRecordReadsNewestFirst() {
        let order = JobsStore.ordered([
            job("done-old", .succeeded, at: "2026-08-22T09:00:00Z"),
            job("queued-2", .queued, at: "2026-08-22T12:00:00Z", position: 2),
            job("done-new", .succeeded, at: "2026-08-22T11:00:00Z"),
            job("running", .generating, at: "2026-08-22T11:30:00Z", position: 0),
            job("queued-1", .queued, at: "2026-08-22T12:00:01Z", position: 1),
        ])
        XCTAssertEqual(ids(order),
                       ["running", "queued-1", "queued-2", "done-new", "done-old"])
    }

    /// A job the engine has given no position sorts behind the ones it has —
    /// unchanged from before finished rows started staying, and pinned here
    /// because it is the one place the top half is not simply chronological.
    /// It is why the fixtures above give the running job a position: a running
    /// job that reported none would draw under the queue waiting for it.
    func testAJobWithNoPositionSortsBehindTheOnesThatHaveOne() {
        let order = JobsStore.ordered([
            job("unplaced", .generating, at: "2026-08-22T09:00:00Z"),
            job("placed", .queued, at: "2026-08-22T12:00:00Z", position: 4),
        ])
        XCTAssertEqual(ids(order), ["placed", "unplaced"])
    }

    /// The reason the halves are sorted differently at all: a queued row's
    /// position is a claim about what happens next, so `#1` cannot appear
    /// under `#2` however recently `#2` was submitted.
    func testQueuedWorkKeepsItsRunOrderRegardlessOfAge() {
        let order = JobsStore.ordered([
            job("later", .queued, at: "2026-08-22T09:00:00Z", position: 3),
            job("sooner", .queued, at: "2026-08-22T12:00:00Z", position: 1),
        ])
        XCTAssertEqual(ids(order), ["sooner", "later"])
    }

    /// What the user asked for, stated directly: submitting something puts it
    /// above everything that has already finished, however much of that there
    /// is.
    func testANewSubmissionOutranksEveryFinishedRow() {
        // The finished rows keep the position they held while they ran — the
        // engine reports one and nothing clears it afterwards — and they were
        // at the head of the queue then. A single sort over the whole list
        // would rank all twenty of them above the job that is about to run.
        var jobs = (0..<20).map {
            job("done-\($0)", .succeeded,
                at: "2026-08-22T10:00:\(String(format: "%02d", $0))Z",
                position: 0)
        }
        jobs.append(job("fresh", .queued, at: "2026-08-22T08:00:00Z",
                        position: 3))
        XCTAssertEqual(JobsStore.ordered(jobs).first?.id, "fresh")
    }

    /// Cancelled and failed rows are part of the record too — a render that
    /// failed is the row you most need to still be there.
    func testEveryTerminalStatusIsKept() {
        let order = JobsStore.ordered([
            job("failed", .failed, at: "2026-08-22T10:00:00Z"),
            job("canceled", .canceled, at: "2026-08-22T10:00:01Z"),
            job("succeeded", .succeeded, at: "2026-08-22T10:00:02Z"),
        ])
        XCTAssertEqual(ids(order), ["succeeded", "canceled", "failed"])
    }

    /// Two jobs submitted in the same second must not be able to trade places
    /// between redraws — a row that moves while you reach for it is worse than
    /// either order.
    func testTheOrderIsTotalWhenTimestampsTie() {
        let tied = [
            job("b", .succeeded, at: "2026-08-22T10:00:00Z"),
            job("a", .succeeded, at: "2026-08-22T10:00:00Z"),
            job("c", .queued, at: "2026-08-22T10:00:00Z"),
            job("d", .queued, at: "2026-08-22T10:00:00Z"),
        ]
        let once = ids(JobsStore.ordered(tied))
        XCTAssertEqual(once, ids(JobsStore.ordered(tied.reversed())),
                       "the same set in a different order must sort the same")
        XCTAssertEqual(once, ["c", "d", "b", "a"])
    }

    // MARK: - Dismissal

    private func store() throws -> JobsStore {
        let db = try DatabaseManager.inMemory()
        return JobsStore(repo: LibraryRepository(db: db),
                         partsRepo: PartsRepository(db: db))
    }

    /// The row's title is read out of the routing context, so the context has
    /// to outlive the job's success and go only when the row does. Dropping it
    /// on success left a finished split sitting there unnamed.
    func testDismissTakesTheRoutingContextWithIt() throws {
        let jobs = try store()
        jobs.pendingContext["job_1"] = .split(songId: "s1",
                                              sourceTitle: "Warehouse jam")
        XCTAssertEqual(jobs.displayTitle(for: job("job_1", .succeeded,
                                                  at: "2026-08-22T10:00:00Z").info),
                       "Split: Warehouse jam")

        jobs.dismiss("job_1")
        XCTAssertNil(jobs.pendingContext["job_1"])
    }

    func testClearDoneTakesTheFinishedRowsAndLeavesTheWork() throws {
        let jobs = try store()
        for row in [job("running", .generating, at: "2026-08-22T10:00:00Z"),
                    job("waiting", .queued, at: "2026-08-22T10:00:01Z"),
                    job("done", .succeeded, at: "2026-08-22T10:00:02Z"),
                    job("failed", .failed, at: "2026-08-22T10:00:03Z")] {
            jobs.adopt(row)
        }

        jobs.dismissFinished()
        XCTAssertEqual(jobs.trackedJobIds, ["running", "waiting"])
    }

    // MARK: - What a finished row remembers

    /// The row stays, and it knows what it made — which is what "Show in
    /// library" needs and the eight-second dismissal used to throw away.
    func testAFinishedGenerationStaysAndRemembersWhatItMade() throws {
        let db = try DatabaseManager.inMemory()
        let library = LibraryRepository(db: db)
        let jobs = JobsStore(repo: library, partsRepo: PartsRepository(db: db))

        let outDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("queue-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outDir,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outDir) }
        var outputs: [JobOutput] = []
        for take in 0..<2 {
            let file = outDir.appendingPathComponent("take-\(take).wav")
            try Data(repeating: 7, count: 128).write(to: file)
            outputs.append(JobOutput(path: file.path, format: "wav",
                                     sampleRate: 48000, durationS: 4,
                                     seedUsed: 1))
        }
        let result = JobResult(outputs: outputs, artifacts: nil, meta: nil,
                               timings: [:])
        let info = JobInfo(
            jobId: "job_g", groupId: "grp", modelId: "m", task: nil,
            status: .succeeded, queuePosition: nil, prompt: "a tune",
            lyrics: nil, durationS: 4, count: 2, params: [:],
            createdAt: "2026-08-22T10:00:00Z", progress: nil, result: result,
            error: nil)
        jobs.adopt(JobsStore.ActiveJob(info: info, status: .generating))

        jobs.ingestGenerate(job: info, result: result)
        createdFiles += ((try? library.recent(limit: 10)) ?? []).map(\.fileURL)

        let row = try XCTUnwrap(jobs.job("job_g"))
        XCTAssertEqual(row.status, .succeeded)
        XCTAssertEqual(row.producedSongIds.count, 2,
                       "both takes are recorded, in submission order")
        // Take a is what the row's button opens; the rest are beside it.
        let first = try XCTUnwrap(row.producedSongIds.first)
        XCTAssertNotNil(try library.song(id: first))
    }

    // MARK: - The button is really there

    /// The card as the panel gives it to it: 340 pt of inspector less the
    /// rail's 14 pt of padding each side.
    private func height(of job: JobsStore.ActiveJob,
                        showsButton: Bool) -> CGFloat {
        let row = JobRow(job: job, title: "a lonely trumpet over rain",
                         modelName: "MusicGen Small",
                         onCancel: {}, onDismiss: {},
                         onShowInLibrary: showsButton ? {} : nil)
        let host = NSHostingView(rootView: row.frame(
            width: Bench.Metrics.Inspector.queue - 28))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    /// `onShowInLibrary` is optional and the row draws it inside an `if let`,
    /// so a wiring mistake shows up as nothing at all — which no assertion
    /// about the store would catch. Rendered rather than reasoned about.
    func testAFinishedRowDrawsTheButtonAndAnUnfinishedOneDoesNot() {
        let done = job("done", .succeeded, at: "2026-08-22T10:00:00Z",
                       produced: ["s1"])
        let bare = height(of: done, showsButton: false)
        let offered = height(of: done, showsButton: true)
        XCTAssertGreaterThan(offered, bare,
                             "the button has to take room, or it is not drawn")
        // A card that has grown by more than a line of controls is one whose
        // title or meta line has wrapped to make space for it.
        XCTAssertLessThan(offered - bare, 44)
    }

    // MARK: - Where the button sends you

    /// A finished row does not assume it made a generated track. The same row
    /// shape carries an import, and sending the user to Generated with an
    /// import selected shows an empty pane over a list it is not in.
    ///
    /// A render needs no such care since the shelves were folded — it lands on
    /// the Generated shelf beside the takes — but the mapping still goes
    /// through the origin rather than guessing.
    func testTheScopeForATrackFollowsItsOrigin() {
        XCTAssertEqual(LibraryScope(origin: .generated), .songs)
        XCTAssertEqual(LibraryScope(origin: .recombined), .songs)
        XCTAssertEqual(LibraryScope(origin: .imported), .imported)
        // The inverse of the mapping that was already there, so the two cannot
        // drift apart: whatever scope an origin is sent to has to be a scope
        // that lists that origin.
        for origin in SongOrigin.allCases {
            let shelf = LibraryScope(origin: origin).shelf
            XCTAssertEqual(shelf, SongShelf(origin: origin))
            XCTAssertEqual(shelf?.origins.contains(origin), true,
                           "\(origin.rawValue) was sent to a list without it")
        }
    }
}

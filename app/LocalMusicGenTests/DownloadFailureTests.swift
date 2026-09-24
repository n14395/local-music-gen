// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import LocalMusicGen

/// A failed download used to be indistinguishable from a finished one: both
/// removed the row and said nothing. These pin that the failure survives the
/// download it belongs to, and that it goes away for the right reasons.
@MainActor
final class DownloadFailureTests: XCTestCase {
    private func store() -> DownloadsStore { DownloadsStore() }

    private func failure(_ code: String,
                         _ message: String = "boom") -> EngineEvent {
        .downloadFailed(downloadId: "dl_1", modelId: "m1",
                        error: APIErrorBody(code: code, message: message))
    }

    private func progress(_ id: String = "dl_1",
                          model: String = "m1") -> EngineEvent {
        .downloadProgress(DownloadInfo(
            downloadId: id, modelId: model, state: .downloading,
            bytesDone: 1, bytesTotal: 100, speedBps: 1,
            stage: "weights", message: nil, runtimeOnly: false))
    }

    func testFailureIsKeptAfterTheDownloadIsGone() {
        let s = store()
        s.apply(progress())
        s.apply(failure("UNAUTHORIZED", "gated — add a token with access"))

        // The download itself is over…
        XCTAssertNil(s.info(forModel: "m1"))
        // …but the reason is still on the model, which is what the row shows.
        XCTAssertEqual(s.failure(forModel: "m1")?.code, "UNAUTHORIZED")
        XCTAssertEqual(s.failure(forModel: "m1")?.message,
                       "gated — add a token with access")
    }

    /// The distinction the row uses to decide between "try again" and "accept
    /// the licence", which no retry can substitute for.
    func testOnlyUnauthorizedNeedsAccess() {
        let s = store()
        s.apply(failure("UNAUTHORIZED"))
        XCTAssertEqual(s.failure(forModel: "m1")?.needsAccess, true)

        let other = store()
        other.apply(failure("INTERNAL"))
        XCTAssertEqual(other.failure(forModel: "m1")?.needsAccess, false)
    }

    func testANewAttemptSupersedesTheLastFailure() {
        let s = store()
        s.apply(failure("UNAUTHORIZED"))
        s.apply(progress(model: "m1"))
        XCTAssertNil(s.failure(forModel: "m1"),
                     "a running download must not sit under an old complaint")
    }

    func testSuccessClearsTheFailure() {
        let s = store()
        s.apply(failure("INTERNAL"))
        s.apply(.downloadCompleted(downloadId: "dl_2", modelId: "m1",
                                   runtimeOnly: false))
        XCTAssertNil(s.failure(forModel: "m1"))
    }

    func testDismissClearsOnlyThatModel() {
        let s = store()
        s.apply(failure("INTERNAL"))
        s.apply(.downloadFailed(downloadId: "dl_9", modelId: "m2",
                                error: APIErrorBody(code: "INTERNAL",
                                                    message: "boom")))
        s.clearFailure(forModel: "m1")
        XCTAssertNil(s.failure(forModel: "m1"))
        XCTAssertNotNil(s.failure(forModel: "m2"))
    }

    /// A completion for one model must not wipe another's failure — the events
    /// are keyed by download id, the failures by model.
    func testCompletionOfAnotherModelLeavesTheFailure() {
        let s = store()
        s.apply(failure("UNAUTHORIZED"))
        s.apply(.downloadCompleted(downloadId: "dl_7", modelId: "m2",
                                   runtimeOnly: false))
        XCTAssertNotNil(s.failure(forModel: "m1"))
    }

    // MARK: - The row a finished transfer leaves behind

    /// The complaint this was written for: a download used to be the one kind
    /// of work in the queue that reported success by disappearing.
    func testACompletedDownloadStaysUntilItIsDismissed() {
        let s = store()
        s.apply(progress())
        s.apply(.downloadCompleted(downloadId: "dl_1", modelId: "m1",
                                   runtimeOnly: false))

        XCTAssertNil(s.info(forModel: "m1"), "it is not transferring any more")
        XCTAssertEqual(s.finished.map(\.id), ["dl_1"])
        XCTAssertEqual(s.finished.first?.outcome, .completed)
        // The size comes off the last progress event, because the completion
        // event carries no bytes.
        XCTAssertEqual(s.finished.first?.bytes, 100)

        s.dismissFinished("dl_1")
        XCTAssertTrue(s.finished.isEmpty)
    }

    func testAFailedDownloadLeavesARowSayingWhy() {
        let s = store()
        s.apply(progress())
        s.apply(failure("INTERNAL", "connection reset"))
        XCTAssertEqual(s.finished.first?.failureMessage, "connection reset")
        XCTAssertEqual(s.finished.first?.isFailure, true)
        // …and the model's own complaint is still there for the Models screen.
        XCTAssertNotNil(s.failure(forModel: "m1"))
    }

    /// Newest first, and one row per model: a second attempt replaces the row
    /// the first one left rather than stacking on it.
    func testFinishedRowsReadNewestFirstAndDoNotDouble() {
        let s = store()
        s.apply(.downloadCompleted(downloadId: "dl_1", modelId: "m1",
                                   runtimeOnly: false))
        s.apply(.downloadCompleted(downloadId: "dl_2", modelId: "m2",
                                   runtimeOnly: false))
        XCTAssertEqual(s.finished.map(\.id), ["dl_2", "dl_1"])

        // m1 is downloaded again: the old row goes, and the new one arrives at
        // the top when it lands.
        s.apply(progress("dl_3", model: "m1"))
        XCTAssertEqual(s.finished.map(\.id), ["dl_2"])
        s.apply(.downloadCompleted(downloadId: "dl_3", modelId: "m1",
                                   runtimeOnly: false))
        XCTAssertEqual(s.finished.map(\.id), ["dl_3", "dl_2"])
    }

    /// A replayed completion (a reconnect re-reading the ring buffer) is the
    /// same row, not a second one.
    func testAReplayedCompletionDoesNotDrawTwice() {
        let s = store()
        let done = EngineEvent.downloadCompleted(downloadId: "dl_1",
                                                 modelId: "m1",
                                                 runtimeOnly: false)
        s.apply(done)
        s.apply(done)
        XCTAssertEqual(s.finished.count, 1)
    }

    /// A runtime install fetched no weights, and its row has to say so rather
    /// than claim a model arrived.
    func testARuntimeInstallIsMarkedAsOne() {
        let s = store()
        s.apply(.downloadCompleted(downloadId: "dl_1", modelId: "m1",
                                   runtimeOnly: true))
        XCTAssertEqual(s.finished.first?.isRuntimeOnly, true)
    }

    /// Off by default — the row waits for a click — and on the Settings
    /// schedule when there is one.
    func testFinishedRowsClearOnTheQueueSchedule() {
        let s = store()
        let t0 = Date()
        s.apply(.downloadCompleted(downloadId: "dl_1", modelId: "m1",
                                   runtimeOnly: false))
        s.sweepFinished(now: t0.addingTimeInterval(86_400))
        XCTAssertEqual(s.finished.count, 1, "no policy means keep it")

        s.autoClearAfterS = { 60 }
        s.sweepFinished(now: t0.addingTimeInterval(30))
        XCTAssertEqual(s.finished.count, 1, "still inside the grace period")
        s.sweepFinished(now: t0.addingTimeInterval(61))
        XCTAssertTrue(s.finished.isEmpty)
    }

    func testClearDoneTakesEveryFinishedRow() {
        let s = store()
        s.apply(.downloadCompleted(downloadId: "dl_1", modelId: "m1",
                                   runtimeOnly: false))
        s.apply(failure("INTERNAL"))
        s.dismissAllFinished()
        XCTAssertTrue(s.finished.isEmpty)
    }
}

import XCTest
@testable import LocalMusic

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
}

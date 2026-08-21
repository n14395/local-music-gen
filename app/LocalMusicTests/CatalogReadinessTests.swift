import XCTest
@testable import LocalMusic

/// An empty catalog is ambiguous until the engine answers once. These pin the
/// rule that decides between "still loading", "the engine is broken", and
/// "genuinely empty" — the bug being guarded against is telling a user with
/// models installed that they have none, purely because the first fetch hadn't
/// landed yet, and its mirror image: spinning forever when no answer is coming.
@MainActor
final class CatalogReadinessTests: XCTestCase {
    func testUnansweredCatalogIsPendingNotEmpty() {
        XCTAssertEqual(
            CatalogReadiness.state(hasLoaded: false, isConnected: false,
                                   lastError: nil, backend: .launching),
            .pending(detail: "Starting the engine…"))
        XCTAssertEqual(
            CatalogReadiness.state(hasLoaded: false, isConnected: true,
                                   lastError: nil, backend: .ready),
            .pending(detail: "Fetching the catalog…"))
        XCTAssertEqual(
            CatalogReadiness.state(hasLoaded: false, isConnected: false,
                                   lastError: nil, backend: .restarting),
            .pending(detail: "Restarting the engine…"))
    }

    func testAnsweredEmptyCatalogIsReady() {
        XCTAssertEqual(
            CatalogReadiness.state(hasLoaded: true, isConnected: true,
                                   lastError: nil, backend: .ready),
            .ready)
    }

    /// A failure is an answer: surfacing it beats an animation that never ends.
    func testFailureOutranksPending() {
        XCTAssertEqual(
            CatalogReadiness.state(hasLoaded: false, isConnected: true,
                                   lastError: "connection refused",
                                   backend: .ready),
            .unavailable(message: "connection refused"))
        XCTAssertEqual(
            CatalogReadiness.state(hasLoaded: false, isConnected: false,
                                   lastError: nil,
                                   backend: .failed(reason: "No engine found.")),
            .unavailable(message: "No engine found."))
        XCTAssertEqual(
            CatalogReadiness.state(hasLoaded: true, isConnected: true,
                                   lastError: "boom", backend: .ready),
            .unavailable(message: "boom"))
    }

    /// The one question every gating screen asks. Only a real answer counts as
    /// knowledge — a broken engine is emphatically not proof of an empty disk.
    func testOnlyReadyKnowsWhatIsInstalled() {
        XCTAssertTrue(CatalogReadiness.ready.knowsWhatIsInstalled)
        XCTAssertFalse(CatalogReadiness.pending(detail: "…").knowsWhatIsInstalled)
        XCTAssertFalse(
            CatalogReadiness.unavailable(message: "…").knowsWhatIsInstalled)
    }

    func testFreshStoreHasNotLoaded() async {
        let store = ModelCatalogStore()
        XCTAssertFalse(store.hasLoaded)
        XCTAssertEqual(store.readiness,
                       .pending(detail: "Starting the engine…"))
        // No client yet: refresh is a no-op and must not claim an answer.
        await store.refresh()
        XCTAssertFalse(store.hasLoaded)
        XCTAssertFalse(store.readiness.knowsWhatIsInstalled)
    }

    /// The store reads the engine's phase so a launch that has already failed
    /// stops presenting as a launch still in progress.
    func testStoreReflectsBackendFailure() {
        let backend = BackendStatusStore()
        let store = ModelCatalogStore(backend: backend)
        XCTAssertEqual(store.readiness, .pending(detail: "Starting the engine…"))
        backend.phase = .failed(reason: "No engine found.")
        XCTAssertEqual(store.readiness,
                       .unavailable(message: "No engine found."))
    }
}

/// The gallery's own use of the rule. Twenty-six cards read their state from
/// one function, so these pin the two things that function must not get wrong:
/// a card that is merely waiting must not shout, and it must not offer a route
/// to a model list that cannot help it yet.
@MainActor
final class ActionCardStateTests: XCTestCase {
    func testPendingIsQuietAndInert() {
        let pending = ActionsScreen.CardState.unknown(.pending(detail: "…"))
        XCTAssertEqual(pending.footnote, "Checking what's installed…")
        XCTAssertFalse(pending.footnoteIsWarning)
        XCTAssertTrue(pending.isInert)
    }

    /// A failed engine is a different animal: it *is* a problem, and clicking
    /// through to Models is how you see what went wrong.
    func testUnavailableWarnsAndStaysClickable() {
        let broken = ActionsScreen.CardState.unknown(.unavailable(message: "x"))
        XCTAssertEqual(broken.footnote, "The engine isn't running")
        XCTAssertTrue(broken.footnoteIsWarning)
        XCTAssertFalse(broken.isInert)
    }

    /// The states that existed before are untouched — a gated card still
    /// names its download and still routes.
    func testGatedStatesUnchanged() {
        XCTAssertEqual(ActionsScreen.CardState.needsMixModel.footnote,
                       "Get Mixdown & Align — free")
        XCTAssertTrue(ActionsScreen.CardState.needsMixModel.footnoteIsWarning)
        XCTAssertFalse(ActionsScreen.CardState.needsMixModel.isInert)
        XCTAssertNil(ActionsScreen.CardState.active.footnote)
        XCTAssertFalse(ActionsScreen.CardState.active.isInert)
        XCTAssertTrue(ActionsScreen.CardState.comingSoon.isInert)
    }
}

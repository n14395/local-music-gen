import XCTest
@testable import LocalMusic

/// An empty catalog is ambiguous until the engine answers once. These pin the
/// rule that decides between "still loading", "the engine is broken", and
/// "genuinely empty" — the bug being guarded against is telling a user with
/// models installed that they have none, purely because the first fetch hadn't
/// landed yet, and its mirror image: spinning forever when no answer is coming.
@MainActor
final class CatalogPlaceholderTests: XCTestCase {
    func testUnansweredCatalogIsLoadingNotEmpty() {
        XCTAssertEqual(
            CatalogPlaceholder.state(hasLoaded: false, isConnected: false,
                                     lastError: nil, backend: .launching),
            .loading(detail: "Starting the engine…"))
        XCTAssertEqual(
            CatalogPlaceholder.state(hasLoaded: false, isConnected: true,
                                     lastError: nil, backend: .ready),
            .loading(detail: "Fetching the catalog…"))
        XCTAssertEqual(
            CatalogPlaceholder.state(hasLoaded: false, isConnected: false,
                                     lastError: nil, backend: .restarting),
            .loading(detail: "Restarting the engine…"))
    }

    func testAnsweredEmptyCatalogIsEmpty() {
        XCTAssertEqual(
            CatalogPlaceholder.state(hasLoaded: true, isConnected: true,
                                     lastError: nil, backend: .ready),
            .empty)
    }

    /// A failure is an answer: surfacing it beats an animation that never ends.
    func testFailureOutranksLoading() {
        XCTAssertEqual(
            CatalogPlaceholder.state(hasLoaded: false, isConnected: true,
                                     lastError: "connection refused",
                                     backend: .ready),
            .failed(message: "connection refused"))
        XCTAssertEqual(
            CatalogPlaceholder.state(hasLoaded: false, isConnected: false,
                                     lastError: nil,
                                     backend: .failed(reason: "No engine found.")),
            .failed(message: "No engine found."))
        XCTAssertEqual(
            CatalogPlaceholder.state(hasLoaded: true, isConnected: true,
                                     lastError: "boom", backend: .ready),
            .failed(message: "boom"))
    }

    func testFreshStoreHasNotLoaded() async {
        let store = ModelCatalogStore()
        XCTAssertFalse(store.hasLoaded)
        XCTAssertEqual(store.placeholder(backend: .launching),
                       .loading(detail: "Starting the engine…"))
        // No client yet: refresh is a no-op and must not claim an answer.
        await store.refresh()
        XCTAssertFalse(store.hasLoaded)
    }
}

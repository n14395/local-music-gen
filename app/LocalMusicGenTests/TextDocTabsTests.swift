import XCTest
@testable import LocalMusicGen

/// The strip a text-docs section puts under a kind that has been run more
/// than once: what the tabs say, which one shows, and which kinds get one at
/// all. Pure, so the rules can be read without a store or a pane behind them.
@MainActor
final class TextDocTabsTests: XCTestCase {
    private func doc(_ id: String, model: String, kind: String = "lyrics",
                     at createdAt: Date = Date()) -> TextDocRecord {
        TextDocRecord(id: id, ownerId: "song1", ownerType: "song",
                      kind: kind, text: "la", segmentsJSON: nil,
                      question: nil, language: nil, modelId: model.lowercased(),
                      modelName: model, jobId: nil, edited: false,
                      createdAt: createdAt, updatedAt: createdAt)
    }

    /// The store hands documents over newest first, and the strip keeps that
    /// order — the reader learns "left is latest" once.
    func testEveryDocumentGetsATabNamedForItsSourceInStoreOrder() {
        let tabs = TextDocsSection.tabs(for: [
            doc("b", model: "Whisper"), doc("a", model: "Qwen2-Audio"),
            doc("c", model: "You"),
        ])
        XCTAssertEqual(tabs.map(\.value), ["b", "a", "c"])
        XCTAssertEqual(tabs.map(\.label), ["Whisper", "Qwen2-Audio", "You"])
        XCTAssertEqual(tabs.map(\.detail), [nil, nil, nil])
    }

    /// Two runs of one model would be two identical tabs, so those — and only
    /// those — say when they ran.
    func testOnlyARepeatedSourceCarriesWhenItRan() {
        let now = Date()
        let tabs = TextDocsSection.tabs(for: [
            doc("today", model: "Whisper", at: now),
            doc("earlier", model: "Whisper", at: now.addingTimeInterval(-3 * 86_400)),
            doc("other", model: "Qwen2-Audio", at: now),
        ], now: now)
        XCTAssertNotNil(tabs[0].detail)
        XCTAssertNotNil(tabs[1].detail)
        XCTAssertNil(tabs[2].detail)
        // A run today is told by its time, an older one by its day, so the
        // two never read the same.
        XCTAssertNotEqual(tabs[0].detail, tabs[1].detail)
        XCTAssertFalse(tabs[0].detail?.isEmpty ?? true)
    }

    func testTheNewestShowsUntilOneIsChosen() {
        let docs = [doc("new", model: "Whisper"), doc("old", model: "You")]
        XCTAssertEqual(TextDocsSection.shown(docs, selected: nil)?.id, "new")
        XCTAssertEqual(TextDocsSection.shown(docs, selected: "old")?.id, "old")
    }

    /// The chosen document was deleted, or the pane moved to a song whose
    /// documents have other ids: the strip lands on the newest, not nowhere.
    func testAChoiceThatNoLongerExistsFallsBackToTheNewest() {
        let docs = [doc("new", model: "Whisper"), doc("old", model: "You")]
        XCTAssertEqual(TextDocsSection.shown(docs, selected: "gone")?.id, "new")
        XCTAssertNil(TextDocsSection.shown([], selected: "gone"))
    }

    /// Answers are to different questions — a list, not re-runs of one thing.
    func testQAIsAListNotAStrip() {
        XCTAssertFalse(TextDocsSection.tabbed(.qa))
        for kind in TextDocKind.allCases where kind != .qa {
            XCTAssertTrue(TextDocsSection.tabbed(kind), kind.rawValue)
        }
    }
}

import XCTest
import SwiftUI
import AppKit
@testable import LocalMusicGen

/// The Library's scope rows carry a mark to the left of their name. Two
/// properties are worth pinning, because both fail quietly — nothing crashes,
/// the sidebar just stops looking like a list:
///
/// 1. The marks are wildly different widths by nature (a music note is barely
///    half a split rectangle), so they are drawn in a fixed column. Drop that
///    and the titles no longer share a left edge.
/// 2. The mark leads the word. It used to trail it, and "move the heart to the
///    left" is the change these rows exist to hold onto.
///
/// Both are measured off pixels rather than asserted about the source, because
/// the layout is what is being claimed, not the spelling of it.
@MainActor
final class BenchSidebarSubRowTests: XCTestCase {
    /// The marks actually in use, read off the scopes rather than copied, so a
    /// scope added later is covered without anyone remembering to come here.
    private static let marks = LibraryScope.allCases.map(\.symbol)

    private struct Harness: View {
        let title: String
        let symbol: String
        @State private var selection = "other"

        var body: some View {
            BenchSidebarSubRow(scope: "row", title: title, symbol: symbol,
                               showsSelection: false, selection: $selection)
                .frame(width: Bench.Metrics.sidebarWidth)
                .background(Color.black)
        }
    }

    /// Which pixel columns of a rendered row had anything drawn in them.
    private func inkColumns(title: String, symbol: String) throws -> [Bool] {
        let host = NSHostingView(rootView: Harness(title: title, symbol: symbol))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)

        var columns = [Bool](repeating: false, count: rep.pixelsWide)
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                // An unselected row draws no background, so anything above the
                // black ground is a glyph — the dimmest of them is textMuted.
                if color.brightnessComponent > 0.18 { columns[x] = true; break }
            }
        }
        return columns
    }

    /// Ink runs with letter spacing closed up, so a word counts as one thing.
    /// At this scale the gaps inside a word are a few pixels; the layout puts
    /// 7 pt between the mark and the word, which is more than twice `gap`
    /// whichever way the display scales.
    private func groups(_ columns: [Bool], gap: Int = 8) -> [ClosedRange<Int>] {
        var runs: [ClosedRange<Int>] = []
        var start: Int?
        var lastInk: Int?
        for (x, inked) in columns.enumerated() where inked {
            if let last = lastInk, let began = start, x - last > gap {
                runs.append(began...last)
                start = x
            } else if start == nil {
                start = x
            }
            lastInk = x
        }
        if let began = start, let last = lastInk { runs.append(began...last) }
        return runs
    }

    /// A misspelt symbol name is not an error anywhere — the row simply draws
    /// nothing where the mark should be, and the titles keep their column, so
    /// it looks like a design decision rather than a typo.
    func testEveryScopeNamesASymbolThatExists() {
        for scope in LibraryScope.allCases {
            XCTAssertNotNil(NSImage(systemSymbolName: scope.symbol,
                                    accessibilityDescription: nil),
                            "\(scope.title) asks for \"\(scope.symbol)\", which "
                            + "is not a symbol on this system")
        }
    }

    func testTitlesShareALeftEdgeWhateverTheMark() throws {
        // Same word every time, so the right-hand edge of the ink is the same
        // pixel unless the word itself moved — which is the thing being tested.
        let edges = try Self.marks.map { mark -> Int in
            let columns = try inkColumns(title: "Renders", symbol: mark)
            return columns.lastIndex(of: true) ?? -1
        }
        try XCTSkipIf(edges.contains(-1), "no drawing available (headless?)")
        let reference = try XCTUnwrap(edges.first)
        for (mark, edge) in zip(Self.marks, edges) {
            XCTAssertEqual(edge, reference, accuracy: 1,
                           "\(mark) moved the title \(edge - reference) px — the "
                           + "marks are not drawn in a fixed column")
        }
    }

    func testTheMarkLeadsTheWord() throws {
        let columns = try inkColumns(title: "Favourites", symbol: "heart.fill")
        try XCTSkipIf(!columns.contains(true), "no drawing available (headless?)")
        let parts = groups(columns)
        XCTAssertEqual(parts.count, 2,
                       "expected a mark and a word separated by the layout's "
                       + "spacing, got \(parts.map(\.count))")
        guard parts.count == 2 else { return }
        // A heart is one glyph and "Favourites" is ten. Whichever is on the
        // left when the row is drawn is the one that reads first.
        XCTAssertLessThan(parts[0].count, parts[1].count / 2,
                          "the wide thing is on the left — the mark is trailing "
                          + "the title, not leading it")
    }
}

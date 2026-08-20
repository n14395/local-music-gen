import XCTest
@testable import LocalMusic

/// The Models tag bar must wrap onto extra rows instead of scrolling sideways,
/// so the row packing is where the behaviour lives.
final class FlowLayoutTests: XCTestCase {
    private func rows(_ widths: [CGFloat], _ maxWidth: CGFloat,
                      spacing: CGFloat = 8) -> [[Int]] {
        FlowLayout.rows(itemWidths: widths, maxWidth: maxWidth, spacing: spacing)
    }

    func testFittingItemsShareOneRow() {
        XCTAssertEqual(rows([100, 100, 100], 400), [[0, 1, 2]])
    }

    func testWrapsWhenSpacingPushesPastTheEdge() {
        // 3 × 100 + 2 × 8 spacing = 316 > 310, so the last item wraps
        XCTAssertEqual(rows([100, 100, 100], 310), [[0, 1], [2]])
    }

    func testWrapsOntoAsManyRowsAsNeeded() {
        XCTAssertEqual(rows([90, 90, 90, 90, 90], 200), [[0, 1], [2, 3], [4]])
    }

    func testOversizedItemGetsItsOwnRowRatherThanVanishing() {
        XCTAssertEqual(rows([50, 500, 50], 200), [[0], [1], [2]])
    }

    func testEmptyInputProducesNoRows() {
        XCTAssertTrue(rows([], 300).isEmpty)
    }

    /// The eight real tag buttons plus "All" at a typical window width should
    /// need two rows — not one scrolling row, and not nine stacked ones.
    func testRealTagBarWrapsToTwoRowsAtTypicalWidth() {
        let widths: [CGFloat] = [70, 170, 150, 165, 140, 155, 145, 175, 130]
        let packed = rows(widths, 900)
        XCTAssertEqual(packed.count, 2)
        XCTAssertEqual(packed.flatMap { $0 }.count, widths.count)
    }
}

import XCTest
@testable import LocalMusicGen

/// The render pipeline strip has to show every stage for the whole render.
/// `HStack` + `layoutPriority` let the running stage take the entire row and
/// left the rest as bare circles, so the share arithmetic is where the
/// behaviour lives now.
final class WeightedRowLayoutTests: XCTestCase {
    private func widths(_ weights: [CGFloat], count: Int, total: CGFloat,
                        spacing: CGFloat = 10) -> [CGFloat] {
        WeightedRowLayout.widths(weights: weights, count: count, total: total,
                                 spacing: spacing)
    }

    func testEqualWeightsSplitTheRowEvenly() {
        // 400 - 3 gaps × 10 = 370, four ways.
        XCTAssertEqual(widths([1, 1, 1, 1], count: 4, total: 400),
                       [92.5, 92.5, 92.5, 92.5])
    }

    func testWidthsPlusSpacingFillTheRowExactly() {
        let result = widths([1, 1.35, 1, 1, 1], count: 5, total: 883)
        let used = result.reduce(0, +) + 10 * 4
        XCTAssertEqual(used, 883, accuracy: 0.0001)
    }

    /// The whole point: the running stage is wider, and every other stage
    /// still gets a readable column rather than collapsing.
    func testRunningStageIsWiderButNeverSwallowsTheRow() {
        let result = widths([1, 1, 1.35, 1, 1], count: 5, total: 883)
        XCTAssertEqual(result[2] / result[0], 1.35, accuracy: 0.0001)
        for (index, width) in result.enumerated() where index != 2 {
            XCTAssertGreaterThan(width, 140,
                                 "stage \(index) collapsed to \(width) pt")
        }
    }

    /// Weights are normalised, so the caller can pass any scale.
    func testWeightScaleDoesNotMatter() {
        XCTAssertEqual(widths([2, 2, 2], count: 3, total: 320),
                       widths([1, 1, 1], count: 3, total: 320))
        XCTAssertEqual(widths([27, 27, 27], count: 3, total: 320),
                       widths([1, 1, 1], count: 3, total: 320))
    }

    /// A short or absent weight list must not make a subview disappear —
    /// pipelines are built from `stages.indices`, and an off-by-one there
    /// would silently delete a stage from the strip.
    func testMissingAndNonPositiveWeightsCountAsOne() {
        XCTAssertEqual(widths([], count: 3, total: 320),
                       widths([1, 1, 1], count: 3, total: 320))
        XCTAssertEqual(widths([1, 1], count: 3, total: 320),
                       widths([1, 1, 1], count: 3, total: 320))
        XCTAssertEqual(widths([1, 0, -4], count: 3, total: 320),
                       widths([1, 1, 1], count: 3, total: 320))
    }

    func testNoSubviewsProducesNoWidths() {
        XCTAssertTrue(widths([1, 1], count: 0, total: 320).isEmpty)
    }

    /// A row narrower than its gaps clamps to zero rather than handing back
    /// negative widths that would place subviews right-to-left.
    func testRowNarrowerThanItsSpacingClampsToZero() {
        XCTAssertEqual(widths([1, 1, 1], count: 3, total: 8), [0, 0, 0])
    }
}

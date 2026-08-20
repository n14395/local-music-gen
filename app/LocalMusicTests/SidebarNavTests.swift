import XCTest
import SwiftUI
@testable import LocalMusic

/// The sidebar's order and the one glyph in it that carries a claim.
final class SidebarNavTests: XCTestCase {

    /// Declaration order *is* sidebar order, which makes the sidebar's layout
    /// a property of an enum nobody thinks of as a layout. Pinned here so a
    /// later case added in the obvious place — the end of the list, or beside
    /// the thing it resembles — cannot quietly reshuffle the nav.
    func testMakeSectionOrder() {
        XCTAssertEqual(Destination.inSection(.make),
                       [.studio, .actions, .styleTransfer, .workbench])
        XCTAssertEqual(Destination.inSection(.browse), [.library, .models])
    }

    /// Every destination is in exactly one section and none has been dropped.
    func testEveryDestinationIsPlacedOnce() {
        let placed = Destination.Section.allCases.flatMap(Destination.inSection)
        XCTAssertEqual(Set(placed), Set(Destination.allCases))
        XCTAssertEqual(placed.count, Destination.allCases.count)
    }

    // MARK: - the Style Transfer glyph

    private func points(_ shape: BenchNavGlyph.Sine, in rect: CGRect) -> [CGPoint] {
        var points: [CGPoint] = []
        shape.path(in: rect).forEach { element in
            switch element {
            case .move(let to): points.append(to)
            case .line(let to): points.append(to)
            default: break
            }
        }
        return points
    }

    /// The claim the glyph makes is that the two waves are the same wave 180°
    /// apart. That is only true if every point of one is the reflection of the
    /// matching point of the other in the box's centre line — a phase of, say,
    /// π/2 would still look wavy and would no longer mean anything.
    func testTheTwoWavesAreExactMirrors() {
        let box = CGRect(x: 0, y: 0, width: 13, height: 13)
        let upper = points(BenchNavGlyph.upperWave, in: box)
        let lower = points(BenchNavGlyph.lowerWave, in: box)
        XCTAssertEqual(upper.count, lower.count)
        XCTAssertFalse(upper.isEmpty)
        for (top, bottom) in zip(upper, lower) {
            XCTAssertEqual(top.x, bottom.x, accuracy: 0.0001,
                           "the waves must sample the same x positions")
            XCTAssertEqual((top.y + bottom.y) / 2, box.midY, accuracy: 0.0001,
                           "\(top.y) and \(bottom.y) are not equal and opposite "
                           + "about \(box.midY)")
        }
    }

    /// They must also stay apart. Overlapping mirrored sines cross at every
    /// node, which at this size reads as a knot rather than as two waves.
    func testTheWavesDoNotMeetInTheMiddle() {
        let box = CGRect(x: 0, y: 0, width: 13, height: 13)
        let upper = points(BenchNavGlyph.upperWave, in: box)
        let lower = points(BenchNavGlyph.lowerWave, in: box)
        let lowestOfTheUpper = upper.map(\.y).max() ?? 0
        let highestOfTheLower = lower.map(\.y).min() ?? 0
        // Half a stroke each, plus something to see between them.
        XCTAssertGreaterThan(highestOfTheLower - lowestOfTheUpper,
                             BenchNavGlyph.waveWidth,
                             "the two waves touch or cross")
    }

    /// And stay inside the glyph's box, or the nav's one column of marks stops
    /// being a column.
    func testTheGlyphStaysInsideItsBox() {
        let box = CGRect(x: 0, y: 0, width: 13, height: 13)
        for wave in [BenchNavGlyph.upperWave, BenchNavGlyph.lowerWave] {
            let drawn = wave.path(in: box).boundingRect
                .insetBy(dx: -BenchNavGlyph.waveWidth / 2,
                         dy: -BenchNavGlyph.waveWidth / 2)
            XCTAssertTrue(box.insetBy(dx: -0.01, dy: -0.01).contains(drawn),
                          "\(drawn) escapes \(box)")
        }
    }
}

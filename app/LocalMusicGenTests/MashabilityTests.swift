import XCTest
@testable import LocalMusicGen

final class MashabilityTests: XCTestCase {

    // MARK: camelot / key

    func testIdenticalKeysScoreFull() throws {
        let match = try XCTUnwrap(Mashability.keyMatch(source: "8A", target: "8A"))
        XCTAssertEqual(match.score, 1.0)
        XCTAssertEqual(match.pitchShiftSt, 0)
        XCTAssertEqual(match.quality, .green)
    }

    func testRelativeMajorMinor() throws {
        let match = try XCTUnwrap(Mashability.keyMatch(source: "8A", target: "8B"))
        XCTAssertEqual(match.score, 0.9)
        XCTAssertEqual(match.pitchShiftSt, 0)
    }

    func testAdjacentCamelotNumber() throws {
        let match = try XCTUnwrap(Mashability.keyMatch(source: "8A", target: "9A"))
        XCTAssertEqual(match.score, 0.8)
        XCTAssertEqual(match.pitchShiftSt, 0)
    }

    func testOneSemitoneReachesExactKey() throws {
        // +1 st moves the camelot number by +7: 8A → 3A
        let match = try XCTUnwrap(Mashability.keyMatch(source: "8A", target: "3A"))
        XCTAssertEqual(match.pitchShiftSt, 1)
        XCTAssertEqual(match.score, 0.9, accuracy: 1e-9)   // 1.0 × 0.9¹
    }

    func testTwoSemitonesReach() throws {
        // +2 st: 8A → 10A
        let match = try XCTUnwrap(Mashability.keyMatch(source: "8A", target: "10A"))
        XCTAssertEqual(match.pitchShiftSt, 2)
        XCTAssertEqual(match.score, 0.81, accuracy: 1e-9)  // 1.0 × 0.9²
    }

    func testUnreachableKeyScoresZero() throws {
        let match = try XCTUnwrap(Mashability.keyMatch(source: "8A", target: "12B"))
        XCTAssertEqual(match.score, 0)
        XCTAssertEqual(match.quality, .red)
    }

    func testMalformedCamelotIsNil() {
        XCTAssertNil(Mashability.keyMatch(source: "13A", target: "8A"))
        XCTAssertNil(Mashability.keyMatch(source: nil, target: "8A"))
        XCTAssertNil(Mashability.keyMatch(source: "8C", target: "8A"))
    }

    // MARK: tempo

    func testIdenticalTempoIsGreen() throws {
        let match = try XCTUnwrap(Mashability.tempoMatch(source: 120, target: 120))
        XCTAssertEqual(match.stretchPercent, 0, accuracy: 1e-9)
        XCTAssertEqual(match.quality(), .green)
        XCTAssertFalse(match.halfTimeFold)
    }

    func testAmberBandAndDrumsStricter() throws {
        // 100 → 112: 12% stretch — amber for melodic, red for drums (>10%)
        let match = try XCTUnwrap(Mashability.tempoMatch(source: 100, target: 112))
        XCTAssertEqual(match.stretchPercent, 12.0, accuracy: 0.01)
        XCTAssertEqual(match.quality(), .amber)
        XCTAssertEqual(match.quality(forDrums: true), .red)
    }

    func testDrumsRequantizeHint() throws {
        // over the drums band → actionable hint; melodic rows never get it,
        // and an in-band drums stretch stays hint-free
        let over = try XCTUnwrap(Mashability.tempoMatch(source: 100, target: 112))
        XCTAssertEqual(over.hint(forDrums: true),
                       "Too big a stretch for drums — re-quantize or pick "
                       + "a closer tempo")
        XCTAssertNil(over.hint(forDrums: false))
        let inBand = try XCTUnwrap(Mashability.tempoMatch(source: 100, target: 104))
        XCTAssertNil(inBand.hint(forDrums: true))
    }

    func testOctaveFolding() throws {
        // a 70 BPM ballad rides a 140 BPM grid without stretching
        let match = try XCTUnwrap(Mashability.tempoMatch(source: 70, target: 140))
        XCTAssertTrue(match.halfTimeFold)
        XCTAssertEqual(match.stretchPercent, 0, accuracy: 1e-9)
        XCTAssertEqual(match.stretchRatio, 1.0, accuracy: 1e-9)
    }

    func testStretchRatioDirection() throws {
        // slower source must speed UP: ratio > 1
        let match = try XCTUnwrap(Mashability.tempoMatch(source: 98, target: 124 / 2 * 2))
        XCTAssertEqual(match.stretchRatio, 124.0 / 98.0, accuracy: 1e-6)
    }

    // MARK: spectral features

    func testHarmonicIdenticalChroma() throws {
        let bar: [[Int]] = (0..<16).map { i in
            var v = [Int](repeating: 10, count: 12)
            v[i % 12] = 255
            return v
        }
        let sim = try XCTUnwrap(Mashability.harmonic(source: bar, target: bar))
        XCTAssertGreaterThan(sim, 0.95)
    }

    func testHarmonicAbsentIsNil() {
        XCTAssertNil(Mashability.harmonic(source: nil, target: [[1, 2]]))
        XCTAssertNil(Mashability.harmonic(source: [[1]], target: [[1]]))  // < 4 beats
    }

    func testSpectralComplementarity() throws {
        let bass: [Double] = [0.7, 0.3, 0, 0, 0, 0, 0, 0]
        let hats: [Double] = [0, 0, 0, 0, 0, 0, 0.4, 0.6]
        let complementary = try XCTUnwrap(
            Mashability.spectral(source: bass, target: hats))
        XCTAssertGreaterThan(complementary, 0.95)
        let clashing = try XCTUnwrap(
            Mashability.spectral(source: bass, target: bass))
        XCTAssertLessThan(clashing, 0.05)
    }

    // MARK: plan

    func testPlanCombinesSignals() {
        let source = AnalysisSummary(bpm: 100, camelot: "8A",
                                     downbeats: [0, 2, 4])
        let target = AnalysisSummary(bpm: 104, camelot: "8B")
        let plan = Mashability.plan(source: source, target: target)
        XCTAssertEqual(plan.pitchShiftSt, 0)
        XCTAssertEqual(try XCTUnwrap(plan.stretchRatio), 1.04, accuracy: 1e-9)
        XCTAssertGreaterThan(plan.badges.stars, 3)
    }

    func testPlanDropsRedStretch() {
        // 100 → 140 is a 40% stretch: unusable, plan offers no ratio
        let plan = Mashability.plan(
            source: AnalysisSummary(bpm: 100, camelot: "8A"),
            target: AnalysisSummary(bpm: 140, camelot: "8A"))
        XCTAssertNil(plan.stretchRatio)
    }

    func testPlanUnknownSignalsAreNeutral() {
        let plan = Mashability.plan(source: AnalysisSummary(),
                                    target: AnalysisSummary())
        XCTAssertNil(plan.badges.tempo)
        XCTAssertNil(plan.badges.key)
        XCTAssertEqual(plan.pitchShiftSt, 0)
        XCTAssertGreaterThan(plan.badges.stars, 1.5)
        XCTAssertLessThan(plan.badges.stars, 4.5)
    }
}

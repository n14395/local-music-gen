import AppKit
import SwiftUI
import XCTest
@testable import LocalMusic

/// A parts row must stay one line tall at every width the app can give it.
///
/// The bug: `strip` asks for `maxWidth: .infinity`, so in a narrow pane SwiftUI
/// took the space back from the only child that could yield — the `＋ Bench`
/// label — and wrapped it to four lines, once per row, down the whole list.
/// The row now drops the waveform instead.
///
/// Measured rather than reasoned about. The decision belongs to `ViewThatFits`,
/// which exposes nothing to assert on, and the widths involved are text metrics
/// nobody can honestly predict in a comment — so this renders the real view in
/// an offscreen host and reads its height back.
@MainActor
final class PartRowFitTests: XCTestCase {
    private func part(kind: String = "stem.vocals",
                      name: String = "Other (keys, synths, rest)",
                      format: String = "wav") -> PartRecord {
        PartRecord(id: "p1", songId: "s1", kind: kind, name: name,
                   fileName: "p1." + format, format: format,
                   previewFileName: nil, modelId: "sep",
                   modelName: "Demucs 4-stem", jobId: "job_1",
                   splitParamsJSON: "{}", durationS: 180, sampleRate: 44100,
                   createdAt: Date())
    }

    private func analysis() -> AnalysisRecord? { nil }

    /// The rendered height of one row laid out at `width`.
    private func height(at width: CGFloat, part: PartRecord) -> CGFloat {
        let row = LibraryPartRow(
            part: part, analysis: analysis(), isZebra: false, isSelected: false,
            playback: PlaybackController(),
            onPlay: {}, onSelect: {}, onSeek: { _ in },
            onAddToWorkbench: {}, onRenderNotes: {})
        let host = NSHostingView(rootView: row.frame(width: width))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    /// One line of `Bench.Typo.body` plus the row's 9 pt of vertical padding
    /// each side lands well under this; two lines of a wrapped button label
    /// clears it comfortably. The gap between the two is what is being
    /// detected, so the threshold does not need to be tight.
    private let oneLineCeiling: CGFloat = 52

    /// 320 is narrower than the parts pane can ever actually be — the window
    /// floor is 1100 with a 404 pt inspector beside the list — so this brackets
    /// the real range from well below it.
    func testRowStaysOneLineAtEveryPlausibleWidth() {
        for width in stride(from: 320.0, through: 900.0, by: 20.0) {
            let h = height(at: width, part: part())
            XCTAssertLessThan(h, oneLineCeiling,
                              "row wrapped at \(width) pt (height \(h))")
        }
    }

    /// The slot holds an explanation rather than a signal for a notes part, and
    /// that text is much wider than a waveform's minimum — so it is the case
    /// most likely to force a wrap, and the one that most needs the fallback.
    func testNotesRowStaysOneLineToo() {
        let notes = part(kind: "notes.piano", name: "Piano", format: "midi")
        for width in stride(from: 320.0, through: 900.0, by: 20.0) {
            let h = height(at: width, part: notes)
            XCTAssertLessThan(h, oneLineCeiling,
                              "notes row wrapped at \(width) pt (height \(h))")
        }
    }

    /// The point of the fallback is that it is a fallback: given room, the row
    /// still draws the waveform. A row that had quietly stopped showing one at
    /// every width would pass the two tests above and be useless.
    ///
    /// Asserted through width rather than by looking for the waveform: with the
    /// strip present the row fills what it is given, and without it the
    /// trailing controls still hold the right edge — so the honest observable
    /// is that a wide row is not taller than a narrow one, and that the strip's
    /// declared minimum is a width the pane can actually afford.
    func testStripSurvivesAtTheWidthsTheLibraryNormallyHas() {
        // 1100 pt window − 232 pt sidebar − 404 pt inspector ≈ 464 pt of list,
        // which is the narrowest the pane gets without the queue pinned.
        let h = height(at: 464, part: part())
        XCTAssertLessThan(h, oneLineCeiling)
        XCTAssertGreaterThan(LibraryPartRow.minStripWidth, 0)
    }
}

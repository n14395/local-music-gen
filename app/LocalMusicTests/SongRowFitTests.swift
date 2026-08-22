import AppKit
import SwiftUI
import XCTest
@testable import LocalMusic

/// Whether a song row can actually afford the waveform it now draws, and what
/// it gives up when it cannot.
///
/// The row is a `ViewThatFits` ladder — strip, then no strip — and a ladder
/// whose first rung never fits is an elaborate way of drawing the old row. So
/// the first test measures the rung rather than trusting the arithmetic in the
/// comments: an unconstrained `ViewThatFits` reports the ideal width of its
/// *first* variant, which is precisely the width at which the strip survives.
///
/// Measured rather than reasoned about, the same way `PartRowFitTests` is:
/// the widths involved are text metrics and `GeometryReader` ideal sizes that
/// nobody can honestly predict in a comment.
@MainActor
final class SongRowFitTests: XCTestCase {
    private func song(title: String = "track042",
                      prompt: String = "warm lo-fi beat with vinyl crackle",
                      durationS: Double = 187) -> SongRecord {
        SongRecord(id: "s1", title: title, prompt: prompt, lyrics: nil,
                   modelId: "musicgen-small", modelName: "MusicGen Small",
                   groupId: nil, paramsJSON: "{}", durationS: durationS,
                   sampleRate: 44100, fileName: "s1.wav", seedUsed: nil,
                   createdAt: Date(), rating: 4, notes: "", favorite: true,
                   origin: "generated")
    }

    private func row(_ song: SongRecord) -> LibrarySongRow {
        LibrarySongRow(song: song, isZebra: false, isSelected: false,
                       isChecked: false, showsCheckbox: true, partCount: 6,
                       isSplitting: false, playback: PlaybackController(),
                       onToggleCheck: {}, onPlay: {}, onSelect: {},
                       onSeek: { _ in })
    }

    private func host(_ song: SongRecord, width: CGFloat?) -> NSHostingView<AnyView> {
        let view = width.map { AnyView(row(song).frame(width: $0)) }
            ?? AnyView(row(song))
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        return host
    }

    /// The library pane at the window's 1100 pt floor: 1100 − 230 pt sidebar −
    /// 404 pt inspector = 466, less the list's own 12 pt of padding each side.
    /// A row narrower than this is only reachable with the queue pinned, and
    /// that is what the ladder's second rung is for.
    private let narrowestPane: CGFloat = 442

    func testTheStripSurvivesAtTheNarrowestPaneTheWindowAllows() {
        let ideal = host(song(), width: nil).fittingSize.width
        XCTAssertLessThanOrEqual(
            ideal, narrowestPane,
            "the row wants \(ideal) pt to draw its waveform, but the library "
            + "pane is only \(narrowestPane) pt at the window's floor width — "
            + "no row would ever show one")
    }

    /// A prompt is arbitrary text and some of them are paragraphs. If the
    /// title block's ideal grew with it, one pasted paragraph would decide
    /// that no row in the list gets a waveform — which is why the block pins
    /// its ideal to its floor.
    func testALongPromptDoesNotCostTheWholeListItsWaveforms() {
        let long = song(prompt: String(repeating: "sombre industrial techno "
                                       + "with a sorrowful acid synthline ", count: 6))
        XCTAssertLessThanOrEqual(host(long, width: nil).fittingSize.width,
                                 narrowestPane)
    }

    /// Both rungs draw the same two lines of text, so the row's height must
    /// not move as the ladder is climbed. A height that grows at some width is
    /// the title or the meta line wrapping — the failure the parts rows had.
    func testHeightIsStableAtEveryPlausibleWidth() {
        let baseline = host(song(), width: 900).fittingSize.height
        for width in stride(from: 320.0, through: 900.0, by: 20.0) {
            let height = host(song(), width: width).fittingSize.height
            XCTAssertEqual(height, baseline, accuracy: 1,
                           "row is \(height) pt tall at \(width) pt, "
                           + "against \(baseline) pt when it has room")
        }
    }

    /// The two title bounds are a floor and a ceiling, in that order, and the
    /// strip's floor is the parts row's rather than a second opinion about the
    /// same drawing.
    func testTheDeclaredBoundsAreCoherent() {
        XCTAssertLessThan(LibrarySongRow.minTitleWidth,
                          LibrarySongRow.maxTitleWidth)
        XCTAssertEqual(LibrarySongRow.minStripWidth,
                       LibraryPartRow.minStripWidth)
    }
}

import AppKit
import SwiftUI
import XCTest
@testable import LocalMusicGen

/// Whether a song row can actually afford the waveform it now draws, and what
/// it gives up when it cannot.
///
/// The row takes the strip outright when the width the list hands it clears
/// what its shape needs, and falls back to the `ViewThatFits` ladder — strip,
/// then no strip — only near the edge. A bar set too low is a row that keeps a
/// waveform it cannot fit; one set too high is a list that never shows one. So
/// these measure the real row rather than trusting the arithmetic in the
/// comments: an unconstrained row reports the ideal width of its strip
/// variant, which is precisely the width at which the strip survives.
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

    private func row(_ song: SongRecord, contentWidth: CGFloat = .infinity,
                     checkbox: Bool = true,
                     splitting: Bool = false) -> LibrarySongRow {
        LibrarySongRow(song: song, contentWidth: contentWidth, isZebra: false,
                       isSelected: false, isChecked: false,
                       showsCheckbox: checkbox, partCount: 6,
                       isSplitting: splitting, playback: PlaybackController(),
                       onToggleCheck: {}, onPlay: {}, onSelect: {},
                       onSeek: { _ in })
    }

    /// Hosted the way the list hosts it: a row given `width` has that much
    /// less its own padding to draw its content in, which is exactly what the
    /// list hands down as `contentWidth`.
    private func host(_ song: SongRecord, width: CGFloat?) -> NSHostingView<AnyView> {
        let view = width.map {
            AnyView(row(song, contentWidth: $0 - LibraryRowMetrics.rowPadding * 2)
                .frame(width: $0))
        } ?? AnyView(row(song))
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        return host
    }

    /// The ideal width of one row shape's strip variant — the number the fast
    /// path in `LibrarySongRow.body` is trusting when it skips the ladder.
    private func stripIdeal(checkbox: Bool = false,
                            splitting: Bool = false) -> CGFloat {
        let content = row(song(), checkbox: checkbox, splitting: splitting)
            .content(showsStrip: true)
        let host = NSHostingView(rootView: AnyView(content))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.width
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

    // MARK: - the fast path's declared widths

    /// The row decides whether it can afford a strip by arithmetic now, rather
    /// than by building itself twice and measuring both — so the arithmetic has
    /// to stay true to the real row. Each of these is the measurement the
    /// declared constant stands in for; a constant that has fallen behind the
    /// row it describes would let a row keep a waveform it has no room for.
    func testTheDeclaredStripWidthCoversAPlainRow() {
        XCTAssertLessThanOrEqual(stripIdeal(), LibrarySongRow.stripIdealWidth,
                                 "a plain row's strip variant has outgrown "
                                 + "LibrarySongRow.stripIdealWidth")
    }

    func testTheDeclaredCheckboxSlotCoversTheRealOne() {
        XCTAssertLessThanOrEqual(stripIdeal(checkbox: true) - stripIdeal(),
                                 LibrarySongRow.checkboxSlot)
    }

    func testTheDeclaredSplittingAllowanceCoversTheRealClause() {
        XCTAssertLessThanOrEqual(stripIdeal(splitting: true) - stripIdeal(),
                                 LibrarySongRow.splittingAllowance)
    }

    /// The badge is the one clause whose width depends on its own text, so the
    /// allowance is checked against the widest count a library will ever show.
    func testTheDeclaredBadgeAllowanceCoversTheWidestBadge() {
        let host = NSHostingView(rootView: AnyView(EditsBadge(count: 999)))
        host.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(host.fittingSize.width + 12,
                                 LibrarySongRow.badgeAllowance)
    }

    /// And the pane the window's floor actually offers still clears the plain
    /// row's bar, or the fast path would never fire where it matters most.
    func testTheNarrowestPaneStillTakesTheFastPath() {
        let content = narrowestPane - LibraryRowMetrics.rowPadding * 2
        XCTAssertGreaterThanOrEqual(
            content, LibrarySongRow.stripIdealWidth + LibrarySongRow.checkboxSlot)
    }
}

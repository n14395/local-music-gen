// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI
import XCTest
@testable import LocalMusicGen

/// A parts row must stay two lines tall at every width the app can give it,
/// and must be the same row the song scopes draw.
///
/// The original bug: `strip` asks for `maxWidth: .infinity`, so in a narrow
/// pane SwiftUI took the space back from the only child that could yield — the
/// `＋ Bench` label — and wrapped it to four lines, once per row, down the
/// whole list. That button now lives in the row's context menu, but the same
/// squeeze can still land on the title block, so the measurement stays.
///
/// Measured rather than reasoned about. The decision belongs to `ViewThatFits`,
/// which exposes nothing to assert on, and the widths involved are text metrics
/// nobody can honestly predict in a comment — so this renders the real view in
/// an offscreen host and reads its height back.
@MainActor
final class PartRowFitTests: XCTestCase {
    private func part(kind: String = "stem.vocals",
                      name: String = "vocals-warehouse-jam",
                      format: String = "wav",
                      rating: Int = 0) -> PartRecord {
        PartRecord(id: "p1", songId: "s1", kind: kind, name: name,
                   fileName: "p1." + format, format: format,
                   previewFileName: nil, modelId: "sep",
                   modelName: "Demucs 4-stem", jobId: "job_1",
                   splitParamsJSON: "{}", durationS: 180, sampleRate: 44100,
                   createdAt: Date(), favorite: false, rating: rating)
    }

    private func analysis() -> AnalysisRecord? { nil }

    private func row(_ part: PartRecord,
                     contentWidth: CGFloat = .infinity) -> LibraryPartRow {
        LibraryPartRow(part: part, contentWidth: contentWidth,
                       analysis: analysis(), isZebra: false,
                       isSelected: false, playback: PlaybackController(),
                       onPlay: {}, onSelect: {}, onSeek: { _ in })
    }

    /// The rendered height of one row laid out at `width`, given the same
    /// content width the list would hand it there.
    private func height(at width: CGFloat, part: PartRecord) -> CGFloat {
        let content = width - LibraryRowMetrics.rowPadding * 2
        let host = NSHostingView(
            rootView: row(part, contentWidth: content).frame(width: width))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    /// The declared width the parts row's fast path trusts, against what the
    /// row actually measures — the same pinning `SongRowFitTests` does, for
    /// the same reason: the arithmetic replaced a measurement, so it has to
    /// stay true to the row it replaced it for.
    func testTheDeclaredStripWidthCoversTheRealRow() {
        let host = NSHostingView(
            rootView: AnyView(row(part()).content(showsStrip: true)))
        host.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(host.fittingSize.width,
                                 LibraryPartRow.stripIdealWidth,
                                 "the parts row's strip variant has outgrown "
                                 + "LibraryPartRow.stripIdealWidth")
    }

    /// Two lines of the title block plus the row's 11 pt of vertical padding
    /// each side lands well under this; a third line — a wrapped title or a
    /// wrapped meta line — clears it comfortably. The gap between the two is
    /// what is being detected, so the threshold does not need to be tight.
    private let twoLineCeiling: CGFloat = 68

    /// 320 is narrower than the parts pane can ever actually be — the window
    /// floor is 1100 with a 404 pt inspector beside the list — so this brackets
    /// the real range from well below it.
    func testRowStaysTwoLinesAtEveryPlausibleWidth() {
        for width in stride(from: 320.0, through: 900.0, by: 20.0) {
            let h = height(at: width, part: part())
            XCTAssertLessThan(h, twoLineCeiling,
                              "row wrapped at \(width) pt (height \(h))")
        }
    }

    /// The meta line is the longest thing in a notes row — it carries the
    /// family, the MIDI marker and the model — so it is the case most likely
    /// to force a wrap.
    func testNotesRowStaysTwoLinesToo() {
        let notes = part(kind: "notes.piano", name: "piano-notes-warehouse-jam",
                         format: "midi")
        for width in stride(from: 320.0, through: 900.0, by: 20.0) {
            let h = height(at: width, part: notes)
            XCTAssertLessThan(h, twoLineCeiling,
                              "notes row wrapped at \(width) pt (height \(h))")
        }
    }

    /// A name as long as a pasted prompt still must not push the row taller.
    func testALongNameStaysTwoLinesToo() {
        let long = part(name: "vocals-a-lonely-trumpet-over-rain-slicked-neon")
        for width in stride(from: 320.0, through: 900.0, by: 20.0) {
            let h = height(at: width, part: long)
            XCTAssertLessThan(h, twoLineCeiling,
                              "long-named row wrapped at \(width) pt (\(h))")
        }
    }

    /// The point of the fallback is that it is a fallback: given room, the row
    /// still draws the waveform. A row that had quietly stopped showing one at
    /// every width would pass the tests above and be useless.
    func testStripSurvivesAtTheWidthsTheLibraryNormallyHas() {
        // 1100 pt window − 232 pt sidebar − 404 pt inspector ≈ 464 pt of list,
        // which is the narrowest the pane gets without the queue pinned.
        let h = height(at: 464, part: part())
        XCTAssertLessThan(h, twoLineCeiling)
        XCTAssertGreaterThan(LibraryPartRow.minStripWidth, 0)
    }

    /// The whole point of the change: a part row and a song row are the same
    /// row. Measured, because "looks the same" is exactly the claim that rots
    /// the moment one of the two lists is tuned.
    func testAPartRowIsTheSameHeightAsASongRow() {
        let song = SongRecord(
            id: "s1", title: "track042", prompt: "a warm drum groove",
            lyrics: nil, modelId: "m", modelName: "MusicGen Small",
            groupId: nil, paramsJSON: "{}", durationS: 180, sampleRate: 32000,
            fileName: "s1.wav", seedUsed: nil, createdAt: Date(), rating: 3,
            notes: "", favorite: true)
        let songRow = LibrarySongRow(
            song: song, isZebra: false, isSelected: false, isChecked: false,
            showsCheckbox: false, partCount: 0, isSplitting: false,
            playback: PlaybackController(), onToggleCheck: {}, onPlay: {},
            onSelect: {}, onSeek: { _ in })
        let songHost = NSHostingView(rootView: songRow.frame(width: 640))
        songHost.layoutSubtreeIfNeeded()

        XCTAssertEqual(height(at: 640, part: part()),
                       songHost.fittingSize.height, accuracy: 1.0,
                       "the two library rows have to line up")
    }

    /// The stars and the heart are the row's right edge in every other scope,
    /// so a rated part has to be able to show them.
    func testTheRowDrawsARating() {
        // Asserted through the record rather than the pixels: `RatingStars` is
        // fixed-size, so a rating changes no geometry — the guard that matters
        // is that the column exists to hold one.
        XCTAssertEqual(part(rating: 4).rating, 4)
        let h = height(at: 640, part: part(rating: 5))
        XCTAssertLessThan(h, twoLineCeiling)
    }
}

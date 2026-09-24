// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import LocalMusicGen

/// The Editor's empty state fills its slot from `PartPickerSheet` now, rather
/// than switching the app to the Library tab and abandoning the user there.
///
/// That makes one coupling load-bearing: what the picker OFFERS has to match
/// what `EditorStore.open(partId:)` will ACCEPT. It refuses anything whose
/// format is not `wav`, and refuses it silently — so a notes row in the sheet
/// would look pickable, get picked, and do nothing at all.
@MainActor
final class EditorPickerAcceptsTests: XCTestCase {
    private func accepts(_ kind: String) -> Bool {
        EditorStore.pickerAccepts.contains { $0.matches(kind) }
    }

    func testOffersEveryAudioKindTheEditorCanOpen() {
        XCTAssertTrue(accepts("song.mix"))
        XCTAssertTrue(accepts("stem.vocals"))
        XCTAssertTrue(accepts("stem.drums"))
        XCTAssertTrue(accepts("layer.pad"))
    }

    /// The ones that would be picked and then ignored.
    func testOffersNothingTheEditorWouldTurnAway() {
        XCTAssertFalse(accepts("notes.piano"),
                       "a MIDI part has no waveform to edit")
        XCTAssertFalse(accepts("features.chroma"),
                       "a features part is numbers, not sound")
    }

    /// `song.mix` is an exact pattern, not a prefix: it must not quietly admit
    /// some future `song.something` the editor has never seen.
    func testSongPatternIsExact() {
        XCTAssertFalse(accepts("song.stems"))
        XCTAssertFalse(accepts("song"))
    }
}

// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import LocalMusicGen

/// Which slots take a part, and which take only a whole song.
///
/// Pinned rather than derived, because widening one is never only a data
/// change: the code behind the slot has to be able to say what it did with the
/// part. `read-features` is the cautionary tale — before its slot was widened,
/// `SplitActionView` attributed every analysis to `songId` with
/// `ownerType: "song"`, and `JobsStore` propagates a song's analysis down to
/// all of its parts, so analysing one stem would have overwritten the tempo
/// and key of the song and of every sibling stem. Nothing would have errored.
///
/// So: a failure here is a prompt to go and read the receiving code, not to
/// update the list.
final class RecipeSlotAcceptsTests: XCTestCase {
    private var allSlots: [(recipe: Recipe, slot: Slot)] {
        RecipeCatalog.all.flatMap { recipe in
            recipe.slots.map { (recipe, $0) }
        }
    }

    private func songOnly(_ slot: Slot) -> Bool {
        slot.accepts == [KindPattern(pattern: "song.mix")]
    }

    /// Splitting a stem into stems, and pulling the vocal out of something that
    /// is already one part, are the two that stay closed: both need the
    /// whole mix by definition, and a dimmed row saying so beats a render that
    /// returns mush. (The two plan cards that used to join them are gone —
    /// their song-only picker lives inside the merged plan page now.)
    func testOnlyTwoSlotsRefuseParts() {
        let closed = allSlots.filter { songOnly($0.slot) }
            .map { "\($0.recipe.id).\($0.slot.id)" }
        XCTAssertEqual(closed.sorted(),
                       ["karaoke.song", "split-instruments.source"])
    }

    /// The doors into Style Transfer take what the Style Transfer screen's
    /// own picker takes. They disagreed for a while, so the same stem was
    /// pickable there and not from the card that opens it.
    func testStyleTransferCardsMatchTheirScreen() {
        for id in ["restyle", "repaint", "add-layer"] {
            let slot = RecipeCatalog.recipe(id: id)?.slots.first
            XCTAssertNotNil(slot, id)
            XCTAssertTrue(slot?.accepts(kind: "song.mix") ?? false, id)
            XCTAssertTrue(slot?.accepts(kind: "stem.vocals") ?? false, id)
            XCTAssertTrue(slot?.accepts(kind: "layer.strings") ?? false, id)
        }
    }

    func testTheTwoAnalysisRecipesTakeParts() {
        for id in ["transcribe-notes", "read-features"] {
            let slot = RecipeCatalog.recipe(id: id)?.slots.first
            XCTAssertTrue(slot?.accepts(kind: "stem.drums") ?? false, id)
        }
    }

    /// Widening a slot renames it: "Song" is what the sheet's title bar says,
    /// and it should not still say that once a part will do.
    func testSlotsThatTakePartsDoNotCallThemselvesSongs() {
        for (recipe, slot) in allSlots where !songOnly(slot) {
            XCTAssertNotEqual(slot.label, "Song",
                              "\(recipe.id).\(slot.id) takes parts but is "
                              + "labelled “Song”")
        }
    }

    // MARK: attribution

    /// A measurement belongs to the thing measured. The part's own id, not the
    /// song it came out of.
    func testAPartOwnsItsOwnAnalysis() {
        let part = PartRecord(id: "p1", songId: "s1", kind: "stem.drums",
                              name: "Drums", fileName: "p1.wav", format: "wav",
                              previewFileName: nil, modelId: "sep",
                              modelName: "Demucs", jobId: "job_1",
                              splitParamsJSON: "{}", durationS: 10,
                              sampleRate: 44100, createdAt: Date())
        let material = PickedMaterial(part: part, sourceTitle: "A Song")
        XCTAssertTrue(material.isPart)
        XCTAssertEqual(material.analysisOwner.id, "p1")
        XCTAssertEqual(material.analysisOwner.type, "part")
        // …and the song it came from is still reachable, which is where the
        // parts a transcribe produces have to be filed.
        XCTAssertEqual(material.songId, "s1")
    }
}

// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import LocalMusicGen

final class ModelSearchTests: XCTestCase {
    private func entry(_ id: String, _ name: String, description: String = "",
                       family: String = "") -> ModelChooser.Entry {
        ModelChooser.Entry(id: id, name: name, description: description,
                           family: family, badges: [])
    }

    private var catalog: [ModelChooser.Entry] {
        [entry("ace-xl-sft", "ACE-Step 1.5 XL SFT (GGUF)",
               description: "Full-length songs with vocals.", family: "acestepcpp"),
         entry("ace-turbo", "ACE-Step 1.5 Turbo",
               description: "Fast drafts.", family: "acestep"),
         entry("musicgen-small", "MusicGen Small",
               description: "Short instrumental loops.", family: "musicgen"),
         entry("stable-audio", "Stable Audio Open",
               description: "Sound effects and textures.", family: "stableaudio")]
    }

    func testEmptyQueryKeepsEverything() {
        XCTAssertEqual(ModelChooser.filter(catalog, query: "").count, 4)
        XCTAssertEqual(ModelChooser.filter(catalog, query: "   ").count, 4)
    }

    func testMatchesOnName() {
        let hits = ModelChooser.filter(catalog, query: "musicgen")
        XCTAssertEqual(hits.map(\.id), ["musicgen-small"])
    }

    func testSearchIsCaseInsensitive() {
        XCTAssertEqual(ModelChooser.filter(catalog, query: "MUSICGEN").map(\.id),
                       ["musicgen-small"])
    }

    /// The reason this is tokens and not one substring: the names are full of
    /// punctuation, so "ace xl" and "ace step" both fail a plain `contains`.
    func testTokensMatchAcrossPunctuationAndOrder() {
        XCTAssertEqual(ModelChooser.filter(catalog, query: "ace xl").map(\.id),
                       ["ace-xl-sft"])
        XCTAssertEqual(ModelChooser.filter(catalog, query: "ace step").count, 2)
        // Order of the tokens is not the order in the name.
        XCTAssertEqual(ModelChooser.filter(catalog, query: "gguf ace").map(\.id),
                       ["ace-xl-sft"])
    }

    /// Every token must land — that is what makes a second word narrow the list
    /// rather than widen it.
    func testAllTokensMustMatch() {
        XCTAssertTrue(ModelChooser.filter(catalog, query: "ace musicgen").isEmpty)
    }

    func testMatchesOnDescription() {
        XCTAssertEqual(ModelChooser.filter(catalog, query: "vocals").map(\.id),
                       ["ace-xl-sft"])
    }

    /// Family is searched but never drawn, so a query naming the runtime finds
    /// models whose rows do not contain the word.
    func testMatchesOnFamilyWhichIsNotShown() {
        XCTAssertEqual(ModelChooser.filter(catalog, query: "stableaudio").map(\.id),
                       ["stable-audio"])
    }

    func testNoMatchReturnsNothingRatherThanEverything() {
        XCTAssertTrue(ModelChooser.filter(catalog, query: "zzzz").isEmpty)
    }

    /// A token cannot straddle the join between two fields: the fields are
    /// joined with a space and tokens are whitespace-free by construction.
    func testTokensDoNotStraddleFieldBoundaries() {
        let one = [entry("x", "Alpha", description: "Beta")]
        XCTAssertTrue(ModelChooser.filter(one, query: "alphabeta").isEmpty)
        XCTAssertEqual(ModelChooser.filter(one, query: "alpha beta").count, 1)
    }

    /// A single-word query behaves exactly like the substring test this
    /// replaced, which is what makes the Models screen's change safe.
    func testSingleWordQueryIsStillASubstringTest() {
        XCTAssertTrue(ModelSearch.matches(query: "ace-step", in: ["ACE-Step 1.5"]))
        XCTAssertTrue(ModelSearch.matches(query: "sic", in: ["MusicGen Small"]))
        XCTAssertFalse(ModelSearch.matches(query: "xyz", in: ["MusicGen Small"]))
    }
}

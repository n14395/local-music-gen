// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import LocalMusicGen

/// Which part of a row's first line gives way when the row runs out of width.
/// The bug this pins: a title with no prompt suffix was held at its full
/// intrinsic width, so anything sharing the row (the library's rating stars)
/// was squeezed until it wrapped one star per line and then disappeared.
final class TrackTitleLayoutTests: XCTestCase {
    func testTitleIsHeldWholeOnlyWhileThePromptCanTruncateInstead() {
        XCTAssertTrue(TrackTitle(title: "track007",
                                 prompt: "warm lo-fi beat").keepsTitleWhole)
    }

    func testTitleYieldsWhenItStandsAlone() {
        // legacy tracks titled with their own prompt: nothing else on the line
        // can absorb the truncation, so the title must
        let legacy = "Industrial sombre techno with a sorrowful acid synthline"
        XCTAssertFalse(TrackTitle(title: legacy, prompt: legacy).keepsTitleWhole)
        // imported and recombined tracks carry no prompt at all
        XCTAssertFalse(TrackTitle(title: "field recording",
                                  prompt: "").keepsTitleWhole)
    }
}

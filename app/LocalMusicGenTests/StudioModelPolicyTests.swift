// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import LocalMusicGen

/// Settings' opening-model policy, resolved against the installed list.
/// Every policy answers nil when its pick is missing, so the composer falls
/// back to catalog order rather than opening empty.
@MainActor
final class StudioModelPolicyTests: XCTestCase {
    private let installed: [(id: String, isFavourite: Bool)] = [
        ("musicgen-small", false),
        ("acestep-base", true),
        ("stableaudio-small", true),
    ]

    private func pick(_ policy: AppSettings.StudioModelPolicy,
                      lastUsed: String? = nil,
                      fixed: String? = nil) -> String? {
        StudioView.preferredModelId(policy: policy, lastUsed: lastUsed,
                                    fixed: fixed, installed: installed)
    }

    func testCatalogOrderExpressesNoPreference() {
        XCTAssertNil(pick(.catalogOrder, lastUsed: "acestep-base",
                          fixed: "acestep-base"))
    }

    func testLastUsedWinsWhenStillInstalled() {
        XCTAssertEqual(pick(.lastUsed, lastUsed: "stableaudio-small"),
                       "stableaudio-small")
    }

    func testAMissingLastUsedFallsThrough() {
        XCTAssertNil(pick(.lastUsed, lastUsed: "deleted-model"))
        XCTAssertNil(pick(.lastUsed))
    }

    /// First *installed* favourite, in catalog order — not the first
    /// favourite the user ever hearted.
    func testFavouritePicksTheFirstInstalledFavourite() {
        XCTAssertEqual(pick(.favourite), "acestep-base")
        XCTAssertNil(StudioView.preferredModelId(
            policy: .favourite, lastUsed: nil, fixed: nil,
            installed: [("musicgen-small", false)]))
    }

    func testFixedHonoursTheChoiceOnlyWhileInstalled() {
        XCTAssertEqual(pick(.fixed, fixed: "musicgen-small"), "musicgen-small")
        XCTAssertNil(pick(.fixed, fixed: "deleted-model"))
        XCTAssertNil(pick(.fixed))
    }
}

// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import LocalMusicGen

/// The delivery policy Settings feeds `NotificationService`. The per-event
/// switches are guards at the call sites in `AppEnvironment.notify(for:)`;
/// what is testable without a notification centre is the delivery decision
/// and the defaults that keep unwired callers on the historical behavior.
@MainActor
final class NotificationPolicyTests: XCTestCase {
    typealias Prefs = NotificationService.Prefs

    /// The defaults are the pre-Settings behavior exactly: enabled,
    /// background-only, sound, bounce.
    func testDefaultsMatchTheHistoricalBehavior() {
        let prefs = Prefs()
        XCTAssertTrue(prefs.enabled)
        XCTAssertFalse(prefs.alwaysDeliver)
        XCTAssertTrue(prefs.sound)
        XCTAssertTrue(prefs.dockBounce)
    }

    func testUnpromptedNoticesRespectTheMasterSwitch() {
        XCTAssertFalse(NotificationService.deliversUnprompted(
            prefs: Prefs(enabled: false), appActive: false))
        XCTAssertFalse(NotificationService.deliversUnprompted(
            prefs: Prefs(enabled: false, alwaysDeliver: true), appActive: true))
    }

    func testBackgroundOnlyIsTheDefaultAndAlwaysDeliverLiftsIt() {
        XCTAssertTrue(NotificationService.deliversUnprompted(
            prefs: Prefs(), appActive: false))
        XCTAssertFalse(NotificationService.deliversUnprompted(
            prefs: Prefs(), appActive: true))
        XCTAssertTrue(NotificationService.deliversUnprompted(
            prefs: Prefs(alwaysDeliver: true), appActive: true))
    }
}

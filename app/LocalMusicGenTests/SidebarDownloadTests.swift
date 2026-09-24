// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import LocalMusicGen

/// The sidebar reports one download out of everything in flight, from every
/// screen. These pin which one it picks and what it is allowed to claim —
/// notably that a runtime install, which has no bytes at all, never borrows the
/// vocabulary of a transfer that does.
final class SidebarDownloadTests: XCTestCase {

    private func download(_ id: String, model: String = "m1",
                          state: DownloadState = .downloading,
                          done: Int64 = 1_073_741_824,
                          total: Int64 = 10_737_418_240,
                          speed: Int64 = 12_000_000,
                          stage: String = "weights",
                          message: String? = nil,
                          runtimeOnly: Bool = false) -> DownloadInfo {
        DownloadInfo(downloadId: id, modelId: model, state: state,
                     bytesDone: done, bytesTotal: total, speedBps: speed,
                     stage: stage, message: message, runtimeOnly: runtimeOnly)
    }

    private func model(_ id: String, name: String) -> ModelInfo {
        ModelInfo(id: id, family: "acestep", displayName: name, description: "",
                  hfRepos: [], sizeBytes: 1, installState: .downloading,
                  installedBytes: 0,
                  capabilities: Capabilities(
                      supportsLyrics: true, instrumentalOnly: false,
                      duration: DurationSpec(minS: 1, maxS: 300, defaultS: 60),
                      sampleRate: 48000, outputsPerJobMax: 1,
                      estSecondsPerAudioSecond: 1, params: []),
                  requirements: Requirements(minRamBytes: 1, diskBytes: 0,
                                             speedTier: .fast),
                  license: LicenseInfo(name: "MIT", commercialUse: true,
                                       requiresHfToken: false, url: nil))
    }

    // MARK: - Which one

    func testNothingInFlightIsNoCard() {
        XCTAssertNil(SidebarDownload.make(downloads: [], models: []))
    }

    /// Transfers run one at a time (contract §4.2), so the card follows the one
    /// that is moving and counts the rest rather than showing whichever id
    /// happens to sort first.
    func testTheMovingOneWinsAndTheRestAreCounted() {
        let made = SidebarDownload.make(downloads: [
            download("dl_a", state: .queued),
            download("dl_b", state: .downloading),
            download("dl_c", state: .queued),
        ], models: [])
        XCTAssertEqual(made?.info.downloadId, "dl_b")
        XCTAssertEqual(made?.others, 2)
        XCTAssertEqual(made?.othersLine, "+2 MORE WAITING")
    }

    /// A download that has reached provisioning has given its transfer slot
    /// back, so it outranks the suspended and the waiting but not the one now
    /// pulling bytes.
    func testProvisioningOutranksPausedAndQueued() {
        let made = SidebarDownload.make(downloads: [
            download("dl_a", state: .paused),
            download("dl_b", state: .provisioning, stage: "provisioning"),
            download("dl_c", state: .queued),
        ], models: [])
        XCTAssertEqual(made?.info.downloadId, "dl_b")
    }

    /// Progress events arrive twice a second; two equals that swapped on each
    /// one would make the card unreadable.
    func testEqualsBreakOnTheIdSoTheCardCannotFlicker() {
        let pair = [download("dl_b", state: .queued),
                    download("dl_a", state: .queued)]
        XCTAssertEqual(SidebarDownload.make(downloads: pair, models: [])?
            .info.downloadId, "dl_a")
        XCTAssertEqual(SidebarDownload.make(downloads: pair.reversed(),
                                            models: [])?.info.downloadId, "dl_a")
    }

    func testTheNameComesFromTheCatalogAndFallsBackToTheId() {
        let named = SidebarDownload.make(downloads: [download("dl_a", model: "ace")],
                                         models: [model("ace", name: "ACE-Step 1.5")])
        XCTAssertEqual(named?.title, "ACE-Step 1.5")

        // A download outlives a catalogue that has not refreshed yet.
        let unknown = SidebarDownload.make(downloads: [download("dl_a", model: "ace")],
                                           models: [])
        XCTAssertEqual(unknown?.title, "ace")
    }

    // MARK: - What it says

    func testATransferReportsItsShareAndLeavesTheLineToTheView() {
        let made = SidebarDownload.make(downloads: [
            download("dl_a", done: 5_368_709_120, total: 10_737_418_240),
        ], models: [])
        XCTAssertEqual(made?.eyebrow, "DOWNLOADING")
        XCTAssertEqual(made?.fraction, 0.5)
        XCTAssertEqual(made?.showsSpinner, false, "the bar is the moving part")
        // Nil means "ask the view" — the smoothed rate lives with what is on
        // screen, not here.
        XCTAssertNil(made?.staticDetail)
    }

    /// The state that has no bytes to count: a bar drawn at zero for it would
    /// read as a stalled download.
    func testARuntimeInstallSpinsAndSaysWhatTheInstallerIsDoing() {
        let made = SidebarDownload.make(downloads: [
            download("dl_a", state: .provisioning, done: 0, total: 0, speed: 0,
                     stage: "provisioning", message: "Resolving torch",
                     runtimeOnly: true),
        ], models: [])
        XCTAssertEqual(made?.eyebrow, "INSTALLING RUNTIME")
        XCTAssertNil(made?.fraction)
        XCTAssertEqual(made?.showsSpinner, true)
        XCTAssertEqual(made?.staticDetail, "RESOLVING TORCH")
    }

    func testARuntimeInstallWithNothingToSayStillSaysSomething() {
        let made = SidebarDownload.make(downloads: [
            download("dl_a", state: .provisioning, done: 0, total: 0, speed: 0,
                     stage: "provisioning"),
        ], models: [])
        XCTAssertEqual(made?.staticDetail, "SETTING UP THE RUNTIME")
    }

    /// Stopped is stopped, whatever it was stopped in the middle of: nothing
    /// spins, and the eyebrow does not claim an install is under way.
    func testStoppedStatesNeverSpinOrClaimProgress() {
        for state in [DownloadState.paused, .queued] {
            let made = SidebarDownload.make(downloads: [
                download("dl_a", state: state, done: 0, total: 0, speed: 0,
                         runtimeOnly: true),
            ], models: [])
            XCTAssertEqual(made?.showsSpinner, false)
            XCTAssertEqual(made?.eyebrow, state == .paused ? "PAUSED" : "QUEUED")
        }
    }

    /// A transfer whose first progress event has not landed yet: no total, so
    /// nothing to measure, but it is not a runtime install either.
    func testATransferWithNoTotalYetSaysItIsStarting() {
        let made = SidebarDownload.make(downloads: [
            download("dl_a", done: 0, total: 0, speed: 0),
        ], models: [])
        XCTAssertEqual(made?.eyebrow, "DOWNLOADING")
        XCTAssertEqual(made?.staticDetail, "STARTING…")
    }

    func testASingleDownloadHasNothingBehindIt() {
        let made = SidebarDownload.make(downloads: [download("dl_a")], models: [])
        XCTAssertEqual(made?.others, 0)
        XCTAssertNil(made?.othersLine)
    }

    // MARK: - The shared transfer line

    /// Three places draw a download now. The branch they share lives in one
    /// place so two of them cannot start describing one download differently.
    func testTheTransferLineIsHonestAboutRateAndETA() {
        var rate = DownloadRate()
        rate.ingest(12_000_000)

        let moving = DownloadFormat.transferLine(
            download("dl_a", done: 5_368_709_120, total: 10_737_418_240),
            rate: rate)
        XCTAssertEqual(moving, "5.0 / 10.0 GB · 12 MB/S · 7 MIN LEFT")

        // Nothing is transferring in either of these, so neither may quote the
        // tail of the smoother's last window as a speed.
        XCTAssertEqual(DownloadFormat.transferLine(
            download("dl_a", state: .paused, done: 5_368_709_120,
                     total: 10_737_418_240), rate: rate),
                       "5.0 / 10.0 GB · PAUSED")
        XCTAssertEqual(DownloadFormat.transferLine(
            download("dl_a", state: .queued, done: 5_368_709_120,
                     total: 10_737_418_240), rate: rate),
                       "5.0 / 10.0 GB · WAITING")
    }

    /// What the row a finished transfer leaves behind says. Never "ready to
    /// use": the weights are one half of an install, and the family runtime
    /// may still be missing.
    func testTheFinishedLineSaysWhatHappened() {
        XCTAssertEqual(DownloadFormat.finishedLine(bytes: 10_093_173_145,
                                                   runtimeOnly: false,
                                                   failure: nil),
                       "9.4 GB · DOWNLOADED")
        // A completion this app never saw move has no size to quote.
        XCTAssertEqual(DownloadFormat.finishedLine(bytes: 0, runtimeOnly: false,
                                                   failure: nil),
                       "DOWNLOADED")
        // A runtime install fetched no weights, so it names neither a size nor
        // a download.
        XCTAssertEqual(DownloadFormat.finishedLine(bytes: 0, runtimeOnly: true,
                                                   failure: nil),
                       "RUNTIME INSTALLED")
        XCTAssertEqual(DownloadFormat.finishedLine(bytes: 12, runtimeOnly: false,
                                                   failure: "connection reset"),
                       "FAILED · CONNECTION RESET")
        XCTAssertEqual(DownloadFormat.finishedLine(bytes: 0, runtimeOnly: false,
                                                   failure: "  "),
                       "FAILED")
    }
}

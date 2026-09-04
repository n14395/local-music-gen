import XCTest
@testable import LocalMusic

/// The registry behind the status strip, "Reset this section" and search.
///
/// Its whole value is being right. The strip's job is to make the Reset button
/// beside it trustworthy — "9 SETTINGS IN THIS SECTION · 3 CHANGED FROM
/// DEFAULT" is only worth printing if the 3 is true — and a default recorded
/// here that disagrees with the one `AppSettings` actually loads would make
/// every one of those numbers quietly wrong. So the check below is against the
/// store rather than against a second list: a fresh `AppSettings` *is* the
/// defaults, and every entry has to agree with it.
@MainActor
final class SettingsCatalogTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "settings-catalog-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func freshSettings() -> AppSettings { AppSettings(defaults: defaults) }

    // MARK: - The defaults are the store's

    func testEveryEntryAgreesWithAFreshStore() {
        let settings = freshSettings()
        for entry in SettingsCatalog.all {
            XCTAssertTrue(
                entry.isDefault(settings),
                "\(entry.id) claims a default the store does not load. Its "
                + "section's status strip will report it as changed on a "
                + "clean install.")
        }
    }

    func testAFreshWindowReportsNothingChanged() {
        let settings = freshSettings()
        for pane in SettingsPane.allCases {
            XCTAssertEqual(SettingsCatalog.changedCount(in: pane, settings), 0,
                           "\(pane.rawValue) opens claiming edits nobody made")
        }
    }

    func testResetAllPreferencesLandsOnTheCatalogsDefaults() {
        let settings = freshSettings()
        moveEverything(settings)
        settings.resetAllPreferences()
        for entry in SettingsCatalog.all {
            XCTAssertTrue(entry.isDefault(settings),
                          "\(entry.id) survived Reset all preferences")
        }
    }

    // MARK: - Counting

    func testAChangedSettingIsCountedInItsOwnSectionOnly() {
        let settings = freshSettings()
        settings.dockBounce = false          // Notifications
        XCTAssertEqual(SettingsCatalog.changedCount(in: .notifications, settings), 1)
        for pane in SettingsPane.allCases where pane != .notifications {
            XCTAssertEqual(SettingsCatalog.changedCount(in: pane, settings), 0,
                           "\(pane.rawValue) counted another section's edit")
        }
    }

    func testEverySectionHoldsAtLeastOneSetting() {
        // A section whose strip reads "0 SETTINGS IN THIS SECTION" is either a
        // registry gap or a section that should not be in the rail.
        for pane in SettingsPane.allCases {
            XCTAssertGreaterThan(SettingsCatalog.entries(in: pane).count, 0,
                                 "\(pane.rawValue) has no registered settings")
        }
    }

    func testIdsAreUnique() {
        let ids = SettingsCatalog.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count,
                       "duplicate ids collide in the search results list")
    }

    // MARK: - Reset

    func testResettingASectionLeavesEveryOtherSectionAlone() {
        let settings = freshSettings()
        moveEverything(settings)
        SettingsCatalog.reset(pane: .notifications, settings)

        XCTAssertEqual(SettingsCatalog.changedCount(in: .notifications, settings), 0)
        for pane in SettingsPane.allCases where pane != .notifications {
            XCTAssertGreaterThan(
                SettingsCatalog.changedCount(in: pane, settings), 0,
                "resetting Notifications reached into \(pane.rawValue)")
        }
    }

    func testResettingEverySectionIsAFullReset() {
        let settings = freshSettings()
        moveEverything(settings)
        for pane in SettingsPane.allCases {
            SettingsCatalog.reset(pane: pane, settings)
        }
        for entry in SettingsCatalog.all {
            XCTAssertTrue(entry.isDefault(settings),
                          "\(entry.id) was not restored by its section's reset")
        }
    }

    /// The policy and the model it names are one row and one entry; a reset
    /// that moved the policy back and left the model behind would leave the
    /// Studio opening on a model the user can no longer see chosen anywhere.
    func testTheOpeningModelResetsAsAPair() {
        let settings = freshSettings()
        settings.studioModelPolicy = .fixed
        settings.studioFixedModelId = "musicgen-small"
        XCTAssertEqual(SettingsCatalog.changedCount(in: .generation, settings), 1)

        SettingsCatalog.reset(pane: .generation, settings)
        XCTAssertEqual(settings.studioModelPolicy, .lastUsed)
        XCTAssertNil(settings.studioFixedModelId)
    }

    // MARK: - Search

    func testSearchFindsBySubstringOfTheTitle() {
        let hits = SettingsCatalog.search("dock")
        XCTAssertEqual(hits.first?.id, "dockBounce")
    }

    func testSearchFindsByKeywordThatIsNotInTheTitle() {
        // "lufs" appears nowhere in "Normalize to".
        XCTAssertTrue(SettingsCatalog.search("lufs").contains { $0.id == "targetLufs" })
    }

    func testSearchFindsAWholeSectionByName() {
        let hits = SettingsCatalog.search("engine")
        XCTAssertTrue(hits.contains { $0.pane == .engine })
    }

    func testAPrefixMatchOutranksAKeywordMatch() {
        let hits = SettingsCatalog.search("notify")
        XCTAssertEqual(hits.first?.id, "notificationsEnabled",
                       "\u{201C}Notify me\u{201D} should lead a search for "
                       + "\u{201C}notify\u{201D}")
    }

    func testOneLetterMatchesNothing() {
        // Otherwise the results list flashes up on the way to a real query.
        XCTAssertTrue(SettingsCatalog.search("n").isEmpty)
    }

    // MARK: - Helper

    /// Every registered setting moved off its default, so a reset has
    /// something to undo. Uses each entry's own `isDefault` to check the move
    /// landed, which keeps this honest as settings are added.
    private func moveEverything(_ settings: AppSettings) {
        settings.confirmDeletes = false
        settings.confirmRevert = false
        settings.confirmQuitWhileRendering = false
        settings.reduceMotion = true
        settings.notificationsEnabled = false
        settings.notifyAlways = true
        settings.notificationSound = false
        settings.dockBounce = false
        settings.autoArmRenders = true
        settings.notifyTrackReady = false
        settings.notifyJobFailed = false
        settings.notifyDownloadCompleted = false
        settings.notifyDownloadFailed = false
        settings.notifyEngineWarning = false
        settings.notifyEditsApplied = false
        settings.studioModelPolicy = .favourite
        settings.defaultDurationS = 42
        settings.defaultTakes = 3
        settings.holdSeed = true
        settings.autoAnalyze = false
        settings.analyzerModelId = "analysis-basic"
        settings.autoDescribe = true
        settings.describerModelId = "caption-lpmusiccaps"
        settings.autoTagScan = true
        settings.taggerModelId = "tag-clap"
        settings.autoLyrics = true
        settings.lyricsTranscriberModelId = "lyrics-whisper-turbo"
        settings.assistantModelId = "assistant-qwen"
        settings.assistantTemperature = 1.2
        settings.defaultSeparatorId = "separation-basic"
        settings.targetLufs = -9
        settings.autoMatchTempo = false
        settings.autoMatchKey = false
        settings.keepStems = true
        settings.nowPlayingEnabled = false
        settings.deleteToTrash = false
        settings.exportFormat = "aiff"
        settings.exportDepth = "float32"
        settings.libraryDefaultSort = .rating
        settings.libraryRemembersSort = true
        settings.backupsCapGB = 5
        settings.hfHomePath = "/tmp/some-library"
        settings.queueAutoClear = .afterMinute
        settings.smallResidency = .keepAlways
        settings.smallWarmSlots = 4
        settings.smallModelBytes = 3_000_000_000
        settings.memGuardPercent = 60
        settings.maxActiveDownloads = 3
        settings.engineLogLevel = "debug"
        settings.engineFileRetentionDays = 30

        for entry in SettingsCatalog.all {
            XCTAssertFalse(entry.isDefault(settings),
                           "\(entry.id) is registered but this helper never "
                           + "moves it, so the reset tests never exercise it")
        }
    }
}

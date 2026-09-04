import XCTest
@testable import LocalMusic

/// The Settings store: defaults, the legacy key rename, reset, and the queue
/// auto-clear policy it feeds `JobsStore`.
@MainActor
final class AppSettingsTests: XCTestCase {
    /// A named suite rather than `.standard`: the test host is the app
    /// bundle, so its standard defaults are the user's real preferences.
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "app-settings-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - Defaults

    func testACleanSlateReadsTheDocumentedDefaults() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(settings.autoAnalyze)
        XCTAssertTrue(settings.deleteToTrash)
        XCTAssertEqual(settings.libraryDefaultSort, .newest)
        XCTAssertFalse(settings.libraryRemembersSort)
        XCTAssertEqual(settings.queueAutoClear, .never)
    }

    func testValuesRoundTripThroughDefaults() {
        let first = AppSettings(defaults: defaults)
        first.autoAnalyze = false
        first.deleteToTrash = false
        first.libraryDefaultSort = .rating
        first.queueAutoClear = .afterTenMinutes

        let second = AppSettings(defaults: defaults)
        XCTAssertFalse(second.autoAnalyze)
        XCTAssertFalse(second.deleteToTrash)
        XCTAssertEqual(second.libraryDefaultSort, .rating)
        XCTAssertEqual(second.queueAutoClear, .afterTenMinutes)
    }

    /// An unrecognised stored value — a downgrade, a hand-edited plist —
    /// falls back to the default rather than crashing or sticking.
    func testGarbageStoredValuesFallBackToDefaults() {
        defaults.set("sideways", forKey: "settings.library.defaultSort")
        defaults.set("whenever", forKey: "settings.queue.autoClear")
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.libraryDefaultSort, .newest)
        XCTAssertEqual(settings.queueAutoClear, .never)
    }

    // MARK: - Legacy key migration

    func testLegacyKeysAreRenamedAndRemoved() {
        defaults.set(true, forKey: "showAllModels")
        defaults.set(["m1", "m2"], forKey: "acceptedLicenses")
        defaults.set(["m3"], forKey: "favouriteModels")

        AppSettings.migrateLegacyKeys(in: defaults)

        XCTAssertTrue(defaults.bool(forKey: "models.showAll"))
        XCTAssertEqual(Set(defaults.stringArray(forKey: "catalog.acceptedLicenses") ?? []),
                       ["m1", "m2"])
        XCTAssertEqual(defaults.stringArray(forKey: "catalog.favourites"), ["m3"])
        XCTAssertNil(defaults.object(forKey: "showAllModels"))
        XCTAssertNil(defaults.object(forKey: "acceptedLicenses"))
        XCTAssertNil(defaults.object(forKey: "favouriteModels"))
    }

    /// A value already under the new key wins — the old key is stale by
    /// definition once anything has written the new one.
    func testMigrationNeverClobbersTheNewKey() {
        defaults.set(["old"], forKey: "favouriteModels")
        defaults.set(["new"], forKey: "catalog.favourites")
        AppSettings.migrateLegacyKeys(in: defaults)
        XCTAssertEqual(defaults.stringArray(forKey: "catalog.favourites"), ["new"])
    }

    func testMigrationRunsOnce() {
        AppSettings.migrateLegacyKeys(in: defaults)
        // A legacy key written *after* the migration (say, by an old build
        // sharing the container) must stay put rather than resurrecting.
        defaults.set(["late"], forKey: "favouriteModels")
        AppSettings.migrateLegacyKeys(in: defaults)
        XCTAssertEqual(defaults.stringArray(forKey: "favouriteModels"), ["late"])
        XCTAssertNil(defaults.object(forKey: "catalog.favourites"))
    }

    /// Constructing the store is what runs the migration — the store reads
    /// nothing legacy itself, but `ModelCatalogStore` is built right after it.
    func testInitMigrates() {
        defaults.set(["m1"], forKey: "acceptedLicenses")
        _ = AppSettings(defaults: defaults)
        XCTAssertEqual(defaults.stringArray(forKey: "catalog.acceptedLicenses"),
                       ["m1"])
    }

    // MARK: - Reset

    func testResetAllPreferencesRestoresDefaultsAndDropsFeatureKeys() {
        let settings = AppSettings(defaults: defaults)
        settings.queueAutoClear = .afterMinute
        defaults.set(3, forKey: "onboarding.completedVersion")
        defaults.set(true, forKey: "queue.pinned")
        defaults.set("full", forKey: "studio.mode")

        settings.resetAllPreferences()

        XCTAssertEqual(settings.queueAutoClear, .never)
        XCTAssertNil(defaults.object(forKey: "onboarding.completedVersion"))
        XCTAssertNil(defaults.object(forKey: "queue.pinned"))
        XCTAssertNil(defaults.object(forKey: "studio.mode"))
    }

    func testTargetedResets() {
        let settings = AppSettings(defaults: defaults)
        defaults.set(2, forKey: "onboarding.completedVersion")
        defaults.set(true, forKey: "analysisToolsCardDismissed")
        defaults.set("{\"a\":1}", forKey: "actions.lastRuns")

        settings.showWelcomeAgain()
        XCTAssertEqual(defaults.integer(forKey: "onboarding.completedVersion"), 0)

        settings.resetDismissedHints()
        XCTAssertNil(defaults.object(forKey: "analysisToolsCardDismissed"))

        settings.clearRecentActions()
        XCTAssertNil(defaults.object(forKey: "actions.lastRuns"))
    }

    // MARK: - Auto-clear policy

    func testAutoClearSecondsMapping() {
        XCTAssertNil(AppSettings.QueueAutoClear.never.seconds)
        XCTAssertEqual(AppSettings.QueueAutoClear.afterMinute.seconds, 60)
        XCTAssertEqual(AppSettings.QueueAutoClear.afterTenMinutes.seconds, 600)
    }

    // MARK: - Engine launch config

    /// Every knob reaches the child process env under its contract name; the
    /// cache root is only set when the user picked one, so the engine's own
    /// `HF_HOME`-then-default resolution still applies otherwise.
    func testEngineEnvironmentAssembly() {
        let config = EngineLaunchConfig(
            memGuardBytes: 123, smallWarmSlots: 3, smallWarmTTLS: 0,
            smallModelBytes: 2_000_000_000, maxActiveDownloads: 2,
            hfHome: nil, auxCache: nil, logLevel: "debug",
            outputsRetentionDays: 7)
        let env = config.environment
        XCTAssertEqual(env["LOCALMUSIC_MEM_GUARD_BYTES"], "123")
        XCTAssertEqual(env["LOCALMUSIC_SMALL_WARM_SLOTS"], "3")
        XCTAssertEqual(env["LOCALMUSIC_SMALL_WARM_TTL_S"], "0")
        XCTAssertEqual(env["LOCALMUSIC_SMALL_MODEL_BYTES"], "2000000000")
        XCTAssertEqual(env["LOCALMUSIC_MAX_ACTIVE_DOWNLOADS"], "2")
        XCTAssertEqual(env["LOCALMUSIC_OUTPUTS_RETENTION_DAYS"], "7")
        XCTAssertNil(env["HF_HOME"])
        XCTAssertNil(env["LOCALMUSIC_AUX_CACHE"])
        XCTAssertEqual(config.arguments, ["--log-level", "debug"])

        var withCache = config
        withCache.hfHome = "/Volumes/Big/hf"
        XCTAssertEqual(withCache.environment["HF_HOME"], "/Volumes/Big/hf")
        // The two roots move together but not to the same place, so the
        // auxiliary one is carried as its own value rather than derived.
        withCache.auxCache = "/Volumes/Big/hf/localmusic-aux"
        XCTAssertEqual(withCache.environment["LOCALMUSIC_AUX_CACHE"],
                       "/Volumes/Big/hf/localmusic-aux")
    }

    /// A relocate is the only thing that sets these, and it sets both: the
    /// engine names the auxiliary destination on the completion event, and
    /// nil means "wherever the engine puts it by default".
    func testAuxCachePathPersistsLikeTheLibraryFolder() {
        var settings = AppSettings(defaults: defaults)
        XCTAssertNil(settings.auxCachePath)
        XCTAssertNil(settings.engineLaunchConfig.auxCache)

        settings.hfHomePath = "/Volumes/Big/Models"
        settings.auxCachePath = "/Volumes/Big/Models/localmusic-aux"
        settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.auxCachePath,
                       "/Volumes/Big/Models/localmusic-aux")
        XCTAssertEqual(settings.engineLaunchConfig.environment[
            "LOCALMUSIC_AUX_CACHE"], "/Volumes/Big/Models/localmusic-aux")

        settings.auxCachePath = nil
        XCTAssertNil(AppSettings(defaults: defaults).auxCachePath)
    }

    func testEngineConfigFromSettings() {
        let settings = AppSettings(defaults: defaults)
        // Defaults mirror the engine's own.
        var config = settings.engineLaunchConfig
        XCTAssertEqual(config.smallWarmSlots, 2)
        XCTAssertEqual(config.smallWarmTTLS, 600)
        XCTAssertEqual(config.smallModelBytes, 1_500_000_000)
        XCTAssertEqual(config.maxActiveDownloads, 1)
        XCTAssertEqual(config.logLevel, "info")
        XCTAssertEqual(config.outputsRetentionDays, 14)
        XCTAssertNil(config.hfHome)
        let ram = Double(ProcessInfo.processInfo.physicalMemory)
        XCTAssertEqual(config.memGuardBytes, Int(ram * 0.9))

        settings.memGuardPercent = 0
        settings.smallResidency = .keepAlways
        config = settings.engineLaunchConfig
        XCTAssertEqual(config.memGuardBytes, 0, "0 disables the guard")
        XCTAssertEqual(config.smallWarmTTLS, 315_360_000,
                       "\u{201C}always\u{201D} is a TTL longer than any session")
    }

    /// The pending-restart banner is a plain value comparison — same knobs,
    /// no banner; one knob moved, banner.
    func testLaunchConfigEqualityDrivesTheRestartBanner() {
        let settings = AppSettings(defaults: defaults)
        let launched = settings.engineLaunchConfig
        XCTAssertEqual(settings.engineLaunchConfig, launched)
        settings.maxActiveDownloads = 3
        XCTAssertNotEqual(settings.engineLaunchConfig, launched)
    }
}

/// The sweep that enforces the auto-clear policy, driven by hand-fed clocks
/// so nothing here sleeps.
@MainActor
final class QueueAutoClearTests: XCTestCase {
    private func store() throws -> JobsStore {
        let db = try DatabaseManager.inMemory()
        return JobsStore(repo: LibraryRepository(db: db),
                         partsRepo: PartsRepository(db: db))
    }

    private func job(_ id: String, _ status: JobStatus) -> JobsStore.ActiveJob {
        let info = JobInfo(
            jobId: id, groupId: "grp", modelId: "m", task: nil, status: status,
            queuePosition: nil, prompt: id, lyrics: nil, durationS: 4,
            count: 1, params: [:], createdAt: "2026-08-23T10:00:00Z",
            progress: nil, result: nil, error: nil)
        return JobsStore.ActiveJob(info: info, status: status)
    }

    func testFinishedRowsClearOnlyAfterTheDeadline() throws {
        let jobs = try store()
        jobs.autoClearAfterS = { 60 }
        jobs.adopt(job("done", .succeeded))
        jobs.adopt(job("running", .generating))

        let t0 = Date()
        // First sight stamps the row; nothing is old enough to go.
        jobs.sweepFinished(now: t0)
        XCTAssertNotNil(jobs.job("done"))

        jobs.sweepFinished(now: t0.addingTimeInterval(30))
        XCTAssertNotNil(jobs.job("done"), "half the grace is not the grace")

        jobs.sweepFinished(now: t0.addingTimeInterval(61))
        XCTAssertNil(jobs.job("done"))
        XCTAssertNotNil(jobs.job("running"),
                        "work is never auto-cleared, only the record")
    }

    /// The clock starts when the row is first *seen* finished, not when the
    /// policy is turned on — so flipping the setting with a day-old row on
    /// screen gives it the full grace from that moment, not instant removal.
    func testRowsFinishedBeforeThePolicyGetTheFullGrace() throws {
        let jobs = try store()
        jobs.adopt(job("old", .succeeded))
        jobs.autoClearAfterS = { 60 }

        let t0 = Date()
        jobs.sweepFinished(now: t0)
        XCTAssertNotNil(jobs.job("old"))
        jobs.sweepFinished(now: t0.addingTimeInterval(61))
        XCTAssertNil(jobs.job("old"))
    }

    func testNoPolicyMeansNoClearing() throws {
        let jobs = try store()
        jobs.adopt(job("done", .succeeded))
        jobs.sweepFinished(now: Date.distantFuture)
        XCTAssertNotNil(jobs.job("done"))
    }

    /// A row dismissed by hand between ticks must not leave a stamp behind
    /// that outlives it — ids are re-stamped if the job somehow returns.
    func testDismissedRowsDropTheirStamps() throws {
        let jobs = try store()
        jobs.autoClearAfterS = { 60 }
        jobs.adopt(job("done", .succeeded))
        let t0 = Date()
        jobs.sweepFinished(now: t0)
        jobs.dismiss("done")

        jobs.adopt(job("done", .succeeded))
        // Were the stale stamp kept, this tick would dismiss immediately.
        jobs.sweepFinished(now: t0.addingTimeInterval(120))
        XCTAssertNotNil(jobs.job("done"))
    }
}

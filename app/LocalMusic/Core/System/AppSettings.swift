import Foundation
import Observation

/// Every preference the Settings window owns, in one observable store.
///
/// Feature screens keep their own view state (`studio.mode`, `queue.pinned`,
/// `workbench.lens`, …) in `@AppStorage` where it always was; this store holds
/// the *policies* — the choices that change how the app behaves rather than
/// how one screen currently looks. Stored properties with a `didSet` write,
/// because `@Observable` tracks stored properties and a computed pass-through
/// to `UserDefaults` would not publish.
///
/// Consumers that need a live read from outside the view tree (stores, the
/// dependency container) take a closure reading this object, not a copied
/// value — a Settings toggle must apply to work already in flight.
@MainActor @Observable
final class AppSettings {
    /// How long a finished queue row stays before it is dismissed on the
    /// user's behalf. There is no "on quit": the queue is in-memory on both
    /// sides, so rows never survive a relaunch anyway.
    enum QueueAutoClear: String, CaseIterable {
        case never, afterMinute, afterTenMinutes

        var seconds: TimeInterval? {
            switch self {
            case .never: nil
            case .afterMinute: 60
            case .afterTenMinutes: 600
            }
        }

        var label: String {
            switch self {
            case .never: "When I dismiss them"
            case .afterMinute: "After a minute"
            case .afterTenMinutes: "After 10 minutes"
            }
        }
    }

    // MARK: General

    /// Ask before deleting songs and parts. Model deletion always asks — a
    /// re-download is measured in gigabytes, not a Trash restore.
    var confirmDeletes: Bool {
        didSet { defaults.set(confirmDeletes, forKey: "settings.general.confirmDeletes") }
    }

    /// Ask before reverting a track to its stashed original.
    var confirmRevert: Bool {
        didSet { defaults.set(confirmRevert, forKey: "settings.general.confirmRevert") }
    }

    /// Ask before quitting while a generation is still rendering.
    var confirmQuitWhileRendering: Bool {
        didSet {
            defaults.set(confirmQuitWhileRendering,
                         forKey: "settings.general.confirmQuit")
        }
    }

    /// Skip the panel slide animations.
    var reduceMotion: Bool {
        didSet { defaults.set(reduceMotion, forKey: "settings.general.reduceMotion") }
    }

    // MARK: Notifications

    /// Master switch over every notice the app raises on its own initiative.
    /// A job the user armed by hand ("Notify me when it lands") bypasses it:
    /// pressing that button *is* consent, given later and more specifically
    /// than this toggle was.
    var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: "settings.notifications.enabled") }
    }

    /// Deliver even while the app is frontmost. Off, notices only arrive once
    /// you have switched away — the long-standing default.
    var notifyAlways: Bool {
        didSet { defaults.set(notifyAlways, forKey: "settings.notifications.always") }
    }

    var notificationSound: Bool {
        didSet { defaults.set(notificationSound, forKey: "settings.notifications.sound") }
    }

    /// Bounce the Dock icon alongside each notification.
    var dockBounce: Bool {
        didSet { defaults.set(dockBounce, forKey: "settings.notifications.dockBounce") }
    }

    /// Arm every Generate render as if "Notify me when it lands" had been
    /// pressed on it.
    var autoArmRenders: Bool {
        didSet { defaults.set(autoArmRenders, forKey: "settings.notifications.autoArm") }
    }

    // Per-event switches, all on by default — the master toggle above is the
    // one that silences everything.
    var notifyTrackReady: Bool {
        didSet { defaults.set(notifyTrackReady, forKey: "settings.notifications.trackReady") }
    }
    var notifyJobFailed: Bool {
        didSet { defaults.set(notifyJobFailed, forKey: "settings.notifications.jobFailed") }
    }
    var notifyDownloadCompleted: Bool {
        didSet { defaults.set(notifyDownloadCompleted, forKey: "settings.notifications.downloadCompleted") }
    }
    var notifyDownloadFailed: Bool {
        didSet { defaults.set(notifyDownloadFailed, forKey: "settings.notifications.downloadFailed") }
    }
    var notifyEngineWarning: Bool {
        didSet { defaults.set(notifyEngineWarning, forKey: "settings.notifications.engineWarning") }
    }
    var notifyEditsApplied: Bool {
        didSet { defaults.set(notifyEditsApplied, forKey: "settings.notifications.editsApplied") }
    }

    // MARK: Generation

    /// How Generate picks the model it opens on.
    enum StudioModelPolicy: String, CaseIterable {
        /// The one you last pressed Generate with.
        case lastUsed
        /// The first installed favourite, catalog order breaking ties.
        case favourite
        /// A specific model, chosen in Settings.
        case fixed
        /// The first installed generator, as the catalog lists them — the
        /// pre-Settings behavior.
        case catalogOrder

        var label: String {
            switch self {
            case .lastUsed: "The one I last used"
            case .favourite: "My first favourite"
            case .fixed: "A specific model"
            case .catalogOrder: "First installed"
            }
        }
    }

    var studioModelPolicy: StudioModelPolicy {
        didSet {
            defaults.set(studioModelPolicy.rawValue,
                         forKey: "settings.generation.modelPolicy")
        }
    }

    /// The model `StudioModelPolicy.fixed` points at.
    var studioFixedModelId: String? {
        didSet { setOrRemove(studioFixedModelId, "settings.generation.fixedModelId") }
    }

    /// What the last Generate actually ran — written by the Studio at submit,
    /// read back by `StudioModelPolicy.lastUsed`.
    var studioLastModelId: String? {
        didSet { setOrRemove(studioLastModelId, "settings.generation.lastModelId") }
    }

    /// Length the Studio's slider starts at, clamped per model on arrival.
    var defaultDurationS: Double {
        didSet { defaults.set(defaultDurationS, forKey: "settings.generation.defaultDurationS") }
    }

    var defaultTakes: Int {
        didSet { defaults.set(defaultTakes, forKey: "settings.generation.defaultTakes") }
    }

    /// Reuse the last render's seed for the next one, when the model takes a
    /// seed and the field was left on "random".
    var holdSeed: Bool {
        didSet { defaults.set(holdSeed, forKey: "settings.generation.holdSeed") }
    }

    /// Ask the engine for partial-audio previews during a render. Off by
    /// default: only some families can decode mid-render, so the render card
    /// reads differently per model with it on — see the note in
    /// `StudioView.submit`.
    var livePreview: Bool {
        didSet { defaults.set(livePreview, forKey: "settings.generation.livePreview") }
    }

    /// Run tempo/key analysis on every new song the moment it appears.
    var autoAnalyze: Bool {
        didSet { defaults.set(autoAnalyze, forKey: "settings.generation.autoAnalyze") }
    }

    /// Which analyzer the automatic pass uses; nil = the first installed one.
    var analyzerModelId: String? {
        didSet { setOrRemove(analyzerModelId, "settings.generation.analyzerModelId") }
    }

    /// Which writing assistant the "Help me write" cards use; nil = the first
    /// installed one, which the catalog orders best-first.
    var assistantModelId: String? {
        didSet { setOrRemove(assistantModelId, "settings.generation.assistantModelId") }
    }

    /// How adventurous the writing assistant is.
    ///
    /// Higher than a coding assistant would want: these are creative-writing
    /// jobs, and at zero it produces the same four adjectives every time. The
    /// engine clamps this to 0…1.5 regardless of what is stored here.
    var assistantTemperature: Double {
        didSet {
            defaults.set(assistantTemperature,
                         forKey: "settings.generation.assistantTemperature")
        }
    }

    /// The separator a Split action opens on; nil = the recipe's own
    /// preference, then catalog order.
    var defaultSeparatorId: String? {
        didSet { setOrRemove(defaultSeparatorId, "settings.generation.defaultSeparator") }
    }

    // MARK: Audio

    /// The house loudness target: what the Workbench footer and the Editor's
    /// normalise slider start at. Flows that never show a slider keep the
    /// wire default.
    var targetLufs: Double {
        didSet { defaults.set(targetLufs, forKey: "settings.audio.targetLufs") }
    }

    /// What a fresh Workbench starts with — each mix can still flip them.
    var autoMatchTempo: Bool {
        didSet { defaults.set(autoMatchTempo, forKey: "settings.audio.autoMatchTempo") }
    }
    var autoMatchKey: Bool {
        didSet { defaults.set(autoMatchKey, forKey: "settings.audio.autoMatchKey") }
    }
    var keepStems: Bool {
        didSet { defaults.set(keepStems, forKey: "settings.audio.keepStems") }
    }

    /// Media keys, Control Centre and the Now Playing widget.
    var nowPlayingEnabled: Bool {
        didSet { defaults.set(nowPlayingEnabled, forKey: "settings.audio.nowPlaying") }
    }

    // MARK: Library

    /// Deleted songs and parts go to the Trash rather than being removed
    /// outright. Derived files (waveform caches, previews) are always removed
    /// outright — restoring a track from the Trash regenerates them.
    var deleteToTrash: Bool {
        didSet { defaults.set(deleteToTrash, forKey: "settings.library.deleteToTrash") }
    }

    /// Total size the Editor's stashed originals may reach before the oldest
    /// are pruned, in GB; 0 = no cap. Pruning a backup costs that track its
    /// Revert, which is why off is the default.
    var backupsCapGB: Double {
        didSet { defaults.set(backupsCapGB, forKey: "settings.library.backupsCapGB") }
    }

    /// The sort the Library opens on.
    var libraryDefaultSort: LibraryRepository.Sort {
        didSet {
            defaults.set(libraryDefaultSort.rawValue,
                         forKey: "settings.library.defaultSort")
        }
    }

    /// When on, picking a sort in the Library rewrites `libraryDefaultSort`,
    /// so the choice carries to the next launch.
    var libraryRemembersSort: Bool {
        didSet {
            defaults.set(libraryRemembersSort,
                         forKey: "settings.library.rememberSort")
        }
    }

    /// What the Editor's export sheet opens set to: "wav" | "aiff" | "flac"
    /// | "mp3", and "pcm16" | "pcm24" | "float32". Each export can still
    /// change both.
    var exportFormat: String {
        didSet { defaults.set(exportFormat, forKey: "settings.library.exportFormat") }
    }
    var exportDepth: String {
        didSet { defaults.set(exportDepth, forKey: "settings.library.exportDepth") }
    }

    // MARK: Queue

    var queueAutoClear: QueueAutoClear {
        didSet {
            defaults.set(queueAutoClear.rawValue,
                         forKey: "settings.queue.autoClear")
        }
    }

    // MARK: Engine

    /// What happens to a small model's warm worker once it goes idle
    /// (`LOCALMUSIC_SMALL_WARM_TTL_S` — 0 already means drop-when-idle, so
    /// "always" is just a TTL longer than any session).
    enum SmallResidency: String, CaseIterable {
        case dropWhenIdle, keepTenMinutes, keepAlways

        var ttlSeconds: Int {
            switch self {
            case .dropWhenIdle: 0
            case .keepTenMinutes: 600
            case .keepAlways: 315_360_000
            }
        }

        var label: String {
            switch self {
            case .dropWhenIdle: "Freed when idle"
            case .keepTenMinutes: "Kept for 10 minutes"
            case .keepAlways: "Kept always"
            }
        }
    }

    var smallResidency: SmallResidency {
        didSet {
            defaults.set(smallResidency.rawValue,
                         forKey: "settings.engine.smallResidency")
        }
    }

    var smallWarmSlots: Int {
        didSet { defaults.set(smallWarmSlots, forKey: "settings.engine.warmSlots") }
    }

    /// The size below which a model counts as small, in bytes.
    var smallModelBytes: Int {
        didSet { defaults.set(smallModelBytes, forKey: "settings.engine.smallModelBytes") }
    }

    /// Memory-guard warning level as a percent of physical RAM; 0 = off.
    var memGuardPercent: Int {
        didSet { defaults.set(memGuardPercent, forKey: "settings.engine.memGuardPercent") }
    }

    var maxActiveDownloads: Int {
        didSet { defaults.set(maxActiveDownloads, forKey: "settings.engine.maxDownloads") }
    }

    /// Model-weights cache root (`HF_HOME`); nil = the shared default cache.
    var hfHomePath: String? {
        didSet { setOrRemove(hfHomePath, "settings.engine.hfHome") }
    }

    var engineLogLevel: String {
        didSet { defaults.set(engineLogLevel, forKey: "settings.engine.logLevel") }
    }

    /// Days the engine keeps finished jobs' output files, and the app keeps
    /// its daily engine logs; 0 = forever.
    var engineFileRetentionDays: Int {
        didSet {
            defaults.set(engineFileRetentionDays,
                         forKey: "settings.engine.retentionDays")
        }
    }

    /// The model to re-pin after every engine start. The engine's own pin
    /// state is deliberately in-memory (contract: "pin state is not persisted
    /// across engine restarts"); persistence is the app's, here.
    var pinnedModelId: String? {
        didSet { setOrRemove(pinnedModelId, "settings.engine.pinnedModelId") }
    }

    /// The launch shape all of the above adds up to — what the process
    /// manager spawns with, and what the pending-restart banner compares.
    var engineLaunchConfig: EngineLaunchConfig {
        let ram = Double(ProcessInfo.processInfo.physicalMemory)
        return EngineLaunchConfig(
            memGuardBytes: memGuardPercent == 0
                ? 0 : Int(ram * Double(memGuardPercent) / 100),
            smallWarmSlots: smallWarmSlots,
            smallWarmTTLS: smallResidency.ttlSeconds,
            smallModelBytes: smallModelBytes,
            maxActiveDownloads: maxActiveDownloads,
            hfHome: hfHomePath,
            logLevel: engineLogLevel,
            outputsRetentionDays: engineFileRetentionDays)
    }

    // MARK: - Storage

    private let defaults: UserDefaults

    /// `true` unless the key holds an explicit `false` — the reading every
    /// on-by-default preference wants, which `bool(forKey:)` gets backwards.
    private static func flag(_ defaults: UserDefaults, _ key: String,
                             default value: Bool) -> Bool {
        defaults.object(forKey: key) as? Bool ?? value
    }

    private func setOrRemove(_ value: String?, _ key: String) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        Self.migrateLegacyKeys(in: defaults)
        confirmDeletes = Self.flag(defaults, "settings.general.confirmDeletes",
                                   default: true)
        confirmRevert = Self.flag(defaults, "settings.general.confirmRevert",
                                  default: true)
        confirmQuitWhileRendering = Self.flag(
            defaults, "settings.general.confirmQuit", default: true)
        reduceMotion = defaults.bool(forKey: "settings.general.reduceMotion")
        exportFormat = defaults.string(forKey: "settings.library.exportFormat")
            ?? "wav"
        exportDepth = defaults.string(forKey: "settings.library.exportDepth")
            ?? "pcm24"
        notificationsEnabled = Self.flag(defaults, "settings.notifications.enabled",
                                         default: true)
        notifyAlways = defaults.bool(forKey: "settings.notifications.always")
        notificationSound = Self.flag(defaults, "settings.notifications.sound",
                                      default: true)
        dockBounce = Self.flag(defaults, "settings.notifications.dockBounce",
                               default: true)
        autoArmRenders = defaults.bool(forKey: "settings.notifications.autoArm")
        notifyTrackReady = Self.flag(defaults, "settings.notifications.trackReady",
                                     default: true)
        notifyJobFailed = Self.flag(defaults, "settings.notifications.jobFailed",
                                    default: true)
        notifyDownloadCompleted = Self.flag(
            defaults, "settings.notifications.downloadCompleted", default: true)
        notifyDownloadFailed = Self.flag(
            defaults, "settings.notifications.downloadFailed", default: true)
        notifyEngineWarning = Self.flag(
            defaults, "settings.notifications.engineWarning", default: true)
        notifyEditsApplied = Self.flag(
            defaults, "settings.notifications.editsApplied", default: true)
        studioModelPolicy = defaults
            .string(forKey: "settings.generation.modelPolicy")
            .flatMap(StudioModelPolicy.init(rawValue:)) ?? .lastUsed
        studioFixedModelId = defaults
            .string(forKey: "settings.generation.fixedModelId")
        studioLastModelId = defaults
            .string(forKey: "settings.generation.lastModelId")
        defaultDurationS = defaults
            .object(forKey: "settings.generation.defaultDurationS")
            as? Double ?? 10
        defaultTakes = defaults.object(forKey: "settings.generation.defaultTakes")
            as? Int ?? 1
        holdSeed = defaults.bool(forKey: "settings.generation.holdSeed")
        livePreview = defaults.bool(forKey: "settings.generation.livePreview")
        autoAnalyze = Self.flag(defaults, "settings.generation.autoAnalyze",
                                default: true)
        analyzerModelId = defaults
            .string(forKey: "settings.generation.analyzerModelId")
        assistantModelId = defaults
            .string(forKey: "settings.generation.assistantModelId")
        assistantTemperature = defaults
            .object(forKey: "settings.generation.assistantTemperature")
            as? Double ?? 0.7
        defaultSeparatorId = defaults
            .string(forKey: "settings.generation.defaultSeparator")
        targetLufs = defaults.object(forKey: "settings.audio.targetLufs")
            as? Double ?? -14
        autoMatchTempo = Self.flag(defaults, "settings.audio.autoMatchTempo",
                                   default: true)
        autoMatchKey = Self.flag(defaults, "settings.audio.autoMatchKey",
                                 default: true)
        keepStems = defaults.bool(forKey: "settings.audio.keepStems")
        nowPlayingEnabled = Self.flag(defaults, "settings.audio.nowPlaying",
                                      default: true)
        deleteToTrash = Self.flag(defaults, "settings.library.deleteToTrash",
                                  default: true)
        libraryDefaultSort = defaults
            .string(forKey: "settings.library.defaultSort")
            .flatMap(LibraryRepository.Sort.init(rawValue:)) ?? .newest
        libraryRemembersSort = defaults
            .bool(forKey: "settings.library.rememberSort")
        queueAutoClear = defaults.string(forKey: "settings.queue.autoClear")
            .flatMap(QueueAutoClear.init(rawValue:)) ?? .never
        smallResidency = defaults
            .string(forKey: "settings.engine.smallResidency")
            .flatMap(SmallResidency.init(rawValue:)) ?? .keepTenMinutes
        smallWarmSlots = defaults.object(forKey: "settings.engine.warmSlots")
            as? Int ?? 2
        smallModelBytes = defaults
            .object(forKey: "settings.engine.smallModelBytes")
            as? Int ?? 1_500_000_000
        memGuardPercent = defaults
            .object(forKey: "settings.engine.memGuardPercent") as? Int ?? 90
        maxActiveDownloads = defaults
            .object(forKey: "settings.engine.maxDownloads") as? Int ?? 1
        hfHomePath = defaults.string(forKey: "settings.engine.hfHome")
        engineLogLevel = defaults.string(forKey: "settings.engine.logLevel")
            ?? "info"
        engineFileRetentionDays = defaults
            .object(forKey: "settings.engine.retentionDays") as? Int ?? 14
        backupsCapGB = defaults
            .object(forKey: "settings.library.backupsCapGB") as? Double ?? 0
        pinnedModelId = defaults.string(forKey: "settings.engine.pinnedModelId")
    }

    /// Three early keys predate the app's `area.name` convention. Renamed
    /// once, before anything reads them; the guard key stays behind so the
    /// rename never runs twice (a second run would resurrect a deleted new
    /// key from a stale old one — except the old ones are removed, so really
    /// it would just be wasted work; the guard makes it *provably* once).
    static func migrateLegacyKeys(in defaults: UserDefaults) {
        guard !defaults.bool(forKey: "settings.migratedLegacyKeys") else { return }
        let renames = ["showAllModels": "models.showAll",
                       "acceptedLicenses": "catalog.acceptedLicenses",
                       "favouriteModels": "catalog.favourites"]
        for (old, new) in renames {
            if let value = defaults.object(forKey: old),
               defaults.object(forKey: new) == nil {
                defaults.set(value, forKey: new)
            }
            defaults.removeObject(forKey: old)
        }
        defaults.set(true, forKey: "settings.migratedLegacyKeys")
    }

    // MARK: - Reset

    /// Back to the welcome tour on next visit to the main window.
    func showWelcomeAgain() {
        defaults.set(0, forKey: "onboarding.completedVersion")
    }

    /// Un-dismiss the inline hint cards.
    func resetDismissedHints() {
        defaults.removeObject(forKey: "analysisToolsCardDismissed")
    }

    /// Forget the Actions gallery's recently-used history.
    func clearRecentActions() {
        defaults.removeObject(forKey: "actions.lastRuns")
    }

    /// Every preference back to its default — this store's own and the
    /// feature screens' `@AppStorage` keys alike. Views bound with
    /// `@AppStorage` observe the removal and update in place.
    func resetAllPreferences() {
        for key in ["onboarding.completedVersion", "queue.pinned",
                    "sidebar.collapsed", "models.onlyInstalled",
                    "models.showAll", "studio.mode", "studio.presets",
                    "workbench.lens", "actions.onlyRunnable",
                    "actions.lastRuns", "analysisToolsCardDismissed",
                    "catalog.acceptedLicenses", "catalog.favourites"] {
            defaults.removeObject(forKey: key)
        }
        confirmDeletes = true
        confirmRevert = true
        confirmQuitWhileRendering = true
        reduceMotion = false
        exportFormat = "wav"
        exportDepth = "pcm24"
        notificationsEnabled = true
        notifyAlways = false
        notificationSound = true
        dockBounce = true
        autoArmRenders = false
        notifyTrackReady = true
        notifyJobFailed = true
        notifyDownloadCompleted = true
        notifyDownloadFailed = true
        notifyEngineWarning = true
        notifyEditsApplied = true
        studioModelPolicy = .lastUsed
        studioFixedModelId = nil
        studioLastModelId = nil
        defaultDurationS = 10
        defaultTakes = 1
        holdSeed = false
        livePreview = false
        autoAnalyze = true
        analyzerModelId = nil
        assistantModelId = nil
        assistantTemperature = 0.7
        defaultSeparatorId = nil
        targetLufs = -14
        autoMatchTempo = true
        autoMatchKey = true
        keepStems = false
        nowPlayingEnabled = true
        deleteToTrash = true
        libraryDefaultSort = .newest
        libraryRemembersSort = false
        queueAutoClear = .never
        smallResidency = .keepTenMinutes
        smallWarmSlots = 2
        smallModelBytes = 1_500_000_000
        memGuardPercent = 90
        maxActiveDownloads = 1
        hfHomePath = nil
        engineLogLevel = "info"
        engineFileRetentionDays = 14
        backupsCapGB = 0
        pinnedModelId = nil
    }
}

import Foundation

/// The eight sections of the Settings window, in rail order.
///
/// Grouped rather than listed flat: eight equal-weight rows read as a wall,
/// and the four pairs below are the same shape the main window's sidebar uses
/// — mono group label, glyph, title, optional trailing count.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, notifications
    case generation, audio
    case library, models
    case queue, engine

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .notifications: "Notifications"
        case .generation: "Generation"
        case .audio: "Audio & Output"
        case .library: "Library & Files"
        case .models: "Models & Downloads"
        case .queue: "Queue"
        case .engine: "Engine"
        }
    }

    var glyph: BenchNavGlyph.Kind {
        switch self {
        case .general: .info
        case .notifications: .bell
        case .generation: .generate
        case .audio: .ring
        case .library: .library
        case .models: .models
        case .queue: .workbench
        case .engine: .engine
        }
    }

    enum Group: String, CaseIterable {
        case app = "APP"
        case making = "MAKING"
        case storage = "STORAGE"
        case running = "RUNNING"

        var panes: [SettingsPane] {
            switch self {
            case .app: [.general, .notifications]
            case .making: [.generation, .audio]
            case .storage: [.library, .models]
            case .running: [.queue, .engine]
            }
        }
    }

    var group: Group {
        Group.allCases.first { $0.panes.contains(self) } ?? .app
    }

    /// The one thing this section can send you to that is not a setting — the
    /// right-hand end of the status strip. nil where there is nothing useful
    /// to point at, and the strip is then just the count.
    var externalLink: (label: String, kind: ExternalLink)? {
        switch self {
        case .notifications:
            ("Open macOS Notification settings", .notificationSettings)
        case .library:
            ("Reveal data folder", .dataFolder)
        case .models:
            ("Reveal model library", .modelLibrary)
        case .engine:
            ("Open engine logs", .engineLogs)
        default:
            nil
        }
    }

    enum ExternalLink {
        case notificationSettings, dataFolder, modelLibrary, engineLogs
    }
}

// MARK: - The registry

/// One preference, described once: what it is called, where it lives, whether
/// it is still at its default, and how to put it back.
///
/// This exists because three separate things in the redesigned window need to
/// ask the same question and none of them can answer it from the view tree:
/// the status strip ("9 SETTINGS IN THIS SECTION · 3 CHANGED FROM DEFAULT"),
/// "Reset this section", and search. A count that was maintained by hand
/// beside the controls would be wrong within a week, and the strip's whole job
/// is to make the Reset button next to it trustworthy.
struct SettingEntry: Identifiable {
    let id: String
    let pane: SettingsPane
    /// As it reads in the window, so a search result and the row it scrolls to
    /// are recognisably the same thing.
    let title: String
    /// Words someone might reasonably type that are not in the title —
    /// "dock", "sound", "lufs". Matched alongside the title.
    let keywords: String
    let isDefault: @MainActor (AppSettings) -> Bool
    let restore: @MainActor (AppSettings) -> Void

    /// The common case: one property, one default value.
    ///
    /// `@MainActor` because the closures it forms are: built anywhere else,
    /// the captured key path and value would be crossing into the main-actor
    /// region, which Swift 6 refuses for non-Sendable generics. Every caller
    /// is a `@MainActor` static table, so nothing moves.
    @MainActor static func of<V: Equatable>(
        _ id: String, _ pane: SettingsPane, _ title: String,
        _ path: ReferenceWritableKeyPath<AppSettings, V>, default value: V,
        keywords: String = ""
    ) -> SettingEntry {
        SettingEntry(id: id, pane: pane, title: title, keywords: keywords,
                     isDefault: { $0[keyPath: path] == value },
                     restore: { $0[keyPath: path] = value })
    }
}

enum SettingsCatalog {
    /// Every preference the window presents, in the order its section draws
    /// them. Kept beside `AppSettings.resetAllPreferences()`, which is the
    /// same inventory written as one sweep — if a preference is added there
    /// and not here, `SettingsCatalogTests` says so.
    @MainActor static let all: [SettingEntry] = general + notifications
        + generation + audio + library + models + queue + engine

    // MARK: General

    @MainActor static let general: [SettingEntry] = [
        .of("confirmDeletes", .general, "Before deleting songs and parts",
            \.confirmDeletes, default: true, keywords: "confirm ask delete"),
        .of("confirmRevert", .general, "Before reverting an edited track",
            \.confirmRevert, default: true, keywords: "confirm ask revert undo"),
        .of("confirmQuit", .general, "Before quitting mid-render",
            \.confirmQuitWhileRendering, default: true,
            keywords: "confirm ask quit"),
        .of("reduceMotion", .general, "Reduce motion", \.reduceMotion,
            default: false, keywords: "animation slide panel"),
    ]

    // MARK: Notifications

    @MainActor static let notifications: [SettingEntry] = [
        .of("notificationsEnabled", .notifications, "Notify me",
            \.notificationsEnabled, default: true,
            keywords: "notification alert master"),
        .of("notifyAlways", .notifications, "Also while I\u{2019}m using the app",
            \.notifyAlways, default: false, keywords: "foreground frontmost"),
        .of("notificationSound", .notifications, "Play a sound",
            \.notificationSound, default: true, keywords: "audio chime"),
        .of("dockBounce", .notifications, "Bounce the Dock icon",
            \.dockBounce, default: true, keywords: "dock icon"),
        .of("autoArmRenders", .notifications,
            "Always tell me when a render lands", \.autoArmRenders,
            default: false, keywords: "arm generate render"),
        .of("notifyTrackReady", .notifications, "Finished tracks",
            \.notifyTrackReady, default: true, keywords: "track ready done"),
        .of("notifyJobFailed", .notifications, "Failed renders",
            \.notifyJobFailed, default: true, keywords: "error failure"),
        .of("notifyDownloadCompleted", .notifications, "Installed models",
            \.notifyDownloadCompleted, default: true, keywords: "download model"),
        .of("notifyDownloadFailed", .notifications, "Failed downloads",
            \.notifyDownloadFailed, default: true, keywords: "download error"),
        .of("notifyEngineWarning", .notifications, "Engine warnings",
            \.notifyEngineWarning, default: true, keywords: "memory pressure"),
        .of("notifyEditsApplied", .notifications, "Applied edits",
            \.notifyEditsApplied, default: true, keywords: "editor render"),
    ]

    // MARK: Generation

    @MainActor static let generation: [SettingEntry] = [
        // Policy and the model it names are one control and reset together:
        // a policy back at "the one I last used" with a fixed model still
        // stored behind it is a half-reset nobody can see.
        SettingEntry(
            id: "studioModelPolicy", pane: .generation,
            title: "Generate opens on", keywords: "model default studio opening",
            isDefault: { $0.studioModelPolicy == .lastUsed
                          && $0.studioFixedModelId == nil },
            restore: { $0.studioModelPolicy = .lastUsed
                       $0.studioFixedModelId = nil }),
        .of("defaultDurationS", .generation, "Start length",
            \.defaultDurationS, default: 10, keywords: "duration seconds"),
        .of("defaultTakes", .generation, "Start takes", \.defaultTakes,
            default: 1, keywords: "count takes"),
        .of("holdSeed", .generation, "Hold the seed", \.holdSeed,
            default: false, keywords: "seed random reroll"),
        .of("autoAnalyze", .generation, "Analyze new audio automatically",
            \.autoAnalyze, default: true, keywords: "tempo key sections"),
        .of("analyzerModelId", .generation, "Analyzer", \.analyzerModelId,
            default: nil, keywords: "analysis model"),
        .of("autoDescribe", .generation, "Describe new audio automatically",
            \.autoDescribe, default: false,
            keywords: "caption describe listen words"),
        .of("describerModelId", .generation, "Describer", \.describerModelId,
            default: nil, keywords: "caption model listener"),
        .of("autoTagScan", .generation, "Tag new audio automatically",
            \.autoTagScan, default: false,
            keywords: "tags genre mood instruments"),
        .of("taggerModelId", .generation, "Tagger", \.taggerModelId,
            default: nil, keywords: "tag model clap"),
        .of("autoLyrics", .generation, "Transcribe lyrics automatically",
            \.autoLyrics, default: false,
            keywords: "lyrics words sung transcribe whisper"),
        .of("lyricsTranscriberModelId", .generation, "Lyric transcriber",
            \.lyricsTranscriberModelId, default: nil,
            keywords: "lyrics model whisper"),
        .of("defaultSeparatorId", .generation, "Splitter",
            \.defaultSeparatorId, default: nil, keywords: "separate stems"),
        .of("assistantModelId", .generation, "Writing assistant",
            \.assistantModelId, default: nil,
            keywords: "assistant llm prompt lyrics help write"),
        .of("assistantTemperature", .generation, "Assistant variety",
            \.assistantTemperature, default: 0.7,
            keywords: "assistant temperature creative"),
    ]

    // MARK: Audio & Output

    @MainActor static let audio: [SettingEntry] = [
        .of("targetLufs", .audio, "Normalize to", \.targetLufs, default: -14,
            keywords: "loudness lufs normalise volume"),
        .of("autoMatchTempo", .audio, "Match tempo when mixing",
            \.autoMatchTempo, default: true, keywords: "bpm sync"),
        .of("autoMatchKey", .audio, "Match key when mixing", \.autoMatchKey,
            default: true, keywords: "pitch transpose"),
        .of("keepStems", .audio, "Keep stems after a mix", \.keepStems,
            default: false, keywords: "parts separation"),
        .of("nowPlayingEnabled", .audio, "Media keys and Now Playing",
            \.nowPlayingEnabled, default: true,
            keywords: "media keys control centre remote"),
    ]

    // MARK: Library & Files

    @MainActor static let library: [SettingEntry] = [
        .of("deleteToTrash", .library, "Move deleted files to the Trash",
            \.deleteToTrash, default: true, keywords: "delete trash bin"),
        .of("exportFormat", .library, "Export format", \.exportFormat,
            default: "wav", keywords: "wav aiff export"),
        .of("exportDepth", .library, "Export bit depth", \.exportDepth,
            default: "pcm24", keywords: "bit depth 24 float export"),
        .of("libraryDefaultSort", .library, "Library opens sorted by",
            \.libraryDefaultSort, default: .newest, keywords: "sort order"),
        .of("libraryRemembersSort", .library, "Remember the last sort",
            \.libraryRemembersSort, default: false, keywords: "sort remember"),
        .of("backupsCapGB", .library, "Keep backups up to", \.backupsCapGB,
            default: 0, keywords: "backup originals stash"),
    ]

    // MARK: Models & Downloads

    // Nothing here resets. `hfHomePath` and `auxCachePath` used to be
    // registered with a default of nil, so "Reset this section" — whose
    // dialog says nothing outside the section changes — re-pointed the
    // engine at the shared Hugging Face cache and stranded a relocated
    // library: models read as not installed, re-downloads filled the boot
    // disk. They are locations, not preferences; the library card's relocate
    // flow is the only thing that may change them, because it moves the bytes.
    @MainActor static let models: [SettingEntry] = []

    // MARK: Queue

    @MainActor static let queue: [SettingEntry] = [
        .of("queueAutoClear", .queue, "Clear finished rows", \.queueAutoClear,
            default: .never, keywords: "queue dismiss auto clear"),
    ]

    // MARK: Engine

    @MainActor static let engine: [SettingEntry] = [
        .of("smallResidency", .engine, "Warm workers are", \.smallResidency,
            default: .keepTenMinutes, keywords: "small model warm pool idle"),
        .of("smallWarmSlots", .engine, "Warm slots", \.smallWarmSlots,
            default: 2, keywords: "small model pool"),
        .of("smallModelBytes", .engine, "Small model ceiling",
            \.smallModelBytes, default: 1_500_000_000,
            keywords: "small transient size"),
        .of("memGuardPercent", .engine, "Warn above", \.memGuardPercent,
            default: 90, keywords: "memory guard ram swap"),
        .of("maxActiveDownloads", .engine, "Parallel downloads",
            \.maxActiveDownloads, default: 1, keywords: "download concurrency"),
        .of("engineLogLevel", .engine, "Engine log level", \.engineLogLevel,
            default: "info", keywords: "log debug verbose"),
        .of("engineFileRetentionDays", .engine, "Keep render files for",
            \.engineFileRetentionDays, default: 14,
            keywords: "retention outputs cleanup days"),
    ]

    // MARK: Queries

    /// Memoised: `all` is a static catalog of some forty entries and this
    /// filter never returns a different answer for a given pane, yet it ran
    /// three times per pass of `SettingsView.body` — twice for the changed
    /// count and once for the total — and that body re-runs on every
    /// setting, including per frame of a slider drag.
    @MainActor private static var entriesByPane: [SettingsPane: [SettingEntry]] = [:]

    @MainActor static func entries(in pane: SettingsPane) -> [SettingEntry] {
        if let cached = entriesByPane[pane] { return cached }
        let made = all.filter { $0.pane == pane }
        entriesByPane[pane] = made
        return made
    }

    @MainActor
    static func changedCount(in pane: SettingsPane,
                             _ settings: AppSettings) -> Int {
        entries(in: pane).count { !$0.isDefault(settings) }
    }

    @MainActor
    static func reset(pane: SettingsPane, _ settings: AppSettings) {
        for entry in entries(in: pane) { entry.restore(settings) }
    }

    /// Ranked matches for the rail's search field.
    ///
    /// Title prefix first, then title substring, then keywords — so typing
    /// "not" puts "Notify me" above "Bounce the Dock icon", which only matches
    /// because its section is called Notifications.
    @MainActor static func search(_ query: String) -> [SettingEntry] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard needle.count >= 2 else { return [] }
        func rank(_ entry: SettingEntry) -> Int? {
            let title = entry.title.lowercased()
            if title.hasPrefix(needle) { return 0 }
            if title.contains(needle) { return 1 }
            if entry.keywords.lowercased().contains(needle) { return 2 }
            if entry.pane.title.lowercased().contains(needle) { return 3 }
            return nil
        }
        return all.compactMap { entry in rank(entry).map { ($0, entry) } }
            .sorted { ($0.0, $0.1.title) < ($1.0, $1.1.title) }
            .map(\.1)
    }
}

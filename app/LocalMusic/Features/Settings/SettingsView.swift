import AppKit
import SwiftUI

/// The `Settings` scene.
///
/// A separate window, so it keeps its own chrome and its own colour scheme —
/// but it is painted from the same tokens as the main window, because a
/// settings sheet that arrives in system grey reads as a different app bolted
/// onto this one. `Form(.grouped)` is not used for exactly that reason: it
/// draws its own materials, which the Bench palette has no light variant of.
///
/// Panes down the left rather than a segmented strip along the top: the strip
/// topped out at two panes, and every label added to it squeezes the rest.
struct SettingsView: View {
    let env: AppEnvironment

    @State private var pane: Pane = .general
    @State private var hfToken = ""
    @State private var tokenSaved = false
    @State private var confirmingReset = false

    enum Pane: String, CaseIterable {
        case general, notifications, generation, audio, library, queue, models,
             engine

        var title: String {
            switch self {
            case .general: "General"
            case .notifications: "Notifications"
            case .generation: "Generation"
            case .audio: "Audio & Output"
            case .library: "Library & Files"
            case .queue: "Queue"
            case .models: "Models & Downloads"
            case .engine: "Engine"
            }
        }
    }

    var body: some View {
        @Bindable var settings = env.settings
        VStack(spacing: 0) {
            BenchTopBar(title: "Settings") { EmptyView() }
            HStack(spacing: 0) {
                paneRail
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        switch pane {
                        case .general:
                            askFirstCard($settings)
                            motionCard($settings)
                            resetCard
                        case .notifications:
                            permissionCard
                            deliveryCard($settings)
                            eventsCard($settings)
                        case .generation:
                            openingModelCard
                            newRendersCard($settings)
                            generationCard($settings)
                            presetsCard
                        case .audio:
                            loudnessCard($settings)
                            mixDefaultsCard($settings)
                            mediaKeysCard($settings)
                        case .library:
                            filesCard($settings)
                            librarySortCard($settings)
                            backupsCard($settings)
                            storageCard
                        case .queue:
                            queueCard($settings)
                        case .models:
                            if libraryNeedsRestart { libraryRestartBanner }
                            ModelLibraryCard(env: env)
                            huggingFaceCard
                            licencesCard
                        case .engine:
                            if needsEngineRestart { restartBanner }
                            smallModelsCard
                            memoryGuardCard
                            downloadsAndCacheCard
                            engineSummaryCard
                            BackendDebugView(status: env.backendStatus,
                                             manager: env.backendManager,
                                             telemetry: env.telemetry)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                }
            }
        }
        .frame(width: 720, height: 560)
        .background(Bench.Palette.windowBackground)
        .preferredColorScheme(.dark)
        .onAppear {
            if let token = Keychain.get(account: "hf-token") {
                hfToken = token
                tokenSaved = true
            }
        }
    }

    // MARK: - Chrome

    private var paneRail: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Pane.allCases, id: \.self) { candidate in
                let isOn = candidate == pane
                Button {
                    pane = candidate
                } label: {
                    Text(candidate.title)
                        .font(isOn ? Bench.Typo.secondaryEmphasis
                                   : Bench.Typo.secondary)
                        .foregroundStyle(isOn ? Bench.Palette.textPrimary
                                              : Bench.Palette.textTertiary)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(
                            cornerRadius: Bench.Metrics.Radius.row,
                            style: .continuous)
                            .fill(isOn ? Bench.Palette.rowSelected : .clear))
                        .contentShape(RoundedRectangle(
                            cornerRadius: Bench.Metrics.Radius.row,
                            style: .continuous))
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(width: 172)
        .frame(maxHeight: .infinity)
        .background(Bench.Palette.sidebar)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Bench.Palette.hairline).frame(width: 1)
        }
    }

    private func card<Content: View>(_ title: String,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(title).eyebrow()
            content()
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .benchCard()
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(Bench.Typo.caption)
            .foregroundStyle(Bench.Palette.textFaint)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func toggleRow(_ label: String, isOn: Binding<Bool>,
                           note: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: isOn) {
                Text(label)
                    .font(Bench.Typo.body)
                    .foregroundStyle(Bench.Palette.textPrimary)
            }
            .toggleStyle(.bench)
            caption(note)
                .padding(.leading, 46)   // under the label, clear of the pill
        }
    }

    // MARK: - General

    private func askFirstCard(_ settings: Bindable<AppSettings>) -> some View {
        card("ASK FIRST") {
            toggleRow("Before deleting songs and parts",
                      isOn: settings.confirmDeletes,
                      note: "Off, the Delete actions act immediately. "
                          + "\u{201C}Move deleted files to the Trash\u{201D} "
                          + "(Library & Files) still applies either way. "
                          + "Deleting a model always asks.")
            toggleRow("Before reverting a track to its original",
                      isOn: settings.confirmRevert,
                      note: "Reverting discards applied edits for good — the "
                          + "one action here the Trash cannot undo.")
            toggleRow("Before quitting while a render is running",
                      isOn: settings.confirmQuitWhileRendering,
                      note: "Quitting cancels the render either way; this is "
                          + "only about being asked.")
        }
    }

    private func motionCard(_ settings: Bindable<AppSettings>) -> some View {
        card("MOTION") {
            toggleRow("Reduce motion", isOn: settings.reduceMotion,
                      note: "Panels and the sidebar snap into place instead "
                          + "of sliding.")
        }
    }

    private var resetCard: some View {
        card("START OVER") {
            HStack(spacing: 8) {
                Button("Show welcome tour again") {
                    env.settings.showWelcomeAgain()
                }
                .buttonStyle(.benchSecondary)
                Button("Reset dismissed hints") {
                    env.settings.resetDismissedHints()
                }
                .buttonStyle(.benchSecondary)
                Button("Clear recent actions") {
                    env.settings.clearRecentActions()
                }
                .buttonStyle(.benchSecondary)
            }
            caption("The welcome tour appears the next time the main window "
                    + "opens. Recent actions is the \u{201C}Recently used\u{201D} "
                    + "row in the Actions gallery.")
            Divider().overlay(Bench.Palette.hairline)
            Button("Reset all preferences…") { confirmingReset = true }
                .buttonStyle(.bench(.destructive))
                .confirmationDialog(
                    "Reset every preference to its default?",
                    isPresented: $confirmingReset) {
                    Button("Reset preferences", role: .destructive) {
                        env.settings.resetAllPreferences()
                        env.catalog.reloadPersisted()
                    }
                } message: {
                    Text("Music, parts, downloaded models and the Hugging "
                         + "Face token are not touched.")
                }
            caption("Everything on these panes, plus per-screen choices like "
                    + "filters and view modes. Your library and models stay "
                    + "as they are.")
        }
    }

    // MARK: - Notifications

    private var permissionCard: some View {
        card("PERMISSION") {
            HStack(spacing: 8) {
                if env.notifications.isAllowed {
                    StatusDot(color: Bench.Palette.ok, size: 6)
                    Text("ALLOWED")
                        .font(Bench.Typo.badge)
                        .foregroundStyle(Bench.Palette.ok)
                } else if env.notifications.isDenied {
                    StatusDot(color: Bench.Palette.warn, size: 6)
                    Text("TURNED OFF IN SYSTEM SETTINGS")
                        .font(Bench.Typo.badge)
                        .foregroundStyle(Bench.Palette.warn)
                } else {
                    StatusDot(color: Bench.Palette.textFaint, size: 6)
                    Text("NOT ASKED YET")
                        .font(Bench.Typo.badge)
                        .foregroundStyle(Bench.Palette.textFaint)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                if !env.notifications.isAllowed, !env.notifications.isDenied {
                    Button("Allow notifications…") {
                        Task { await env.notifications.request() }
                    }
                    .buttonStyle(.benchSecondary)
                }
                if env.notifications.isDenied {
                    Button("Open System Settings") {
                        env.notifications.openSystemSettings()
                    }
                    .buttonStyle(.benchSecondary)
                }
            }
        }
        .task { await env.notifications.refresh() }
    }

    private func deliveryCard(_ settings: Bindable<AppSettings>) -> some View {
        card("DELIVERY") {
            toggleRow("Notify me", isOn: settings.notificationsEnabled,
                      note: "The master switch for every notice the app sends "
                          + "on its own. A render you armed with \u{201C}Notify "
                          + "me when it lands\u{201D} is delivered regardless — "
                          + "that button is its own consent.")
            Divider().overlay(Bench.Palette.hairline)
            toggleRow("Also while I\u{2019}m using the app",
                      isOn: settings.notifyAlways,
                      note: "Off, notices arrive only once you have switched "
                          + "away to something else.")
            toggleRow("Play a sound", isOn: settings.notificationSound,
                      note: "The system notification sound, on each notice.")
            toggleRow("Bounce the Dock icon", isOn: settings.dockBounce,
                      note: "A nudge in the Dock alongside each notice.")
            Divider().overlay(Bench.Palette.hairline)
            toggleRow("Always tell me when a render lands",
                      isOn: settings.autoArmRenders,
                      note: "Every Generate render behaves as if \u{201C}Notify "
                          + "me when it lands\u{201D} were pressed on it — "
                          + "you hear about it even with the app in front.")
        }
    }

    private func eventsCard(_ settings: Bindable<AppSettings>) -> some View {
        card("TELL ME ABOUT") {
            toggleRow("Finished tracks", isOn: settings.notifyTrackReady,
                      note: "A generation completed while you were away.")
            toggleRow("Failed renders", isOn: settings.notifyJobFailed,
                      note: "A generation stopped with an error.")
            toggleRow("Installed models", isOn: settings.notifyDownloadCompleted,
                      note: "A model download or runtime install finished.")
            toggleRow("Failed downloads", isOn: settings.notifyDownloadFailed,
                      note: "A download died before it finished.")
            toggleRow("Engine warnings", isOn: settings.notifyEngineWarning,
                      note: "Memory pressure and other engine trouble.")
            toggleRow("Applied edits", isOn: settings.notifyEditsApplied,
                      note: "An Editor render replaced a track\u{2019}s file.")
        }
    }

    // MARK: - Generation

    private var installedModels: [ModelInfo] {
        env.catalog.models.filter {
            $0.installState == .installed && $0.id != "test-tiny"
        }
    }

    private func installed(supporting task: String) -> [ModelInfo] {
        installedModels.filter { $0.capabilities.supportedTasks.contains(task) }
    }

    private func modelName(_ id: String?) -> String? {
        guard let id else { return nil }
        return env.catalog.models.first { $0.id == id }?.displayName
    }

    /// `Automatic ⌄` — an optional-model picker over one task's installed
    /// models, nil being "let the app choose".
    private func modelPicker(selection: String?, task: String,
                             automaticLabel: String,
                             onPick: @escaping (String?) -> Void) -> some View {
        BenchMenu(label: modelName(selection) ?? automaticLabel) {
            Button(automaticLabel) { onPick(nil) }
            Divider()
            ForEach(installed(supporting: task), id: \.id) { model in
                Button(model.displayName) { onPick(model.id) }
            }
        }
    }

    private var openingModelCard: some View {
        card("OPENING MODEL") {
            HStack(spacing: 12) {
                Text("Generate opens on")
                    .font(Bench.Typo.body)
                    .foregroundStyle(Bench.Palette.textPrimary)
                BenchMenu(label: env.settings.studioModelPolicy.label) {
                    ForEach(AppSettings.StudioModelPolicy.allCases,
                            id: \.self) { policy in
                        Button(policy.label) {
                            env.settings.studioModelPolicy = policy
                        }
                    }
                }
                if env.settings.studioModelPolicy == .fixed {
                    modelPicker(selection: env.settings.studioFixedModelId,
                                task: "generate",
                                automaticLabel: "Choose a model…") {
                        env.settings.studioFixedModelId = $0
                    }
                }
            }
            caption("Whichever policy, a model that is missing falls back to "
                    + "the first installed generator.")
        }
    }

    private func newRendersCard(_ settings: Bindable<AppSettings>) -> some View {
        card("NEW RENDERS") {
            BenchSliderRow(label: "Start length",
                           value: settings.defaultDurationS,
                           range: 1...120, step: 1, labelWidth: 92,
                           format: { String(format: "%.0f s", $0) })
            HStack(spacing: 12) {
                Text("Start takes")
                    .font(Bench.Typo.secondary)
                    .foregroundStyle(Bench.Palette.textSecondary)
                    .frame(width: 92, alignment: .leading)
                BenchStepper(value: settings.defaultTakes, range: 1...8)
                Spacer(minLength: 0)
            }
            caption("Where the composer's length and take count start — each "
                    + "model still clamps them to what it can do.")
            Divider().overlay(Bench.Palette.hairline)
            toggleRow("Hold the seed",
                      isOn: settings.holdSeed,
                      note: "A seed field left on \u{201C}random\u{201D} "
                          + "borrows the previous take\u{2019}s seed, so "
                          + "prompt tweaks re-roll the words, not the dice. "
                          + "A seed you typed is always yours.")
            toggleRow("Live preview while rendering",
                      isOn: settings.livePreview,
                      note: "Asks the engine for partial audio mid-render, so "
                          + "the render card can draw the take as it forms. "
                          + "Only some models can produce one — the card "
                          + "stays quiet for the rest.")
        }
    }

    private func generationCard(_ settings: Bindable<AppSettings>) -> some View {
        card("AUTOMATIC ANALYSIS & SPLITTING") {
            toggleRow("Analyze new audio automatically",
                      isOn: settings.autoAnalyze,
                      note: "Runs a quick tempo/key/beats pass on every track "
                          + "that lands in the library, when an analysis "
                          + "model is installed. Powers part badges, "
                          + "mash-ability scores and timeline alignment.")
            if env.settings.autoAnalyze {
                HStack(spacing: 12) {
                    Text("Analyzer")
                        .font(Bench.Typo.secondary)
                        .foregroundStyle(Bench.Palette.textSecondary)
                        .frame(width: 92, alignment: .leading)
                    modelPicker(selection: env.settings.analyzerModelId,
                                task: "analyze",
                                automaticLabel: "Automatic") {
                        env.settings.analyzerModelId = $0
                    }
                }
            }
            Divider().overlay(Bench.Palette.hairline)
            HStack(spacing: 12) {
                Text("Split with")
                    .font(Bench.Typo.secondary)
                    .foregroundStyle(Bench.Palette.textSecondary)
                    .frame(width: 92, alignment: .leading)
                modelPicker(selection: env.settings.defaultSeparatorId,
                            task: "separate",
                            automaticLabel: "Recipe\u{2019}s choice") {
                    env.settings.defaultSeparatorId = $0
                }
            }
            caption("The separator a Split action opens on. The picker on the "
                    + "action itself still lists everything installed.")
        }
    }

    private var presetsCard: some View {
        card("SAVED PRESETS") {
            let presets = storedPresets
            if presets.isEmpty {
                caption("Parameter presets you save in the Studio\u{2019}s "
                        + "Full-control panel appear here.")
            } else {
                ForEach(presets) { preset in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.name)
                                .font(Bench.Typo.secondaryEmphasis)
                                .foregroundStyle(Bench.Palette.textPrimary)
                            Text(modelName(preset.modelId) ?? preset.modelId)
                                .metaLine()
                        }
                        Spacer(minLength: 8)
                        Button("Delete") { deletePreset(preset) }
                            .buttonStyle(.bench(.quiet))
                    }
                }
            }
        }
    }

    /// The same `studio.presets` blob the parameter panel writes; managed
    /// here so a pile of stale presets does not need a per-chip hunt through
    /// the Studio to clean up.
    @AppStorage("studio.presets") private var storedPresetsJSON = "[]"

    private var storedPresets: [StudioPreset] {
        (try? JSONDecoder().decode([StudioPreset].self,
                                   from: Data(storedPresetsJSON.utf8))) ?? []
    }

    private func deletePreset(_ preset: StudioPreset) {
        let kept = storedPresets.filter { $0 != preset }
        if let data = try? JSONEncoder().encode(kept),
           let json = String(data: data, encoding: .utf8) {
            storedPresetsJSON = json
        }
    }

    // MARK: - Audio & Output

    private func loudnessCard(_ settings: Bindable<AppSettings>) -> some View {
        card("LOUDNESS") {
            BenchSliderRow(label: "House target",
                           value: settings.targetLufs,
                           range: -30...(-6), step: 0.5, labelWidth: 92,
                           valueWidth: 74,
                           format: { String(format: "%.1f LUFS", $0) })
            caption("Where the Workbench footer and the Editor\u{2019}s "
                    + "normalise slider start; each mix can still move it. "
                    + "Everything ends in the same limiter at \u{2212}1 dBTP.")
        }
    }

    private func mixDefaultsCard(_ settings: Bindable<AppSettings>) -> some View {
        card("A FRESH WORKBENCH STARTS WITH") {
            toggleRow("Match tempo", isOn: settings.autoMatchTempo,
                      note: "Stretch clips onto the mix\u{2019}s grid.")
            toggleRow("Match key", isOn: settings.autoMatchKey,
                      note: "Shift clips into the mix\u{2019}s key.")
            toggleRow("Keep the separate tracks", isOn: settings.keepStems,
                      note: "Save each mixed track as a part alongside the "
                          + "mixdown.")
            caption("Applied at launch; the bench\u{2019}s own chips override "
                    + "them for the session.")
        }
    }

    private func mediaKeysCard(_ settings: Bindable<AppSettings>) -> some View {
        card("SYSTEM PLAYBACK") {
            toggleRow("Media keys & Now Playing",
                      isOn: settings.nowPlayingEnabled,
                      note: "Play/pause keys, Control Centre and the Now "
                          + "Playing widget follow whichever player is "
                          + "sounding.")
            .onChange(of: env.settings.nowPlayingEnabled) { _, enabled in
                env.setNowPlaying(enabled: enabled)
            }
        }
    }

    // MARK: - Library & Files

    private func filesCard(_ settings: Bindable<AppSettings>) -> some View {
        card("FILES") {
            toggleRow("Move deleted files to the Trash",
                      isOn: settings.deleteToTrash,
                      note: "Deleted songs, parts and edit backups go to the "
                          + "Trash instead of being removed outright. "
                          + "Waveform caches are always removed — they "
                          + "regenerate.")
            Divider().overlay(Bench.Palette.hairline)
            HStack(spacing: 12) {
                Text("Export as")
                    .font(Bench.Typo.body)
                    .foregroundStyle(Bench.Palette.textPrimary)
                BenchMenu(label: env.settings.exportFormat.uppercased()) {
                    ForEach(["wav", "aiff", "flac", "mp3"], id: \.self) { format in
                        Button(format.uppercased()) {
                            env.settings.exportFormat = format
                        }
                    }
                }
                BenchMenu(label: Self.depthLabel(env.settings.exportDepth)) {
                    ForEach(["pcm16", "pcm24", "float32"], id: \.self) { depth in
                        Button(Self.depthLabel(depth)) {
                            env.settings.exportDepth = depth
                        }
                    }
                }
            }
            caption("What the Editor\u{2019}s export sheet opens set to; "
                    + "each export can still change both.")
        }
    }

    static func depthLabel(_ depth: String) -> String {
        switch depth {
        case "pcm16": "16-bit"
        case "pcm24": "24-bit"
        case "float32": "32-bit float"
        default: depth
        }
    }

    private func librarySortCard(_ settings: Bindable<AppSettings>) -> some View {
        card("LIBRARY") {
            HStack(spacing: 12) {
                Text("Sort the library by")
                    .font(Bench.Typo.body)
                    .foregroundStyle(Bench.Palette.textPrimary)
                BenchMenu(label: LibraryScreen.label(
                    for: env.settings.libraryDefaultSort)) {
                    ForEach(LibraryRepository.Sort.allCases, id: \.self) { sort in
                        Button(LibraryScreen.label(for: sort)) {
                            env.settings.libraryDefaultSort = sort
                        }
                    }
                }
            }
            toggleRow("Remember my last sort",
                      isOn: settings.libraryRemembersSort,
                      note: "Picking a sort in the Library also makes it the "
                          + "default above.")
        }
    }

    private func backupsCard(_ settings: Bindable<AppSettings>) -> some View {
        card("EDIT BACKUPS") {
            HStack(spacing: 12) {
                Text("Keep at most")
                    .font(Bench.Typo.body)
                    .foregroundStyle(Bench.Palette.textPrimary)
                BenchMenu(label: env.settings.backupsCapGB == 0
                          ? "Everything"
                          : String(format: "%.0f GB",
                                   env.settings.backupsCapGB)) {
                    Button("Everything") { setBackupsCap(0) }
                    Divider()
                    ForEach([2.0, 5.0, 10.0], id: \.self) { gb in
                        Button(String(format: "%.0f GB", gb)) {
                            setBackupsCap(gb)
                        }
                    }
                }
            }
            caption("The originals stashed when the Editor applies edits in "
                    + "place. Past the cap the oldest are pruned — and a "
                    + "pruned backup is that track\u{2019}s Revert gone, "
                    + "which is why \u{201C}Everything\u{201D} is the default.")
        }
    }

    private func setBackupsCap(_ gb: Double) {
        env.settings.backupsCapGB = gb
        env.pruneHousekeeping()
    }

    @State private var diskFigures: [(label: String, url: URL, bytes: Int64)] = []

    private var storageCard: some View {
        card("STORAGE") {
            BenchInfoRow(label: "Data folder", labelWidth: 92) {
                Text(StoragePaths.root.path)
                    .font(Bench.Typo.mono(11))
                    .foregroundStyle(Bench.Palette.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(diskFigures, id: \.label) { figure in
                BenchInfoRow(label: figure.label, labelWidth: 92) {
                    HStack(spacing: 10) {
                        Text(ByteCountFormatter.string(
                            fromByteCount: figure.bytes, countStyle: .file))
                            .font(Bench.Typo.mono(12))
                            .foregroundStyle(Bench.Palette.textPrimary)
                        Button("Reveal") {
                            NSWorkspace.shared
                                .activateFileViewerSelecting([figure.url])
                        }
                        .buttonStyle(.bench(.quiet))
                    }
                }
            }
            Button("Reveal data folder in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([StoragePaths.root])
            }
            .buttonStyle(.benchSecondary)
        }
        .task { await refreshDiskFigures() }
    }

    /// One walk per named pile, off the main actor; a Settings visit is rare
    /// enough that freshness beats caching here.
    private func refreshDiskFigures() async {
        let piles: [(String, [URL])] = [
            ("Music", [StoragePaths.libraryAudio, StoragePaths.libraryParts]),
            ("Job outputs", [StoragePaths.engineOutputs]),
            ("Backups", [StoragePaths.libraryBackups]),
            ("Engine logs", [StoragePaths.engineLogs]),
        ]
        let figures = await Task.detached(priority: .utility) {
            piles.map { label, urls in
                (label: label, url: urls[0],
                 bytes: urls.reduce(Int64(0)) {
                     $0 + StorageStore.directoryBytes($1)
                 })
            }
        }.value
        diskFigures = figures
    }

    // MARK: - Queue

    private func queueCard(_ settings: Bindable<AppSettings>) -> some View {
        card("FINISHED RENDERS") {
            HStack(spacing: 12) {
                Text("Clear finished rows")
                    .font(Bench.Typo.body)
                    .foregroundStyle(Bench.Palette.textPrimary)
                BenchMenu(label: env.settings.queueAutoClear.label) {
                    ForEach(AppSettings.QueueAutoClear.allCases,
                            id: \.self) { policy in
                        Button(policy.label) {
                            env.settings.queueAutoClear = policy
                            // Rows already finished start their clock now.
                            env.jobsStore.ensureAutoClearRunning()
                        }
                    }
                }
            }
            caption("Failed and cancelled rows clear on the same schedule. "
                    + "\u{201C}Clear done\u{201D} in the queue panel always "
                    + "works immediately.")
        }
    }

    // MARK: - Hugging Face

    private var huggingFaceCard: some View {
        card("HUGGING FACE") {
            SecureField("Access token (hf_…)", text: $hfToken)
                .textFieldStyle(.plain)
                .tint(Bench.Palette.accent)
                .font(Bench.Typo.mono(12))
                .foregroundStyle(Bench.Palette.textPrimary)
                .padding(.horizontal, 11).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.control,
                                             style: .continuous)
                    .fill(Bench.Palette.windowBackground))
                .overlay(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.control,
                                          style: .continuous)
                    .strokeBorder(Bench.Palette.cardStroke, lineWidth: 1))
            HStack(spacing: 8) {
                Button("Save token", action: saveToken)
                    .buttonStyle(.benchSecondary)
                Button("Remove", action: removeToken)
                    .buttonStyle(.bench(.quiet))
                if tokenSaved {
                    HStack(spacing: 6) {
                        StatusDot(color: Bench.Palette.ok, size: 6)
                        Text("SAVED TO KEYCHAIN")
                            .font(Bench.Typo.badge)
                            .foregroundStyle(Bench.Palette.ok)
                    }
                }
                Spacer(minLength: 0)
            }
            caption("Needed for gated models like Stable Audio Open. Stored only "
                    + "in your Keychain and handed to the local engine at launch.")
        }
    }

    private func saveToken() {
        let trimmed = hfToken.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        Keychain.set(trimmed, account: "hf-token")
        Task {
            if let client = await env.backendManager.client {
                try? await client.setHFToken(trimmed)
            }
        }
        tokenSaved = true
        // Settings is its own window, so a Models screen open behind it is not
        // re-created by this. Tell the store, or every gated row goes on
        // reading HF TOKEN NEEDED until the user navigates away and back.
        env.catalog.refreshHFToken()
    }

    private func removeToken() {
        Keychain.delete(account: "hf-token")
        hfToken = ""
        tokenSaved = false
        env.catalog.refreshHFToken()
    }

    // MARK: - Engine

    /// The running engine was spawned with a different config than Settings
    /// would produce now. Attach-mode and never-launched engines answer no —
    /// there is nothing to restart into.
    private var needsEngineRestart: Bool {
        guard let launched = env.backendStatus.launchedEngineConfig else {
            return false
        }
        return launched != env.settings.engineLaunchConfig
    }

    /// The library folder has changed on disk and the engine has not been told.
    /// Distinct from the generic engine-settings banner because the
    /// consequence is specific and alarming if left unexplained: until the
    /// restart, every model reads as not downloaded.
    private var libraryNeedsRestart: Bool {
        env.modelLibrary.pendingRestartPath != nil
    }

    private var libraryRestartBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            StatusDot(color: Bench.Palette.warn, size: 6)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                Text("Restart the engine to use the new library folder.")
                    .font(Bench.Typo.secondary)
                    .foregroundStyle(Bench.Palette.textPrimary)
                Text("Until it restarts the engine is still reading the old "
                     + "folder, so models will show as not downloaded.")
                    .font(Bench.Typo.caption)
                    .foregroundStyle(Bench.Palette.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Restart engine now") {
                _ = env.modelLibrary.consumePendingRestart()
                Task {
                    await env.backendManager.restart()
                    await env.modelLibrary.refresh()
                }
            }
            .buttonStyle(.benchSecondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .benchCard(fill: Bench.Palette.warn.opacity(0.07),
                   stroke: Bench.Palette.warn.opacity(0.25))
    }

    private var restartBanner: some View {
        HStack(spacing: 10) {
            StatusDot(color: Bench.Palette.warn, size: 6)
            Text("Engine settings apply after a restart.")
                .font(Bench.Typo.secondary)
                .foregroundStyle(Bench.Palette.textPrimary)
            Spacer(minLength: 8)
            Button("Restart engine now") {
                Task { await env.backendManager.restart() }
            }
            .buttonStyle(.benchSecondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .benchCard(fill: Bench.Palette.warn.opacity(0.07),
                   stroke: Bench.Palette.warn.opacity(0.25))
    }

    private var smallModelsCard: some View {
        card("SMALL HELPER MODELS") {
            HStack(spacing: 12) {
                Text("Warm workers are")
                    .font(Bench.Typo.body)
                    .foregroundStyle(Bench.Palette.textPrimary)
                BenchMenu(label: env.settings.smallResidency.label) {
                    ForEach(AppSettings.SmallResidency.allCases,
                            id: \.self) { choice in
                        Button(choice.label) {
                            env.settings.smallResidency = choice
                        }
                    }
                }
                Spacer(minLength: 12)
                Text("Slots")
                    .font(Bench.Typo.secondary)
                    .foregroundStyle(Bench.Palette.textSecondary)
                BenchStepper(value: Binding(
                    get: { env.settings.smallWarmSlots },
                    set: { env.settings.smallWarmSlots = $0 }), range: 1...4)
            }
            BenchSliderRow(
                label: "Counts as small",
                value: Binding(
                    get: { Double(env.settings.smallModelBytes)
                        / 1_000_000_000 },
                    set: { env.settings.smallModelBytes
                        = Int($0 * 1_000_000_000) }),
                range: 0.5...4, step: 0.25, labelWidth: 112, valueWidth: 64,
                format: { String(format: "%.2f GB", $0) })
            caption("Analyzers, separators and other helpers under the size "
                    + "limit run beside the big resident model instead of "
                    + "evicting it, and stay loaded between jobs for as long "
                    + "as chosen above.")
        }
    }

    private var memoryGuardCard: some View {
        card("MEMORY GUARD") {
            toggleRow("Warn about memory pressure",
                      isOn: Binding(
                          get: { env.settings.memGuardPercent > 0 },
                          set: { env.settings.memGuardPercent = $0 ? 90 : 0 }),
                      note: "A warning when a render\u{2019}s accelerator "
                          + "memory crosses the level — it never stops the "
                          + "job. Legitimate generations can spike briefly "
                          + "past it.")
            if env.settings.memGuardPercent > 0 {
                BenchSliderRow(
                    label: "Warn at",
                    value: Binding(
                        get: { Double(env.settings.memGuardPercent) },
                        set: { env.settings.memGuardPercent = Int($0) }),
                    range: 50...100, step: 5, labelWidth: 112, valueWidth: 84,
                    format: { String(format: "%.0f%% of RAM", $0) })
            }
        }
    }

    private var downloadsAndCacheCard: some View {
        card("DOWNLOADS & MODEL CACHE") {
            HStack(spacing: 12) {
                Text("Parallel downloads")
                    .font(Bench.Typo.body)
                    .foregroundStyle(Bench.Palette.textPrimary)
                BenchStepper(value: Binding(
                    get: { env.settings.maxActiveDownloads },
                    set: { env.settings.maxActiveDownloads = $0 }), range: 1...4)
                Spacer(minLength: 0)
            }
            Divider().overlay(Bench.Palette.hairline)
            BenchInfoRow(label: "Model cache", labelWidth: 92) {
                Text(env.settings.hfHomePath
                     ?? "~/.cache/huggingface (shared default)")
                    .font(Bench.Typo.mono(11))
                    .foregroundStyle(Bench.Palette.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Read-only here on purpose. This used to offer its own "Choose
            // folder…", which changed a path and moved nothing — so the models
            // stayed in the old folder and the catalog appeared to have
            // un-downloaded itself. Changing the folder is a decision about
            // what happens to tens of gigabytes, and it now lives with the
            // rest of that decision on Models & Downloads.
            Button("Manage in Models & Downloads") { pane = .models }
                .buttonStyle(.bench(.quiet))
            caption("Where model weights live — the shared Hugging Face cache "
                    + "by default, so other tools reuse them.")
            Divider().overlay(Bench.Palette.hairline)
            HStack(spacing: 12) {
                Text("Keep render files for")
                    .font(Bench.Typo.body)
                    .foregroundStyle(Bench.Palette.textPrimary)
                BenchMenu(label: Self.retentionLabel(
                    env.settings.engineFileRetentionDays)) {
                    ForEach([7, 14, 30, 0], id: \.self) { days in
                        Button(Self.retentionLabel(days)) {
                            env.settings.engineFileRetentionDays = days
                            env.pruneHousekeeping()
                        }
                    }
                }
            }
            caption("Sweeps the engine\u{2019}s Outputs folder — failed "
                    + "takes, uncollected stems; finished music is already "
                    + "in your library — and the daily engine logs.")
            Divider().overlay(Bench.Palette.hairline)
            HStack(spacing: 12) {
                Text("Engine log level")
                    .font(Bench.Typo.body)
                    .foregroundStyle(Bench.Palette.textPrimary)
                BenchMenu(label: env.settings.engineLogLevel) {
                    ForEach(["info", "debug", "warning"], id: \.self) { level in
                        Button(level) { env.settings.engineLogLevel = level }
                    }
                }
            }
        }
    }

    static func retentionLabel(_ days: Int) -> String {
        days == 0 ? "Forever" : "\(days) days"
    }

    private var licencesCard: some View {
        card("ACCEPTED LICENSES") {
            let accepted = env.catalog.acceptedLicenses.sorted()
            if accepted.isEmpty {
                caption("Licenses you accept before downloading a model are "
                        + "remembered here.")
            } else {
                ForEach(accepted, id: \.self) { id in
                    HStack(spacing: 10) {
                        Text(modelName(id) ?? id)
                            .font(Bench.Typo.secondary)
                            .foregroundStyle(Bench.Palette.textPrimary)
                        Spacer(minLength: 8)
                        Button("Forget") {
                            env.catalog.revokeLicense(modelId: id)
                        }
                        .buttonStyle(.bench(.quiet))
                    }
                }
                caption("Forgetting one shows that model\u{2019}s license "
                        + "sheet again before its next download. Nothing is "
                        + "deleted.")
            }
        }
    }

    // MARK: - Engine summary

    private var engineSummaryCard: some View {
        card("ENGINE") {
            BenchInfoRow("Status", env.backendStatus.phase.label, labelWidth: 92)
            BenchInfoRow("Version", env.backendStatus.engineVersion ?? "—",
                         mono: true, labelWidth: 92)
        }
    }
}

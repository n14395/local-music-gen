import AppKit
import SwiftUI

/// The `Settings` scene, wearing the app's own window.
///
/// It used to be a system preferences window with the Bench palette painted
/// on: a title bar reading "Settings", a second band underneath reading
/// "Settings" again, eight equal-weight rows in a 172 pt rail, and a blue
/// macOS focus ring on whichever of them the keyboard was on. Each of those is
/// individually small and collectively they read as a different application.
///
/// So the shell is the main window's, component for component — `SettingsRail`
/// is built from the same `BenchSidebarRow`/`BenchSidebarHeading`/
/// `BenchSidebarCard` the main sidebar is, at the same 230 pt, with the
/// traffic lights over its reserved 52 pt header. What is left of the old
/// window is its content, restyled by two rules: group labels sit above their
/// card rather than inside it, and controls sit in one right-hand column
/// (`SettingsRows.swift` explains why both matter).
struct SettingsView: View {
    let env: AppEnvironment

    @State private var pane: SettingsPane = .general
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @State private var hfToken = ""
    @State private var tokenSaved = false
    @State private var t3kKey = ""
    @State private var t3kSaved = false
    @State private var confirmingReset = false
    @State private var confirmingSectionReset = false
    /// How many songs the library holds, for the rail's trailing count. Read
    /// from the repository rather than from `library.results`, which is
    /// whatever the Library screen was last filtered to — a number that would
    /// mean something different depending on where you had been.
    @State private var songCount = 0

    private var isSearching: Bool {
        query.trimmingCharacters(in: .whitespaces).count >= 2
    }

    var body: some View {
        @Bindable var settings = env.settings
        HStack(spacing: 0) {
            SettingsRail(env: env, pane: $pane, query: $query,
                         searchFocus: $searchFocused, songCount: songCount)
            content($settings)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Bench.Palette.windowBackground)
        }
        .background(Bench.Palette.windowBackground)
        // Ordered exactly as `MainWindow` orders it, and the order is the
        // whole trick: `.hiddenTitleBar` gives a full-size content view but
        // SwiftUI still reserves a 32 pt safe area where the titlebar would
        // be. Ignoring it *after* the columns are laid out lifts both of them
        // into that band together — the rail's reserved header takes the
        // traffic lights and the content's 52 pt header lines up beside it. A
        // `.frame` applied before this modifier resolves against the inset
        // area instead, which lifted the content header alone and left it
        // half above the window's top edge.
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 900, minHeight: 620)
        .preferredColorScheme(.dark)
        .background(SettingsWindowConfigurator())
        .onAppear {
            if let token = Keychain.get(account: "hf-token") {
                hfToken = token
                tokenSaved = true
            }
            if let key = Keychain.get(account: "tone3000-key") {
                t3kKey = key
                t3kSaved = true
            }
            refreshSongCount()
        }
        .onChange(of: env.library.recent.count) { refreshSongCount() }
        // ⌘F is the Edit menu's item now, not a hidden button: one item that
        // names where it will land ("Find in Settings") instead of four
        // invisible ones that claimed the key with nothing to show for it.
        .focusedSceneValue(\.searchCommand,
                           SearchCommand(scope: "Settings") { searchFocused = true })
    }

    private func refreshSongCount() {
        let counts = (try? env.library.repository.countsByOrigin()) ?? [:]
        songCount = counts.values.reduce(0, +)
    }

    // MARK: - Content column

    @ViewBuilder
    private func content(_ settings: Bindable<AppSettings>) -> some View {
        VStack(spacing: 0) {
            if isSearching {
                SettingsSearchResults(query: query) { entry in
                    pane = entry.pane
                    query = ""
                    searchFocused = false
                }
            } else {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        panel(settings)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.top, 24).padding(.bottom, 28)
                }
                statusStrip
            }
        }
    }

    private var header: some View {
        SettingsSectionHeader(
            title: pane.title,
            onReset: { confirmingSectionReset = true },
            resetDisabled: changedInPane == 0) {
            if pane == .notifications { notificationChip }
        }
        .confirmationDialog(
            "Reset \u{201C}\(pane.title)\u{201D} to its defaults?",
            isPresented: $confirmingSectionReset) {
            Button("Reset \(settingsInPane) setting"
                   + (settingsInPane == 1 ? "" : "s"), role: .destructive) {
                SettingsCatalog.reset(pane: pane, env.settings)
            }
        } message: {
            Text(changedInPane == 1
                 ? "One setting in this section differs from its default. "
                   + "Nothing outside this section changes."
                 : "\(changedInPane) settings in this section differ from "
                   + "their defaults. Nothing outside this section changes.")
        }
    }

    /// The section's permission state, as a chip rather than as a card whose
    /// only content was one line of it.
    @ViewBuilder
    private var notificationChip: some View {
        if env.notifications.isAllowed {
            SettingsChip(text: "ALLOWED BY MACOS")
        } else if env.notifications.isDenied {
            SettingsChip(text: "TURNED OFF IN SYSTEM SETTINGS",
                         tone: Bench.Palette.warn)
        } else {
            SettingsChip(text: "NOT ASKED YET", tone: Bench.Palette.textFaint)
        }
    }

    private var settingsInPane: Int { SettingsCatalog.entries(in: pane).count }
    private var changedInPane: Int {
        SettingsCatalog.changedCount(in: pane, env.settings)
    }

    private var statusStrip: some View {
        SettingsStatusStrip(
            total: settingsInPane, changed: changedInPane,
            link: pane.externalLink.map { link in
                (label: link.label, action: { follow(link.kind) })
            })
    }

    private func follow(_ link: SettingsPane.ExternalLink) {
        switch link {
        case .notificationSettings:
            env.notifications.openSystemSettings()
        case .dataFolder:
            NSWorkspace.shared.activateFileViewerSelecting([StoragePaths.root])
        case .modelLibrary:
            if let url = env.modelLibrary.info?.url {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        case .engineLogs:
            NSWorkspace.shared
                .activateFileViewerSelecting([StoragePaths.engineLogs])
        }
    }

    @ViewBuilder
    private func panel(_ settings: Bindable<AppSettings>) -> some View {
        switch pane {
        case .general:
            askFirstGroup(settings)
            motionGroup(settings)
            resetGroup
        case .notifications:
            permissionBanner
            deliveryGroup(settings)
            eventsGroup(settings)
        case .generation:
            openingModelGroup
            newRendersGroup(settings)
            analysisGroup(settings)
            assistantGroup(settings)
            presetsGroup
        case .audio:
            loudnessGroup(settings)
            mixDefaultsGroup(settings)
            mediaKeysGroup(settings)
        case .library:
            filesGroup(settings)
            librarySortGroup(settings)
            backupsGroup
            storageGroup
        case .queue:
            queueGroup
        case .models:
            if libraryNeedsRestart { libraryRestartBanner }
            ModelLibraryCard(env: env)
            huggingFaceGroup
            tone3000Group
            licencesGroup
        case .engine:
            if needsEngineRestart { restartBanner }
            smallModelsGroup
            memoryGuardGroup
            downloadsGroup
            engineSummaryGroup
            BackendDebugView(status: env.backendStatus,
                             manager: env.backendManager,
                             telemetry: env.telemetry)
        }
    }

    // MARK: - Bits

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(Bench.Typo.caption)
            .foregroundStyle(Bench.Palette.textFaint)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// A note under a card, outside it — the counterpart of lifting the label
    /// out of the top. An explanation that belonged to the whole card used to
    /// be its last row, which made the card's bottom edge arbitrary.
    private func footnote(_ text: String) -> some View {
        caption(text).padding(.horizontal, 2)
    }

    // MARK: - General

    private func askFirstGroup(_ settings: Bindable<AppSettings>) -> some View {
        SettingsGroup("ASK FIRST") {
            SettingsToggleRow(
                title: "Before deleting songs and parts",
                detail: "Off, the Delete actions act immediately. "
                    + "\u{201C}Move deleted files to the Trash\u{201D} "
                    + "(Library & Files) still applies either way. Deleting a "
                    + "model always asks.",
                isOn: settings.confirmDeletes)
            SettingsDivider()
            SettingsToggleRow(
                title: "Before reverting a track to its original",
                detail: "Reverting discards applied edits for good — the one "
                    + "action here the Trash cannot undo.",
                isOn: settings.confirmRevert)
            SettingsDivider()
            SettingsToggleRow(
                title: "Before quitting while a render is running",
                detail: "Quitting cancels the render either way; this is only "
                    + "about being asked.",
                isOn: settings.confirmQuitWhileRendering)
        }
    }

    private func motionGroup(_ settings: Bindable<AppSettings>) -> some View {
        SettingsGroup("MOTION") {
            SettingsToggleRow(
                title: "Reduce motion",
                detail: "Panels and the sidebar snap into place instead of "
                    + "sliding.",
                isOn: settings.reduceMotion)
        }
    }

    private var resetGroup: some View {
        SettingsGroup("START OVER") {
            SettingsActionRow(
                detail: "The welcome tour appears the next time the main "
                    + "window opens. Recent actions is the \u{201C}Recently "
                    + "used\u{201D} row in the Actions gallery.") {
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
            SettingsDivider()
            SettingsActionRow(
                detail: "Every section of this window, plus per-screen choices "
                    + "like filters and view modes. Your library and models "
                    + "stay as they are.") {
                Button("Reset all preferences…") { confirmingReset = true }
                    .buttonStyle(.bench(.destructive))
            }
        }
        .confirmationDialog("Reset every preference to its default?",
                            isPresented: $confirmingReset) {
            Button("Reset preferences", role: .destructive) {
                env.settings.resetAllPreferences()
                env.catalog.reloadPersisted()
            }
        } message: {
            Text("Music, parts, downloaded models and the Hugging Face token "
                 + "are not touched.")
        }
    }

    // MARK: - Notifications

    /// Only drawn when there is something to do about it. The state itself is
    /// the header's chip; this is the button that chip cannot be.
    @ViewBuilder
    private var permissionBanner: some View {
        Group {
            if !env.notifications.isAllowed {
                HStack(alignment: .top, spacing: 10) {
                    StatusDot(color: env.notifications.isDenied
                              ? Bench.Palette.warn : Bench.Palette.textFaint,
                              size: 6)
                        .padding(.top, 5)
                    Text(env.notifications.isDenied
                         ? "macOS is holding these back. Everything below "
                           + "stays set, and starts working again the moment "
                           + "notifications are switched back on for LocalMusic."
                         : "macOS has not been asked yet, so nothing below can "
                           + "be delivered.")
                        .font(Bench.Typo.caption)
                        .foregroundStyle(Bench.Palette.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if env.notifications.isDenied {
                        Button("Open System Settings") {
                            env.notifications.openSystemSettings()
                        }
                        .buttonStyle(.benchSecondary)
                    } else {
                        Button("Allow notifications…") {
                            Task { await env.notifications.request() }
                        }
                        .buttonStyle(.benchSecondary)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .benchCard(fill: Bench.Palette.warn.opacity(0.07),
                           stroke: Bench.Palette.warn.opacity(0.22))
            }
        }
        .task { await env.notifications.refresh() }
    }

    private func deliveryGroup(_ settings: Bindable<AppSettings>) -> some View {
        SettingsGroup("DELIVERY") {
            SettingsToggleRow(
                title: "Notify me",
                detail: "The master switch for every notice the app sends on "
                    + "its own. A render you armed with \u{201C}Notify me when "
                    + "it lands\u{201D} is delivered regardless — that button "
                    + "is its own consent.",
                isOn: settings.notificationsEnabled)
            SettingsDivider()
            SettingsToggleRow(
                title: "Also while I\u{2019}m using the app",
                detail: "Off, notices arrive only once you have switched away "
                    + "to something else.",
                isOn: settings.notifyAlways)
            SettingsDivider()
            SettingsToggleRow(
                title: "Play a sound",
                detail: "The system notification sound, on each notice.",
                isOn: settings.notificationSound)
            SettingsDivider()
            SettingsToggleRow(
                title: "Bounce the Dock icon",
                detail: "A nudge in the Dock alongside each notice.",
                isOn: settings.dockBounce)
            SettingsDivider()
            SettingsToggleRow(
                title: "Always tell me when a render lands",
                detail: "Every Generate render behaves as if \u{201C}Notify me "
                    + "when it lands\u{201D} were pressed on it — you hear "
                    + "about it even with the app in front.",
                isOn: settings.autoArmRenders)
        }
    }

    private func eventsGroup(_ settings: Bindable<AppSettings>) -> some View {
        SettingsGroup("TELL ME ABOUT") {
            SettingsToggleRow(
                title: "Finished tracks",
                detail: "A generation completed while you were away.",
                isOn: settings.notifyTrackReady)
            SettingsDivider()
            SettingsToggleRow(
                title: "Failed renders",
                detail: "A generation stopped with an error.",
                isOn: settings.notifyJobFailed)
            SettingsDivider()
            SettingsToggleRow(
                title: "Installed models",
                detail: "A model download or runtime install finished.",
                isOn: settings.notifyDownloadCompleted)
            SettingsDivider()
            SettingsToggleRow(
                title: "Failed downloads",
                detail: "A download died before it finished.",
                isOn: settings.notifyDownloadFailed)
            SettingsDivider()
            SettingsToggleRow(
                title: "Engine warnings",
                detail: "Memory pressure and other engine trouble.",
                isOn: settings.notifyEngineWarning)
            SettingsDivider()
            SettingsToggleRow(
                title: "Applied edits",
                detail: "An Editor render replaced a track\u{2019}s file.",
                isOn: settings.notifyEditsApplied)
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

    private var openingModelGroup: some View {
        SettingsGroup("OPENING MODEL") {
            SettingsRow(
                title: "Generate opens on",
                detail: "Whichever policy, a model that is missing falls back "
                    + "to the first installed generator.",
                alignment: .center) {
                HStack(spacing: 9) {
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
            }
        }
    }

    private func newRendersGroup(_ settings: Bindable<AppSettings>) -> some View {
        SettingsGroup("NEW RENDERS") {
            SettingsWideRow(
                title: "Start length and takes",
                detail: "Where the composer\u{2019}s length and take count "
                    + "start — each model still clamps them to what it can "
                    + "do.") {
                VStack(spacing: 11) {
                    BufferedSliderRow(label: "Length",
                                      value: settings.defaultDurationS,
                                      range: 1...120, step: 1, labelWidth: 64,
                                      format: { String(format: "%.0f s", $0) })
                    HStack(spacing: 12) {
                        Text("Takes")
                            .font(Bench.Typo.secondary)
                            .foregroundStyle(Bench.Palette.textSecondary)
                            .frame(width: 64, alignment: .leading)
                        BenchStepper(value: settings.defaultTakes, range: 1...16)
                        Spacer(minLength: 0)
                    }
                }
            }
            SettingsDivider()
            SettingsToggleRow(
                title: "Hold the seed",
                detail: "A seed field left on \u{201C}random\u{201D} borrows "
                    + "the previous take\u{2019}s seed, so prompt tweaks "
                    + "re-roll the words, not the dice. A seed you typed is "
                    + "always yours.",
                isOn: settings.holdSeed)
            SettingsDivider()
            SettingsToggleRow(
                title: "Live preview while rendering",
                detail: "Asks the engine for partial audio mid-render, so the "
                    + "render card can draw the take as it forms. Only some "
                    + "models can produce one — the card stays quiet for the "
                    + "rest.",
                isOn: settings.livePreview)
        }
    }

    private func analysisGroup(_ settings: Bindable<AppSettings>) -> some View {
        SettingsGroup("WHEN NEW AUDIO LANDS") {
            SettingsToggleRow(
                title: "Analyze new audio automatically",
                detail: "Runs a quick tempo/key/beats pass on every track that "
                    + "lands in the library, when an analysis model is "
                    + "installed. Powers part badges, mash-ability scores and "
                    + "timeline alignment.",
                isOn: settings.autoAnalyze)
            if env.settings.autoAnalyze {
                SettingsDivider()
                SettingsRow(title: "Analyzer", alignment: .center) {
                    modelPicker(selection: env.settings.analyzerModelId,
                                task: "analyze",
                                automaticLabel: "Automatic") {
                        env.settings.analyzerModelId = $0
                    }
                }
            }
            SettingsDivider()
            SettingsToggleRow(
                title: "Describe new audio automatically",
                detail: "Has a model listen to every new track and write a "
                    + "description onto it. Off by default: describers are "
                    + "language models, and one large enough to be good "
                    + "unloads the music model between renders.",
                isOn: settings.autoDescribe)
            if env.settings.autoDescribe {
                SettingsDivider()
                SettingsRow(title: "Describer", alignment: .center) {
                    modelPicker(selection: env.settings.describerModelId,
                                task: "caption",
                                automaticLabel: "Automatic") {
                        env.settings.describerModelId = $0
                    }
                }
            }
            SettingsDivider()
            SettingsToggleRow(
                title: "Tag new audio automatically",
                detail: "Scores every new track against genre, mood and "
                    + "instrument vocabularies, and adds the confident "
                    + "labels to its tags. Nothing you typed is removed.",
                isOn: settings.autoTagScan)
            if env.settings.autoTagScan {
                SettingsDivider()
                SettingsRow(title: "Tagger", alignment: .center) {
                    modelPicker(selection: env.settings.taggerModelId,
                                task: "tag",
                                automaticLabel: "Automatic") {
                        env.settings.taggerModelId = $0
                    }
                }
            }
            SettingsDivider()
            SettingsToggleRow(
                title: "Transcribe lyrics automatically",
                detail: "Writes down the sung words of every new track as "
                    + "their own attributed text, with timings. The song's "
                    + "own lyrics field — what a generator was given — is "
                    + "never touched.",
                isOn: settings.autoLyrics)
            if env.settings.autoLyrics {
                SettingsDivider()
                SettingsRow(title: "Lyric transcriber", alignment: .center) {
                    modelPicker(selection: env.settings.lyricsTranscriberModelId,
                                task: "lyrics",
                                automaticLabel: "Automatic") {
                        env.settings.lyricsTranscriberModelId = $0
                    }
                }
            }
            SettingsDivider()
            SettingsRow(
                title: "Split with",
                detail: "The separator a Split action opens on. The picker on "
                    + "the action itself still lists everything installed.",
                alignment: .center) {
                modelPicker(selection: env.settings.defaultSeparatorId,
                            task: "separate",
                            automaticLabel: "Recipe\u{2019}s choice") {
                    env.settings.defaultSeparatorId = $0
                }
            }
        }
    }

    private func assistantGroup(_ settings: Bindable<AppSettings>) -> some View {
        SettingsGroup("WRITING ASSISTANT") {
            SettingsRow(
                title: "Assistant",
                detail: "The small language model behind the \u{201C}Help me "
                    + "write\u{201D} cards. It runs on this Mac and sends "
                    + "nothing anywhere.",
                alignment: .center) {
                modelPicker(selection: env.settings.assistantModelId,
                            task: "assist",
                            automaticLabel: "Automatic") {
                    env.settings.assistantModelId = $0
                }
            }
            SettingsDivider()
            SettingsRow(
                title: "Variety",
                detail: "How adventurous its suggestions are. Lower repeats "
                    + "itself; higher surprises you and occasionally wanders.",
                alignment: .center) {
                HStack(spacing: 10) {
                    Slider(value: settings.assistantTemperature,
                           in: 0...1.5, step: 0.05)
                        .frame(width: 180)
                    Text(env.settings.assistantTemperature
                            .formatted(.number.precision(.fractionLength(2))))
                        .font(Bench.Typo.metaLine)
                        .foregroundStyle(Bench.Palette.textTertiary)
                        .monospacedDigit()
                }
            }
        }
    }

    private var presetsGroup: some View {
        SettingsGroup("SAVED PRESETS") {
            let presets = storedPresets
            if presets.isEmpty {
                SettingsRow(
                    title: "None saved yet",
                    detail: "Parameter presets you save in the Studio\u{2019}s "
                        + "Full-control panel appear here.")
            } else {
                ForEach(Array(presets.enumerated()), id: \.element) { index, preset in
                    if index > 0 { SettingsDivider() }
                    SettingsRow(title: preset.name,
                                detail: modelName(preset.modelId) ?? preset.modelId,
                                alignment: .center) {
                        Button("Delete") { deletePreset(preset) }
                            .buttonStyle(.bench(.quiet))
                    }
                }
            }
        }
    }

    /// The same `studio.presets` blob the parameter panel writes; managed here
    /// so a pile of stale presets does not need a per-chip hunt through the
    /// Studio to clean up.
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

    private func loudnessGroup(_ settings: Bindable<AppSettings>) -> some View {
        SettingsGroup("LOUDNESS") {
            SettingsWideRow(
                title: "House target",
                detail: "Where the Workbench footer and the Editor\u{2019}s "
                    + "normalise slider start; each mix can still move it. "
                    + "Everything ends in the same limiter at \u{2212}1 dBTP.") {
                BufferedSliderRow(label: "Target", value: settings.targetLufs,
                                  range: -30...(-6), step: 0.5, labelWidth: 64,
                                  valueWidth: 84,
                                  format: { String(format: "%.1f LUFS", $0) })
            }
        }
    }

    private func mixDefaultsGroup(_ settings: Bindable<AppSettings>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsGroup("A FRESH WORKBENCH STARTS WITH") {
                SettingsToggleRow(
                    title: "Match tempo",
                    detail: "Stretch clips onto the mix\u{2019}s grid.",
                    isOn: settings.autoMatchTempo)
                SettingsDivider()
                SettingsToggleRow(
                    title: "Match key",
                    detail: "Shift clips into the mix\u{2019}s key.",
                    isOn: settings.autoMatchKey)
                SettingsDivider()
                SettingsToggleRow(
                    title: "Keep the separate tracks",
                    detail: "Save each mixed track as a part alongside the "
                        + "mixdown.",
                    isOn: settings.keepStems)
            }
            footnote("Applied at launch; the bench\u{2019}s own chips override "
                     + "them for the session.")
        }
    }

    private func mediaKeysGroup(_ settings: Bindable<AppSettings>) -> some View {
        SettingsGroup("SYSTEM PLAYBACK") {
            SettingsToggleRow(
                title: "Media keys & Now Playing",
                detail: "Play/pause keys, Control Centre and the Now Playing "
                    + "widget follow whichever player is sounding.",
                isOn: settings.nowPlayingEnabled)
            .onChange(of: env.settings.nowPlayingEnabled) { _, enabled in
                env.setNowPlaying(enabled: enabled)
            }
        }
    }

    // MARK: - Library & Files

    private func filesGroup(_ settings: Bindable<AppSettings>) -> some View {
        SettingsGroup("FILES") {
            SettingsToggleRow(
                title: "Move deleted files to the Trash",
                detail: "Deleted songs, parts and edit backups go to the Trash "
                    + "instead of being removed outright. Waveform caches are "
                    + "always removed — they regenerate.",
                isOn: settings.deleteToTrash)
            SettingsDivider()
            SettingsRow(
                title: "Export as",
                detail: "What the Editor\u{2019}s export sheet opens set to; "
                    + "each export can still change both.",
                alignment: .center) {
                HStack(spacing: 9) {
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
            }
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

    private func librarySortGroup(_ settings: Bindable<AppSettings>) -> some View {
        SettingsGroup("LIBRARY") {
            SettingsRow(title: "Sort the library by", alignment: .center) {
                BenchMenu(label: LibraryScreen.label(
                    for: env.settings.libraryDefaultSort)) {
                    ForEach(LibraryRepository.Sort.allCases, id: \.self) { sort in
                        Button(LibraryScreen.label(for: sort)) {
                            env.settings.libraryDefaultSort = sort
                        }
                    }
                }
            }
            SettingsDivider()
            SettingsToggleRow(
                title: "Remember my last sort",
                detail: "Picking a sort in the Library also makes it the "
                    + "default above.",
                isOn: settings.libraryRemembersSort)
        }
    }

    private var backupsGroup: some View {
        SettingsGroup("EDIT BACKUPS") {
            SettingsRow(
                title: "Keep at most",
                detail: "The originals stashed when the Editor applies edits "
                    + "in place. Past the cap the oldest are pruned — and a "
                    + "pruned backup is that track\u{2019}s Revert gone, which "
                    + "is why \u{201C}Everything\u{201D} is the default.",
                alignment: .center) {
                BenchMenu(label: env.settings.backupsCapGB == 0
                          ? "Everything"
                          : String(format: "%.0f GB", env.settings.backupsCapGB)) {
                    Button("Everything") { setBackupsCap(0) }
                    Divider()
                    ForEach([2.0, 5.0, 10.0], id: \.self) { gb in
                        Button(String(format: "%.0f GB", gb)) { setBackupsCap(gb) }
                    }
                }
            }
        }
    }

    private func setBackupsCap(_ gb: Double) {
        env.settings.backupsCapGB = gb
        env.pruneHousekeeping()
    }

    @State private var diskFigures: [(label: String, url: URL, bytes: Int64)] = []

    private var storageGroup: some View {
        SettingsGroup("STORAGE") {
            SettingsRow(title: "Data folder", detail: StoragePaths.root.path,
                        alignment: .center) {
                Button("Reveal") {
                    NSWorkspace.shared
                        .activateFileViewerSelecting([StoragePaths.root])
                }
                .buttonStyle(.bench(.quiet))
            }
            ForEach(diskFigures, id: \.label) { figure in
                SettingsDivider()
                SettingsRow(title: figure.label,
                            detail: ByteCountFormatter.string(
                                fromByteCount: figure.bytes, countStyle: .file),
                            alignment: .center) {
                    Button("Reveal") {
                        NSWorkspace.shared
                            .activateFileViewerSelecting([figure.url])
                    }
                    .buttonStyle(.bench(.quiet))
                }
            }
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

    private var queueGroup: some View {
        SettingsGroup("FINISHED ROWS") {
            SettingsRow(
                title: "Clear finished rows",
                detail: "Renders and downloads alike, whether they succeeded, "
                    + "failed or were cancelled. \u{201C}Clear done\u{201D} in "
                    + "the queue panel always works immediately.",
                alignment: .center) {
                BenchMenu(label: env.settings.queueAutoClear.label) {
                    ForEach(AppSettings.QueueAutoClear.allCases, id: \.self) { policy in
                        Button(policy.label) {
                            env.settings.queueAutoClear = policy
                            // Rows already finished start their clock now.
                            env.jobsStore.ensureAutoClearRunning()
                            env.downloadsStore.ensureAutoClearRunning()
                        }
                    }
                }
            }
        }
    }

    // MARK: - Models & Downloads

    private var huggingFaceGroup: some View {
        SettingsGroup("HUGGING FACE") {
            SettingsWideRow(
                title: "Access token",
                detail: "Needed for gated models like Stable Audio Open. "
                    + "Stored only in your Keychain and handed to the local "
                    + "engine at launch.") {
                VStack(alignment: .leading, spacing: 9) {
                    SecureField("hf_…", text: $hfToken)
                        .textFieldStyle(.plain)
                        .tint(Bench.Palette.accent)
                        .font(Bench.Typo.mono(12))
                        .foregroundStyle(Bench.Palette.textPrimary)
                        .padding(.horizontal, 11).padding(.vertical, 8)
                        .background(RoundedRectangle(
                            cornerRadius: Bench.Metrics.Radius.control,
                            style: .continuous)
                            .fill(Bench.Palette.windowBackground))
                        .overlay(RoundedRectangle(
                            cornerRadius: Bench.Metrics.Radius.control,
                            style: .continuous)
                            .strokeBorder(Bench.Palette.cardStroke, lineWidth: 1))
                    HStack(spacing: 8) {
                        Button("Save token", action: saveToken)
                            .buttonStyle(.benchSecondary)
                        Button("Remove", action: removeToken)
                            .buttonStyle(.bench(.quiet))
                        if tokenSaved {
                            SettingsChip(text: "SAVED TO KEYCHAIN")
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private var tone3000Group: some View {
        SettingsGroup("TONE3000") {
            SettingsWideRow(
                title: "API key",
                detail: "Lets the re-amp card browse tone3000.com's amp "
                    + "captures in place. Use the SECRET key (t3k_cs_…) "
                    + "from tone3000.com/settings — the public t3k_pub_ "
                    + "key is an OAuth id and will not work. Stored only "
                    + "in your Keychain; downloads go straight from "
                    + "TONE3000 to this Mac.") {
                VStack(alignment: .leading, spacing: 9) {
                    SecureField("t3k_cs_…", text: $t3kKey)
                        .textFieldStyle(.plain)
                        .tint(Bench.Palette.accent)
                        .font(Bench.Typo.mono(12))
                        .foregroundStyle(Bench.Palette.textPrimary)
                        .padding(.horizontal, 11).padding(.vertical, 8)
                        .background(RoundedRectangle(
                            cornerRadius: Bench.Metrics.Radius.control,
                            style: .continuous)
                            .fill(Bench.Palette.windowBackground))
                        .overlay(RoundedRectangle(
                            cornerRadius: Bench.Metrics.Radius.control,
                            style: .continuous)
                            .strokeBorder(Bench.Palette.cardStroke, lineWidth: 1))
                    HStack(spacing: 8) {
                        Button("Save key", action: saveT3KKey)
                            .buttonStyle(.benchSecondary)
                        Button("Remove", action: removeT3KKey)
                            .buttonStyle(.bench(.quiet))
                        if t3kSaved {
                            SettingsChip(text: "SAVED TO KEYCHAIN")
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private func saveT3KKey() {
        let trimmed = t3kKey.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        Keychain.set(trimmed, account: "tone3000-key")
        t3kSaved = true
    }

    private func removeT3KKey() {
        Keychain.delete(account: "tone3000-key")
        t3kKey = ""
        t3kSaved = false
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

    private var licencesGroup: some View {
        SettingsGroup("ACCEPTED LICENSES") {
            let accepted = env.catalog.acceptedLicenses.sorted()
            if accepted.isEmpty {
                SettingsRow(
                    title: "None yet",
                    detail: "Licenses you accept before downloading a model "
                        + "are remembered here.")
            } else {
                ForEach(Array(accepted.enumerated()), id: \.element) { index, id in
                    if index > 0 { SettingsDivider() }
                    SettingsRow(
                        title: modelName(id) ?? id,
                        detail: index == accepted.count - 1
                            ? "Forgetting one shows that model\u{2019}s license "
                              + "sheet again before its next download. Nothing "
                              + "is deleted."
                            : nil,
                        alignment: .center) {
                        Button("Forget") { env.catalog.revokeLicense(modelId: id) }
                            .buttonStyle(.bench(.quiet))
                    }
                }
            }
        }
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
    /// Distinct from the generic engine-settings banner because the consequence
    /// is specific and alarming if left unexplained: until the restart, every
    /// model reads as not downloaded.
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

    private var smallModelsGroup: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsGroup("SMALL HELPER MODELS") {
                SettingsRow(title: "Warm workers are", alignment: .center) {
                    HStack(spacing: 12) {
                        BenchMenu(label: env.settings.smallResidency.label) {
                            ForEach(AppSettings.SmallResidency.allCases,
                                    id: \.self) { choice in
                                Button(choice.label) {
                                    env.settings.smallResidency = choice
                                }
                            }
                        }
                        BenchStepper(value: Binding(
                            get: { env.settings.smallWarmSlots },
                            set: { env.settings.smallWarmSlots = $0 }),
                                     range: 1...4)
                    }
                }
                SettingsDivider()
                SettingsWideRow(title: "Counts as small") {
                    BufferedSliderRow(
                        label: "At most",
                        value: Binding(
                            get: { Double(env.settings.smallModelBytes)
                                / 1_000_000_000 },
                            set: { env.settings.smallModelBytes
                                = Int($0 * 1_000_000_000) }),
                        range: 0.5...4, step: 0.25, labelWidth: 64,
                        valueWidth: 74,
                        format: { String(format: "%.2f GB", $0) })
                }
            }
            footnote("Analyzers, separators and other helpers under the size "
                     + "limit run beside the big resident model instead of "
                     + "evicting it, and stay loaded between jobs for as long "
                     + "as chosen above.")
        }
    }

    private var memoryGuardGroup: some View {
        SettingsGroup("MEMORY GUARD") {
            SettingsToggleRow(
                title: "Warn about memory pressure",
                detail: "A warning when a render\u{2019}s accelerator memory "
                    + "crosses the level — it never stops the job. Legitimate "
                    + "generations can spike briefly past it.",
                isOn: Binding(
                    get: { env.settings.memGuardPercent > 0 },
                    set: { env.settings.memGuardPercent = $0 ? 90 : 0 }))
            if env.settings.memGuardPercent > 0 {
                SettingsDivider()
                SettingsWideRow(title: "Warn at") {
                    BufferedSliderRow(
                        label: "Level",
                        value: Binding(
                            get: { Double(env.settings.memGuardPercent) },
                            set: { env.settings.memGuardPercent = Int($0) }),
                        range: 50...100, step: 5, labelWidth: 64,
                        valueWidth: 94,
                        format: { String(format: "%.0f%% of RAM", $0) })
                }
            }
        }
    }

    private var downloadsGroup: some View {
        SettingsGroup("DOWNLOADS & FILES") {
            SettingsRow(title: "Parallel downloads", alignment: .center) {
                BenchStepper(value: Binding(
                    get: { env.settings.maxActiveDownloads },
                    set: { env.settings.maxActiveDownloads = $0 }), range: 1...4)
            }
            SettingsDivider()
            SettingsRow(
                title: "Model cache",
                detail: env.settings.hfHomePath
                    ?? "~/.cache/huggingface (shared default)",
                alignment: .center) {
                // Read-only here on purpose. This used to offer its own
                // "Choose folder…", which changed a path and moved nothing —
                // so the models stayed in the old folder and the catalog
                // appeared to have un-downloaded itself. Changing the folder
                // is a decision about tens of gigabytes, and it now lives with
                // the rest of that decision on Models & Downloads.
                Button("Manage…") { pane = .models }
                    .buttonStyle(.bench(.quiet))
            }
            SettingsDivider()
            SettingsRow(
                title: "Keep render files for",
                detail: "Sweeps the engine\u{2019}s Outputs folder — failed "
                    + "takes, uncollected stems; finished music is already in "
                    + "your library — and the daily engine logs.",
                alignment: .center) {
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
            SettingsDivider()
            SettingsRow(title: "Engine log level", alignment: .center) {
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

    private var engineSummaryGroup: some View {
        SettingsGroup("ENGINE") {
            SettingsRow(title: "Status", detail: env.backendStatus.phase.label)
            SettingsDivider()
            SettingsRow(title: "Version",
                        detail: env.backendStatus.engineVersion ?? "—")
        }
    }
}

// MARK: - Window

/// The one thing the scene modifiers cannot say: the window's own background.
/// Left at the system's, a resize past the content's edge flashes grey before
/// SwiftUI catches up.
private struct SettingsWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        // Deferred: the view has no window until it is in the hierarchy, and
        // this runs while it is being put there.
        DispatchQueue.main.async { [weak view] in
            view?.window?.backgroundColor = NSColor(Bench.Palette.windowBackground)
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        view.window?.backgroundColor = NSColor(Bench.Palette.windowBackground)
    }
}


/// A settings slider whose value reaches the setting when the drag ends,
/// not on every frame of it.
///
/// The sliders here are bound straight to `AppSettings`, and this window's
/// header reads `SettingsCatalog.changedCount` — which asks every entry in the
/// pane whether it still holds its default, and so subscribes the whole
/// content column to every property in the pane. One slider therefore
/// re-evaluated the header, all its group cards and the status strip on every
/// mouse-move. The `UserDefaults` write behind the setting was never the cost;
/// the pane-wide invalidation was.
///
/// Deliberately not applied to the sliders in the Studio or on the Workbench:
/// those drive a preview you are listening to while you drag, so they have to
/// stay live. Nothing in Settings previews anything.
private struct BufferedSliderRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double?
    var labelWidth: CGFloat = 112
    var valueWidth: CGFloat = 52
    var format: (Double) -> String = { String(format: "%g", $0) }

    /// Where the knob is while the gesture runs. Only read while `dragging`,
    /// so a setting changed from anywhere else still shows through at rest.
    @State private var draft = 0.0
    @State private var dragging = false

    var body: some View {
        BenchSliderRow(
            label: label,
            value: Binding(
                get: { dragging ? draft : value },
                // A caller that moves the value without a gesture — a click
                // straight onto the track, were the control ever to offer one
                // — still writes through rather than into a draft nothing
                // would commit.
                set: { next in
                    if dragging { draft = next } else { value = next }
                }),
            range: range, step: step, labelWidth: labelWidth,
            valueWidth: valueWidth, format: format,
            onEditingBegan: { draft = value; dragging = true },
            onEditingEnded: { dragging = false; value = draft })
    }
}

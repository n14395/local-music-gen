import Foundation
import Observation

/// A pending "reuse prompt" / "use as melody" / Actions-preset request from
/// another screen, consumed by Generate.
@MainActor @Observable
final class PrefillBox {
    struct Prefill: Equatable {
        var prompt: String
        var lyrics: String?
        /// Which model to arrive on. Optional since the Actions cards: a card
        /// asks for a *kind* of model and the best installed one is picked
        /// for it, and on a machine with none the card is gated before it can
        /// send anything here.
        var modelId: String?
        /// Audio files to land in specific params of the arriving model
        /// (param key → file). Generic on purpose: "use as melody" fills
        /// `melody_audio`, the vocals2music card fills `accompany_audio`,
        /// and the Studio applies whichever keys the chosen model declares,
        /// holding the rest in case the user switches to a model that does.
        var audioParams: [String: URL]
        /// Length to ask for, clamped to whatever the chosen model allows.
        var durationS: Double?
        /// How many takes. Same clamping — a model that renders one at a time
        /// gets one however many the card asked for.
        var takes: Int?
        /// A line shown once above the composer, saying what arriving here
        /// changed. Without it a card that quietly set four fields looks like
        /// a screen that changed its mind on its own.
        var notice: String?
        /// Parameter values to pour into the arriving model's form (param key
        /// → value), which is how "Reuse all parameters" carries a whole Full
        /// control panel across. Applied after the form is rebuilt, and only
        /// for keys the chosen model declares — unlike an audio file, a number
        /// from another model's form means nothing here, so an unmatched key
        /// is dropped rather than held.
        var params: [String: JSONValue]

        init(prompt: String, lyrics: String? = nil, modelId: String? = nil,
             audioParams: [String: URL] = [:], durationS: Double? = nil,
             takes: Int? = nil, notice: String? = nil,
             params: [String: JSONValue] = [:]) {
            self.prompt = prompt
            self.lyrics = lyrics
            self.modelId = modelId
            self.audioParams = audioParams
            self.durationS = durationS
            self.takes = takes
            self.notice = notice
            self.params = params
        }
    }
    var pending: Prefill?
}

/// A pending Split & Recombine intent from another screen (Library context
/// menu, part detail), consumed by the Split & Recombine screen.
@MainActor @Observable
final class StudioBox {
    enum StudioIntent: Equatable {
        case split(songId: String)
        case addToWorkbench(partId: String)
        case findMatches(materialId: String)
        /// Reopen a finished recombination on the bench, from its provenance.
        case openMix(songId: String)
        /// Open the Style Transfer workspace on this song or part, optionally
        /// with an Actions preset already applied.
        case styleTransfer(materialId: String, presetId: String?)
        /// Open Generate with an Actions preset applied. `materialId` is the
        /// track a preset reads tempo and key from, and is nil for the
        /// thirteen cards that read nothing.
        case generate(presetId: String, materialId: String?)
        /// Open the Editor on this song or part.
        case edit(materialId: String)
        /// Open "Describe it by listening" on this song or part.
        case describe(materialId: String)
    }
    var pending: StudioIntent?
}

/// Dependency container wiring the app together.
@MainActor
final class AppEnvironment {
    /// First, deliberately: its init migrates legacy defaults keys, and the
    /// stores below read the renamed keys.
    let settings: AppSettings
    let prefill = PrefillBox()
    let studio = StudioBox()
    let notifications = NotificationService()
    let backendStatus: BackendStatusStore
    let catalog: ModelCatalogStore
    let downloadsStore: DownloadsStore
    let modelLibrary = ModelLibraryStore()
    let library: LibraryStore
    let partsStore: PartsStore
    /// Text documents on songs and parts — what the music-to-text models
    /// wrote, and what the user typed into the same slots.
    let textStore: TextStore
    let partsRepo: PartsRepository
    let jobsStore: JobsStore
    let playback: PlaybackController
    /// The system transport — media keys, Control Centre, the Now Playing
    /// widget — pointed at whichever player is sounding.
    let nowPlaying = NowPlayingBridge()
    let telemetry = TelemetryStore()
    /// How long this Mac's stages have actually taken, so the render card can
    /// put a figure against a stage that has not started yet. Session-scoped
    /// and measured, never projected — see `RenderTimingStore`.
    let renderTimings = RenderTimingStore()
    let storage = StorageStore()
    /// The bench is a destination now rather than a pane inside Split &
    /// Recombine, so its model lives here — switching away from Workbench and
    /// back must not reset an arrangement in progress.
    let workbench = WorkbenchModel()
    /// Style Transfer is a workspace for the same reason the bench is: its
    /// configuration is worth more than one visit. Leaving to find a reference
    /// track in the Library and coming back to an empty form is precisely the
    /// failure the destination exists to remove.
    let styleTransfer = StyleTransferModel()
    /// The writing assistant, and the reader for a model's own plan. Both run
    /// short task jobs whose answers are a dictionary the asking page reads
    /// once — nothing they return ever becomes a library row, which is why
    /// neither goes through JobsStore. See `MetaJobRunner`.
    let assistant = AssistantStore()
    let plans = PlanStore()
    /// A music↔text pipeline in flight. Owned here rather than by the page
    /// for the reason the style-transfer chain is: the telephone game is
    /// minutes of work, and leaving Actions to listen to round two must not
    /// cancel round three — nor lose a run parked waiting for an edit.
    let textChain = TextChainModel()
    /// The Editor is a workspace too: leaving mid-edit and coming back keeps
    /// the file, the selection and the pending program.
    private(set) var editor: EditorStore!
    private(set) var backendManager: BackendProcessManager!

    /// What the engine status label opens. Assembled here because this is the
    /// only place that holds all three.
    var engineStatus: EngineStatus {
        EngineStatus(status: backendStatus, manager: backendManager,
                     telemetry: telemetry)
    }

    init(modeOverride: BackendLaunchMode? = nil,
         database: DatabaseManager? = nil,
         settings: AppSettings? = nil) {
        self.settings = settings ?? AppSettings()
        let status = BackendStatusStore()
        self.backendStatus = status
        self.catalog = ModelCatalogStore(backend: status)
        self.downloadsStore = DownloadsStore()

        let db: DatabaseManager
        if let database {
            db = database
        } else {
            do {
                try StoragePaths.ensureDirectories()
                db = try DatabaseManager(path: StoragePaths.database)
            } catch {
                // A broken database file is unrecoverable in-place; fall back to
                // memory so the app can at least run and show the error.
                db = (try? DatabaseManager.inMemory())!
                assertionFailure("library database failed to open: \(error)")
            }
        }
        let repo = LibraryRepository(db: db)
        let partsRepo = PartsRepository(db: db)
        self.partsRepo = partsRepo
        self.library = LibraryStore(repo: repo, partsRepo: partsRepo)
        self.partsStore = PartsStore(repo: partsRepo)
        self.textStore = TextStore(repo: partsRepo)
        self.jobsStore = JobsStore(repo: repo, partsRepo: partsRepo)
        self.playback = PlaybackController()
        self.editor = EditorStore(library: library, partsRepo: partsRepo,
                                  jobs: jobsStore, catalog: catalog)

        self.backendManager = BackendProcessManager(status: status, onEvent: { [weak self] item in
            Task { @MainActor in
                self?.route(item)
            }
        }, modeOverride: modeOverride,
           launchConfig: { [settings = self.settings] in
            await settings.engineLaunchConfig
        })

        // Settings policies, as live reads — a toggle applies to the next
        // delete and to rows already finished, not to the next launch.
        library.usesTrash = { [settings = self.settings] in
            settings.deleteToTrash
        }
        partsStore.usesTrash = { [settings = self.settings] in
            settings.deleteToTrash
        }
        jobsStore.autoClearAfterS = { [settings = self.settings] in
            settings.queueAutoClear.seconds
        }
        // The setting is about the queue, and a finished transfer is a row in
        // it — so both halves clear on the same schedule.
        downloadsStore.autoClearAfterS = { [settings = self.settings] in
            settings.queueAutoClear.seconds
        }
        jobsStore.autoArm = { [settings = self.settings] in
            settings.autoArmRenders
        }
        notifications.prefs = { [settings = self.settings] in
            .init(enabled: settings.notificationsEnabled,
                  alwaysDeliver: settings.notifyAlways,
                  sound: settings.notificationSound,
                  dockBounce: settings.dockBounce)
        }
        library.filters.sort = self.settings.libraryDefaultSort
        // Where a fresh bench and the Editor's normalise slider start;
        // session tweaks in either place stay theirs.
        workbench.targetLufs = self.settings.targetLufs
        workbench.autoMatchTempo = self.settings.autoMatchTempo
        workbench.autoMatchKey = self.settings.autoMatchKey
        workbench.keepTracks = self.settings.keepStems
        editor.houseTargetLufs = { [settings = self.settings] in
            settings.targetLufs
        }
        // The engine's pin is in-memory by contract; the app is what makes it
        // survive a restart. Recorded on change, replayed on `.connected`.
        catalog.onPinChanged = { [settings = self.settings] id in
            settings.pinnedModelId = id
        }

        // Closures rather than copies, like every other store's settings: the
        // assistant must see a model switched in Settings without the app
        // being restarted, and it reads the catalog live because the catalog
        // refreshes underneath it.
        assistant.models = { [weak self] in self?.catalog.models ?? [] }
        assistant.preferredModelId = { [settings = self.settings] in
            settings.assistantModelId
        }
        assistant.temperature = { [settings = self.settings] in
            settings.assistantTemperature
        }

        jobsStore.modelName = { [weak self] id in
            self?.catalog.models.first { $0.id == id }?.displayName ?? id
        }
        // These two are single-assignment properties, not a multicast — a
        // second feature that claims one silently deletes the auto-analyze
        // wiring above it. Anything else that needs to know a job landed is
        // chained here, in the one place that owns them.
        jobsStore.onSongsIngested = { [weak self] songs in
            self?.library.refreshRecent()
            for song in songs { self?.autoRun(song: song) }
            self?.advanceStyleTransfer(songs: songs, parts: [])
            self?.advanceTextChain(songs: songs, parts: [], texts: [])
        }
        jobsStore.onPartsIngested = { [weak self] parts in
            self?.partsStore.refresh()
            if let songId = parts.first?.songId {
                self?.autoRunSong(id: songId)
            }
            self?.advanceStyleTransfer(songs: [], parts: parts)
            self?.advanceTextChain(songs: [], parts: parts, texts: [])
        }
        library.onSongsImported = { [weak self] songs in
            for song in songs { self?.autoRun(song: song) }
        }
        library.onPartsRenamed = { [weak self] in
            self?.partsStore.refresh()
        }
        // Same single-assignment rule as its two siblings above.
        jobsStore.onTextIngested = { [weak self] docs in
            self?.textStore.noteIngested(docs)
            self?.advanceTextChain(songs: [], parts: [], texts: docs)
        }
        jobsStore.onEditorArtifact = { [weak self] job, result, purpose in
            self?.editor.handleArtifact(job: job, result: result,
                                        purpose: purpose)
            self?.library.refreshRecent()
            self?.partsStore.refresh()
        }
        editor.partsStore = partsStore
        editor.pauseGlobalPlayback = { [weak self] in
            guard let playback = self?.playback, playback.isPlaying else {
                return
            }
            playback.toggle()
        }
        // The system transport speaks for whichever player is making sound. Both
        // sources answer nil when they are not a candidate, and the bridge
        // leaves the Now Playing slot alone until one of them is.
        nowPlaying.songSource = { [weak self] in
            guard let playback = self?.playback,
                  playback.currentSongId != nil else { return nil }
            return NowPlayingBridge.Source(
                title: playback.currentTitle,
                subtitle: playback.currentSubtitle,
                durationS: playback.duration,
                elapsedS: playback.currentTime,
                isPlaying: playback.isPlaying,
                toggle: { playback.toggle() },
                stop: { playback.stop() },
                seek: { playback.seek(to: $0) })
        }
        nowPlaying.editorSource = { [weak self] in
            guard let editor = self?.editor, let material = editor.material,
                  editor.previewEngaged else { return nil }
            let source = material.songTitle.map { "Editing · \($0)" } ?? "Editing"
            return NowPlayingBridge.Source(
                title: material.title,
                subtitle: source,
                durationS: editor.timelineDurationS,
                elapsedS: editor.playheadS,
                isPlaying: editor.isPlaying,
                toggle: { editor.togglePlayback() },
                stop: { editor.stopPreview() },
                seek: { editor.seekPreview(to: $0) })
        }
        if self.settings.nowPlayingEnabled { nowPlaying.start() }

        editor.notifyApplied = { [weak self] title in
            guard self?.settings.notifyEditsApplied ?? true else { return }
            self?.notifications.notifyIfInactive(
                title: "Edits applied",
                body: "“\(title)” now plays the edited version.")
        }
    }

    /// Everything Settings asks for whenever new audio appears: analysis
    /// (tempo/key/beats, which part badges and alignment read), and — off by
    /// default — a description, tags, and transcribed lyrics.
    ///
    /// The decision itself lives in `AutoRunPlanner`, which is pure and
    /// tested; this is only the part that needs the stores. Every pass is
    /// guarded on what the song already carries, because each pass's own
    /// ingest re-enters the hooks that started it: without the guards, one
    /// landed description schedules the next one forever.
    private func autoRun(song: SongRecord) {
        let passes = AutoRunPlanner.passes(
            preferences: autoRunPreferences,
            existing: AutoRunPlanner.Existing(
                hasAnalysis: ((try? partsRepo.analysis(ownerId: song.id))
                              ?? nil) != nil,
                hasDescription: hasTextDoc(song.id, .description),
                hasTags: !library.tags(for: song.id).isEmpty,
                hasLyrics: hasTextDoc(song.id, .lyrics)),
            installed: installedModelIds)
        guard !passes.isEmpty else { return }
        Task { [jobsStore] in
            for pass in passes {
                switch pass {
                case .analyze(let modelId):
                    await jobsStore.submitAnalyze(
                        modelId: modelId, ownerId: song.id, ownerType: "song",
                        title: song.title, sourceURL: song.fileURL)
                case .describe(let modelId):
                    await jobsStore.submitCaption(
                        modelId: modelId, ownerId: song.id, ownerType: "song",
                        title: song.title, sourceURL: song.fileURL)
                case .tag(let modelId):
                    await jobsStore.submitTag(
                        modelId: modelId, ownerId: song.id, ownerType: "song",
                        title: song.title, sourceURL: song.fileURL)
                case .lyrics(let modelId):
                    await jobsStore.submitLyrics(
                        modelId: modelId, ownerId: song.id, ownerType: "song",
                        title: song.title, sourceURL: song.fileURL)
                }
            }
        }
    }

    private var autoRunPreferences: AutoRunPlanner.Preferences {
        AutoRunPlanner.Preferences(
            autoAnalyze: settings.autoAnalyze,
            analyzerModelId: settings.analyzerModelId,
            autoDescribe: settings.autoDescribe,
            describerModelId: settings.describerModelId,
            autoTagScan: settings.autoTagScan,
            taggerModelId: settings.taggerModelId,
            autoLyrics: settings.autoLyrics,
            lyricsTranscriberModelId: settings.lyricsTranscriberModelId)
    }

    private func installedModelIds(task: String) -> [String] {
        catalog.models
            .filter {
                $0.installState == .installed
                    && $0.capabilities.supportedTasks.contains(task)
            }
            .map(\.id)
    }

    private func hasTextDoc(_ ownerId: String, _ kind: TextDocKind) -> Bool {
        ((try? partsRepo.hasTextDoc(ownerId: ownerId,
                                    kind: kind.rawValue)) ?? false)
    }

    /// A job the Style Transfer chain was waiting on has landed.
    ///
    /// Routed through here rather than through a callback on the store because
    /// `JobsStore`'s two ingest hooks are single-assignment and already spoken
    /// for — see the comment where they are wired. Submitting the next step
    /// needs the stores, which is why the chain is driven from the dependency
    /// container rather than from inside the document.
    private func advanceStyleTransfer(songs: [SongRecord], parts: [PartRecord]) {
        guard styleTransfer.isWaitingOnWork else { return }
        Task { @MainActor in
            await styleTransfer.ingested(
                songs: songs, parts: parts, jobs: jobsStore,
                partsStore: partsStore, library: library,
                models: catalog.models)
        }
    }

    /// A job the music↔text pipeline was waiting on has landed. Routed here
    /// for the same reason the style-transfer chain is: the ingest hooks are
    /// single-assignment and already spoken for, and submitting the next
    /// stage needs the stores.
    private func advanceTextChain(songs: [SongRecord], parts: [PartRecord],
                                  texts: [TextDocRecord]) {
        guard textChain.isRunning else { return }
        Task { @MainActor in
            await textChain.ingested(
                songs: songs, parts: parts, texts: texts,
                context: .init(jobs: jobsStore, parts: partsStore,
                               library: library, textStore: textStore,
                               models: catalog.models))
        }
    }

    private func autoRunSong(id: String) {
        guard let song = ((try? library.repository.song(id: id)) ?? nil) else {
            return
        }
        autoRun(song: song)
    }

    private func route(_ item: EventStreamClient.StreamItem) {
        switch item {
        case .connected:
            Task {
                let client = await backendManager.client
                catalog.client = client
                downloadsStore.client = client
                jobsStore.client = client
                modelLibrary.client = client
                assistant.client = client
                plans.client = client
                if let client, let token = Keychain.get(account: "hf-token") {
                    try? await client.setHFToken(token)
                }
                await catalog.refresh()
                await downloadsStore.reconcile()
                await jobsStore.reconcile()
                if let system = try? await client?.system() {
                    backendStatus.workerModelId = system.warmModelId
                    backendStatus.workerModelState =
                        system.warmModelId != nil ? "loaded" : nil
                    telemetry.apply(system)
                    // A hold survives a dropped stream and an app relaunch, so
                    // it is re-read here rather than assumed released.
                    jobsStore.applyHold(from: system)
                    // Replay the persisted pin onto a fresh engine — but only
                    // onto one with no pin of its own (a reconnect mid-session
                    // must not overwrite a pin set elsewhere), and only while
                    // the model is still installed.
                    if system.pinnedModelId == nil,
                       let pinned = settings.pinnedModelId,
                       catalog.models.contains(where: {
                           $0.id == pinned && $0.installState == .installed
                       }) {
                        try? await client?.setPin(modelId: pinned, enabled: true)
                        await catalog.refresh()
                    }
                }
                storage.refresh()
            }
        case .disconnected:
            break
        case .event(let event):
            downloadsStore.apply(event)
            jobsStore.apply(event)
            modelLibrary.apply(event)
            switch event {
            case .modelsChanged, .downloadCompleted, .downloadFailed:
                Task { await catalog.refresh() }
            case .workerState(let state, let modelId, _):
                backendStatus.workerModelId = state == "stopped" ? nil : modelId
                backendStatus.workerModelState = state == "stopped" ? nil : state
            case .jobFailed(let jobId, let error):
                // A stopped chain has to stop *waiting*, or the workspace sits
                // on a job id the engine has already forgotten. Handled here
                // rather than off the ingest hooks because a job that failed
                // never ingests anything.
                styleTransfer.chainStepFailed(jobId: jobId,
                                              message: error.message)
                textChain.stepFailed(jobId: jobId, message: error.message)
            case .jobCanceled(let jobId):
                styleTransfer.chainStepFailed(jobId: jobId,
                                              message: "cancelled")
                textChain.stepFailed(jobId: jobId, message: "cancelled")
            case .libraryFinished(let op):
                // Applied on any terminal state, not only success: a relocate
                // that fell over halfway has still moved repositories, and the
                // folder the engine should come back pointing at is the new
                // one either way — the models that made it are there, and the
                // rest can be downloaded again.
                if op.restartRequired == true, let destination = op.destination {
                    settings.hfHomePath = Self.librarySetting(for: destination)
                }
            case .engineWarning(let message):
                backendStatus.appendStderr("[warning] \(message)")
            default:
                break
            }
            notify(for: event)
        }
    }

    /// nil means "the shared Hugging Face default", which is what
    /// `hfHomePath` stores for it — so choosing that folder explicitly has to
    /// land on nil rather than on a hard-coded copy of the same path.
    static func librarySetting(for path: String) -> String? {
        let chosen = URL(fileURLWithPath: path).standardizedFileURL.path
        let shared = URL(fileURLWithPath: NSString(string: "~/.cache/huggingface")
            .expandingTildeInPath).standardizedFileURL.path
        return chosen == shared ? nil : chosen
    }

    var hasRunningJob: Bool {
        jobsStore.active.values.contains { !$0.status.isTerminal }
    }

    /// Keeps the sidebar's engine card live.
    ///
    /// This polls rather than subscribing because `/v1/system` is the only
    /// surface that reports usage today; if the engine starts emitting a
    /// telemetry event, `route(_:)` can feed `telemetry` directly and this loop
    /// can slow to a heartbeat. The cadence follows the work: a few seconds
    /// while something is running, a quarter-minute when the machine is idle,
    /// so an idle app is not waking the engine every two seconds forever.
    func pollTelemetry() async {
        while !Task.isCancelled {
            if let client = await backendManager.client,
               let system = try? await client.system() {
                telemetry.apply(system)
                jobsStore.applyHold(from: system)
            }
            let busy = hasRunningJob || backendStatus.workerModelId != nil
            try? await Task.sleep(for: .seconds(busy ? 3 : 15))
        }
    }

    /// Whether each *event* deserves a notice is decided here, where the
    /// events are routed; how one is delivered (master toggle, foreground,
    /// sound, bounce) is `NotificationService.Prefs`. Armed jobs skip the
    /// per-event gate the way they skip the master toggle — the user asked
    /// about that specific job, after any of these switches were set.
    private func notify(for event: EngineEvent) {
        switch event {
        case .jobQueued:
            // No point requesting permission for notices that are all off.
            guard settings.notificationsEnabled else { break }
            notifications.requestAuthorizationIfNeeded()
        case .jobCompleted(let jobId):
            // Spent before the Editor guard below, or an armed edit render
            // would leave its id in the set for the rest of the session.
            let armed = jobsStore.takeNotifyOnLanding(jobId)
            // The Editor announces its own renders — an apply that lands
            // says "Edits applied", and "Your track is ready" beside it
            // would be the same event claimed twice.
            guard !jobsStore.isEditorJob(jobId) else { break }
            // One notice per submission, not per take. A batch is four jobs
            // now (contract §5.1) and each of them is armed, so without this
            // a four-take render buzzes four times — and the first three of
            // those are false: the render was not finished. Every take is
            // armed all the same, because any of them may be the last.
            guard jobsStore.isFinalOfBatch(jobId) else { break }
            let title = jobsStore.active[jobId].map {
                jobsStore.displayTitle(for: $0.info)
            } ?? ""
            // A job the user armed from the render card is told about either
            // way; everything else only when the app is in the background,
            // and only when the event's switch is on.
            if armed {
                notifications.notify(title: "Your track is ready",
                                     body: String(title.prefix(80)))
            } else if settings.notifyTrackReady {
                notifications.notifyIfInactive(title: "Your track is ready",
                                               body: String(title.prefix(80)))
            }
        case .jobFailed(let jobId, let error):
            // Failing IS landing, for someone who walked away. Silence here
            // would be the arming's worst outcome: they asked to be told when
            // it was done and it is done, badly.
            let armed = jobsStore.takeNotifyOnLanding(jobId)
            // Once per submission, as above: takes of a batch fail together
            // (same model, same params), and four identical alerts for one
            // press of Generate is what "tell me when it lands" would become.
            guard jobsStore.isFinalOfBatch(jobId) else { break }
            let title = jobsStore.active[jobId].map {
                jobsStore.displayTitle(for: $0.info)
            } ?? ""
            let body = "\(title.prefix(50)) — \(error.message)"
            if armed {
                notifications.notify(title: "Generation failed", body: body)
            } else if settings.notifyJobFailed {
                notifications.notifyIfInactive(title: "Generation failed",
                                               body: body)
            }
        case .downloadCompleted(_, let modelId, let runtimeOnly):
            guard settings.notifyDownloadCompleted else { break }
            let name = catalog.models.first { $0.id == modelId }?.displayName
                ?? modelId
            // A runtime install fetched no model, and saying one arrived would
            // send the user looking for a download they never started.
            notifications.notifyIfInactive(
                title: runtimeOnly ? "Runtime installed" : "Model installed",
                body: runtimeOnly ? "\(name) can render without a wait now."
                                  : "\(name) is ready to use.")
        case .downloadFailed(_, let modelId, let error):
            // The counterpart of the "Model installed" notice above. Without
            // it a download that died while the app was in the background is
            // indistinguishable from one that finished.
            guard settings.notifyDownloadFailed else { break }
            let name = catalog.models.first { $0.id == modelId }?.displayName
                ?? modelId
            notifications.notifyIfInactive(
                title: "Download failed",
                body: "\(name) — \(error.message.prefix(100))")
        case .engineWarning(let message):
            guard settings.notifyEngineWarning else { break }
            notifications.notifyIfInactive(title: "Engine warning",
                                           body: String(message.prefix(120)))
        default:
            break
        }
    }

    func startBackend() {
        Task { await backendManager.start() }
        // Read, not requested: the prompt belongs to the moment the user asks
        // to be notified, but the *answer* has to be known before then so the
        // render card can tell an armed take it will land quietly.
        Task { await notifications.refresh() }
        pruneHousekeeping()
    }

    /// Launch-time disk housekeeping the engine cannot do: the daily
    /// `backend-*.log` files the *app* writes (same retention as the engine's
    /// outputs sweep) and the Editor-backups size cap. Both no-op at their
    /// default settings.
    func pruneHousekeeping() {
        let logDays = settings.engineFileRetentionDays
        let backupCap = Int64(settings.backupsCapGB * 1_000_000_000)
        Task.detached(priority: .utility) {
            FilePruning.pruneByAge(in: StoragePaths.engineLogs,
                                   olderThanDays: logDays)
            FilePruning.capBySize(in: StoragePaths.libraryBackups,
                                  capBytes: backupCap)
        }
    }

    /// Free the resident model now; the engine refuses while a job runs and
    /// the sidebar's engine card clears via the resulting worker.state event.
    /// The engine panel's Unload button goes through the client directly to
    /// echo a refusal into the log tail; this fire-and-forget form is for
    /// flows (and tests) that only care that an idle model gets dropped.
    func unloadModel() {
        Task {
            if let client = await backendManager.client {
                try? await client.unloadWorker()
            }
        }
    }

    /// Settings' Now Playing toggle, applied live. `start()` is idempotent,
    /// so enabling after a launch that never started the bridge registers the
    /// commands now; disabling flips the bridge's own switch, which hands the
    /// tile back and keeps the observation loop from re-claiming it.
    func setNowPlaying(enabled: Bool) {
        nowPlaying.isEnabled = enabled
        if enabled { nowPlaying.start() }
    }

    func shutdown() async {
        // Hand the Now Playing tile back before the process goes, or the widget
        // keeps offering a transport for an app that is no longer there.
        nowPlaying.relinquish()
        await backendManager.stop()
    }
}

import Foundation
import Observation

/// A pending "reuse prompt" / "use as melody" request from another screen,
/// consumed by Studio.
@MainActor @Observable
final class PrefillBox {
    struct Prefill: Equatable {
        var prompt: String
        var lyrics: String?
        var modelId: String
        var melodyAudio: URL?

        init(prompt: String, lyrics: String?, modelId: String,
             melodyAudio: URL? = nil) {
            self.prompt = prompt
            self.lyrics = lyrics
            self.modelId = modelId
            self.melodyAudio = melodyAudio
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
        /// Open the Editor on this song or part.
        case edit(materialId: String)
    }
    var pending: StudioIntent?
}

/// Dependency container wiring the app together.
@MainActor
final class AppEnvironment {
    let prefill = PrefillBox()
    let studio = StudioBox()
    let notifications = NotificationService()
    let backendStatus: BackendStatusStore
    let catalog: ModelCatalogStore
    let downloadsStore: DownloadsStore
    let library: LibraryStore
    let partsStore: PartsStore
    let partsRepo: PartsRepository
    let jobsStore: JobsStore
    let playback: PlaybackController
    let telemetry = TelemetryStore()
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
         database: DatabaseManager? = nil) {
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
        self.jobsStore = JobsStore(repo: repo, partsRepo: partsRepo)
        self.playback = PlaybackController()
        self.editor = EditorStore(library: library, partsRepo: partsRepo,
                                  jobs: jobsStore, catalog: catalog)

        self.backendManager = BackendProcessManager(status: status, onEvent: { [weak self] item in
            Task { @MainActor in
                self?.route(item)
            }
        }, modeOverride: modeOverride)

        jobsStore.modelName = { [weak self] id in
            self?.catalog.models.first { $0.id == id }?.displayName ?? id
        }
        // These two are single-assignment properties, not a multicast — a
        // second feature that claims one silently deletes the auto-analyze
        // wiring above it. Anything else that needs to know a job landed is
        // chained here, in the one place that owns them.
        jobsStore.onSongsIngested = { [weak self] songs in
            self?.library.refreshRecent()
            for song in songs { self?.autoAnalyze(song: song) }
            self?.advanceStyleTransfer(songs: songs, parts: [])
        }
        jobsStore.onPartsIngested = { [weak self] parts in
            self?.partsStore.refresh()
            if let songId = parts.first?.songId {
                self?.autoAnalyzeSong(id: songId)
            }
            self?.advanceStyleTransfer(songs: [], parts: parts)
        }
        library.onSongsImported = { [weak self] songs in
            for song in songs { self?.autoAnalyze(song: song) }
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
        editor.notifyApplied = { [weak self] title in
            self?.notifications.notifyIfInactive(
                title: "Edits applied",
                body: "“\(title)” now plays the edited version.")
        }
    }

    /// Analysis (tempo/key/beats) powers part badges and later alignment, so
    /// run it opportunistically whenever new audio appears — if an analyzer is
    /// installed and the song hasn't been analyzed yet.
    private func autoAnalyze(song: SongRecord) {
        guard ((try? partsRepo.analysis(ownerId: song.id)) ?? nil) == nil,
              let analyzer = catalog.models.first(where: {
                  $0.installState == .installed
                      && $0.capabilities.supportedTasks.contains("analyze")
              }) else { return }
        Task { [jobsStore] in
            await jobsStore.submitAnalyze(
                modelId: analyzer.id, ownerId: song.id, ownerType: "song",
                title: song.title, sourceURL: song.fileURL)
        }
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

    private func autoAnalyzeSong(id: String) {
        guard let song = ((try? library.repository.song(id: id)) ?? nil) else {
            return
        }
        autoAnalyze(song: song)
    }

    private func route(_ item: EventStreamClient.StreamItem) {
        switch item {
        case .connected:
            Task {
                let client = await backendManager.client
                catalog.client = client
                downloadsStore.client = client
                jobsStore.client = client
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
                }
                storage.refresh()
            }
        case .disconnected:
            break
        case .event(let event):
            downloadsStore.apply(event)
            jobsStore.apply(event)
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
            case .jobCanceled(let jobId):
                styleTransfer.chainStepFailed(jobId: jobId,
                                              message: "cancelled")
            case .engineWarning(let message):
                backendStatus.appendStderr("[warning] \(message)")
            default:
                break
            }
            notify(for: event)
        }
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

    private func notify(for event: EngineEvent) {
        switch event {
        case .jobQueued:
            notifications.requestAuthorizationIfNeeded()
        case .jobCompleted(let jobId):
            // The Editor announces its own renders — an apply that lands
            // says "Edits applied", and "Your track is ready" beside it
            // would be the same event claimed twice.
            guard !jobsStore.isEditorJob(jobId) else { break }
            let title = jobsStore.active[jobId].map {
                jobsStore.displayTitle(for: $0.info)
            } ?? ""
            notifications.notifyIfInactive(title: "Your track is ready",
                                           body: String(title.prefix(80)))
        case .jobFailed(let jobId, let error):
            let title = jobsStore.active[jobId].map {
                jobsStore.displayTitle(for: $0.info)
            } ?? ""
            notifications.notifyIfInactive(
                title: "Generation failed",
                body: "\(title.prefix(50)) — \(error.message)")
        case .downloadCompleted(_, let modelId, let runtimeOnly):
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
            let name = catalog.models.first { $0.id == modelId }?.displayName
                ?? modelId
            notifications.notifyIfInactive(
                title: "Download failed",
                body: "\(name) — \(error.message.prefix(100))")
        case .engineWarning(let message):
            notifications.notifyIfInactive(title: "Engine warning",
                                           body: String(message.prefix(120)))
        default:
            break
        }
    }

    func startBackend() {
        Task { await backendManager.start() }
    }

    /// "Unload model" in the titlebar; the engine refuses while a job runs and
    /// the titlebar clears via the resulting worker.state event.
    func unloadModel() {
        Task {
            if let client = await backendManager.client {
                try? await client.unloadWorker()
            }
        }
    }

    func shutdown() async {
        await backendManager.stop()
    }
}

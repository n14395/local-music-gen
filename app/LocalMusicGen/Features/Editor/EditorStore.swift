import Accelerate
import AVFoundation
import Foundation
import Observation

/// The Editor's workspace: one file, its edit program, the preview that plays
/// it and the render that commits it. A destination store like the Workbench's
/// — it lives in `AppEnvironment` so leaving the Editor and coming back keeps
/// the session, selection and pending edits intact.
@MainActor @Observable
final class EditorStore {

    /// What is loaded: a library song or a part (stem). One shape, because
    /// from here on the two differ only in which table gets written back.
    struct Material: Equatable {
        var id: String
        var ownerType: String            // "song" | "part"
        var title: String
        var songTitle: String?           // a part's parent song
        var stemKind: String?            // a part's colour identity
        var promptLine: String?
        var fileURL: URL
        var backupURL: URL
        var fileName: String
        var waveformCacheURL: URL
        var sampleRate: Int
        var fileDurationS: Double
        var origin: SongOrigin?

        var isPart: Bool { ownerType == "part" }
    }

    /// Where an apply currently is — the five stages the design's progress
    /// card names. `rendering` carries what the engine reports.
    enum ApplyStage: Equatable {
        case idle
        case stashingBackup
        case uploading
        case queued(jobId: String)
        case rendering(jobId: String, fraction: Double?, etaS: Double?,
                       message: String?)
        case replacing
        /// Putting the stashed original back. Its own case rather than
        /// `replacing` because the file work is now detached, and this is
        /// what holds the editing surface closed while it runs — see
        /// `restoreOriginal`.
        case restoring
        case rebuildingPeaks
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .idle, .failed: false
            default: true
            }
        }
    }

    enum RailTab: String, CaseIterable {
        case selection, adjust, effects, edits
    }

    // MARK: dependencies

    // Internal, not private: EditorStoreRender is the same store's other
    // half, and Swift's `private` is per-file.
    let library: LibraryStore
    /// The narrow write path for the Editor's own columns — see
    /// `persistPending`.
    var repo: LibraryRepository { library.repository }
    let partsRepo: PartsRepository
    /// Set by the shell so a narrow edits write can keep the parts list's
    /// cached rows in step — see `persistPending`.
    weak var partsStore: PartsStore?
    let jobs: JobsStore
    let catalog: ModelCatalogStore
    let player = MultiPartPlayer()

    /// Pauses the app's main transport — starting the edit preview while a
    /// library track keeps playing would sum two songs.
    var pauseGlobalPlayback: () -> Void = {}
    /// A rendered selection snippet has landed in the library; the shell
    /// routes it (continue from here / split / find matches).
    var onSnippetReady: (SongRecord, SnippetIntent) -> Void = { _, _ in }
    /// The apply finished while the user asked to be told and moved on.
    var notifyApplied: (String) -> Void = { _ in }
    /// Where the normalise slider starts when it is switched on — Settings'
    /// house loudness. A live read so a change applies to the next toggle-on.
    var houseTargetLufs: @MainActor () -> Double = { -14 }

    enum SnippetIntent: Equatable {
        case continueFrom, splitRegion, findMatches
    }

    // MARK: state

    /// The backup's existence follows the material, so every `open` path
    /// refreshes the cached answer without having to remember to.
    var material: Material? {
        didSet { refreshBackupState() }
    }
    var document = EditDocument()
    private(set) var segments: [EditSegment] = []
    private(set) var grid = EditorGrid()
    private(set) var analysis: AnalysisPayload?
    private(set) var bpm: Double?
    private(set) var camelot: String?
    /// The program state the file currently holds (nil = file is pristine).
    var appliedDocument: EditDocument?

    var selection: EditRange? {
        didSet {
            guard oldValue != selection else { return }
            let amplify = computeAmplifyDbForSelection()
            if amplify != amplifyDbForSelection { amplifyDbForSelection = amplify }
        }
    }
    var cursorS: Double = 0
    var snapMode: EditorGeometry.SnapMode = .beats
    var showBeatGrid = true
    var stereoView = false
    var loopSelection = false
    var railTab: RailTab = .selection
    /// Derived, not stored, so an undo that restores the document also
    /// restores the chip.
    var crossfadeJoins: Bool { document.joinCrossfadeMs > 0 }

    /// Viewport of the main well; width is supplied by the view's geometry.
    var visibleStartS: Double = 0
    var pxPerSecond: CGFloat = 0    // 0 = fit on first layout
    /// The well's last laid-out width, so zoom math outside the view (the
    /// slider, the overview strip) shares the same geometry.
    var wellWidth: CGFloat = 0

    private(set) var clipboard: [EditSegment] = []
    /// Which material the clipboard was cut from. A copied slice is a
    /// reference into THAT source file, so pasting it into another track
    /// would splice in whatever happens to sit at those seconds of a
    /// different recording. The clipboard is kept across tracks anyway, so
    /// the menu can say why it is unavailable rather than going quiet.
    private(set) var clipboardSourceId: String?
    private(set) var clipboardSourceTitle: String?
    /// A one-line result from an action that would otherwise do nothing
    /// visible. Cleared by the next edit, and after a few seconds.
    private(set) var actionNote: String?
    /// Gated in their `didSet`-free way: `setApplyStage` / `setExportStage`
    /// below are what the render watcher writes through.
    ///
    /// These are still plain `var`s because a dozen paths assign them
    /// directly with a value that really is new (`.failed`, `.idle`,
    /// `.uploading`). The one caller that repeats itself is `watchJob`, which
    /// polls and used to republish an identical `.rendering` three times a
    /// second — redrawing the apply card, its five stage tiles, the toolbar
    /// and every row menu that reads `renderingTitle`, on every tick, for the
    /// whole render.
    var applyStage: ApplyStage = .idle
    var exportStage: ApplyStage = .idle

    func setApplyStage(_ next: ApplyStage) {
        if next != applyStage { applyStage = next }
    }

    func setExportStage(_ next: ApplyStage) {
        if next != exportStage { exportStage = next }
    }
    /// The export dialog (E04) — opened from two places on the rail.
    var exportSheetOpen = false
    /// True while the user chose "notify me" and left the apply running.
    var notifyWhenApplied = false

    var undoManager: UndoManager?

    /// Playback bound: stop (or loop) at this timeline second.
    private var stopAtS: Double?
    private var loopWatcher: Timer?
    /// A/B: true while the untouched source is playing instead of the edit.
    private(set) var auditioningOriginal = false
    private var reversedSourceURL: URL?
    private var reversedSourceBuilding = false
    var uploadedSourceId: String?
    private var snippetIntents: [String: SnippetIntent] = [:]
    /// The gesture whose changes are folding into one undo step.
    private var interactionKey: String?
    /// A structural re-arm waiting for a drag to settle — see
    /// `refreshPreviewAfterEdit`.
    private var previewRearmTask: Task<Void, Never>?

    /// A structural edit landed while the preview was paused. `resume` re-arms
    /// from the items captured at the last `prepare`, so without this the user
    /// hears the pre-edit cut list — deleted audio plays. Gain changes do not
    /// set it: the nodes outlive a pause and `updateGains` lands on them
    /// directly.
    private var previewStale = false

    /// True between `beginScrub` and `endScrub`.
    private var scrubbing = false
    /// How many undo steps this session has registered. A slider drag must
    /// add exactly one however many frames it spans — see `perform`.
    private(set) var undoStepsRegistered = 0
    private var persistTask: Task<Void, Never>?
    private var noteTask: Task<Void, Never>?
    private var hasPendingWrite = false
    /// Which material the in-flight apply belongs to. An apply survives
    /// navigating away and opening something else, so every write it makes
    /// is checked against this rather than against whatever is loaded now.
    var applyOwnerId: String? {
        didSet {
            guard applyOwnerId != oldValue else { return }
            // Resolved once, when ownership changes, because the only reader
            // is a `.help()` tooltip on two buttons — evaluated on every pass
            // of the top bar for as long as another track is rendering, and
            // resolving it costs up to two synchronous SQLite reads.
            resolvedRenderingTitle = applyOwnerId.map { ownerId in
                if ownerId == material?.id { return material?.title }
                if let song = library.song(id: ownerId) { return song.title }
                return ((try? partsRepo.part(id: ownerId)) ?? nil)?.name
            } ?? nil
        }
    }

    /// The title behind `renderingTitle`, resolved when `applyOwnerId` is set.
    private var resolvedRenderingTitle: String?

    func noteSnippetIntent(_ intent: SnippetIntent, jobId: String) {
        snippetIntents[jobId] = intent
    }

    func takeSnippetIntent(jobId: String) -> SnippetIntent? {
        snippetIntents.removeValue(forKey: jobId)
    }

    init(library: LibraryStore, partsRepo: PartsRepository, jobs: JobsStore,
         catalog: ModelCatalogStore) {
        self.library = library
        self.partsRepo = partsRepo
        self.jobs = jobs
        self.catalog = catalog
        player.metersEnabled = true
        player.sumsConcurrently = false
    }

    // MARK: derived

    /// The pristine audio the program edits: the backup once one exists, the
    /// live file until then. Everything the Editor plays or renders reads
    /// THIS, never the possibly-already-edited live file.
    var sourceURL: URL? {
        guard let material else { return nil }
        return hasBackup ? material.backupURL : material.fileURL
    }

    /// Whether the pristine copy exists.
    ///
    /// Stored, not a `fileExists` on every read. `sourceURL` and
    /// `sourcePeaksCacheURL` are built on it and both are read from view
    /// bodies — including as a `.task(id:)` key, which a syscall has no
    /// business being — so this used to be a blocking `stat` on the main
    /// thread per pass. It can only change in four places: opening a
    /// material, stashing the backup, applying, and reverting. Each calls
    /// `refreshBackupState()`.
    private(set) var hasBackup = false

    /// Re-read whether the backup is on disk. The one place that syscall
    /// happens.
    func refreshBackupState() {
        let next = material.map {
            FileManager.default.fileExists(atPath: $0.backupURL.path)
        } ?? false
        if next != hasBackup { hasBackup = next }
    }

    var sourceDurationS: Double {
        document.originalDurationS ?? material?.fileDurationS ?? 0
    }

    /// The whole-source peaks cache for the overview strip. The live file's
    /// cache belongs to the live file; an applied track's source is the
    /// backup, which gets its own.
    var sourcePeaksCacheURL: URL? {
        guard let material else { return nil }
        return hasBackup
            ? StoragePaths.libraryWaveforms
                .appendingPathComponent(material.id + ".original.peaks")
            : material.waveformCacheURL
    }

    var timelineDurationS: Double { EditProgram.timelineDuration(segments) }

    var resultDurationS: Double { timelineDurationS / document.speedRate }

    /// Pending work differs from what the file holds.
    var isDirty: Bool {
        guard !document.isEmpty || appliedDocument != nil else { return false }
        return document.ops != (appliedDocument?.ops ?? [])
            || document.enabledEffects != (appliedDocument?.enabledEffects ?? [])
            || abs(document.joinCrossfadeMs
                   - (appliedDocument?.joinCrossfadeMs ?? 8)) > 1e-9
    }

    var mixdownModel: ModelInfo? { MixModels.mixdown(in: catalog.models) }

    /// Whether the visible apply progress belongs to what is on screen.
    var applyBelongsToCurrentMaterial: Bool {
        applyOwnerId == nil || applyOwnerId == material?.id
    }

    /// The stage as it concerns the material on screen. A render started for
    /// another track is still running, but it is not this screen's business
    /// to draw — so everything the view reads goes through here.
    var currentApplyStage: ApplyStage {
        applyBelongsToCurrentMaterial ? applyStage : .idle
    }

    /// A render is in flight for something — possibly a track that is not
    /// open. Only one runs at a time, so this is what gates Apply and Revert
    /// wherever they are offered.
    var isRenderingAnything: Bool { applyStage.isBusy }

    /// What is rendering, for the tooltip that explains a disabled button.
    var renderingTitle: String? {
        guard applyStage.isBusy, applyOwnerId != nil else { return nil }
        return resolvedRenderingTitle
    }

    /// Why this program cannot be rendered, in plain language — nil when it
    /// can. Checked before anything irreversible happens.
    var renderRefusal: String? {
        // The program's own problem first: telling someone to install a
        // model when what they actually did was silence everything is the
        // wrong advice, however true it also is.
        if segments.isEmpty || segments.allSatisfy({ $0.silent }) {
            return "There is nothing left to render — every part of this "
                + "track has been deleted or silenced."
        }
        if mixdownModel == nil {
            return "The Mixdown & Align (DSP) model is not installed — it "
                + "renders edits."
        }
        return nil
    }

    /// The seams the render will actually have. A split leaves a segment
    /// edge but no seam, so the markers read this rather than counting
    /// segment boundaries.
    /// Stored, not computed: `EditMixPlan.joinTimes` is O(segments²) — it
    /// calls `hasGap(before:in:)` inside its own loop — and three view bodies
    /// read it on every pass, including through a selection drag. It is a
    /// function of `segments` alone, so `rebuild()` is the honest place for
    /// it.
    private(set) var joinTimes: [Double] = []

    /// The head and tail fades as they will really render — clamped to the
    /// run that carries them, because the engine's ramps cannot span two
    /// tracks. The well draws these, not the numbers that were asked for.
    /// Stored for the reason `joinTimes` is, and one worse: computing it ran
    /// `EditProgram.segments` again from the top, replaying every op to
    /// re-derive the list `segments` was already holding.
    ///
    /// A named `Equatable` pair rather than a tuple — a tuple cannot conform,
    /// so a view taking one can never be proven unchanged and redraws on
    /// every pass of its parent.
    struct Fades: Equatable {
        var headS: Double = 0
        var tailS: Double = 0
    }

    private(set) var effectiveFades = Fades()

    /// Where the head and tail fades actually land: the first and last
    /// AUDIBLE moment. Leading or trailing silence is not faded — the engine
    /// attaches the ramps to the tracks, and a gap produces no track.
    var fadeAnchors: (headS: Double, tailS: Double) {
        var cursor = 0.0
        var head: Double?
        var tail = 0.0
        for segment in segments {
            let start = cursor
            cursor += segment.length
            guard !segment.silent else { continue }
            if head == nil { head = start }
            tail = cursor
        }
        return (head ?? 0, tail)
    }

    /// Beats within the selection, for the "20 BARS" style readouts.
    func barsInSelection() -> Int? {
        guard let selection else { return nil }
        let covered = grid.beats.filter {
            $0 >= selection.start && $0 <= selection.end
        }
        return covered.isEmpty ? nil : covered.count
    }

    func barNumber(at timelineS: Double) -> Int? {
        grid.barTicks.last { $0.timelineS <= timelineS + 1e-9 }?.number
    }

    // MARK: loading

    func open(songId: String) {
        guard let song = library.song(id: songId) else { return }
        flushPersist()
        stopPreview()
        material = Material(
            id: song.id, ownerType: "song", title: song.title,
            songTitle: nil, stemKind: nil,
            promptLine: song.prompt.isEmpty ? nil : song.prompt,
            fileURL: song.fileURL, backupURL: song.backupURL,
            fileName: song.fileName, waveformCacheURL: song.waveformURL,
            sampleRate: song.sampleRate, fileDurationS: song.durationS,
            origin: song.originKind)
        loadDocument(json: song.editsJSON)
        loadAnalysis(ownerId: song.id, parentSongId: nil)
        finishOpen()
    }

    /// What the editor can open, as the material picker's filter.
    ///
    /// Kept beside `open(partId:)` because it has to stay in step with it:
    /// that method turns away anything whose format is not `wav`, so a notes
    /// part offered here would be picked and then silently ignored — a row
    /// that does nothing is worse than a row that was never shown. Audio
    /// kinds only, and songs are always their full mix.
    static let pickerAccepts = [KindPattern(pattern: "song.mix"),
                                KindPattern(pattern: "stem.*"),
                                KindPattern(pattern: "layer.*")]

    /// Open whatever the material picker handed back.
    ///
    /// `PickedMaterial` already carries the kind, so this costs no lookup —
    /// unlike routing by bare id, which has to ask the parts table whether the
    /// id is a part before it can tell the two apart.
    func open(_ picked: PickedMaterial) {
        if picked.kind == "song.mix" {
            open(songId: picked.id)
        } else {
            open(partId: picked.id)
        }
    }

    func open(partId: String) {
        guard let part = ((try? partsRepo.part(id: partId)) ?? nil),
              part.format == "wav" else { return }
        flushPersist()
        stopPreview()
        let song = library.song(id: part.songId)
        material = Material(
            id: part.id, ownerType: "part", title: part.name,
            songTitle: song?.title, stemKind: part.kind,
            promptLine: nil,
            fileURL: part.fileURL, backupURL: part.backupURL,
            fileName: part.fileName, waveformCacheURL: part.waveformURL,
            sampleRate: part.sampleRate ?? 44100,
            fileDurationS: part.durationS ?? 0, origin: nil)
        loadDocument(json: part.editsJSON)
        // Parts carry the parent song's grid when they were never analysed
        // on their own.
        loadAnalysis(ownerId: part.id, parentSongId: part.songId)
        finishOpen()
    }

    func close() {
        flushPersist()
        stopPreview()
        material = nil
        document = EditDocument()
        appliedDocument = nil
        segments = []
        grid = EditorGrid()
        analysis = nil
        selection = nil
        cursorS = 0
        // The clipboard deliberately survives, exactly as it does when you
        // switch tracks: `canPaste` refuses a slice from another recording,
        // and keeping it is what lets the menu say WHY rather than greying out
        // in silence. Closing a track is not a reason to forget what you cut.
        // An apply in flight belongs to the material it was started for, not
        // to the screen: leaving the Editor must not make it look finished.
        if applyOwnerId == nil { applyStage = .idle }
        exportStage = .idle
        reversedSourceURL = nil
        uploadedSourceId = nil
        interactionKey = nil
        undoManager?.removeAllActions()
    }

    private func loadDocument(json: String?) {
        if let json, let decoded = try? JSONDecoder().decode(
            EditDocument.self, from: Data(json.utf8)) {
            document = decoded
            appliedDocument = decoded.appliedAt != nil ? decoded : nil
        } else {
            document = EditDocument()
            appliedDocument = nil
        }
    }

    /// Fetch the beat grid and key for the material being opened.
    ///
    /// Off the opening turn: the payload carries the beats, downbeats and
    /// sections, which on a long analysed track is thousands of doubles to
    /// decode, on top of up to two synchronous reads. Nothing on the first
    /// frame needs it — the waveform and the edit list draw without a grid —
    /// so the track appears immediately and the grid arrives with the
    /// `rebuild` below, which is the same path a late analysis already took.
    ///
    /// Guarded on the material still being the one that asked: switching
    /// tracks quickly must not stamp the first track's grid onto the second.
    private func loadAnalysis(ownerId: String, parentSongId: String?) {
        bpm = nil
        camelot = nil
        analysis = nil
        analysisLoad?.cancel()
        analysisLoad = Task { [weak self, partsRepo] in
            let loaded = await Task.detached(priority: .userInitiated) {
                () -> (bpm: Double?, camelot: String?, payload: AnalysisPayload?)? in
                var record = (try? partsRepo.analysis(ownerId: ownerId)) ?? nil
                if record == nil, let parentSongId {
                    record = (try? partsRepo.analysis(ownerId: parentSongId)) ?? nil
                }
                guard let record else { return nil }
                return (record.bpm, record.camelot,
                        try? BackendClient.decoder.decode(
                            AnalysisPayload.self,
                            from: Data(record.analysisJSON.utf8)))
            }.value
            guard let self, !Task.isCancelled,
                  self.material?.id == ownerId else { return }
            self.bpm = loaded?.bpm
            self.camelot = loaded?.camelot
            self.analysis = loaded?.payload
            self.rebuild()
        }
    }

    /// The analysis fetch in flight, so opening another track cancels it.
    private var analysisLoad: Task<Void, Never>?

    private func finishOpen() {
        selection = nil
        cursorS = 0
        visibleStartS = 0
        pxPerSecond = 0
        // A render started for another track keeps its stage — it is still
        // running, and clearing it here made the progress card describe
        // whatever was opened next.
        if applyOwnerId == nil { applyStage = .idle }
        exportStage = .idle
        reversedSourceURL = nil
        reversedSourceBuilding = false
        uploadedSourceId = nil
        interactionKey = nil
        undoManager?.removeAllActions()
        rebuild()
    }

    /// What a join will actually be lapped by, in milliseconds. Off does
    /// not mean zero: the engine de-clicks every trim either way, and two of
    /// those ramps in disjoint windows is a hole — so the plan keeps them
    /// overlapping at the minimum. The readouts say this number rather than
    /// the one the chip was set to.
    var joinCrossfadeMsEffective: Double {
        max(document.joinCrossfadeMs, EditMixPlan.engineEdgeFadeS * 2 * 1000)
    }

    /// The Tier 2.6 chip: on = a few ms of overlap at every discontinuous
    /// join, off = the shortest join that does not click.
    func setCrossfadeJoins(_ on: Bool) {
        guard on != crossfadeJoins else { return }
        perform(on ? "Crossfade Joins" : "Butt Joins") { doc in
            doc.joinCrossfadeMs = on ? 8 : 0
        }
    }

    private func rebuild() {
        let nextSegments = EditProgram.segments(sourceDuration: sourceDurationS,
                                                ops: document.ops)
        // Gated. Observation publishes on every *set*, not on every change, so
        // reassigning these republished the whole segment list and the entire
        // beat grid on each frame of an Amplify drag — and `segments` is what
        // the well and the overview strip re-slice their waveforms from.
        let boundariesMoved = !Self.sameBoundaries(nextSegments, segments)
        if nextSegments != segments { segments = nextSegments }
        // The grid is a function of the analysis and where the segment edges
        // fall. A gain move changes neither, so it cannot change the grid.
        if boundariesMoved || grid.isEmpty {
            let nextGrid = EditorGrid.make(analysis: analysis, segments: segments)
            if nextGrid != grid { grid = nextGrid }
        }
        let duration = timelineDurationS
        cursorS = cursorS.clamped(to: 0...max(0, duration))
        if let current = selection {
            if current.start >= duration {
                selection = nil
            } else {
                selection = EditRange(start: current.start,
                                      end: min(current.end, duration))
            }
        }
        refreshDerivedFromSegments()
        if document.ops.contains(where: { op in
            if case .reverse = op.kind { return true }
            return false
        }) {
            ensureReversedSource()
        }
    }

    /// Everything that follows from `segments` (and, for the amplify readout,
    /// the selection). One place, called wherever either moves.
    private func refreshDerivedFromSegments() {
        let joins = EditMixPlan.joinTimes(segments: segments)
        if joins != joinTimes { joinTimes = joins }
        let fades = EditMixPlan.effectiveFades(document: document,
                                               segments: segments)
        let nextFades = Fades(headS: fades.headS, tailS: fades.tailS)
        if nextFades != effectiveFades { effectiveFades = nextFades }
        let amplify = computeAmplifyDbForSelection()
        if amplify != amplifyDbForSelection { amplifyDbForSelection = amplify }
    }

    /// Do these two segment lists cut the source in the same places?
    ///
    /// Compared on the edges alone, because that is all the beat grid reads —
    /// a segment whose gain moved is the same cut.
    private static func sameBoundaries(_ lhs: [EditSegment],
                                       _ rhs: [EditSegment]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (a, b) in zip(lhs, rhs) {
            if a.sourceStart != b.sourceStart || a.sourceEnd != b.sourceEnd
                || a.silent != b.silent || a.reversed != b.reversed {
                return false
            }
        }
        return true
    }

    // MARK: mutation + undo

    /// Every document change goes through here: snapshot, mutate, rebuild,
    /// persist — and the snapshot registered so ⌘Z swaps it straight back
    /// (the timeline's pattern; the model is value types, so undo is a swap).
    ///
    /// `coalescing` names a continuous gesture. A slider drag calls this
    /// dozens of times; only the first registers an undo, so ⌘Z steps back
    /// over the whole drag rather than one step per pixel. Deliberately NOT
    /// `UndoManager.beginUndoGrouping` — with `groupsByEvent` on (the
    /// default) a manual group nests inside the per-event one, and the
    /// unbalanced level makes the next undo raise "too many nested undo
    /// groups" and terminate the app.
    func perform(_ name: String, coalescing key: String? = nil,
                 _ change: (inout EditDocument) -> Void) {
        let before = document
        let selectionBefore = selection
        var updated = document
        change(&updated)
        guard updated != document else { return }
        updated.appliedAt = nil
        document = updated
        if key == nil || key != interactionKey {
            registerUndo(name, before: before, selectionBefore: selectionBefore)
        }
        interactionKey = key
        actionNote = nil
        rebuild()
        schedulePersist()
        refreshPreviewAfterEdit()
    }

    /// A continuous gesture ended: the next change starts a fresh undo step
    /// even if it carries the same key, and any structural re-arm the drag
    /// deferred happens now.
    func endInteraction() {
        interactionKey = nil
        if previewRearmTask != nil { rearmPreview() }
    }

    private func registerUndo(_ name: String, before: EditDocument,
                              selectionBefore: EditRange?) {
        undoStepsRegistered += 1
        undoManager?.registerUndo(withTarget: self) { target in
            let after = target.document
            let selectionAfter = target.selection
            target.document = before
            target.selection = selectionBefore
            target.interactionKey = nil
            target.rebuild()
            target.schedulePersist()
            target.refreshPreviewAfterEdit()
            target.registerUndo(name, before: after,
                                selectionBefore: selectionAfter)
        }
        undoManager?.setActionName(name)
    }

    /// Store the program soon, not now. `LibraryStore.update` re-queries the
    /// whole library and re-indexes the row through the FTS triggers, and a
    /// slider drag calls `perform` dozens of times — so the write trails the
    /// gesture by a beat and is flushed on the way out (`close`, `applyEdits`,
    /// leaving the screen).
    func schedulePersist() {
        persistTask?.cancel()
        hasPendingWrite = true
        persistTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.persistPending()
        }
    }

    /// Write anything still pending right now. A no-op when nothing is —
    /// "flush" must not mean "write the in-memory document back", or a path
    /// that has just cleared the row (revert) would have it restored by the
    /// next flush.
    func flushPersist() {
        guard hasPendingWrite else { return }
        persistTask?.cancel()
        persistTask = nil
        persistPending()
    }

    /// Drop a scheduled write without performing it — for callers that have
    /// already written the truth themselves.
    func discardPendingWrite() {
        persistTask?.cancel()
        persistTask = nil
        hasPendingWrite = false
    }

    /// The pending program is stored as it changes, so "Continue editing"
    /// survives a relaunch — `editedAt` (the applied mark) is not touched.
    func persistPending() {
        hasPendingWrite = false
        guard let material else { return }
        let json = (try? JSONEncoder().encode(document))
            .map { String(decoding: $0, as: UTF8.self) }
        // A narrow column write: the pending program changes as fast as a
        // slider moves, and a whole-row update would re-index the track and
        // re-query the library on every step. `editedAt` is carried through
        // unchanged — this is the pending program, not an applied one.
        if material.isPart {
            let part = (try? partsRepo.part(id: material.id)) ?? nil
            try? partsRepo.setEdits(id: material.id, editsJSON: json,
                                    editedAt: part?.editedAt,
                                    backupFileName: part?.backupFileName)
            partsStore?.noteEdits(id: material.id, editsJSON: json)
        } else {
            let song = library.song(id: material.id)
            try? repo.setEdits(id: material.id, editsJSON: json,
                               editedAt: song?.editedAt,
                               backupFileName: song?.backupFileName)
            // The cached rows every OTHER writer builds its whole-row update
            // from must learn about this, or the next rating or heart write
            // sends the pre-edit editsJSON back over the program.
            library.noteEdits(id: material.id, editsJSON: json)
        }
    }

    // MARK: edit actions

    func trimToSelection() {
        guard let selection else { return }
        perform("Trim") { $0.ops.append(EditOp(kind: .trim(selection))) }
        self.selection = nil
        cursorS = 0
    }

    func deleteSelection() {
        guard let selection else { return }
        perform("Delete") { $0.ops.append(EditOp(kind: .delete(selection))) }
        self.selection = nil
        cursorS = selection.start.clamped(to: 0...max(0, timelineDurationS))
    }

    func silenceSelection() {
        guard let selection else { return }
        perform("Silence") { $0.ops.append(EditOp(kind: .silence(selection))) }
    }

    func insertGap(seconds: Double = 2) {
        let at = cursorS
        perform("Insert Gap") {
            $0.ops.append(EditOp(kind: .insertGap(at: at, seconds: seconds)))
        }
    }

    func splitAtCursor() {
        let at = cursorS
        perform("Split") { $0.ops.append(EditOp(kind: .splitAt(at))) }
    }

    func reverseSelection() {
        guard let selection else { return }
        perform("Reverse") { $0.ops.append(EditOp(kind: .reverse(selection))) }
        ensureReversedSource()
    }

    func copySelection() {
        guard let selection else { return }
        clipboard = EditProgram.extract(segments, range: selection)
        clipboardSourceId = material?.id
        clipboardSourceTitle = material?.title
    }

    /// Whether the clipboard belongs to what is open. See
    /// `clipboardSourceId` for why it is not simply cleared.
    var canPaste: Bool {
        !clipboard.isEmpty && clipboardSourceId == material?.id
    }

    func cutSelection() {
        guard selection != nil else { return }
        copySelection()
        deleteSelection()
    }

    func paste() {
        guard canPaste else { return }
        let at = cursorS
        let slices = clipboard
        perform("Paste") {
            $0.ops.append(EditOp(kind: .paste(at: at, slices: slices)))
        }
    }

    func selectAll() {
        selection = EditRange(start: 0, end: timelineDurationS)
    }

    /// Double-click: the region between the nearest boundaries — which is the
    /// whole track until a split or cut has created any.
    func selectRegion(at t: Double) {
        let edges = EditProgram.boundaries(segments)
        let start = edges.last { $0 <= t } ?? 0
        let end = edges.first { $0 > t } ?? timelineDurationS
        selection = EditRange(start: start, end: end)
    }

    /// Grow the selection to the analysed section under the cursor (or under
    /// the selection's midpoint) — "delete the second chorus" in two clicks.
    func snapSelectionToSection() {
        let probe = selection.map { ($0.start + $0.end) / 2 } ?? cursorS
        guard let section = grid.sections.first(where: {
            probe >= $0.startS && probe <= $0.endS
        }) else { return }
        selection = EditRange(start: section.startS, end: section.endS)
    }

    // MARK: whole-track rows (replace-in-place: pressing Fade in with one
    // already there edits the row rather than stacking a second)

    func setFadeIn(seconds: Double, curve: FadeCurve) {
        replaceWholeTrack("Fade In", matches: { kind in
            if case .fadeIn = kind { return true }
            return false
        }, with: seconds > 0 ? .fadeIn(seconds: seconds, curve: curve) : nil)
    }

    func setFadeOut(seconds: Double, curve: FadeCurve) {
        replaceWholeTrack("Fade Out", matches: { kind in
            if case .fadeOut = kind { return true }
            return false
        }, with: seconds > 0 ? .fadeOut(seconds: seconds, curve: curve) : nil)
    }

    func setNormalize(lufs: Double?) {
        let selection = selection
        replaceWholeTrack("Normalise", matches: { kind in
            if case .normalize = kind { return true }
            return false
        }, with: lufs.map { .normalize(lufs: $0) },
           coalescing: "normalize", then: { doc in
            // The other half of the radio pair — see `setAmplify`. Only the
            // current selection's amplify goes: a level set on some other
            // region is not what this control is about.
            guard lufs != nil, let selection else { return }
            doc.ops.removeAll { op in
                if case .amplify(let range, _) = op.kind {
                    return range == selection
                }
                return false
            }
        })
    }

    func setSpeed(rate: Double) {
        replaceWholeTrack("Speed", matches: { kind in
            if case .speed = kind { return true }
            return false
        }, with: abs(rate - 1) > 1e-6 ? .speed(rate: rate) : nil,
           coalescing: "speed")
    }

    func setPitch(semitones: Double) {
        replaceWholeTrack("Pitch", matches: { kind in
            if case .pitch = kind { return true }
            return false
        }, with: abs(semitones) > 1e-6 ? .pitch(semitones: semitones) : nil,
           coalescing: "pitch")
    }

    func setResample(hz: Int?) {
        replaceWholeTrack("Resample", matches: { kind in
            if case .resample = kind { return true }
            return false
        }, with: hz.map { .resample(hz: $0) })
    }

    /// The default fade the toolbar buttons make: sized by the selection when
    /// one reaches the track's edge, a musical guess otherwise.
    func addFadeInFromContext() {
        let seconds: Double
        if let selection, selection.start < 0.5 {
            seconds = selection.end
        } else {
            seconds = min(1.5, timelineDurationS / 2)
        }
        setFadeIn(seconds: seconds, curve: document.fadeIn?.curve ?? .linear)
    }

    func addFadeOutFromContext() {
        let duration = timelineDurationS
        let seconds: Double
        if let selection, selection.end > duration - 0.5 {
            seconds = duration - selection.start
        } else {
            seconds = min(6, duration / 2)
        }
        setFadeOut(seconds: seconds, curve: document.fadeOut?.curve ?? .linear)
    }

    /// Amplify the current selection, updating the row that already targets
    /// this exact range rather than stacking a second one.
    ///
    /// Matched by range, not by "is it the last op": `EditProgram` SUMS
    /// overlapping amplifies, so appending a second +6 dB over the same
    /// region silently renders +12 while the slider still reads +6. Any
    /// whole-track row appended in between — a fade, normalise, speed —
    /// used to be enough to trigger that.
    func setAmplify(db: Double) {
        guard let selection else { return }
        let existing = amplifyIndex(for: selection)
        // Whether this region is already at some level — possibly set by a
        // row covering a different range, which is why the flat case cannot
        // just delete a row and hope.
        let current = amplifyDbForSelection
        perform("Amplify", coalescing: "amplify") { doc in
            if let existing {
                if abs(db) < 0.05 {
                    doc.ops.remove(at: existing)
                } else {
                    doc.ops[existing].kind = .amplify(selection, db: db)
                }
            } else if abs(db) >= 0.05 || abs(current) >= 0.05 {
                // Dialling back to 0 over a region an earlier, wider row
                // raised is still an edit: it says "this part, flat".
                doc.ops.append(EditOp(kind: .amplify(selection, db: db)))
            }
            // Levelling is one decision, which is why the design draws these
            // two as a radio pair: normalising the whole track re-levels
            // everything the amplify just set. Taking one drops the other,
            // and ⌘Z brings it back.
            if abs(db) >= 0.05 {
                doc.ops.removeAll { op in
                    if case .normalize = op.kind { return true }
                    return false
                }
            }
        }
    }

    /// What this selection is already amplified by, for the slider — read
    /// from the SEGMENTS, which is where the truth is. Reading it off an op
    /// meant hunting for a row whose stored numbers still matched a ruler
    /// that later cuts had moved underneath it.
    ///
    /// Zero when the selection spans regions at different levels: there is
    /// no single number to show, and showing one of them would misreport the
    /// rest.
    /// Stored: the Adjust tab reads this three times per pass — the radio
    /// indicator, the readout and the slider's getter — and each read
    /// allocated a fresh slice of the whole segment list. It is a function of
    /// `segments` and `selection`, and both funnel through `rebuild()` and
    /// `setSelection`.
    private(set) var amplifyDbForSelection: Double = 0

    private func computeAmplifyDbForSelection() -> Double {
        guard let selection else { return 0 }
        let covered = EditProgram.extract(segments, range: selection)
            .filter { !$0.silent }
        guard let first = covered.first,
              covered.allSatisfy({ abs($0.gainDb - first.gainDb) < 1e-9 })
        else { return 0 }
        return first.gainDb
    }

    private func amplifyIndex(for selection: EditRange) -> Int? {
        document.ops.lastIndex { op in
            if case .amplify(let range, _) = op.kind { return range == selection }
            return false
        }
    }

    private func replaceWholeTrack(_ name: String,
                                   matches: (EditOp.Kind) -> Bool,
                                   with kind: EditOp.Kind?,
                                   coalescing key: String? = nil,
                                   then: ((inout EditDocument) -> Void)? = nil) {
        let existingIndex = document.ops.lastIndex { matches($0.kind) }
        perform(name, coalescing: key) { doc in
            if let existingIndex {
                if let kind {
                    doc.ops[existingIndex].kind = kind
                } else {
                    doc.ops.remove(at: existingIndex)
                }
            } else if let kind {
                doc.ops.append(EditOp(kind: kind))
            }
            then?(&doc)
        }
    }

    // MARK: edit list rows

    func removeOp(id: UUID) {
        perform("Remove Edit") { $0.ops.removeAll { $0.id == id } }
    }

    /// `coalescing` is passed by the edit-list sliders: a drag on a row's
    /// Length or Gain is one edit to undo, not one per frame.
    func updateOp(id: UUID, kind: EditOp.Kind, coalescing key: String? = nil) {
        perform("Edit Step", coalescing: key) { doc in
            if let index = doc.ops.firstIndex(where: { $0.id == id }) {
                doc.ops[index].kind = kind
            }
        }
    }

    func clearAllOps() {
        perform("Clear Edits") { $0.ops.removeAll() }
    }

    // MARK: effects chain

    func addEffect(_ kind: EffectSetting.Kind) {
        perform("Add \(kind.label)") { $0.effects.append(.fresh(kind)) }
    }

    func updateEffect(_ effect: EffectSetting, coalescing key: String? = nil) {
        perform("Adjust \(effect.kind.label)", coalescing: key) { doc in
            if let index = doc.effects.firstIndex(where: { $0.id == effect.id }) {
                doc.effects[index] = effect
            }
        }
    }

    func removeEffect(id: UUID) {
        perform("Remove Effect") { $0.effects.removeAll { $0.id == id } }
    }

    func moveEffect(id: UUID, up: Bool) {
        perform("Reorder Chain") { doc in
            guard let index = doc.effects.firstIndex(where: { $0.id == id })
            else { return }
            let target = up ? index - 1 : index + 1
            guard doc.effects.indices.contains(target) else { return }
            doc.effects.swapAt(index, target)
        }
    }

    func setAllEffectsEnabled(_ enabled: Bool) {
        perform(enabled ? "Enable Chain" : "Bypass Chain") { doc in
            for index in doc.effects.indices {
                doc.effects[index].enabled = enabled
            }
        }
    }

    // MARK: auto-trim (Tier 3.4)

    /// Head/tail silence of the *source*, mapped through the program; the
    /// menu shows what would go before it goes.
    func detectEdgeSilence(thresholdDb: Double = -48) async -> EditRange? {
        guard let sourceURL else { return nil }
        let peaks = try? await WaveformExtractor.shared.peaks(
            for: sourceURL, startS: 0, endS: sourceDurationS,
            binCount: 2000, mono: true)
        guard let lane = peaks?.first, !lane.maxs.isEmpty else { return nil }
        let threshold = Float(pow(10.0, thresholdDb / 20))
        let binSeconds = sourceDurationS / Double(lane.maxs.count)
        var head = 0
        while head < lane.maxs.count,
              max(abs(lane.maxs[head]), abs(lane.mins[head])) < threshold {
            head += 1
        }
        var tail = lane.maxs.count - 1
        while tail > head,
              max(abs(lane.maxs[tail]), abs(lane.mins[tail])) < threshold {
            tail -= 1
        }
        guard head > 0 || tail < lane.maxs.count - 1 else { return nil }
        let startSource = Double(head) * binSeconds
        let endSource = Double(tail + 1) * binSeconds
        guard let start = EditProgram.sourceToTimeline(startSource,
                                                       in: segments),
              let end = EditProgram.sourceToTimeline(endSource, in: segments),
              end - start > 0.05 else { return nil }
        return EditRange(start: start, end: end)
    }

    /// The thresholds the menu offers. A single hard-coded one is wrong for
    /// real material at both ends: a quiet ambient intro sits above −48 dB
    /// and never gets trimmed, a noisy take sits below it and loses its
    /// first beat.
    static let autoTrimThresholdsDb: [Double] = [-36, -42, -48, -54, -60]

    func autoTrimSilence(thresholdDb: Double = -48) async {
        guard let keep = await detectEdgeSilence(thresholdDb: thresholdDb)
        else {
            // Doing nothing silently is what makes a menu item feel broken.
            note(String(format: "Nothing to trim — neither end is below "
                        + "%.0f dB.", thresholdDb))
            return
        }
        let trimmed = timelineDurationS - keep.length
        perform("Auto-trim Silence") {
            $0.ops.append(EditOp(kind: .trim(keep)))
        }
        note(String(format: "Trimmed %.2f s of silence at %.0f dB.",
                    trimmed, thresholdDb))
    }

    /// Show a one-line result, and take it away again.
    private func note(_ text: String) {
        actionNote = text
        noteTask?.cancel()
        noteTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            if self?.actionNote == text { self?.actionNote = nil }
        }
    }

    // MARK: zero crossings (Tier 3.5)

    /// Nudge both selection edges to the nearest zero crossing of the source
    /// — called after a drag ends when the snap control says Zero-x.
    func refineSelectionToZeroCrossings() async {
        guard snapMode == .zeroX, let current = selection else { return }
        let start = await nearestZeroCrossing(toTimeline: current.start)
        let end = await nearestZeroCrossing(toTimeline: current.end)
        guard selection == current else { return }   // moved on meanwhile
        selection = EditRange(start: start ?? current.start,
                              end: end ?? current.end)
    }

    private func nearestZeroCrossing(toTimeline t: Double) async -> Double? {
        guard let sourceURL,
              let s = EditProgram.timelineToSource(t, in: segments)
        else { return nil }
        let windowS = 0.05
        let peaks = try? await WaveformExtractor.shared.peaks(
            for: sourceURL, startS: max(0, s - windowS), endS: s + windowS,
            binCount: 4000, mono: true)
        guard let lane = peaks?.first, !lane.maxs.isEmpty else { return nil }
        // A bin whose min/max straddle zero contains a crossing; find the
        // nearest to the middle of the window.
        let center = lane.maxs.count / 2
        var samples = [Float](repeating: 0, count: lane.maxs.count)
        for i in samples.indices {
            samples[i] = abs(lane.maxs[i]) >= abs(lane.mins[i])
                ? lane.maxs[i] : lane.mins[i]
        }
        guard let index = ZeroCross.nearest(in: samples, around: center)
        else { return nil }
        let offset = (Double(index) - Double(center)) / Double(lane.maxs.count)
            * windowS * 2
        return t + offset
    }

    // MARK: preview

    /// Exact cuts, real gains; fades, normalise, stretch and effects are
    /// drawn, not heard — the design's honesty banner states it.
    func previewItems() -> [MultiPartPlayer.Item] {
        guard let sourceURL else { return [] }
        var items: [MultiPartPlayer.Item] = []
        var cursor = 0.0
        for (index, segment) in segments.enumerated() {
            defer { cursor += segment.length }
            guard !segment.silent else { continue }
            if segment.reversed, let reversedSourceURL {
                let duration = sourceDurationS
                items.append(MultiPartPlayer.Item(
                    id: "seg-\(index)", url: reversedSourceURL,
                    offsetS: cursor, gainDb: segment.gainDb, muted: false,
                    sourceStartS: duration - segment.sourceEnd,
                    sourceEndS: duration - segment.sourceStart))
            } else {
                items.append(MultiPartPlayer.Item(
                    id: "seg-\(index)", url: sourceURL,
                    offsetS: cursor, gainDb: segment.gainDb, muted: false,
                    sourceStartS: segment.sourceStart,
                    sourceEndS: segment.sourceEnd))
            }
        }
        return items
    }

    var playheadS: Double {
        if scrubbing { return cursorS }
        return player.state == .stopped ? cursorS : player.currentPosition()
    }

    // MARK: zoom

    /// The zoom rail's four verbs, on the store rather than in the view.
    ///
    /// They were the waveform view's private methods until the View menu
    /// needed them: a menu command cannot reach into a view, and copying the
    /// anchoring arithmetic into a second place would have been the surest way
    /// to make ⌘+ and the rail's `+` disagree about where they zoom to. The
    /// rail calls these now, so there is one implementation.
    ///
    /// All four are no-ops before the well has been laid out (`wellWidth` 0),
    /// which is the state a freshly opened Editor is in for one frame.
    func zoomIn() { scaleZoom(by: 1.33) }
    func zoomOut() { scaleZoom(by: 0.75) }

    /// Back to the whole file in view. `0` is the store's "not yet zoomed"
    /// sentinel, which the view resolves to `fitZoom` on the next layout.
    func zoomToFit() {
        pxPerSecond = 0
        visibleStartS = 0
    }

    /// Fill the well with the selection.
    ///
    /// Nothing to do without one, and nothing to do for a zero-length one — a
    /// selection collapsed to a point has no width to divide by. Nothing to do
    /// either when an end does not map into the timeline at all:
    /// `sourceToTimeline` answers nil for a source position that lands in a
    /// deleted or silenced stretch, and there is no honest window to show for
    /// a selection whose edge is not on screen anywhere.
    func zoomToSelection() {
        guard let selection, selection.length > 0, wellWidth > 0,
              let start = EditProgram.sourceToTimeline(selection.start,
                                                       in: segments),
              let end = EditProgram.sourceToTimeline(selection.end,
                                                     in: segments)
        else { return }
        let span = max(0.001, end - start)
        pxPerSecond = EditorGeometry.clampZoom(wellWidth / CGFloat(span),
                                               durationS: timelineDurationS,
                                               width: wellWidth)
        let visible = Double(wellWidth / pxPerSecond)
        visibleStartS = (start + span / 2 - visible / 2)
            .clamped(to: 0...max(0, timelineDurationS - visible))
    }

    func scaleZoom(by factor: CGFloat) {
        let zoom = pxPerSecond > 0
            ? pxPerSecond
            : EditorGeometry.fitZoom(durationS: timelineDurationS,
                                     width: max(1, wellWidth))
        setZoomKeepingCenter(zoom * factor)
    }

    /// Anchor on the playhead when it is visible, the window centre otherwise
    /// — zooming away from what you are listening to is the one thing a zoom
    /// control must not do.
    func setZoomKeepingCenter(_ zoom: CGFloat) {
        let duration = timelineDurationS
        let width = max(1, wellWidth)
        let visible = pxPerSecond > 0 ? Double(width / pxPerSecond) : duration
        let anchor = (playheadS >= visibleStartS
                      && playheadS <= visibleStartS + visible)
            ? playheadS : visibleStartS + visible / 2
        pxPerSecond = EditorGeometry.clampZoom(zoom, durationS: duration,
                                               width: width)
        let newVisible = Double(width / pxPerSecond)
        visibleStartS = (anchor - newVisible / 2)
            .clamped(to: 0...max(0, duration - newVisible))
    }

    var isPlaying: Bool { player.isPlaying }

    /// The listener's level, handed to the preview graph.
    ///
    /// The Editor has its own player, so the app's volume has to be told to it
    /// as well as to the transport — otherwise turning the app down would go
    /// quiet everywhere except the screen you are actually listening on.
    /// `ShellActions` writes both from one number; nothing here remembers it.
    func setPreviewVolume(_ level: Double) {
        player.outputScale = level
    }

    /// True while the preview is playing, or paused part-way through — i.e.
    /// while the Editor is the thing the system transport should be about. A
    /// track that is merely loaded has not "played", and must not take the Now
    /// Playing tile off a song that has.
    var previewEngaged: Bool { player.state != .stopped }

    func togglePlayback() {
        switch player.state {
        case .playing:
            player.pause()
            cursorS = player.currentPosition()
            stopLoopWatcher()
        case .paused:
            pauseGlobalPlayback()
            if previewStale {
                resumeFromStaleEdit()
            } else {
                player.resume()
            }
            startLoopWatcher()
        case .stopped:
            playPreview(from: cursorS)
        }
    }

    func playPreview(from position: Double) {
        guard material != nil else { return }
        pauseGlobalPlayback()
        stopAtS = nil
        previewStale = false
        player.play(items: previewItems(), from: position)
        startLoopWatcher()
    }

    func playSelection() {
        guard let selection else { return }
        pauseGlobalPlayback()
        previewStale = false
        stopAtS = loopSelection ? nil : selection.end
        player.play(items: previewItems(), from: selection.start)
        startLoopWatcher()
    }

    func stopPreview() {
        stopLoopWatcher()
        stopAtS = nil
        auditioningOriginal = false
        previewStale = false
        player.stop()
    }

    /// A/B against the untouched source, holding the musical position: the
    /// same moment keeps playing, from whichever version is switched in.
    func toggleOriginalAudition() {
        guard let sourceURL, material != nil else { return }
        pauseGlobalPlayback()
        // Both arms re-arm from scratch, so nothing is left stale either way.
        previewStale = false
        if auditioningOriginal {
            let sourcePosition = player.currentPosition()
            let editPosition = EditProgram.sourceToTimeline(
                sourcePosition, in: segments) ?? 0
            auditioningOriginal = false
            player.play(items: previewItems(), from: editPosition)
        } else {
            let editPosition = player.state == .stopped
                ? cursorS : player.currentPosition()
            let sourcePosition = EditProgram.timelineToSource(
                editPosition, in: segments) ?? 0
            auditioningOriginal = true
            stopAtS = nil
            player.play(items: [MultiPartPlayer.Item(
                id: "original", url: sourceURL, offsetS: 0, gainDb: 0,
                muted: false)], from: sourcePosition)
        }
        startLoopWatcher()
    }

    func pausePreview() {
        guard player.state == .playing else { return }
        player.pause()
        cursorS = player.currentPosition()
        // Paused is not stopped, so nothing used to retire this — the watcher
        // went on waking thirty-three times a second, for the rest of the
        // session, to find the player paused and return. Every path that
        // resumes calls `startLoopWatcher` again.
        stopLoopWatcher()
    }

    private func stopLoopWatcher() {
        loopWatcher?.invalidate()
        loopWatcher = nil
    }

    func seekPreview(to t: Double) {
        cursorS = t.clamped(to: 0...max(0, timelineDurationS))
        // Mid-gesture the position moves but the graph does not: see
        // `beginScrub`.
        guard !scrubbing, player.state != .stopped else { return }
        player.seek(to: cursorS)
    }

    /// A scrub gesture started.
    ///
    /// `player.seek` is not cheap: it disarms every node and re-arms them
    /// against a fresh anchor placed ~120 ms in the future, so a drag that
    /// calls it per mouse-move schedules audio sixty times a second and
    /// throws each schedule away ~16 ms later. The result is a drag that
    /// holds the main thread and plays nothing.
    ///
    /// So a gesture moves `cursorS` alone and the seek happens once, at the
    /// end — the same shape the selection drags already use. `playheadS`
    /// follows the cursor while this is set, so the thumb still tracks the
    /// pointer even though the player has not moved yet.
    func beginScrub() { scrubbing = true }

    /// The gesture ended: put the player where the pointer left off. A tap on
    /// the ruler runs both halves in one turn, so it still seeks at once.
    func endScrub() {
        guard scrubbing else { return }
        scrubbing = false
        guard player.state != .stopped else { return }
        player.seek(to: cursorS)
    }

    /// Loop and play-selection bounds — checked beside the position tick.
    ///
    /// Installed in `.common` rather than through `Timer.scheduledTimer`,
    /// which uses the default run loop mode only: AppKit leaves that mode
    /// while it tracks a scroll or a menu, so a loop could overrun its end for
    /// as long as the user was scrolling the rail beside it.
    private func startLoopWatcher() {
        loopWatcher?.invalidate()
        let timer = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.player.state == .playing else { return }
                // Both bounds are read fresh each tick — the loop toggle and
                // the selection can move mid-playback — and with neither set
                // there is nothing to ask the audio clock about. Ordinary
                // playback needs no timer at all: the playhead reads the clock
                // itself, on its own redraw.
                let looping = self.loopSelection && self.selection != nil
                guard looping || self.stopAtS != nil else { return }
                let position = self.player.currentPosition()
                if self.loopSelection, let selection = self.selection,
                   position >= selection.end - 0.015 {
                    self.player.seek(to: selection.start)
                    return
                }
                if let bound = self.stopAtS, position >= bound {
                    self.player.pause()
                    self.cursorS = bound
                    self.stopAtS = nil
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        loopWatcher = timer
    }

    /// Bring the running preview in line with the document.
    ///
    /// Three cases, and only the third is expensive:
    ///
    /// - **Gain or mute only.** The nodes are already playing the right audio
    ///   at the right time and need a new volume, which `updateGains` sets on
    ///   the live graph. This is the common one — the first frame of an
    ///   Amplify drag splits a segment (structural), every frame after it is
    ///   this — and it used to take the expensive path: `play` is `stop` +
    ///   `prepare` + `arm`, which detaches every node, reopens each file from
    ///   disk and restarts the engine. At a slider's event rate that is a
    ///   graph teardown about sixty times a second, which is audible as
    ///   dropouts and holds the main thread the whole time.
    /// - **Structural, mid-gesture.** A speed or pitch drag really does re-cut
    ///   the timeline. Let the gesture settle first; `endInteraction` flushes
    ///   whatever is still outstanding when the drag ends.
    /// - **Structural, settled.** Re-arm now, from the same timeline moment so
    ///   tweaking a cut mid-listen does not restart the track.
    /// - **Paused.** The graph is up but not running. A gain change still
    ///   lands on the live nodes, which survive the pause; a structural one
    ///   cannot, so it is remembered and applied when playback resumes.
    private func refreshPreviewAfterEdit() {
        guard !auditioningOriginal else { return }
        if player.state == .paused {
            let items = previewItems()
            if MultiPartPlayer.Schedule(items) == player.armedSchedule {
                player.updateGains(items: items)
            } else {
                previewStale = true
            }
            return
        }
        guard player.state == .playing else { return }
        let items = previewItems()
        if MultiPartPlayer.Schedule(items) == player.armedSchedule {
            cancelPreviewRearm()
            player.updateGains(items: items)
            return
        }
        guard interactionKey != nil else {
            cancelPreviewRearm()
            rearmPreview()
            return
        }
        previewRearmTask?.cancel()
        previewRearmTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            self?.rearmPreview()
        }
    }

    private func cancelPreviewRearm() {
        previewRearmTask?.cancel()
        previewRearmTask = nil
    }

    /// Rebuild the audio graph and pick playback back up where it was.
    private func rearmPreview() {
        cancelPreviewRearm()
        guard player.state == .playing, !auditioningOriginal else { return }
        previewStale = false
        let position = min(player.currentPosition(),
                           max(0, timelineDurationS - 0.01))
        player.play(items: previewItems(), from: position)
    }

    /// Resume after the timeline was re-cut while paused: arm the current cut
    /// list rather than the stale one `resume` would replay, holding the
    /// moment the user paused at.
    private func resumeFromStaleEdit() {
        previewStale = false
        let position = min(player.currentPosition(),
                           max(0, timelineDurationS - 0.01))
        player.play(items: previewItems(), from: position)
    }

    // MARK: reversed preview source

    /// A reversed copy of the source, built once per material, so reversed
    /// segments actually play backwards in the preview instead of waiting
    /// for Apply. Chunked from the tail so memory stays flat.
    private func ensureReversedSource() {
        guard reversedSourceURL == nil, !reversedSourceBuilding,
              let sourceURL else { return }
        reversedSourceBuilding = true
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalMusicGenEditor", isDirectory: true)
            .appendingPathComponent((material?.id ?? "src") + ".reversed.wav")
        Task.detached(priority: .userInitiated) {
            let url = try? Self.writeReversed(of: sourceURL, to: destination)
            await MainActor.run {
                self.reversedSourceBuilding = false
                self.reversedSourceURL = url
                self.refreshPreviewAfterEdit()
            }
        }
    }

    nonisolated private static func writeReversed(of source: URL,
                                                  to destination: URL) throws -> URL {
        let file = try AVAudioFile(forReading: source)
        let format = file.processingFormat
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: destination)
        let out = try AVAudioFile(
            forWriting: destination,
            settings: [AVFormatIDKey: kAudioFormatLinearPCM,
                       AVSampleRateKey: format.sampleRate,
                       AVNumberOfChannelsKey: format.channelCount,
                       AVLinearPCMBitDepthKey: 32,
                       AVLinearPCMIsFloatKey: true],
            commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk: AVAudioFrameCount = 65536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: chunk),
              let flipped = AVAudioPCMBuffer(pcmFormat: format,
                                             frameCapacity: chunk)
        else { throw CocoaError(.fileReadUnknown) }
        var end = file.length
        while end > 0 {
            let start = max(0, end - AVAudioFramePosition(chunk))
            let count = AVAudioFrameCount(end - start)
            file.framePosition = start
            try file.read(into: buffer, frameCount: count)
            let frames = Int(buffer.frameLength)
            guard frames > 0, let source = buffer.floatChannelData,
                  let target = flipped.floatChannelData else { break }
            for channel in 0..<Int(format.channelCount) {
                // `vDSP_vrvrs` reverses in place, so the chunk is copied
                // across and then flipped. Same answer as the scalar loop,
                // vectorised — this runs over every sample of the track.
                target[channel].update(from: source[channel], count: frames)
                vDSP_vrvrs(target[channel], 1, vDSP_Length(frames))
            }
            flipped.frameLength = AVAudioFrameCount(frames)
            try out.write(from: flipped)
            end = start
        }
        return destination
    }
}

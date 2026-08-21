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
    let partsRepo: PartsRepository
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

    enum SnippetIntent: Equatable {
        case continueFrom, splitRegion, findMatches
    }

    // MARK: state

    var material: Material?
    var document = EditDocument()
    private(set) var segments: [EditSegment] = []
    private(set) var grid = EditorGrid()
    private(set) var analysis: AnalysisPayload?
    private(set) var bpm: Double?
    private(set) var camelot: String?
    /// The program state the file currently holds (nil = file is pristine).
    var appliedDocument: EditDocument?

    var selection: EditRange?
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

    private(set) var clipboard: [EditSegment] = []
    var applyStage: ApplyStage = .idle
    var exportStage: ApplyStage = .idle
    /// True while the user chose "notify me" and left the apply running.
    var notifyWhenApplied = false

    var undoManager: UndoManager?

    /// Playback bound: stop (or loop) at this timeline second.
    private var stopAtS: Double?
    private var loopWatcher: Timer?
    private var reversedSourceURL: URL?
    private var reversedSourceBuilding = false
    var uploadedSourceId: String?
    private var snippetIntents: [String: SnippetIntent] = [:]

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

    var hasBackup: Bool {
        guard let material else { return false }
        return FileManager.default.fileExists(atPath: material.backupURL.path)
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

    func open(partId: String) {
        guard let part = ((try? partsRepo.part(id: partId)) ?? nil),
              part.format == "wav" else { return }
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
        stopPreview()
        material = nil
        document = EditDocument()
        appliedDocument = nil
        segments = []
        grid = EditorGrid()
        analysis = nil
        selection = nil
        cursorS = 0
        clipboard = []
        applyStage = .idle
        exportStage = .idle
        reversedSourceURL = nil
        uploadedSourceId = nil
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

    private func loadAnalysis(ownerId: String, parentSongId: String?) {
        var record = (try? partsRepo.analysis(ownerId: ownerId)) ?? nil
        if record == nil, let parentSongId {
            record = (try? partsRepo.analysis(ownerId: parentSongId)) ?? nil
        }
        bpm = record?.bpm
        camelot = record?.camelot
        analysis = record.flatMap {
            try? BackendClient.decoder.decode(
                AnalysisPayload.self, from: Data($0.analysisJSON.utf8))
        }
    }

    private func finishOpen() {
        selection = nil
        cursorS = 0
        visibleStartS = 0
        pxPerSecond = 0
        clipboard = []
        applyStage = .idle
        exportStage = .idle
        reversedSourceURL = nil
        reversedSourceBuilding = false
        uploadedSourceId = nil
        undoManager?.removeAllActions()
        rebuild()
    }

    /// The Tier 2.6 chip: on = a few ms of overlap at every discontinuous
    /// join, off = butt joints (the engine's 2 ms de-click still applies).
    func setCrossfadeJoins(_ on: Bool) {
        guard on != crossfadeJoins else { return }
        perform(on ? "Crossfade Joins" : "Butt Joins") { doc in
            doc.joinCrossfadeMs = on ? 8 : 0
        }
    }

    private func rebuild() {
        segments = EditProgram.segments(sourceDuration: sourceDurationS,
                                        ops: document.ops)
        grid = EditorGrid.make(analysis: analysis, segments: segments)
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
        if document.ops.contains(where: { op in
            if case .reverse = op.kind { return true }
            return false
        }) {
            ensureReversedSource()
        }
    }

    // MARK: mutation + undo

    /// Every document change goes through here: snapshot, mutate, rebuild,
    /// persist — and the snapshot registered so ⌘Z swaps it straight back
    /// (the timeline's pattern; the model is value types, so undo is a swap).
    func perform(_ name: String, _ change: (inout EditDocument) -> Void) {
        let before = document
        let selectionBefore = selection
        var updated = document
        change(&updated)
        guard updated != document else { return }
        updated.appliedAt = nil
        document = updated
        registerUndo(name, before: before, selectionBefore: selectionBefore)
        rebuild()
        persistPending()
        refreshPreviewAfterEdit()
    }

    private func registerUndo(_ name: String, before: EditDocument,
                              selectionBefore: EditRange?) {
        undoManager?.registerUndo(withTarget: self) { target in
            let after = target.document
            let selectionAfter = target.selection
            target.document = before
            target.selection = selectionBefore
            target.rebuild()
            target.persistPending()
            target.refreshPreviewAfterEdit()
            target.registerUndo(name, before: after,
                                selectionBefore: selectionAfter)
        }
        undoManager?.setActionName(name)
    }

    /// The pending program is stored as it changes, so "Continue editing"
    /// survives a relaunch — `editedAt` (the applied mark) is not touched.
    func persistPending() {
        guard let material else { return }
        let json = (try? JSONEncoder().encode(document))
            .map { String(decoding: $0, as: UTF8.self) }
        if material.isPart {
            if var part = ((try? partsRepo.part(id: material.id)) ?? nil) {
                part.editsJSON = json
                try? partsRepo.update(part)
            }
        } else if var song = library.song(id: material.id) {
            song.editsJSON = json
            library.update(song)
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
    }

    func cutSelection() {
        guard selection != nil else { return }
        copySelection()
        deleteSelection()
    }

    func paste() {
        guard !clipboard.isEmpty else { return }
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
        replaceWholeTrack("Normalise", matches: { kind in
            if case .normalize = kind { return true }
            return false
        }, with: lufs.map { .normalize(lufs: $0) })
    }

    func setSpeed(rate: Double) {
        replaceWholeTrack("Speed", matches: { kind in
            if case .speed = kind { return true }
            return false
        }, with: abs(rate - 1) > 1e-6 ? .speed(rate: rate) : nil)
    }

    func setPitch(semitones: Double) {
        replaceWholeTrack("Pitch", matches: { kind in
            if case .pitch = kind { return true }
            return false
        }, with: abs(semitones) > 1e-6 ? .pitch(semitones: semitones) : nil)
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

    /// Amplify the current selection, updating the last amplify row while it
    /// targets the same range (a slider drag is one edit, not sixty).
    func setAmplify(db: Double) {
        guard let selection else { return }
        if case .amplify(let range, _)? = document.ops.last?.kind,
           range == selection {
            if abs(db) < 0.05 {
                perform("Amplify") { $0.ops.removeLast() }
            } else {
                perform("Amplify") {
                    $0.ops[$0.ops.count - 1].kind = .amplify(selection, db: db)
                }
            }
        } else if abs(db) >= 0.05 {
            perform("Amplify") {
                $0.ops.append(EditOp(kind: .amplify(selection, db: db)))
            }
        }
    }

    /// What the last amplify row says about this selection, for the slider.
    var amplifyDbForSelection: Double {
        guard let selection else { return 0 }
        if case .amplify(let range, let db)? = document.ops.last?.kind,
           range == selection {
            return db
        }
        return 0
    }

    private func replaceWholeTrack(_ name: String,
                                   matches: (EditOp.Kind) -> Bool,
                                   with kind: EditOp.Kind?) {
        let existingIndex = document.ops.lastIndex { matches($0.kind) }
        perform(name) { doc in
            if let existingIndex {
                if let kind {
                    doc.ops[existingIndex].kind = kind
                } else {
                    doc.ops.remove(at: existingIndex)
                }
            } else if let kind {
                doc.ops.append(EditOp(kind: kind))
            }
        }
    }

    // MARK: edit list rows

    func removeOp(id: UUID) {
        perform("Remove Edit") { $0.ops.removeAll { $0.id == id } }
    }

    func updateOp(id: UUID, kind: EditOp.Kind) {
        perform("Edit Step") { doc in
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

    func updateEffect(_ effect: EffectSetting) {
        perform("Adjust \(effect.kind.label)") { doc in
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

    func autoTrimSilence() async {
        guard let keep = await detectEdgeSilence() else { return }
        perform("Auto-trim Silence") {
            $0.ops.append(EditOp(kind: .trim(keep)))
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
        player.state == .stopped ? cursorS : player.currentPosition()
    }

    var isPlaying: Bool { player.isPlaying }

    func togglePlayback() {
        switch player.state {
        case .playing:
            player.pause()
            cursorS = player.currentPosition()
        case .paused:
            pauseGlobalPlayback()
            player.resume()
            startLoopWatcher()
        case .stopped:
            playPreview(from: cursorS)
        }
    }

    func playPreview(from position: Double) {
        guard material != nil else { return }
        pauseGlobalPlayback()
        stopAtS = nil
        player.play(items: previewItems(), from: position)
        startLoopWatcher()
    }

    func playSelection() {
        guard let selection else { return }
        pauseGlobalPlayback()
        stopAtS = loopSelection ? nil : selection.end
        player.play(items: previewItems(), from: selection.start)
        startLoopWatcher()
    }

    func stopPreview() {
        loopWatcher?.invalidate()
        loopWatcher = nil
        stopAtS = nil
        player.stop()
    }

    func pausePreview() {
        guard player.state == .playing else { return }
        player.pause()
        cursorS = player.currentPosition()
    }

    func seekPreview(to t: Double) {
        cursorS = t.clamped(to: 0...max(0, timelineDurationS))
        if player.state != .stopped {
            player.seek(to: cursorS)
        }
    }

    /// Loop and play-selection bounds — checked beside the position tick.
    private func startLoopWatcher() {
        loopWatcher?.invalidate()
        loopWatcher = Timer.scheduledTimer(withTimeInterval: 0.03,
                                           repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.player.state == .playing else { return }
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
    }

    /// A structural edit rebuilds the schedule; keep playing from the same
    /// timeline moment so tweaking a cut mid-listen does not restart it.
    private func refreshPreviewAfterEdit() {
        guard player.state == .playing else { return }
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
            .appendingPathComponent("LocalMusicEditor", isDirectory: true)
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
                for i in 0..<frames {
                    target[channel][i] = source[channel][frames - 1 - i]
                }
            }
            flipped.frameLength = AVAudioFrameCount(frames)
            try out.write(from: flipped)
            end = start
        }
        return destination
    }
}

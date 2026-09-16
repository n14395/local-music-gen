import AppKit
import SwiftUI

// MARK: - narration

enum MatchNarrator {
    /// One transform, split at the points the commit bar wants to emphasise:
    /// the part's name is set in the primary colour and the number is mono.
    /// Splitting here rather than at two call sites is what keeps the plain
    /// sentence (tested, and reused by RecipeFlowView) and the typeset one
    /// from drifting into two different accounts of the same edit.
    private struct Clause {
        var verb: String
        var name: String
        var middle: String
        var value: String
    }

    private static func clauses(_ items: [(name: String, plan: MatchPlan)])
        -> [Clause] {
        var out: [Clause] = []
        for (name, plan) in items {
            // The tempo badge's ratio, not plan.stretchRatio: the latter is
            // nil for red-quality matches, which the mix stretches anyway — so
            // reading it here left the biggest stretches unnarrated.
            if let ratio = plan.badges.tempo?.stretchRatio,
               abs(ratio - 1) > 0.005 {
                out.append(Clause(
                    verb: "stretch ", name: name, middle: " by ",
                    value: String(format: "%+.1f%%", (ratio - 1) * 100)))
            }
            if plan.pitchShiftSt != 0 {
                let st = Int(abs(plan.pitchShiftSt))
                out.append(Clause(
                    verb: "shift ", name: name,
                    middle: plan.pitchShiftSt > 0 ? " up " : " down ",
                    value: "\(st) semitone" + (st == 1 ? "" : "s")))
            }
        }
        return out
    }

    /// "Will stretch Drums (Song B) by +4.2% and shift Vocals (Song A) down
    /// 1 semitone." — nil when auto-match has nothing to do.
    static func narrate(_ items: [(name: String, plan: MatchPlan)]) -> String? {
        let parts = clauses(items)
        guard !parts.isEmpty else { return nil }
        return "Will "
            + parts.map { $0.verb + $0.name + $0.middle + $0.value }
                .joined(separator: " and ")
            + "."
    }

    /// The same sentence typeset for the commit bar: names in the primary
    /// colour, numbers in mono.
    static func sentence(_ items: [(name: String, plan: MatchPlan)]) -> Text? {
        let parts = clauses(items)
        guard !parts.isEmpty else { return nil }
        var out = Text("Will ")
        for (index, clause) in parts.enumerated() {
            if index > 0 { out = out + Text(" and ") }
            out = out
                + Text(clause.verb)
                + Text(clause.name)
                    .font(Bench.Typo.secondaryEmphasis)
                    .foregroundStyle(Bench.Palette.textPrimary)
                + Text(clause.middle)
                + Text(clause.value)
                    .font(Bench.Typo.mono(11, .semibold))
                    .foregroundStyle(Bench.Palette.textPrimary)
        }
        return out + Text(".")
    }
}

extension MatchQuality {
    var color: Color {
        switch self {
        case .green: Bench.Palette.ok
        case .amber: Bench.Palette.warn
        case .red: Bench.Palette.danger
        }
    }

    var badgeTone: BenchBadge.Tone {
        switch self {
        case .green: .ok
        case .amber: .warn
        case .red: .danger
        }
    }
}

// MARK: - lens

/// Two views of one model: Rows is the faster editor while each lane holds a
/// single clip, Timeline is the only one that can express *when*.
///
/// The raw values are the persisted `workbench.lens` preference — renaming
/// them silently resets every saved lens, so they are not decorative.
enum WorkbenchLens: String, CaseIterable, Identifiable {
    case rows = "Rows"
    case timeline = "Timeline"
    var id: String { rawValue }
}

// MARK: - screen

/// The Workbench: stack parts, align them to one grid, and render an exact mix
/// or hand the result to a generative model.
///
/// Four bands, in the order the work happens: what the mix *is* (top bar), what
/// everything is aligned *to* (align bar), the material itself (Rows or
/// Timeline), and what pressing the button will do (commit bar). The commit bar
/// narrates the edit as a sentence before it happens, which is the whole reason
/// the align controls sit at the top and the button at the bottom.
struct WorkbenchScreen: View {
    let model: WorkbenchModel
    let catalog: ModelCatalogStore
    let library: LibraryStore
    let parts: PartsStore
    let jobs: JobsStore
    let playback: PlaybackController
    let telemetry: TelemetryStore
    let timings: RenderTimingStore
    let notifications: NotificationService
    /// One-off notes from reopening a finished mix (recovered tempo, missing
    /// parts, settings that were never recorded).
    @Binding var notices: [String]
    let onOpenModels: () -> Void
    /// "AI layer…" is a door into the Style Transfer workspace rather than a
    /// sheet of its own: the settings behind it are worth keeping, and a modal
    /// that forgets them the moment it closes is the pattern the workspace
    /// exists to replace.
    let onOpenStyleTransfer: (StylePreset?, String?) -> Void

    enum OutputPath: String, CaseIterable, Identifiable {
        case exact = "Exact"
        case reimagine = "Reimagine"
        var id: String { rawValue }
    }

    @AppStorage("workbench.lens") private var lens: WorkbenchLens = .rows
    /// The window's undo stack, so the menubar's bench commands register the
    /// same snapshots the timeline's own edits do — see
    /// `WorkbenchModel.registerUndo`.
    @Environment(\.undoManager) private var undoManager
    /// "Clear the bench" throws away every lane and every clip on it, so it
    /// asks first. `role: .destructive` only colours the menu item.
    @State private var confirmClear = false
    @State private var showPicker = false
    /// The timeline's pixels-per-second. Held here rather than inside the lens
    /// so the View menu's zoom items can move it — see `ClipTimelineView.zoom`.
    @State private var timelineZoom: CGFloat = 20
    @State private var outputPath: OutputPath = .exact
    @State private var preview = MultiPartPlayer()
    /// A pending re-arm of the preview after a structural edit — see
    /// `syncPreview`.
    @State private var previewRearm: Task<Void, Never>?
    @State private var selection: Set<String> = []
    @State private var peaksStore = PeaksStore()
    @State private var reimaginePrompt = ""
    @State private var reimagineModelId: String?
    /// Set when the user asks for the bench back while a mix renders —
    /// Generate's `showingComposer`, under this screen's name for it.
    @State private var showingBench = false

    /// The models the commit bar can offer, picked once per catalog.
    ///
    /// Three filters over the whole catalog — the mixdown model, and the cover
    /// and shape candidates a Reimagine pass can run on — and `body` ran all
    /// three on every pass. That is every frame of a lane fader's drag, since
    /// dragging one writes `model.lanes` and this screen watches them. None of
    /// the three reads anything but the catalog, and the catalog says when it
    /// has changed.
    private struct EligibleModels {
        let mixdown: ModelInfo?
        let reimagine: [ModelInfo]
    }

    @State private var eligibleCache: (version: Int, value: EligibleModels)?

    private func pickEligible() -> EligibleModels {
        let cover = StyleTransferMode.cover.eligible(catalog.models)
        let loop = StyleTransferMode.shape.eligible(catalog.models)
        var seen = Set<String>()
        return EligibleModels(
            mixdown: MixModels.mixdown(in: catalog.models),
            reimagine: (cover + loop).filter { seen.insert($0.id).inserted })
    }

    private var eligible: EligibleModels {
        if let eligibleCache, eligibleCache.version == catalog.version {
            return eligibleCache.value
        }
        // Picked rather than cached here, because `body` must not write state.
        // The `.onChange` fills the cache a beat later; until it does the
        // answer is arrived at exactly the way it always was, so the bar never
        // draws a catalog it has already been given.
        return pickEligible()
    }

    private var mixModel: ModelInfo? { eligible.mixdown }

    private var reimagineModels: [ModelInfo] { eligible.reimagine }

    /// The mixes and Reimagine passes this bench has in flight, as queue rows.
    private var renderingJobs: [JobsStore.ActiveJob] {
        let ids = model.renderingJobIds
        return jobs.displayJobs.filter {
            !$0.status.isTerminal && ids.contains($0.id)
        }
    }

    /// Off `busy` rather than `renderingJobs` — see the note in `StudioView`.
    /// Reading the queue itself here subscribed every lane card and the align
    /// bar to each progress frame.
    private var isRendering: Bool {
        let ids = model.renderingJobIds
        return jobs.busy.contains { ids.contains($0.id) }
    }
    private var showsRendering: Bool { isRendering && !showingBench }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            topBar
            if showsRendering {
                // The same full-page render Generate shows. An exact mix is
                // usually seconds; a Reimagine pass is a generation, and this
                // is where you watch it. Done rows cover both shapes a bench
                // run can land as.
                StudioRenderingPane(jobs: jobs, library: library,
                                    playback: playback, catalog: catalog,
                                    telemetry: telemetry, timings: timings,
                                    notifications: notifications,
                                    renderingJobs: renderingJobs,
                                    doneOrigins: [.recombined, .generated])
            } else {
                WorkbenchAlignBar(model: model,
                                  onAddPart: { showPicker = true },
                                  onAddAILayer: addAILayer)
                if !notices.isEmpty { noticesStrip }
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                WorkbenchCommitBar(
                    model: model, jobs: jobs, outputPath: $outputPath,
                    mixModel: mixModel,
                    narration: narration, isPreviewing: preview.isPlaying,
                    reimaginePrompt: $reimaginePrompt,
                    reimagineModelId: $reimagineModelId,
                    reimagineModels: reimagineModels,
                    readiness: catalog.readiness,
                    canReimagine: canReimagine,
                    onPreview: togglePreview,
                    onCreateMix: createMix,
                    onReimagine: { Task { await createReimagine() } },
                    onOpenModels: onOpenModels)
            }
        }
        .background(Bench.Palette.windowBackground)
        // The bench's ⌘↩. Published for the same reason the Editor publishes
        // its Apply: the Render menu's first item is whatever the screen you
        // are on calls "run this", and on the bench that key used to do
        // nothing at all.
        .focusedSceneValue(\.runCommand, RunCommand(
            title: "Create Mix",
            isEnabled: mixModel != nil && !model.clips.isEmpty
                && !model.hasMissingClips,
            run: createMix))
        // The arrangement, where the menubar can reach it. Clip operations
        // were ruled out when the menubar was built because the bench had no
        // lifted selection; the cards and the timeline share one now.
        .focusedSceneValue(\.workbenchCommands, benchCommands)
        // Coming back to a finished mix should not leave you stranded on an
        // empty rendering pane; the receipts go with it, so the next visit
        // starts clean.
        .onChange(of: isRendering) {
            if !isRendering {
                showingBench = false
                model.renderingJobIds.removeAll()
            }
        }
        .sheet(isPresented: $showPicker) {
            PartPickerSheet(
                slotLabel: "Any part or song",
                accepts: [KindPattern(pattern: "stem.*"),
                          KindPattern(pattern: "song.mix"),
                          KindPattern(pattern: "notes.*")],
                autoDerive: AutoDerive(splitTask: "separate",
                                       note: "Split into instruments first"),
                catalog: catalog, library: library, parts: parts, jobs: jobs,
                playback: playback, onOpenModels: onOpenModels,
                onPick: { model.add(material: $0, parts: parts) },
                // "Add part" is the button; parts are what it opens on. Songs
                // stay one tab away — the slot still takes them.
                opensOn: .parts)
        }
        .onChange(of: catalog.version, initial: true) { _, version in
            eligibleCache = (version: version, value: pickEligible())
        }
        .onDisappear {
            previewRearm?.cancel()
            preview.stop()
        }
        .onChange(of: model.clips) { syncPreview() }
        .onChange(of: model.lanes) { syncPreview() }
        .confirmationDialog("Take everything off the bench?",
                            isPresented: $confirmClear,
                            titleVisibility: .visible) {
            Button("Clear \(model.lanes.count) "
                   + (model.lanes.count == 1 ? "track" : "tracks"),
                   role: .destructive, action: clearBench)
        } message: {
            Text("Every lane and every clip on it goes. The parts themselves "
                 + "stay in the Library, and ⌘Z puts the arrangement back.")
        }
    }

    // MARK: top bar

    private var topBar: some View {
        @Bindable var model = model
        return BenchTopBar {
            HStack(spacing: 12) {
                Text("AI Workbench")
                    .font(Bench.Typo.screenTitle)
                    .tracking(-0.15)
                    .foregroundStyle(Bench.Palette.textPrimary)
                // The mix name is the same field as the one in the commit bar;
                // the design puts it in both places because it is the name of
                // the thing you are looking at, not just a render option.
                TextField("Workbench mix", text: $model.outputName)
                    .textFieldStyle(.plain)
                    .font(Bench.Typo.secondary)
                    .foregroundStyle(Bench.Palette.textPrimary)
                    .tint(Bench.Palette.accent)
                    .frame(width: 150)
                    .padding(.horizontal, 11).padding(.vertical, 6)
                    .background(RoundedRectangle(
                        cornerRadius: Bench.Metrics.Radius.button,
                        style: .continuous).fill(Bench.Palette.raised))
                    .overlay(RoundedRectangle(
                        cornerRadius: Bench.Metrics.Radius.button,
                        style: .continuous)
                        .strokeBorder(Bench.Palette.cardStrokeSoft, lineWidth: 1))
                BenchSegmented(selection: $lens, options: [
                    .init(value: WorkbenchLens.rows, label: "Rows"),
                    .init(value: WorkbenchLens.timeline, label: "Timeline"),
                ])
                Text(countLine)
                    .font(Bench.Typo.mono(11))
                    .foregroundStyle(Bench.Palette.textFaintest)
            }
        } trailing: {
            if isRendering {
                RenderStatusPill(
                    label: showingBench
                        ? "Back to render"
                        : QueueLoad.of(jobs: renderingJobs).renderingLabel,
                    direction: showingBench ? .toRender : .toWorkspace) {
                    showingBench.toggle()
                }
            }
            Menu {
                Button("Pull everything to bar 1") { pullToStart() }
                    .disabled(model.clips.isEmpty)
                Divider()
                Button("Clear the bench", role: .destructive) {
                    confirmClear = true
                }
                .disabled(model.lanes.isEmpty)
            } label: {
                Text("⋯")
                    .font(Bench.Typo.secondary)
                    .foregroundStyle(Bench.Palette.textSecondary)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(RoundedRectangle(
                        cornerRadius: Bench.Metrics.Radius.button,
                        style: .continuous).fill(Bench.Palette.raised))
                    .overlay(RoundedRectangle(
                        cornerRadius: Bench.Metrics.Radius.button,
                        style: .continuous)
                        .strokeBorder(Bench.Palette.cardStrokeSoft, lineWidth: 1))
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    /// `4 PARTS · 3:21`, or the timeline's `4 TRACKS · 4 CLIPS · 3:21`. The
    /// duration is only shown when there is a target grid to measure it on —
    /// without a tempo the arrangement has no length in seconds.
    private var countLine: String {
        var out: [String] = []
        switch lens {
        case .rows:
            out.append("\(model.clips.count) PART"
                       + (model.clips.count == 1 ? "" : "S"))
        case .timeline:
            out.append("\(model.lanes.count) TRACK"
                       + (model.lanes.count == 1 ? "" : "S"))
            out.append("\(model.clips.count) CLIP"
                       + (model.clips.count == 1 ? "" : "S"))
        }
        if let seconds = model.arrangementDurationS {
            out.append(String(format: "%d:%02d", Int(seconds) / 60,
                              Int(seconds.rounded()) % 60))
        }
        return out.joined(separator: " · ")
    }

    // MARK: notices

    private var noticesStrip: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(Bench.Palette.cyan)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(notices, id: \.self) { notice in
                    Text(notice)
                        .font(Bench.Typo.small)
                        .foregroundStyle(Bench.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Button {
                notices = []
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Bench.Palette.textFaint)
                    // Padding *inside* the content shape: transparent padding
                    // takes no hits in SwiftUI, so without this the target is
                    // the 10 pt glyph box and the notice is near-undismissable.
                    .padding(.horizontal, 7).padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Bench.Palette.cyan.opacity(0.07))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Bench.Palette.hairlineFaint).frame(height: 1)
        }
    }

    // MARK: content

    @ViewBuilder
    private var content: some View {
        if model.lanes.isEmpty {
            WorkbenchEmptyState(onAddPart: { showPicker = true },
                                onAddAILayer: addAILayer)
                .dropDestination(for: String.self) { ids, _ in
                    drop(ids: ids, atBeats: 0)
                }
        } else {
            switch lens {
            case .rows:
                WorkbenchRowsLens(
                    model: model, selection: $selection,
                    onAddPart: { showPicker = true },
                    onAddAILayer: addAILayer,
                    onOpenTimeline: { lens = .timeline })
                    .dropDestination(for: String.self) { ids, _ in
                        // Rows has no playhead, so everything dropped here
                        // starts at bar 1 on a lane of its own.
                        drop(ids: ids, atBeats: 0)
                    }
            case .timeline:
                // The timeline takes the drop itself rather than inheriting one
                // from here: it is the lens that owns the playhead, and ⌥-drop
                // is defined against it.
                ClipTimelineView(model: model, selection: $selection,
                                 peaksStore: peaksStore, preview: preview,
                                 onAddPart: { showPicker = true },
                                 onPlay: { beats in
                                     playback.stop()
                                     preview.play(items: previewItems,
                                                  from: seconds(beats))
                                 },
                                 onDrop: { ids, beats in
                                     drop(ids: ids, atBeats: beats)
                                 },
                                 zoom: $timelineZoom)
            }
        }
    }

    /// Accept parts dragged onto the bench — the gesture the sidebar's parts
    /// drawer advertises ("Drag a part onto the bench, or hold ⌥ to drop it at
    /// the playhead").
    ///
    /// The payload is the material's **id as a plain `String`**: the drag side
    /// only has to say `.draggable(part.id)`, and a String needs no exported
    /// UTType in Info.plist the way a custom `Transferable` would. Ids that
    /// resolve to neither a part nor a song are rejected, which is also what
    /// rejects stray text dragged in from elsewhere.
    private func drop(ids: [String], atBeats: Double) -> Bool {
        var landed: Set<String> = []
        for id in ids {
            guard let material = PickedMaterial.resolve(id: id, parts: parts,
                                                        library: library)
            else { continue }
            let clip = model.add(material: material, parts: parts)
            if atBeats > 0,
               let index = model.clips.firstIndex(where: { $0.id == clip.id }) {
                model.clips[index].startBeats = TimelineMath.clampStart(atBeats)
            }
            landed.insert(clip.id)
        }
        guard !landed.isEmpty else { return false }
        // Select everything that landed. Assigning inside the loop left a
        // three-part drop with one clip selected, which reads as "two of those
        // went somewhere else".
        selection = landed
        return true
    }

    // MARK: actions

    /// "AI layer…" is the catalog's `add-layer` preset, opened in the Style
    /// Transfer workspace with the bench's first audible clip already in it:
    /// the model plays a new instrument over that material and saves it as a
    /// part, so it lands in the Library and can be dropped back onto the bench.
    private func addAILayer() {
        guard let preset = StylePreset.preset(forRecipeId: "add-layer") else {
            return
        }
        // Nothing to do until the catalog exists: routing to Models would be
        // acting on "no model can do this" before anyone has said so.
        guard catalog.readiness.knowsWhatIsInstalled else { return }
        guard !preset.mode.eligible(catalog.models).isEmpty else {
            onOpenModels()
            return
        }
        // The first audible *audio* clip: a notes part has no waveform for a
        // model to play over, and handing one across would open the workspace
        // on something it cannot use.
        onOpenStyleTransfer(preset, aiLayerSource?.material.id)
    }

    /// What the menubar may do to the bench, assembled from the same helpers
    /// the cards and the inspector use — so a clip duplicated from the menu
    /// and one duplicated from its own card do the same thing.
    private var benchCommands: WorkbenchCommands {
        let picked = pickedClip
        return WorkbenchCommands(
            hasClips: !model.clips.isEmpty,
            hasLanes: !model.lanes.isEmpty,
            hasSelection: picked != nil,
            canExplode: (picked?.sections.count ?? 0) >= 2,
            canCrossfade: picked.flatMap(crossfadeCandidate) != nil,
            canReimagine: canReimagine && !reimaginePrompt.isEmpty
                && !reimagineModels.isEmpty,
            addPart: { showPicker = true },
            // Every one of these mutates the arrangement, and none of them used
            // to register anything: ⌘Z after "Remove" from the menu bar undid
            // whatever the timeline had done before it.
            duplicate: {
                guard let picked else { return }
                model.registerUndo(undoManager)
                if let new = model.duplicate(picked.id) { selection = [new.id] }
            },
            remove: {
                guard let picked else { return }
                model.registerUndo(undoManager)
                removeClip(picked)
            },
            explode: {
                guard let picked else { return }
                model.registerUndo(undoManager)
                model.explodeIntoSections(picked.id)
            },
            crossfade: {
                guard let picked, let other = crossfadeCandidate(picked)
                else { return }
                model.registerUndo(undoManager)
                model.crossfade(picked.id, with: other)
            },
            pullToStart: pullToStart,
            // The menubar asks first too — see `confirmClear`.
            clearBench: { confirmClear = true },
            reimagine: { Task { await createReimagine() } })
    }

    /// The one clip the menubar acts on: the first selected in arrangement
    /// order, which is the same clip the rows lens hands to its inspector.
    /// Selecting a card selects every clip on its lane, so a lane with several
    /// placements resolves to its first.
    private var pickedClip: WorkbenchModel.Clip? {
        WorkbenchModel.ordered(lanes: model.lanes, clips: model.clips)
            .first { selection.contains($0.id) }
    }

    /// Removing the last clip on a lane takes the lane with it — an empty lane
    /// draws a card with no waveform and reads as a bug. The rows lens has the
    /// same rule for its own Remove button.
    private func removeClip(_ clip: WorkbenchModel.Clip) {
        selection.remove(clip.id)
        if model.clips(inLane: clip.laneId).count <= 1 {
            model.removeLane(clip.laneId)
        } else {
            model.removeClip(clip.id)
        }
    }

    /// A clip on the same lane whose span overlaps this one — the pair a
    /// crossfade joins. The timeline's own menu asks the same question; this
    /// is that rule, where both the menu bar and the lens can read it.
    private func crossfadeCandidate(_ clip: WorkbenchModel.Clip) -> String? {
        let start = clip.startBeats
        let end = start + model.lengthBeats(of: clip)
        return model.clips.first { other in
            other.id != clip.id && other.laneId == clip.laneId
                && other.startBeats < end
                && other.startBeats + model.lengthBeats(of: other) > start
        }?.id
    }

    /// Take everything off the bench. The overflow menu's item, lifted so the
    /// menubar and the `⋯` run one implementation.
    private func clearBench() {
        preview.stop()
        selection = []
        model.registerUndo(undoManager, name: "Clear the Bench")
        for lane in model.lanes { model.removeLane(lane.id) }
    }

    /// Slide the whole arrangement back so the earliest clip starts at bar 1.
    /// The engine rejects negative offsets, so this is the only way to reclaim
    /// space someone dragged away from the front.
    private func pullToStart() {
        guard let earliest = model.clips.map(\.startBeats).min() else { return }
        model.registerUndo(undoManager)
        model.shiftAll(byBeats: -earliest)
    }

    private func togglePreview() {
        if preview.isPlaying {
            preview.stop()
        } else {
            playback.stop()
            preview.play(items: previewItems)
        }
    }

    private var narration: Text? {
        guard model.autoMatchTempo || model.autoMatchKey else { return nil }
        return MatchNarrator.sentence(model.clips.compactMap { clip in
            model.plan(for: clip).map { (clip.material.name, $0) }
        })
    }

    private var aiLayerSource: WorkbenchModel.Clip? {
        let muteMap = WorkbenchModel.effectivelyMuted(lanes: model.lanes,
                                                      clips: model.clips)
        return WorkbenchModel.ordered(lanes: model.lanes, clips: model.clips)
            .first { !(muteMap[$0.id] ?? $0.muted)
                && !$0.material.kind.hasPrefix("notes.") }
    }

    private var reimagineSource: WorkbenchModel.Clip? {
        let muteMap = WorkbenchModel.effectivelyMuted(lanes: model.lanes,
                                                      clips: model.clips)
        return WorkbenchModel.ordered(lanes: model.lanes, clips: model.clips)
            .first { !(muteMap[$0.id] ?? $0.muted) }
    }

    /// Whether a Reimagine pass has anything to work from.
    ///
    /// The question, not the clip: `reimagineSource` builds two dictionaries
    /// and sorts the whole bench to name the first audible one, and the commit
    /// bar only wants to know whether its button is live — which `body` asks
    /// on every pass, at fader-drag rate. Kept beside `reimagineSource` and
    /// folding lanes by the same rule as `effectivelyMuted`, because the two
    /// disagreeing would arm a button over nothing.
    private var canReimagine: Bool {
        let anySolo = model.lanes.contains { $0.solo }
        var audible: [String: Bool] = [:]
        audible.reserveCapacity(model.lanes.count)
        for lane in model.lanes {
            audible[lane.id] = anySolo ? lane.solo : !lane.muted
        }
        // A clip on no lane at all follows `effectivelyMuted` too: nothing
        // silences it until somebody else solos.
        return model.clips.contains {
            !$0.muted && (audible[$0.laneId] ?? !anySolo)
        }
    }

    /// v1 scope: an AI pass reimagines the first audible clip (the bench is
    /// not mixed first — chain a Create mix, then reimagine the result).
    private func createReimagine() async {
        guard let clip = reimagineSource,
              let model = reimagineModels.first(where: {
                  $0.id == (reimagineModelId ?? reimagineModels.first?.id)
              })
        else { return }
        guard let upload = await jobs.uploadAudio(fileURL: clip.material.fileURL)
        else { return }
        var params: [String: JSONValue] = [:]
        let mode: StyleTransferMode =
            StyleTransferMode.cover.canRun(model) ? .cover : .shape
        params = mode.wireParams(.init(sourceUploadId: upload), model: model)
        if let created = await jobs.submitGenerative(
            modelId: model.id, prompt: reimaginePrompt, lyrics: nil,
            durationS: model.capabilities.duration.defaultS,
            params: params, context: nil) {
            self.model.renderingJobIds.formUnion(created.jobs.map(\.jobId))
        }
    }

    private var previewItems: [MultiPartPlayer.Item] {
        let muteMap = WorkbenchModel.effectivelyMuted(lanes: model.lanes,
                                                      clips: model.clips)
        let gainMap = WorkbenchModel.effectiveGainDb(lanes: model.lanes,
                                                     clips: model.clips)
        let panMap = WorkbenchModel.effectivePan(lanes: model.lanes,
                                                 clips: model.clips)
        let bpm = model.effectiveTargetBpm ?? 120
        return model.clips.map { clip in
            MultiPartPlayer.Item(
                id: clip.id, url: clip.material.fileURL,
                offsetS: clip.startBeats * 60.0 / bpm,
                gainDb: gainMap[clip.id] ?? clip.gainDb,
                pan: panMap[clip.id] ?? clip.pan,
                muted: muteMap[clip.id] ?? clip.muted,
                sourceStartS: clip.sectionStartS ?? 0,
                sourceEndS: clip.sectionEndS)
        }
    }

    /// Keep a running preview honest with the bench. A change that only
    /// moved a fader, a mute or a solo lands on the live nodes; anything
    /// structural — an offset, a trim, a clip added or removed — re-arms
    /// from the same moment, the way the Editor does, so the audio follows
    /// the timeline instead of the arrangement Play was pressed on. The
    /// re-arm is debounced because a drag reports every pixel; it settles
    /// once the drag stops. (Only gains used to be synced, so every move
    /// was ignored until Stop.)
    private func syncPreview() {
        guard preview.isPlaying else { return }
        let items = previewItems
        if MultiPartPlayer.Schedule(items) == preview.armedSchedule {
            previewRearm?.cancel()
            preview.updateGains(items: items)
            return
        }
        previewRearm?.cancel()
        previewRearm = Task {
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled, preview.isPlaying else { return }
            preview.play(items: previewItems, from: preview.currentPosition())
        }
    }

    private func seconds(_ beats: Double) -> Double {
        beats * 60.0 / (model.effectiveTargetBpm ?? 120)
    }

    private func createMix() {
        guard let mixModel else { return }
        let title = model.outputName.isEmpty
            ? "Workbench mix" : model.outputName
        preview.stop()
        Task {
            if let created = await jobs.submitRecombine(
                modelId: mixModel.id, recipeId: "workbench", title: title,
                ingredients: model.ingredients(), options: model.options()) {
                // The receipt the full-page render view watches.
                model.renderingJobIds.formUnion(created.jobs.map(\.jobId))
            }
        }
    }
}

// MARK: - align bar

/// What everything on the bench is being aligned *to*. It sits above the
/// material rather than beside it because it governs every row at once: the
/// stretch percentages on the cards below are all consequences of these four
/// controls.
private struct WorkbenchAlignBar: View {
    @Bindable var model: WorkbenchModel
    let onAddPart: () -> Void
    let onAddAILayer: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Button(action: onAddPart) {
                Text("＋ Add part…")
            }
            .buttonStyle(BenchPrimaryButtonStyle(size: .compact, glows: false))
            Button(action: onAddAILayer) {
                Text("✧ AI layer…")
            }
            .buttonStyle(.bench(.violet))
            .help("Ask a model to play a new instrument over your track — it "
                  + "is saved as a part you can drop onto the bench")

            Spacer(minLength: 12)

            Text("ALIGN EVERYTHING TO").eyebrow(Bench.Palette.textFaintest)
            WorkbenchFieldMenu(
                unit: "TEMPO",
                value: model.effectiveTargetBpm.map {
                    String(format: "%.1f", $0)
                } ?? "—") {
                Button("Auto (first part)") { model.targetBpm = nil }
                ForEach(Array(Set(model.clips.compactMap { $0.summary?.bpm }))
                    .sorted(), id: \.self) { bpm in
                    Button("\(Int(bpm.rounded())) BPM") { model.targetBpm = bpm }
                }
            }
            WorkbenchFieldMenu(unit: "KEY",
                               value: model.effectiveTargetCamelot ?? "—") {
                Button("Auto (first part)") { model.targetCamelot = nil }
                ForEach(1...12, id: \.self) { n in
                    ForEach(["A", "B"], id: \.self) { letter in
                        Button("\(n)\(letter)") {
                            model.targetCamelot = "\(n)\(letter)"
                        }
                    }
                }
            }
            BenchToggleChip(isOn: $model.autoMatchTempo, label: "Match tempo")
            BenchToggleChip(isOn: $model.autoMatchKey, label: "Match key")
        }
        .padding(.horizontal, 20)
        .frame(height: Bench.Metrics.filterBarHeight)
        .background(Bench.Palette.panel)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Bench.Palette.hairlineFaint).frame(height: 1)
        }
    }
}

/// `TEMPO 107.0 ⌄` — a menu whose *value* is a number, so it is mono and sits
/// beside a mono unit label. `BenchMenu` sets its label in the prose face,
/// which is right for `Any model ⌄` and wrong for a tempo.
struct WorkbenchFieldMenu<Content: View>: View {
    let unit: String
    let value: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        Menu {
            content()
        } label: {
            HStack(spacing: 8) {
                Text(unit)
                    .font(Bench.Typo.mono(10))
                    .foregroundStyle(Bench.Palette.textMuted)
                Text(value)
                    .font(Bench.Typo.mono(12, .semibold))
                    .foregroundStyle(Bench.Palette.textPrimary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Bench.Palette.textFaintest)
            }
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.button,
                                         style: .continuous)
                .fill(Bench.Palette.raised))
            .overlay(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.button,
                                      style: .continuous)
                .strokeBorder(Bench.Palette.cardStrokeSoft, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

// MARK: - shared bits

/// The `S` / `M` badges. Solo lights lime because it is the loud, exclusive
/// state; mute goes to the danger tint because it is the one that makes
/// something disappear from the render.
struct WorkbenchToggleBadge: View {
    enum Kind {
        case solo, mute

        var label: String { self == .solo ? "S" : "M" }
        var help: String { self == .solo ? "Solo" : "Mute" }
        var onFill: Color {
            self == .solo ? Bench.Palette.accent
                          : Bench.Palette.danger.opacity(0.16)
        }
        var onText: Color {
            self == .solo ? Bench.Palette.onAccent : Bench.Palette.dangerText
        }
    }

    let kind: Kind
    @Binding var isOn: Bool
    /// Undo hook: the timeline registers a snapshot before every mutation.
    var onBeforeEdit: (() -> Void)?

    var body: some View {
        Button {
            onBeforeEdit?()
            isOn.toggle()
        } label: {
            Text(kind.label)
                .font(Bench.Typo.mono(9, .bold))
                .foregroundStyle(isOn ? kind.onText : Bench.Palette.textQuaternary)
                .padding(.horizontal, 7).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isOn ? kind.onFill : Bench.Palette.control))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(kind.help)
    }
}

/// The small `✕` that removes a lane or a clip.
struct WorkbenchRemoveButton: View {
    var help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Bench.Palette.textFaint)
                .padding(.horizontal, 4).padding(.vertical, 2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// The square checkbox from the commit bar. Not `Toggle`: the design's box is
/// 15 pt with a 4 pt radius and the label sits in the prose face beside it.
struct WorkbenchCheckbox: View {
    @Binding var isOn: Bool
    let label: String

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isOn ? Bench.Palette.accent : .clear)
                    .frame(width: 15, height: 15)
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(isOn ? Bench.Palette.accent
                                           : Color.white.opacity(0.18),
                                      lineWidth: 1.5))
                    .overlay {
                        if isOn {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Bench.Palette.onAccent)
                        }
                    }
                Text(label)
                    .font(Bench.Typo.secondary)
                    .foregroundStyle(Bench.Palette.textSecondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The dashed "add something" tiles that close the Rows list. They are the same
/// two actions as the align bar, restated where the material runs out.
private struct WorkbenchDashedAction: View {
    let title: String
    var tone: Color = Bench.Palette.textQuaternary
    var stroke: Color = Color.white.opacity(0.13)
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Bench.Typo.secondary)
                .foregroundStyle(tone)
                .frame(maxWidth: .infinity)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(stroke,
                                  style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                .contentShape(RoundedRectangle(cornerRadius: 11,
                                               style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - empty state

private struct WorkbenchEmptyState: View {
    let onAddPart: () -> Void
    let onAddAILayer: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            Text("No parts on the bench")
                .font(Bench.Typo.inspectorTitle)
                .foregroundStyle(Bench.Palette.textPrimary)
            Text("Add parts or songs and stack them into something new.")
                .font(Bench.Typo.small)
                .foregroundStyle(Bench.Palette.textMuted)
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                WorkbenchDashedAction(title: "＋ Add a part from the Library",
                                      action: onAddPart)
                WorkbenchDashedAction(title: "✧ Ask AI for a new layer",
                                      tone: Bench.Palette.violet,
                                      stroke: Bench.Palette.violet.opacity(0.28),
                                      action: onAddAILayer)
            }
            .frame(maxWidth: 520)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 18)
    }
}

// MARK: - rows lens

private struct WorkbenchRowsLens: View {
    @Bindable var model: WorkbenchModel
    @Binding var selection: Set<String>
    let onAddPart: () -> Void
    let onAddAILayer: () -> Void
    let onOpenTimeline: () -> Void
    /// This lens edits the same arrangement the timeline does, so it registers
    /// the same undo — see `WorkbenchModel.registerUndo`. Removing a lane card
    /// here used to destroy every clip on it with nothing to press ⌘Z for.
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 9) {
                    ForEach(Array(model.lanes.enumerated()), id: \.element.id) {
                        index, lane in
                        WorkbenchLaneCard(
                            lane: $model.lanes[index],
                            clips: clipBindings(for: lane.id),
                            plan: firstClip(in: lane.id).flatMap { model.plan(for: $0) },
                            target: model.targetSummary,
                            beatsPerBar: model.beatsPerBar,
                            bpm: model.effectiveTargetBpm,
                            lengthBeats: { model.lengthBeats(of: $0) },
                            isSelected: isSelected(lane.id),
                            onSelect: { select(lane.id) },
                            onOpenTimeline: onOpenTimeline,
                            onRemove: {
                                model.registerUndo(undoManager)
                                model.removeLane(lane.id)
                            },
                            onEdit: { model.registerUndo(undoManager, name: $0) })
                    }
                    HStack(spacing: 10) {
                        WorkbenchDashedAction(title: "＋ Add a part from the Library",
                                              action: onAddPart)
                        WorkbenchDashedAction(title: "✧ Ask AI for a new layer",
                                              tone: Bench.Palette.violet,
                                              stroke: Bench.Palette.violet.opacity(0.28),
                                              action: onAddAILayer)
                    }
                }
                .padding(.horizontal, 18).padding(.vertical, 14)
            }
            .frame(maxWidth: .infinity)
            inspector
        }
    }

    /// The 322 pt right-hand column. It stays put with nothing selected rather
    /// than appearing and disappearing under the cursor — the cards to its left
    /// would reflow by 322 pt every time a part was picked.
    private var inspector: some View {
        BenchInspector(width: Bench.Metrics.Inspector.workbench) {
            if let clip = focusBinding {
                WorkbenchPartInspector(
                    clip: clip,
                    // The lane's name, not the material's: the lane is what the
                    // card you clicked is titled with, and it is renameable.
                    title: model.lane(clip.wrappedValue.laneId)?.name
                        ?? clip.wrappedValue.material.name,
                    placement: placement(of: clip.wrappedValue),
                    plan: model.plan(for: clip.wrappedValue),
                    target: model.targetSummary,
                    autoMatchTempo: model.autoMatchTempo,
                    lengthSeconds: model.lengthBeats(of: clip.wrappedValue)
                        * 60.0 / (model.effectiveTargetBpm ?? 120),
                    onDuplicate: {
                        model.registerUndo(undoManager)
                        let new = model.duplicate(clip.wrappedValue.id)
                        if let new { selection = [new.id] }
                    },
                    onRemove: { remove(clip.wrappedValue) })
            } else {
                VStack(spacing: 8) {
                    Text("No part selected")
                        .font(Bench.Typo.secondaryEmphasis)
                        .foregroundStyle(Bench.Palette.textMuted)
                    Text("Pick a card to see how it will be aligned.")
                        .font(Bench.Typo.small)
                        .foregroundStyle(Bench.Palette.textFaintest)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 18)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// The one part the inspector is about. Selecting a card selects every clip
    /// on its lane, so a lane with several placements focuses the first — they
    /// are placements of the same material and share every number in the panel
    /// except the fades, which is what `placement` then says out loud.
    private var focus: WorkbenchModel.Clip? {
        WorkbenchModel.ordered(lanes: model.lanes, clips: model.clips)
            .first { selection.contains($0.id) }
    }

    private var focusBinding: Binding<WorkbenchModel.Clip>? {
        guard let focus else { return nil }
        let id = focus.id
        return Binding(
            get: { model.clips.first { $0.id == id } ?? focus },
            set: { updated in
                if let i = model.clips.firstIndex(where: { $0.id == id }) {
                    model.clips[i] = updated
                }
            })
    }

    /// `nil` for the ordinary one-clip lane; `(2, 3)` when the panel is editing
    /// the second of three placements.
    private func placement(of clip: WorkbenchModel.Clip)
        -> (index: Int, count: Int)? {
        let siblings = model.clips(inLane: clip.laneId)
        guard siblings.count > 1,
              let index = siblings.firstIndex(where: { $0.id == clip.id })
        else { return nil }
        return (index + 1, siblings.count)
    }

    /// Removing the last clip on a lane takes the lane with it: an empty lane
    /// draws a card with no waveform and no controls, which reads as a bug.
    private func remove(_ clip: WorkbenchModel.Clip) {
        model.registerUndo(undoManager)
        selection.remove(clip.id)
        if model.clips(inLane: clip.laneId).count <= 1 {
            model.removeLane(clip.laneId)
        } else {
            model.removeClip(clip.id)
        }
    }

    private func firstClip(in laneId: String) -> WorkbenchModel.Clip? {
        model.clips.first { $0.laneId == laneId }
    }

    private func isSelected(_ laneId: String) -> Bool {
        model.clips.contains { $0.laneId == laneId && selection.contains($0.id) }
    }

    /// Selecting a lane selects its clips, so a part picked here is the part
    /// the timeline's inspector opens on when the lens is switched.
    private func select(_ laneId: String) {
        selection = Set(model.clips.filter { $0.laneId == laneId }.map(\.id))
    }

    /// Bindings by identity rather than index: a clip's position in the array
    /// changes as lanes are edited, and a stale index would edit the wrong clip.
    private func clipBindings(for laneId: String)
        -> [Binding<WorkbenchModel.Clip>] {
        model.clips.filter { $0.laneId == laneId }
            .sorted { $0.startBeats < $1.startBeats }
            .map { clip in
                Binding(
                    get: {
                        model.clips.first { $0.id == clip.id } ?? clip
                    },
                    set: { updated in
                        if let i = model.clips.firstIndex(where: {
                            $0.id == clip.id
                        }) {
                            model.clips[i] = updated
                        }
                    })
            }
    }
}

// MARK: - lane card

/// One lane in the Rows lens. A lane usually holds a single clip, which is the
/// case this card is designed for; when it holds several (a repeat, or a
/// section arrangement) placement stops being expressible as one number, so the
/// card says how many and sends you to the timeline instead of pretending one
/// stepper can express three start times.
private struct WorkbenchLaneCard: View {
    @Binding var lane: WorkbenchModel.Lane
    let clips: [Binding<WorkbenchModel.Clip>]
    let plan: MatchPlan?
    let target: AnalysisSummary
    let beatsPerBar: Double
    let bpm: Double?
    let lengthBeats: (WorkbenchModel.Clip) -> Double
    let isSelected: Bool
    let onSelect: () -> Void
    let onOpenTimeline: () -> Void
    let onRemove: () -> Void
    /// About to change the lane or its clip, named for the Undo menu. The
    /// card's controls bind straight to the model, so they used to register
    /// nothing: ⌘Z after a fader move undid the *previous* edit instead,
    /// which is worse than doing nothing. A slider reports once per drag, a
    /// switch or a stepper click once per change.
    let onEdit: (String) -> Void

    /// A binding whose every write is an undoable edit.
    private func edited(_ name: String,
                        _ binding: Binding<Bool>) -> Binding<Bool> {
        Binding(get: { binding.wrappedValue },
                set: { onEdit(name); binding.wrappedValue = $0 })
    }

    private var single: Binding<WorkbenchModel.Clip>? {
        clips.count == 1 ? clips[0] : nil
    }

    private var first: WorkbenchModel.Clip? { clips.first?.wrappedValue }

    private var stem: Color { Bench.Palette.stem(first?.material.kind) }

    private var isAILayer: Bool {
        first?.material.kind.hasPrefix("layer.") == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            header
            waveform
            controls
        }
        .padding(.horizontal, 13).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(isSelected ? Bench.Palette.cardSelected : Bench.Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .strokeBorder(isSelected ? stem.opacity(0.5)
                                     : Bench.Palette.cardStrokeSoft,
                          lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .onTapGesture(perform: onSelect)
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 8) {
            StemBar(kind: first?.material.kind)
            Text(lane.name)
                .font(Bench.Typo.secondaryEmphasis)
                .foregroundStyle(Bench.Palette.textPrimary)
                .lineLimit(1)
            if let source = first?.material.sourceTitle {
                Text(source)
                    .font(Bench.Typo.small)
                    .foregroundStyle(Bench.Palette.textMuted)
                    .lineLimit(1)
                    .frame(maxWidth: 230, alignment: .leading)
            }
            if clips.count > 1 {
                BenchBadge("\(clips.count) CLIPS")
            }
            badges
            Spacer(minLength: 8)
            WorkbenchToggleBadge(kind: .solo, isOn: edited("Solo", $lane.solo))
            WorkbenchToggleBadge(kind: .mute, isOn: edited("Mute", $lane.muted))
            WorkbenchRemoveButton(help: "Remove from bench", action: onRemove)
        }
    }

    /// What auto-match will do to this part, stated as numbers rather than a
    /// colour: how far it stretches, how far it is transposed, and whether the
    /// key lands.
    @ViewBuilder
    private var badges: some View {
        if let clip = first, clip.isMissing {
            BenchBadge("MISSING", tone: .danger)
                .help("The part this clip came from is gone — replace or "
                      + "remove it before rendering")
        }
        if isAILayer {
            BenchBadge("AI", tone: .violet)
        }
        if let tempo = plan?.badges.tempo, let clip = first {
            let percent = (tempo.stretchRatio - 1) * 100
            let stretches = abs(tempo.stretchRatio - 1) > 0.005
            BenchBadge(String(format: "%+.1f%%", percent),
                       tone: stretches
                           ? tempo.quality(forDrums: clip.isDrums).badgeTone
                           : .neutral)
                .help(tempo.hint(forDrums: clip.isDrums)
                      ?? (tempo.halfTimeFold
                          ? "Tempo matched at half/double time"
                          : "Stretch needed to sit on the target tempo"))
        }
        if let key = plan?.badges.key {
            BenchBadge(String(format: "%+d st", Int(key.pitchShiftSt)),
                       tone: key.pitchShiftSt == 0 ? .neutral : .warn)
                .help("Semitones this part is transposed by")
            BenchBadge(keyLabel(key), tone: key.quality.badgeTone)
                .help("Key compatibility with the target")
        }
    }

    private func keyLabel(_ key: KeyMatch) -> String {
        guard key.pitchShiftSt != 0,
              let source = first?.summary?.camelot,
              let camelot = target.camelot else { return "key ✓" }
        return "\(source) → \(camelot)"
    }

    // MARK: waveform

    @ViewBuilder
    private var waveform: some View {
        if let clip = first {
            BenchWaveformWell(height: 44, padding: 6, radius: 7) {
                // Notes parts go down this path too: `auditionURL` is the
                // pre-rendered preview for a MIDI part, so what is drawn here
                // is the same audio the timeline lens draws for the same clip.
                // A part with no preview render says so — a decorative figure
                // here would be read as this part's shape.
                if let url = clip.material.auditionURL, !clip.isMissing {
                    BenchWaveformLoader(
                        audioURL: url,
                        cacheURL: StoragePaths.libraryWaveforms
                            .appendingPathComponent("\(clip.material.id).peaks"),
                        tint: stem, rest: stem.opacity(0.55))
                } else {
                    Text(noPreviewLabel(clip))
                        .metaLine(Bench.Palette.textFaintest)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .opacity(lane.muted ? 0.35 : 1)
        }
    }

    /// Why there is no waveform. A notes part has none of its own — it is drawn
    /// from the preview the renderer makes of it — so its absence is a missing
    /// *render*, which is a different (and fixable) thing from missing audio.
    private func noPreviewLabel(_ clip: WorkbenchModel.Clip) -> String {
        if clip.isMissing { return "PART IS MISSING" }
        return clip.material.kind.hasPrefix("notes.")
            ? "NO PREVIEW RENDER" : "NO PREVIEW AUDIO"
    }

    // MARK: controls

    private var controls: some View {
        HStack(spacing: 14) {
            HStack(spacing: 9) {
                Text("Gain")
                    .font(Bench.Typo.small)
                    .foregroundStyle(Bench.Palette.textQuaternary)
                BenchSlider(value: $lane.gainDb, range: -24...6, tint: stem,
                            knobSize: Bench.Metrics.Slider.knobSmall,
                            onEditingBegan: { onEdit("Change Gain") })
                Text(String(format: "%+.1f dB", lane.gainDb))
                    .font(Bench.Typo.mono(11, .semibold))
                    .foregroundStyle(Bench.Palette.textSecondary)
                    .frame(width: 52, alignment: .trailing)
            }
            .frame(width: 244)

            HStack(spacing: 9) {
                Text("Pan")
                    .font(Bench.Typo.small)
                    .foregroundStyle(Bench.Palette.textQuaternary)
                BenchSlider(value: $lane.pan, range: -1...1, tint: stem,
                            knobSize: Bench.Metrics.Slider.knobSmall,
                            onEditingBegan: { onEdit("Change Pan") })
                Text(Bench.panLabel(lane.pan))
                    .font(Bench.Typo.mono(11, .semibold))
                    .foregroundStyle(Bench.Palette.textSecondary)
                    .frame(width: 44, alignment: .trailing)
            }
            .frame(width: 200)

            if let clip = single {
                HStack(spacing: 8) {
                    Text("Start at bar")
                        .font(Bench.Typo.small)
                        .foregroundStyle(Bench.Palette.textQuaternary)
                    BenchStepper(value: Binding(
                        get: { barNumber(clip.wrappedValue) + 1 },
                        set: { onEdit("Move Clip")
                               clip.wrappedValue.startBeats =
                                TimelineMath.clampStart(
                                    Double($0 - 1) * beatsPerBar) }),
                                 range: 1...513, width: 18)
                }
                HStack(spacing: 8) {
                    Text("Region")
                        .font(Bench.Typo.small)
                        .foregroundStyle(Bench.Palette.textQuaternary)
                    sectionMenu(clip)
                }
            } else {
                Text("\(clips.count) placements")
                    .font(Bench.Typo.small)
                    .foregroundStyle(Bench.Palette.textFaint)
                    .help("Several clips on this lane — one stepper cannot "
                          + "express three start times, so edit their "
                          + "placement on the timeline")
                Button("Timeline", action: onOpenTimeline)
                    .buttonStyle(.benchSecondary)
            }

            Spacer(minLength: 8)
            Text(lengthLine)
                .metaLine(Bench.Palette.textFaintest)
        }
    }

    private func barNumber(_ clip: WorkbenchModel.Clip) -> Int {
        Int((clip.startBeats / beatsPerBar).rounded(.down))
    }

    /// The lane's footprint on the target grid: earliest start to latest end,
    /// which for the usual single-clip lane is just that clip's length.
    private var lengthLine: String {
        let spans = clips.map { clip -> (Double, Double) in
            let start = clip.wrappedValue.startBeats
            return (start, start + lengthBeats(clip.wrappedValue))
        }
        guard let start = spans.map(\.0).min(),
              let end = spans.map(\.1).max() else { return "" }
        let beats = max(0, end - start)
        let seconds = beats * 60.0 / (bpm ?? 120)
        return String(format: "%.1f BARS · %.1f S", beats / beatsPerBar, seconds)
    }

    @ViewBuilder
    private func sectionMenu(_ clip: Binding<WorkbenchModel.Clip>) -> some View {
        if clip.wrappedValue.sections.isEmpty {
            // Rule: an inapplicable control dims and says why rather than
            // disappearing.
            BenchValueField(text: "Whole part", width: nil, alignment: .leading,
                            font: Bench.Typo.secondary,
                            foreground: Bench.Palette.textMuted)
                .opacity(0.45)
                .help("Run Musical analysis on this part to trim it to a section")
        } else {
            BenchMenu(label: currentSectionLabel(clip.wrappedValue),
                      fill: Bench.Palette.windowBackground,
                      stroke: Bench.Palette.cardStroke,
                      radius: Bench.Metrics.Radius.control) {
                Button("Whole part") {
                    onEdit("Change Region")
                    clip.wrappedValue.sectionStartS = nil
                    clip.wrappedValue.sectionEndS = nil
                }
                ForEach(Array(clip.wrappedValue.sections.enumerated()),
                        id: \.offset) { i, s in
                    Button("\(s.label ?? s.group ?? "Section \(i + 1)")  "
                           + timeRange(s)) {
                        onEdit("Change Region")
                        clip.wrappedValue.sectionStartS = s.startS
                        clip.wrappedValue.sectionEndS = s.endS
                    }
                }
            }
        }
    }

    private func currentSectionLabel(_ clip: WorkbenchModel.Clip) -> String {
        guard let start = clip.sectionStartS, let end = clip.sectionEndS else {
            return "Whole part"
        }
        return range(start, end)
    }

    private func timeRange(_ s: AnalysisPayload.Section) -> String {
        range(s.startS, s.endS)
    }

    /// A region as bars, because the two controls either side of this menu —
    /// `Start at bar` and `42.7 BARS · 95.5 S` — are both in bars, and a clock
    /// time here has to be converted in the head before it can be compared.
    ///
    /// Section boundaries are source seconds; they are named on the *target*
    /// grid, at the same tempo the length readout beside them uses, so the
    /// three numbers stay comparable. With no target tempo there is no grid to
    /// count bars on and the clock is all there is.
    private func range(_ startS: Double, _ endS: Double) -> String {
        guard let bpm, bpm > 0, beatsPerBar > 0 else {
            return "\(clock(startS))–\(clock(endS))"
        }
        let bars = { (t: Double) in t * bpm / 60 / self.beatsPerBar }
        // Inclusive bar numbers: a region from 0 to exactly 12 bars covers
        // bars 1 through 12, so the start floors and the end ceilings.
        return String(format: "Bars %d–%d",
                      Int(bars(startS).rounded(.down)) + 1,
                      max(Int(bars(endS).rounded(.up)),
                          Int(bars(startS).rounded(.down)) + 1))
    }

    private func clock(_ t: Double) -> String {
        String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
    }
}

// MARK: - part inspector

/// Design 08's right-hand column: which part is selected, its fades, and — the
/// reason the panel exists — the arithmetic auto-match is about to apply to it,
/// spelled out before the mix runs rather than discovered after it.
///
/// Two of the design's rows are deliberately absent. A Pitch slider would have
/// to write a per-clip transposition, and there is none: the shift comes out of
/// `Mashability.plan` and would be recomputed away by the next align-bar edit.
/// Snap is a property of the timeline (its `SNAP` segmented control), not of a
/// part. Drawing either would promise an edit the render cannot honour.
private struct WorkbenchPartInspector: View {
    @Binding var clip: WorkbenchModel.Clip
    /// What the card calls this part — its lane name, which is renameable.
    let title: String
    /// `(2, 3)` when this is the second of three placements on its lane.
    let placement: (index: Int, count: Int)?
    let plan: MatchPlan?
    let target: AnalysisSummary
    let autoMatchTempo: Bool
    /// Length on the target grid, which is the ceiling for a fade.
    let lengthSeconds: Double
    let onDuplicate: () -> Void
    let onRemove: () -> Void

    /// The design's label column — what makes the fades and the four alignment
    /// rows line up down the panel.
    private static let labelWidth: CGFloat = 82

    var body: some View {
        VStack(spacing: 0) {
            BenchPanelHeader {
                StemBar(kind: clip.material.kind, height: 16)
                Text(title)
                    .font(Bench.Typo.sectionTitle)
                    .foregroundStyle(Bench.Palette.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(sourceLine).metaLine().lineLimit(1).fixedSize()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    fades
                    Rectangle().fill(Bench.Palette.hairline).frame(height: 1)
                    alignment
                }
                .padding(.horizontal, 18).padding(.vertical, 15)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // The ScrollView takes the slack, which pins the footer to the
            // bottom of the column the way the design's `margin-top:auto` does.
            footer
        }
    }

    private var sourceLine: String {
        let from = "FROM \(clip.material.sourceTitle)"
        guard let placement else { return from }
        return "PLACEMENT \(placement.index) OF \(placement.count) · \(from)"
    }

    // MARK: fades

    private var fades: some View {
        HStack(spacing: 11) {
            Text("Fades")
                .font(Bench.Typo.secondary)
                .foregroundStyle(Bench.Palette.textSecondary)
                .frame(width: Self.labelWidth, alignment: .leading)
            fadeField($clip.fadeInS, help: "Fade in (ms)")
            fadeField($clip.fadeOutS, help: "Fade out (ms)")
            Text("ms")
                .font(Bench.Typo.mono(10))
                .foregroundStyle(Bench.Palette.textMuted)
        }
    }

    /// Milliseconds, as in the timeline's clip bar — at 40 ms, seconds is three
    /// characters of leading zero. Clamped to the clip so a fade can never be
    /// longer than the audio it applies to.
    private func fadeField(_ value: Binding<Double>, help: String) -> some View {
        BenchNumberField(value: Binding(
            get: { (value.wrappedValue * 1000).rounded() },
            set: { value.wrappedValue = max(0, min($0 / 1000, lengthSeconds)) }),
                         format: .number.precision(.fractionLength(0)),
                         width: 62)
            .help(help)
    }

    // MARK: how it will be aligned

    private var alignment: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("HOW IT WILL BE ALIGNED").eyebrow()
            BenchInfoRow("Source", sourceSummary ?? "not analysed", mono: true,
                         labelWidth: Self.labelWidth,
                         color: sourceSummary == nil ? Bench.Palette.textMuted
                                                     : Bench.Palette.textPrimary)
                .help(sourceSummary == nil
                      ? "Run Musical analysis on this part to give it a tempo "
                        + "and a key" : "This part's own tempo and key")
            BenchInfoRow("Target", targetSummary ?? "no grid yet", mono: true,
                         labelWidth: Self.labelWidth,
                         color: targetSummary == nil ? Bench.Palette.textMuted
                                                     : Bench.Palette.textPrimary)
            BenchInfoRow("Stretch", stretch.text, mono: true,
                         labelWidth: Self.labelWidth, color: stretch.color)
            BenchInfoRow("Beat grid", beatGrid.text,
                         labelWidth: Self.labelWidth, color: beatGrid.color)
            if let sentence {
                Text(sentence)
                    .font(Bench.Typo.caption)
                    .foregroundStyle(Bench.Palette.textFaint)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var sourceSummary: String? { Self.line(clip.summary) }

    private var targetSummary: String? { Self.line(target) }

    /// `86.0 BPM · 5B`, or nil when neither is known.
    private static func line(_ summary: AnalysisSummary?) -> String? {
        guard let summary else { return nil }
        var out: [String] = []
        if let bpm = summary.bpm { out.append(String(format: "%.1f BPM", bpm)) }
        if let camelot = summary.camelot { out.append(camelot) }
        return out.isEmpty ? nil : out.joined(separator: " · ")
    }

    /// The stretch as the render will apply it. The stretcher is named because
    /// "+24.4%" alone says nothing about what it will cost the audio — the
    /// engine's mix worker runs Rubber Band R3 through pedalboard.
    private var stretch: (text: String, color: Color) {
        guard autoMatchTempo else {
            return ("none · Match tempo is off", Bench.Palette.textMuted)
        }
        guard let tempo = plan?.badges.tempo else {
            return ("none · no tempo to match", Bench.Palette.textMuted)
        }
        let percent = (tempo.stretchRatio - 1) * 100
        guard abs(percent) > 0.05 else {
            return ("+0.0% · already on the grid", Bench.Palette.textPrimary)
        }
        return (String(format: "%+.1f%% · Rubber Band R3", percent),
                tempo.quality(forDrums: clip.isDrums).color)
    }

    /// Mirrors the stretch mode `JobsStore` will put in the mix spec: the beat
    /// grid is only used when this part is actually being stretched *and* its
    /// analysis found downbeats — otherwise the engine stretches uniformly and
    /// the grid plays no part, which is worth knowing before a drum loop drifts.
    private var beatGrid: (text: String, color: Color) {
        guard autoMatchTempo, clip.summary?.bpm != nil, target.bpm != nil else {
            return ("not used · nothing is being stretched",
                    Bench.Palette.textMuted)
        }
        let downbeats = clip.summary?.downbeats ?? []
        guard !downbeats.isEmpty else {
            return ("uniform · no downbeats detected", Bench.Palette.warn)
        }
        return ("locked · \(downbeats.count) downbeats", Bench.Palette.ok)
    }

    /// SPEC §4 rule 4: the app says what it is about to do, and says how to stop
    /// it. Only shown when there is something to stop.
    private var sentence: String? {
        guard autoMatchTempo, let bpm = clip.summary?.bpm,
              let tempo = plan?.badges.tempo,
              abs(tempo.stretchRatio - 1) > 0.0005 else { return nil }
        return String(format: "Switch Match tempo off in the align bar to keep "
                      + "this part at its own %.0f BPM.", bpm.rounded())
    }

    // MARK: footer

    private var footer: some View {
        HStack(spacing: 8) {
            footerButton("Duplicate", tone: .neutral, action: onDuplicate)
                .help("Add another placement of this part on the same lane")
            footerButton("Reveal part", tone: .neutral) {
                NSWorkspace.shared
                    .activateFileViewerSelecting([clip.material.fileURL])
            }
            .disabled(clip.isMissing)
            .opacity(clip.isMissing ? 0.45 : 1)
            .help(clip.isMissing
                  ? "The file this part came from is gone"
                  : "Show this part's audio file in Finder")
            footerButton("Remove", tone: .destructive, action: onRemove)
                .help("Take this part off the bench")
        }
        .padding(.horizontal, 18).padding(.vertical, 15)
        .overlay(alignment: .top) {
            Rectangle().fill(Bench.Palette.hairline).frame(height: 1)
        }
    }

    /// Equal thirds, so the row reads as one control strip. The label carries
    /// the width rather than the button: `BenchSecondaryButtonStyle` sizes its
    /// fill to the label, so stretching the button alone would leave three
    /// small pills floating in a wide row.
    private func footerButton(_ title: String,
                              tone: BenchSecondaryButtonStyle.Tone,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).frame(maxWidth: .infinity)
        }
        .buttonStyle(BenchSecondaryButtonStyle(
            tone: tone,
            padding: EdgeInsets(top: 10, leading: 8, bottom: 10, trailing: 8)))
        .frame(maxWidth: .infinity)
    }
}

// MARK: - commit bar

/// Two rows: what the mix is about to do, then the button that does it. The
/// sentence comes first because it is the only place the user is told that
/// their vocal is about to be stretched a quarter of its length.
private struct WorkbenchCommitBar: View {
    @Bindable var model: WorkbenchModel
    let jobs: JobsStore
    @Binding var outputPath: WorkbenchScreen.OutputPath
    let mixModel: ModelInfo?
    let narration: Text?
    let isPreviewing: Bool
    @Binding var reimaginePrompt: String
    @Binding var reimagineModelId: String?
    let reimagineModels: [ModelInfo]
    /// An empty `reimagineModels` means "install one" only once the engine has
    /// said what is installed; before that it means nothing at all.
    let readiness: CatalogReadiness
    let canReimagine: Bool
    let onPreview: () -> Void
    let onCreateMix: () -> Void
    let onReimagine: () -> Void
    let onOpenModels: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            narrationRow
            commitRow
            if outputPath == .reimagine { reimagineRow }
            if let error = jobs.lastError {
                HStack(spacing: 7) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 11))
                    Text(error).font(Bench.Typo.small)
                }
                .foregroundStyle(Bench.Palette.dangerText)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(Bench.Palette.panel)
        .overlay(alignment: .top) {
            Rectangle().fill(Bench.Palette.cardStrokeSoft).frame(height: 1)
        }
    }

    private var narrationRow: some View {
        HStack(spacing: 12) {
            if let narration {
                Text("✦")
                    .font(Bench.Typo.body)
                    .foregroundStyle(Bench.Palette.violet)
                narration
                    .font(Bench.Typo.secondary)
                    .foregroundStyle(Bench.Palette.textSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 12)
            Text("Rough preview — the final mix is aligned and stretched")
                .font(Bench.Typo.small)
                .foregroundStyle(Bench.Palette.textFaint)
            Button(action: onPreview) {
                HStack(spacing: 8) {
                    Image(systemName: isPreviewing ? "stop.fill" : "play.fill")
                        .font(.system(size: 9, weight: .bold))
                    Text(isPreviewing ? "Stop" : "Preview")
                }
            }
            .buttonStyle(BenchSecondaryButtonStyle(
                tone: .quiet,
                padding: EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14)))
            .disabled(model.clips.isEmpty)
            .opacity(model.clips.isEmpty ? 0.45 : 1)
        }
    }

    private var commitRow: some View {
        HStack(spacing: 12) {
            TextField("Workbench mix", text: $model.outputName)
                .textFieldStyle(.plain)
                .font(Bench.Typo.secondary)
                .foregroundStyle(Bench.Palette.textPrimary)
                .tint(Bench.Palette.accent)
                .padding(.horizontal, 11).padding(.vertical, 8)
                .frame(width: 196)
                .background(RoundedRectangle(
                    cornerRadius: Bench.Metrics.Radius.button,
                    style: .continuous).fill(Bench.Palette.windowBackground))
                .overlay(RoundedRectangle(
                    cornerRadius: Bench.Metrics.Radius.button,
                    style: .continuous)
                    .strokeBorder(Bench.Palette.cardStroke, lineWidth: 1))

            HStack(spacing: 10) {
                Text("Loudness")
                    .font(Bench.Typo.secondary)
                    .foregroundStyle(Bench.Palette.textQuaternary)
                BenchSlider(value: $model.targetLufs, range: -30 ... -6,
                            step: 0.5)
                Text(String(format: "%.1f LUFS", model.targetLufs))
                    .font(Bench.Typo.mono(11, .semibold))
                    .foregroundStyle(Bench.Palette.textSecondary)
                    .frame(width: 74, alignment: .trailing)
            }
            .frame(width: 290)

            WorkbenchCheckbox(isOn: $model.keepTracks,
                              label: "Keep the separate tracks")
                .help("Also save each aligned track as a part of the new song")

            Spacer(minLength: 12)

            BenchSegmented(selection: $outputPath, options: [
                .init(value: WorkbenchScreen.OutputPath.exact, label: "Exact"),
                .init(value: WorkbenchScreen.OutputPath.reimagine,
                      label: "Reimagine"),
            ])

            switch outputPath {
            case .exact:
                if mixModel == nil {
                    Button("Get Mixdown & Align — free") { onOpenModels() }
                        .buttonStyle(.bench(.accent))
                } else {
                    Button("Create mix", action: onCreateMix)
                        .buttonStyle(.benchPrimaryCompact)
                        .disabled(model.clips.isEmpty || model.hasMissingClips)
                        .opacity(model.clips.isEmpty || model.hasMissingClips
                                 ? 0.45 : 1)
                        .help(createMixHelp)
                }
            case .reimagine:
                Button("Reimagine", action: onReimagine)
                    .buttonStyle(.benchPrimaryCompact)
                    .disabled(!canReimagine || reimaginePrompt.isEmpty
                              || reimagineModels.isEmpty)
                    .opacity(!canReimagine || reimaginePrompt.isEmpty
                             || reimagineModels.isEmpty ? 0.45 : 1)
                    .help("Reimagines the first audible clip; to reimagine the "
                          + "whole stack, Create mix first, then run this on "
                          + "the result")
            }
        }
    }

    /// A disabled button has to say why it is disabled — and it is disabled for
    /// two different reasons, so the tooltip has three branches, not two.
    private var createMixHelp: String {
        if model.clips.isEmpty {
            return "Add a part to the bench first — there is nothing to mix"
        }
        if model.hasMissingClips {
            return "Replace or remove the missing parts first"
        }
        return "Render the bench into a new song"
    }

    /// The generative path needs a model and a prompt, and the design's commit
    /// bar has no room for either — so they appear only once Reimagine is the
    /// chosen output.
    private var reimagineRow: some View {
        HStack(spacing: 12) {
            if let waiting = readiness.shortLine {
                if case .pending = readiness { BenchSpinner(size: 12) }
                Text(waiting)
                    .font(Bench.Typo.small)
                    .foregroundStyle(Bench.Palette.textFaint)
                Spacer(minLength: 0)
            } else if reimagineModels.isEmpty {
                Text("Needs an ACE-Step or Stable Audio model")
                    .font(Bench.Typo.small)
                    .foregroundStyle(Bench.Palette.textMuted)
                Button("Open Models") { onOpenModels() }
                    .buttonStyle(.benchSecondary)
                Spacer(minLength: 0)
            } else {
                BenchMenu(label: reimagineModelName) {
                    ForEach(reimagineModels) { candidate in
                        Button(candidate.displayName) {
                            reimagineModelId = candidate.id
                        }
                    }
                }
                TextField("e.g. orchestral, cinematic", text: $reimaginePrompt)
                    .textFieldStyle(.plain)
                    .font(Bench.Typo.secondary)
                    .foregroundStyle(Bench.Palette.textPrimary)
                    .tint(Bench.Palette.accent)
                    .padding(.horizontal, 11).padding(.vertical, 8)
                    .background(RoundedRectangle(
                        cornerRadius: Bench.Metrics.Radius.button,
                        style: .continuous).fill(Bench.Palette.windowBackground))
                    .overlay(RoundedRectangle(
                        cornerRadius: Bench.Metrics.Radius.button,
                        style: .continuous)
                        .strokeBorder(Bench.Palette.cardStroke, lineWidth: 1))
            }
        }
    }

    private var reimagineModelName: String {
        let id = reimagineModelId ?? reimagineModels.first?.id
        return reimagineModels.first { $0.id == id }?.displayName ?? "Model"
    }
}

// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// The page behind every multi-stage music↔text card: transcribe-lyrics, the
/// two round trips, the telephone game, and the two ABC pipelines.
///
/// One page for six cards because what differs between them is the plan, and
/// the plan is data (`TextChain.Kind`). What the page adds is the per-stage
/// model pickers, the editable middle card, and a commit bar that cycles
/// through run → running → your-turn → done.
struct TextPipelineView: View {
    let recipe: Recipe
    let kind: TextChain.Kind
    let sourceId: String?
    let settings: AppSettings
    let catalog: ModelCatalogStore
    let library: LibraryStore
    let parts: PartsStore
    let jobs: JobsStore
    let textStore: TextStore
    let chain: TextChainModel
    let playback: PlaybackController
    let onOpenModels: () -> Void
    let onBack: () -> Void

    init(recipe: Recipe, kind: TextChain.Kind, sourceId: String?,
         settings: AppSettings, catalog: ModelCatalogStore,
         library: LibraryStore, parts: PartsStore, jobs: JobsStore,
         textStore: TextStore, chain: TextChainModel,
         playback: PlaybackController, onOpenModels: @escaping () -> Void,
         onBack: @escaping () -> Void) {
        self.recipe = recipe
        self.kind = kind
        self.sourceId = sourceId
        self.settings = settings
        self.catalog = catalog
        self.library = library
        self.parts = parts
        self.jobs = jobs
        self.textStore = textStore
        self.chain = chain
        self.playback = playback
        self.onOpenModels = onOpenModels
        self.onBack = onBack
        _pauseToEdit = State(initialValue: kind.pausesForEdit)
    }

    /// The card's kind with the pause toggle applied — what actually plans
    /// and runs. The card carries the plain kind; the edited sibling is one
    /// checkbox away rather than a second card.
    private var effectiveKind: TextChain.Kind {
        switch (kind, pauseToEdit) {
        case (.roundTrip, true): .roundTripEdited
        case (.roundTripEdited, false): .roundTrip
        case (.abcRoundTrip, true): .abcEdited
        case (.abcEdited, false): .abcRoundTrip
        default: kind
        }
    }

    /// Whether this card's pipeline has an editable-pause sibling at all —
    /// the lyric and telephone pipelines do not.
    private var canPauseToEdit: Bool {
        switch kind {
        case .roundTrip, .roundTripEdited, .abcRoundTrip, .abcEdited: true
        case .lyrics, .telephone: false
        }
    }

    @State private var source: PickedMaterial?
    /// The source card's second line, resolved when the source changes.
    ///
    /// `ActionCopy.sourceMeta` is a song read plus an analysis read, and asked
    /// for from inside `body` it ran on every pass of a page that has text
    /// fields on it. The line only depends on the material, so it is resolved
    /// with it.
    @State private var sourceMeta: String?
    @State private var captionerId: String?
    @State private var transcriberId: String?
    @State private var lyricsModelId: String?
    @State private var composerId: String?
    @State private var separatorId: String?
    @State private var generatorId: String?
    @State private var separateVocalsFirst = true
    /// The "…→ edit →…" cards folded into their plain siblings: same
    /// pipeline, one toggle. Seeded from the card's own kind so a deep link
    /// to an old edited-variant card still arrives paused.
    @State private var pauseToEdit: Bool
    @State private var rounds = 3
    @State private var durationS: Double = 20
    @State private var name = ""
    @State private var draft = ""
    @State private var choosingSource = false
    @State private var starting = false
    /// The score the notation viewer is open on — "View" on the ABC output
    /// row, once a document has landed on the source song.
    @State private var openScore: NotationDocument?
    @AppStorage("actions.lastRuns") private var runsJSON = "{}"

    private var slot: Slot? { recipe.slots.first }

    /// This card's run, when the live one is this card's.
    private var activeRun: TextChainModel.Run? {
        chain.run(forRecipe: recipe.id)
    }

    private var plan: TextChain {
        TextChain.make(kind: effectiveKind, inputs: inputs)
    }

    private var inputs: TextChain.Inputs {
        var inputs = TextChain.Inputs()
        inputs.models = catalog.models
        inputs.captionerId = captionerId
        inputs.transcriberId = transcriberId
        inputs.lyricsModelId = lyricsModelId
        inputs.composerId = composerId
        inputs.separatorId = separatorId
        inputs.generatorId = generatorId
        inputs.separateVocalsFirst = separateVocalsFirst
        inputs.hasVocalsStem = sourceIsVocal
        inputs.rounds = rounds
        inputs.durationS = durationS
        return inputs
    }

    /// Whether the picked material is already a vocal — a stem the separator
    /// would only produce again.
    private var sourceIsVocal: Bool {
        source?.kind.hasPrefix("stem.vocals") ?? false
    }

    private var canRun: Bool {
        source != nil && plan.isRunnable && !starting
            && (activeRun == nil || activeRun?.isFinished == true
                || activeRun?.progress.isFailed == true)
    }

    var body: some View {
        ActionPage(recipe: recipe, onBack: onBack) {
            ActionSourceCard(
                eyebrow: "START FROM",
                material: source,
                meta: sourceMeta,
                playback: playback,
                placeholder: "A song or a part from your library.",
                chooseTitle: source == nil ? "Choose from Library…" : "Change…",
                onChoose: { choosingSource = true },
                onRemove: source == nil ? nil : { source = nil })
            stagesCard
            optionsCard
            editCard
            statusCard
        } commit: {
            ActionCommitRow(title: commitTitle,
                            costLine: costLine,
                            costSubline: "THE ORIGINAL IS NEVER MODIFIED",
                            isEnabled: commitEnabled,
                            error: activeRun?.progress.failure
                                ?? plan.blockedReason,
                            queueTitle: nil,
                            onCommit: commit,
                            onQueue: nil)
        } rail: {
            ActionRail(outputs: outputs, explanation: explanation,
                       lastRun: ActionRunLog.decoded(runsJSON).runs[recipe.id])
        }
        .onAppear { restore() }
        // The editable middle stage, seeded when the run parks rather than
        // only in `restore()`. On the normal path the page is already on
        // screen when the caption lands, so `onAppear` fired minutes ago and
        // nothing re-seeded the draft: the editor showed an empty box, the
        // card that would at least have *displayed* the model's words is in
        // the `else` branch of the same `if`, and `commitEnabled` needs a
        // non-empty draft — so the run could not be continued at all.
        .onChange(of: pendingEditText, initial: true) { previous, text in
            guard let text else { return }
            // A run that has just parked brings its own text; coming back to
            // one already parked keeps whatever was typed into it.
            if previous == nil || draft.isEmpty { draft = text }
        }
        .onChange(of: source, initial: true) {
            sourceMeta = source.map {
                ActionCopy.sourceMeta($0, library: library, parts: parts)
            }
        }
        .sheet(isPresented: $choosingSource) {
            PartPickerSheet(
                slotLabel: slot?.label ?? "Song or part",
                accepts: slot?.accepts ?? [KindPattern(pattern: "song.mix")],
                autoDerive: slot?.autoDerive, catalog: catalog,
                library: library, parts: parts, jobs: jobs,
                playback: playback, onOpenModels: onOpenModels,
                onPick: { source = $0 })
        }
        // No renderer route from here: the Actions pages never had one, and
        // the sheet's Hear it says where the render lives instead.
        .sheet(item: $openScore) { score in
            NotationSheet(document: score, playback: playback,
                          onRenderNotes: nil)
        }
    }

    // MARK: - Sections

    /// One row per stage: what it does, and the model it runs on. Compact
    /// menus rather than the big radio picker — four stages of radio cards
    /// would be a page of nothing but models.
    private var stagesCard: some View {
        ActionOptionsCard(eyebrow: "THE RUN") {
            if plan.stages.isEmpty {
                ActionFootnote(
                    text: plan.blockedReason ?? "Nothing to run yet.",
                    tone: Bench.Palette.warn)
                Button("Get the models…", action: onOpenModels)
                    .buttonStyle(BenchSecondaryButtonStyle(tone: .quiet))
            } else {
                ForEach(Array(displayStages.enumerated()), id: \.offset) {
                    index, stage in
                    stageRow(index: index, stage: stage)
                }
            }
            ForEach(plan.warnings, id: \.self) { warning in
                ActionFootnote(text: warning, tone: Bench.Palette.warn)
            }
        }
    }

    /// The telephone game unrolls to as many as eighteen stages; the card
    /// shows one round and says so, rather than scrolling for a page.
    private var displayStages: [TextChain.Stage] {
        guard kind.repeats else { return plan.stages }
        let perRound = max(1, plan.stages.count / max(1, plan.rounds))
        return Array(plan.stages.prefix(perRound))
    }

    private func stageRow(index: Int, stage: TextChain.Stage) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(index + 1)")
                .font(Bench.Typo.mono(10))
                .foregroundStyle(Bench.Palette.textFaintest)
                .frame(width: 14, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(stage.title)
                    .font(Bench.Typo.body)
                    .foregroundStyle(Bench.Palette.textPrimary)
                Text(stage.detail)
                    .font(Bench.Typo.small)
                    .foregroundStyle(Bench.Palette.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if let picker = pickerTask(for: stage) {
                modelMenu(task: picker.task, selection: picker.selection,
                          onPick: picker.onPick)
            }
        }
        .padding(.vertical, 3)
    }

    private struct StagePicker {
        let task: String
        let selection: String?
        let onPick: (String?) -> Void
    }

    private func pickerTask(for stage: TextChain.Stage) -> StagePicker? {
        switch stage {
        case .separate:
            StagePicker(task: "separate", selection: separatorId) {
                separatorId = $0
            }
        case .caption:
            StagePicker(task: "caption", selection: captionerId) {
                captionerId = $0
            }
        case .transcribeLyrics:
            StagePicker(task: "lyrics", selection: lyricsModelId) {
                lyricsModelId = $0
            }
        case .extractABC:
            StagePicker(task: "transcribe", selection: transcriberId) {
                transcriberId = $0
            }
        case .composeABC:
            StagePicker(task: "compose", selection: composerId) {
                composerId = $0
            }
        case .generate:
            StagePicker(task: "generate", selection: generatorId) {
                generatorId = $0
            }
        case .editText:
            nil
        }
    }

    private func modelMenu(task: String, selection: String?,
                           onPick: @escaping (String?) -> Void) -> some View {
        let installed = task == "generate"
            ? GenerateNeed().eligible(catalog.models)
            : catalog.models.filter {
                $0.installState == .installed
                    && $0.capabilities.supportedTasks.contains(task)
            }
        let name = installed.first { $0.id == selection }?.displayName
            ?? installed.first?.displayName ?? "None installed"
        return BenchMenu(label: name) {
            Button("Automatic") { onPick(nil) }
            Divider()
            ForEach(installed, id: \.id) { model in
                Button(model.displayName) { onPick(model.id) }
            }
        }
    }

    @ViewBuilder
    private var optionsCard: some View {
        ActionOptionsCard(eyebrow: "OPTIONS") {
            if kind == .lyrics {
                ActionCheckChip(
                    label: "Isolate the vocal first",
                    isOn: $separateVocalsFirst,
                    disabledReason: sourceIsVocal
                        ? "This already is a vocal" : nil)
            }
            if canPauseToEdit {
                ActionCheckChip(
                    label: "Pause to edit the text before it becomes music",
                    isOn: $pauseToEdit)
            }
            if kind.repeats {
                HStack(spacing: 12) {
                    Text("ROUNDS")
                        .font(Bench.Typo.mono(10))
                        .foregroundStyle(Bench.Palette.textFaintest)
                    BenchSlider(value: Binding(
                        get: { Double(rounds) },
                        set: { rounds = Int($0) }), range: 2...6, step: 1)
                    Text("\(rounds)")
                        .font(Bench.Typo.value)
                        .foregroundStyle(Bench.Palette.textPrimary)
                        .frame(width: 32, alignment: .trailing)
                }
            }
            if kind.needsGenerator {
                HStack(spacing: 12) {
                    Text("LENGTH")
                        .font(Bench.Typo.mono(10))
                        .foregroundStyle(Bench.Palette.textFaintest)
                    BenchSlider(value: $durationS, range: 5...60, step: 1)
                    Text("\(Int(durationS)) s")
                        .font(Bench.Typo.value)
                        .foregroundStyle(Bench.Palette.textPrimary)
                        .frame(width: 46, alignment: .trailing)
                }
                ActionTextField(placeholder: "Name the takes (optional)",
                                text: $name)
            }
        }
    }

    /// What the editor should be holding while the run is parked for an edit,
    /// and nil at every other moment — the value the seeding `onChange` above
    /// watches.
    private var pendingEditText: String? {
        guard let run = activeRun, run.progress.awaitingEdit else { return nil }
        return run.progress.editedText ?? run.progress.text ?? ""
    }

    /// The editable middle stage — the whole point of two of these cards.
    @ViewBuilder
    private var editCard: some View {
        if let run = activeRun, run.progress.awaitingEdit {
            ActionOptionsCard(eyebrow: effectiveKind == .abcEdited
                                ? "THE NOTATION — YOUR TURN"
                                : "WHAT IT HEARD — YOUR TURN") {
                LyricsEditor(
                    lyrics: $draft, tags: [],
                    hint: effectiveKind == .abcEdited
                        ? "ABC notation. Edit it freely — what you leave "
                            + "here is what gets composed."
                        : "This is what the model heard. Rewrite anything "
                            + "before it becomes music.",
                    fills: true)
                // The score follows the typing, a beat behind, so editing
                // ABC by hand stops being blind: a broken bar shows up as a
                // warning under the staff before Compose is pressed.
                if effectiveKind == .abcEdited {
                    NotationLivePreview(abc: draft)
                }
            }
        } else if let text = activeRun?.progress.effectiveText,
                  !text.isEmpty {
            TextResultCard(eyebrow: "THE TEXT SO FAR", text: text,
                           monospaced: effectiveKind == .abcEdited
                               || effectiveKind == .abcRoundTrip)
        }
    }

    @ViewBuilder
    private var statusCard: some View {
        if let run = activeRun, !run.plan.stages.isEmpty {
            ActionOptionsCard(eyebrow: "PROGRESS") {
                Text(run.plan.statusLine(run.progress))
                    .font(Bench.Typo.body)
                    .foregroundStyle(run.progress.isFailed
                                     ? Bench.Palette.warn
                                     : Bench.Palette.textPrimary)
                if run.isFinished, let notice = chain.notice {
                    ActionFootnote(text: notice)
                }
                if run.isFinished || run.progress.isFailed {
                    Button("Clear") { chain.dismiss() }
                        .buttonStyle(BenchSecondaryButtonStyle(tone: .quiet))
                }
            }
        }
    }

    // MARK: - Commit

    private var commitEnabled: Bool {
        if activeRun?.progress.awaitingEdit == true {
            return !draft.trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        }
        return canRun
    }

    private var commitTitle: String {
        if let run = activeRun {
            if run.progress.awaitingEdit { return "Continue with this text" }
            if run.progress.isFailed { return "Run it again" }
            if run.isFinished { return "Run it again" }
            return run.plan.statusLine(run.progress)
        }
        return "Run · \(plan.jobCount) job\(plan.jobCount == 1 ? "" : "s")"
    }

    private var costLine: String? {
        guard source != nil else { return "CHOOSE SOMETHING TO START FROM" }
        return ActionFormat.join([
            "\(plan.jobCount) JOBS",
            kind.needsGenerator ? "NEW TAKES IN LIBRARY › GENERATED" : nil,
            kind == .lyrics ? "WORDS ATTACHED TO THE TRACK" : nil,
        ])
    }

    private func commit() {
        if let run = activeRun, run.progress.awaitingEdit {
            let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            Task { await chain.continueAfterEdit(text, context: context) }
            return
        }
        guard canRun, let source else { return }
        starting = true
        let plan = plan
        Task {
            defer { starting = false }
            await chain.start(recipeId: recipe.id, plan: plan, source: source,
                              name: name, context: context)
            runsJSON = ActionRunLog.recording(
                .init(summary: "\(recipe.name): \(source.name)",
                      detail: ActionFormat.join([
                        "\(plan.jobCount) JOBS",
                        kind.repeats ? "\(rounds) ROUNDS" : nil]),
                      at: Date(), sourceId: source.id, modelId: nil),
                recipeId: recipe.id, in: runsJSON)
        }
    }

    private var context: TextChainModel.RunContext {
        .init(jobs: jobs, parts: parts, library: library,
              textStore: textStore, models: catalog.models)
    }

    // MARK: - Copy

    private var outputs: [ActionOutput] {
        switch kind {
        case .lyrics:
            [ActionOutput(id: "lyrics", name: "Transcribed lyrics",
                          meta: "TEXT + TIMINGS")]
        case .roundTrip, .roundTripEdited:
            [ActionOutput(id: "text", name: "The description", meta: "TEXT"),
             ActionOutput(id: "song", name: "A new take", meta: "AUDIO",
                          kind: "song.mix")]
        case .telephone:
            [ActionOutput(id: "text", name: "A caption per round",
                          meta: "TEXT"),
             ActionOutput(id: "song", name: "\(rounds) takes", meta: "AUDIO",
                          kind: "song.mix")]
        case .abcRoundTrip, .abcEdited:
            [ActionOutput(id: "abc", name: "ABC notation", meta: "TEXT",
                          onOpen: latestScore.map { doc in { open(score: doc) } }),
             ActionOutput(id: "notes", name: "Composed notes", meta: "MIDI",
                          kind: "notes.melody")]
        }
    }

    /// The newest ABC document on the run's source song, once one has
    /// landed — the output row is drawn before the run has produced any, and
    /// only offers "View" when there is something to view.
    private var latestScore: TextDocRecord? {
        guard let songId = activeRun?.sourceSongId ?? source?.songId else {
            return nil
        }
        return NotationDocument.newest(in: textStore.docs(for: songId,
                                                          kind: .abc))
    }

    private func open(score doc: TextDocRecord) {
        let songParts = (try? parts.repository.allParts(forSong: doc.ownerId))
            ?? []
        let title = ((try? library.repository.song(id: doc.ownerId)) ?? nil)?
            .title ?? activeRun?.sourceTitle ?? source?.sourceTitle ?? "Notation"
        openScore = NotationDocument.resolve(doc: doc, parts: songParts,
                                             songTitle: title)
    }

    private var explanation: String {
        switch kind {
        case .lyrics:
            "The words land on the track as their own text — the song's own "
                + "lyrics field, which is what a generator was given, is "
                + "never touched."
        case .roundTrip:
            "A model describes your track, and another generates from that "
                + "description alone. What comes back is a cover written by "
                + "a game of telephone with one link."
        case .roundTripEdited:
            "The same, but the run stops so you can rewrite the description "
                + "before any audio is made."
        case .telephone:
            "Each round describes the last take and generates from that "
                + "description — the drift is the point."
        case .abcRoundTrip:
            "The tune becomes notation, and a notation model writes a new "
                + "piece from it. Render the result to hear it."
        case .abcEdited:
            "The same, with the notation handed to you first — change a key, "
                + "a bar or the whole melody before it is composed."
        }
    }

    private func restore() {
        if source == nil, let sourceId {
            source = PickedMaterial.resolve(id: sourceId, parts: parts,
                                            library: library)
        }
        if separatorId == nil { separatorId = settings.defaultSeparatorId }
        if captionerId == nil { captionerId = settings.describerModelId }
        if lyricsModelId == nil {
            lyricsModelId = settings.lyricsTranscriberModelId
        }
        // The parked-for-an-edit draft is seeded by the `pendingEditText`
        // observer in `body`, which covers both arriving at a parked run and
        // a run parking while the page is up — this only ever caught the first.
    }
}

import SwiftUI

/// One source, one music-to-text job, and the words that come back — the
/// page behind every `TextAction` card, the way `TransformActionView` is one
/// page behind every DSP card.
///
/// Two submission paths, chosen by the action (`savesByDefault`):
/// - Persisting actions (describe / tags / extract-abc) go through JobsStore:
///   the job rides the queue, its words land as library rows through the
///   ordinary ingest, and this page shows the newest matching document.
/// - Read-once actions (music→text, ask) run through `MetaJobRunner`: the
///   answer arrives in `result.meta`, lives on this page, and becomes a row
///   only if the user presses "Save to song".
struct TextActionView: View {
    let recipe: Recipe
    let action: TextAction
    let sourceId: String?
    let settings: AppSettings
    let catalog: ModelCatalogStore
    let library: LibraryStore
    let parts: PartsStore
    let jobs: JobsStore
    let textStore: TextStore
    let playback: PlaybackController
    let onOpenModels: () -> Void
    let onUseText: (PrefillBox.Prefill) -> Void
    let onBack: () -> Void

    /// A read-once request's life, page-local on purpose: what MetaJobRunner
    /// returns is a dictionary the asking page reads, and leaving the page is
    /// how you throw it away.
    enum Phase: Equatable {
        case idle
        case working
        case done(TextPayload)
        case failed(String)
    }

    init(recipe: Recipe, action: TextAction, sourceId: String?,
         settings: AppSettings, catalog: ModelCatalogStore,
         library: LibraryStore, parts: PartsStore, jobs: JobsStore,
         textStore: TextStore, playback: PlaybackController,
         onOpenModels: @escaping () -> Void,
         onUseText: @escaping (PrefillBox.Prefill) -> Void,
         onBack: @escaping () -> Void) {
        self.recipe = recipe
        self.action = action
        self.sourceId = sourceId
        self.settings = settings
        self.catalog = catalog
        self.library = library
        self.parts = parts
        self.jobs = jobs
        self.textStore = textStore
        self.playback = playback
        self.onOpenModels = onOpenModels
        self.onUseText = onUseText
        self.onBack = onBack
        _keepOnTrack = State(initialValue: action.savesByDefault)
    }

    /// The caption card's one choice, since "Music → text" folded into
    /// "Describe it by listening": keep the words on the track, or only read
    /// them here. Seeded from the card's action; flipping it swaps between
    /// the persisting caption (`.describe`) and the read-once one
    /// (`.freeCaption`) — the same two the two cards used to hard-code.
    @State private var keepOnTrack: Bool

    /// What actually runs and renders. Only the caption pair participates;
    /// every other action is exactly its card.
    private var effectiveAction: TextAction {
        switch (action, keepOnTrack) {
        case (.describe, false): .freeCaption
        case (.freeCaption, true): .describe
        default: action
        }
    }

    /// Whether this card offers the keep-or-read choice at all.
    private var offersKeepToggle: Bool {
        action == .describe || action == .freeCaption
    }

    @State private var source: PickedMaterial?
    /// The source card's second line, resolved when the source changes.
    ///
    /// `ActionCopy.sourceMeta` is a song read plus an analysis read, and it
    /// was being asked for from inside `body` — which on the Ask card meant
    /// two queries between one keystroke of the question and the next. The
    /// line only depends on the material, so it is resolved with it.
    @State private var sourceMeta: String?
    @State private var selectedModelId: String?
    @State private var question = ""
    @State private var alsoTag = false
    @State private var choosingSource = false
    @State private var submitting = false
    @State private var phase: Phase = .idle
    @State private var request: Task<Void, Never>?
    /// Set at submit for persisting actions, so the result card can tell the
    /// document this run produced from ones that were already there.
    @State private var submittedAt: Date?
    @State private var saved = false
    @AppStorage("actions.lastRuns") private var runsJSON = "{}"
    /// The action log, decoded once rather than at render time.
    ///
    /// It lives in `@AppStorage` as a JSON blob, and the rail was asking for
    /// the whole thing to be parsed from inside `body` — so every redraw
    /// re-decoded it, which on a page with a text field is every keystroke.
    @State private var runLog = ActionRunLog()

    private var slot: Slot? { recipe.slots.first }

    private var eligibleModels: [ModelInfo] {
        catalog.models.filter {
            $0.installState == .installed && action.canRun($0)
        }
    }

    private var model: ModelInfo? {
        eligibleModels.first { $0.id == selectedModelId }
            ?? eligibleModels.first
    }

    /// A tag model for the describe card's "also tag" chip.
    private var tagModel: ModelInfo? {
        catalog.models.first {
            $0.installState == .installed
                && $0.capabilities.supportedTasks.contains("tag")
        }
    }

    private var canRun: Bool {
        guard source != nil, model != nil, !submitting else { return false }
        if action == .ask,
           question.trimmingCharacters(in: .whitespaces).isEmpty {
            return false
        }
        if case .working = phase { return false }
        return true
    }

    var body: some View {
        ActionPage(recipe: recipe, onBack: onBack) {
            ActionSourceCard(
                eyebrow: sourceEyebrow,
                material: source,
                meta: sourceMeta,
                playback: playback,
                placeholder: "A song or a part from your library.",
                chooseTitle: source == nil ? "Choose from Library…" : "Change…",
                onChoose: { choosingSource = true },
                onRemove: source == nil ? nil : { source = nil })
            if eligibleModels.isEmpty {
                ActionModelGate(
                    readiness: catalog.readiness,
                    title: gateTitle,
                    detail: gateDetail,
                    onOpenModels: onOpenModels)
            } else {
                ActionModelPicker(eyebrow: "LISTENER",
                                  models: eligibleModels,
                                  selectedId: Binding(
                                    get: { model?.id },
                                    set: { selectedModelId = $0 }),
                                  meta: modelMeta)
                optionsCard
                resultCard
            }
        } commit: {
            ActionCommitRow(title: commitTitle,
                            costLine: costLine,
                            costSubline: "THE AUDIO IS UNTOUCHED",
                            isEnabled: canRun,
                            error: jobs.lastError ?? phaseError,
                            queueTitle: effectiveAction.savesByDefault
                                ? "Add to queue" : nil,
                            onCommit: { submit(back: false) },
                            onQueue: effectiveAction.savesByDefault
                                ? { submit(back: true) } : nil)
        } rail: {
            ActionRail(outputs: outputs, explanation: explanation,
                       lastRun: runLog.runs[recipe.id])
        }
        .onAppear { restore() }
        .onChange(of: source) {
            sourceMeta = source.map {
                ActionCopy.sourceMeta($0, library: library, parts: parts)
            }
        }
        .onDisappear { request?.cancel() }
        .task { runLog = ActionRunLog.decoded(runsJSON) }
        .onChange(of: runsJSON) { runLog = ActionRunLog.decoded(runsJSON) }
        .sheet(isPresented: $choosingSource) {
            PartPickerSheet(
                slotLabel: slot?.label ?? "Song or part",
                accepts: slot?.accepts ?? [KindPattern(pattern: "song.mix")],
                autoDerive: slot?.autoDerive, catalog: catalog,
                library: library, parts: parts, jobs: jobs,
                playback: playback, onOpenModels: onOpenModels,
                onPick: { source = $0 })
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var optionsCard: some View {
        switch effectiveAction {
        case .ask:
            ActionOptionsCard(eyebrow: "YOUR QUESTION") {
                HStack(spacing: 10) {
                    ActionTextField(
                        placeholder: "What instruments carry the chorus?",
                        text: $question)
                    BenchMenu(label: "Ideas") {
                        ForEach(Self.cannedQuestions, id: \.self) { canned in
                            Button(canned) { question = canned }
                        }
                    }
                }
                ActionFootnote(text: "Answered from the audio itself — the "
                    + "model listens, it does not look anything up.")
            }
        case .describe, .freeCaption:
            ActionOptionsCard {
                ActionCheckChip(label: "Keep the words on the track",
                                isOn: $keepOnTrack)
                if effectiveAction == .describe, tagModel != nil {
                    ActionCheckChip(label: "Also tag genre & mood",
                                    isOn: $alsoTag)
                }
                ActionFootnote(text: footnote)
            }
        default:
            ActionOptionsCard { ActionFootnote(text: footnote) }
        }
    }

    /// The words, once there are words: the landed document for persisting
    /// actions, the in-memory payload for read-once ones.
    @ViewBuilder
    private var resultCard: some View {
        if effectiveAction.savesByDefault {
            if let doc = landedDoc {
                TextResultCard(
                    eyebrow: resultEyebrow,
                    text: doc.text,
                    attribution: "\(doc.modelName) · saved to the "
                        + (doc.ownerType == "song" ? "song" : "part"),
                    monospaced: effectiveAction == .extractABC,
                    onUse: canUseInGenerate
                        ? { useInGenerate(doc.text) } : nil)
            }
        } else {
            switch phase {
            case .idle:
                EmptyView()
            case .working:
                ActionOptionsCard(eyebrow: resultEyebrow) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(workingLine)
                            .font(Bench.Typo.body)
                            .foregroundStyle(Bench.Palette.textFaint)
                    }
                }
            case .done(let payload):
                let text = (payload.text ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                TextResultCard(
                    eyebrow: resultEyebrow,
                    text: text.isEmpty ? "The model heard no words." : text,
                    attribution: model?.displayName ?? "",
                    monospaced: false,
                    onSave: text.isEmpty || saved
                        ? nil : { save(payload) },
                    saveTitle: saved ? "Saved" : "Save to song",
                    onUse: text.isEmpty ? nil : { useInGenerate(text) })
            case .failed(let message):
                ActionOptionsCard(eyebrow: resultEyebrow) {
                    ActionFootnote(text: message, tone: Bench.Palette.warn)
                }
            }
        }
    }

    /// The document this page's last submit produced, if it has landed.
    private var landedDoc: TextDocRecord? {
        guard let source, let submittedAt else { return nil }
        return textStore.docs(for: docOwnerId(source), kind: docKind)
            .first { $0.createdAt >= submittedAt }
    }

    // MARK: - Submit

    private func submit(back: Bool) {
        guard canRun, let source, let model else { return }
        let asked = question.trimmingCharacters(in: .whitespacesAndNewlines)
        submitting = true
        saved = false
        let title = "\(recipe.name): \(source.name)"
        Task {
            defer { submitting = false }
            if effectiveAction.savesByDefault {
                await submitPersisting(source: source, model: model)
            } else {
                await runReadOnce(source: source, model: model,
                                  question: asked.isEmpty ? nil : asked)
            }
            runsJSON = ActionRunLog.recording(
                .init(summary: title,
                      detail: ActionFormat.join(
                        [model.displayName.uppercased(),
                         asked.isEmpty ? nil : "QUESTION"]),
                      at: Date(), sourceId: source.id, modelId: model.id),
                recipeId: recipe.id, in: runsJSON)
            if back { onBack() }
        }
    }

    private func submitPersisting(source: PickedMaterial,
                                  model: ModelInfo) async {
        submittedAt = Date()
        switch effectiveAction {
        case .describe:
            await jobs.submitCaption(
                modelId: model.id, ownerId: docOwnerId(source),
                ownerType: docOwnerType(source), title: source.name,
                sourceURL: source.fileURL)
            if alsoTag, let tagModel {
                await jobs.submitTag(
                    modelId: tagModel.id, ownerId: docOwnerId(source),
                    ownerType: docOwnerType(source), title: source.name,
                    sourceURL: source.fileURL)
            }
        case .tags:
            await jobs.submitTag(
                modelId: model.id, ownerId: docOwnerId(source),
                ownerType: docOwnerType(source), title: source.name,
                sourceURL: source.fileURL)
        case .extractABC:
            // Transcription artifacts (notes + notation) always belong to a
            // song, so a picked part hands off to the song it came from.
            await jobs.submitTranscribe(
                modelId: model.id, songId: source.songId,
                sourceTitle: source.sourceTitle, sourceURL: source.fileURL,
                params: ["emit_abc": .bool(true)])
        case .freeCaption, .ask:
            break
        }
    }

    private func runReadOnce(source: PickedMaterial, model: ModelInfo,
                             question: String?) async {
        guard let client = jobs.client else {
            phase = .failed("Not connected to the engine.")
            return
        }
        guard let uploadId = await jobs.uploadAudio(fileURL: source.fileURL)
        else {
            phase = .failed(jobs.lastError ?? "Could not upload the audio.")
            return
        }
        phase = .working
        var params: [String: JSONValue] = ["source_audio": .string(uploadId)]
        if let question { params["question"] = .string(question) }
        request?.cancel()
        request = Task {
            let outcome = await MetaJobRunner.run(
                client: client, modelId: model.id, task: "caption",
                params: params)
            guard !Task.isCancelled else { return }
            switch outcome {
            case .success(let job):
                if let payload = Self.payload(fromMeta: job.result?.meta) {
                    phase = .done(payload)
                } else {
                    phase = .failed("Nothing usable came back.")
                }
            case .failure(let failure):
                phase = .failed(failure.message)
            }
        }
        await request?.value
    }

    /// `result.meta.text` decoded back into the payload — the read path the
    /// contract provides precisely so nobody re-reads the artifact file.
    static func payload(fromMeta meta: [String: JSONValue]?) -> TextPayload? {
        guard let value = meta?["text"],
              let data = try? BackendClient.encoder.encode(value) else {
            return nil
        }
        return try? BackendClient.decoder.decode(TextPayload.self, from: data)
    }

    private func save(_ payload: TextPayload) {
        guard let source, let model else { return }
        let asked = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let doc = JobsStore.textDoc(
            from: payload,
            context: TextJobContext(
                ownerId: docOwnerId(source),
                ownerType: docOwnerType(source), title: source.name,
                kind: effectiveAction == .ask ? .qa : .caption,
                question: asked.isEmpty ? nil : asked),
            modelId: model.id, modelName: model.displayName, jobId: nil)
        else { return }
        textStore.insert(doc)
        saved = true
    }

    private func useInGenerate(_ text: String) {
        onUseText(.init(
            prompt: text,
            notice: "Written by \(model?.displayName ?? "a describer") "
                + "listening to \(source?.name ?? "your track"). Edit freely."))
    }

    // MARK: - Copy

    private static let cannedQuestions = [
        "What instruments do you hear?",
        "What's the mood of this piece?",
        "What key and tempo is this in?",
        "Write liner notes for this track.",
        "What genre is this, and what does it borrow from?",
    ]

    private func docOwnerId(_ source: PickedMaterial) -> String {
        effectiveAction == .extractABC ? source.songId : source.id
    }

    private func docOwnerType(_ source: PickedMaterial) -> String {
        effectiveAction == .extractABC || source.kind == "song.mix" ? "song" : "part"
    }

    private var docKind: TextDocKind {
        switch effectiveAction {
        case .describe: .description
        case .freeCaption: .caption
        case .ask: .qa
        case .tags: .tags
        case .extractABC: .abc
        }
    }

    private var sourceEyebrow: String {
        effectiveAction == .extractABC ? "AUDIO TO NOTATE" : "AUDIO TO LISTEN TO"
    }

    private var resultEyebrow: String {
        switch effectiveAction {
        case .describe: "WHAT IT HEARD"
        case .freeCaption: "WHAT IT HEARD"
        case .ask: "THE ANSWER"
        case .tags: "TAGS"
        case .extractABC: "NOTATION"
        }
    }

    private var workingLine: String {
        effectiveAction == .ask ? "Listening, then answering…" : "Listening…"
    }

    private func modelMeta(_ candidate: ModelInfo) -> String {
        let estimate = ActionEstimate.taskSeconds(
            model: candidate, sourceDurationS: source?.durationS)
        return ActionFormat.join(["INSTALLED",
                                  ActionFormat.estimate(estimate)])
    }

    private var commitTitle: String {
        switch effectiveAction {
        case .describe: "Describe it"
        case .freeCaption: "Listen and write"
        case .ask: "Ask"
        case .tags: "Tag it"
        case .extractABC: "Extract the notation"
        }
    }

    private var costLine: String? {
        switch effectiveAction {
        case .describe: "SAVED AS A DESCRIPTION ON THE TRACK"
        case .tags: "TAGS LAND ON THE TRACK"
        case .extractABC: "NOTES + NOTATION, ATTACHED TO THE SONG"
        case .freeCaption, .ask: "SHOWN HERE — SAVED ONLY IF YOU SAY SO"
        }
    }

    private var footnote: String {
        switch effectiveAction {
        case .describe:
            "The words are saved as a description slot on the track — edit "
                + "them there, add more slots, or delete them."
        case .tags:
            "Confident labels join the tags you set by hand; the full scored "
                + "list is kept on the track too. Nothing you typed is removed."
        case .extractABC:
            "Transcribes to notes first, then writes each track as ABC — a "
                + "notation sketch, not engraving. A separated stem reads far "
                + "more cleanly than a full mix."
        case .freeCaption, .ask:
            ""
        }
    }

    private var gateTitle: String {
        switch effectiveAction {
        case .describe, .freeCaption, .ask: "No describer is installed"
        case .tags: "No tagging model is installed"
        case .extractABC: "No transcription model is installed"
        }
    }

    private var gateDetail: String {
        switch effectiveAction {
        case .describe, .freeCaption, .ask:
            "These models listen to the audio itself and write prose about "
                + "it — unlike the writing assistant, which only reads the "
                + "measurements."
        case .tags:
            "The zero-shot tagger scores your audio against genre, mood and "
                + "instrument vocabularies with CLAP — small, fast and free."
        case .extractABC:
            "Any note transcriber can also write its result as ABC notation "
                + "text."
        }
    }

    private var explanation: String {
        switch effectiveAction {
        case .describe:
            "A description slot on the track, searchable like your notes — "
                + "and the writing assistant quotes it from then on."
        case .freeCaption, .ask:
            "Words on this page. Keep them with “Save to song”, or send "
                + "them straight into Generate."
        case .tags:
            "Labels merged into the track's tags, plus the full scored list."
        case .extractABC:
            "Notes parts in Library › Parts and the notation as text on the "
                + "song — ready for ABC → generate."
        }
    }

    private var outputs: [ActionOutput] {
        switch effectiveAction {
        case .describe:
            [ActionOutput(id: "doc", name: "Description", meta: "TEXT")]
        case .freeCaption:
            [ActionOutput(id: "doc", name: "Caption", meta: "TEXT")]
        case .ask:
            [ActionOutput(id: "doc", name: "Answer", meta: "TEXT")]
        case .tags:
            [ActionOutput(id: "doc", name: "Tags", meta: "LABELS + SCORES")]
        case .extractABC:
            [ActionOutput(id: "notes", name: "Notes parts", meta: "MIDI",
                          kind: "notes.melody"),
             ActionOutput(id: "abc", name: "ABC notation", meta: "TEXT")]
        }
    }

    private var canUseInGenerate: Bool {
        effectiveAction == .describe || effectiveAction == .freeCaption
    }

    private var phaseError: String? {
        if case .failed(let message) = phase { return message }
        return nil
    }

    private func restore() {
        if source == nil, let sourceId {
            source = PickedMaterial.resolve(id: sourceId, parts: parts,
                                            library: library)
        }
        if selectedModelId == nil {
            selectedModelId = recipe.prefersModelIds
                .first { id in eligibleModels.contains { $0.id == id } }
                ?? eligibleModels.first?.id
        }
    }
}

/// The words a run produced, with what to do next. Shared by this page and
/// the compare grid.
struct TextResultCard: View {
    let eyebrow: String
    let text: String
    var attribution: String = ""
    var monospaced = false
    var onSave: (() -> Void)?
    var saveTitle = "Save to song"
    var onUse: (() -> Void)?

    var body: some View {
        ActionOptionsCard(eyebrow: eyebrow) {
            Text(text)
                .font(monospaced ? Bench.Typo.mono(12) : Bench.Typo.body)
                .foregroundStyle(Bench.Palette.textPrimary)
                .lineSpacing(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 10) {
                if !attribution.isEmpty {
                    Text(attribution.uppercased())
                        .font(Bench.Typo.mono(10))
                        .foregroundStyle(Bench.Palette.textFaintest)
                }
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                .buttonStyle(BenchSecondaryButtonStyle(tone: .quiet))
                if let onSave {
                    Button(saveTitle, action: onSave)
                        .buttonStyle(BenchSecondaryButtonStyle(tone: .quiet))
                }
                if let onUse {
                    Button("Use in Generate", action: onUse)
                        .buttonStyle(BenchSecondaryButtonStyle())
                }
            }
        }
    }
}

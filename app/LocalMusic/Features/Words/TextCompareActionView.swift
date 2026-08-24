import SwiftUI

/// One track through every describer you tick — the text-model sibling of
/// CompareActionView, for the same reason that page exists: hearing (here,
/// reading) the same input through different models side by side is the
/// comparison the app is for.
///
/// Every run is read-once (`MetaJobRunner`): nothing lands in the library
/// until a result earns its "Save to song". The runs are fired concurrently;
/// the engine queues them serially and the grid fills in as answers arrive.
struct TextCompareActionView: View {
    let recipe: Recipe
    let sourceId: String?
    let catalog: ModelCatalogStore
    let library: LibraryStore
    let parts: PartsStore
    let jobs: JobsStore
    let textStore: TextStore
    let playback: PlaybackController
    let onOpenModels: () -> Void
    let onUseText: (PrefillBox.Prefill) -> Void
    let onBack: () -> Void

    struct Entry: Identifiable, Equatable {
        let id: String            // model id
        let modelName: String
        var phase: TextActionView.Phase = .idle
        var saved = false
    }

    @State private var source: PickedMaterial?
    @State private var tickedIds: Set<String> = []
    @State private var question = ""
    @State private var entries: [Entry] = []
    @State private var choosingSource = false
    @State private var running = false
    @State private var requests: [Task<Void, Never>] = []
    @AppStorage("actions.lastRuns") private var runsJSON = "{}"

    private var slot: Slot? { recipe.slots.first }

    private var describers: [ModelInfo] {
        catalog.models.filter {
            $0.installState == .installed
                && $0.capabilities.supportedTasks.contains("caption")
        }
    }

    private var chosen: [ModelInfo] {
        describers.filter { tickedIds.contains($0.id) }
    }

    private var canRun: Bool {
        source != nil && chosen.count >= 2 && !running
    }

    var body: some View {
        ActionPage(recipe: recipe, onBack: onBack) {
            ActionSourceCard(
                eyebrow: "AUDIO TO LISTEN TO",
                material: source,
                meta: source.map {
                    ActionCopy.sourceMeta($0, library: library, parts: parts)
                },
                playback: playback,
                placeholder: "A song or a part from your library.",
                chooseTitle: source == nil ? "Choose from Library…" : "Change…",
                onChoose: { choosingSource = true },
                onRemove: source == nil ? nil : { source = nil })
            describersCard
            ActionOptionsCard(eyebrow: "OPTIONAL QUESTION") {
                ActionTextField(
                    placeholder: "Leave empty for a plain description",
                    text: $question)
            }
            resultsGrid
        } commit: {
            ActionCommitRow(
                title: running ? "Listening…" : "Run the comparison",
                costLine: ActionFormat.join([
                    chosen.count >= 2 ? "\(chosen.count) DESCRIBERS" : nil,
                    "ONE AT A TIME ON THE ENGINE",
                    "SHOWN HERE — SAVED ONLY IF YOU SAY SO"]),
                costSubline: "THE AUDIO IS UNTOUCHED",
                isEnabled: canRun,
                error: jobs.lastError,
                queueTitle: nil,
                onCommit: submit,
                onQueue: nil)
        } rail: {
            ActionRail(
                outputs: chosen.map {
                    ActionOutput(id: $0.id, name: $0.displayName,
                                 meta: "TEXT")
                },
                explanation: "One answer per describer, side by side. Save "
                    + "the ones worth keeping; the rest vanish when you "
                    + "leave.",
                lastRun: ActionRunLog.decoded(runsJSON).runs[recipe.id])
        }
        .onAppear { restore() }
        .onDisappear { requests.forEach { $0.cancel() } }
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

    private var describersCard: some View {
        ActionOptionsCard(eyebrow: "DESCRIBERS") {
            ForEach(describers, id: \.id) { model in
                ActionCheckChip(
                    label: model.displayName,
                    isOn: Binding(
                        get: { tickedIds.contains(model.id) },
                        set: { ticked in
                            if ticked { tickedIds.insert(model.id) }
                            else { tickedIds.remove(model.id) }
                        }))
            }
            if describers.count < 2 {
                ActionFootnote(
                    text: "Two is the least that can be compared — install "
                        + "a second describer.",
                    tone: Bench.Palette.warn)
            }
        }
    }

    @ViewBuilder
    private var resultsGrid: some View {
        ForEach(entries) { entry in
            switch entry.phase {
            case .idle:
                EmptyView()
            case .working:
                ActionOptionsCard(eyebrow: entry.modelName.uppercased()) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Listening…")
                            .font(Bench.Typo.body)
                            .foregroundStyle(Bench.Palette.textFaint)
                    }
                }
            case .done(let payload):
                let text = (payload.text ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                TextResultCard(
                    eyebrow: entry.modelName.uppercased(),
                    text: text.isEmpty ? "The model heard no words." : text,
                    onSave: text.isEmpty || entry.saved
                        ? nil : { save(entry: entry, payload: payload) },
                    saveTitle: entry.saved ? "Saved" : "Save to song",
                    onUse: text.isEmpty ? nil : {
                        onUseText(.init(
                            prompt: text, modelId: nil,
                            notice: "Written by \(entry.modelName) listening "
                                + "to \(source?.name ?? "your track")."))
                    })
            case .failed(let message):
                ActionOptionsCard(eyebrow: entry.modelName.uppercased()) {
                    ActionFootnote(text: message, tone: Bench.Palette.warn)
                }
            }
        }
    }

    private func submit() {
        guard canRun, let source, let client = jobs.client else { return }
        let asked = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let models = chosen
        entries = models.map {
            Entry(id: $0.id, modelName: $0.displayName, phase: .working)
        }
        running = true
        requests.forEach { $0.cancel() }
        requests = []
        Task {
            // One upload, shared by every run — the id resolves per job.
            guard let uploadId = await jobs.uploadAudio(fileURL: source.fileURL)
            else {
                for index in entries.indices {
                    entries[index].phase = .failed(
                        jobs.lastError ?? "Could not upload the audio.")
                }
                running = false
                return
            }
            var params: [String: JSONValue] = [
                "source_audio": .string(uploadId),
            ]
            if !asked.isEmpty { params["question"] = .string(asked) }
            for model in models {
                let task = Task {
                    let outcome = await MetaJobRunner.run(
                        client: client, modelId: model.id, task: "caption",
                        params: params)
                    guard !Task.isCancelled else { return }
                    guard let index = entries.firstIndex(where: {
                        $0.id == model.id
                    }) else { return }
                    switch outcome {
                    case .success(let job):
                        if let payload = TextActionView.payload(
                            fromMeta: job.result?.meta) {
                            entries[index].phase = .done(payload)
                        } else {
                            entries[index].phase = .failed(
                                "Nothing usable came back.")
                        }
                    case .failure(let failure):
                        entries[index].phase = .failed(failure.message)
                    }
                }
                requests.append(task)
            }
            for task in requests { await task.value }
            running = false
            runsJSON = ActionRunLog.recording(
                .init(summary: "\(recipe.name): \(source.name)",
                      detail: ActionFormat.join([
                        "\(models.count) DESCRIBERS",
                        asked.isEmpty ? nil : "QUESTION"]),
                      at: Date(), sourceId: source.id, modelId: nil),
                recipeId: recipe.id, in: runsJSON)
        }
    }

    private func save(entry: Entry, payload: TextPayload) {
        guard let source else { return }
        let asked = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let doc = JobsStore.textDoc(
            from: payload,
            context: TextJobContext(
                ownerId: source.id,
                ownerType: source.kind == "song.mix" ? "song" : "part",
                title: source.name,
                kind: asked.isEmpty ? .caption : .qa,
                question: asked.isEmpty ? nil : asked),
            modelId: entry.id, modelName: entry.modelName, jobId: nil)
        else { return }
        textStore.insert(doc)
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index].saved = true
        }
    }

    private func restore() {
        if source == nil, let sourceId {
            source = PickedMaterial.resolve(id: sourceId, parts: parts,
                                            library: library)
        }
        if tickedIds.isEmpty {
            tickedIds = Set(describers.prefix(3).map(\.id))
        }
    }
}

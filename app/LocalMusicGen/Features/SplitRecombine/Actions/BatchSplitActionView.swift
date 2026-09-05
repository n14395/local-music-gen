import SwiftUI

/// "Split several at once" — separation over a whole selection.
///
/// Every other separation card takes one song, which is the right shape for
/// one song and the wrong one for a folder of imports. This is one job per
/// track, queued in one press: the engine runs them in turn on a warm worker,
/// which is far cheaper than a person queueing twenty by hand and much cheaper
/// than the engine loading the model twenty times.
struct BatchSplitActionView: View {
    let recipe: Recipe
    let catalog: ModelCatalogStore
    let library: LibraryStore
    let parts: PartsStore
    let jobs: JobsStore
    let playback: PlaybackController
    /// Rows the Library had ticked when this page was opened from the Track
    /// menu. Seeded once, on appear — a preselection that reasserted itself
    /// would fight the tick you just made here.
    var preselected: Set<String> = []
    let onOpenModels: () -> Void
    let onBack: () -> Void

    @State private var picked: Set<String> = []
    @State private var didSeedPicked = false
    @State private var selectedModelId: String?
    @State private var query = ""
    @State private var submitting = false
    @AppStorage("actions.lastRuns") private var runsJSON = "{}"
    /// The action log, decoded once rather than at render time.
    ///
    /// It lives in `@AppStorage` as a JSON blob, and the rail was asking for
    /// the whole thing to be parsed from inside `body` — so every redraw
    /// re-decoded it, which on a page with a text field is every keystroke.
    @State private var runLog = ActionRunLog()

    private var eligible: [ModelInfo] {
        catalog.models.filter {
            $0.installState == .installed
                && $0.capabilities.supportedTasks.contains("separate")
        }
    }

    private var model: ModelInfo? {
        eligible.first { $0.id == selectedModelId } ?? eligible.first
    }

    /// Whole songs only. A stem is already the output of a separation, and
    /// offering to separate one again is offering a job whose result is the
    /// thing you started with.
    private var songs: [SongRecord] {
        let all = library.recent
        guard !query.isEmpty else { return all }
        return all.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.prompt.localizedCaseInsensitiveContains(query)
        }
    }

    private var chosen: [SongRecord] { songs.filter { picked.contains($0.id) } }

    var body: some View {
        ActionPage(recipe: recipe, onBack: onBack) {
            if eligible.isEmpty {
                ActionModelGate(
                    readiness: catalog.readiness,
                    title: "No separation model is installed",
                    detail: "Demucs is 84 MB and splits a song into vocals, "
                        + "drums, bass and the rest.",
                    onOpenModels: onOpenModels)
            } else {
                trackList
                ActionModelPicker(eyebrow: "SEPARATOR", models: eligible,
                                  selectedId: Binding(
                                    get: { model?.id },
                                    set: { selectedModelId = $0 }),
                                  meta: { candidate in
                                      ActionFormat.join([
                                        "INSTALLED",
                                        ActionFormat.estimate(
                                            estimate(with: candidate))])
                                  })
            }
        } commit: {
            ActionCommitRow(title: picked.isEmpty
                                ? "Split"
                                : "Split \(chosen.count) "
                                    + (chosen.count == 1 ? "track" : "tracks"),
                            costLine: ActionFormat.join([
                                ActionFormat.estimate(estimate(with: model)),
                                "SAVED TO LIBRARY › PARTS"]),
                            costSubline: "ONE JOB PER TRACK · THEY RUN IN TURN",
                            isEnabled: !chosen.isEmpty && model != nil
                                && !submitting,
                            error: jobs.lastError,
                            queueTitle: nil,
                            onCommit: submit)
        } rail: {
            ActionRail(outputs: outputs,
                       explanation: "Each track's parts land in Library › "
                            + "Parts, grouped under the song they came from.",
                       lastRun: runLog.runs[recipe.id])
        }
        .onAppear {
            if selectedModelId == nil { selectedModelId = eligible.first?.id }
            if !didSeedPicked {
                didSeedPicked = true
                if picked.isEmpty { picked = preselected }
            }
        }
        .task { runLog = ActionRunLog.decoded(runsJSON) }
        .onChange(of: runsJSON) { runLog = ActionRunLog.decoded(runsJSON) }
    }

    private var trackList: some View {
        ActionOptionsCard(eyebrow: "TRACKS — \(chosen.count) TICKED") {
            HStack(spacing: 10) {
                BenchTextField(text: $query, placeholder: "Filter…")
                Spacer(minLength: 8)
                Button(picked.isEmpty ? "Select all" : "Clear") {
                    picked = picked.isEmpty ? Set(songs.map(\.id)) : []
                }
                .buttonStyle(.bench(.quiet))
            }
            if songs.isEmpty {
                ActionFootnote(text: query.isEmpty
                    ? "Nothing in the library yet. Import some audio or "
                        + "generate a track first."
                    : "No track matches “\(query)”.")
            } else {
                // Bounded on purpose: this is a picker, not the Library, and
                // a scroll view inside a scrolling page is a trap.
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(songs) { song in row(song) }
                    }
                }
                .frame(maxHeight: 260)
            }
        }
    }

    private func row(_ song: SongRecord) -> some View {
        let isOn = picked.contains(song.id)
        return Button {
            if isOn { picked.remove(song.id) } else { picked.insert(song.id) }
        } label: {
            HStack(spacing: 11) {
                LibraryCheckbox(isOn: isOn) {
                    if isOn { picked.remove(song.id) } else { picked.insert(song.id) }
                }
                .allowsHitTesting(false)
                Text(song.title)
                    .font(Bench.Typo.body)
                    .foregroundStyle(Bench.Palette.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(ActionFormat.length(song.durationS))
                    .font(Bench.Typo.mono(10))
                    .foregroundStyle(Bench.Palette.textFaintest)
                    .fixedSize()
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.row,
                                         style: .continuous)
                .fill(isOn ? Bench.Palette.accent.opacity(0.07) : .clear))
        }
        .buttonStyle(.plain)
    }

    /// Every ticked track's estimate, added up — the number that matters is
    /// the wait, and the wait is the whole queue.
    private func estimate(with model: ModelInfo?) -> Double? {
        guard let model, !chosen.isEmpty else { return nil }
        let each = chosen.compactMap {
            ActionEstimate.taskSeconds(model: model,
                                       sourceDurationS: $0.durationS)
        }
        return each.isEmpty ? nil : each.reduce(0, +)
    }

    private var outputs: [ActionOutput] {
        chosen.prefix(4).map {
            ActionOutput(id: $0.id, name: $0.title,
                         meta: "PARTS", kind: "stem.*")
        }
    }

    private func submit() {
        guard let model, !chosen.isEmpty else { return }
        submitting = true
        let tracks = chosen
        Task {
            for song in tracks {
                await jobs.submitSplit(modelId: model.id, songId: song.id,
                                       sourceTitle: song.title,
                                       sourceURL: song.fileURL, params: [:])
            }
            submitting = false
            runsJSON = ActionRunLog.recording(
                .init(summary: "\(tracks.count) tracks",
                      detail: model.displayName.uppercased(), at: Date(),
                      sourceId: tracks.first?.id, modelId: model.id),
                recipeId: recipe.id, in: runsJSON)
            onBack()
        }
    }
}

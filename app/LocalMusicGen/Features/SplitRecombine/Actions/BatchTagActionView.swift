import SwiftUI

/// "Tag the whole library" — genre and mood chips over a whole selection.
///
/// The tag card takes one song; this is one `tag` job per ticked track,
/// queued in one press, exactly the `BatchSplitActionView` shape. The warm
/// worker pool keeps the tagger loaded between jobs (it is small-pool
/// eligible), and the Essentia adapter caches its embedding per file, so a
/// second sweep of the same library costs almost nothing.
struct BatchTagActionView: View {
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
    @State private var untaggedOnly = true
    @State private var submitting = false
    /// Which songs have no tags yet, read once rather than asked per row.
    ///
    /// `songs` is read by the eyebrow count, the "Select all" button, the
    /// commit title and the list itself, and it was answering "is this one
    /// untagged?" with a query per track on each of those — so a library of a
    /// hundred songs cost hundreds of round trips per redraw, and the filter
    /// field above the list redraws on every keystroke.
    @State private var untaggedIds: Set<String> = []
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
                && $0.capabilities.supportedTasks.contains("tag")
        }
    }

    private var model: ModelInfo? {
        (eligible.first { $0.id == selectedModelId })
            ?? recipe.prefersModelIds
                .compactMap { id in eligible.first { $0.id == id } }.first
            ?? eligible.first
    }

    private var songs: [SongRecord] {
        var all = library.recent
        if untaggedOnly {
            all = all.filter { untaggedIds.contains($0.id) }
        }
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
                    title: "No tagging model is installed",
                    detail: "The Essentia tagger is ~25 MB and labels genre, "
                        + "mood and instrumentation in seconds per song.",
                    onOpenModels: onOpenModels)
            } else {
                trackList
                ActionModelPicker(eyebrow: "TAGGER", models: eligible,
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
                                ? "Tag"
                                : "Tag \(chosen.count) "
                                    + (chosen.count == 1 ? "track" : "tracks"),
                            costLine: ActionFormat.join([
                                ActionFormat.estimate(estimate(with: model)),
                                "LABELS LAND IN THE TAGS FIELD"]),
                            costSubline: "ONE JOB PER TRACK · THEY RUN IN TURN",
                            isEnabled: !chosen.isEmpty && model != nil
                                && !submitting,
                            error: jobs.lastError,
                            queueTitle: nil,
                            onCommit: submit)
        } rail: {
            ActionRail(outputs: outputs,
                       explanation: "Labels merge into the same tag field "
                            + "you edit by hand — nothing is overwritten, "
                            + "and the full scored list is kept as a "
                            + "document on each song.",
                       lastRun: runLog.runs[recipe.id])
        }
        .onAppear {
            if selectedModelId == nil { selectedModelId = model?.id }
            if !didSeedPicked {
                didSeedPicked = true
                if picked.isEmpty { picked = preselected }
                // A preselection made in the Library is a deliberate set, and
                // the untagged filter would silently drop half of it.
                if !picked.isEmpty { untaggedOnly = false }
            }
            refreshUntagged()
        }
        .onChange(of: untaggedOnly) { refreshUntagged() }
        .onChange(of: library.recent) { refreshUntagged() }
        .task { runLog = ActionRunLog.decoded(runsJSON) }
        .onChange(of: runsJSON) { runLog = ActionRunLog.decoded(runsJSON) }
    }

    private func refreshUntagged() {
        untaggedIds = (try? library.repository.untaggedSongIds()) ?? []
    }

    private var trackList: some View {
        ActionOptionsCard(eyebrow: "TRACKS — \(chosen.count) TICKED") {
            HStack(spacing: 10) {
                BenchTextField(text: $query, placeholder: "Filter…")
                ActionCheckChip(label: "Untagged only", isOn: $untaggedOnly,
                                disabledReason: nil)
                Spacer(minLength: 8)
                Button(picked.isEmpty ? "Select all" : "Clear") {
                    picked = picked.isEmpty ? Set(songs.map(\.id)) : []
                }
                .buttonStyle(.bench(.quiet))
            }
            if songs.isEmpty {
                ActionFootnote(text: untaggedOnly && query.isEmpty
                    ? "Everything in the library already has tags. Untick "
                        + "“Untagged only” to re-tag."
                    : query.isEmpty
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
            ActionOutput(id: $0.id, name: $0.title, meta: "TAGS")
        }
    }

    private func submit() {
        guard let model, !chosen.isEmpty else { return }
        submitting = true
        let tracks = chosen
        Task {
            for song in tracks {
                await jobs.submitTag(modelId: model.id, ownerId: song.id,
                                     ownerType: "song", title: song.title,
                                     sourceURL: song.fileURL)
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

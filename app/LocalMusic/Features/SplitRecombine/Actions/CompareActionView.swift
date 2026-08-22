import SwiftUI

/// "Compare models on one prompt" — the comparison this app exists to make,
/// as one click instead of five round trips through Generate.
///
/// The only Generate card that is a page rather than a door. Every other one
/// carries a preset into the composer, because the settings behind it are
/// worth keeping. A comparison is not like that: it is a prompt and a set of
/// ticks, run once, and what you keep afterwards is the takes.
///
/// One job per model rather than one job with many takes, because a job
/// belongs to exactly one model (contract §5.1). They queue in the order they
/// are ticked and run one at a time — this Mac has one GPU, and the engine's
/// warm-worker discipline is the whole reason a comparison takes minutes
/// rather than hours of thrash.
struct CompareActionView: View {
    let recipe: Recipe
    let catalog: ModelCatalogStore
    let library: LibraryStore
    let jobs: JobsStore
    let playback: PlaybackController
    let onOpenModels: () -> Void
    let onBack: () -> Void

    @State private var prompt = ""
    @State private var picked: Set<String> = []
    @State private var durationS: Double = 15
    @State private var submitting = false
    @AppStorage("actions.lastRuns") private var runsJSON = "{}"

    private var eligible: [ModelInfo] {
        GenerateNeed().eligible(catalog.models)
            .sorted { $0.displayName < $1.displayName }
    }

    private var chosen: [ModelInfo] {
        eligible.filter { picked.contains($0.id) }
    }

    /// The length every model in the comparison can actually manage.
    ///
    /// Clamped to the *intersection* rather than to each model's own range: a
    /// comparison where one take is thirty seconds and another is two minutes
    /// is not a comparison, it is two different questions. Nil while nothing
    /// is ticked.
    private var sharedRange: ClosedRange<Double>? {
        guard !chosen.isEmpty else { return nil }
        let low = chosen.map(\.capabilities.duration.minS).max() ?? 0
        let high = chosen.map(\.capabilities.duration.maxS).min() ?? 0
        guard low <= high else { return nil }
        return low...high
    }

    private var canRun: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && chosen.count >= 2 && sharedRange != nil && !submitting
    }

    var body: some View {
        ActionPage(recipe: recipe, onBack: onBack) {
            if eligible.count < 2 {
                ActionModelGate(
                    readiness: catalog.readiness,
                    title: eligible.isEmpty
                        ? "Nothing installed can generate audio"
                        : "Only one model is installed",
                    detail: "A comparison needs at least two. Install a "
                        + "second and every take lands side by side in the "
                        + "Library, ready for the A/B in the transport bar.",
                    onOpenModels: onOpenModels)
            } else {
                promptCard
                modelsCard
                lengthCard
            }
        } commit: {
            ActionCommitRow(title: chosen.count >= 2
                                ? "Generate \(chosen.count) takes"
                                : "Generate",
                            costLine: costLine,
                            costSubline: "ONE JOB PER MODEL · THEY RUN IN TURN",
                            isEnabled: canRun,
                            error: jobs.lastError,
                            queueTitle: nil,
                            onCommit: submit)
        } rail: {
            ActionRail(outputs: outputs,
                       explanation: "One take per model, all on the same "
                            + "prompt, seed and length — so the only thing "
                            + "that differs between them is the model.",
                       lastRun: ActionRunLog.decoded(runsJSON).runs[recipe.id])
        }
        .onAppear {
            // Two is the point of the card, so it opens with two ticked
            // rather than with an empty list and a disabled button.
            if picked.isEmpty { picked = Set(eligible.prefix(2).map(\.id)) }
            snapDuration()
        }
        .onChange(of: picked) { snapDuration() }
    }

    private var promptCard: some View {
        ActionOptionsCard(eyebrow: "PROMPT") {
            StudioPromptEditor(text: $prompt, font: Bench.Typo.promptCompact)
        }
    }

    private var modelsCard: some View {
        ActionOptionsCard(eyebrow: "MODELS — \(chosen.count) TICKED") {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(eligible) { model in
                    modelRow(model)
                }
            }
            ActionFootnote(
                text: "Every installed model that generates from a "
                    + "description. Ticking more is more minutes, not more "
                    + "memory — they run one after another.")
        }
    }

    private func modelRow(_ model: ModelInfo) -> some View {
        let isOn = picked.contains(model.id)
        let duration = model.capabilities.duration
        return Button {
            if isOn { picked.remove(model.id) } else { picked.insert(model.id) }
        } label: {
            HStack(spacing: 11) {
                LibraryCheckbox(isOn: isOn) {
                    if isOn { picked.remove(model.id) } else { picked.insert(model.id) }
                }
                .allowsHitTesting(false)
                Text(model.displayName)
                    .font(Bench.Typo.body)
                    .foregroundStyle(Bench.Palette.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(ActionFormat.join([
                    model.capabilities.supportsLyrics ? "LYRICS" : nil,
                    "\(Int(duration.minS))–\(Int(duration.maxS)) S"]))
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

    @ViewBuilder
    private var lengthCard: some View {
        ActionOptionsCard(eyebrow: "LENGTH") {
            if let sharedRange {
                HStack(spacing: 12) {
                    BenchSlider(value: $durationS, range: sharedRange,
                                step: 1)
                    Text("\(Int(durationS.rounded())) S")
                        .font(Bench.Typo.value)
                        .foregroundStyle(Bench.Palette.textPrimary)
                        .frame(width: 54, alignment: .trailing)
                }
                ActionFootnote(
                    text: "\(Int(sharedRange.lowerBound))–"
                        + "\(Int(sharedRange.upperBound)) s is what every "
                        + "ticked model can manage. Untick the narrowest to "
                        + "widen it.")
            } else {
                ActionFootnote(
                    text: "These models share no length they can all render. "
                        + "Untick one — a comparison at two different lengths "
                        + "is two different questions.",
                    tone: Bench.Palette.warn)
            }
        }
    }

    private var outputs: [ActionOutput] {
        chosen.map { model in
            ActionOutput(id: model.id, name: model.displayName,
                         meta: "\(Int(durationS.rounded())) S · WAV",
                         kind: "song.mix")
        }
    }

    private var costLine: String? {
        guard !chosen.isEmpty else { return nil }
        let total = chosen.compactMap {
            ActionEstimate.generativeSeconds(model: $0, durationS: durationS)
        }.reduce(0, +)
        return ActionFormat.join([
            total > 0 ? ActionFormat.estimate(total) : nil,
            "SAVED TO LIBRARY › GENERATED"])
    }

    /// Keep the chosen length inside what every ticked model can render.
    private func snapDuration() {
        guard let sharedRange else { return }
        durationS = durationS.clamped(to: sharedRange)
    }

    private func submit() {
        guard canRun else { return }
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        // One seed across the whole comparison, so the only variable is the
        // model. Drawn once here rather than left to each engine's default,
        // which would be a different number per job.
        let seed = Int.random(in: 1...2_000_000_000)
        submitting = true
        let models = chosen
        Task {
            for model in models {
                var params: [String: JSONValue] = [:]
                if model.capabilities.params.contains(where: { $0.key == "seed" }) {
                    params["seed"] = .int(seed)
                }
                await jobs.submit(modelId: model.id, prompt: text,
                                  lyrics: nil, durationS: durationS,
                                  count: 1, params: params)
            }
            submitting = false
            runsJSON = ActionRunLog.recording(
                .init(summary: text,
                      detail: ActionFormat.join([
                        "\(models.count) MODELS",
                        "\(Int(durationS.rounded())) S",
                        "SEED \(seed)"]),
                      at: Date(), sourceId: nil, modelId: nil),
                recipeId: recipe.id, in: runsJSON)
            onBack()
        }
    }
}

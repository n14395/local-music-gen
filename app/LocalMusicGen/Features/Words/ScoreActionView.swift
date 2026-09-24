// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// "Score against its prompt": how close a render actually landed to the
/// words that asked for it, as a CLAP cosine between the prompt's text
/// embedding and the audio's.
///
/// The number is the point of the app made measurable — four models on one
/// prompt can finally be ranked by something other than taste. It is a
/// *similarity*, not a mark out of ten: 0.3 is a good score, and the copy
/// says so rather than letting a 30% read as a failure.
struct ScoreActionView: View {
    let recipe: Recipe
    let sourceId: String?
    let settings: AppSettings
    let catalog: ModelCatalogStore
    let library: LibraryStore
    let parts: PartsStore
    let jobs: JobsStore
    let playback: PlaybackController
    let onOpenModels: () -> Void
    let onBack: () -> Void

    struct Row: Identifiable, Equatable {
        let id: String
        let title: String
        let prompt: String
        var score: Double?
    }

    @State private var source: PickedMaterial?
    /// The source card's second line, resolved when the source changes.
    ///
    /// `ActionCopy.sourceMeta` is a song read plus an analysis read, and asked
    /// for from inside `body` it ran on every pass of a page that has text
    /// fields on it. The line only depends on the material, so it is resolved
    /// with it.
    @State private var sourceMeta: String?
    @State private var promptText = ""
    @State private var choosingSource = false
    @State private var submitting = false
    @State private var batching = false
    @State private var batchDone = 0
    @State private var batchTotal = 0
    @AppStorage("actions.lastRuns") private var runsJSON = "{}"

    private var slot: Slot? { recipe.slots.first }

    /// Only a CLAP-equipped analyzer can score a prompt — the param is the
    /// honest test for it, the way `mix_spec` distinguishes the mixdown.
    private var scorer: ModelInfo? {
        catalog.models.first {
            $0.installState == .installed
                && $0.capabilities.supportedTasks.contains("analyze")
                && $0.capabilities.params.contains { $0.key == "prompt_text" }
        }
    }

    private var storedPayload: AnalysisPayload? {
        guard let source else { return nil }
        return Self.payload(ownerId: source.id, parts: parts)
    }

    /// The score already on the track, when it was measured against the text
    /// in the field — a different prompt means the number is about a
    /// different question.
    private var currentScore: Double? {
        guard let payload = storedPayload, let score = payload.clapPromptScore,
              let scored = payload.clapPrompt,
              scored.trimmingCharacters(in: .whitespacesAndNewlines)
                == promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return nil }
        return score
    }

    private var canRun: Bool {
        source != nil && scorer != nil && !submitting && !batching
            && !promptText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        ActionPage(recipe: recipe, onBack: onBack) {
            ActionSourceCard(
                eyebrow: "THE RENDER",
                material: source,
                meta: sourceMeta,
                playback: playback,
                placeholder: "A generated track, and the words that asked "
                    + "for it.",
                chooseTitle: source == nil ? "Choose from Library…" : "Change…",
                onChoose: { choosingSource = true },
                onRemove: source == nil ? nil : { source = nil })
            if scorer == nil {
                ActionModelGate(
                    readiness: catalog.readiness,
                    title: "No prompt-scoring analyzer is installed",
                    detail: "Scoring needs the analyzer variant that also "
                        + "computes a CLAP embedding — the same one that "
                        + "powers timbre matching.",
                    onOpenModels: onOpenModels)
            } else {
                promptCard
                scoreCard
                batchCard
            }
        } commit: {
            ActionCommitRow(title: submitting ? "Scoring…" : "Score it",
                            costLine: costLine,
                            costSubline: "RE-ANALYSES THE TRACK",
                            isEnabled: canRun,
                            error: jobs.lastError,
                            queueTitle: nil,
                            onCommit: score,
                            onQueue: nil)
        } rail: {
            ActionRail(
                outputs: [ActionOutput(id: "score", name: "Adherence score",
                                       meta: "CLAP COSINE")],
                explanation: "A similarity between the prompt's words and "
                    + "the audio, stored with the track's analysis. Compare "
                    + "scores against each other, never against 100% — even "
                    + "a perfect match sits well below it.",
                lastRun: ActionRunLog.decoded(runsJSON).runs[recipe.id])
        }
        .onAppear { restore() }
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
                playback: playback,
                onOpenModels: onOpenModels,
                onPick: { picked in
                    source = picked
                    promptText = Self.prompt(for: picked, library: library)
                })
        }
    }

    // MARK: - Cards

    private var promptCard: some View {
        ActionOptionsCard(eyebrow: "SCORE AGAINST THESE WORDS") {
            ActionTextField(placeholder: "The prompt this track was made from",
                            text: $promptText)
            ActionFootnote(text: "Prefilled from the track's own prompt when "
                + "it has one. Change it to ask a different question — “is "
                + "this actually a waltz?” is a fair thing to measure.")
        }
    }

    @ViewBuilder
    private var scoreCard: some View {
        if let score = currentScore {
            ActionOptionsCard(eyebrow: "HOW CLOSE IT LANDED") {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(String(format: "%.2f", score))
                        .font(Bench.Typo.promptHero)
                        .foregroundStyle(Bench.Palette.textPrimary)
                    Text(Self.verdict(score))
                        .font(Bench.Typo.body)
                        .foregroundStyle(Bench.Palette.textFaint)
                }
                ActionFootnote(text: "CLAP cosine, −1 to 1. Anything above "
                    + "0.25 is a recognisable match; the useful comparison is "
                    + "between two takes of the same prompt.")
            }
        }
    }

    /// The batch: every generated track scored against its own prompt, so a
    /// library can be sorted by how well the model listened.
    private var batchCard: some View {
        ActionOptionsCard(eyebrow: "THE WHOLE LIBRARY") {
            ActionFootnote(text: batching
                ? "Scoring \(batchDone) of \(batchTotal)…"
                : "Scores every generated track against the prompt it was "
                    + "made from. Tracks already scored against that exact "
                    + "prompt are skipped; the rest are re-analysed, which "
                    + "takes a moment each.")
            Button(batching ? "Scoring…" : "Score every generated track") {
                scoreEverything()
            }
            .buttonStyle(BenchSecondaryButtonStyle(tone: .quiet))
            .disabled(batching || scorer == nil)
        }
    }

    private var costLine: String? {
        guard source != nil else { return "CHOOSE A TRACK" }
        if scorer == nil { return "NEEDS THE CLAP ANALYZER" }
        return currentScore == nil ? "ONE ANALYSIS JOB"
                                   : "ALREADY SCORED — RUN AGAIN TO REFRESH"
    }

    // MARK: - Running

    private func score() {
        guard canRun, let source, let scorer else { return }
        let text = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        submitting = true
        Task {
            defer { submitting = false }
            await jobs.submitAnalyze(
                modelId: scorer.id, ownerId: source.id,
                ownerType: source.kind == "song.mix" ? "song" : "part",
                title: source.name, sourceURL: source.fileURL,
                params: ["prompt_text": .string(text)])
            runsJSON = ActionRunLog.recording(
                .init(summary: "\(recipe.name): \(source.name)",
                      detail: text.uppercased(), at: Date(),
                      sourceId: source.id, modelId: scorer.id),
                recipeId: recipe.id, in: runsJSON)
        }
    }

    private func scoreEverything() {
        guard let scorer else { return }
        let candidates = Self.batchCandidates(library: library, parts: parts)
        guard !candidates.isEmpty else { return }
        batching = true
        batchDone = 0
        batchTotal = candidates.count
        Task {
            defer { batching = false }
            for song in candidates {
                await jobs.submitAnalyze(
                    modelId: scorer.id, ownerId: song.id, ownerType: "song",
                    title: song.title, sourceURL: song.fileURL,
                    params: ["prompt_text": .string(song.prompt)])
                batchDone += 1
            }
        }
    }

    // MARK: - Pure helpers

    @MainActor
    static func payload(ownerId: String,
                        parts: PartsStore) -> AnalysisPayload? {
        guard let record = (try? parts.repository.analysis(ownerId: ownerId))
            ?? nil, let data = record.analysisJSON.data(using: .utf8)
        else { return nil }
        return try? BackendClient.decoder.decode(AnalysisPayload.self,
                                                 from: data)
    }

    @MainActor
    static func prompt(for material: PickedMaterial,
                       library: LibraryStore) -> String {
        library.song(id: material.songId)?.prompt ?? ""
    }

    /// Generated tracks with a prompt that have not already been scored
    /// against that same prompt — the idempotence the `clap_prompt` echo
    /// exists for.
    @MainActor
    static func batchCandidates(library: LibraryStore,
                                parts: PartsStore) -> [SongRecord] {
        let songs = (try? library.repository.search(.init())) ?? []
        return songs.filter { song in
            guard song.originKind == .generated,
                  !song.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                      .isEmpty else { return false }
            guard let payload = payload(ownerId: song.id, parts: parts),
                  payload.clapPromptScore != nil,
                  payload.clapPrompt == song.prompt else { return true }
            return false
        }
    }

    /// What a cosine means in words. Deliberately not a percentage: CLAP
    /// similarities cluster low, and "31%" reads as a failure to everyone
    /// who has not read the paper.
    static func verdict(_ score: Double) -> String {
        switch score {
        case ..<0.10: "barely related to those words"
        case ..<0.20: "loosely related"
        case ..<0.30: "a recognisable match"
        case ..<0.40: "a good match"
        default: "a very close match"
        }
    }

    private func restore() {
        if source == nil, let sourceId {
            source = PickedMaterial.resolve(id: sourceId, parts: parts,
                                            library: library)
        }
        if promptText.isEmpty, let source {
            promptText = Self.prompt(for: source, library: library)
        }
    }
}

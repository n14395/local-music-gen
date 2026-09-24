// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// "Find similar in library": the whole library ranked by CLAP timbre alone —
/// how it *sounds*, with tempo, key and everything else deliberately left
/// out of the score. The mashability ranking answers "what would mix with
/// this"; this page answers "what else sounds like this", which is a
/// different question with a different winner.
///
/// No job and no model: the embeddings were computed when each track was
/// analysed (the CLAP analyzer variant), so this is ranking maths over what
/// the library already holds — the `.match` pattern exactly.
struct SimilarActionView: View {
    let recipe: Recipe
    let sourceId: String?
    let catalog: ModelCatalogStore
    let library: LibraryStore
    let parts: PartsStore
    let jobs: JobsStore
    let playback: PlaybackController
    let onOpenModels: () -> Void
    let onBack: () -> Void

    struct Candidate: Identifiable, Equatable {
        let material: PickedMaterial
        let similarity: Double        // 0…1 CLAP cosine, floored at 0
        var id: String { material.id }
    }

    @State private var base: PickedMaterial?
    @State private var candidates: [Candidate] = []
    /// The source card's second line, resolved when the base changes.
    ///
    /// `ActionCopy.sourceMeta` is a song read plus an analysis read, and asked
    /// for from inside `body` it ran on every pass. The line only depends on
    /// the material, so it is resolved with it.
    @State private var baseMeta: String?
    @State private var missingEmbedding = 0
    @State private var choosingBase = false
    @AppStorage("actions.lastRuns") private var runsJSON = "{}"

    private var slot: Slot? { recipe.slots.first }

    /// Whether the base itself has an embedding to compare against.
    private var baseHasEmbedding: Bool {
        guard let base else { return false }
        return SimilarRanking.embedding(for: base.id, parts: parts) != nil
    }

    var body: some View {
        ActionPage(recipe: recipe, onBack: onBack) {
            ActionSourceCard(
                eyebrow: "SOUNDS LIKE…",
                material: base,
                meta: baseMeta,
                playback: playback,
                placeholder: "The track whose sound to search for.",
                chooseTitle: base == nil ? "Choose from Library…" : "Change…",
                onChoose: { choosingBase = true },
                onRemove: base == nil ? nil : { base = nil; candidates = [] })
            if let base, !baseHasEmbedding {
                ActionOptionsCard {
                    ActionFootnote(
                        text: "“\(base.name)” has no timbre embedding yet — "
                            + "run “Read the features” on it with the CLAP "
                            + "analyzer and it becomes searchable.",
                        tone: Bench.Palette.warn)
                }
            }
            resultsCard
        } commit: {
            ActionCommitRow(
                title: "Rank the library",
                costLine: costLine,
                costSubline: "NO MODEL RUNS — STORED EMBEDDINGS ONLY",
                isEnabled: base != nil && baseHasEmbedding,
                error: nil,
                queueTitle: nil,
                onCommit: rerank,
                onQueue: nil)
        } rail: {
            ActionRail(
                title: "How it ranks",
                outputs: [
                    ActionOutput(id: "timbre", name: "Timbre only",
                                 meta: "CLAP COSINE"),
                    ActionOutput(id: "not", name: "Tempo & key ignored",
                                 meta: "BY DESIGN"),
                ],
                explanation: "Similarity is the angle between stored CLAP "
                    + "embeddings — texture and instrumentation, not tempo "
                    + "or key. For “what would mix with this”, use “What "
                    + "mashes with this?” instead.",
                lastRun: ActionRunLog.decoded(runsJSON).runs[recipe.id])
        }
        .onAppear { restore() }
        .onChange(of: base, initial: true) {
            baseMeta = base.map {
                ActionCopy.sourceMeta($0, library: library, parts: parts)
            }
        }
        .sheet(isPresented: $choosingBase) {
            PartPickerSheet(
                slotLabel: slot?.label ?? "Starting point",
                accepts: slot?.accepts ?? [KindPattern(pattern: "song.mix")],
                autoDerive: slot?.autoDerive, catalog: catalog,
                library: library, parts: parts, jobs: jobs,
                playback: playback, onOpenModels: onOpenModels,
                onPick: { base = $0; rerank() })
        }
    }

    @ViewBuilder
    private var resultsCard: some View {
        if !candidates.isEmpty {
            ActionOptionsCard(eyebrow: "CLOSEST IN SOUND") {
                ForEach(candidates.prefix(20)) { candidate in
                    row(candidate)
                    if candidate.id != candidates.prefix(20).last?.id {
                        Divider().overlay(Bench.Palette.hairline)
                    }
                }
            }
        }
    }

    private func row(_ candidate: Candidate) -> some View {
        let material = candidate.material
        let isCurrent = playback.currentSongId == material.id
        return HStack(spacing: 12) {
            BenchPlayButton(isPlaying: isCurrent && playback.isPlaying,
                            isCurrent: isCurrent, size: 26) {
                let url = material.auditionURL ?? material.fileURL
                playback.play(url: url, songId: material.id,
                              title: material.sourceTitle,
                              duration: material.durationS ?? 0)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(material.name)
                    .font(Bench.Typo.body)
                    .foregroundStyle(Bench.Palette.textPrimary)
                    .lineLimit(1)
                Text(material.sourceTitle.uppercased()).metaLine()
                    .lineLimit(1)
            }
            Spacer()
            Text(String(format: "%.0f%%", candidate.similarity * 100))
                .font(Bench.Typo.value)
                .foregroundStyle(Bench.Palette.textPrimary)
                .frame(width: 52, alignment: .trailing)
        }
        .padding(.vertical, 4)
    }

    private var costLine: String? {
        guard base != nil else { return "CHOOSE A STARTING POINT" }
        return ActionFormat.join([
            candidates.isEmpty ? nil : "\(candidates.count) RANKED",
            missingEmbedding > 0 ? "\(missingEmbedding) WITHOUT EMBEDDINGS"
                                 : nil,
        ])
    }

    private func rerank() {
        guard let base else { return }
        let result = SimilarRanking.rank(baseId: base.id, library: library,
                                         parts: parts)
        candidates = result.ranked
        missingEmbedding = result.skipped
        runsJSON = ActionRunLog.recording(
            .init(summary: "\(recipe.name): \(base.name)",
                  detail: "\(candidates.count) RANKED",
                  at: Date(), sourceId: base.id, modelId: nil),
            recipeId: recipe.id, in: runsJSON)
    }

    private func restore() {
        guard base == nil, let id = sourceId else { return }
        base = MatchRanking.material(id: id, library: library, parts: parts)
        if base != nil { rerank() }
    }
}

/// The ranking core, pure enough to test: cosine over stored CLAP vectors.
enum SimilarRanking {
    @MainActor
    static func embedding(for id: String, parts: PartsStore) -> [Double]? {
        guard let record = (try? parts.repository.analysis(ownerId: id))
            ?? nil else { return nil }
        return AnalysisSummary(record: record)?.clap
    }

    @MainActor
    static func rank(baseId: String, library: LibraryStore, parts: PartsStore)
        -> (ranked: [SimilarActionView.Candidate], skipped: Int) {
        guard let baseVector = embedding(for: baseId, parts: parts) else {
            return ([], 0)
        }
        var ranked: [SimilarActionView.Candidate] = []
        var skipped = 0
        var ids: [String] = []
        ids += ((try? library.repository.search(.init())) ?? []).map(\.id)
        ids += ((try? parts.repository.parts(.init())) ?? []).map(\.id)

        for id in ids where id != baseId {
            guard let material = MatchRanking.material(id: id,
                                                       library: library,
                                                       parts: parts)
            else { continue }
            guard let vector = embedding(for: id, parts: parts),
                  let similarity = Mashability.timbre(source: vector,
                                                      target: baseVector)
            else {
                skipped += 1
                continue
            }
            ranked.append(.init(material: material, similarity: similarity))
        }
        ranked.sort {
            ($0.similarity, $1.material.sourceTitle)
                > ($1.similarity, $0.material.sourceTitle)
        }
        return (ranked, skipped)
    }
}

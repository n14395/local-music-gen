import SwiftUI

/// "What mashes with this?" — rank every analysed part and song in the library
/// against a chosen starting point.
///
/// Badged ANALYSE rather than EXACT: it measures and submits nothing. That is
/// also why it is the one action page with no lime primary — there is nothing
/// to commit, so the commit row states the shape of the answer instead.
struct MatchActionView: View {
    struct Candidate: Identifiable {
        let material: PickedMaterial
        let plan: MatchPlan
        var id: String { material.id }
    }

    let recipe: Recipe
    let sourceId: String?
    let catalog: ModelCatalogStore
    let library: LibraryStore
    let parts: PartsStore
    let jobs: JobsStore
    let playback: PlaybackController
    let workbench: WorkbenchModel
    let onOpenModels: () -> Void
    let onOpenWorkbench: ([String]) -> Void
    let onBack: () -> Void

    @State private var base: PickedMaterial?
    @State private var candidates: [Candidate] = []
    @State private var unanalyzedCount = 0
    @State private var choosing = false

    private var slot: Slot? { recipe.slots.first }

    var body: some View {
        ActionPage(recipe: recipe, onBack: onBack) {
            ActionSourceCard(
                eyebrow: "STARTING POINT",
                material: base,
                meta: base.map {
                    ActionCopy.sourceMeta($0, library: library, parts: parts)
                },
                playback: playback,
                placeholder: "Choose a song or part to match against.",
                chooseTitle: base == nil ? "Choose from Library…" : "Change…",
                onChoose: { choosing = true },
                onRemove: base == nil ? nil : {
                    base = nil
                    candidates = []
                })
            if base != nil {
                results
            }
        } commit: {
            ActionCommitRow(title: "Open Workbench",
                            costLine: costLine,
                            costSubline: "NOTHING IS SUBMITTED — THIS ONLY RANKS",
                            isEnabled: true,
                            queueTitle: nil,
                            onCommit: { onOpenWorkbench([]) })
        } rail: {
            ActionRail(title: "How this is scored",
                       outputs: signalRows,
                       explanation: unanalyzedCount > 0
                            ? "\(unanalyzedCount) items are skipped because "
                              + "they have no analysis yet. Run Read the "
                              + "features on them and they join the ranking."
                            : "Ranking is pure metadata, so it is instant and "
                              + "costs nothing. Nothing here is generated.")
        }
        .onAppear(perform: restore)
        .sheet(isPresented: $choosing) {
            PartPickerSheet(
                slotLabel: slot?.label ?? "Starting point",
                accepts: slot?.accepts ?? [KindPattern(pattern: "song.mix")],
                autoDerive: slot?.autoDerive,
                catalog: catalog, library: library, parts: parts, jobs: jobs,
                playback: playback, onOpenModels: onOpenModels,
                onPick: { picked in
                    base = picked
                    rerank()
                })
        }
    }

    // MARK: - Results

    @ViewBuilder
    private var results: some View {
        if candidates.isEmpty {
            ActionOptionsCard(eyebrow: "MATCHES") {
                ActionFootnote(
                    text: unanalyzedCount > 0
                        ? "\(unanalyzedCount) items have no analysis, so there "
                          + "is nothing to compare yet. Run Read the features "
                          + "on them first."
                        : "Split or import more material to compare against.",
                    tone: Bench.Palette.warn)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Text("MATCHES").eyebrow()
                    Text("\(candidates.count)").metaLine()
                    Spacer()
                }
                VStack(spacing: 0) {
                    ForEach(Array(candidates.enumerated()), id: \.element.id) {
                        index, candidate in
                        row(candidate)
                            .background(index.isMultiple(of: 2)
                                        ? Bench.Palette.rowZebra : .clear)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.row,
                                            style: .continuous))
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
            StemBar(kind: material.kind, width: 5, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(material.sourceTitle)
                    .font(Bench.Typo.body)
                    .foregroundStyle(Bench.Palette.textPrimary)
                    .lineLimit(1)
                Text(MatchRanking.why(candidate.plan).uppercased()).metaLine()
                    .lineLimit(1)
            }
            .frame(width: 240, alignment: .leading)
            BenchWaveformLoader(
                audioURL: material.auditionURL ?? material.fileURL,
                cacheURL: material.waveformURL,
                playedFraction: isCurrent ? playback.playedFraction : 0,
                tint: Bench.Palette.stem(material.kind))
                .frame(height: 26)
            RatingStars(rating: Int(candidate.plan.badges.stars.rounded()),
                        size: 11)
                .frame(width: 70, alignment: .trailing)
            Button("＋ Bench") {
                if let base {
                    workbench.add(material: base, parts: parts)
                }
                workbench.add(material: material, parts: parts)
                onOpenWorkbench([])
            }
            .buttonStyle(BenchSecondaryButtonStyle(
                tone: .quiet,
                padding: .init(top: 6, leading: 10, bottom: 6, trailing: 10),
                radius: Bench.Metrics.Radius.control))
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    // MARK: - Copy

    private var costLine: String? {
        guard base != nil else { return "CHOOSE A STARTING POINT" }
        return ActionFormat.join(["\(candidates.count) RANKED",
                                  unanalyzedCount > 0
                                    ? "\(unanalyzedCount) SKIPPED" : nil])
    }

    /// Every signal `Mashability.plan` weighs, heaviest first — key and tempo
    /// at .3, harmony and spectrum at .2, timbre at .15. Spectral
    /// complementarity counts for as much as harmony does, so leaving it out
    /// made the rail describe a scorer the app does not have.
    private var signalRows: [ActionOutput] {
        [ActionOutput(id: "tempo", name: "Tempo", meta: "STRETCH COST"),
         ActionOutput(id: "key", name: "Key", meta: "CAMELOT DISTANCE"),
         ActionOutput(id: "harmony", name: "Harmony", meta: "BEAT CHROMA"),
         ActionOutput(id: "spectrum", name: "Spectrum", meta: "BAND ENERGY"),
         ActionOutput(id: "timbre", name: "Timbre", meta: "CLAP EMBEDDING")]
    }

    // MARK: - Ranking

    private func restore() {
        guard base == nil, let id = sourceId else { return }
        base = MatchRanking.material(id: id, library: library, parts: parts)
        rerank()
    }

    private func rerank() {
        guard let base else { return }
        let result = MatchRanking.rank(baseId: base.id, library: library,
                                       parts: parts)
        candidates = result.ranked
        unanalyzedCount = result.skipped
    }
}

/// Testable ranking core: gather analyzed material, score against a base,
/// sort by stars. Store-touching entry points are MainActor (the stores
/// are); the text helpers below stay nonisolated for plain unit tests.
enum MatchRanking {
    @MainActor
    static func material(id: String, library: LibraryStore,
                         parts: PartsStore) -> PickedMaterial? {
        if let part = ((try? parts.repository.part(id: id)) ?? nil) {
            let title = ((try? library.repository.song(id: part.songId))
                         ?? nil)?.title ?? part.modelName
            return PickedMaterial(
                part: part,
                // What it is, then where it came from. The part's own name
                // opens with a slug of that same title, so using it here would
                // say the song twice.
                sourceTitle: "\(PartNaming.label(kind: part.kind)) — \(title)")
        }
        if let song = ((try? library.repository.song(id: id)) ?? nil) {
            return PickedMaterial(song: song)
        }
        return nil
    }

    @MainActor
    static func rank(baseId: String, library: LibraryStore, parts: PartsStore)
        -> (ranked: [MatchActionView.Candidate], skipped: Int) {
        guard let baseSummary = AnalysisSummary(
            record: (try? parts.repository.analysis(ownerId: baseId)) ?? nil)
        else { return ([], 0) }

        var candidates: [MatchActionView.Candidate] = []
        var skipped = 0
        var ids: [String] = []
        let songs = (try? library.repository.search(.init())) ?? []
        ids += songs.map(\.id)
        let allParts = (try? parts.repository.parts(.init())) ?? []
        ids += allParts.map(\.id)

        for id in ids where id != baseId {
            guard let material = material(id: id, library: library,
                                          parts: parts) else { continue }
            guard let summary = AnalysisSummary(
                record: (try? parts.repository.analysis(ownerId: id)) ?? nil)
            else {
                skipped += 1
                continue
            }
            let plan = Mashability.plan(
                source: summary, target: baseSummary,
                isDrums: material.kind.hasPrefix("stem.drums"))
            candidates.append(.init(material: material, plan: plan))
        }
        candidates.sort {
            ($0.plan.badges.stars, $0.material.sourceTitle)
                > ($1.plan.badges.stars, $1.material.sourceTitle)
        }
        return (candidates, skipped)
    }

    static func starsText(_ stars: Double) -> String {
        let full = Int(stars)
        let half = stars - Double(full) >= 0.5
        return String(repeating: "★", count: full) + (half ? "½" : "")
            .appending(String(repeating: "☆", count: max(0, 5 - full - (half ? 1 : 0))))
    }

    static func why(_ plan: MatchPlan) -> String {
        var bits: [String] = []
        if let key = plan.badges.key {
            bits.append(key.pitchShiftSt == 0
                ? "key ✓"
                : String(format: "key %+.0f st", key.pitchShiftSt))
        }
        if let tempo = plan.badges.tempo {
            bits.append(String(format: "stretch %.1f%%%@",
                               tempo.stretchPercent,
                               tempo.halfTimeFold ? " (half-time)" : ""))
        }
        if let harm = plan.badges.harmonic {
            bits.append(String(format: "harmony %.0f%%", harm * 100))
        }
        if let timbre = plan.badges.timbre {
            bits.append(String(format: "timbre %.0f%%", timbre * 100))
        }
        return bits.isEmpty ? "No shared signals yet" : bits.joined(separator: " · ")
    }
}

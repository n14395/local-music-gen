import SwiftUI

/// "What mashes with this?" — rank every analysed part and song in the library
/// against a chosen starting point.
///
/// Badged ANALYSE rather than EXACT: it measures and submits nothing. That is
/// also why it is the one action page with no lime primary — there is nothing
/// to commit, so the commit row states the shape of the answer instead.
struct MatchActionView: View {
    /// `Sendable` is spelled out rather than left to inference: these are
    /// built off the main actor and handed back to it, and a stored property
    /// added here that is not itself sendable should fail on this line rather
    /// than somewhere in `rerank`.
    struct Candidate: Identifiable, Sendable {
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
    /// True from asking for a ranking until it lands. The scoring runs off
    /// this actor now, so there are a few frames with a starting point chosen
    /// and no candidates yet, and those must not read as "nothing matches".
    @State private var ranking = false
    @State private var rankTask: Task<Void, Never>?

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
                    rerank()
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
                // Three things this card can mean, not two: the scoring lands
                // a beat after the starting point is chosen, and an empty list
                // in that gap is not the library telling you it has nothing.
                if ranking {
                    ActionFootnote(text: "Ranking the library against this…")
                } else {
                    ActionFootnote(
                        text: unanalyzedCount > 0
                            ? "\(unanalyzedCount) items have no analysis, so "
                              + "there is nothing to compare yet. Run Read the "
                              + "features on them first."
                            : "Split or import more material to compare "
                              + "against.",
                        tone: Bench.Palette.warn)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Text("MATCHES").eyebrow()
                    Text("\(candidates.count)").metaLine()
                    Spacer()
                }
                // Lazy because this list is the whole analysed library and
                // every row loads its own peaks off disk: eagerly it was N
                // waveform reads the instant a starting point was chosen, for
                // rows almost all of which sit below the fold of the page's
                // scroller.
                LazyVStack(spacing: 0) {
                    ForEach(Array(candidates.enumerated()), id: \.element.id) {
                        index, candidate in
                        MatchCandidateRow(
                            candidate: candidate,
                            playback: playback,
                            onBench: { bench(candidate.material) })
                            .background(index.isMultiple(of: 2)
                                        ? Bench.Palette.rowZebra : .clear)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.row,
                                            style: .continuous))
            }
        }
    }

    /// The starting point goes onto the bench alongside the candidate: the
    /// whole point of the page is the pair, and arriving with only half of it
    /// would make you go back for the other.
    private func bench(_ material: PickedMaterial) {
        if let base {
            workbench.add(material: base, parts: parts)
        }
        workbench.add(material: material, parts: parts)
        onOpenWorkbench([])
    }

    // MARK: - Copy

    private var costLine: String? {
        guard base != nil else { return "CHOOSE A STARTING POINT" }
        if ranking { return "RANKING…" }
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

    /// Read on this actor, score off it.
    ///
    /// Both halves grow with the library, and both used to happen inline on
    /// the click that chose a starting point: a query to resolve each
    /// candidate, another for its analysis, then a JSON decode and a
    /// 512-dimension cosine apiece. `MatchRanking.inputs` is now three queries
    /// whatever the library's size, and the scoring runs on a detached task,
    /// so the click returns and the list fills in behind it.
    private func rerank() {
        rankTask?.cancel()
        guard let base else {
            rankTask = nil
            ranking = false
            candidates = []
            return
        }
        let inputs = MatchRanking.inputs(baseId: base.id, library: library,
                                         parts: parts)
        ranking = true
        rankTask = Task {
            let answer = await Task.detached(priority: .userInitiated) {
                MatchRanking.rank(inputs)
            }.value
            // Same rule the stores' deferred refreshes follow: a slow answer
            // must never overwrite a fresher one. Changing the starting point
            // mid-flight does not just make this stale, it makes it an answer
            // to a different question.
            guard !Task.isCancelled, self.base?.id == inputs.baseId else {
                return
            }
            candidates = answer.ranked
            unanalyzedCount = answer.skipped
            ranking = false
        }
    }
}

// MARK: - Candidate row

/// One ranked candidate: audition, stem colour, title over why it scored, its
/// waveform, the stars, and the way onto the bench.
///
/// A view of its own rather than a method on the page, because SwiftUI tracks
/// observable reads per body. Read from the page, the transport clock below
/// belonged to the page's body and every row in the list redrew four times a
/// second while anything played; read from here it invalidates the one row
/// that is playing.
struct MatchCandidateRow: View {
    let candidate: MatchActionView.Candidate
    let playback: PlaybackController
    let onBench: () -> Void

    private var material: PickedMaterial { candidate.material }
    private var isCurrent: Bool { playback.currentSongId == material.id }

    var body: some View {
        HStack(spacing: 12) {
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
            // `isCurrent` first and the ternary short-circuits, exactly as the
            // library rows do it: `playedFraction` reads the transport clock,
            // so a row that is not the one playing must not touch it or the
            // saving above is given straight back.
            BenchWaveformLoader(
                audioURL: material.auditionURL ?? material.fileURL,
                cacheURL: material.waveformURL,
                playedFraction: isCurrent ? playback.playedFraction : 0,
                tint: Bench.Palette.stem(material.kind))
                .frame(height: 26)
            RatingStars(rating: Int(candidate.plan.badges.stars.rounded()),
                        size: 11)
                .frame(width: 70, alignment: .trailing)
            Button("＋ Bench", action: onBench)
                .buttonStyle(BenchSecondaryButtonStyle(
                    tone: .quiet,
                    padding: .init(top: 6, leading: 10, bottom: 6, trailing: 10),
                    radius: Bench.Metrics.Radius.control))
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

/// Testable ranking core: gather analyzed material, score against a base,
/// sort by stars.
///
/// Split down the middle on isolation. `material(id:)` and `inputs` touch the
/// stores, so they are MainActor (the stores are); `rank` and the text helpers
/// take what those read as plain values and stay nonisolated, which is what
/// lets the scoring run off the main actor and the helpers be unit-tested
/// without one.
enum MatchRanking {
    /// Everything `rank` reads, so that the reading and the scoring can happen
    /// in different places. Records rather than summaries: decoding a stored
    /// analysis is most of the per-candidate cost, and it belongs on whichever
    /// thread does the scoring.
    struct Inputs: Sendable {
        var baseId: String
        var baseRecord: AnalysisRecord?
        /// In the order the scan produced them — songs, then parts. The base
        /// is already excluded. `rank` sorts by stars and then title, so this
        /// order only shows through on an exact tie in both, but it is the
        /// order the unbatched scan had and it costs nothing to keep.
        var materials: [PickedMaterial]
        /// Keyed by owner id; a missing entry is a candidate with no analysis.
        var analyses: [String: AnalysisRecord]
    }

    @MainActor
    static func material(id: String, library: LibraryStore,
                         parts: PartsStore) -> PickedMaterial? {
        if let part = ((try? parts.repository.part(id: id)) ?? nil) {
            let title = ((try? library.repository.song(id: part.songId))
                         ?? nil)?.title
            return material(part: part, songTitle: title)
        }
        if let song = ((try? library.repository.song(id: id)) ?? nil) {
            return PickedMaterial(song: song)
        }
        return nil
    }

    /// A part as pickable material, given its song's title if the song is
    /// still there. Shared with the batched scan below so the one decision
    /// about how a part names itself cannot drift between the two paths.
    static func material(part: PartRecord, songTitle: String?)
        -> PickedMaterial {
        PickedMaterial(
            part: part,
            // What it is, then where it came from. The part's own name opens
            // with a slug of that same title, so using it here would say the
            // song twice.
            sourceTitle: "\(PartNaming.label(kind: part.kind)) — "
                + (songTitle ?? part.modelName))
    }

    /// The database half of ranking: every song, every part, and one batched
    /// read of the analyses for all of them.
    ///
    /// Three queries whatever the library holds. The scan this replaces went
    /// through `material(id:)` per candidate — a part lookup, then a song
    /// lookup for its title — and then asked for that candidate's analysis on
    /// its own, so a two hundred item library was six hundred round trips
    /// before any scoring started, all of them on the click.
    ///
    /// Resolving the fetched records directly is the same answer
    /// `material(id:)` gives: it probes the part table first, and no part
    /// shares an id with a song.
    @MainActor
    static func inputs(baseId: String, library: LibraryStore,
                       parts: PartsStore) -> Inputs {
        let songs = (try? library.repository.search(.init())) ?? []
        let allParts = (try? parts.repository.parts(.init())) ?? []
        let titles = Dictionary(songs.map { ($0.id, $0.title) }) { first, _ in
            first
        }
        var materials: [PickedMaterial] = []
        materials.reserveCapacity(songs.count + allParts.count)
        for song in songs where song.id != baseId {
            materials.append(PickedMaterial(song: song))
        }
        for part in allParts where part.id != baseId {
            materials.append(material(part: part,
                                      songTitle: titles[part.songId]))
        }
        return Inputs(
            baseId: baseId,
            baseRecord: (try? parts.repository.analysis(ownerId: baseId))
                ?? nil,
            materials: materials,
            analyses: (try? parts.repository
                .analyses(ownerIds: materials.map(\.id))) ?? [:])
    }

    /// The scoring half: decode each candidate's analysis and plan the match
    /// against the base. Pure, and deliberately not isolated — per candidate
    /// this is a JSON decode of the stored payload plus a 512-dimension
    /// cosine, which is exactly the work that used to stall the click.
    static func rank(_ inputs: Inputs)
        -> (ranked: [MatchActionView.Candidate], skipped: Int) {
        guard let baseSummary = AnalysisSummary(record: inputs.baseRecord)
        else { return ([], 0) }

        var candidates: [MatchActionView.Candidate] = []
        var skipped = 0
        for material in inputs.materials {
            guard let summary = AnalysisSummary(
                record: inputs.analyses[material.id])
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

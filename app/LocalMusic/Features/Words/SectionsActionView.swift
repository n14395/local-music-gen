import SwiftUI

/// "Map the sections": the shape the analyzer found, read out loud — and cut
/// up, if the shape turns out to be what you wanted.
///
/// No model of its own. The section map is already in the stored analysis
/// (the `deep` pass); this page is what finally shows it, and the slicing is
/// ordinary mix jobs with a trim on each. When there is no analysis it offers
/// to run one rather than sitting empty.
struct SectionsActionView: View {
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

    @State private var source: PickedMaterial?
    @State private var choosingSource = false
    @State private var submitting = false
    @AppStorage("actions.lastRuns") private var runsJSON = "{}"

    private var slot: Slot? { recipe.slots.first }

    private var payload: AnalysisPayload? {
        guard let source,
              let json = (try? parts.repository.analysis(ownerId: source.id))
                  .flatMap({ $0?.analysisJSON }),
              let data = json.data(using: .utf8) else { return nil }
        return try? BackendClient.decoder.decode(AnalysisPayload.self,
                                                 from: data)
    }

    private var sections: [AnalysisPayload.Section] {
        payload?.sections ?? []
    }

    private var analyzer: ModelInfo? {
        catalog.models.first {
            $0.installState == .installed
                && $0.capabilities.supportedTasks.contains("analyze")
        }
    }

    private var mixModel: ModelInfo? { MixModels.mixdown(in: catalog.models) }

    var body: some View {
        ActionPage(recipe: recipe, onBack: onBack) {
            ActionSourceCard(
                eyebrow: "TRACK",
                material: source,
                meta: source.map {
                    ActionCopy.sourceMeta($0, library: library, parts: parts)
                },
                playback: playback,
                placeholder: "A song or a part from your library.",
                chooseTitle: source == nil ? "Choose from Library…" : "Change…",
                onChoose: { choosingSource = true },
                onRemove: source == nil ? nil : { source = nil })
            if source != nil, sections.isEmpty {
                emptyCard
            }
            if !sections.isEmpty {
                sectionsCard
            }
        } commit: {
            ActionCommitRow(title: commitTitle,
                            costLine: costLine,
                            costSubline: "THE ORIGINAL IS UNTOUCHED",
                            isEnabled: canSlice,
                            error: jobs.lastError,
                            queueTitle: nil,
                            onCommit: sliceIntoParts,
                            onQueue: nil)
        } rail: {
            ActionRail(
                outputs: sections.isEmpty
                    ? [ActionOutput(id: "map", name: "The section map",
                                    meta: "FROM ANALYSIS")]
                    : [ActionOutput(id: "parts",
                                    name: "\(sections.count) section parts",
                                    meta: "AUDIO", kind: "layer.section")],
                explanation: "Sections come from the analyzer's structure "
                    + "pass — repeated shapes it found, lettered by first "
                    + "appearance. Slicing cuts the audio at those exact "
                    + "boundaries; nothing is re-rendered by a model.",
                lastRun: ActionRunLog.decoded(runsJSON).runs[recipe.id])
        }
        .onAppear { restore() }
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

    private var emptyCard: some View {
        ActionOptionsCard(eyebrow: "NO STRUCTURE YET") {
            ActionFootnote(
                text: analyzer == nil
                    ? "This track has not been analysed, and no analysis "
                        + "model is installed to do it."
                    : "This track has no section map yet — analyse it and "
                        + "the shape appears here.")
            if let analyzer {
                Button("Analyse it now") { analyse(with: analyzer) }
                    .buttonStyle(BenchSecondaryButtonStyle())
            } else {
                Button("Get an analysis model…", action: onOpenModels)
                    .buttonStyle(BenchSecondaryButtonStyle(tone: .quiet))
            }
        }
    }

    private var sectionsCard: some View {
        ActionOptionsCard(eyebrow: "THE SHAPE") {
            ForEach(Array(sections.enumerated()), id: \.offset) { index, part in
                sectionRow(index: index, section: part)
            }
            HStack {
                Spacer()
                Button("Copy as text") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(outline, forType: .string)
                }
                .buttonStyle(BenchSecondaryButtonStyle(tone: .quiet))
            }
        }
    }

    private func sectionRow(index: Int,
                            section: AnalysisPayload.Section) -> some View {
        Button {
            if playback.currentSongId == source?.id {
                playback.seek(to: section.startS)
            } else if let source {
                let url = source.auditionURL ?? source.fileURL
                playback.play(url: url, songId: source.id,
                              title: source.sourceTitle,
                              duration: source.durationS ?? 0)
                playback.seek(to: section.startS)
            }
        } label: {
            HStack(spacing: 10) {
                Text(label(section, index: index))
                    .font(Bench.Typo.body)
                    .foregroundStyle(Bench.Palette.textPrimary)
                    .frame(width: 90, alignment: .leading)
                Text("\(TextDocsSection.stamp(section.startS)) – "
                     + TextDocsSection.stamp(section.endS))
                    .font(Bench.Typo.mono(11))
                    .foregroundStyle(Bench.Palette.textFaint)
                Spacer()
                Text("\(Int((section.endS - section.startS).rounded())) s")
                    .font(Bench.Typo.mono(10))
                    .foregroundStyle(Bench.Palette.textFaintest)
            }
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Copy

    /// "A", "B" — the analyzer letters groups by first appearance, which is a
    /// form description once it is read aloud. The index is kept alongside so
    /// two sections of the same group are still tellable apart.
    private func label(_ section: AnalysisPayload.Section,
                       index: Int) -> String {
        let group = section.label ?? section.group ?? "—"
        return "\(index + 1). \(group)"
    }

    private var outline: String {
        sections.enumerated().map { index, section in
            "\(TextDocsSection.stamp(section.startS))  "
                + label(section, index: index)
        }.joined(separator: "\n")
    }

    private var canSlice: Bool {
        source != nil && !sections.isEmpty && mixModel != nil && !submitting
    }

    private var commitTitle: String {
        sections.isEmpty ? "Slice into parts"
                         : "Slice into \(sections.count) parts"
    }

    private var costLine: String? {
        guard source != nil else { return "CHOOSE A TRACK" }
        if sections.isEmpty { return "NEEDS A STRUCTURE ANALYSIS" }
        if mixModel == nil { return "NEEDS MIXDOWN & ALIGN" }
        return ActionFormat.join(["\(sections.count) JOBS",
                                  "SAVED TO LIBRARY › PARTS"])
    }

    // MARK: - Actions

    private func analyse(with model: ModelInfo) {
        guard let source else { return }
        submitting = true
        Task {
            defer { submitting = false }
            await jobs.submitAnalyze(
                modelId: model.id, ownerId: source.id,
                ownerType: source.kind == "song.mix" ? "song" : "part",
                title: source.name, sourceURL: source.fileURL,
                params: ["deep": .bool(true)])
        }
    }

    /// One mix job per section, each a single ingredient trimmed to its own
    /// boundaries and landed as a part of the source song — the audio is cut,
    /// never re-rendered, so `autoMatch` is off and nothing is stretched.
    private func sliceIntoParts() {
        guard canSlice, let source, let mixModel else { return }
        let cuts = sections
        submitting = true
        Task {
            defer { submitting = false }
            for (index, section) in cuts.enumerated() {
                var ingredient = IngredientSubmission(slotId: "section",
                                                      partId: source.id)
                ingredient.sectionStartS = section.startS
                ingredient.sectionEndS = section.endS
                // 8 ms is under a perceptible fade and over a click — the
                // same ramp the loop transform uses at its cut points.
                ingredient.fadeInS = 0.008
                ingredient.fadeOutS = 0.008
                var options = RecombineOptions()
                options.autoMatchTempo = false
                options.autoMatchKey = false
                let name = label(section, index: index)
                await jobs.submitRecombine(
                    modelId: mixModel.id, recipeId: recipe.id,
                    title: "\(source.name) — \(name)",
                    ingredients: [ingredient], options: options,
                    context: .generativePart(
                        songId: source.songId,
                        sourceTitle: source.sourceTitle,
                        kind: "layer.section",
                        name: name))
            }
            runsJSON = ActionRunLog.recording(
                .init(summary: "\(recipe.name): \(source.name)",
                      detail: "\(cuts.count) SECTIONS",
                      at: Date(), sourceId: source.id, modelId: mixModel.id),
                recipeId: recipe.id, in: runsJSON)
        }
    }

    private func restore() {
        if source == nil, let sourceId {
            source = PickedMaterial.resolve(id: sourceId, parts: parts,
                                            library: library)
        }
    }
}

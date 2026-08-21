import SwiftUI

// Two actions whose whole configuration is "which audio?": the SoundFont
// render of a notes part, and the structure arranger. They are pages rather
// than pickers because the right rail is the point — each one has something
// worth saying about what happens next that a bare file chooser had nowhere to
// put.
//
// The melody hand-off used to live here too. It is now a mode of the Style
// Transfer workspace, which actually runs the job rather than bouncing you to
// Studio to set it up a second time.

// MARK: - Notes → audio

/// "Notes into a new instrument": a SoundFont render of a notes part back into
/// audio, which lands as a `layer.*` part of the same song.
struct RenderActionView: View {
    let recipe: Recipe
    let sourceId: String?
    let catalog: ModelCatalogStore
    let library: LibraryStore
    let parts: PartsStore
    let jobs: JobsStore
    let playback: PlaybackController
    let onOpenModels: () -> Void
    let onBack: () -> Void

    @State private var source: PickedMaterial?
    @State private var selectedModelId: String?
    @State private var choosing = false
    @State private var submitting = false
    @AppStorage("actions.lastRuns") private var runsJSON = "{}"

    private var slot: Slot? { recipe.slots.first }

    private var eligible: [ModelInfo] {
        catalog.models.filter {
            $0.installState == .installed
                && $0.capabilities.supportedTasks.contains("render")
        }
    }

    private var model: ModelInfo? {
        eligible.first { $0.id == selectedModelId } ?? eligible.first
    }

    var body: some View {
        ActionPage(recipe: recipe, onBack: onBack) {
            ActionSourceCard(
                eyebrow: "NOTES",
                material: source,
                meta: source.map {
                    ActionCopy.sourceMeta($0, library: library, parts: parts)
                },
                playback: playback,
                placeholder: "A notes part. Transcribe a song or a stem first "
                    + "if you have none.",
                chooseTitle: source == nil ? "Choose from Library…" : "Change…",
                onChoose: { choosing = true },
                onRemove: source == nil ? nil : { source = nil })
            if eligible.isEmpty {
                ActionModelGate(
                    readiness: catalog.readiness,
                    title: "The note renderer is not installed",
                    detail: "Note renderer (SoundFont) turns MIDI parts back "
                        + "into audio with General MIDI instruments. It is free.",
                    onOpenModels: onOpenModels)
            } else {
                ActionModelPicker(eyebrow: "RENDERER", models: eligible,
                                  selectedId: Binding(
                                    get: { model?.id },
                                    set: { selectedModelId = $0 }),
                                  meta: { candidate in
                                      ActionFormat.join([
                                        "INSTALLED",
                                        ActionFormat.estimate(
                                            ActionEstimate.taskSeconds(
                                                model: candidate,
                                                sourceDurationS: source?.durationS))])
                                  })
                ActionOptionsCard {
                    ActionFootnote(
                        text: "The instrument comes from the notes part's own "
                            + "General MIDI program. Once it is audio, every "
                            + "Reimagine action can restyle it.")
                }
            }
        } commit: {
            ActionCommitRow(title: "Render to audio",
                            costLine: ActionFormat.join([
                                ActionFormat.estimate(
                                    ActionEstimate.taskSeconds(
                                        model: model,
                                        sourceDurationS: source?.durationS)),
                                "SAVED TO LIBRARY › PARTS"]),
                            costSubline: "THE NOTES PART IS KEPT",
                            isEnabled: source != nil && model != nil
                                && !submitting,
                            error: jobs.lastError,
                            onCommit: { submit(back: true) },
                            onQueue: { submit(back: false) })
        } rail: {
            ActionRail(outputs: outputs,
                       explanation: "A new audio part on the same song, sitting "
                            + "beside the stems it was transcribed from.",
                       lastRun: ActionRunLog.decoded(runsJSON).runs[recipe.id])
        }
        .onAppear {
            if source == nil, let sourceId {
                source = PickedMaterial.resolve(id: sourceId, parts: parts,
                                                library: library)
            }
            if selectedModelId == nil { selectedModelId = eligible.first?.id }
        }
        .sheet(isPresented: $choosing) {
            PartPickerSheet(
                slotLabel: slot?.label ?? "Notes",
                accepts: slot?.accepts ?? [KindPattern(pattern: "notes.*")],
                autoDerive: slot?.autoDerive,
                catalog: catalog, library: library, parts: parts, jobs: jobs,
                playback: playback, onOpenModels: onOpenModels,
                onPick: { source = $0 })
        }
    }

    private var outputs: [ActionOutput] {
        guard let source else {
            return [ActionOutput(id: "layer", name: "Rendered part",
                                 meta: "WAV")]
        }
        return [ActionOutput(id: "layer",
                             name: "Render: \(source.name)",
                             meta: ActionFormat.join([
                                source.durationS.map(ActionFormat.length),
                                "WAV"]),
                             kind: "layer.\(source.name.lowercased())")]
    }

    private func submit(back: Bool) {
        guard let source, let model,
              let part = ((try? parts.repository.part(id: source.id)) ?? nil)
        else { return }
        submitting = true
        Task {
            let created = await jobs.submitRender(
                modelId: model.id, part: part, sourceTitle: source.sourceTitle)
            submitting = false
            guard created != nil else { return }
            runsJSON = ActionRunLog.recording(
                .init(summary: "\(source.name) → audio",
                      detail: model.displayName.uppercased(),
                      at: Date(), sourceId: source.id, modelId: model.id),
                recipeId: recipe.id, in: runsJSON)
            if back { onBack() }
        }
    }
}

// MARK: - Remix the structure

/// "Remix the structure" is an opening move on the timeline rather than a job:
/// the song's analysed sections land as clips, and from there they can be
/// dragged, repeated, dropped or crossfaded like anything else.
///
/// The rail says how many sections exist *before* you commit, because a song
/// with no structure analysis will land as a single clip and that used to be a
/// surprise delivered after the screen had already changed.
struct ArrangeActionView: View {
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

    @State private var source: PickedMaterial?
    @State private var choosing = false
    @AppStorage("workbench.lens") private var lens: WorkbenchLens = .rows

    private var slot: Slot? { recipe.slots.first }

    /// Sections come from the stored analysis payload, not from a guess: a song
    /// nobody has analysed genuinely has none.
    private var sections: [AnalysisPayload.Section] {
        guard let source, let record = parts.analysis(for: source.id),
              let payload = try? BackendClient.decoder.decode(
                AnalysisPayload.self, from: Data(record.analysisJSON.utf8))
        else { return [] }
        return payload.sections ?? []
    }

    var body: some View {
        ActionPage(recipe: recipe, onBack: onBack) {
            ActionSourceCard(
                eyebrow: "SONG",
                material: source,
                meta: source.map {
                    ActionCopy.sourceMeta($0, library: library, parts: parts)
                },
                playback: playback,
                placeholder: "Choose the song whose sections you want to move.",
                chooseTitle: source == nil ? "Choose from Library…" : "Change…",
                onChoose: { choosing = true },
                onRemove: source == nil ? nil : { source = nil })
            ActionOptionsCard(eyebrow: "STRUCTURE") {
                if source == nil {
                    ActionFootnote(text: "Pick a song and its sections appear "
                                        + "here.")
                } else if sections.count > 1 {
                    ActionFootnote(
                        text: "\(sections.count) sections will be placed back "
                            + "to back on the timeline, labelled A1, A2, B1 … "
                            + "Drag, duplicate or delete them to rearrange, "
                            + "then render the result as an exact mix.")
                } else {
                    ActionFootnote(
                        text: "No structure analysis yet, so this lands as one "
                            + "clip. Run Read the features on it first to get "
                            + "its sections.",
                        tone: Bench.Palette.warn)
                }
            }
        } commit: {
            ActionCommitRow(title: "Open on the timeline",
                            costLine: "NOTHING IS SUBMITTED YET",
                            costSubline: "RENDER FROM THE WORKBENCH WHEN READY",
                            isEnabled: source != nil,
                            queueTitle: nil,
                            onCommit: place)
        } rail: {
            ActionRail(title: "You'll get back",
                       outputs: outputs,
                       explanation: "Clips on the Workbench timeline. Nothing "
                            + "is rendered until you press Create mix there, "
                            + "and the original song is untouched either way.")
        }
        .onAppear {
            if source == nil, let sourceId {
                source = PickedMaterial.resolve(id: sourceId, parts: parts,
                                                library: library)
            }
        }
        .sheet(isPresented: $choosing) {
            PartPickerSheet(
                slotLabel: slot?.label ?? "Song to rearrange",
                accepts: slot?.accepts ?? [KindPattern(pattern: "song.mix")],
                autoDerive: slot?.autoDerive,
                catalog: catalog, library: library, parts: parts, jobs: jobs,
                playback: playback, onOpenModels: onOpenModels,
                onPick: { source = $0 })
        }
    }

    private var outputs: [ActionOutput] {
        guard let source else {
            return [ActionOutput(id: "clips", name: "Timeline clips",
                                 meta: "WORKBENCH")]
        }
        let count = max(1, sections.count)
        return [ActionOutput(id: "clips",
                             name: count == 1 ? "1 clip" : "\(count) clips",
                             qualifier: source.name,
                             meta: ActionFormat.join([
                                source.durationS.map(ActionFormat.length),
                                "WORKBENCH"]),
                             kind: source.kind)]
    }

    private func place() {
        guard let source else { return }
        let clip = workbench.add(material: source, parts: parts)
        let made = workbench.explodeIntoSections(clip.id)
        lens = .timeline
        onOpenWorkbench(made.isEmpty
            ? ["\(source.name) has no structure analysis yet — run Read the "
               + "features on it to split it into sections."]
            : ["\(made.count) sections placed back to back — drag, duplicate "
               + "or delete them to rearrange."])
    }
}

import SwiftUI

/// Design 07, literally: the config page for every action whose engine is a
/// preset split — `separate`, `transcribe` and `analyze`.
///
/// This is the old Split tab turned inside out. It held the same four
/// decisions (source, task, model, quality) but showed none of the
/// consequences; here the same controls sit beside "You'll get back" and a cost
/// line, so the expensive choice — Mel-Band RoFormer is fifteen times slower
/// than Demucs — is visible at the moment you make it.
struct SplitActionView: View {
    let recipe: Recipe
    /// Contract task: "separate" | "transcribe" | "analyze".
    let task: String
    /// The engine's one-line explanation of what this split does.
    let note: String
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
    @State private var selectedModelId: String?
    @State private var formState = ParameterFormState(specs: [])
    @State private var choosing = false
    @State private var importing = false
    @State private var alsoAnalyse = false
    @State private var alsoTranscribe = false
    @State private var submitting = false
    @State private var browsingT3K = false
    @AppStorage("analysisToolsCardDismissed")
    private var analysisCardDismissed = false
    @AppStorage("actions.lastRuns") private var runsJSON = "{}"

    // MARK: models

    private var eligibleModels: [ModelInfo] {
        catalog.models.filter { model in
            model.installState == .installed
                && model.capabilities.supportedTasks.contains(task)
                && (recipe.sourceParamKey == nil
                    || model.capabilities.params.contains {
                        $0.key == recipe.sourceParamKey
                    })
        }
    }

    private var model: ModelInfo? {
        eligibleModels.first { $0.id == selectedModelId } ?? eligibleModels.first
    }

    private func installedModel(task: String) -> ModelInfo? {
        catalog.models.first {
            $0.installState == .installed
                && $0.capabilities.supportedTasks.contains(task)
        }
    }

    private var estimateSeconds: Double? {
        ActionEstimate.taskSeconds(model: model,
                                   sourceDurationS: source?.durationS)
    }

    var body: some View {
        ActionPage(recipe: recipe,
                   preset: model.map {
                       ActionPresetContext(model: $0, form: formState)
                   },
                   onBack: onBack) {
            if task != "analyze", installedModel(task: "analyze") == nil,
               !analysisCardDismissed {
                analysisNudge
            }
            ActionSourceCard(
                material: source,
                meta: source.map {
                    ActionCopy.sourceMeta($0, library: library, parts: parts)
                },
                playback: playback,
                placeholder: "Choose a song from your library, or import audio.",
                importTitle: "Import audio…",
                onChoose: { choosing = true },
                onImport: { importing = true })
            if eligibleModels.isEmpty {
                ActionModelGate(
                    readiness: catalog.readiness,
                    title: "No \(modelNoun) model installed",
                    detail: "Install one from Models and this action can run. "
                        + "Nothing else on this page changes.",
                    onOpenModels: onOpenModels)
            } else {
                ActionModelPicker(eyebrow: modelEyebrow, models: eligibleModels,
                                  selectedId: Binding(
                                    get: { model?.id },
                                    set: { selectedModelId = $0 }),
                                  meta: modelMeta)
                optionsCard
            }
        } commit: {
            ActionCommitRow(title: commitTitle,
                            costLine: costLine, costSubline: costSubline,
                            isEnabled: source != nil && model != nil
                                && !submitting,
                            error: jobs.lastError,
                            onCommit: { submit(returningToGallery: true) },
                            onQueue: { submit(returningToGallery: false) })
        } rail: {
            ActionRail(outputs: expectedOutputs,
                       explanation: railExplanation,
                       lastRun: ActionRunLog.decoded(runsJSON).runs[recipe.id],
                       onReplay: replay)
        }
        .onAppear(perform: restore)
        .onChange(of: selectedModelId) { rebuildForm() }
        .onChange(of: catalog.version) { rebuildForm() }
        .sheet(isPresented: $choosing) {
            PartPickerSheet(
                slotLabel: recipe.slots.first?.label ?? "Song",
                accepts: recipe.slots.first?.accepts
                    ?? [KindPattern(pattern: "song.mix")],
                autoDerive: nil,
                catalog: catalog, library: library, parts: parts, jobs: jobs,
                playback: playback, onOpenModels: onOpenModels,
                onPick: { source = $0 })
        }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [.audio],
                      allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task {
                let imported = await library.importSongs(urls: urls)
                if let first = imported.first {
                    source = PickedMaterial(song: first)
                }
            }
        }
        .sheet(isPresented: $browsingT3K) {
            Tone3000BrowseSheet(
                onPick: { url in formState.audioSelections["nam_file"] = url },
                onOpenSettings: nil)
        }
    }

    // MARK: - Options

    @ViewBuilder
    private var optionsCard: some View {
        ActionOptionsCard {
            if let model, !visibleParams(model).isEmpty {
                ParameterFormView(state: formState, grouped: false,
                                  labelWidth: 130,
                                  materialPicker: MaterialPickerContext(
                                      catalog: catalog, library: library,
                                      parts: parts, jobs: jobs,
                                      playback: playback,
                                      onOpenModels: onOpenModels))
            }
            // The re-amp card's capture slot can be filled from TONE3000
            // in place — the sheet downloads the .nam into the same
            // `nam_file` selection the file picker sets.
            if task == "reamp" {
                Button("Browse TONE3000…") { browsingT3K = true }
                    .buttonStyle(.benchSecondary)
                    .help(Tone3000Store.hasKey
                          ? "Search tone3000.com's captures and drop one "
                            + "straight into the capture slot"
                          : "Add your TONE3000 API key in Settings › "
                            + "Models to browse captures here")
            }
            ActionFootnote(text: note)
            // Compose reads a MIDI file — the "also" jobs would hand an
            // audio analyzer notes it cannot open.
            if task != "analyze", task != "compose" {
                Divider().overlay(Bench.Palette.hairline)
                HStack(alignment: .top, spacing: 12) {
                    Text("Also analyse")
                        .font(Bench.Typo.secondary)
                        .foregroundStyle(Bench.Palette.textSecondary)
                        .frame(width: 130, alignment: .leading)
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 7) {
                            ActionCheckChip(
                                label: "Tempo & key",
                                isOn: $alsoAnalyse,
                                disabledReason: installedModel(task: "analyze") == nil
                                    ? "no analysis model installed" : nil)
                            if task != "transcribe" {
                                ActionCheckChip(
                                    label: "Transcribe to notes",
                                    isOn: $alsoTranscribe,
                                    disabledReason: installedModel(task: "transcribe") == nil
                                        ? "no transcription model installed" : nil)
                            }
                        }
                        ActionFootnote(
                            text: "Queued as their own jobs on the same source, "
                                + "right behind this one.")
                    }
                }
            }
        }
    }

    private func visibleParams(_ model: ModelInfo) -> [ParamSpec] {
        model.capabilities.params.filter {
            $0.key != "source_audio" && $0.isInternal != true
                && $0.key != recipe.sourceParamKey
        }
    }

    private func rebuildForm() {
        guard let model else {
            formState = ParameterFormState(specs: [])
            return
        }
        formState = ParameterFormState(specs: visibleParams(model))
        for (key, value) in recipe.paramPresets {
            guard let spec = formState.specs.first(where: { $0.key == key })
            else { continue }
            switch value {
            case .int(let v): formState.setDouble(spec, Double(v))
            case .double(let v): formState.setDouble(spec, v)
            case .bool(let v): formState.setBool(spec, v)
            case .string(let v): formState.setString(spec, v)
            default: break
            }
        }
    }

    // MARK: - Copy

    private var modelNoun: String {
        switch task {
        case "transcribe": "transcription"
        case "analyze": "analysis"
        case "timbre": "timbre-transfer"
        case "reamp": "amp-modelling"
        case "convert-voice": "voice-conversion"
        case "sing": "singing"
        case "compose": "composition"
        default: "separation"
        }
    }

    private var modelEyebrow: String {
        switch task {
        case "transcribe": "TRANSCRIPTION MODEL"
        case "analyze": "ANALYSIS MODEL"
        case "timbre": "TIMBRE MODEL"
        case "reamp": "AMP MODEL"
        case "convert-voice": "VOICE MODEL"
        case "sing": "SINGING MODEL"
        case "compose": "COMPOSER MODEL"
        default: "SEPARATOR MODEL"
        }
    }

    private func modelMeta(_ candidate: ModelInfo) -> String {
        let estimate = ActionEstimate.taskSeconds(
            model: candidate, sourceDurationS: source?.durationS)
        return ActionFormat.join(["INSTALLED",
                                  ActionFormat.estimate(estimate)])
    }

    /// `Split into 4 parts` once this model has actually produced four; the
    /// catalog does not declare stem lists, so the count comes from what the
    /// library already holds rather than from a guess.
    ///
    /// Gated on the recipe rather than on `task`, because "Make a karaoke
    /// track" is a `separate` too and it promises one thing, not a count of
    /// stems.
    private var commitTitle: String {
        guard recipe.id == "split-instruments", !priorKinds.isEmpty else {
            return recipe.name
        }
        let count = priorKinds.count
        return "Split into \(count) part\(count == 1 ? "" : "s")"
    }

    private var costLine: String? {
        let destination = task == "analyze"
            ? "ATTACHED TO THE SONG"
            : "SAVED TO LIBRARY › PARTS"
        return ActionFormat.join([ActionFormat.estimate(estimateSeconds),
                                  destination])
    }

    private var costSubline: String? { "ORIGINAL IS NEVER MODIFIED" }

    // MARK: - Rail

    /// The kinds this model has produced before, in the order the library holds
    /// them. Nothing in `capabilities` declares an output list, so rather than
    /// invent one the rail reports the model's own track record and falls back
    /// to naming the output class.
    ///
    /// Asks the repository rather than reading `parts.results`: that array is
    /// whatever the Library › Parts filter bar last narrowed it to, and those
    /// filters are not reset on leaving the Library. Filtered to "Vocals", the
    /// whole rail would claim this model only ever produces one part.
    private var priorKinds: [String] {
        guard let model else { return [] }
        let all = (try? parts.repository.parts(.init())) ?? []
        var seen: [String] = []
        for part in all where part.modelId == model.id {
            if !seen.contains(part.kind) { seen.append(part.kind) }
        }
        return seen
    }

    private var expectedOutputs: [ActionOutput] {
        let lengthMeta = source?.durationS.map {
            ActionFormat.length($0)
        }
        if task == "analyze" {
            return [ActionOutput(id: "analysis",
                                 name: "Tempo, key, beats, sections",
                                 meta: "ATTACHED TO THE SONG")]
        }
        guard !priorKinds.isEmpty else {
            let makesNotes = task == "transcribe" || task == "compose"
            return [ActionOutput(id: "parts",
                                 name: makesNotes ? "Note parts" : "Parts",
                                 meta: makesNotes ? "MIDI" : "WAV",
                                 kind: makesNotes ? "notes" : nil)]
        }
        return priorKinds.map { kind in
            ActionOutput(id: kind, name: ActionCopy.kindLabel(kind),
                         meta: ActionFormat.join([
                            lengthMeta,
                            kind.hasPrefix("notes.") ? "MIDI" : "WAV"]),
                         kind: kind)
        }
    }

    private var railExplanation: String? {
        guard let source else { return note }
        return "Parts stay linked to \(source.sourceTitle), so Find matches and "
            + "the Workbench can beat-align them automatically."
    }

    private func replay() {
        guard let entry = ActionRunLog.decoded(runsJSON).runs[recipe.id]
        else { return }
        if let sourceId = entry.sourceId,
           let material = PickedMaterial.resolve(id: sourceId, parts: parts,
                                                 library: library) {
            source = material
        }
        if let modelId = entry.modelId,
           eligibleModels.contains(where: { $0.id == modelId }) {
            selectedModelId = modelId
        }
    }

    // MARK: - Lifecycle

    private func restore() {
        if source == nil, let sourceId {
            source = PickedMaterial.resolve(id: sourceId, parts: parts,
                                            library: library)
        }
        if selectedModelId == nil {
            // Settings' default separator leads, for separations only —
            // transcription recipes have specialists of their own. Then the
            // card's favourite when it is installed: several of these tasks
            // have a specialist that is strictly better at one job and
            // invisible in an alphabetical list. Still only a preference: the
            // picker below lists everything that can run the task.
            let chosen = task == "separate" ? settings.defaultSeparatorId : nil
            selectedModelId = [chosen].compactMap(\.self)
                .first(where: { id in eligibleModels.contains { $0.id == id } })
                ?? recipe.prefersModelIds.first(where: { id in
                    eligibleModels.contains { $0.id == id }
                }) ?? eligibleModels.first?.id
        }
        rebuildForm()
    }

    // MARK: - Submit

    private func submit(returningToGallery: Bool) {
        guard let source, let model else { return }
        submitting = true
        let analyseToo = alsoAnalyse ? installedModel(task: "analyze") : nil
        let transcribeToo = alsoTranscribe && task != "transcribe"
            ? installedModel(task: "transcribe") : nil
        Task {
            var params = formState.params
            // Extra audio/file params (a reference voice, a .nam capture)
            // travel as uploads — same loop the Studio submit runs.
            for (key, url) in formState.audioSelections {
                guard let uploadId = await jobs.uploadAudio(fileURL: url) else {
                    submitting = false
                    return  // uploadAudio surfaced the error
                }
                params[key] = .string(uploadId)
            }
            let created: JobsCreated?
            switch task {
            // `songId` for the two that make parts, because parts belong to
            // songs and there is no part-of-a-part: transcribing a stem files
            // its notes under the song the stem came from, exactly as
            // `submitRender` already does. `analysisOwner` for the one that
            // makes a measurement, because that belongs to the thing measured.
            // The title is the material's own name, which for a song is its
            // title and for a part is the part.
            case "transcribe":
                created = await jobs.submitTranscribe(
                    modelId: model.id, songId: source.songId,
                    sourceTitle: source.name, sourceURL: source.fileURL,
                    params: params)
            case "analyze":
                created = await jobs.submitAnalyze(
                    modelId: model.id, ownerId: source.analysisOwner.id,
                    ownerType: source.analysisOwner.type, title: source.name,
                    sourceURL: source.fileURL, params: params)
            case "separate":
                created = await jobs.submitSplit(
                    modelId: model.id, songId: source.songId,
                    sourceTitle: source.name, sourceURL: source.fileURL,
                    params: params)
            case "compose":
                // The picked notes part rides the card's own param key
                // ("melody_midi"), not source_audio — compose models read
                // notes, not audio.
                created = await jobs.submitComposeFromNotes(
                    modelId: model.id, songId: source.songId,
                    sourceTitle: source.name, sourceURL: source.fileURL,
                    inputKey: recipe.sourceParamKey ?? "melody_midi",
                    params: params)
            default:
                // The audio-transformation tasks (timbre / reamp /
                // convert-voice / sing): one stem back, filed as a part.
                created = await jobs.submitAudioTransform(
                    task: task, modelId: model.id, songId: source.songId,
                    sourceTitle: source.name, sourceURL: source.fileURL,
                    params: params)
            }
            if let analyseToo {
                await jobs.submitAnalyze(
                    modelId: analyseToo.id, ownerId: source.analysisOwner.id,
                    ownerType: source.analysisOwner.type, title: source.name,
                    sourceURL: source.fileURL)
            }
            if let transcribeToo {
                await jobs.submitTranscribe(
                    modelId: transcribeToo.id, songId: source.songId,
                    sourceTitle: source.name, sourceURL: source.fileURL,
                    params: [:])
            }
            submitting = false
            // "LAST RUN OF THIS ACTION" and the gallery's "Recently used" are
            // claims that a job exists. With the backend down every submit
            // returns nil, and a rail that remembers a run nobody made is
            // worse than one that remembers nothing.
            guard created != nil else { return }
            record(source: source, model: model)
            if returningToGallery, jobs.lastError == nil { onBack() }
        }
    }

    private func record(source: PickedMaterial, model: ModelInfo) {
        let outcome = switch task {
        case "transcribe": "notes"
        case "analyze": "features"
        default: "parts"
        }
        runsJSON = ActionRunLog.recording(
            .init(summary: "\(source.sourceTitle) → \(outcome)",
                  detail: ActionFormat.join([
                    model.displayName.uppercased(),
                    ActionRunLog.changedParams(formState)]),
                  at: Date(), sourceId: source.id, modelId: model.id),
            recipeId: recipe.id, in: runsJSON)
    }

    // MARK: - Nudge

    /// Analysis powers every alignment badge and auto-match in the app, so the
    /// first split is where it is worth saying so — once, dismissibly.
    private var analysisNudge: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Get tempo & key badges")
                    .font(Bench.Typo.bodyEmphasis)
                    .foregroundStyle(Bench.Palette.textPrimary)
                Text("Install Musical analysis (81 MB) to unlock alignment, "
                     + "compatibility badges and auto-match.")
                    .font(Bench.Typo.small)
                    .foregroundStyle(Bench.Palette.textQuaternary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Open Models", action: onOpenModels)
                .buttonStyle(.benchSecondary)
            Button {
                analysisCardDismissed = true
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Bench.Palette.textFaint)
                    .padding(6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Don't show again")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .benchCard(fill: Bench.Palette.statusCard,
                   stroke: Bench.Palette.cardStrokeSoft)
    }
}

// MARK: - Check chip

/// `✓ Tempo & key` — a checkbox that keeps its label and its reason visible.
/// A disabled one dims to the design's 45% and says why in the same pill, which
/// is the fifth rule: inapplicable controls explain themselves rather than
/// disappearing.
struct ActionCheckChip: View {
    let label: String
    @Binding var isOn: Bool
    var disabledReason: String?

    var body: some View {
        Button {
            guard disabledReason == nil else { return }
            isOn.toggle()
        } label: {
            HStack(spacing: 7) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(isOn ? Bench.Palette.accent : .clear)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(isOn ? .clear : Color.white.opacity(0.2),
                                      lineWidth: 1.5)
                    if isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Bench.Palette.onAccent)
                    }
                }
                .frame(width: 13, height: 13)
                Text(label)
                    .font(Bench.Typo.small)
                    .foregroundStyle(isOn ? Bench.Palette.textPrimary
                                          : Bench.Palette.textSecondary)
                if let disabledReason {
                    Text("— \(disabledReason)")
                        .font(Bench.Typo.small)
                        .foregroundStyle(Bench.Palette.textFaintest)
                }
            }
            .padding(.horizontal, 11).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.controlLarge,
                                         style: .continuous)
                .fill(Bench.Palette.control))
            .contentShape(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.controlLarge,
                                           style: .continuous))
        }
        .buttonStyle(.plain)
        .opacity(disabledReason == nil ? 1 : 0.45)
    }
}

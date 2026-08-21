import SwiftUI

/// Config page for the literal-recombination recipes: mash-up, swap vocals,
/// replace drums, polish.
///
/// The submission path is untouched from the old sheet — slots become
/// `IngredientSubmission`s in slot order, and the two auto-match switches plus
/// the target grid become `RecombineOptions`. What changed is that the page can
/// now say, before you commit, what the alignment is going to do to each
/// ingredient, and Polish the Mix can state plainly that it will do nothing of
/// the sort.
struct MixActionView: View {
    let recipe: Recipe
    let sourceId: String?
    let catalog: ModelCatalogStore
    let library: LibraryStore
    let parts: PartsStore
    let jobs: JobsStore
    let playback: PlaybackController
    let onOpenModels: () -> Void
    let onBack: () -> Void

    @State private var filled: [String: [PickedMaterial]] = [:]
    @State private var pickingSlot: Slot?
    /// slotId → songId of a split we kicked off from the picker, so the slot
    /// fills itself the moment matching parts land.
    @State private var pendingAutofill: [String: String] = [:]
    @State private var autoMatchTempo = true
    @State private var autoMatchKey = true
    @State private var targetBpm: Double?
    @State private var targetCamelot: String?
    @State private var name = ""
    @State private var submitting = false
    @AppStorage("actions.lastRuns") private var runsJSON = "{}"

    private var defaults: MixDefaults {
        if case .mix(let d) = recipe.engine { return d }
        return MixDefaults()
    }

    private var mixModel: ModelInfo? {
        MixModels.mixdown(in: catalog.models)
    }

    private var allPicked: [PickedMaterial] {
        recipe.slots.flatMap { filled[$0.id] ?? [] }
    }

    private var slotsSatisfied: Bool {
        recipe.slots.allSatisfy { slot in
            (filled[slot.id] ?? []).count >= slot.arity.lowerBound
        }
    }

    private var defaultName: String {
        let titles = Array(NSOrderedSet(
            array: allPicked.map(\.sourceTitle))) as? [String] ?? []
        let joined = titles.prefix(2).joined(separator: " × ")
        return joined.isEmpty ? recipe.name : "\(recipe.name): \(joined)"
    }

    var body: some View {
        ActionPage(recipe: recipe, onBack: onBack) {
            if mixModel == nil {
                ActionModelGate(
                    readiness: catalog.readiness,
                    title: "Mixdown & Align is not installed",
                    detail: "Every exact recombination is rendered by the "
                        + "Mixdown & Align DSP model. It is free and has no "
                        + "weights to download.",
                    onOpenModels: onOpenModels)
            }
            ForEach(recipe.slots) { slot in
                slotCard(slot)
            }
            matchCard
            ActionOptionsCard(eyebrow: "NAME") {
                ActionTextField(placeholder: defaultName, text: $name)
            }
        } commit: {
            ActionCommitRow(title: recipe.name,
                            costLine: costLine,
                            costSubline: "ORIGINALS ARE NEVER MODIFIED",
                            isEnabled: slotsSatisfied && mixModel != nil
                                && !submitting,
                            error: jobs.lastError,
                            onCommit: { create(returningToGallery: true) },
                            onQueue: { create(returningToGallery: false) })
        } rail: {
            ActionRail(outputs: expectedOutputs,
                       explanation: railExplanation,
                       lastRun: ActionRunLog.decoded(runsJSON).runs[recipe.id],
                       onReplay: replay)
        }
        .onAppear(perform: restore)
        .onChange(of: parts.results) { tryAutofill() }
        .sheet(item: $pickingSlot) { slot in
            PartPickerSheet(
                slotLabel: slot.label, accepts: slot.accepts,
                autoDerive: slot.autoDerive,
                catalog: catalog, library: library, parts: parts, jobs: jobs,
                playback: playback, onOpenModels: onOpenModels,
                onPick: { fill(slot: slot, with: $0) },
                onSplitStarted: { songId in
                    pendingAutofill[slot.id] = songId
                })
        }
    }

    // MARK: - Slots

    @ViewBuilder
    private func slotCard(_ slot: Slot) -> some View {
        let picked = filled[slot.id] ?? []
        if slot.arity.upperBound == 1 {
            ActionSourceCard(
                eyebrow: slot.label.uppercased(),
                material: picked.first,
                meta: picked.first.map {
                    ActionCopy.sourceMeta($0, library: library, parts: parts)
                },
                playback: playback,
                placeholder: slot.arity.lowerBound == 0
                    ? "Optional — leave empty to skip it."
                    : "Choose a part or a whole song.",
                chooseTitle: picked.isEmpty ? "Choose from Library…" : "Change…",
                onChoose: { pickingSlot = slot },
                onRemove: picked.isEmpty ? nil : { filled[slot.id] = [] })
        } else {
            ActionOptionsCard {
                HStack(spacing: 10) {
                    Text(slot.label.uppercased()).eyebrow()
                    Text("\(picked.count)/\(slot.arity.upperBound)")
                        .metaLine()
                    Spacer(minLength: 8)
                    if pendingAutofill[slot.id] != nil {
                        HStack(spacing: 6) {
                            BenchSpinner(size: 12)
                            Text("SPLITTING — WILL FILL ITSELF").metaLine()
                        }
                    }
                    if picked.count < slot.arity.upperBound {
                        Button("Add part…") { pickingSlot = slot }
                            .buttonStyle(BenchSecondaryButtonStyle(
                                tone: .quiet,
                                padding: .init(top: 6, leading: 10,
                                               bottom: 6, trailing: 10),
                                radius: Bench.Metrics.Radius.control))
                    }
                }
                if picked.isEmpty {
                    ActionFootnote(
                        text: "Needs at least \(slot.arity.lowerBound). Parts "
                            + "from different songs are fine — they get "
                            + "beat-aligned below.")
                } else {
                    VStack(spacing: 7) {
                        ForEach(picked) { material in
                            ActionMaterialRow(
                                material: material, playback: playback,
                                meta: ActionCopy.sourceMeta(
                                    material, library: library, parts: parts),
                                onRemove: {
                                    filled[slot.id]?.removeAll {
                                        $0.id == material.id
                                    }
                                })
                        }
                    }
                }
            }
        }
    }

    // MARK: - Alignment

    @ViewBuilder
    private var matchCard: some View {
        let audio = allPicked.filter { !$0.kind.hasPrefix("notes.") }
        if defaults.stretch {
            ActionOptionsCard(eyebrow: "ALIGNMENT") {
                HStack(spacing: 10) {
                    BenchToggleChip(isOn: $autoMatchTempo, label: "Match tempo")
                    BenchToggleChip(isOn: $autoMatchKey, label: "Match key")
                    Spacer(minLength: 8)
                    targetMenus
                }
                if audio.count >= 2, autoMatchTempo || autoMatchKey,
                   let narration = MatchNarrator.narrate(planned(audio)) {
                    ActionFootnote(text: narration,
                                   tone: Bench.Palette.textQuaternary)
                } else if audio.count < 2 {
                    ActionFootnote(
                        text: "Alignment has nothing to do until two pieces of "
                            + "audio are in the recipe.")
                }
            }
        } else {
            ActionOptionsCard(eyebrow: "ALIGNMENT") {
                ActionFootnote(
                    text: "\(recipe.name) never stretches or transposes. It "
                        + "normalises loudness and limits true peaks, and "
                        + "leaves every sample otherwise as it found it.")
            }
        }
    }

    private func planned(_ audio: [PickedMaterial])
        -> [(name: String, plan: MatchPlan)] {
        let target = targetSummary
        return audio.compactMap { material in
            guard let summary = summary(for: material) else { return nil }
            return (name: material.name,
                    plan: Mashability.plan(source: summary, target: target,
                                           isDrums: material.kind
                                              .hasPrefix("stem.drums")))
        }
    }

    private var targetMenus: some View {
        HStack(spacing: 8) {
            ActionFieldMenu(
                unit: "TEMPO",
                value: effectiveTargetBpm.map { String(format: "%.1f", $0) }
                    ?? "—") {
                Button("Auto") { targetBpm = nil }
                ForEach(Array(Set(allPicked.compactMap {
                    summary(for: $0)?.bpm
                })).sorted(), id: \.self) { bpm in
                    Button("\(Int(bpm.rounded())) BPM") { targetBpm = bpm }
                }
            }
            ActionFieldMenu(unit: "KEY",
                            value: effectiveTargetCamelot ?? "—") {
                Button("Auto") { targetCamelot = nil }
                ForEach(1...12, id: \.self) { n in
                    ForEach(["A", "B"], id: \.self) { letter in
                        Button("\(n)\(letter)") { targetCamelot = "\(n)\(letter)" }
                    }
                }
            }
        }
    }

    // MARK: - Copy

    private var estimateSeconds: Double? {
        let longest = allPicked.compactMap(\.durationS).max()
        return ActionEstimate.taskSeconds(model: mixModel,
                                          sourceDurationS: longest)
    }

    private var costLine: String? {
        ActionFormat.join([ActionFormat.estimate(estimateSeconds),
                           "SAVED TO LIBRARY › SONGS"])
    }

    private var expectedOutputs: [ActionOutput] {
        let length = allPicked.compactMap(\.durationS).max()
            .map { ActionFormat.length($0) }
        return [ActionOutput(id: "mix",
                             name: name.isEmpty ? defaultName : name,
                             meta: ActionFormat.join([length, "WAV"]))]
    }

    private var railExplanation: String? {
        var line = "One new song in Library › Songs, tagged with this recipe "
            + "and every part that went into it, so it can be reopened in the "
            + "Workbench later."
        if !defaults.stretch {
            line += " Nothing is stretched or transposed."
        }
        return line
    }

    // MARK: - Logic (unchanged wire assembly)

    private var effectiveTargetBpm: Double? {
        targetBpm ?? allPicked.compactMap { summary(for: $0)?.bpm }.first
    }

    private var effectiveTargetCamelot: String? {
        targetCamelot ?? allPicked.compactMap { summary(for: $0)?.camelot }.first
    }

    private var targetSummary: AnalysisSummary {
        AnalysisSummary(bpm: effectiveTargetBpm,
                        camelot: effectiveTargetCamelot)
    }

    private func summary(for material: PickedMaterial) -> AnalysisSummary? {
        AnalysisSummary(record: parts.analysis(for: material.id))
    }

    private func fill(slot: Slot, with material: PickedMaterial) {
        var list = filled[slot.id] ?? []
        guard !list.contains(where: { $0.id == material.id }) else { return }
        if list.count >= slot.arity.upperBound { list.removeLast() }
        list.append(material)
        filled[slot.id] = list
    }

    private func tryAutofill() {
        for (slotId, songId) in pendingAutofill {
            guard let slot = recipe.slots.first(where: { $0.id == slotId })
            else { continue }
            if let match = parts.results.first(where: {
                $0.songId == songId && slot.accepts(kind: $0.kind)
            }) {
                let title = ((try? library.repository.song(id: songId)) ?? nil)?
                    .title ?? match.modelName
                fill(slot: slot, with: PickedMaterial(part: match,
                                                      sourceTitle: title))
                pendingAutofill[slotId] = nil
            }
        }
    }

    private func restore() {
        autoMatchTempo = defaults.stretch && defaults.autoMatchTempo
        autoMatchKey = defaults.stretch && defaults.autoMatchKey
        guard let sourceId, allPicked.isEmpty,
              let material = PickedMaterial.resolve(id: sourceId, parts: parts,
                                                    library: library),
              let slot = recipe.slots.first(where: {
                  $0.accepts(kind: material.kind)
              })
        else { return }
        fill(slot: slot, with: material)
    }

    private func replay() {
        guard let entry = ActionRunLog.decoded(runsJSON).runs[recipe.id],
              let sourceId = entry.sourceId,
              let material = PickedMaterial.resolve(id: sourceId, parts: parts,
                                                    library: library),
              let slot = recipe.slots.first(where: {
                  $0.accepts(kind: material.kind)
              })
        else { return }
        fill(slot: slot, with: material)
    }

    private func create(returningToGallery: Bool) {
        guard let mixModel else { return }
        submitting = true
        let ingredients = recipe.slots.flatMap { slot in
            (filled[slot.id] ?? []).map {
                IngredientSubmission(slotId: slot.id, partId: $0.id)
            }
        }
        let options = RecombineOptions(
            autoMatchTempo: defaults.stretch && autoMatchTempo,
            autoMatchKey: defaults.stretch && autoMatchKey,
            targetBpm: targetBpm, targetCamelot: targetCamelot)
        let title = name.isEmpty ? defaultName : name
        let first = allPicked.first
        Task {
            let created = await jobs.submitRecombine(
                modelId: mixModel.id, recipeId: recipe.id, title: title,
                ingredients: ingredients, options: options)
            submitting = false
            guard created != nil else { return }
            runsJSON = ActionRunLog.recording(
                .init(summary: title,
                      detail: ActionFormat.join([
                        "\(ingredients.count) PARTS",
                        autoMatchTempo ? "TEMPO MATCHED" : nil,
                        autoMatchKey ? "KEY MATCHED" : nil]),
                      at: Date(), sourceId: first?.id, modelId: mixModel.id),
                recipeId: recipe.id, in: runsJSON)
            if returningToGallery { onBack() }
        }
    }
}

// MARK: - Mono field menu

/// `TEMPO 107.0 ⌄` — a menu whose *value* is a number, so it is mono and sits
/// beside a mono unit label.
///
/// `BenchMenu` draws its label in the prose face, which is right for
/// `Any model ⌄` and wrong for a tempo: the design sets this control as
/// `TEMPO` mono 10 + `107.0` mono semibold 12. The Workbench's align bar draws
/// the same pair with `WorkbenchFieldMenu`; this is that control, for the
/// pages that are not the Workbench.
struct ActionFieldMenu<Content: View>: View {
    let unit: String
    let value: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        Menu {
            content()
        } label: {
            HStack(spacing: 8) {
                Text(unit)
                    .font(Bench.Typo.mono(10))
                    .foregroundStyle(Bench.Palette.textMuted)
                Text(value)
                    .font(Bench.Typo.mono(12, .semibold))
                    .foregroundStyle(Bench.Palette.textPrimary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Bench.Palette.textFaintest)
            }
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.button,
                                         style: .continuous)
                .fill(Bench.Palette.raised))
            .overlay(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.button,
                                      style: .continuous)
                .strokeBorder(Bench.Palette.cardStrokeSoft, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

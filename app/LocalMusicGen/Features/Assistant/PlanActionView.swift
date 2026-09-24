// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// The page behind the four "model's own plan" cards.
///
/// ACE-Step renders in two halves: a small language model writes a plan — the
/// tempo, key, time signature and a coarse sketch of the whole song — and only
/// then does the expensive diffusion half render that plan into audio. The
/// planning half is cheap. That asymmetry is the entire feature: you can read
/// three plans in less time than one render takes, and then pay for only the
/// one you wanted.
///
/// All four modes share this page because they share the same two halves —
/// obtain a plan, then do something with it. What differs is where the plan
/// comes from (rolled fresh, or read off a take you already have) and what the
/// button at the bottom does.
struct PlanActionView: View {
    let recipe: Recipe
    let mode: PlanCardMode
    let sourceId: String?
    let catalog: ModelCatalogStore
    let library: LibraryStore
    let parts: PartsStore
    let jobs: JobsStore
    let plans: PlanStore
    let playback: PlaybackController
    let onOpenModels: () -> Void
    let onOpenGenerate: (GeneratePreset, String?) -> Void
    let onBack: () -> Void

    @State private var source: PickedMaterial?
    /// The source card's second line, resolved when the source changes.
    ///
    /// `ActionCopy.sourceMeta` is a song read plus an analysis read, and asked
    /// for from inside `body` it ran on every pass of a page that has text
    /// fields on it. The line only depends on the material, so it is resolved
    /// with it.
    @State private var sourceMeta: String?
    @State private var choosing = false
    @State private var selectedModelId: String?
    @State private var caption = ""
    @State private var lyrics = ""
    @State private var durationS: Double = 60
    @State private var howMany = 3
    @State private var chosenPlan: Int?
    @State private var submitting = false
    @State private var pinnedBpm = ""
    @State private var pinnedKey = ""
    @State private var pinnedTime = ""
    /// The merged card's two starts: roll fresh plans, or read the plan back
    /// off a take you already rendered — the job the plan-inspect and
    /// plan-reroll cards used to carry. Only the choose card offers the
    /// switch; a deep link arriving on another mode keeps that mode.
    @State private var fromTake = false

    private var activeMode: PlanCardMode {
        mode == .choose && fromTake ? .reroll : mode
    }
    @AppStorage("actions.lastRuns") private var runsJSON = "{}"

    private var slot: Slot? { recipe.slots.first }
    private var phase: PlanStore.Phase { plans.phase(recipe.id) }

    private var eligible: [ModelInfo] {
        PlanModels.installed(catalog.models)
    }

    private var model: ModelInfo? {
        eligible.first { $0.id == selectedModelId } ?? eligible.first
    }

    /// For inspect and reroll, the plan comes off the take rather than from a
    /// fresh run — it is stored with the song when it was generated.
    private var storedPlan: SongPlan? {
        guard let source, let song = library.song(id: source.songId),
              let data = song.paramsJSON.data(using: .utf8),
              let params = try? JSONDecoder().decode([String: JSONValue].self,
                                                     from: data)
        else { return nil }
        return SongPlan.of(meta: params["meta"]?.objectValue)
    }

    private var visiblePlans: [SongPlan] {
        switch activeMode {
        case .choose: phase.plans
        case .inspect, .reroll: storedPlan.map { [$0] } ?? []
        case .pin: phase.plans
        }
    }

    var body: some View {
        ActionPage(recipe: recipe, onBack: onBack) {
            if mode == .choose {
                BenchSegmented(selection: $fromTake, options: [
                    .init(value: false, label: "Fresh plans"),
                    .init(value: true, label: "From a take"),
                ])
            }
            if fromTake || !recipe.slots.isEmpty {
                ActionSourceCard(
                    eyebrow: "TRACK",
                    material: source,
                    meta: sourceMeta,
                    playback: playback,
                    placeholder: "A song this app generated. Imported audio has "
                        + "no plan — nothing wrote one.",
                    chooseTitle: source == nil ? "Choose from Library…" : "Change…",
                    onChoose: { choosing = true },
                    onRemove: source == nil ? nil : { source = nil })
            }
            if eligible.isEmpty {
                ActionModelGate(
                    readiness: catalog.readiness,
                    title: "No model here plans before it renders",
                    detail: "ACE-Step writes a plan — tempo, key, the shape of "
                        + "the song — before it renders anything. Install one "
                        + "of its variants to see and steer that step.",
                    onOpenModels: onOpenModels)
            } else {
                if activeMode == .choose || activeMode == .pin {
                    describeCard
                    // The old "Lock in the tempo and key" card, folded in:
                    // `requestPlans` has always sent the pins, only the
                    // fields were hidden outside the pin card.
                    pinCard
                }
                planCards
            }
        } commit: {
            ActionCommitRow(title: commitTitle,
                            costLine: costLine,
                            costSubline: commitSubline,
                            isEnabled: canCommit,
                            error: errorText,
                            onCommit: { commit(back: true) },
                            onQueue: canQueue ? { commit(back: false) } : nil)
        } rail: {
            ActionRail(outputs: outputs,
                       explanation: railExplanation,
                       lastRun: ActionRunLog.decoded(runsJSON).runs[recipe.id])
        }
        .onChange(of: source, initial: true) {
            sourceMeta = source.map {
                ActionCopy.sourceMeta($0, library: library, parts: parts)
            }
            if fromTake, let source,
               let song = library.song(id: source.songId) {
                caption = song.prompt
                lyrics = song.lyrics ?? ""
                durationS = song.durationS
            }
        }
        .onAppear {
            if source == nil, let sourceId {
                source = PickedMaterial.resolve(id: sourceId, parts: parts,
                                                library: library)
            }
            if selectedModelId == nil { selectedModelId = eligible.first?.id }
            // Reroll and inspect read a plan the take already carries, so
            // seeding the description from the song it came from means the
            // re-render says what the original said.
            if caption.isEmpty, let source,
               let song = library.song(id: source.songId) {
                caption = song.prompt
                lyrics = song.lyrics ?? ""
                durationS = song.durationS
            }
        }
        .onDisappear { plans.clear(recipe.id) }
        .onChange(of: fromTake) { _, _ in
            chosenPlan = nil
            plans.clear(recipe.id)
            // The take's own words seed the re-render, as the reroll card
            // always did on arrival.
            if fromTake, let source, let song = library.song(id: source.songId) {
                caption = song.prompt
                lyrics = song.lyrics ?? ""
                durationS = song.durationS
            }
        }
        .sheet(isPresented: $choosing) {
            PartPickerSheet(
                slotLabel: slot?.label ?? "Song",
                accepts: slot?.accepts ?? [KindPattern(pattern: "song.mix")],
                autoDerive: slot?.autoDerive,
                catalog: catalog, library: library, parts: parts, jobs: jobs,
                playback: playback, onOpenModels: onOpenModels,
                onPick: { source = $0 })
        }
    }

    // MARK: - Cards

    private var describeCard: some View {
        ActionOptionsCard(eyebrow: "THE SONG") {
            VStack(alignment: .leading, spacing: 10) {
                AssistField(text: $caption,
                            placeholder: "Describe the music you want…",
                            multiline: true)
                AssistField(text: $lyrics,
                            placeholder: "Lyrics (optional)",
                            multiline: true)
                HStack(spacing: 12) {
                    Text("\(Int(durationS))s")
                        .font(Bench.Typo.metaLine)
                        .foregroundStyle(Bench.Palette.textTertiary)
                    Slider(value: $durationS, in: 10...300, step: 5)
                        .frame(maxWidth: 240)
                    if activeMode == .choose {
                        Picker("Plans", selection: $howMany) {
                            ForEach([2, 3, 4, 5], id: \.self) {
                                Text("\($0) plans").tag($0)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(width: 110)
                    }
                    Spacer()
                }
                ActionModelPicker(eyebrow: "PLANNER", models: eligible,
                                  selectedId: Binding(
                                    get: { model?.id },
                                    set: { selectedModelId = $0 }),
                                  meta: { _ in "INSTALLED" })
                HStack(spacing: 10) {
                    AssistButton(
                        title: phase.isWorking
                            ? "Planning…"
                            : (visiblePlans.isEmpty ? planButtonTitle
                                                    : "Plan again"),
                        action: requestPlans)
                        .disabled(!canPlan)
                    Spacer()
                }
            }
        }
    }

    /// Card 11: the facts you take out of the model's hands.
    private var pinCard: some View {
        ActionOptionsCard(eyebrow: "YOUR CALL — OPTIONAL") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    AssistField(text: $pinnedBpm, placeholder: "Tempo (BPM)")
                        .frame(width: 140)
                    AssistField(text: $pinnedKey, placeholder: "Key, e.g. F minor")
                        .frame(width: 190)
                    AssistField(text: $pinnedTime, placeholder: "Time, e.g. 4")
                        .frame(width: 150)
                    Spacer()
                }
                ActionFootnote(
                    text: "Anything you fill in here, the model stops choosing "
                        + "for itself. Leave a box empty and it decides — which "
                        + "is what the plan below shows it doing.")
            }
        }
    }

    @ViewBuilder
    private var planCards: some View {
        switch phase {
        case .working:
            ActionOptionsCard(eyebrow: "WORKING") {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Writing \(howMany) plans — no audio yet")
                        .font(Bench.Typo.body)
                        .foregroundStyle(Bench.Palette.textSecondary)
                }
            }
        case .failed(let message):
            ActionOptionsCard(eyebrow: "DIDN'T WORK") {
                ActionFootnote(text: message)
            }
        default:
            if visiblePlans.isEmpty {
                if activeMode == .inspect || activeMode == .reroll {
                    ActionOptionsCard(eyebrow: "NO PLAN") {
                        ActionFootnote(text: source == nil
                            ? "Choose a generated song to see what the model "
                                + "was thinking."
                            : "This track carries no plan. Either it was "
                                + "imported, or it was made by a model that "
                                + "renders in one pass with nothing to show.")
                    }
                }
            } else {
                ActionOptionsCard(eyebrow: planEyebrow) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(visiblePlans) { plan in
                            planRow(plan)
                        }
                    }
                }
            }
        }
    }

    private func planRow(_ plan: SongPlan) -> some View {
        let selectable = activeMode == .choose && plan.isRenderable
        let isChosen = chosenPlan == plan.index
            || (visiblePlans.count == 1 && activeMode != .choose)
        return Button {
            if selectable { chosenPlan = plan.index }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(activeMode == .choose ? "Plan \(plan.index + 1)"
                                         : "What it was thinking")
                        .font(Bench.Typo.bodyEmphasis)
                        .foregroundStyle(Bench.Palette.textPrimary)
                    if !plan.isRenderable {
                        BenchBadge("NOT RE-RENDERABLE", tone: .warn)
                    }
                    Spacer()
                }
                if plan.facts.isEmpty {
                    Text("It reported no details.")
                        .font(Bench.Typo.caption)
                        .foregroundStyle(Bench.Palette.textTertiary)
                } else {
                    // A wrapping row of label/value pairs, so a plan that
                    // reported two facts does not draw six empty slots.
                    FlowLayout(spacing: 14) {
                        ForEach(plan.facts, id: \.label) { fact in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(fact.label.uppercased()).eyebrow()
                                Text(fact.value)
                                    .font(Bench.Typo.body)
                                    .foregroundStyle(Bench.Palette.textPrimary)
                            }
                        }
                    }
                }
                if let caption = plan.caption {
                    Text(caption)
                        .font(Bench.Typo.caption)
                        .foregroundStyle(Bench.Palette.textSecondary)
                        .multilineTextAlignment(.leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(isChosen ? Bench.Palette.accent.opacity(0.12)
                               : Bench.Palette.inset))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(isChosen ? Bench.Palette.accent : Bench.Palette.hairline,
                        lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!selectable)
    }

    // MARK: - Actions

    private var pinned: PlanStore.PinnedFacts {
        PlanStore.PinnedFacts(
            bpm: Int(pinnedBpm.trimmingCharacters(in: .whitespaces)),
            keyscale: pinnedKey.trimmingCharacters(in: .whitespaces).isEmpty
                ? nil : pinnedKey.trimmingCharacters(in: .whitespaces),
            timeSignature: pinnedTime.trimmingCharacters(in: .whitespaces).isEmpty
                ? nil : pinnedTime.trimmingCharacters(in: .whitespaces))
    }

    private var canPlan: Bool {
        !phase.isWorking && model != nil
            && !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func requestPlans() {
        guard let model else { return }
        chosenPlan = nil
        plans.plan(slot: recipe.id, model: model,
                   caption: caption.trimmingCharacters(in: .whitespacesAndNewlines),
                   lyrics: lyrics, durationS: durationS,
                   count: activeMode == .pin ? 1 : howMany,
                   pinned: pinned)
    }

    /// The plan the commit button will act on.
    private var actingPlan: SongPlan? {
        if let chosenPlan {
            return visiblePlans.first { $0.index == chosenPlan }
        }
        return visiblePlans.count == 1 ? visiblePlans.first : nil
    }

    private var commitTitle: String {
        switch activeMode {
        case .choose: "Render this plan"
        case .inspect: "Reuse this description"
        case .reroll: "Record it again"
        case .pin: "Render with these locked in"
        }
    }

    private var commitSubline: String? {
        switch activeMode {
        case .reroll: "SAME SONG, DIFFERENT TAKE"
        case .inspect: "NOTHING RENDERS"
        default: "SAVED TO LIBRARY"
        }
    }

    private var costLine: String? {
        switch activeMode {
        case .inspect: "GOES TO › GENERATE"
        default: ActionFormat.join([
            ActionFormat.estimate(ActionEstimate.generativeSeconds(
                model: model, durationS: durationS)),
            "SAVED TO LIBRARY"])
        }
    }

    private var canCommit: Bool {
        guard !submitting, model != nil else { return false }
        switch activeMode {
        case .inspect: return actingPlan != nil
        case .choose: return actingPlan?.isRenderable == true
        case .reroll: return actingPlan?.isRenderable == true
        case .pin: return !caption.trimmingCharacters(
            in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var canQueue: Bool { activeMode != .inspect }

    private var errorText: String? {
        if case .failed(let message) = phase { return message }
        return jobs.lastError
    }

    private func commit(back: Bool) {
        guard let model else { return }
        if activeMode == .inspect {
            // Nothing to render: this card explains a take that already
            // exists. The useful onward move is the model's own words, which
            // are usually a better prompt than the one that produced them.
            guard let plan = actingPlan else { return }
            let preset = GeneratePreset.preset(id: "gen-instrumental")
            if let preset {
                onOpenGenerate(preset, source?.id)
            }
            _ = plan
            return
        }

        var params: [String: JSONValue] = pinned.params
        if let plan = actingPlan, plan.isRenderable {
            params["audio_codes"] = .string(plan.codes)
            // The plan already fixes these; sending them again would be the
            // same statement twice, and a disagreement between the two is a
            // bug waiting to happen.
            if let bpm = plan.bpm { params["bpm"] = .int(bpm) }
            if let key = plan.keyscale { params["keyscale"] = .string(key) }
        }
        if activeMode == .reroll {
            // A new seed is the whole point: same plan, different rendering
            // of it. Left unset the engine picks one, which is what we want.
            params.removeValue(forKey: "seed")
        }
        let wire = params.filter { model.declares($0.key) }
        let length = actingPlan?.durationS.map(Double.init) ?? durationS

        submitting = true
        Task {
            let created = await jobs.submit(
                modelId: model.id,
                prompt: caption.trimmingCharacters(in: .whitespacesAndNewlines),
                lyrics: lyrics.isEmpty ? nil : lyrics,
                durationS: length, count: 1, params: wire)
            submitting = false
            guard created != nil else { return }
            runsJSON = ActionRunLog.recording(
                ActionRunLog.Entry(
                    summary: activeMode == .reroll ? "Re-recorded a plan"
                                             : "Rendered a chosen plan",
                    detail: actingPlan?.summary ?? caption,
                    at: Date(), sourceId: source?.id, modelId: model.id),
                recipeId: recipe.id, in: runsJSON)
            if back, jobs.lastError == nil { onBack() }
        }
    }

    // MARK: - Copy

    private var planButtonTitle: String {
        activeMode == .pin ? "Show me the plan" : "Write \(howMany) plans"
    }

    private var planEyebrow: String {
        switch activeMode {
        case .choose: "PICK ONE — NOTHING HAS RENDERED YET"
        case .reroll: "THE PLAN BEHIND THIS TAKE"
        case .inspect: "WHAT THE MODEL DECIDED"
        case .pin: "WHAT IT FILLED IN"
        }
    }

    private var outputs: [ActionOutput] {
        guard activeMode != .inspect else { return [] }
        return [ActionOutput(id: "take", name: "A new take",
                             meta: ActionFormat.join([
                                ActionFormat.length(durationS), "WAV"]),
                             kind: "song.mix")]
    }

    private var railExplanation: String {
        switch mode {
        case .choose:
            "Writing a plan is quick; rendering one is not. You are reading "
                + "what the model intends before it spends the time — and only "
                + "the plan you pick gets rendered."
        case .inspect:
            "The tempo, key and shape the model settled on for this track. It "
                + "chose these from your description; anything you set "
                + "yourself, it left alone."
        case .reroll:
            "The same plan, rendered again from a different starting point. "
                + "The structure and timing hold; the performance and the "
                + "production change."
        case .pin:
            "Whatever you fill in, the model stops guessing. Everything you "
                + "leave blank it still decides, and the plan shows you what "
                + "it decided."
        }
    }
}

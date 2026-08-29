import SwiftUI

/// One track, one transform, no model — the page behind every card in
/// `TrackTransform`.
///
/// One page rather than seven, because seven pages that differ by which
/// slider they draw are seven places for the same bug. What each card supplies
/// is data: the control's name, its bounds, and the `RecombineOptions` it
/// produces. See `TrackTransform`.
struct TransformActionView: View {
    let recipe: Recipe
    let transform: TrackTransform
    let sourceId: String?
    let catalog: ModelCatalogStore
    let library: LibraryStore
    let parts: PartsStore
    let jobs: JobsStore
    let playback: PlaybackController
    let onOpenModels: () -> Void
    let onBack: () -> Void

    @State private var source: PickedMaterial?
    @State private var reference: PickedMaterial?
    /// The two source cards' second lines, resolved when their material
    /// changes.
    ///
    /// `ActionCopy.sourceMeta` is a song read plus an analysis read each, and
    /// both were being asked for from inside `body` — so four queries ran
    /// again on every redraw, including every drag of the amount slider. The
    /// lines only depend on the materials, so they are resolved with them.
    @State private var sourceMeta: String?
    @State private var referenceMeta: String?
    @State private var value: Double = 0
    @State private var startBar: Double = 0
    @State private var choosingSource = false
    @State private var choosingReference = false
    @State private var submitting = false
    @AppStorage("actions.lastRuns") private var runsJSON = "{}"
    /// The action log, decoded once rather than at render time.
    ///
    /// It lives in `@AppStorage` as a JSON blob, and the rail was asking for
    /// the whole thing to be parsed from inside `body` — so every redraw
    /// re-decoded it, which on a page with a text field is every keystroke.
    @State private var runLog = ActionRunLog()

    private var mixModel: ModelInfo? { MixModels.mixdown(in: catalog.models) }
    private var slot: Slot? { recipe.slots.first }
    private var referenceSlot: Slot? {
        recipe.slots.count > 1 ? recipe.slots[1] : nil
    }

    private func analysis(_ material: PickedMaterial?) -> AnalysisSummary? {
        guard let material else { return nil }
        return AnalysisSummary(record: parts.analysis(for: material.id))
    }

    private var sourceAnalysis: AnalysisSummary? { analysis(source) }

    /// Downbeats the loop is cut on. Empty is a real answer: a track nobody
    /// has analysed has no bars, and the card says so rather than inventing a
    /// grid from the tempo alone.
    private var downbeats: [Double] { sourceAnalysis?.downbeats ?? [] }

    private var canRun: Bool {
        guard source != nil, mixModel != nil, !submitting else { return false }
        if transform.needsReference && reference == nil { return false }
        if transform == .loop && loopSection == nil { return false }
        if transform == .conform && analysis(reference)?.bpm == nil {
            return false
        }
        return true
    }

    var body: some View {
        ActionPage(recipe: recipe, onBack: onBack) {
            ActionSourceCard(
                eyebrow: "TRACK",
                material: source,
                meta: sourceMeta,
                playback: playback,
                placeholder: "A song or a part from your library.",
                chooseTitle: source == nil ? "Choose from Library…" : "Change…",
                onChoose: { choosingSource = true },
                onRemove: source == nil ? nil : { source = nil })
            if transform.needsReference {
                ActionSourceCard(
                    eyebrow: "MATCH TO",
                    material: reference,
                    meta: referenceMeta,
                    playback: playback,
                    placeholder: "The track whose tempo and key to take. Only "
                        + "its measurements are used — none of its audio.",
                    chooseTitle: reference == nil ? "Choose from Library…"
                                                  : "Change…",
                    onChoose: { choosingReference = true },
                    onRemove: reference == nil ? nil : { reference = nil })
            }
            if mixModel == nil {
                ActionModelGate(
                    readiness: catalog.readiness,
                    title: "Mixdown & Align is not installed",
                    detail: "Every one of these runs on the engine's own DSP "
                        + "mixdown — beat-aligned stretch, pitch shift and a "
                        + "processor chain. No AI model, and it is free.",
                    onOpenModels: onOpenModels)
            } else {
                controls
            }
        } commit: {
            ActionCommitRow(title: commitTitle,
                            costLine: ActionFormat.join([
                                "SECONDS", "SAVED TO LIBRARY › RENDERS"]),
                            costSubline: "THE ORIGINAL IS UNTOUCHED",
                            isEnabled: canRun,
                            error: jobs.lastError,
                            onCommit: { submit(back: true) },
                            onQueue: { submit(back: false) })
        } rail: {
            ActionRail(outputs: outputs, explanation: explanation,
                       lastRun: runLog.runs[recipe.id])
        }
        .onAppear {
            if source == nil, let sourceId {
                source = PickedMaterial.resolve(id: sourceId, parts: parts,
                                                library: library)
            }
            if let bounds = transform.bounds { value = bounds.initial }
        }
        .onChange(of: source) {
            sourceMeta = source.map {
                ActionCopy.sourceMeta($0, library: library, parts: parts)
            }
        }
        .onChange(of: reference) {
            referenceMeta = reference.map {
                ActionCopy.sourceMeta($0, library: library, parts: parts)
            }
        }
        .task { runLog = ActionRunLog.decoded(runsJSON) }
        .onChange(of: runsJSON) { runLog = ActionRunLog.decoded(runsJSON) }
        .sheet(isPresented: $choosingSource) {
            picker(slot: slot, label: "Track") { source = $0 }
        }
        .sheet(isPresented: $choosingReference) {
            picker(slot: referenceSlot, label: "Track to match") {
                reference = $0
            }
        }
    }

    private func picker(slot: Slot?, label: String,
                        onPick: @escaping (PickedMaterial) -> Void) -> some View {
        PartPickerSheet(
            slotLabel: slot?.label ?? label,
            accepts: slot?.accepts ?? [KindPattern(pattern: "song.mix")],
            autoDerive: slot?.autoDerive, catalog: catalog, library: library,
            parts: parts, jobs: jobs, playback: playback,
            onOpenModels: onOpenModels, onPick: onPick)
    }

    @ViewBuilder
    private var controls: some View {
        if let bounds = transform.bounds, let title = transform.controlTitle {
            ActionOptionsCard(eyebrow: title) {
                HStack(spacing: 12) {
                    BenchSlider(value: $value, range: bounds.range,
                                step: bounds.step)
                    Text("\(valueText) \(transform.unit)")
                        .font(Bench.Typo.value)
                        .foregroundStyle(Bench.Palette.textPrimary)
                        .frame(width: 92, alignment: .trailing)
                }
                if transform == .loop { loopControls }
                ActionFootnote(text: footnote)
            }
        } else {
            ActionOptionsCard { ActionFootnote(text: footnote) }
        }
    }

    @ViewBuilder
    private var loopControls: some View {
        if downbeats.count < 2 {
            ActionFootnote(
                text: source == nil
                    ? "Pick a track and its bars appear here."
                    : "This track has no beat grid yet — run “Read the "
                        + "features” on it and the bars become selectable.",
                tone: Bench.Palette.warn)
        } else {
            HStack(spacing: 12) {
                Text("FROM BAR")
                    .font(Bench.Typo.mono(10))
                    .foregroundStyle(Bench.Palette.textFaintest)
                BenchSlider(value: $startBar,
                            range: 0...Double(max(1, downbeats.count - 1)),
                            step: 1)
                Text("\(Int(startBar) + 1)")
                    .font(Bench.Typo.value)
                    .foregroundStyle(Bench.Palette.textPrimary)
                    .frame(width: 46, alignment: .trailing)
            }
        }
    }

    /// The loop's cut points, on real downbeats or not at all.
    ///
    /// Clamped to the last downbeat rather than extrapolated: past the end of
    /// the measured grid there are no bars, only arithmetic, and a loop that
    /// ends mid-bar is the one thing a loop may not do.
    private var loopSection: (start: Double, end: Double)? {
        let bars = downbeats
        guard bars.count >= 2 else { return nil }
        let first = Int(startBar).clamped(to: 0...(bars.count - 2))
        let last = min(first + Int(value), bars.count - 1)
        guard last > first else { return nil }
        return (bars[first], bars[last])
    }

    private var valueText: String {
        switch transform {
        case .speed: String(format: "%.2f", value)
        case .key: value > 0 ? "+\(Int(value))" : "\(Int(value))"
        case .fades: String(format: "%.1f", value)
        default: "\(Int(value))"
        }
    }

    private var commitTitle: String {
        switch transform {
        case .reverse: "Reverse it"
        case .speed: "Render at \(valueText)×"
        case .key: "Shift by \(valueText) semitones"
        case .fades: "Add the fades"
        case .cleanUp: "Clean it up"
        case .loop: "Cut the loop"
        case .conform: "Conform it"
        }
    }

    private var footnote: String {
        switch transform {
        case .reverse:
            "Sample-for-sample, before anything else the engine does."
        case .speed:
            "Time-stretched, not resampled — the pitch stays where it was. "
                + "Above about 1.5× or below 0.7× it starts to sound like an "
                + "effect rather than a tempo."
        case .key:
            "Formants preserved, so a voice stays the same voice rather than "
                + "turning into a chipmunk on the way up."
        case .fades:
            "The same length at both ends. Set it to zero at one end in the "
                + "Editor if you want them different."
        case .cleanUp:
            "High-pass at 80 Hz, a gate at −55 dB and a gentle 2.5:1 "
                + "compressor. Sensible on a spoken or close-mic'd recording, "
                + "heavy-handed on a finished mix."
        case .loop:
            "Cut on measured downbeats, with a short ramp at each end so the "
                + "seam does not click. Not crossfaded — for a seamless loop, "
                + "overlap it yourself in the Workbench."
        case .conform:
            "Beat-aligned when the track has a grid, uniformly stretched when "
                + "it does not. Nothing of the reference is mixed in."
        }
    }

    private var explanation: String {
        transform == .conform
            ? "A new track at the reference's tempo and key, in Library › "
                + "Renders. Both originals are left alone."
            : "A new track in Library › Renders. The original is left alone."
    }

    private var outputs: [ActionOutput] {
        let name = source.map { "\(recipe.name): \($0.name)" } ?? recipe.name
        return [ActionOutput(id: "out", name: name, meta: "WAV",
                             kind: "song.mix")]
    }

    private func submit(back: Bool) {
        guard canRun, let source, let mixModel else { return }
        var options = transform.options(value: value)
        if transform == .conform, let reference = analysis(reference) {
            options.targetBpm = reference.bpm
            options.targetCamelot = reference.camelot
        }
        var ingredient = IngredientSubmission(slotId: slot?.id ?? "source",
                                              partId: source.id)
        if transform == .loop, let section = loopSection {
            ingredient.sectionStartS = section.start
            ingredient.sectionEndS = section.end
            // 8 ms is under a perceptible fade and over a click.
            ingredient.fadeInS = 0.008
            ingredient.fadeOutS = 0.008
        }
        let title = "\(recipe.name): \(source.name)"
        submitting = true
        Task {
            let created = await jobs.submitRecombine(
                modelId: mixModel.id, recipeId: recipe.id, title: title,
                ingredients: [ingredient], options: options)
            submitting = false
            guard created != nil else { return }
            runsJSON = ActionRunLog.recording(
                .init(summary: title, detail: detailForLog, at: Date(),
                      sourceId: source.id, modelId: mixModel.id),
                recipeId: recipe.id, in: runsJSON)
            if back { onBack() }
        }
    }

    private var detailForLog: String {
        switch transform {
        case .reverse: "REVERSED"
        case .speed: "\(valueText)× SPEED"
        case .key: "\(valueText) ST"
        case .fades: "\(valueText) S FADES"
        case .cleanUp: "HIGHPASS · GATE · COMPRESSOR"
        case .loop: "\(Int(value)) BARS FROM \(Int(startBar) + 1)"
        case .conform: ActionFormat.join([
            analysis(reference)?.bpm.map { "\(Int($0.rounded())) BPM" },
            analysis(reference)?.camelot])
        }
    }
}

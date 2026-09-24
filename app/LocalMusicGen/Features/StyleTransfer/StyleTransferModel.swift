// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Observation

/// The Style Transfer workspace's document.
///
/// Owned by `AppEnvironment` beside `workbench`, and for the same reason its
/// comment gives: this is somewhere you *work*, not a page you visit. A
/// configuration that survives being left and returned to is the entire
/// difference between this and the one-shot Action pages it replaces — leaving
/// to find a reference track in the Library and coming back to an empty form is
/// the failure the feature exists to remove.
///
/// Holds document state only. Submission and the multi-step chain live in
/// `StyleTransferModel+Run.swift`, which takes the stores it needs as
/// parameters rather than storing them, so this type stays a value-ish
/// document in the shape of `WorkbenchModel`.
@MainActor @Observable
final class StyleTransferModel {

    // MARK: - What is being transformed

    /// The track being transformed. Persisted as a `PickedMaterial` — which
    /// carries a **file URL**, never an upload id. Upload ids die with the
    /// engine (`uploads/` is purged at startup), so a workspace holding one
    /// across a backend restart would submit a job against a file that is gone.
    var source: PickedMaterial?

    /// The track whose sound is being borrowed, for the modes that take one.
    var reference: PickedMaterial?

    var mode: StyleTransferMode = .cover {
        didSet {
            guard mode != oldValue else { return }
            // The dial means something different in every mode — 0.3 on a
            // cover strength and 0.3 on a noise level are not the same
            // distance from the source — so carrying the number across would
            // silently change the run.
            styleAmount = nil
            // Same argument, and sharper: the length control changes unit
            // between modes. 30 carried from "Continue it" into "Keep the
            // shape" would turn "add half a minute" into "render half a
            // minute in total".
            lengthS = nil
            if !mode.trackNeed.isNeeded { track = nil }
            // A preset names one transformation. Once the user has moved off
            // it, this is no longer "Restyle this song" — and leaving the
            // attribution in place would file the run under that card's name in
            // the shared last-run log, where it would offer to set up something
            // the user never ran.
            if let presetId, StylePreset.preset(forRecipeId: presetId)?.mode
                != mode {
                self.presetId = nil
                presetName = nil
            }
        }
    }

    // MARK: - Controls

    var prompt = ""
    var lyrics = ""
    /// What the source *is*, for the modes that morph one description into
    /// another. Empty means "let the model read the audio itself".
    var sourceCaption = ""
    var outputName = ""
    var selectedModelId: String?
    var track: String?
    var regionStartS = 0.0
    var regionEndS = 8.0

    /// The unified `Original ←→ Style` dial, 0…1. `nil` means untouched, and
    /// untouched means the model's own default goes on the wire rather than a
    /// number the app invented.
    var styleAmount: Double?

    /// How long the result should be, in seconds, or `nil` for the workspace's
    /// own derivation.
    ///
    /// What the number *means* is the mode's `LengthPolicy`: a whole output
    /// length where the source only conditions the render, the tail to add
    /// where the source is kept inside the output. Cleared on a mode change for
    /// the same reason `styleAmount` is — 30 s of total and 30 s of tail are
    /// not the same run — and deliberately **kept** across a model change,
    /// where it is clamped to the new model's window instead, so comparing two
    /// models at the same length does not mean retyping it.
    var lengthS: Double?

    /// Which stems the `stems` mode preserves literally.
    var keptStems: Set<String> = []

    /// The advanced knobs the user has moved.
    ///
    /// Held here rather than inside a `ParameterFormState` because that type's
    /// `specs` is a `let`: switching model forces a brand-new form state and
    /// throws away every knob. Keeping the overrides in the document means a
    /// model switch keeps the settings the new model also understands and
    /// quietly drops the ones it does not — which is the behaviour a workspace
    /// owes you and a wizard never had.
    ///
    /// Always filtered against the chosen model's declared specs before
    /// submit: the engine drops unknown param keys **silently**, reporting them
    /// only as a `job.log` line, so an override left over from another model
    /// would vanish without ever failing.
    var overrides: [String: JSONValue] = [:]

    // MARK: - Provenance of the current configuration

    /// Which Actions card seeded this configuration, if any. Shown in the top
    /// bar so a deep-linked workspace still says what it is.
    var presetId: String?
    var presetName: String?

    // MARK: - Runtime

    var submitting = false
    /// A one-off line above the workspace: what a preset just changed, why a
    /// chain stopped. Cleared by the user or by the next seed.
    var notice: String?
    var chain: ChainRun?

    // MARK: - Takes

    /// A result this workspace produced, kept beside the controls that made it
    /// so a run can be judged against the source without leaving the screen.
    ///
    /// The audio itself lives in the Library like anything else — this is a
    /// session-level view of "what I have tried here", not a second store.
    struct Take: Identifiable, Equatable, Sendable {
        /// The song or part id, which is also this row's identity.
        let id: String
        let isPart: Bool
        var title: String
        var fileURL: URL
        var durationS: Double?
        var modelName: String
        var modeTitle: String
        /// What the dial was set to, so two takes can be told apart by the one
        /// number most likely to explain the difference.
        var styleAmount: Double?
        var createdAt: Date
        /// 0 = unrated, 1…5 as everywhere else in the app.
        var rating: Int = 0
        /// Discarded takes stay listed, struck through, until the workspace is
        /// cleared: "I already tried that" is information worth keeping, and
        /// the audio is still in the Library either way.
        var isDiscarded = false
    }

    var takes: [Take] = []

    /// What a run was *asked* for, kept until it lands.
    ///
    /// Stamped at submit rather than read back at ingest: a generation takes
    /// minutes, and a workspace is somewhere you keep working while it runs. A
    /// take labelled with whatever the mode chips happened to say when the
    /// audio arrived would be labelled with the *next* experiment, not the one
    /// that produced it.
    struct RunStamp: Equatable, Sendable {
        var modeTitle: String
        var styleAmount: Double?
    }

    /// One-shot runs this workspace has in flight. Job ids only — the audio
    /// belongs to the Library, and this is a receipt, not a copy.
    var pendingRuns: [String: RunStamp] = [:]

    /// Which take the A/B toggle is comparing against the source.
    var comparingTakeId: String?

    // MARK: - Derived

    /// Whether the workspace holds anything at all — what the Clear button
    /// keys off.
    ///
    /// Deliberately ignores `takes`: those are already in the Library, so
    /// replacing the configuration does not destroy them.
    var isConfigured: Bool {
        source != nil || hasUnsavedWork
    }

    /// Whether the workspace holds anything a preset would be *destroying*.
    ///
    /// A source on its own does not count. Arriving from an Actions card with a
    /// track already chosen and being asked "are you sure?" would be an
    /// obstacle rather than a safeguard — the preset is about to set the mode
    /// and the knobs, not to take the track away. Everything else here is work
    /// the user typed or moved, and is worth one question.
    var hasUnsavedWork: Bool {
        reference != nil || !prompt.isEmpty || !lyrics.isEmpty
            || !sourceCaption.isEmpty || !overrides.isEmpty
            || !keptStems.isEmpty || styleAmount != nil || !outputName.isEmpty
            || lengthS != nil
    }

    var isChainRunning: Bool {
        guard let chain else { return false }
        return !chain.progress.isFailed && !chain.isFinished
    }

    /// The chain believes it is waiting on a job the engine no longer knows
    /// about — a result that never ingested, a relaunch, a job dismissed from
    /// the queue. Without this the workspace would wait forever, with every
    /// escape hatch disabled behind `isChainRunning`.
    func isChainStranded(jobs: JobsStore) -> Bool {
        guard let chain, isChainRunning, let jobId = chain.progress.jobId
        else { return false }
        return jobs.job(jobId) == nil
    }

    /// Whether anything this workspace started is still outstanding. The
    /// dependency container checks this before doing any work on an ingest, so
    /// an idle workspace costs nothing on every job the app runs.
    var isWaitingOnWork: Bool { isChainRunning || !pendingRuns.isEmpty }

    /// Job ids this workspace started and is still waiting on, so the shell can
    /// put the spinner on Style Transfer rather than on whichever destination
    /// the job's task string happens to resemble.
    var outstandingJobIds: Set<String> {
        var ids = Set(pendingRuns.keys)
        if let jobId = chain?.progress.jobId { ids.insert(jobId) }
        return ids
    }

    /// The name a run will be given if the user types nothing.
    var defaultName: String {
        guard let source else { return "Style Transfer" }
        return "\(mode.title): \(source.sourceTitle)"
    }

    var effectiveName: String {
        outputName.isEmpty ? defaultName : outputName
    }

    // MARK: - Model selection

    /// The model that will run, given the mode and what is installed.
    ///
    /// Falls back to the first eligible model rather than to nothing, so
    /// switching to a mode the current model cannot serve moves the selection
    /// instead of emptying the screen.
    func model(in models: [ModelInfo]) -> ModelInfo? {
        let eligible = mode.eligible(models)
        return eligible.first { $0.id == selectedModelId } ?? eligible.first
    }

    /// The instrument choices the chosen model offers, for the track picker.
    func trackChoices(in models: [ModelInfo]) -> [EnumChoice] {
        model(in: models)?.capabilities.params
            .first { $0.key == "track" }?.choices ?? []
    }

    /// The advanced knobs left once the workspace has taken the keys it owns.
    func knobSpecs(in models: [ModelInfo]) -> [ParamSpec] {
        guard let model = model(in: models) else { return [] }
        return StyleTransferMode.knobSpecs(for: model)
    }

    /// The overrides that the chosen model actually understands.
    ///
    /// Anything else is dropped here rather than on the wire, where the engine
    /// would discard it without a word.
    func applicableOverrides(in models: [ModelInfo]) -> [String: JSONValue] {
        let declared = Set(knobSpecs(in: models).map(\.key))
        return overrides.filter { declared.contains($0.key) }
    }

    /// Keeps the selection honest after the catalog changes underneath it —
    /// a model finishing its download, or being uninstalled.
    func reconcileSelection(in models: [ModelInfo]) {
        let eligible = mode.eligible(models)
        if let selectedModelId, eligible.contains(where: { $0.id == selectedModelId }) {
            return
        }
        selectedModelId = eligible.first?.id
    }

    /// The slider's position, which is the model's own default until the user
    /// moves it.
    func effectiveStyleAmount(in models: [ModelInfo]) -> Double {
        guard let dial = mode.dial else { return 0 }
        if let styleAmount { return styleAmount }
        return dial.defaultStyleAmount(spec: mode.dialSpec(for: model(in: models)))
    }

    // MARK: - Length

    /// The tail a continuation adds when the user has not said otherwise.
    ///
    /// This was the hardcoded `+ 30` inside `requestedDurationS`, and it is
    /// still where the control starts. What changed is that it is a starting
    /// point rather than the only length a continuation could ever have.
    static let defaultTailS: Double = 30

    /// The shortest tail worth asking for.
    ///
    /// Stable Audio 3 refuses a continuation outright once the source sits
    /// within `MIN_EXTEND_TAIL_S` — 5 s — of its window: "source is 118s —
    /// continuation needs it under 115s". Matching the number here turns that
    /// `RuntimeError`, which used to arrive after the upload and the model
    /// load, into a sentence on the commit bar before anything is queued.
    static let minTailS: Double = 5

    /// What `duration_s` will mean for the run as currently configured.
    func lengthPolicy(in models: [ModelInfo]) -> StyleTransferMode.LengthPolicy {
        mode.lengthPolicy(for: model(in: models), hasSource: source != nil)
    }

    /// The range the length control may travel, in the unit its policy implies,
    /// or `nil` when there is no control to offer.
    ///
    /// `nil` for a pinned length, where the source decides and a slider would
    /// be decoration; and for a continuation the model has no room for, which
    /// is a reason rather than a clamp — a tail control from 5 s down to 2 s is
    /// not a control.
    func lengthBounds(for model: ModelInfo,
                      policy: StyleTransferMode.LengthPolicy)
        -> ClosedRange<Double>? {
        let duration = model.capabilities.duration
        switch policy {
        case .pinnedToSource:
            return nil
        case .total:
            guard duration.maxS > duration.minS else { return nil }
            return duration.minS...duration.maxS
        case .extendsSource:
            // A tail, so the ceiling is what is left of the model's window once
            // the source inside the output has taken its share.
            let headroom = duration.maxS - (source?.durationS ?? 0)
            guard headroom >= Self.minTailS else { return nil }
            return Self.minTailS...headroom
        }
    }

    /// Where the control sits: the user's number held inside the bounds, or the
    /// value the workspace would have sent without one.
    func effectiveLengthS(for model: ModelInfo,
                          policy: StyleTransferMode.LengthPolicy) -> Double {
        // Never by way of `requestedDurationS`, which reads this back: the
        // fallback has to stand on its own or the two recurse.
        let fallback = policy == .extendsSource
            ? Self.defaultTailS : model.capabilities.duration.defaultS
        guard let bounds = lengthBounds(for: model, policy: policy) else {
            return fallback
        }
        return min(max(lengthS ?? fallback, bounds.lowerBound),
                   bounds.upperBound)
    }

    /// The total length of the audio this run will produce — what `duration_s`
    /// carries, and what the render estimate is drawn from.
    ///
    /// Lives beside the document rather than beside the submission because the
    /// screen reads it for every model in the picker, long before anything is
    /// sent.
    func requestedDurationS(model: ModelInfo) -> Double {
        let duration = model.capabilities.duration
        let policy = mode.lengthPolicy(for: model, hasSource: source != nil)
        switch policy {
        case .pinnedToSource:
            // The adapter resolves this from the source and never reads what we
            // send. Sending the source's own length anyway is what makes the
            // estimate on the commit bar an estimate of the render that will
            // actually happen: the model's nominal default used to stand in,
            // which quoted a four-minute restyle as sixty seconds of work.
            return min(duration.maxS, source?.durationS ?? duration.defaultS)
        case .total:
            return effectiveLengthS(for: model, policy: policy)
        case .extendsSource:
            // The user chose a tail; the wire wants the total.
            return min(duration.maxS, (source?.durationS ?? 0)
                       + effectiveLengthS(for: model, policy: policy))
        }
    }

    // MARK: - Readiness

    /// Why the workspace cannot run yet, in the user's terms, or nil when it
    /// can. One reason at a time, in the order a person would fix them.
    func blockedReason(in models: [ModelInfo]) -> String? {
        if submitting { return "Submitting…" }
        if isChainRunning { return "Already running." }
        if mode.sourceNeed == .required, source == nil {
            return "Choose the track to transform."
        }
        if mode.referenceNeed == .required, reference == nil {
            return "Choose a reference track."
        }
        if model(in: models) == nil {
            return mode.unavailableReason(models) ?? "No model can run this yet."
        }
        // Said here rather than discovered by the adapter: a continuation whose
        // source already fills the model's window has nowhere to put the new
        // audio, and upstream's own refusal arrives only after the upload and
        // the model load.
        if let chosen = model(in: models),
           mode.lengthPolicy(for: chosen, hasSource: source != nil)
               == .extendsSource,
           lengthBounds(for: chosen, policy: .extendsSource) == nil {
            return "\(chosen.displayName) renders at most "
                + "\(Int(chosen.capabilities.duration.maxS)) s — not enough "
                + "room to continue a \(Int(source?.durationS ?? 0)) s track. "
                + "Pick a model with a longer window, or a shorter source."
        }
        if mode.needsPrompt, prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty {
            return "Say what it should become."
        }
        if mode.trackNeed == .required, track == nil {
            return "Choose an instrument."
        }
        if mode.isChain, let chainPlan = plannedChain(in: models),
           let reason = chainPlan.blockedReason {
            return reason
        }
        return nil
    }

    func canRun(in models: [ModelInfo]) -> Bool { blockedReason(in: models) == nil }

    // MARK: - The chain

    /// A chain in flight: the plan it is following and how far it has got.
    struct ChainRun: Equatable, Sendable {
        /// Distinguishes this run from a later one started after it was
        /// cleared, so a step that was already in flight cannot write its
        /// result back into a chain the user has since abandoned.
        let id: String
        var plan: StyleTransferChain
        var progress: StyleTransferChain.Progress
        /// What the user asked for when they pressed the button.
        ///
        /// The chain runs for minutes across three or four jobs, and reading
        /// the prompt back at each step would let an edit made while step one
        /// was running silently change step two. A chain is one instruction,
        /// given once.
        var prompt: String = ""
        var name: String = ""
        var styleAmount: Double?
        /// The upload-free handles the steps pass to one another: the part ids
        /// being replaced, the song the fold produced, the song the restyle
        /// produced.
        var foldedSongId: String?
        var restyledSongId: String?
        /// The parts being kept and replaced, resolved at plan time so a
        /// Library change mid-run cannot re-target the mix.
        var keptPartIds: [String] = []
        var replacedPartIds: [String] = []

        var isFinished: Bool {
            progress.stepIndex >= plan.steps.count
        }

        var currentStep: StyleTransferChain.Step? {
            guard progress.stepIndex < plan.steps.count else { return nil }
            return plan.steps[progress.stepIndex]
        }
    }

    /// The stems the source song already has, as the planner wants them.
    ///
    /// **One part per kind, newest first.** Nothing stops a song holding two
    /// `stem.vocals` parts — extracting a vocal generatively and then splitting
    /// the song does exactly that, and so does re-splitting with a second
    /// separator to compare them. The chain selects by kind, so a duplicate
    /// would be submitted twice: the final mix would carry the original vocal
    /// *and* the AI one, phasing against each other, and the user would have
    /// ticked one chip.
    func availableStems(parts: PartsStore) -> [StyleTransferChain.Stem] {
        guard let songId = source?.songId,
              let records = try? parts.repository.allParts(forSong: songId)
        else { return [] }
        var seen = Set<String>()
        return records
            .filter { $0.format == "wav" }
            .sorted { $0.createdAt > $1.createdAt }
            .filter { seen.insert($0.kind).inserted }
            // The chip's label is the kind: these are the stems of one song,
            // named for it, so their full names differ only in the last word.
            .map { .init(id: $0.id, kind: $0.kind,
                         name: PartNaming.label(kind: $0.kind),
                         durationS: $0.durationS) }
    }

    /// The chain as it would be planned right now. Recomputed rather than
    /// cached: the stem list changes when a split finishes, and a stale plan is
    /// how a chain ends up mixing parts that no longer exist.
    var plannerInput: [StyleTransferChain.Stem] = []
    var plannerAnalysed = true

    /// Feed the planner what only a store can tell it. Called by the screen on
    /// appear and whenever the parts store republishes.
    func refreshPlannerInput(parts: PartsStore) {
        plannerInput = availableStems(parts: parts)
        if let songId = source?.songId {
            plannerAnalysed =
                ((try? parts.repository.analysis(ownerId: songId)) ?? nil) != nil
        } else {
            plannerAnalysed = true
        }
    }

    func plannedChain(in models: [ModelInfo]) -> StyleTransferChain? {
        guard mode.isChain else { return nil }
        return StyleTransferChain.make(
            stems: plannerInput, keep: keptStems, models: models,
            restyleModelId: selectedModelId,
            sourceIsAnalyzed: plannerAnalysed)
    }

    // MARK: - Seeding from a preset or a deep link

    /// Apply an Actions preset, optionally with a source to work on.
    ///
    /// Refuses to overwrite a configuration in progress. Silently clobbering it
    /// is the exact failure a workspace exists to prevent, and a card that
    /// throws away ten minutes of setup is worse than a card that does nothing.
    /// Returns whether it applied.
    @discardableResult
    func seed(preset: StylePreset, presetName: String?,
              source newSource: PickedMaterial?,
              models: [ModelInfo], force: Bool = false) -> Bool {
        if hasUnsavedWork && !force {
            notice = "\(presetName ?? "That preset") is ready to apply — but "
                + "this workspace already has a setup in it. Clear it first, or "
                + "apply the preset over the top."
            pendingPreset = PendingPreset(preset: preset, name: presetName,
                                          source: newSource)
            return false
        }
        pendingPreset = nil
        guard apply(preset: preset, presetName: presetName,
                    source: newSource, models: models) else {
            // `apply` refuses while a chain is running, and the preset used to
            // be gone at that point — `pendingPreset` is what the "Apply
            // preset" button is bound to, so clearing it took away the only
            // way to act on the notice's own advice ("wait for it, or dismiss
            // it"). Held instead, and the caller is told nothing was applied.
            pendingPreset = PendingPreset(preset: preset, name: presetName,
                                          source: newSource)
            return false
        }
        return true
    }

    /// A preset the user was offered but has not accepted yet.
    struct PendingPreset: Equatable, Sendable {
        var preset: StylePreset
        var name: String?
        var source: PickedMaterial?
    }

    var pendingPreset: PendingPreset?

    /// Accept the preset that `seed` held back. Kept on offer if it cannot be
    /// applied yet — same reason as in `seed`.
    func applyPendingPreset(models: [ModelInfo]) {
        guard let pending = pendingPreset else { return }
        guard apply(preset: pending.preset, presetName: pending.name,
                    source: pending.source, models: models) else { return }
        pendingPreset = nil
    }

    func dismissPendingPreset() {
        pendingPreset = nil
        notice = nil
    }

    /// Whether it applied. False means a chain is in flight and the caller
    /// still owns the preset.
    private func apply(preset: StylePreset, presetName: String?,
                       source newSource: PickedMaterial?,
                       models: [ModelInfo]) -> Bool {
        guard !isChainRunning else {
            notice = "A chain is still running. Wait for it, or dismiss it, "
                + "before starting something else."
            return false
        }
        presetId = preset.id
        self.presetName = presetName
        // Land on something that works: a deep link into a mode no installed
        // model serves still shows a usable screen, with the dimmed chip
        // carrying the reason and the offer to install.
        mode = preset.mode
        if let newSource {
            self.source = newSource
            regionStartS = 0
            regionEndS = min(8, newSource.durationS ?? 8)
        }
        if !preset.promptSeed.isEmpty { prompt = preset.promptSeed }
        if let amount = preset.styleAmount { styleAmount = amount }
        lyrics = ""
        overrides = [:]
        lengthS = nil
        keptStems = []
        // The stem list belongs to the source, so a preset that brought a new
        // one has invalidated it. Left stale, the chain would plan against
        // another song's parts.
        plannerInput = []
        plannerAnalysed = true
        track = nil
        outputName = ""
        notice = preset.notice
        reconcileSelection(in: models)
        return true
    }

    /// Put a source in without disturbing anything else — the Library's
    /// "Restyle this…" and the picker sheet both land here.
    ///
    /// Refused outright while a chain runs: swapping the track underneath a
    /// three-job sequence would leave its remaining steps mixing parts of a
    /// song nobody is looking at any more.
    func setSource(_ material: PickedMaterial?) {
        guard !isChainRunning else {
            notice = "A chain is running on \(source?.sourceTitle ?? "this track"). "
                + "Wait for it, or dismiss it, before changing the source."
            return
        }
        source = material
        regionStartS = 0
        regionEndS = min(8, material?.durationS ?? 8)
        keptStems = []
        chain = nil
    }

    /// Back to an empty workspace, keeping the takes list — the audio is in the
    /// Library either way, and "what I already tried" survives a reset.
    ///
    /// The chain is dropped along with everything else, and its in-flight jobs
    /// are deliberately *not* cancelled: whatever they produce still lands in
    /// the Library, which is worth more than a tidy state. `ChainRun.id` is
    /// what stops a step that was already in the air writing itself back into a
    /// workspace that has moved on.
    func clearConfiguration() {
        source = nil
        reference = nil
        prompt = ""
        lyrics = ""
        sourceCaption = ""
        outputName = ""
        track = nil
        styleAmount = nil
        lengthS = nil
        keptStems = []
        overrides = [:]
        chain = nil
        presetId = nil
        presetName = nil
        notice = nil
        pendingPreset = nil
    }

    // MARK: - Takes

    func record(take: Take) {
        takes.removeAll { $0.id == take.id }
        takes.insert(take, at: 0)
    }

    func rate(takeId: String, rating: Int) {
        guard let index = takes.firstIndex(where: { $0.id == takeId }) else { return }
        // Tapping the current rating clears it, as everywhere else.
        takes[index].rating = takes[index].rating == rating ? 0 : rating
    }

    func toggleDiscarded(takeId: String) {
        guard let index = takes.firstIndex(where: { $0.id == takeId }) else { return }
        takes[index].isDiscarded.toggle()
        if takes[index].isDiscarded, comparingTakeId == takeId {
            comparingTakeId = nil
        }
    }
}

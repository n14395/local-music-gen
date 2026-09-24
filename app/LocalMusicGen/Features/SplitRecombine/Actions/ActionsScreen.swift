// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// The Actions destination: a gallery of everything the app can do to audio,
/// and — one level down, on a page rather than in a sheet — the configuration
/// for whichever one you picked.
///
/// `route` is live navigation state, not a mailbox: `nil` is the gallery and a
/// non-nil value is the page currently open. The shell holds it so a jump from
/// elsewhere ("Split this song", "Find matches") lands directly on a configured
/// page, and so leaving Actions and coming back does not lose your place.
struct ActionsScreen: View {
    let settings: AppSettings
    /// Amp captures kept on this Mac — the re-amp card's picker reads it.
    let tones: ToneLibraryStore
    let catalog: ModelCatalogStore
    let library: LibraryStore
    let parts: PartsStore
    let jobs: JobsStore
    let playback: PlaybackController
    let workbench: WorkbenchModel
    let assistant: AssistantStore
    let plans: PlanStore
    let textStore: TextStore
    let textChain: TextChainModel
    @Binding var route: Route?
    /// The Library's ticked rows, so a batch page opened from Track ▸ Ticked
    /// Rows starts with them chosen. Empty from every other route, which is
    /// what the pages' own "nothing picked yet" state is for.
    var batchPreselection: Set<String> = []
    let onOpenModels: (ModelRequirement?) -> Void
    /// Switches the shell to the Workbench destination, carrying the one-off
    /// notes `WorkbenchScreen` shows above the bench ("12 sections placed back
    /// to back…"). Pass `[]` when there is nothing to say.
    let onOpenWorkbench: ([String]) -> Void
    /// Switches the shell to the Style Transfer destination with a preset
    /// applied. The same escape hatch `.workbench` already uses: some cards are
    /// doors into a place rather than pages of their own.
    let onOpenStyleTransfer: (StylePreset?, String?) -> Void
    /// Switches the shell to Generate with a preset applied — the same escape
    /// hatch as `onOpenStyleTransfer`, for the shelf of cards that start from
    /// a description rather than from audio. The id is the track a preset
    /// reads tempo and key from, nil for the cards that read nothing.
    let onOpenGenerate: (GeneratePreset, String?) -> Void
    /// Switches the shell to the Editor on this song or part — the same
    /// escape hatch as the two above.
    let onOpenEditor: (String) -> Void
    /// Open Generate on text the assistant drafted and the user accepted.
    /// Distinct from `onOpenGenerate`, which carries a card's preset: there is
    /// no preset here, only words that already exist.
    let onUseText: (PrefillBox.Prefill) -> Void

    /// `sourceId` is a song or part id to preselect; the page resolves it.
    enum Route: Equatable {
        case action(recipeId: String, sourceId: String?)
    }

    /// The preset waiting on a track to measure — `gen-fit-track` and nothing
    /// else. Held rather than routed because the card needs one fact off a
    /// song and then leaves; a page of its own would exist to hold a single
    /// picker.
    @State private var pickingFor: GeneratePreset?
    /// The Editor door, waiting on the file it opens.
    @State private var pickingForEditor = false
    @State private var query = ""
    @State private var category: RecipeCategory?
    @AppStorage("actions.onlyRunnable") private var onlyRunnable = false
    @AppStorage("actions.lastRuns") private var runsJSON = "{}"
    /// The "Recently used" menu, resolved when the log changes rather than
    /// when the gallery redraws.
    ///
    /// The log lives in `@AppStorage` as a JSON blob, and this was decoding
    /// the whole thing from inside `body` — once per keystroke in the gallery
    /// search field, to fill a menu that only changes when a run is recorded.
    @State private var recentRecipes: [Recipe] = []
    /// The Models screen's own disclosure. Written here only when routing to a
    /// model that would otherwise be hidden — see `featuredCanSatisfy`.

    var body: some View {
        if case .action(let recipeId, let sourceId) = route,
           let recipe = RecipeCatalog.recipe(id: recipeId) {
            // Several recipes share one page type (every preset split is a
            // SplitActionView), so without an identity keyed to the route the
            // second one would inherit the first one's chosen source and model.
            page(for: recipe, sourceId: sourceId)
                .id("\(recipeId)|\(sourceId ?? "")")
        } else {
            gallery
        }
    }

    // MARK: - Gallery

    private var gallery: some View {
        ActionGallery(recipes: RecipeCatalog.all,
                      states: cardStates,
                      readiness: catalog.readiness,
                      recent: recentRecipes,
                      query: $query,
                      category: $category,
                      onlyRunnable: $onlyRunnable,
                      onOpen: open,
                      onDropAudio: importDropped,
                      onOpenModels: { onOpenModels(nil) })
            // The gates depend on the catalog and on how much the engine has
            // told us, and on nothing else — so they are recomputed exactly
            // when one of those moves. `version` rather than `models` because
            // comparing the array would cost more than the work it saves.
            .task { refreshCardStates() }
            .onChange(of: catalog.version) { refreshCardStates() }
            .onChange(of: catalog.readiness) { refreshCardStates() }
            .task { refreshRecentRecipes() }
            .onChange(of: runsJSON) { refreshRecentRecipes() }
            .sheet(isPresented: $pickingForEditor) {
                PartPickerSheet(
                    slotLabel: "Song or part",
                    accepts: [KindPattern(pattern: "song.mix"),
                              KindPattern(pattern: "stem.*"),
                              KindPattern(pattern: "layer.*")],
                    autoDerive: nil, catalog: catalog, library: library,
                    parts: parts, jobs: jobs, playback: playback,
                    onOpenModels: { onOpenModels(nil) },
                    onPick: { picked in
                        pickingForEditor = false
                        onOpenEditor(picked.id)
                    })
            }
            .sheet(item: $pickingFor) { preset in
                PartPickerSheet(
                    slotLabel: "Track to match",
                    accepts: RecipeCatalog.recipe(id: preset.id)?
                        .slots.first?.accepts ?? [],
                    autoDerive: nil, catalog: catalog, library: library,
                    parts: parts, jobs: jobs, playback: playback,
                    onOpenModels: { onOpenModels(nil) },
                    onPick: { picked in
                        pickingFor = nil
                        onOpenGenerate(preset, picked.id)
                    })
            }
    }

    private func refreshRecentRecipes() {
        recentRecipes = ActionRunLog.decoded(runsJSON).recentRecipeIds
            .compactMap { RecipeCatalog.recipe(id: $0) }
    }

    // MARK: - Availability

    /// Why a card cannot run right now. Gated states still open — they route to
    /// Models, which is the only place the problem can be fixed.
    enum CardState {
        case active
        case comingSoon
        case needsMixModel
        case needsStyleModel(mode: StyleTransferMode, hint: String)
        case needsRenderModel
        case needsSpliceModel
        /// A split-family card — separate, transcribe or analyze — with no
        /// model installed for its task. These used to have no gate at all, so
        /// four cards read as runnable on a fresh install and only admitted
        /// the problem once you were on the page.
        case needsTaskModel(String)
        /// A Generate card with nothing installed that can do what it says.
        /// The hint names the smallest model that would, because "install
        /// something" is not an instruction anyone can follow.
        case needsGenerateModel(need: GenerateNeed, hint: String)
        /// A "Help me write" card with no writing assistant installed.
        case needsAssistant(hint: String)
        /// A plan card with nothing installed that can plan before it renders.
        /// Only some generative models have a planning stage at all, so this
        /// is a narrower requirement than "a model that generates".
        case needsPlanModel(hint: String)
        /// The engine has not said what is installed, so this card cannot
        /// honestly claim anything. Every other gated state is a statement
        /// about the user's disk; this one is a statement about the app.
        case unknown(CatalogReadiness)

        var footnote: String? {
            switch self {
            case .active: nil
            case .comingSoon: "Coming soon"
            case .needsMixModel: "Get Mixdown & Align — free"
            case .needsStyleModel(_, let hint): hint
            case .needsRenderModel: "Get the SoundFont renderer — free"
            case .needsSpliceModel: "Get Token Splice — 76 MB"
            case .needsGenerateModel(_, let hint): hint
            case .needsAssistant(let hint): hint
            case .needsPlanModel(let hint): hint
            case .unknown(let readiness): readiness.shortLine
            case .needsTaskModel(let task):
                switch task {
                case "separate": "Get a separation model — 84 MB"
                case "transcribe": "Get a transcription model — free"
                case "analyze": "Get Musical analysis — 81 MB"
                case "caption": "Get a describer model"
                case "lyrics": "Get a lyric transcriber"
                case "tag": "Get a tagging model"
                case "compose": "Get a notation composer"
                default: "Get a model for this"
                }
            }
        }

        /// Whether the footnote is telling the user off or just telling them
        /// to wait. A "still starting" line drawn in the same amber as
        /// "install this first" reads as a fault, and there isn't one.
        var footnoteIsWarning: Bool {
            if case .unknown(.pending) = self { return false }
            return true
        }

        /// Nothing worth clicking. "Coming soon" has nowhere to go, and a card
        /// that does not yet know what it needs cannot send you to get it —
        /// unlike every gated state, which routes to Models on purpose.
        var isInert: Bool {
            switch self {
            case .comingSoon: return true
            case .unknown(let readiness):
                if case .pending = readiness { return true }
                return false
            default: return false
            }
        }
    }

    private var mixInstalled: Bool {
        MixModels.mixdown(in: catalog.models) != nil
    }

    private var spliceInstalled: Bool {
        MixModels.splicer(in: catalog.models) != nil
    }

    private var renderModel: ModelInfo? {
        catalog.models.first {
            $0.installState == .installed
                && $0.capabilities.supportedTasks.contains("render")
        }
    }

    /// Every card's gate, computed when the catalog changes rather than when
    /// the gallery redraws.
    ///
    /// This was a computed property read from `body`, and each of its sixty
    /// entries runs several predicates over a catalog of a hundred and
    /// twenty-nine models — the gated arms additionally build a "Get X" hint
    /// by filtering the catalog again. Tens of thousands of iterations, with
    /// allocations, to answer a question whose inputs are the catalog and the
    /// engine's readiness and nothing else. So it is keyed on exactly those.
    @State private var cardStates: [String: CardState] = [:]

    private func refreshCardStates() {
        cardStates = Dictionary(uniqueKeysWithValues:
            RecipeCatalog.all.map { ($0.id, cardState($0)) })
    }

    /// Whether a style mode can actually run, not merely be configured.
    ///
    /// The stem chain is three jobs, and the middle one is the only part a
    /// model-eligibility check would notice: without a separator and a mixdown
    /// the card reads as runnable and then admits, on the page, that it cannot
    /// separate anything. Gating four cards on the model they *say* they need
    /// and one on the models it actually needs is the same lesson
    /// `.needsTaskModel` was added for.
    private func styleReady(_ mode: StyleTransferMode) -> Bool {
        guard !mode.eligible(catalog.models).isEmpty else { return false }
        guard mode.isChain else { return true }
        return installed(task: "separate")
            && MixModels.mixdown(in: catalog.models) != nil
    }

    /// Installed models that can generate audio from a description — the
    /// pool "Compare models" draws from.
    private var generativeInstalled: [ModelInfo] {
        GenerateNeed().eligible(catalog.models)
    }

    /// One `Set` lookup. This used to walk the whole catalog doing a string
    /// search inside a nested array, and `cardStates` below asks it once per
    /// card across sixty of them.
    private func installed(task: String) -> Bool {
        catalog.hasInstalled(task: task)
    }

    private func cardState(_ recipe: Recipe) -> CardState {
        guard recipe.isAvailable else { return .comingSoon }
        // Everything below this line asks "is model X installed", and until
        // the engine has answered once there is no honest answer to give: an
        // empty catalog during startup is indistinguishable from an empty
        // disk. Claiming the latter is how a fresh launch spent its first
        // second telling a user with forty models installed that all
        // twenty-six actions needed a download.
        //
        // Recipes that need no model at all — the bench, matching — are
        // deliberately left alone: they run with no engine whatsoever, and
        // greying them out while one starts would be its own wrong claim.
        let readiness = catalog.readiness
        if !readiness.knowsWhatIsInstalled, requirement(for: recipe) != nil {
            return .unknown(readiness)
        }
        switch recipe.engine {
        case .mix where !mixInstalled, .arrange where !mixInstalled:
            return .needsMixModel
        case .styleTransfer(let preset) where !styleReady(preset.mode):
            return .needsStyleModel(
                mode: preset.mode,
                hint: preset.mode.candidates(catalog.models).first.map {
                    "Get \($0.displayName)"
                } ?? "No model can do this yet")
        case .render where renderModel == nil:
            return .needsRenderModel
        case .tokenSplice where !spliceInstalled:
            return .needsSpliceModel
        case .split(let task, _) where !installed(task: task):
            return .needsTaskModel(task)
        case .generate(let preset) where preset.need.best(catalog.models) == nil:
            return .needsGenerateModel(
                need: preset.need,
                hint: ModelRequirement.generate(preset.need)
                    .candidates(catalog.models).first
                    .map { "Get \($0.displayName)" }
                    ?? "No model can do this yet")
        case .transform where !mixInstalled:
            return .needsMixModel
        case .batchSplit where !installed(task: "separate"):
            return .needsTaskModel("separate")
        case .batchTag where !installed(task: "tag"):
            return .needsTaskModel("tag")
        case .compareModels where generativeInstalled.count < 2:
            // Two is the least that can be compared. One installed model
            // makes this card a slower way to press Generate.
            return .needsGenerateModel(
                need: GenerateNeed(),
                hint: generativeInstalled.isEmpty
                    ? "Get a model that generates audio"
                    : "Needs a second model to compare against")
        case .assistant where AssistantModels.installed(catalog.models).isEmpty:
            return .needsAssistant(
                hint: AssistantModels.candidates(catalog.models).first
                    .map { "Get \($0.displayName) — "
                         + $0.sizeBytes.formatted(.byteCount(style: .file)) }
                    ?? "No writing assistant is available")
        case .songPlan where PlanModels.installed(catalog.models).isEmpty:
            // Narrower than "a model that generates": only some generative
            // models have a planning stage to show at all.
            return .needsPlanModel(
                hint: PlanModels.candidates(catalog.models).first
                    .map { "Get \($0.displayName)" }
                    ?? "No model here plans before it renders")
        case .textAction(let action)
            where !catalog.models.contains(where: {
                $0.installState == .installed && action.canRun($0)
            }):
            // Not merely "declares the task": Ask needs a model that also
            // declares a `question` param — see `TextAction.canRun`.
            return .needsTaskModel(action.task)
        case .textCompare where installedCount(task: "caption") < 2:
            // Two is the least that can be compared, as with .compareModels.
            return .needsTaskModel("caption")
        case .textPipeline(let kind):
            if let missing = firstMissingTask(of: kind) {
                return .needsTaskModel(missing)
            }
            if kind.needsGenerator && generativeInstalled.isEmpty {
                return .needsGenerateModel(
                    need: GenerateNeed(),
                    hint: "Get a model that generates audio")
            }
            return .active
        case .promptScore where !installed(task: "analyze"):
            return .needsTaskModel("analyze")
        // `.mapSections` and `.similar` stay active on purpose: both read
        // analysis the library already holds and degrade in-page — the
        // `.match` precedent.
        default:
            return .active
        }
    }

    /// The first wire task a pipeline needs that nothing installed can run.
    private func firstMissingTask(of kind: TextChain.Kind) -> String? {
        kind.requiredTasks.first { !installed(task: $0) }
    }

    private func installedCount(task: String) -> Int {
        catalog.models.filter {
            $0.installState == .installed
                && $0.capabilities.supportedTasks.contains(task)
        }.count
    }

    /// What a recipe needs installed, read off the recipe rather than off its
    /// current state: the same answer whether the model is missing now (route
    /// to the filtered list) or the user simply wants a different one later.
    private func requirement(for recipe: Recipe) -> ModelRequirement? {
        switch recipe.engine {
        case .mix, .arrange: .mixdown
        case .tokenSplice: .splicer
        case .render: .task("render")
        case .split(let task, _): .task(task)
        case .styleTransfer(let preset): .style(preset.mode)
        case .transform: .mixdown
        case .batchSplit: .task("separate")
        case .batchTag: .task("tag")
        // A door into a screen that needs no model to open.
        case .editor: nil
        case .generate(let preset): .generate(preset.need)
        case .compareModels: .generate(GenerateNeed())
        // Both are ordinary task requirements: the model either declares the
        // verb or it does not, which is exactly what `.task` tests.
        case .assistant: .task("assist")
        case .songPlan: .task("plan")
        case .textAction(let action): .task(action.task)
        case .textCompare: .task("caption")
        // The *missing* task, when one is — a card gated on its second stage
        // (transcribe installed, compose not) should land the user on the
        // list that actually ungates it, not on models they already have.
        case .textPipeline(let kind):
            .task(firstMissingTask(of: kind)
                  ?? kind.requiredTasks.first ?? "caption")
        case .promptScore: .task("analyze")
        // Neither runs a model of its own: both read analysis the library
        // already holds, like `.match`.
        case .mapSections, .similar: nil
        // Neither runs a model: the bench is a surface, and matching is
        // ranking maths over analysis the library already holds.
        case .workbench, .match: nil
        }
    }

    // MARK: - Opening

    private func open(_ recipe: Recipe) {
        switch cardState(recipe) {
        case .comingSoon:
            return
        case .active:
            break
        case .unknown(let readiness):
            // Pending is inert at the card, so only the failure lands here.
            // Models is still the right destination — it is where the engine
            // error is spelled out — but *without* a requirement filter: a
            // list narrowed to "models that would ungate this" is empty and
            // silent when the reason is that nothing can be listed at all.
            guard !readiness.knowsWhatIsInstalled else { return }
            onOpenModels(nil)
            return
        case let state:
            // Deliberate: a gated card is the shortest path to the model that
            // ungates it, so it stays clickable and lands you in Models —
            // carrying what it needs, so the list there narrows to the models
            // that would actually ungate it. Arriving at a 64-row catalog with
            // no sign of which row you were sent for is barely better than not
            // routing at all.
            onOpenModels(requirement(for: recipe))
            return
        }
        if case .workbench = recipe.engine {
            onOpenWorkbench([])
            return
        }
        // Style Transfer is a destination, not a page: the card carries a
        // preset into it rather than opening a one-shot form that forgets
        // everything the moment you leave.
        if case .styleTransfer(let preset) = recipe.engine {
            onOpenStyleTransfer(preset, nil)
            return
        }
        // Generate is a destination too. The one preset that measures a track
        // asks for it here rather than on a page, because a picker is all the
        // page would have contained.
        if case .editor = recipe.engine {
            pickingForEditor = true
            return
        }
        if case .generate(let preset) = recipe.engine {
            if preset.readsSource {
                pickingFor = preset
            } else {
                onOpenGenerate(preset, nil)
            }
            return
        }
        route = .action(recipeId: recipe.id, sourceId: nil)
    }

    /// A file dropped on the gallery is imported and then handed to the action
    /// it suits. A whole song's first move is almost always separation, so that
    /// is where a single file lands; extra files stay in the Library, where the
    /// source picker on any page can reach them.
    private func importDropped(_ urls: [URL]) {
        Task {
            let imported = await library.importSongs(urls: urls)
            guard let first = imported.first else { return }
            route = .action(recipeId: "split-instruments", sourceId: first.id)
        }
    }

    // MARK: - Pages

    @ViewBuilder
    private func page(for recipe: Recipe, sourceId: String?) -> some View {
        let back = { route = nil }
        switch recipe.engine {
        case .split(let task, let note):
            SplitActionView(recipe: recipe, task: task, note: note,
                            sourceId: sourceId, settings: settings,
                            tones: tones, catalog: catalog,
                            library: library, parts: parts, jobs: jobs,
                            playback: playback, onOpenModels: { onOpenModels(requirement(for: recipe)) },
                            onBack: back)
        case .mix:
            MixActionView(recipe: recipe, sourceId: sourceId,
                          catalog: catalog, library: library, parts: parts,
                          jobs: jobs, playback: playback,
                          onOpenModels: { onOpenModels(requirement(for: recipe)) }, onBack: back)
        case .styleTransfer:
            // `open(_:)` never routes here; the shell switches destination.
            // A deep link that arrives as a route anyway is bounced the same
            // way rather than rendering a page that no longer exists.
            gallery
                .onAppear {
                    if case .styleTransfer(let preset) = recipe.engine {
                        route = nil
                        onOpenStyleTransfer(preset, sourceId)
                    }
                }
        case .render:
            RenderActionView(recipe: recipe, sourceId: sourceId,
                             catalog: catalog, library: library, parts: parts,
                             jobs: jobs, playback: playback,
                             onOpenModels: { onOpenModels(requirement(for: recipe)) }, onBack: back)
        case .arrange:
            ArrangeActionView(recipe: recipe, sourceId: sourceId,
                              catalog: catalog, library: library, parts: parts,
                              jobs: jobs, playback: playback,
                              workbench: workbench,
                              onOpenModels: { onOpenModels(requirement(for: recipe)) },
                              onOpenWorkbench: onOpenWorkbench, onBack: back)
        case .match:
            MatchActionView(recipe: recipe, sourceId: sourceId,
                            catalog: catalog, library: library, parts: parts,
                            jobs: jobs, playback: playback,
                            workbench: workbench, onOpenModels: { onOpenModels(requirement(for: recipe)) },
                            onOpenWorkbench: onOpenWorkbench, onBack: back)
        case .tokenSplice:
            SpliceActionView(recipe: recipe, sourceId: sourceId,
                             catalog: catalog, library: library, parts: parts,
                             jobs: jobs, playback: playback,
                             onOpenModels: { onOpenModels(requirement(for: recipe)) }, onBack: back)
        case .transform(let transform):
            TransformActionView(recipe: recipe, transform: transform,
                                sourceId: sourceId, catalog: catalog,
                                library: library, parts: parts, jobs: jobs,
                                playback: playback,
                                onOpenModels: { onOpenModels(requirement(for: recipe)) },
                                onBack: back)
        case .batchSplit:
            BatchSplitActionView(recipe: recipe, catalog: catalog,
                                 library: library, parts: parts, jobs: jobs,
                                 playback: playback,
                                 preselected: batchPreselection,
                                 onOpenModels: { onOpenModels(requirement(for: recipe)) },
                                 onBack: back)
        case .batchTag:
            BatchTagActionView(recipe: recipe, catalog: catalog,
                               library: library, parts: parts, jobs: jobs,
                               playback: playback,
                               preselected: batchPreselection,
                               onOpenModels: { onOpenModels(requirement(for: recipe)) },
                               onBack: back)
        case .editor:
            // `open(_:)` never routes here; the shell switches destination.
            gallery
                .onAppear {
                    route = nil
                    if let sourceId { onOpenEditor(sourceId) }
                }
        case .compareModels:
            CompareActionView(recipe: recipe, catalog: catalog,
                              library: library, jobs: jobs,
                              playback: playback,
                              onOpenModels: { onOpenModels(requirement(for: recipe)) },
                              onBack: back)
        case .generate:
            // `open(_:)` never routes here; the shell switches destination.
            // A deep link that arrives as a route anyway is bounced the same
            // way `.styleTransfer` is.
            gallery
                .onAppear {
                    if case .generate(let preset) = recipe.engine {
                        route = nil
                        onOpenGenerate(preset, sourceId)
                    }
                }
        case .assistant(let kind, let needsSource):
            AssistantActionView(recipe: recipe, kind: kind,
                                needsSource: needsSource, sourceId: sourceId,
                                catalog: catalog, library: library,
                                parts: parts, jobs: jobs,
                                assistant: assistant, playback: playback,
                                onOpenModels: { onOpenModels(requirement(for: recipe)) },
                                onUseText: onUseText,
                                onOpenAction: { route = .action(recipeId: $0,
                                                                sourceId: $1) },
                                onBack: back)
        case .songPlan(let mode):
            PlanActionView(recipe: recipe, mode: mode, sourceId: sourceId,
                           catalog: catalog, library: library, parts: parts,
                           jobs: jobs, plans: plans, playback: playback,
                           onOpenModels: { onOpenModels(requirement(for: recipe)) },
                           onOpenGenerate: onOpenGenerate, onBack: back)
        case .workbench:
            // `open(_:)` never routes here; the shell switches destination.
            gallery
        case .textAction(let action):
            TextActionView(recipe: recipe, action: action, sourceId: sourceId,
                           settings: settings, catalog: catalog,
                           library: library, parts: parts, jobs: jobs,
                           textStore: textStore, playback: playback,
                           onOpenModels: { onOpenModels(requirement(for: recipe)) },
                           onUseText: onUseText, onBack: back)
        case .textCompare:
            TextCompareActionView(recipe: recipe, sourceId: sourceId,
                                  catalog: catalog, library: library,
                                  parts: parts, jobs: jobs,
                                  textStore: textStore, playback: playback,
                                  onOpenModels: { onOpenModels(requirement(for: recipe)) },
                                  onUseText: onUseText, onBack: back)
        case .similar:
            SimilarActionView(recipe: recipe, sourceId: sourceId,
                              catalog: catalog, library: library,
                              parts: parts, jobs: jobs, playback: playback,
                              onOpenModels: { onOpenModels(requirement(for: recipe)) },
                              onBack: back)
        case .textPipeline(let kind):
            TextPipelineView(recipe: recipe, kind: kind, sourceId: sourceId,
                             settings: settings, catalog: catalog,
                             library: library, parts: parts, jobs: jobs,
                             textStore: textStore, chain: textChain,
                             playback: playback,
                             onOpenModels: { onOpenModels(requirement(for: recipe)) },
                             onBack: back)
        case .mapSections:
            SectionsActionView(recipe: recipe, sourceId: sourceId,
                               settings: settings, catalog: catalog,
                               library: library, parts: parts, jobs: jobs,
                               playback: playback,
                               onOpenModels: { onOpenModels(requirement(for: recipe)) },
                               onBack: back)
        case .promptScore:
            ScoreActionView(recipe: recipe, sourceId: sourceId,
                            settings: settings, catalog: catalog,
                            library: library, parts: parts, jobs: jobs,
                            playback: playback,
                            onOpenModels: { onOpenModels(requirement(for: recipe)) },
                            onBack: back)
        }
    }
}

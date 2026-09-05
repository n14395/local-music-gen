import SwiftUI

/// The Style Transfer workspace.
///
/// Four bands in the order the work happens, the same frame `WorkbenchScreen`
/// uses: what you are working on (top bar), anything the app needs to say
/// (notices), the controls and the takes beside them (content), and what
/// pressing the button will do (commit bar).
///
/// Deliberately **not** built on `ActionPage`, which hardcodes a `Recipe`,
/// binds Escape to a back action and fixes the rail width. A destination has no
/// "back" — that is the point of promoting this out of Actions — so the frame
/// comes from the bench and the pieces that are frame-agnostic
/// (`ActionSourceCard`, `ActionModelPicker`, `ActionCommitRow`) are re-hosted
/// inside it.
struct StyleTransferScreen: View {
    let model: StyleTransferModel
    let catalog: ModelCatalogStore
    let library: LibraryStore
    let parts: PartsStore
    let jobs: JobsStore
    let playback: PlaybackController
    let telemetry: TelemetryStore
    let timings: RenderTimingStore
    let notifications: NotificationService
    let onOpenModels: (ModelRequirement?) -> Void

    /// Which slot the picker sheet is filling.
    private enum PickTarget: String, Identifiable {
        case source, reference
        var id: String { rawValue }
    }

    private enum ControlMode: String {
        case simple, full
    }

    @State private var picking: PickTarget?
    /// Rebuilt whenever the model changes; seeded from — and written back to —
    /// `model.overrides`, which is what survives that rebuild.
    @State private var formState = ParameterFormState(specs: [])
    @AppStorage("styleTransfer.controlMode") private var controlMode: ControlMode = .simple
    /// Set when the user asks for the controls back while a run is in flight
    /// — Generate's `showingComposer`, under this screen's name for it.
    @State private var showingWorkspace = false
    /// The source and reference cards' second lines, resolved when their
    /// material changes.
    ///
    /// `ActionCopy.sourceMeta` is a song read plus an analysis read each, and
    /// both were being asked for from inside `body` — so four queries ran
    /// between one keystroke of the prompt and the next. The lines only depend
    /// on the materials, so they are resolved with them.
    @State private var sourceMeta: String?
    @State private var referenceMeta: String?
    /// Which installed models serve each mode, the smallest one that would,
    /// and the line to show when none does — rebuilt when the catalog moves
    /// and not before.
    ///
    /// Answering "can anything run this mode?" is a filter over the whole
    /// catalog with a requirement check per model, and the eleven mode chips,
    /// the card beneath them and the model picker all ask it. That was a
    /// dozen full passes over a hundred-odd models on every redraw of a
    /// screen that redraws for every keystroke in the prompt field. The
    /// answers depend on the catalog and on nothing else, so `catalog.version`
    /// is the whole key — the same bargain `ActionsScreen.cardStates` makes.
    @State private var eligibleByMode: [StyleTransferMode: [ModelInfo]] = [:]
    @State private var smallestCandidateByMode: [StyleTransferMode: ModelInfo] = [:]
    @State private var unavailableReasonByMode: [StyleTransferMode: String] = [:]
    @AppStorage("actions.lastRuns") private var runsJSON = "{}"
    /// The action log, decoded once rather than at render time.
    ///
    /// It lives in `@AppStorage` as a JSON blob, and the takes rail was asking
    /// for the whole thing to be parsed from inside `body` — so every redraw
    /// re-decoded it, which on this screen is every keystroke in the prompt.
    @State private var runLog = ActionRunLog()

    private var models: [ModelInfo] { catalog.models }
    private var chosen: ModelInfo? { model.model(in: models) }

    /// The jobs this workspace is waiting on, as queue rows — what the
    /// full-page render view draws. `outstandingJobIds` covers one-shot runs
    /// and the chain's current step alike.
    private var renderingJobs: [JobsStore.ActiveJob] {
        let ids = model.outstandingJobIds
        return jobs.displayJobs.filter {
            !$0.status.isTerminal && ids.contains($0.id)
        }
    }

    /// Chain-aware: between two chain steps there is a moment with no live
    /// job, and the page must not blink back to the workspace across it.
    private var isRendering: Bool {
        let ids = model.outstandingJobIds
        // Off `busy` rather than `renderingJobs` — see `StudioView`.
        return jobs.busy.contains { ids.contains($0.id) } || model.isChainRunning
    }

    private var showsRendering: Bool { isRendering && !showingWorkspace }
    /// Whether anything on this screen may claim a model is missing. Every
    /// mode chip, the model picker and the commit bar all answer "is X
    /// installed" from `models`, which is empty for the first second of a
    /// launch whether or not anything is installed.
    private var readiness: CatalogReadiness { catalog.readiness }
    private var knowsModels: Bool { readiness.knowsWhatIsInstalled }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            topBar
            if showsRendering {
                // The same full-page render Generate shows: the run gets the
                // whole screen, and the pill in the top bar is the way back
                // to the controls. The takes rail goes with the workspace —
                // its results reappear the moment the run lands and the page
                // flips back on its own.
                StudioRenderingPane(jobs: jobs, library: library,
                                    playback: playback, catalog: catalog,
                                    telemetry: telemetry, timings: timings,
                                    notifications: notifications,
                                    renderingJobs: renderingJobs,
                                    waitingLine: chainWaitingLine)
            } else {
                // The stems card draws the chain plan and the cost line counts
                // its jobs, and building it walks the stem pool against the
                // catalog. Built once here and handed down, rather than asked
                // for by each of them.
                let plan = model.plannedChain(in: models)
                if model.pendingPreset != nil || model.notice != nil {
                    noticeStrip
                }
                HStack(spacing: 0) {
                    mainColumn(chain: plan)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    BenchInspector(width: Bench.Metrics.Inspector.takes) {
                        StyleTransferTakesRail(
                            model: self.model, playback: playback,
                            lastRun: lastRun, onReplay: replay)
                    }
                }
                .frame(maxHeight: .infinity)
                commitBar(chain: plan)
            }
        }
        .background(Bench.Palette.windowBackground)
        // The workspace's ⌘↩, named by the mode the way the commit bar is.
        // Published for the same reason the bench publishes its Create Mix:
        // the Render menu's first item belongs to whichever screen is up, and
        // on this one the key used to do nothing.
        .focusedSceneValue(\.runCommand, RunCommand(
            title: model.mode.isChain ? "Run the Chain" : "Transform",
            isEnabled: knowsModels && model.blockedReason(in: models) == nil,
            run: { Task { await run() } }))
        .onAppear(perform: restore)
        .task { runLog = ActionRunLog.decoded(runsJSON) }
        .onChange(of: runsJSON) { runLog = ActionRunLog.decoded(runsJSON) }
        .onChange(of: model.source) { refreshMaterialMeta() }
        .onChange(of: model.reference) { refreshMaterialMeta() }
        .onChange(of: model.mode) { rebuildForm() }
        .onChange(of: model.selectedModelId) { rebuildForm() }
        .onChange(of: catalog.version) {
            refreshEligibility()
            reconcile()
        }
        // `parts.results.count`, not the array: the planner only needs to
        // know the pool changed, and observing every record subscribed this
        // whole screen to each parts search and each ingest.
        .onChange(of: parts.results.count) {
            model.refreshPlannerInput(parts: parts)
        }
        // Coming back to a finished run should not leave you stranded on an
        // empty rendering pane — same rule as Generate.
        .onChange(of: isRendering) { if !isRendering { showingWorkspace = false } }
        .sheet(item: $picking) { target in
            picker(for: target)
        }
    }

    /// What the hero slot says across a chain's seams — which step of the
    /// plan is (about to be) running.
    private var chainWaitingLine: String {
        model.chain.map { $0.plan.statusLine($0.progress) } ?? "Starting…"
    }

    // MARK: - Top bar

    private var topBar: some View {
        BenchTopBar {
            HStack(spacing: 10) {
                Text("Style Transfer").font(Bench.Typo.screenTitle)
                    .foregroundStyle(Bench.Palette.textPrimary)
                if let name = model.presetName {
                    BenchBadge(name.uppercased(), tone: .violet)
                }
                if let source = model.source {
                    Text(source.sourceTitle)
                        .font(Bench.Typo.secondary)
                        .foregroundStyle(Bench.Palette.textMuted)
                        .lineLimit(1)
                }
            }
        } trailing: {
            HStack(spacing: 8) {
                // The same pill Generate wears: the way between the run and
                // the controls, and the sign that something is in flight.
                if isRendering {
                    RenderStatusPill(
                        label: showingWorkspace
                            ? "Back to render"
                            : QueueLoad.of(jobs: renderingJobs).renderingLabel,
                        direction: showingWorkspace ? .toRender : .toWorkspace) {
                        showingWorkspace.toggle()
                    }
                }
                // The engine has forgotten the job this chain is waiting on —
                // a backend restart, a result that never ingested. Without an
                // explicit way out the workspace would stay locked forever,
                // because every other control is gated on `isChainRunning`.
                if model.isChainStranded(jobs: jobs) {
                    Button("Stop waiting") { model.dismissChain() }
                        .buttonStyle(.bench(.destructive))
                }
                // Locked while a chain is in flight. Clearing would abandon
                // jobs that are still running and leave their results
                // unattributed in the Library — and the chain is the one thing
                // here that cannot simply be started again cheaply.
                if model.isConfigured, !showsRendering {
                    Button("Clear") { model.clearConfiguration() }
                        .buttonStyle(.bench(.quiet))
                        .disabled(model.isChainRunning)
                }
                if !showsRendering {
                    BenchSegmented(selection: $controlMode, options: [
                        .init(value: .simple, label: "Simple"),
                        .init(value: .full, label: "Full control"),
                    ])
                }
            }
        }
    }

    // MARK: - Notices

    /// The strip's two jobs are independent: saying something, and holding an
    /// un-applied preset. Nesting the buttons inside the message meant a
    /// dismissed message stranded the preset behind an empty band, with no way
    /// left to accept or refuse it.
    @ViewBuilder
    private var noticeStrip: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(model.notice ?? "A preset is waiting to be applied.")
                .font(Bench.Typo.secondary)
                .foregroundStyle(Bench.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            // A preset that arrived while the workspace was already configured
            // is offered, never applied — silently throwing away a setup is the
            // exact failure this screen exists to prevent.
            if model.pendingPreset != nil {
                Button("Apply preset") {
                    model.applyPendingPreset(models: models)
                    rebuildForm()
                }
                .buttonStyle(.bench(.accent))
                Button("Keep mine") { model.dismissPendingPreset() }
                    .buttonStyle(.bench(.quiet))
            } else {
                Button("Dismiss") { model.notice = nil }
                    .buttonStyle(.bench(.quiet))
            }
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Bench.Palette.panel)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Bench.Palette.hairline).frame(height: 1)
        }
    }

    // MARK: - Main column

    private func mainColumn(chain: StyleTransferChain?) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                sourceCards
                modeSection
                controls(chain: chain)
                modelSection
                advancedSection
            }
            .padding(.horizontal, 30)
            .padding(.top, 26)
            .padding(.bottom, 20)
        }
    }

    // MARK: Source and reference

    @ViewBuilder
    private var sourceCards: some View {
        ActionSourceCard(
            eyebrow: model.mode.sourceNeed == .optional
                ? "YOUR TRACK (OPTIONAL)" : "TRACK TO TRANSFORM",
            material: model.source,
            meta: sourceMeta,
            playback: playback,
            placeholder: model.mode.sourceNeed == .optional
                ? "Optional — with nothing here the model writes from scratch, "
                    + "shaped by the reference."
                : "Choose the audio this transformation works on.",
            chooseTitle: model.source == nil ? "Choose from Library…" : "Change…",
            isEnabled: !model.isChainRunning,
            onChoose: { picking = .source },
            onRemove: model.source == nil || model.isChainRunning ? nil : {
                model.setSource(nil)
            })

        // Some models serve a mode without taking a source at all —
        // MusicGen-Style writes from its excerpt and has no source input. The
        // track would otherwise be quietly dropped at submit, which is the one
        // thing this screen must never do.
        if model.source != nil, let chosen, !sourceReaches(chosen) {
            ActionFootnote(
                text: "\(chosen.displayName) writes from the reference alone "
                    + "and has no input for your track — it will be ignored. "
                    + "Pick another model to keep it.",
                tone: Bench.Palette.warn)
        }

        if model.mode.referenceNeed.isNeeded {
            ActionSourceCard(
                eyebrow: model.mode.referenceNeed == .required
                    ? "SOUND TO BORROW" : "STYLE REFERENCE (OPTIONAL)",
                material: model.reference,
                meta: referenceMeta,
                playback: playback,
                placeholder: "A track whose texture and production the model "
                    + "should borrow. Its melody is not copied.",
                chooseTitle: model.reference == nil
                    ? "Choose from Library…" : "Change…",
                isEnabled: !model.isChainRunning,
                onChoose: { picking = .reference },
                onRemove: model.reference == nil || model.isChainRunning ? nil : {
                    model.reference = nil
                })
        }
    }

    // MARK: Modes

    private var modeSection: some View {
        ActionOptionsCard(eyebrow: "WHAT DO YOU WANT TO KEEP?") {
            ForEach(StyleTransferMode.Group.allCases) { group in
                VStack(alignment: .leading, spacing: 8) {
                    Text(group.title).eyebrow()
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 168),
                                                 spacing: 8)],
                              spacing: 8) {
                        ForEach(StyleTransferMode.inGroup(group)) { mode in
                            modeChip(mode)
                        }
                    }
                    .disabled(model.isChainRunning)
                }
                .padding(.bottom, 4)
            }
            survivesCard
        }
    }

    private func modeChip(_ mode: StyleTransferMode) -> some View {
        // Until the engine answers, every mode is neither available nor
        // unavailable. Treating it as unavailable would grey out all eleven
        // and offer eleven downloads the user very likely already has.
        let isAvailable = !knowsModels || !(eligibleByMode[mode] ?? []).isEmpty
        let isSelected = model.mode == mode
        return Button {
            // A dimmed chip stays clickable on purpose: clicking it is the
            // shortest path to the model that lights it up, which is the same
            // bargain the gated Actions cards make. That bargain is off while
            // the catalog is unknown — there is no model to send anyone to.
            if isAvailable {
                self.model.mode = mode
            } else {
                routeToModels(for: mode)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: mode.icon)
                    .font(Bench.Typo.caption)
                    .frame(width: 14)
                Text(mode.title)
                    .font(Bench.Typo.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? Bench.Palette.onAccent
                                        : isAvailable ? Bench.Palette.textSecondary
                                                      : Bench.Palette.textFaint)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Bench.Metrics.Radius.control)
                    .fill(isSelected ? Bench.Palette.accent
                                     : Bench.Palette.raised))
            .overlay(
                RoundedRectangle(cornerRadius: Bench.Metrics.Radius.control)
                    .strokeBorder(isSelected ? Color.clear
                                             : Bench.Palette.cardStrokeSoft,
                                  lineWidth: 1))
            .opacity(isAvailable || isSelected ? 1 : 0.55)
        }
        .buttonStyle(.plain)
        .help(isAvailable ? mode.survives
                          : (unavailableReasonByMode[mode] ?? mode.survives))
    }

    /// The one line that stands in for every "you need to install something"
    /// this screen would otherwise be guessing at.
    @ViewBuilder
    private func catalogFootnote() -> some View {
        if let line = readiness.shortLine {
            HStack(spacing: 8) {
                if case .pending = readiness { BenchSpinner(size: 12) }
                Text(line)
                    .font(Bench.Typo.caption)
                    .foregroundStyle(Bench.Palette.textFaint)
                Spacer(minLength: 0)
            }
        }
    }

    /// What the chosen mode preserves, said plainly under the chips.
    ///
    /// This is the feature rather than a caveat attached to it: audio style
    /// transfer keeps a *different* thing in every mode, and a user who does
    /// not know which cannot tell a bad result from the wrong tool.
    private var survivesCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.mode.survives)
                .font(Bench.Typo.secondary)
                .foregroundStyle(Bench.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if !knowsModels {
                catalogFootnote()
            } else if let reason = unavailableReasonByMode[model.mode] {
                HStack(spacing: 10) {
                    Text(reason)
                        .font(Bench.Typo.caption)
                        .foregroundStyle(Bench.Palette.warn)
                    if let candidate = smallestCandidateByMode[model.mode] {
                        let label = "Get \(candidate.displayName) · "
                            + ByteFormat.gb(candidate.sizeBytes)
                        Button(label) { routeToModels(for: model.mode) }
                            .buttonStyle(.bench(.accent))
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Bench.Metrics.Radius.control)
                .fill(Bench.Palette.well))
    }

    // MARK: Controls

    @ViewBuilder
    private func controls(chain: StyleTransferChain?) -> some View {
        @Bindable var model = model

        if model.mode.isChain { stemsCard(chain: chain) }

        if model.mode.trackNeed.isNeeded {
            ActionOptionsCard(eyebrow: "INSTRUMENT") {
                HStack(spacing: 12) {
                    Text(model.mode.trackNeed == .optional ? "Focus on" : "Track")
                        .font(Bench.Typo.secondary)
                        .foregroundStyle(Bench.Palette.textSecondary)
                        .frame(width: 130, alignment: .leading)
                    BenchMenu(label: trackLabel) {
                        if model.mode.trackNeed == .optional {
                            Button("Automatic") { model.track = nil }
                        }
                        ForEach(model.trackChoices(in: models)) { choice in
                            Button(choice.label) { model.track = choice.value }
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }

        if model.mode.needsRegion, let source = model.source {
            ActionOptionsCard(eyebrow: "SECTION TO REGENERATE") {
                WaveformRegionSelector(
                    audioURL: source.fileURL,
                    cacheURL: source.waveformURL,
                    durationS: source.durationS ?? model.regionEndS,
                    startS: $model.regionStartS, endS: $model.regionEndS)
                ActionFootnote(
                    text: "Everything outside the window is kept exactly as it "
                        + "is; only the selected seconds are resampled.")
            }
        }

        if model.mode.needsPrompt {
            ActionOptionsCard(eyebrow: model.mode.promptLabel) {
                ActionTextField(placeholder: model.mode.promptPlaceholder,
                                text: $model.prompt,
                                font: Bench.Typo.promptCompact)
            }
        }

        if model.mode == .morph {
            ActionOptionsCard(eyebrow: "WHAT IS IT NOW?") {
                ActionTextField(
                    placeholder: "e.g. upbeat electropop with a female vocal",
                    text: $model.sourceCaption)
                ActionFootnote(
                    text: "A morph travels from this description to the one "
                        + "above, so the two together are the instruction. "
                        + "Left blank it starts from nothing in particular, "
                        + "which blurs the result rather than sharpening it.")
            }
        }

        strengthCard

        if model.wantsLyrics(in: models), let chosen {
            ActionOptionsCard(eyebrow: "LYRICS") {
                LyricsEditor(lyrics: $model.lyrics,
                             tags: chosen.capabilities.lyricsTags ?? [],
                             hint: chosen.capabilities.lyricsHint)
                    .frame(minHeight: 140)
            }
        }

        ActionOptionsCard(eyebrow: "NAME") {
            ActionTextField(placeholder: model.defaultName,
                            text: $model.outputName)
        }
    }

    /// The one dial. Two models express "how far from the source" with opposite
    /// senses and incompatible ranges; the mode converts, so the control can
    /// mean one thing.
    @ViewBuilder
    private var strengthCard: some View {
        if let dial = model.mode.dial, model.mode.hasDial(on: chosen) {
            ActionOptionsCard(eyebrow: "HOW FAR FROM THE ORIGINAL?") {
                let spec = model.mode.dialSpec(for: chosen)
                let amount = model.effectiveStyleAmount(in: models)
                HStack(spacing: 12) {
                    Text("Original")
                        .font(Bench.Typo.caption)
                        .foregroundStyle(Bench.Palette.textMuted)
                    BenchSlider(
                        value: Binding(
                            get: { amount },
                            set: { model.styleAmount = $0 }),
                        range: 0...1, step: 0.01)
                    Text("Style")
                        .font(Bench.Typo.caption)
                        .foregroundStyle(Bench.Palette.textMuted)
                    BenchValueField(
                        text: String(format: "%.0f%%", amount * 100), width: 52)
                }
                ActionFootnote(
                    text: model.styleAmount == nil
                        ? "At the model's own default — "
                            + "\(dial.key.replacingOccurrences(of: "_", with: " ")) "
                            + String(format: "%g",
                                     dial.wireValue(styleAmount: amount,
                                                    spec: spec))
                        : "\(dial.key.replacingOccurrences(of: "_", with: " ")) "
                            + String(format: "%g",
                                     dial.wireValue(styleAmount: amount,
                                                    spec: spec)))
            }
        }
    }

    /// Which stems survive literally, for the chain mode.
    @ViewBuilder
    private func stemsCard(chain plan: StyleTransferChain?) -> some View {
        ActionOptionsCard(eyebrow: "STEMS TO KEEP") {
            if model.source == nil {
                ActionFootnote(text: "Choose a song first.")
            } else if model.plannerInput.isEmpty {
                ActionFootnote(
                    text: "This song has not been split yet. Running will "
                        + "separate it first — then come back and tick the "
                        + "stems to keep.")
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150),
                                             spacing: 8)], spacing: 8) {
                    ForEach(model.plannerInput) { stem in
                        stemChip(stem)
                    }
                }
            }
            if let plan {
                ForEach(Array(plan.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(index + 1)")
                            .font(Bench.Typo.counter)
                            .foregroundStyle(Bench.Palette.textFaint)
                            .frame(width: 14, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(step.title) · \(step.modelName)")
                                .font(Bench.Typo.caption)
                                .foregroundStyle(Bench.Palette.textSecondary)
                            Text(step.detail)
                                .font(Bench.Typo.micro)
                                .foregroundStyle(Bench.Palette.textFaint)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                }
                ForEach(plan.warnings, id: \.self) { warning in
                    ActionFootnote(text: warning, tone: Bench.Palette.warn)
                }
            }
        }
    }

    private func stemChip(_ stem: StyleTransferChain.Stem) -> some View {
        let isKept = model.keptStems.contains(stem.kind)
        return Button {
            if isKept { model.keptStems.remove(stem.kind) }
            else { model.keptStems.insert(stem.kind) }
        } label: {
            HStack(spacing: 8) {
                StemBar(kind: stem.kind, width: 4, height: 14)
                Text(stem.name)
                    .font(Bench.Typo.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(isKept ? "KEEP" : "REPLACE")
                    .font(Bench.Typo.badge)
                    .foregroundStyle(isKept ? Bench.Palette.ok
                                            : Bench.Palette.textFaint)
            }
            .foregroundStyle(Bench.Palette.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: Bench.Metrics.Radius.control)
                    .fill(isKept ? Bench.Palette.cardSelected
                                 : Bench.Palette.raised))
            .overlay(
                RoundedRectangle(cornerRadius: Bench.Metrics.Radius.control)
                    .strokeBorder(isKept ? Bench.Palette.ok.opacity(0.5)
                                         : Bench.Palette.cardStrokeSoft,
                                  lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var trackLabel: String {
        guard let track = model.track else { return "Automatic" }
        return model.trackChoices(in: models)
            .first { $0.value == track }?.label ?? track
    }

    // MARK: Model

    @ViewBuilder
    private var modelSection: some View {
        @Bindable var model = model
        let eligible = eligibleByMode[model.mode] ?? []
        if eligible.isEmpty {
            ActionModelGate(
                readiness: readiness,
                title: "No installed model can do this yet",
                detail: unavailableReasonByMode[model.mode]
                    ?? "Install a model that supports this transformation.",
                onOpenModels: { routeToModels(for: model.mode) })
        } else {
            ActionModelPicker(
                eyebrow: "MODEL", models: eligible,
                selectedId: Binding(get: { chosen?.id },
                                    set: { model.selectedModelId = $0 }),
                meta: modelMeta)
        }
    }

    /// Whether the chosen model has anywhere to put the source track in this
    /// mode.
    private func sourceReaches(_ candidate: ModelInfo) -> Bool {
        candidate.capabilities.params
            .contains { $0.key == model.mode.sourceAudioKey }
    }

    private func modelMeta(_ candidate: ModelInfo) -> String {
        let estimate = ActionEstimate.generativeSeconds(
            model: candidate,
            durationS: model.requestedDurationS(model: candidate))
        return ActionFormat.join(["INSTALLED", ActionFormat.estimate(estimate)])
    }

    // MARK: Advanced

    @ViewBuilder
    private var advancedSection: some View {
        let specs = model.knobSpecs(in: models)
        if !specs.isEmpty {
            advancedSummary
            if controlMode == .full {
                ActionOptionsCard {
                    HStack(spacing: 10) {
                        Text("PARAMETERS").eyebrow()
                        // Counts what *this* model will send, not everything
                        // the document is holding for other models.
                        let changed = model.applicableOverrides(in: models).count
                        if changed > 0 {
                            BenchBadge("\(changed) CHANGED", tone: .accent)
                        }
                        Spacer(minLength: 8)
                        if !model.overrides.isEmpty {
                            Button("Reset") {
                                model.overrides = [:]
                                rebuildForm()
                            }
                            .buttonStyle(.bench(.quiet))
                        }
                    }
                    // Ungrouped so the knobs do not grow a second layer of
                    // cards inside this one — but with the explanations kept,
                    // which is the whole difference between "Full control"
                    // and a column of unlabelled sliders.
                    ParameterFormView(state: formState, grouped: false,
                                      showsHelp: true, labelWidth: 130,
                                      materialPicker: MaterialPickerContext(
                                          catalog: catalog, library: library,
                                          parts: parts, jobs: jobs,
                                          playback: playback,
                                          onOpenModels: { onOpenModels(nil) }))
                        .onChange(of: formState.values) { captureOverrides() }
                }
            }
        }
    }

    /// The parameter values stay visible in Simple mode, just as they do in
    /// Generate, so the full form is never an opaque "Advanced" drawer.
    private var advancedSummary: some View {
        let isOpen = controlMode == .full
        return Button { controlMode = isOpen ? .simple : .full } label: {
            HStack(spacing: 14) {
                Text(summaryText)
                    .font(Bench.Typo.mono(12))
                    .foregroundStyle(Bench.Palette.textQuaternary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                HStack(spacing: 4) {
                    Text("Full control")
                    Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
                .font(Bench.Typo.secondaryEmphasis)
                .foregroundStyle(Bench.Palette.accent)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.card)
                .fill(Color(hex: 0x131820)))
            .overlay(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.card)
                .strokeBorder(Bench.Palette.hairline, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.card))
        }
        .buttonStyle(.plain)
        .help(isOpen ? "Hide the full parameter panel"
                     : "Open the full parameter panel")
    }

    private var summaryText: String {
        let interesting = formState.specs.filter {
            $0.isInternal != true && ($0.type == .int || $0.type == .float
                || $0.type == .enum || $0.type == .bool)
        }
        return interesting.prefix(4).map { spec in
            let value: String
            switch spec.type {
            case .int, .float:
                value = formState.isNull(spec) ? "random"
                    : (spec.type == .int ? String(Int(formState.doubleValue(spec)))
                                         : String(format: "%g", formState.doubleValue(spec)))
            case .bool:
                value = formState.boolValue(spec) ? "on" : "off"
            default:
                value = formState.stringValue(spec)
            }
            return "\(spec.label.uppercased()) \(value)"
        }.joined(separator: " · ")
    }

    // MARK: - Commit bar

    private func commitBar(chain: StyleTransferChain?) -> some View {
        // `canRun` *is* `blockedReason == nil`, and asking for both walked the
        // catalog and rebuilt the chain plan twice over to answer one question.
        let blocked = knowsModels ? model.blockedReason(in: models) : nil
        return ActionCommitRow(
            title: model.mode.isChain ? "Run the chain" : "Transform",
            costLine: costLine(chain: chain),
            costSubline: "ORIGINAL IS NEVER MODIFIED",
            isEnabled: knowsModels && blocked == nil,
            error: knowsModels ? (blocked ?? jobs.lastError)
                               : readiness.shortLine,
            queueTitle: nil,
            onCommit: { Task { await run() } })
    }

    private func costLine(chain plan: StyleTransferChain?) -> String? {
        if let chain = model.chain {
            return chain.plan.statusLine(chain.progress).uppercased()
        }
        guard let chosen else { return nil }
        let estimate = ActionEstimate.generativeSeconds(
            model: chosen, durationS: model.requestedDurationS(model: chosen))
        var parts: [String?] = [ActionFormat.estimate(estimate)]
        if let plan, plan.isRunnable {
            parts.append("\(plan.jobCount) JOBS")
        }
        parts.append(model.mode.outputsPart ? "SAVED TO LIBRARY › PARTS"
                                            : "SAVED TO LIBRARY › SONGS")
        return ActionFormat.join(parts)
    }

    // MARK: - Actions

    private func run() async {
        let context = StyleTransferModel.RunContext(
            jobs: jobs, parts: parts, library: library, models: models)
        guard let jobId = await model.run(context) else { return }
        recordRun(jobId: jobId)
    }

    /// Keep the shared "last run of this action" log fed, so an Actions card
    /// still shows what it last did even though it no longer owns a page.
    private func recordRun(jobId: String) {
        guard let recipeId = model.presetId, let chosen else { return }
        let detail = ActionFormat.join([
            chosen.displayName.uppercased(),
            model.track?.uppercased(),
            model.overrides.isEmpty ? nil
                : "\(model.overrides.count) PARAMS",
        ])
        runsJSON = ActionRunLog.recording(
            .init(summary: model.effectiveName, detail: detail, at: Date(),
                  sourceId: model.source?.id, modelId: chosen.id),
            recipeId: recipeId, in: runsJSON)
    }

    private var lastRun: ActionRunLog.Entry? {
        guard let recipeId = model.presetId else { return nil }
        return runLog.runs[recipeId]
    }

    private func replay() {
        guard let entry = lastRun else { return }
        if let sourceId = entry.sourceId,
           let material = PickedMaterial.resolve(id: sourceId, parts: parts,
                                                 library: library) {
            model.setSource(material)
            model.refreshPlannerInput(parts: parts)
        }
        if let modelId = entry.modelId,
           model.mode.eligible(models).contains(where: { $0.id == modelId }) {
            model.selectedModelId = modelId
        }
    }

    /// Send the user to Models, having first made sure the model they were just
    /// told to get will actually be visible when they arrive — the list hides
    /// everything unfeatured behind "Show all", and several of the models that
    /// unlock these modes are nested variants.
    private func routeToModels(for mode: StyleTransferMode) {
        // The mode's own eligibility travels with the jump, so Models narrows
        // to the builds that can actually serve it — which is most of the
        // point here, since a mode is typically served by nested DiT variants
        // and unfeatured Stable Audio builds rather than by anything the
        // default list shows.
        onOpenModels(.style(mode))
    }

    // MARK: - Lifecycle

    private func restore() {
        refreshEligibility()
        refreshMaterialMeta()
        reconcile()
        model.refreshPlannerInput(parts: parts)
        rebuildForm()
    }

    private func reconcile() {
        model.reconcileSelection(in: models)
    }

    private func refreshMaterialMeta() {
        sourceMeta = model.source.map {
            ActionCopy.sourceMeta($0, library: library, parts: parts)
        }
        referenceMeta = model.reference.map {
            ActionCopy.sourceMeta($0, library: library, parts: parts)
        }
    }

    /// Re-answer every mode's eligibility question against the catalog as it
    /// now stands. Cheap enough to do all eleven at once, because it happens
    /// when the catalog changes rather than when the screen redraws.
    private func refreshEligibility() {
        var eligible: [StyleTransferMode: [ModelInfo]] = [:]
        var smallest: [StyleTransferMode: ModelInfo] = [:]
        var reasons: [StyleTransferMode: String] = [:]
        for mode in StyleTransferMode.allCases {
            eligible[mode] = mode.eligible(models)
            smallest[mode] = mode.candidates(models).first
            reasons[mode] = mode.unavailableReason(models)
        }
        eligibleByMode = eligible
        smallestCandidateByMode = smallest
        unavailableReasonByMode = reasons
    }

    /// Rebuild the generic form for the current model, re-seeding it from the
    /// overrides the document kept.
    ///
    /// The form state itself cannot hold them: its `specs` is a `let`, so
    /// switching model *must* construct a new one, and every knob set on the
    /// old one would go with it. Keeping the values in the document and
    /// replaying them here is what makes a model switch non-destructive.
    private func rebuildForm() {
        let specs = model.knobSpecs(in: models)
        let state = ParameterFormState(specs: specs)
        state.apply(overrides: model.overrides)
        formState = state
        captureOverrides()
    }

    /// Fold the visible form back into the document.
    ///
    /// Merges rather than assigns, and that distinction is the whole point of
    /// keeping overrides here at all. The form only knows the keys the
    /// *current* model declares, so writing its output wholesale would delete
    /// an override belonging to a model the user is one click away from
    /// switching back to — the same knob-loss the store exists to prevent, one
    /// level up. Keys the current model does declare are replaced outright, so
    /// clearing a knob back to its default really clears it.
    private func captureOverrides() {
        var merged = model.overrides
        for spec in formState.specs { merged.removeValue(forKey: spec.key) }
        for (key, value) in formState.changedValues { merged[key] = value }
        model.overrides = merged
    }

    // MARK: - Picker

    @ViewBuilder
    private func picker(for target: PickTarget) -> some View {
        PartPickerSheet(
            slotLabel: target == .source ? "Track to transform"
                                         : "Sound to borrow",
            accepts: [KindPattern(pattern: "song.mix"),
                      KindPattern(pattern: "stem.*"),
                      KindPattern(pattern: "layer.*")],
            autoDerive: model.mode.isChain
                ? AutoDerive(splitTask: "separate",
                             note: "Split into stems first")
                : nil,
            catalog: catalog, library: library, parts: parts, jobs: jobs,
            // The picker's own "get a model" button is about the split this
            // sheet would auto-derive, not about the style mode behind it.
            playback: playback,
            onOpenModels: { onOpenModels(.task("separate")) },
            onPick: { picked in
                if target == .source {
                    model.setSource(picked)
                    model.refreshPlannerInput(parts: parts)
                } else {
                    model.reference = picked
                }
            })
    }
}

extension ParameterFormState {
    /// Seed from a stored override dict.
    ///
    /// Goes through the typed setters rather than assigning `values` because
    /// that property is `private(set)` — which is also what keeps the clamping
    /// on write, so a stored value from a model with a wider range lands inside
    /// the new model's bounds instead of being rejected by the engine.
    func apply(overrides: [String: JSONValue]) {
        for spec in specs {
            guard let value = overrides[spec.key] else { continue }
            switch value {
            case .null: setNull(spec)
            case .bool(let flag): setBool(spec, flag)
            case .string(let text): setString(spec, text)
            case .int(let number): setDouble(spec, Double(number))
            case .double(let number): setDouble(spec, number)
            case .array, .object: break     // json params are never user-edited
            }
        }
    }

    /// Everything that differs from the model's declared default — the only
    /// part worth carrying across a model switch.
    var changedValues: [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for spec in specs where spec.isInternal != true {
            if let value = values[spec.key], value != spec.default {
                out[spec.key] = value
            }
        }
        return out
    }
}

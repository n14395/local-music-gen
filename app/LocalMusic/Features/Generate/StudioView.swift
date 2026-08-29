import SwiftUI

/// Studio — where you ask for music.
///
/// Three states rather than three screens. **Simple** is one prompt, one
/// length, one button, with every advanced value collapsed into a single
/// readable line. **Full control** opens the parameter panel as a right rail
/// and gives lyrics room. While a job runs the screen becomes **Rendering**:
/// the take being made, the stage it is in, and the queue behind it — because
/// the thing you want when you have just pressed Generate is to watch, not to
/// keep typing. The header pill toggles back to the composer, so queueing a
/// second take never means waiting for the first.
struct StudioView: View {
    let catalog: ModelCatalogStore
    let jobs: JobsStore
    let library: LibraryStore
    let parts: PartsStore
    let playback: PlaybackController
    let telemetry: TelemetryStore
    let timings: RenderTimingStore
    let notifications: NotificationService
    let prefill: PrefillBox
    let actions: SongActions
    let settings: AppSettings
    let onOpenModels: () -> Void

    enum Mode: String { case simple, full }

    @AppStorage("studio.mode") private var mode: Mode = .simple
    @State private var selectedModelId: String?
    /// One line above the composer saying what an Actions card just changed.
    /// Dismissible, and gone the moment you press Generate: it describes an
    /// arrival, and after the first take it is describing history.
    @State private var notice: String?
    @State private var prompt = ""
    @State private var lyrics = ""
    /// What the finished tracks will be called. Left empty on purpose: the
    /// `trackNNN` default is the field's *placeholder*, not text sitting in
    /// it, so it stays visibly a default — it follows the library forward on
    /// its own, and it is never something you have to clear before typing.
    @State private var name = ""
    @State private var durationS: Double
    @State private var count: Int
    /// "Unlock max length", from Full control. Deliberately `@State` and not
    /// `@AppStorage`: it is a per-session decision about one render, and a
    /// ceiling that silently stayed unlocked from last week is exactly the
    /// surprise the warning is there to prevent. `clampToModel` clears it
    /// whenever the model changes, so it can never outlive the model it was
    /// granted for.
    @State private var unlockLength = false
    @State private var formState = ParameterFormState(specs: [])
    /// Reference audio waiting to land in the (possibly not-yet-rebuilt) form.
    @State private var pendingAudio: [String: URL] = [:]
    /// Reused parameter values waiting for the same rebuild. Same deferral as
    /// `pendingAudio` and for the same reason — see the note over the state
    /// plumbing below.
    @State private var pendingParams: [String: JSONValue] = [:]
    /// A reused length, held until the model it was measured against is the
    /// one on screen. Deferred rather than assigned because it is the only
    /// value here that can need `unlockLength` turned on to survive
    /// `clampToModel`, and that decision needs the arriving model, not the
    /// outgoing one.
    @State private var pendingDurationS: Double?
    /// Set when the user asks to go back to composing while a render runs.
    @State private var showingComposer = false
    @State private var showingModelChooser = false

    /// Explicit only to seed two `@State`s from Settings — length and take
    /// count start where Settings says, then belong to the user (and to
    /// `clampToModel`) exactly as before.
    @MainActor
    init(catalog: ModelCatalogStore, jobs: JobsStore, library: LibraryStore,
         parts: PartsStore, playback: PlaybackController,
         telemetry: TelemetryStore,
         timings: RenderTimingStore, notifications: NotificationService,
         prefill: PrefillBox, actions: SongActions, settings: AppSettings,
         onOpenModels: @escaping () -> Void) {
        self.catalog = catalog
        self.jobs = jobs
        self.library = library
        self.parts = parts
        self.playback = playback
        self.telemetry = telemetry
        self.timings = timings
        self.notifications = notifications
        self.prefill = prefill
        self.actions = actions
        self.settings = settings
        self.onOpenModels = onOpenModels
        _durationS = State(initialValue: settings.defaultDurationS)
        _count = State(initialValue: max(1, settings.defaultTakes))
    }

    private var installed: [ModelInfo] {
        catalog.models.filter {
            $0.installState == .installed && $0.id != "test-tiny"
                && $0.capabilities.supportedTasks.contains("generate")
        }
    }

    private var model: ModelInfo? {
        installed.first { $0.id == selectedModelId }
    }

    /// Generate jobs only — a separation running in the background does not
    /// take over the composer.
    private var renderingJobs: [JobsStore.ActiveJob] {
        jobs.displayJobs.filter {
            !$0.status.isTerminal && $0.info.isGenerate
        }
    }

    private var isRendering: Bool { !renderingJobs.isEmpty }
    private var showsRendering: Bool { isRendering && !showingComposer }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if installed.isEmpty {
                noModels.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if showsRendering {
                StudioRenderingPane(jobs: jobs, library: library,
                                    playback: playback, catalog: catalog,
                                    telemetry: telemetry, timings: timings,
                                    notifications: notifications,
                                    renderingJobs: renderingJobs)
            } else {
                composer
            }
        }
        .onAppear { syncSelection(); applyPrefill() }
        .onChange(of: catalog.version) { syncSelection() }
        .onChange(of: selectedModelId) { rebuildForm() }
        // Re-locking has to pull the length back down with it, or the slider
        // would keep a value the model no longer offers and the engine would
        // clamp it on submit — the change happening somewhere you cannot see.
        .onChange(of: unlockLength) { clampToModel() }
        .onChange(of: prefill.pending) { applyPrefill() }
        // Coming back to a finished queue should not leave you stranded on an
        // empty rendering pane.
        .onChange(of: isRendering) { if !isRendering { showingComposer = false } }
    }

    // MARK: - Top bar

    private var topBar: some View {
        BenchTopBar {
            HStack(spacing: 14) {
                Text("Generate")
                    .font(Bench.Typo.screenTitle)
                    .tracking(-0.15)
                    .foregroundStyle(Bench.Palette.textPrimary)
            }
        } trailing: {
            HStack(spacing: 10) {
                if isRendering {
                    RenderStatusPill(
                        label: showingComposer
                            ? "Back to render"
                            : QueueLoad.of(jobs: renderingJobs).renderingLabel,
                        direction: showingComposer ? .toRender : .toWorkspace) {
                        showingComposer.toggle()
                    }
                    .help(showingComposer ? "Watch the render" : "Set up another take")
                }
                if !showsRendering {
                    BenchSegmented(selection: $mode, options: [
                        .init(value: .simple, label: "Simple"),
                        .init(value: .full, label: "Full control"),
                    ])
                }
            }
        }
    }

    // MARK: - Composer

    private var composer: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let notice { noticeBar(notice) }
                    if let model {
                        HStack(alignment: .center, spacing: 12) {
                            modelPicker(model, compact: false)
                            badgeRow(model)
                        }
                    }
                    promptCard
                    if let model, model.capabilities.supportsLyrics, mode == .full {
                        LyricsEditor(lyrics: $lyrics,
                                     tags: model.capabilities.lyricsTags ?? [],
                                     hint: model.capabilities.lyricsHint,
                                     fills: true)
                    }
                    if let model {
                        nameCard
                        lengthAndTakes(model)
                        advancedSummary
                        // Full control's parameters belong in the reading
                        // order they are used in: after the settings they
                        // refine, before the button that spends them. They
                        // were a second rail, which cost the takes column
                        // its place and put the knobs furthest from the
                        // control they modify.
                        if mode == .full {
                            StudioParameterPanel(
                                state: formState, model: model,
                                onApplyPreset: applyPreset, layout: .inline,
                                unlockLength: $unlockLength,
                                materialPicker: MaterialPickerContext(
                                    catalog: catalog, library: library,
                                    parts: parts, jobs: jobs,
                                    playback: playback,
                                    onOpenModels: onOpenModels))
                        }
                        generateRow(model)
                    }
                    if let error = jobs.lastError {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                            Text(error)
                        }
                        .font(Bench.Typo.secondary)
                        .foregroundStyle(Bench.Palette.danger)
                    }
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Takes stay put in both modes: what you made last is context for
            // what you are making now, and switching to full control was
            // never a request to stop showing it.
            BenchInspector(width: Bench.Metrics.Inspector.takes) {
                StudioTakesRail(library: library, playback: playback,
                                catalog: catalog, actions: actions,
                                // Through the prefill mailbox rather than by
                                // setting the fields here: the rail's three
                                // buttons and the Library's three menu items
                                // are the same three actions, and one of them
                                // has an ordering dance around the form
                                // rebuild that is not worth having twice.
                                onReuse: { song, scope in
                                    prefill.pending = GenerationSettings
                                        .prefill(for: song, scope: scope)
                                })
            }
        }
        .frame(maxHeight: .infinity)
    }

    /// What the chooser shows per model: the name and its labels on one line,
    /// what it is for underneath.
    ///
    /// The full row, the same one the heading and the Models screen carry —
    /// picking a model is exactly when its size and speed matter, and a list
    /// that showed less than the heading above it made you close the list to
    /// find out what you had just chosen. The row wraps them under the name
    /// rather than truncating.
    private var chooserEntries: [ModelChooser.Entry] {
        installed.map { candidate in
            ModelChooser.Entry(
                id: candidate.id,
                name: candidate.displayName,
                description: candidate.description,
                family: candidate.family,
                isFavourite: catalog.isFavourite(candidate.id),
                badges: badges(candidate))
        }
    }

    private func modelPicker(_ model: ModelInfo, compact: Bool) -> some View {
        Button {
            showingModelChooser = true
        } label: {
            // The design writes the model as a heading with a disclosure
            // chevron in front of it, not as a button: it names what you are
            // working with, and the badges beside it finish the sentence. A
            // filled, bordered pill made it read as a control competing with
            // the screen title next to it.
            HStack(spacing: 7) {
                Image(systemName: "chevron.down")
                    .font(.system(size: compact ? 9 : 10, weight: .semibold))
                    .foregroundStyle(Bench.Palette.textMuted)
                Text(model.displayName)
                    .font(compact ? Bench.Typo.bodyEmphasis
                                  : .system(size: 15, weight: .semibold))
                    .foregroundStyle(Bench.Palette.textPrimary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .popover(isPresented: $showingModelChooser, arrowEdge: .bottom) {
            ModelChooser(entries: chooserEntries,
                         selectedId: selectedModelId,
                         onPick: { selectedModelId = $0 },
                         onManage: onOpenModels,
                         onToggleFavourite: { catalog.toggleFavourite($0) })
        }
    }

    /// The same row of tokens the Models screen draws under this model's name
    /// — modality, ceiling, size, speed, licence, what it unlocks — so the two
    /// screens describe one model the same way. Built by `ModelBadges`.
    ///
    /// A disk warning is the one thing that cannot appear here: it is only
    /// drawn for a model you have not downloaded, and Studio only ever offers
    /// models you have.
    private func badges(_ model: ModelInfo) -> [ModelBadges.Badge] {
        ModelBadges.list(for: model,
                         isVariant: model.variantOf != nil,
                         physicalMemory: ModelCatalogStore.physicalRAM,
                         hasHFToken: catalog.hasHFToken,
                         actionCount: ModelActions.count(for: model))
    }

    /// The badge row beside the picker. It wraps rather than pushing the
    /// composer sideways: the full list is six tokens wide on a model with an
    /// awkward licence, and the column it sits in is not always that wide.
    private func badgeRow(_ model: ModelInfo) -> some View {
        FlowLayout(spacing: 6, rowSpacing: 6) {
            ForEach(badges(model)) { badge in
                BenchBadge(badge.text, tone: badge.tone)
            }
        }
    }

    /// One line of badges, kept at its natural width. For the top bar, where
    /// wrapping is not an option.
    // MARK: prompt

    private var promptCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("PROMPT").eyebrow()
            StudioPromptEditor(text: $prompt, font: Bench.Typo.promptHero)
            if mode == .simple {
                HStack(spacing: 10) {
                    attachment("Lyrics",
                               enabled: model?.capabilities.supportsLyrics ?? false,
                               disabledNote: "instrumental model") {
                        mode = .full
                    }
                    if hasParam(type: .audio, containing: "reference") {
                        attachment("Style reference", enabled: true) { mode = .full }
                    }
                    if hasParam(type: .audio, containing: "src")
                        || hasParam(type: .audio, containing: "init")
                        || hasParam(type: .audio, containing: "melody") {
                        attachment("Source audio", enabled: true) { mode = .full }
                    }
                    Spacer()
                    Text("\(prompt.count) CHARS")
                        .font(Bench.Typo.mono(11))
                        .foregroundStyle(Bench.Palette.textFaintest)
                }
                .padding(.top, 14)
                .overlay(alignment: .top) {
                    Rectangle().fill(Bench.Palette.hairline).frame(height: 1)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .benchCard(radius: Bench.Metrics.Radius.cardLarge)
    }

    private func hasParam(type: ParamType, containing token: String) -> Bool {
        model?.capabilities.params.contains {
            $0.type == type && $0.key.contains(token)
        } ?? false
    }

    /// A disabled attachment says *why* rather than vanishing — "＋ Lyrics —
    /// instrumental model" teaches you something about the model you picked.
    private func attachment(_ title: String, enabled: Bool,
                            disabledNote: String? = nil,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Text("＋ \(title)")
                    .font(Bench.Typo.secondary)
                    .foregroundStyle(enabled ? Bench.Palette.textSecondary
                                             : Bench.Palette.textFaint)
                if !enabled, let disabledNote {
                    Text("— \(disabledNote)")
                        .font(Bench.Typo.caption)
                        .foregroundStyle(Bench.Palette.textFaint)
                }
            }
            .padding(.horizontal, 11).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.button)
                .fill(Bench.Palette.controlDim))
            .contentShape(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.button))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(enabled ? "Open Full control to set this" : (disabledNote ?? ""))
    }

    // MARK: name

    /// What the finished tracks are called, offered pre-filled with the
    /// `trackNNN` the library is up to.
    private var nameCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline) {
                Text("Name")
                    .font(Bench.Typo.secondary)
                    .foregroundStyle(Bench.Palette.textQuaternary)
                Spacer()
                if let footnote = nameFootnote {
                    Text(footnote)
                        .font(Bench.Typo.mono(10))
                        .foregroundStyle(Bench.Palette.textFaintest)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            BenchTextField(text: $name, placeholder: library.nextTrackName)
            if let taken = nameCollision {
                Text(taken)
                    .font(Bench.Typo.caption)
                    .foregroundStyle(Bench.Palette.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .benchCard()
    }

    /// Said before you generate, not after. A name identifies one track —
    /// renaming to a taken name is refused outright — but a generation
    /// cannot be refused at ingest, because by then the audio exists. So the
    /// name is made free on the way in and this says it will be, while there
    /// is still time to type a different one.
    ///
    /// Warn, not error: generating a second "warehouse jam" is a reasonable
    /// thing to do, and the take letters already disambiguate a batch.
    private var nameCollision: String? {
        guard !isDefaultName else { return nil }
        let names = SongRecord.takeNames(base: effectiveName, count: count)
        let clashes = names.filter { library.titleIsTaken($0, excluding: "") }
        guard let first = clashes.first else { return nil }
        if clashes.count == names.count, names.count > 1 {
            return "Those names are all taken — the takes will land as "
                + "“\(library.uniqueTitle(first))” and so on."
        }
        return "“\(first)” is taken — it will land as "
            + "“\(library.uniqueTitle(first))”."
    }

    /// The name a submission right now would use: what you typed, or the
    /// library's next `trackNNN` when you have typed nothing.
    private var effectiveName: String {
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? library.nextTrackName : typed
    }

    /// Whether the field is still offering the default rather than holding a
    /// name of yours.
    private var isDefaultName: Bool { effectiveName == library.nextTrackName }

    /// `track042a … track042c` — what the takes will actually be called, which
    /// is the one thing the field cannot show once a letter is involved.
    private var nameFootnote: String? {
        guard count > 1 else { return nil }
        let names = SongRecord.takeNames(base: effectiveName, count: count)
        guard let first = names.first, let last = names.last else { return nil }
        return count == 2 ? "\(first) · \(last)" : "\(first) … \(last)"
    }

    // MARK: length + takes

    private func lengthAndTakes(_ model: ModelInfo) -> some View {
        let duration = model.capabilities.duration
        return HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 11) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Length")
                        .font(Bench.Typo.secondary)
                        .foregroundStyle(Bench.Palette.textQuaternary)
                    Spacer()
                    Text(durationS < 60 ? String(format: "%.1f s", durationS)
                                        : "\(Int(durationS)) s")
                        .font(Bench.Typo.valueLarge)
                        .foregroundStyle(Bench.Palette.textPrimary)
                }
                DurationBar(value: $durationS,
                            range: duration.minS...effectiveMaxS(model))
                HStack {
                    Text("0")
                    Spacer()
                    // Unlocked, the ceiling is no longer the model's own
                    // recommendation, and the readout says so rather than
                    // just showing a bigger number: this is the one place
                    // the length is read back after the toggle is out of
                    // sight in Full control.
                    Text(isUnlocked(model)
                         ? "UNLOCKED \(Int(effectiveMaxS(model))) S"
                         : "MAX \(Int(duration.maxS)) S")
                }
                .font(Bench.Typo.mono(10))
                .foregroundStyle(isUnlocked(model)
                                 ? Bench.Palette.warn
                                 : Bench.Palette.textFaintest)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .benchCard()

            if model.capabilities.outputsPerJobMax > 1 {
                StudioTakesCard(count: $count, model: model,
                                width: 150)
            }
        }
    }

    // MARK: advanced summary

    /// The whole parameter panel reduced to one legible line. This is the
    /// design's answer to a disclosure triangle: you can always read what the
    /// advanced values are without opening anything.
    /// The disclosure for the parameters, and the summary of what they are
    /// currently set to.
    ///
    /// It stays put in both modes rather than disappearing on the way in: it
    /// is the header of the section it opens, so the way back out is where
    /// the way in was, and the chevron says which of the two you are looking
    /// at. Its summary line keeps earning its place while the panel is open —
    /// the panel is a screenful of controls, and this stays one line of what
    /// they add up to.
    private var advancedSummary: some View {
        let isOpen = mode == .full
        return Button { mode = isOpen ? .simple : .full } label: {
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

    /// `SEED random · STEPS 8 · GUIDANCE 7` — built from whatever the model
    /// actually declares, capped so it stays one line.
    private var summaryText: String {
        let specs = formState.specs.filter { $0.isInternal != true }
        let interesting = specs.filter {
            $0.type == .int || $0.type == .float || $0.type == .enum || $0.type == .bool
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

    // MARK: generate

    private func generateRow(_ model: ModelInfo) -> some View {
        let missing = missingRequiredAudio(model)
        let needsWords = model.capabilities.needsLyrics
            && lyrics.trimmingCharacters(in: .whitespaces).isEmpty
        let emptyPrompt = prompt.trimmingCharacters(in: .whitespaces).isEmpty
        let blocked = emptyPrompt || missing != nil || needsWords
        return HStack(spacing: 16) {
            Button {
                submit(model)
            } label: {
                HStack(spacing: 10) {
                    BenchNavGlyph(kind: .generate, color: Bench.Palette.onAccent, size: 14)
                    Text(count > 1 ? "Generate \(count) takes" : "Generate")
                }
            }
            .buttonStyle(.benchPrimary)
            .disabled(blocked)
            .opacity(blocked ? 0.5 : 1)
            .keyboardShortcut(.return, modifiers: .command)

            VStack(alignment: .leading, spacing: 3) {
                Text(estimateText(model))
                    .font(Bench.Typo.mono(12))
                    .foregroundStyle(Bench.Palette.textQuaternary)
                if let missing {
                    // Said here rather than by the engine twenty seconds in:
                    // this model transforms audio it is given, and the form
                    // has not been given any.
                    Text("NEEDS \(missing.label.uppercased()) — PICK IT "
                         + "UNDER FULL CONTROL")
                        .font(Bench.Typo.mono(12))
                        .foregroundStyle(Bench.Palette.warn)
                } else if needsWords {
                    Text("NEEDS LYRICS — THIS MODEL SINGS, IT HAS NOTHING "
                         + "TO DO WITHOUT WORDS")
                        .font(Bench.Typo.mono(12))
                        .foregroundStyle(Bench.Palette.warn)
                } else {
                    Text("⌘↩ TO RUN")
                        .font(Bench.Typo.mono(12))
                        .foregroundStyle(Bench.Palette.textFaintest)
                }
            }
            Spacer()
        }
    }

    /// Audio the model cannot run without and the form has not been given —
    /// VampNet's source loop, vocals2music's vocal take. The engine would
    /// only refuse after loading the model; the button refuses first, and
    /// says why.
    private func missingRequiredAudio(_ model: ModelInfo) -> ParamSpec? {
        model.capabilities.params.first {
            ($0.type == .audio || $0.type == .midi) && !$0.nullable
                && $0.isInternal != true
                && formState.audioSelections[$0.key] == nil
        }
    }

    /// `≈ 15 S ON THIS MAC` — from the model's declared throughput, so it is a
    /// real claim about this machine's measured rate rather than a guess.
    private func estimateText(_ model: ModelInfo) -> String {
        let est = model.capabilities.estSecondsPerAudioSecond * durationS * Double(count)
        let time = est < 90 ? "≈ \(Int(est.rounded())) S"
                            : "≈ \(Int((est / 60).rounded())) MIN"
        return "\(time) ON THIS MAC"
    }

    // MARK: - Empty states

    /// An empty model list means "nothing installed" only once the catalog has
    /// actually arrived — before that, saying so would send a user who *does*
    /// have models to the Models tab for nothing.
    @ViewBuilder
    private var noModels: some View {
        switch catalog.readiness {
        case .ready:
            StudioEmptyState(
                title: "No models installed",
                message: "Download a model and it appears here.",
                actionTitle: "Open Models", action: onOpenModels)
        case .unavailable(let message):
            StudioEmptyState(title: "The engine isn't running",
                             message: message, tone: .danger)
        case .pending(let detail):
            StudioEmptyState(title: "Loading generative models…",
                             message: detail, showsSpinner: true)
        }
    }

    /// What an Actions card changed on the way in.
    private func noticeBar(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "sparkles")
                .font(Bench.Typo.mono(11))
                .foregroundStyle(Bench.Palette.accent)
            Text(text)
                .font(Bench.Typo.secondary)
                .foregroundStyle(Bench.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button {
                notice = nil
            } label: {
                Image(systemName: "xmark")
                    .font(Bench.Typo.mono(9, .semibold))
                    .foregroundStyle(Bench.Palette.textFaintest)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .benchCard(fill: Bench.Palette.accent.opacity(0.07),
                   stroke: Bench.Palette.accent.opacity(0.22))
    }

    // MARK: - State plumbing
    //
    // The ordering of these four hooks is load-bearing: setting
    // `selectedModelId` triggers `rebuildForm()`, which RECREATES `formState` —
    // which is why `pendingAudio` exists as a deferred slot, and why
    // `prefill.pending = nil` happens after the branch and not inside it.

    private func syncSelection() {
        if model == nil {
            selectedModelId = preferredModelId ?? installed.first?.id
        }
    }

    private var preferredModelId: String? {
        Self.preferredModelId(
            policy: settings.studioModelPolicy,
            lastUsed: settings.studioLastModelId,
            fixed: settings.studioFixedModelId,
            installed: installed.map {
                ($0.id, catalog.isFavourite($0.id))
            })
    }

    /// Settings' opening-model policy, resolved against what is actually
    /// installed. nil falls through to catalog order — which is also every
    /// policy's answer when its pick is missing (deleted, never set), rather
    /// than an empty composer.
    static func preferredModelId(
        policy: AppSettings.StudioModelPolicy, lastUsed: String?,
        fixed: String?, installed: [(id: String, isFavourite: Bool)]
    ) -> String? {
        switch policy {
        case .catalogOrder:
            nil
        case .lastUsed:
            installed.first { $0.id == lastUsed }?.id
        case .favourite:
            installed.first(where: \.isFavourite)?.id
        case .fixed:
            installed.first { $0.id == fixed }?.id
        }
    }

    private func applyPrefill() {
        guard let request = prefill.pending else { return }
        prompt = request.prompt
        lyrics = request.lyrics ?? ""
        pendingAudio = request.audioParams
        pendingParams = request.params
        notice = request.notice
        // Asked for, not imposed: `clampToModel` below reduces both to what
        // the chosen model actually allows, so a card wanting two minutes
        // lands on thirty seconds of MusicGen rather than on a length it
        // would refuse.
        pendingDurationS = request.durationS
        if let takes = request.takes { count = takes }
        if let modelId = request.modelId,
           installed.contains(where: { $0.id == modelId }),
           selectedModelId != modelId {
            selectedModelId = modelId   // onChange rebuilds the form
        } else {
            consumeArrivals()
        }
        prefill.pending = nil
    }

    private func rebuildForm() {
        guard let model else { return }
        formState = ParameterFormState(specs: model.capabilities.params)
        consumeArrivals()
    }

    /// Everything a prefill left waiting for the form it belongs to, in the
    /// order the values depend on each other: the length decides whether the
    /// unlock is needed, the clamp then holds both length and take count to
    /// what the model allows, and the params go into a form that exists.
    private func consumeArrivals() {
        consumePendingLength()
        clampToModel()
        // Params before audio: pouring a reuse resets the form first, which
        // would otherwise throw away the files the same prefill just landed.
        consumePendingParams()
        consumePendingAudio()
    }

    /// Length and take count are the user's until the model disagrees.
    ///
    /// The unlock is cleared here rather than carried across: it was granted
    /// against one model's ceiling, and a model that never offered one must
    /// not inherit it. Clearing before the clamp is what makes the length fall
    /// back inside the new model's own recommendation.
    private func clampToModel() {
        guard let model else { return }
        if !model.capabilities.duration.canUnlock { unlockLength = false }
        let dur = model.capabilities.duration
        durationS = min(max(durationS, dur.minS), effectiveMaxS(model))
        count = min(max(1, count), model.capabilities.outputsPerJobMax)
    }

    /// Whether this render is currently running past the model's own
    /// recommendation — the toggle being on is not enough, the model has to
    /// have somewhere to go.
    private func isUnlocked(_ model: ModelInfo) -> Bool {
        unlockLength && model.capabilities.duration.canUnlock
    }

    /// The length ceiling in force: the model's documented maximum, or the
    /// unlocked one when Full control has been used to ask for it.
    private func effectiveMaxS(_ model: ModelInfo) -> Double {
        model.capabilities.duration.maxS(unlocked: unlockLength)
    }

    /// Apply whichever prefilled audio params the current model declares.
    /// Unmatched keys stay pending — switching to a model that has the param
    /// still lands the file, exactly as the melody slot always behaved.
    private func consumePendingAudio() {
        guard !pendingAudio.isEmpty, let model else { return }
        for (key, url) in pendingAudio {
            if let spec = model.capabilities.params.first(
                where: { $0.type == .audio && $0.key == key }) {
                formState.audioSelections[spec.key] = url
                pendingAudio.removeValue(forKey: key)
            }
        }
    }

    /// Pour a reused take's parameter values into the rebuilt form.
    ///
    /// Dropped rather than held, unlike `pendingAudio`: a file is the user's
    /// material and belongs to whichever model can take it, but a number from
    /// another model's form has no meaning here — `guidance_scale 3` on a
    /// model whose range starts at 5 is not a setting anyone chose.
    ///
    /// Audio params are skipped even where the key matches. What the row
    /// stored for one is an engine upload id, and an upload does not outlive
    /// the job that used it; re-submitting the id would name nothing. The
    /// slot is left empty for the user to fill, which is visible, rather than
    /// filled with a reference that fails at submit.
    private func consumePendingParams() {
        guard !pendingParams.isEmpty, let model else { return }
        let arriving = pendingParams
        pendingParams = [:]
        // From the model's defaults, not from whatever the panel was left on.
        // The arriving dict is the whole submitted param bag, so anything it
        // does not name is something the reused take did NOT set — and a knob
        // the user had moved half an hour ago surviving into "reuse all" would
        // make it a different render, which is the one thing it must not be.
        // A no-op when the model changed, since that rebuilt the form already.
        formState.reset()
        for (key, value) in arriving {
            guard let spec = model.capabilities.params.first(
                where: { $0.key == key }), spec.isInternal != true,
                  spec.type != .audio, spec.type != .midi, spec.type != .json
            else { continue }
            switch value {
            case .int(let v): formState.setDouble(spec, Double(v))
            case .double(let v): formState.setDouble(spec, v)
            case .bool(let v): formState.setBool(spec, v)
            case .string(let v): formState.setString(spec, v)
            case .null: formState.setNull(spec)
            default: continue
            }
        }
    }

    /// Take a reused length, unlocking the slider first where the take was
    /// rendered past the model's own recommendation.
    ///
    /// Without the unlock `clampToModel` would pull the length back down and
    /// "reuse all" would quietly be a different render — the one failure this
    /// whole path exists to avoid. The unlock is only ever turned ON here: a
    /// shorter reuse leaves it where the user had it, and `clampToModel`
    /// clears it whenever the model cannot offer it at all.
    private func consumePendingLength() {
        guard let want = pendingDurationS, let model else { return }
        pendingDurationS = nil
        if want > model.capabilities.duration.maxS(unlocked: false),
           model.capabilities.duration.canUnlock {
            unlockLength = true
        }
        durationS = want
    }

    private func applyPreset(_ preset: StudioPreset) {
        formState.reset()
        for (key, value) in preset.values {
            guard let spec = formState.specs.first(where: { $0.key == key }) else { continue }
            switch value {
            case .int(let v): formState.setDouble(spec, Double(v))
            case .double(let v): formState.setDouble(spec, v)
            case .bool(let v): formState.setBool(spec, v)
            case .string(let v): formState.setString(spec, v)
            case .null: formState.setNull(spec)
            default: break
            }
        }
    }

    private func submit(_ model: ModelInfo) {
        let lyricsValue = model.capabilities.supportsLyrics
            && !lyrics.trimmingCharacters(in: .whitespaces).isEmpty ? lyrics : nil
        notice = nil
        // Recorded whatever the opening-model policy is, so switching to
        // "the one I last used" later has a history to read.
        settings.studioLastModelId = model.id
        Task {
            var params = formState.params
            // "Hold the seed": a seed field left on random borrows the last
            // take's. A seed the user typed is theirs and stays.
            if settings.holdSeed, let seed = jobs.lastSeedUsed,
               model.capabilities.params.contains(where: { $0.key == "seed" }),
               params["seed"] == nil || params["seed"] == .null {
                params["seed"] = .int(Int(seed))
            }
            for (key, url) in formState.audioSelections {
                guard let uploadId = await jobs.uploadAudio(fileURL: url) else {
                    return  // uploadAudio surfaced the error
                }
                params[key] = .string(uploadId)
            }
            await jobs.submit(modelId: model.id, prompt: prompt,
                              lyrics: lyricsValue, durationS: durationS,
                              count: count, params: params,
                              // Previews are a Settings opt-in, off by
                              // default: only some generative families can
                              // decode mid-render, so with them on the render
                              // card shows a live waveform for some models
                              // and not others (which is why the per-render
                              // control was removed). Gated on the model too:
                              // the engine 422-refuses a preview it cannot
                              // produce rather than silently ignoring it.
                              preview: settings.livePreview
                                  && model.capabilities.canPreview,
                              // A field still showing the default sends no
                              // name at all, so the number is allocated when
                              // the take lands. Pinning "track042" here would
                              // hand the same number to every job queued
                              // behind this one.
                              name: isDefaultName ? nil : effectiveName)
        }
    }
}

/// How many takes one Generate makes — the number, the arrows, and the model's
/// ceiling.
///
/// The number is drawn once. It used to be drawn twice: a large readout beside
/// a `BenchStepper`, which prints its own value, so the card read `1  1 ▲▼`.
struct StudioTakesCard: View {
    @Binding var count: Int
    let model: ModelInfo
    var width: CGFloat = 150

    private var maxTakes: Int { model.capabilities.outputsPerJobMax }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("Takes")
                .font(Bench.Typo.secondary)
                .foregroundStyle(Bench.Palette.textQuaternary)
            HStack {
                Text("\(count)")
                    .font(Bench.Typo.mono(22, .semibold))
                    .foregroundStyle(Bench.Palette.textPrimary)
                Spacer()
                BenchStepperArrows(
                    value: $count, range: 1...maxTakes,
                    limitNote: "\(model.displayName) makes at most "
                        + "\(maxTakes) takes in one go")
            }
            Spacer(minLength: 0)
            // The ceiling is the model's own, declared in the catalog. Stated
            // the way Length states its own, rather than left for you to find
            // by clicking an arrow that does nothing.
            Text("MAX \(maxTakes)")
                .font(Bench.Typo.mono(10))
                .foregroundStyle(Bench.Palette.textFaintest)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(width: width)
        .benchCard()
    }
}

// MARK: - Prompt editor

/// A borderless multi-line editor that looks like prose, not a form field.
/// `TextEditor` insists on its own background; it is stripped so the text sits
/// directly on the card.
struct StudioPromptEditor: View {
    @Binding var text: String
    var font: Font

    /// Where `TextEditor` puts its first glyph, relative to its own frame.
    /// Measured, not guessed: SwiftUI leaves `textContainerInset` at zero and
    /// the text container's `lineFragmentPadding` at its 5 pt default, so the
    /// first line starts 5 pt in and flush with the top.
    ///
    /// The placeholder has to land on exactly that spot, because the moment
    /// you type it is replaced by the real text — any difference reads as the
    /// prompt jumping. It was 8 pt low until this was measured, which is what
    /// `StudioPromptEditorTests` now pins by drawing both and comparing ink.
    static let firstGlyphOrigin = CGPoint(x: 5, y: 0)

    static let placeholder = "Describe the music you want…"

    var body: some View {
        TextEditor(text: $text)
            .tint(Bench.Palette.accent)
            .font(font)
            .lineSpacing(7)
            .scrollContentBackground(.hidden)
            .foregroundStyle(Bench.Palette.textPrimary)
            .frame(minHeight: 74)
            .fixedSize(horizontal: false, vertical: true)
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(Self.placeholder)
                        .font(font)
                        .lineSpacing(7)
                        .foregroundStyle(Bench.Palette.textFaint)
                        .padding(.leading, Self.firstGlyphOrigin.x)
                        .padding(.top, Self.firstGlyphOrigin.y)
                        .allowsHitTesting(false)
                }
            }
    }
}

/// The length control: a filled region over tick marks rather than a slider
/// knob, so it reads as a span of time.
struct DurationBar: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var height: CGFloat = 26

    var body: some View {
        GeometryReader { geo in
            let span = max(range.upperBound - range.lowerBound, 0.001)
            let fraction = ((value - range.lowerBound) / span).clamped(to: 0...1)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6).fill(Bench.Palette.windowBackground)
                HStack(spacing: 6) {
                    ForEach(0..<10, id: \.self) { index in
                        Rectangle()
                            .fill(Color.white.opacity(index % 3 == 0 ? 0.18 : 0.1))
                            .frame(width: 1, height: index % 3 == 0 ? 9 : 5)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(.horizontal, 4).padding(.bottom, 3)
                Rectangle()
                    .fill(Bench.Palette.accent.opacity(0.14))
                    .frame(width: geo.size.width * fraction)
                    .overlay(alignment: .trailing) {
                        Rectangle().fill(Bench.Palette.accent).frame(width: 2)
                    }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                let f = Double(drag.location.x / max(geo.size.width, 1)).clamped(to: 0...1)
                value = (range.lowerBound + f * span).clamped(to: range)
            })
        }
        .frame(height: height)
    }
}

// MARK: - Empty state

struct StudioEmptyState: View {
    let title: String
    var message: String = ""
    var tone: Tone = .neutral
    var showsSpinner = false
    var actionTitle: String?
    var action: (() -> Void)?

    enum Tone { case neutral, danger }

    var body: some View {
        VStack(spacing: 12) {
            if showsSpinner {
                BenchSpinner(size: 26, lineWidth: 2.5)
            } else {
                Image(systemName: tone == .danger ? "exclamationmark.triangle"
                                                  : "square.and.arrow.down")
                    .font(.system(size: 26))
                    .foregroundStyle(tone == .danger ? Bench.Palette.danger
                                                     : Bench.Palette.textFaint)
            }
            Text(title)
                .font(Bench.Typo.sectionTitle)
                .foregroundStyle(Bench.Palette.textPrimary)
            if !message.isEmpty {
                Text(message)
                    .font(Bench.Typo.secondary)
                    .foregroundStyle(Bench.Palette.textQuaternary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.benchPrimaryCompact)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

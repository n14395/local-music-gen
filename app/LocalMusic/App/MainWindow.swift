import SwiftUI

/// The Bench shell: a 230 pt sidebar, a content column that supplies its own
/// top bar, and a transport bar spanning the full width beneath both.
///
/// The window uses `.hiddenTitleBar`, so the traffic lights float over the
/// sidebar's 52 pt header exactly as the design draws them, and there is no
/// system toolbar at all — every screen draws its own.
struct MainWindow: View {
    let env: AppEnvironment

    @State private var destination: Destination = .studio
    @State private var libraryScope: LibraryScope = .songs
    /// Live navigation inside Actions: nil is the gallery, non-nil is the
    /// configuration page currently open. Held by the shell so a jump from
    /// another screen lands on a configured page, and so leaving Actions and
    /// coming back keeps your place.
    @State private var actionsRoute: ActionsScreen.Route?
    /// One-off notes from reopening a finished mix — recovered tempo, missing
    /// parts, settings that were never recorded. Owned here because both
    /// Actions (which can hand the bench a fresh arrangement) and Workbench
    /// (which displays them) need to reach them.
    @State private var workbenchNotices: [String] = []
    /// A/B comparison of two library rows. It lives in the shell rather than
    /// in the Library because the transport bar — which is where you switch
    /// sides — sits outside the screen.
    @State private var libraryCompare = LibraryCompare()
    /// What a gated feature sent the user to Models to find, so the list there
    /// can narrow to the models that would ungate it. Held by the shell
    /// because it is set on one screen and read on another.
    @State private var modelRequirement: ModelRequirement?
    /// Which build of the first-run flow this user has been through. Versioned
    /// rather than a bool so a later change to the recommended set can offer
    /// itself once more without a defaults migration.
    @AppStorage("onboarding.completedVersion") private var onboardingVersion = 0
    @State private var showOnboarding = false

    /// Bump when the recommended set changes enough to be worth re-offering.
    private static let onboardingVersionCurrent = 1

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Bench.Palette.windowBackground)
            }
            .frame(maxHeight: .infinity)
            TransportBar(playback: env.playback, slot: transportSlot,
                         onToggleCompare: {
                             libraryCompare.toggle(playback: env.playback)
                         })
        }
        .background(Bench.Palette.windowBackground)
        .preferredColorScheme(.dark)
        .frame(minWidth: 1100, minHeight: 700)
        .onChange(of: env.studio.pending) { routeIntent() }
        .onChange(of: env.prefill.pending) { if env.prefill.pending != nil {
            destination = .studio
        } }
        .task { await env.pollTelemetry() }
        .onAppear(perform: offerOnboarding)
        .onChange(of: env.catalog.hasLoaded) { offerOnboarding() }
        // Stamped on the way *out* rather than by the sheet's own buttons, so
        // every route closes it for good — including an Escape press, which
        // would otherwise bring the welcome back on every launch.
        .sheet(isPresented: Binding(get: { showOnboarding },
                                    set: { open in
                                        showOnboarding = open
                                        if !open {
                                            onboardingVersion = Self.onboardingVersionCurrent
                                        }
                                    })) {
            OnboardingView(catalog: env.catalog,
                           downloads: env.downloadsStore,
                           freeDiskBytes: env.telemetry.freeDiskBytes) {
                showOnboarding = false
            }
        }
    }

    /// Show the first-run sheet once, and only when there is something to say:
    /// an install that already has every recommended model gets no welcome.
    private func offerOnboarding() {
        guard onboardingVersion < Self.onboardingVersionCurrent,
              !showOnboarding,
              env.catalog.hasLoaded else { return }
        let plan = OnboardingPlan.make(models: env.catalog.models,
                                       physicalRAM: ModelCatalogStore.physicalRAM)
        guard !plan.isEmpty else {
            onboardingVersion = Self.onboardingVersionCurrent
            return
        }
        showOnboarding = true
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            // Reserved for the traffic lights, which the system draws over the
            // top-left of the window content.
            Color.clear.frame(height: Bench.Metrics.topBarHeight)

            VStack(spacing: 2) {
                ForEach(Destination.Section.allCases, id: \.self) { section in
                    BenchSidebarHeading(text: section.rawValue,
                                        topPadding: section == .make ? 14 : 18)
                    ForEach(Destination.inSection(section)) { item in
                        BenchSidebarRow(destination: item,
                                        title: item.title,
                                        glyph: glyph(for: item),
                                        count: count(for: item),
                                        isBusy: isBusy(item),
                                        selection: $destination)
                        // The Library's scopes live under it rather than in the
                        // screen, and stay open from every destination: they
                        // are five places you can go, and a list that only
                        // appears once you are already there cannot take you
                        // anywhere. Picking one from elsewhere goes to the
                        // Library rather than quietly re-aiming a screen you
                        // are not looking at — which is also why none of them
                        // reads as selected until you are on it.
                        if item == .library {
                            ForEach(LibraryScope.allCases) { scope in
                                BenchSidebarSubRow(
                                    scope: scope, title: scope.title,
                                    symbol: scope.symbol,
                                    showsSelection: destination == .library,
                                    selection: Binding(
                                        get: { libraryScope },
                                        set: {
                                            libraryScope = $0
                                            destination = .library
                                        }))
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 10).padding(.top, 4)

            Spacer(minLength: 0)
            SidebarFooterCard(env: env, destination: destination,
                              libraryScope: libraryScope)
        }
        .frame(width: Bench.Metrics.sidebarWidth)
        .frame(maxHeight: .infinity)
        .background(Bench.Palette.sidebar)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Bench.Palette.hairline).frame(width: 1)
        }
    }

    private func glyph(for destination: Destination) -> BenchNavGlyph.Kind {
        switch destination {
        case .studio: .studio
        case .styleTransfer: .styleTransfer
        case .actions: .actions
        case .workbench: .workbench
        case .library: .library
        case .models: .models
        }
    }

    private func count(for destination: Destination) -> String? {
        switch destination {
        case .library:
            // How many rows the Library is showing right now — so it tracks
            // the scope switch and any active filter rather than claiming a
            // fixed size the list may not be displaying.
            let total: Int
            switch libraryScope {
            case .parts: total = env.partsStore.results.count
            // Favourites is one view over two tables, so its count is both.
            case .favourites: total = env.library.results.count
                + env.partsStore.favorites().count
            case .songs, .imported, .renders: total = env.library.results.count
            }
            return total > 0 ? "\(total)" : nil
        case .models:
            let installed = env.catalog.models.filter { $0.installState == .installed }
            guard !env.catalog.models.isEmpty else { return nil }
            return "\(installed.count)/\(env.catalog.models.count)"
        case .workbench:
            let clips = env.workbench.clips.count
            return clips > 0 ? "\(clips)" : nil
        default:
            return nil
        }
    }

    /// A spinner on the destination that owns the running work, so leaving a
    /// screen mid-job does not hide that the job is still going.
    private var styleTransferJobs: Set<String> {
        env.styleTransfer.outstandingJobIds
    }

    private func isBusy(_ destination: Destination) -> Bool {
        switch destination {
        case .studio:
            return env.jobsStore.active.values.contains {
                !$0.status.isTerminal && $0.info.task == nil
                    && !styleTransferJobs.contains($0.info.jobId)
            }
        case .actions:
            return env.jobsStore.active.values.contains {
                !$0.status.isTerminal && $0.info.task != nil
                    && !styleTransferJobs.contains($0.info.jobId)
            }
        case .styleTransfer:
            // Style Transfer's jobs are ordinary generate/separate/mix jobs, so
            // neither arm above can tell them apart by shape — the workspace
            // reports the ids it started instead, and the other two subtract
            // them so one job never spins two destinations.
            return env.styleTransfer.isWaitingOnWork
        case .models:
            return !env.downloadsStore.downloads.isEmpty
        default:
            return false
        }
    }

    // MARK: - Transport slot

    /// Exactly one thing at a time, in priority order: an active download beats
    /// the queue, because a download is the slower and less visible of the two.
    private var transportSlot: TransportBar.Slot {
        // Comparing two takes is the one thing you are doing *with* the
        // transport, so it outranks the background work readouts.
        if destination == .library, libraryCompare.isActive {
            return .compare(isB: libraryCompare.isB)
        }
        let downloading = env.downloadsStore.downloads.values
            .filter { $0.state == .downloading }
        if let download = downloading.first, download.bytesTotal > 0 {
            let percent = Int(Double(download.bytesDone)
                              / Double(download.bytesTotal) * 100)
            return .download(percent: percent)
        }
        // Takes, not jobs: one submission of four takes is four tracks being
        // made, and reading "QUEUE 1" beside it was the counter disagreeing
        // with the number the user typed.
        let load = QueueLoad.of(jobs: Array(env.jobsStore.active.values))
        return load.jobs == 0 ? .idle : .queue(count: load.takesLeft)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch destination {
        case .studio:
            StudioView(catalog: env.catalog, jobs: env.jobsStore,
                       downloads: env.downloadsStore, library: env.library,
                       playback: env.playback, prefill: env.prefill,
                       backend: env.backendStatus, actions: songActions,
                       onOpenModels: { openModels(for: nil) })
        case .library:
            LibraryScreen(library: env.library, parts: env.partsStore,
                          jobs: env.jobsStore, playback: env.playback,
                          scope: $libraryScope, actions: songActions,
                          onAddToWorkbench: { part in
                              env.studio.pending = .addToWorkbench(partId: part.id)
                          },
                          onRenderNotes: renderNotesAction,
                          onUseMelody: { useMelody($0) },
                          onFindMatches: { materialId in
                              env.studio.pending = .findMatches(materialId: materialId)
                          },
                          compare: libraryCompare)
        case .styleTransfer:
            StyleTransferScreen(model: env.styleTransfer, catalog: env.catalog,
                                library: env.library, parts: env.partsStore,
                                jobs: env.jobsStore, playback: env.playback,
                                onOpenModels: { openModels(for: $0) })
        case .actions:
            ActionsScreen(
                catalog: env.catalog, library: env.library,
                parts: env.partsStore, jobs: env.jobsStore,
                playback: env.playback, workbench: env.workbench,
                route: $actionsRoute,
                onOpenModels: { openModels(for: $0) },
                onOpenWorkbench: { notes in
                    workbenchNotices = notes
                    destination = .workbench
                },
                onOpenStyleTransfer: { preset, sourceId in
                    openStyleTransfer(preset: preset, sourceId: sourceId)
                })
        case .workbench:
            WorkbenchScreen(model: env.workbench, catalog: env.catalog,
                            library: env.library, parts: env.partsStore,
                            jobs: env.jobsStore, playback: env.playback,
                            notices: $workbenchNotices,
                            onOpenModels: { openModels(for: nil) },
                            onOpenStyleTransfer: { preset, sourceId in
                                openStyleTransfer(preset: preset,
                                                  sourceId: sourceId)
                            })
        case .models:
            ModelsScreen(catalog: env.catalog, downloads: env.downloadsStore,
                         backend: env.backendStatus, telemetry: env.telemetry,
                         requirement: $modelRequirement)
        }
    }

    /// Go to Models, carrying what was missing. Always assigned — including
    /// `nil` — so an errand from one screen cannot leave its filter behind for
    /// the next visit from another.
    private func openModels(for requirement: ModelRequirement?) {
        modelRequirement = requirement
        destination = .models
    }

    // MARK: - Intents

    /// Wired once and handed to every screen, so a track offers the same jumps
    /// wherever it is opened from.
    private var songActions: SongActions {
        SongActions(
            reusePrompt: { song in
                env.prefill.pending = .init(prompt: song.prompt,
                                            lyrics: song.lyrics,
                                            modelId: song.modelId)
                destination = .studio
            },
            split: { song in
                env.studio.pending = .split(songId: song.id)
            },
            findMatches: { song in
                env.studio.pending = .findMatches(materialId: song.id)
            },
            openMix: { song in
                env.studio.pending = .openMix(songId: song.id)
            },
            restyle: { song in
                env.studio.pending = .styleTransfer(materialId: song.id,
                                                    presetId: nil)
            })
    }

    /// Intents arrive as a mailbox write from any screen. With Split &
    /// Recombine dissolved, there is no longer a second-level screen to hand
    /// them to, so the shell both routes *and* consumes them — and must clear
    /// the mailbox, which the old consumer did.
    private func routeIntent() {
        guard let intent = env.studio.pending else { return }
        switch intent {
        case .split(let songId):
            actionsRoute = .action(recipeId: "split-instruments", sourceId: songId)
            destination = .actions
        case .findMatches(let materialId):
            actionsRoute = .action(recipeId: "what-mashes", sourceId: materialId)
            destination = .actions
        case .addToWorkbench(let partId):
            if let material = material(id: partId) {
                env.workbench.add(material: material, parts: env.partsStore)
            }
            destination = .workbench
        case .openMix(let songId):
            workbenchNotices = env.workbench.load(songId: songId,
                                                  parts: env.partsStore,
                                                  library: env.library)
            destination = .workbench
        case .styleTransfer(let materialId, let presetId):
            openStyleTransfer(
                preset: presetId.flatMap(StylePreset.preset(forRecipeId:)),
                sourceId: materialId)
        }
        env.studio.pending = nil
    }

    /// "Render…" on a MIDI part, available only while a SoundFont renderer is
    /// installed. Returning nil is a supported state, not a stub: the Library
    /// dims the control and says what is missing rather than hiding it.
    private var renderNotesAction: ((PartRecord) -> Void)? {
        guard let renderer = env.catalog.models.first(where: {
            $0.installState == .installed
                && $0.capabilities.supportedTasks.contains("render")
        }) else { return nil }
        return { part in
            let title = ((try? env.library.repository.song(id: part.songId)) ?? nil)?
                .title ?? part.modelName
            Task {
                await env.jobsStore.submitRender(modelId: renderer.id, part: part,
                                                 sourceTitle: title)
            }
        }
    }

    /// An id from an intent may name either a part or a whole song — the
    /// Library's "add to bench" and a part row both write to the same mailbox.
    private func material(id: String) -> PickedMaterial? {
        if let part = ((try? env.partsStore.repository.part(id: id)) ?? nil) {
            let title = ((try? env.library.repository.song(id: part.songId)) ?? nil)?
                .title ?? part.modelName
            return PickedMaterial(part: part, sourceTitle: title)
        }
        if let song = ((try? env.library.repository.song(id: id)) ?? nil) {
            return PickedMaterial(song: song)
        }
        return nil
    }

    /// Take the shell to the Style Transfer workspace, seeding it from a
    /// preset and/or a source.
    ///
    /// Seeding *offers* rather than applies when the workspace already holds a
    /// configuration: an Actions card that silently discards ten minutes of
    /// setup is worse than one that does nothing, and the whole reason this is
    /// a destination is that its state is worth keeping.
    private func openStyleTransfer(preset: StylePreset?, sourceId: String?) {
        let material = sourceId.flatMap { material(id: $0) }
        if let preset {
            env.styleTransfer.seed(
                preset: preset,
                presetName: StylePreset.recipe(for: preset)?.name,
                source: material, models: env.catalog.models)
        } else if let material {
            env.styleTransfer.setSource(material)
        }
        destination = .styleTransfer
    }

    private func useMelody(_ melodyURL: URL) {
        let melodyModel = env.catalog.models.first {
            $0.installState == .installed
                && $0.capabilities.supportedTasks.contains("generate")
                && $0.capabilities.params.contains {
                    $0.type == .audio && $0.key == "melody_audio"
                }
        }
        env.prefill.pending = .init(prompt: "", lyrics: nil,
                                    modelId: melodyModel?.id ?? "",
                                    melodyAudio: melodyURL)
        destination = .studio
    }
}

/// Which slice of the library is on screen. Lives here rather than inside the
/// library view because the sidebar card changes with it — Parts swaps the
/// engine readout for the stem-colour legend.
enum LibraryScope: String, CaseIterable, Identifiable, Codable {
    // Declaration order is sidebar order: the two kinds of whole track first,
    // then their parts, then what was built from them.
    case songs, imported, parts, renders, favourites
    var id: String { rawValue }
    var title: String {
        switch self {
        // "Songs" while imports had nowhere else to go; now that they do, the
        // distinction has to be on the label rather than implied by absence.
        case .songs: "Generated Songs"
        case .imported: "Imported"
        case .parts: "Parts"
        case .renders: "Renders"
        case .favourites: "Favourites"
        }
    }

    /// The slice of the `song` table this scope reads, or nil for the scopes
    /// that aren't a single origin (Parts comes from another table; Favourites
    /// spans everything).
    var origin: SongOrigin? {
        switch self {
        case .songs: .generated
        case .imported: .imported
        case .renders: .recombined
        case .parts, .favourites: nil
        }
    }

    /// The mark drawn to the left of the title. Every scope has one, so they
    /// read as a set you can pick from by shape — a heart on its own with four
    /// bare words beside it looks like a status on one row rather than one of
    /// five places to go.
    ///
    /// Chosen to differ in silhouette as well as in meaning, because at 11 pt
    /// that is all you get: a note, a tray, a divided rectangle, a wave, a
    /// heart. Imported deliberately does *not* reuse the download arrow the
    /// model catalogue uses — bringing a file in from your disk is not the same
    /// act as fetching a model, and the sidebar should not imply it is.
    var symbol: String {
        switch self {
        case .songs: "music.note"
        case .imported: "tray.and.arrow.down"
        case .parts: "rectangle.split.3x1"
        case .renders: "waveform"
        case .favourites: "heart.fill"
        }
    }
}

// MARK: - Sidebar footer

/// The contextual card at the bottom of the sidebar. Same rectangle on every
/// screen, different contents: whatever you need while you are *there*.
private struct SidebarFooterCard: View {
    let env: AppEnvironment
    let destination: Destination
    let libraryScope: LibraryScope

    /// Shared with `ModelsScreen`, so the storage card can point the list at
    /// what is on disk.
    @AppStorage("models.onlyInstalled") private var onlyInstalled = false

    var body: some View {
        switch destination {
        case .studio, .library where libraryScope != .parts:
            engineCard
        case .library:
            stemColoursCard
        case .actions, .styleTransfer:
            legendCard
        case .workbench:
            partsDrawerCard
        case .models:
            storageCard
        }
    }

    // MARK: engine

    private var isRendering: Bool {
        env.jobsStore.active.values.contains { !$0.status.isTerminal }
    }

    private var engineCard: some View {
        BenchSidebarCard(stroke: isRendering ? Bench.Palette.accent.opacity(0.2)
                                             : Bench.Palette.hairline) {
            HStack(spacing: 8) {
                StatusDot(color: statusColor)
                Text(isRendering ? "Rendering" : env.backendStatus.phase.label)
                    .font(Bench.Typo.secondaryEmphasis)
                    .foregroundStyle(Bench.Palette.textPrimary)
            }
            if let detail = engineDetail {
                Text(detail)
                    .font(Bench.Typo.mono(11))
                    .lineSpacing(3)
                    .foregroundStyle(Bench.Palette.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let fraction = env.telemetry.memoryFraction {
                BenchProgressBar(fraction: fraction,
                                 tint: isRendering ? Bench.Palette.accent
                                                   : Bench.Palette.ok)
            }
        }
    }

    private var statusColor: Color {
        if isRendering { return Bench.Palette.accent }
        switch env.backendStatus.phase {
        case .ready: return env.backendStatus.eventStreamConnected
            ? Bench.Palette.ok : Bench.Palette.warn
        case .launching, .restarting: return Bench.Palette.warn
        case .degraded: return Bench.Palette.warn
        case .failed: return Bench.Palette.danger
        case .stopped: return Bench.Palette.textMuted
        }
    }

    /// Two mono lines: what is loaded, and what it is costing. Either may be
    /// absent — an engine that reports no telemetry simply gets one line.
    private var engineDetail: String? {
        var lines: [String] = []
        if let modelId = env.backendStatus.workerModelId {
            let name = env.catalog.models.first { $0.id == modelId }?.displayName
                ?? modelId
            lines.append(env.backendStatus.workerModelState == "loading"
                         ? "\(name) loading…" : "\(name) loaded")
        }
        if let usage = isRendering ? env.telemetry.busyLine : env.telemetry.memoryLine {
            lines.append(usage)
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    // MARK: legend

    private var legendCard: some View {
        BenchSidebarCard {
            Text("LEGEND").eyebrow()
            legendRow(Bench.Palette.accent, "Exact — your audio, DSP only")
            legendRow(Bench.Palette.violet, "Reimagine — a model rewrites it")
            legendRow(Bench.Palette.cyan, "Analyse — measures, no audio out")
        }
    }

    private func legendRow(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 7, height: 7)
            Text(text)
                .font(Bench.Typo.caption)
                .foregroundStyle(Bench.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: stem colours

    private var stemColoursCard: some View {
        BenchSidebarCard {
            Text("STEM COLOURS").eyebrow()
            BenchFlow(spacing: 5) {
                ForEach(["vocals", "drums", "bass", "other"], id: \.self) { kind in
                    Text(kind)
                        .font(.system(size: 10))
                        .foregroundStyle(Bench.Palette.stem(kind))
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 5)
                            .fill(Bench.Palette.stem(kind).opacity(0.12)))
                }
            }
        }
    }

    // MARK: parts drawer

    private var partsDrawerCard: some View {
        BenchSidebarCard {
            HStack(spacing: 8) {
                Text("PARTS DRAWER").eyebrow()
                Spacer()
            }
            let recent = Array(env.partsStore.results.prefix(3))
            if recent.isEmpty {
                Text("Split a song into instruments and its parts appear here.")
                    .font(Bench.Typo.micro)
                    .foregroundStyle(Bench.Palette.textFaintest)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(recent, id: \.id) { part in
                    HStack(spacing: 9) {
                        StemBar(kind: part.kind)
                        Text(part.name)
                            .font(Bench.Typo.secondary)
                            .foregroundStyle(Bench.Palette.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if let bpm = env.partsStore.analysis(for: part.id)?.bpm {
                            Text("\(Int(bpm.rounded()))")
                                .font(Bench.Typo.mono(10))
                                .foregroundStyle(Bench.Palette.textMuted)
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 9)
                        .fill(Bench.Palette.statusCard))
                    .overlay(RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(Bench.Palette.hairline, lineWidth: 1))
                    // The bench accepts a bare `String` id — see
                    // `WorkbenchScreen.drop(ids:atBeats:)` for why the payload
                    // is not a custom `Transferable`.
                    .draggable(part.id)
                }
                Text("Drag a part onto the bench, or hold ⌥ to drop it at the "
                     + "playhead.")
                    .font(Bench.Typo.micro)
                    .lineSpacing(2)
                    .foregroundStyle(Bench.Palette.textFaintest)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: storage

    private var storageCard: some View {
        BenchSidebarCard {
            Text("STORAGE").eyebrow()
            Text(TelemetryStore.gigabytes(modelBytes + audioBytes) + " GB")
                .font(Bench.Typo.valueLarge)
                .foregroundStyle(Bench.Palette.textPrimary)
            BenchSplitBar(segments: [
                (fraction: share(modelBytes), color: Bench.Palette.accent),
                (fraction: share(audioBytes), color: Bench.Palette.violet),
            ])
            Text(storageDetail)
                .font(Bench.Typo.mono(10))
                .lineSpacing(3)
                .foregroundStyle(Bench.Palette.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            // Narrows the list to what is actually on disk, which is the
            // question you are asking when you click it. The deleting itself
            // stays on the rows, where the size and the licence are.
            Button("Free up space…") { onlyInstalled = true }
                .buttonStyle(.bench(.quiet))
                .frame(maxWidth: .infinity)
                .help("Show only the models taking up space")
        }
    }

    private var installedModels: [ModelInfo] {
        env.catalog.models.filter { $0.installState == .installed }
    }

    private var modelBytes: Int64 {
        installedModels.reduce(0) { $0 + $1.installedBytes }
    }

    private var audioBytes: Int64 { env.storage.audioBytes }

    /// Against total occupied + free, so the bar reads as "of this disk".
    private func share(_ bytes: Int64) -> Double {
        let free = env.telemetry.freeDiskBytes ?? 0
        let total = modelBytes + audioBytes + free
        guard total > 0 else { return 0 }
        return Double(bytes) / Double(total)
    }

    private var storageDetail: String {
        var line = "\(installedModels.count) MODEL"
            + (installedModels.count == 1 ? "" : "S")
        line += " · \(TelemetryStore.gigabytes(audioBytes)) GB AUDIO"
        if let free = env.telemetry.freeDiskBytes {
            line += "\n\(TelemetryStore.gigabytes(free)) GB FREE"
        }
        return line
    }
}

/// Minimal wrapping row used by the sidebar legends. `FlowLayout` already
/// exists for the tag fields; this is the two-line version without its
/// alignment machinery.
private struct BenchFlow<Content: View>: View {
    var spacing: CGFloat = 6
    @ViewBuilder var content: () -> Content

    var body: some View {
        FlowLayout(spacing: spacing) { content() }
    }
}

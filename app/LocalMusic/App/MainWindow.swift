import AppKit
import SwiftUI

/// The Bench shell: a 230 pt sidebar, a content column that supplies its own
/// top bar, and a transport bar spanning the full width beneath both.
///
/// The window uses `.hiddenTitleBar` and the shell ignores the top safe area,
/// so the whole thing starts at the top edge: the traffic lights float over
/// the sidebar's 52 pt header exactly as the design draws them, each screen's
/// top bar is level with them, and there is no system toolbar at all — every
/// screen draws its own.
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
    /// A track the user asked to revert, held until they confirm.
    @State private var pendingRevert: SongRecord?
    /// Set when a revert could not run because a render was in flight —
    /// a confirmed destructive action must never appear to do nothing.
    @State private var revertBlocked: String?
    /// What a gated feature sent the user to Models to find, so the list there
    /// can narrow to the models that would ungate it. Held by the shell
    /// because it is set on one screen and read on another.
    @State private var modelRequirement: ModelRequirement?
    /// Which build of the first-run flow this user has been through. Versioned
    /// rather than a bool so a later change to the recommended set can offer
    /// itself once more without a defaults migration.
    @AppStorage("onboarding.completedVersion") private var onboardingVersion = 0
    @State private var showOnboarding = false
    /// The queue panel, and the rule for when it shows itself. Shell state
    /// rather than a screen's, because the point of the change is that the
    /// queue is the same queue from everywhere.
    @State private var queuePanel = QueuePanel()
    /// Whether the queue panel holds a column of its own instead of floating
    /// over the screen. Stored, unlike `queuePanel`: where you want the queue
    /// to sit is a way of working — a wide display can afford it permanently,
    /// a laptop cannot — and re-pinning it every launch would be a chore.
    @AppStorage("queue.pinned") private var queuePinned = false

    /// Bump when the recommended set changes enough to be worth re-offering.
    private static let onboardingVersionCurrent = 1

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Bench.Palette.windowBackground)
                    // A focus ring is not drawn in z-order with everything
                    // else: SwiftUI composites it above neighbouring views, so
                    // the blue ring on whatever the keyboard is on — the
                    // Simple/Full control switch, on a fresh launch — draws
                    // straight through a floating panel sitting over it.
                    // Nothing the panel covers may draw one, then. Pinned, it
                    // covers nothing, so they come back.
                    //
                    // Applied under the overlay rather than over it: an
                    // overlay's content is not a descendant of the modifiers
                    // beneath it in the chain, so the panel keeps its own
                    // focus rings while the screen behind it loses them.
                    .focusEffectDisabled(queueFloats)
                    // Pinning is this padding and nothing else. The panel is
                    // one view in one place either way — the gutter decides
                    // whether the screen ends before it or runs underneath it,
                    // so pinning animates a single number instead of moving a
                    // rail between two branches of the layout.
                    .padding(.trailing, queueGutter)
                    .overlay(alignment: .trailing) { queueOverlay }
            }
            .frame(maxHeight: .infinity)
            TransportBar(playback: env.playback, slot: transportSlot,
                         queue: transportQueue,
                         engine: env.engineStatus,
                         editor: destination == .editor ? env.editor : nil,
                         isQueueOpen: queuePanel.isOpen,
                         onToggleQueue: {
                             withAnimation(Self.panelMotion) { queuePanel.toggle() }
                         },
                         onToggleCompare: {
                             libraryCompare.toggle(playback: env.playback)
                         })
        }
        .background(Bench.Palette.windowBackground)
        // `.hiddenTitleBar` gives the window a full-size content view but
        // SwiftUI still keeps a 32 pt safe area where the titlebar would be,
        // so every screen's own 52 pt bar was drawing *below* the traffic
        // lights with an empty band above it. The design has one bar per
        // screen and the lights floating over the sidebar's reserved header,
        // which is what this restores — and it hands 32 pt of window height
        // back to the screen.
        //
        // Safe to draw into: the titlebar's own widgets still win hit-testing
        // where they are, and everything else in that band reaches the content.
        .ignoresSafeArea(.container, edges: .top)
        .preferredColorScheme(.dark)
        // The floor rises with the pinned rail rather than letting it eat the
        // screen behind it: 1100 is already fully spent by Studio in Full
        // control (230 pt of sidebar, a 576 pt parameter panel).
        .frame(minWidth: Self.windowMinWidth + queueGutter, minHeight: 700)
        .onChange(of: env.studio.pending) { routeIntent() }
        .onChange(of: env.prefill.pending) { if env.prefill.pending != nil {
            destination = .studio
        } }
        .onChange(of: isRenderingWork) {
            withAnimation(Self.panelMotion) {
                queuePanel.workChanged(isWorking: isRenderingWork)
            }
        }
        .task { await env.pollTelemetry() }
        .onAppear {
            offerOnboarding()
            wireEditorRouting()
        }
        .confirmationDialog(
            "Revert “\(pendingRevert?.title ?? "")” to the original?",
            isPresented: Binding(get: { pendingRevert != nil },
                                 set: { if !$0 { pendingRevert = nil } })) {
            Button("Revert — discard the edits", role: .destructive) {
                if let song = pendingRevert { revert(song) }
                pendingRevert = nil
            }
        } message: {
            Text("The file goes back to the untouched original and the edit "
                 + "list is cleared. This cannot be undone.")
        }
        .alert("Still rendering",
               isPresented: Binding(get: { revertBlocked != nil },
                                    set: { if !$0 { revertBlocked = nil } })) {
            Button("OK") { revertBlocked = nil }
        } message: {
            Text("“\(revertBlocked ?? "")” is being rendered. Reverting has "
                 + "to wait for it to finish.")
        }
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
                           backend: env.backendStatus,
                           freeDiskBytes: env.telemetry.freeDiskBytes) {
                showOnboarding = false
            }
        }
    }

    /// Show the first-run sheet once, and only when there is something to say:
    /// an install that already has every recommended model gets no welcome.
    ///
    /// Deliberately opened *before* the catalog arrives. A genuine first launch
    /// spends tens of seconds inside the engine shim fetching a Python runtime
    /// and building the supervisor's venv, and this used to wait it out — so
    /// the slowest minute of the app's life was spent behind a fully-drawn
    /// window claiming nothing was installed, with the welcome appearing only
    /// once it was over. The sheet carries that wait now, and explains it.
    private func offerOnboarding() {
        guard onboardingVersion < Self.onboardingVersionCurrent,
              !showOnboarding else { return }
        // Only a never-onboarded install opens early. A *re-onboarding* — the
        // version stamp moving in a later release — belongs to someone whose
        // engine is already provisioned and whose catalog lands in under a
        // second, and flashing a welcome at them to conclude "everything
        // recommended is here" is worse than the second's wait.
        guard env.catalog.hasLoaded else {
            if onboardingVersion == 0 { showOnboarding = true }
            return
        }
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
                                    count: subRowCount(scope),
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

    /// The one scope whose size is what it is for: how many tracks carry
    /// applied edits. The others are read by name.
    private func subRowCount(_ scope: LibraryScope) -> String? {
        guard scope == .edited else { return nil }
        let count = (try? env.library.repository.editedCount()) ?? 0
        return count > 0 ? "\(count)" : nil
    }

    private func glyph(for destination: Destination) -> BenchNavGlyph.Kind {
        switch destination {
        case .studio: .studio
        case .styleTransfer: .styleTransfer
        case .actions: .actions
        case .workbench: .workbench
        case .editor: .editor
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
            case .songs, .imported, .renders, .edited:
                total = env.library.results.count
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
            // Task jobs, minus the two destinations that own their own:
            // Style Transfer reports the ids it started, and an Editor
            // render is a `mix` job that belongs to the Editor row.
            return env.jobsStore.active.values.contains {
                !$0.status.isTerminal && $0.info.task != nil
                    && !styleTransferJobs.contains($0.info.jobId)
                    && !env.jobsStore.isEditorJob($0.info.jobId)
            }
        case .styleTransfer:
            // Style Transfer's jobs are ordinary generate/separate/mix jobs, so
            // neither arm above can tell them apart by shape — the workspace
            // reports the ids it started instead, and the other two subtract
            // them so one job never spins two destinations.
            return env.styleTransfer.isWaitingOnWork
        case .models:
            return !env.downloadsStore.downloads.isEmpty
        case .editor:
            return env.editor.applyStage.isBusy
        default:
            return false
        }
    }

    // MARK: - Transport corner

    /// What the transport has to say *besides* the queue, which is always
    /// drawn. Comparing two takes is the one thing you do with the transport
    /// itself, so it is what earns the space beside the readout.
    private var transportSlot: TransportBar.Slot {
        if destination == .library, libraryCompare.isActive {
            return .compare(isB: libraryCompare.isB)
        }
        return .none
    }

    /// A transfer beats a render in the capsule, because a download is the
    /// slower and less visible of the two — both are in the panel it opens, so
    /// the one that loses here is not hidden, only unmentioned.
    private var transportQueue: TransportBar.Queue {
        let downloading = env.downloadsStore.downloads.values
            .filter { $0.state == .downloading }
        if let download = downloading.first, download.bytesTotal > 0 {
            let percent = Int(Double(download.bytesDone)
                              / Double(download.bytesTotal) * 100)
            return .downloading(percent: percent)
        }
        // Takes, not jobs: one submission of four takes is four tracks being
        // made, and reading "QUEUE 1" beside it was the counter disagreeing
        // with the number the user typed.
        let load = QueueLoad.of(jobs: Array(env.jobsStore.active.values))
        if load.jobs > 0 { return .working(takes: load.takesLeft) }
        // Running work outranks a failure, because the render in front of you
        // is the more useful thing to watch — but with nothing running, a
        // failure nobody has dismissed is the truth about the queue and
        // "QUEUE EMPTY" is not.
        if load.failed > 0 { return .failed(count: load.failed) }
        return .idle
    }

    // MARK: - Queue panel

    /// Renders, not transfers. A download is started from the Models screen
    /// with its progress already in front of you; a render is started and then
    /// waited on, which is the wait this panel exists to fill.
    private var isRenderingWork: Bool {
        env.jobsStore.active.values.contains { !$0.status.isTerminal }
    }

    private static let panelMotion = Animation.easeOut(duration: 0.22)
    private static let windowMinWidth: CGFloat = 1100

    /// Where the panel is sitting right now: the stored preference, unless it
    /// opened itself for a render, which pins it for that showing.
    private var queueIsPinned: Bool { queuePanel.isPinned(preference: queuePinned) }

    private var queueGutter: CGFloat {
        QueuePanel.gutter(isOpen: queuePanel.isOpen, isPinned: queueIsPinned,
                          width: Bench.Metrics.Inspector.queue)
    }

    /// Showing, and over the screen rather than beside it.
    private var queueFloats: Bool { queuePanel.isOpen && !queueIsPinned }

    /// Floats by default, so glancing at the queue never reflows the screen
    /// you were working on, and pins when you want it permanently — which is
    /// the same view either way, sat in the gutter the padding above reserves.
    ///
    /// It covers the content only: the sidebar stays reachable underneath it,
    /// and so does the transport bar carrying the button that opened it. The
    /// shadow is what says which of the two it is doing — a floating panel is
    /// over your work, a pinned one is beside it — so it goes when it pins.
    @ViewBuilder
    private var queueOverlay: some View {
        if queuePanel.isOpen {
            BenchInspector(width: Bench.Metrics.Inspector.queue) {
                QueueRail(jobs: env.jobsStore, downloads: env.downloadsStore,
                          catalog: env.catalog, isPinned: queueIsPinned,
                          onClose: {
                              withAnimation(Self.panelMotion) { queuePanel.close() }
                          },
                          onTogglePin: {
                              // Toggling what is *drawn*, not what is stored:
                              // a panel pinned by a render shows a filled pin,
                              // and clicking it has to unpin — flipping the
                              // preference alone would leave it pinned and the
                              // button looking broken.
                              withAnimation(Self.panelMotion) {
                                  queuePinned = !queueIsPinned
                                  queuePanel.pinChanged()
                              }
                          })
            }
            .shadow(color: .black.opacity(queueIsPinned ? 0 : 0.45), radius: 26, x: -8)
            .transition(.move(edge: .trailing))
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch destination {
        case .studio:
            StudioView(catalog: env.catalog, jobs: env.jobsStore,
                       library: env.library, playback: env.playback,
                       prefill: env.prefill, actions: songActions,
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
                          onEditPart: { part in
                              env.studio.pending = .edit(materialId: part.id)
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
        case .editor:
            EditorScreen(store: env.editor, library: env.library,
                         parts: env.partsStore, playback: env.playback,
                         onOpenLibrary: { destination = .library })
        case .models:
            ModelsScreen(catalog: env.catalog, downloads: env.downloadsStore,
                         telemetry: env.telemetry,
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
            },
            edit: { song in
                env.studio.pending = .edit(materialId: song.id)
            },
            playOriginal: { song in
                env.playback.play(url: song.backupURL,
                                  songId: song.id + ".original",
                                  title: song.title,
                                  duration: song.durationS,
                                  subtitle: "ORIGINAL · "
                                      + song.sourceLabel.uppercased())
            },
            revertEdits: { song in
                // Confirmed here rather than at each call site: this is the
                // one action in the app that discards audio the user cannot
                // get back, and the row menu used to fire it on one click.
                pendingRevert = song
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
        case .edit(let materialId):
            openEditor(materialId: materialId)
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

    /// Reverting goes through the Editor's own path: it owns the file swap,
    /// the record rewrite and the peak invalidation, and a second copy here
    /// would drift. It refuses while a render is in flight rather than
    /// resetting a session that is mid-apply.
    private func revert(_ song: SongRecord) {
        // By id: the Editor may be holding a different track mid-edit, and
        // taking that session over to act on this one is a surprise.
        if !env.editor.revert(songId: song.id) {
            revertBlocked = env.editor.renderingTitle
                ?? "another track"
        }
    }

    /// Open the Editor on a song or a part — the id may be either, exactly
    /// as the other material intents accept.
    private func openEditor(materialId: String) {
        if ((try? env.partsStore.repository.part(id: materialId)) ?? nil) != nil {
            env.editor.open(partId: materialId)
        } else {
            env.editor.open(songId: materialId)
        }
        destination = .editor
    }

    /// A rendered selection snippet landed in the library: route it where
    /// the send-onward panel promised (Tier 3.1).
    private func wireEditorRouting() {
        env.editor.onSnippetReady = { song, intent in
            switch intent {
            case .continueFrom:
                useMelody(song.fileURL)
            case .splitRegion:
                env.studio.pending = .split(songId: song.id)
            case .findMatches:
                env.studio.pending = .findMatches(materialId: song.id)
            }
        }
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
    case songs, imported, parts, renders, edited, favourites
    var id: String { rawValue }
    var title: String {
        switch self {
        // "Songs" while imports had nowhere else to go; now that they do, the
        // distinction has to be on the label rather than implied by absence.
        // The noun is dropped because the column of scopes supplies it — every
        // one of these is a kind of thing in the library, and only this one was
        // saying so.
        case .songs: "Generated"
        case .imported: "Imported"
        case .parts: "Parts"
        case .renders: "Renders"
        case .edited: "Edited"
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
        // Edited spans every origin — a generated take, an import and a
        // render are all editable, and all land here once applied.
        case .parts, .edited, .favourites: nil
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
        case .edited: "scissors"
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
        case .library where libraryScope == .edited:
            backupsCard
        case .studio, .editor, .library where libraryScope != .parts:
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
        EngineStatusButton(engine: env.engineStatus, arrowEdge: .trailing) {
            engineCardBody
        }
    }

    private var engineCardBody: some View {
        BenchSidebarCard(stroke: isRendering ? Bench.Palette.accent.opacity(0.2)
                                             : Bench.Palette.hairline) {
            HStack(spacing: 8) {
                StatusDot(color: statusColor)
                Text(isRendering ? "Rendering" : env.backendStatus.phase.label)
                    .font(Bench.Typo.secondaryEmphasis)
                    .foregroundStyle(Bench.Palette.textPrimary)
                Spacer(minLength: 0)
                EngineStatusHint()
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

    // MARK: backups

    /// What the originals are costing, and the one honest warning about
    /// deleting them: the backup file's existence is what makes Revert
    /// offerable, so removing one ends that track's revert forever.
    private var backupsCard: some View {
        let usage = LibraryRepository.backupUsage()
        return BenchSidebarCard {
            Text("BACKUPS").eyebrow()
            Text(TelemetryStore.gigabytes(usage.bytes) + " GB")
                .font(Bench.Typo.valueLarge)
                .foregroundStyle(Bench.Palette.textPrimary)
            Text("\(usage.count) ORIGINAL"
                 + (usage.count == 1 ? "" : "S") + " KEPT\n"
                 + "DELETING ONE DROPS REVERT")
                .font(Bench.Typo.mono(11))
                .lineSpacing(3)
                .foregroundStyle(Bench.Palette.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            Button("Manage backups…") {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [StoragePaths.libraryBackups])
            }
            .buttonStyle(.bench(.quiet))
            .frame(maxWidth: .infinity)
            .help("Show the stashed originals in Finder")
        }
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
        // "0 MODELS" while the engine is still starting is the same wrong
        // claim the Actions cards used to make, in the one card that is on
        // screen at the same time as the list saying "Loading models…".
        var line = env.catalog.readiness.knowsWhatIsInstalled
            ? "\(installedModels.count) MODEL"
                + (installedModels.count == 1 ? "" : "S")
            : "— MODELS"
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

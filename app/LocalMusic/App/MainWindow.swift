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

    /// Where the shell is pointed, what it has picked, and which panels are
    /// showing. All of it used to be `@State` here; it moved to `ShellState`
    /// when the menubar arrived, because a `Commands` body is built with the
    /// scene and can never reach a view’s state. Nothing else changed —
    /// this view reads and writes exactly the same values, one indirection
    /// further out.
    @Bindable private var shell: ShellState

    /// How far each library scope was scrolled, kept out of the screen because
    /// the screen itself is rebuilt on every navigation. Dies with the window,
    /// as asked: a scroll position is where you just were, not a preference —
    /// and no menu item has an opinion about it, so it stayed here.
    @State private var libraryScroll = LibraryScrollMemory()
    /// Which build of the first-run flow this user has been through. Versioned
    /// rather than a bool so a later change to the recommended set can offer
    /// itself once more without a defaults migration.
    @AppStorage("onboarding.completedVersion") private var onboardingVersion = 0
    /// Whether the window is currently too narrow to hold both. Overrules the
    /// preference without erasing it.
    @State private var sidebarFit = SidebarFit()
    /// The narrowest the screen on show fits inside without overflowing its
    /// own edges, measured from the screen itself — a different number on
    /// every destination, and several hundred points larger on the Editor than
    /// any constant the shell could carry. Seeded with the old guess for the
    /// first frame.
    @State private var contentMinWidth = SidebarFit.contentMinWidth
    /// The window's own width, kept so the sidebar's fit can be recomputed
    /// when the *content's* requirement changes rather than only when the
    /// window is dragged.
    ///
    /// In a reference box rather than in `@State` because nothing in the body
    /// reads it — only `refitSidebar` does, and only to decide a boolean that
    /// flips at one width. Held as state, every frame of a window drag wrote
    /// it, and every write rebuilt this view and the whole screen inside it,
    /// to discover that the sidebar still fits. `sidebarFit` is the state; the
    /// width is just the input.
    @State private var measuredWidth = WidthBox()

    /// Mutable storage that is deliberately invisible to SwiftUI — see
    /// `measuredWidth`.
    private final class WidthBox { var value: CGFloat = 0 }

    /// Bump when the recommended set changes enough to be worth re-offering.
    private static let onboardingVersionCurrent = 1

    init(env: AppEnvironment) {
        self.env = env
        self.shell = env.shell
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if !sidebarIsCollapsed {
                    // Slides out to the left rather than fading: the sidebar
                    // is a column of the window, and a column that dissolves
                    // in place reads as a drawing bug.
                    ShellSidebar(env: env, destination: $shell.destination,
                                 libraryScope: $shell.libraryScope)
                        .transition(.move(edge: .leading))
                }
                FittingWidthReader(version: contentShapeVersion,
                                   onChange: { contentMinWidth = $0 }) {
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
            ShellTransport(env: env, slot: transportSlot,
                           isQueueOpen: shell.queuePanel.isOpen,
                           onToggleQueue: {
                               withAnimation(panelMotion) { shell.queuePanel.toggle() }
                           },
                           onToggleCompare: {
                               shell.compare.toggle(playback: env.playback)
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
        // Settings, ambiently: the confirmation gates live on leaf views
        // (song and part inspectors), and threading a parameter through
        // every layer for a yes/no would make Settings look like a
        // dependency of screens that merely honour one preference.
        .environment(env.settings)
        // Ambient for the same reason settings is, and read optionally at the
        // far end for the same reason too: the only thing that wants it down
        // there is the detail pane's rename mailbox, and threading a shell
        // through six layers for one `FocusState` would make the Library look
        // like a dependency of the menubar.
        .environment(env.shell)
        // Ambient like settings, and optional at the reading end for the same
        // reason: previews and tests host panes without an environment, and
        // "no text store" must read as "no text-docs section".
        .environment(env.textStore)
        // The floor rises with the pinned rail rather than letting it eat the
        // screen behind it: 1100 is already fully spent by Studio in Full
        // control (230 pt of sidebar, a 576 pt parameter panel).
        // The floor is the *content's*, not the content plus a sidebar that
        // can now step out of the way. Below `contentMinWidth + sidebarWidth`
        // the sidebar collapses on its own, which is what lets the window go
        // this narrow at all.
        // The measured requirement, not a constant: this is what stops the
        // window being dragged narrower than the screen inside it can draw.
        .frame(minWidth: contentMinWidth, minHeight: 700)
        // The floor above only stops the window being dragged narrower; it
        // cannot widen one that is already too small — see `WindowWidthFloor`.
        // So the window is grown to fit as well, and the sidebar collapsing is
        // what happens when even the display cannot supply the width.
        .background {
            WindowWidthFloor(width: requiredWidth)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
        // Measured from the window rather than inferred from the screen: the
        // decision is about the room the sidebar and the screen have to share,
        // and only the enclosing frame knows how much that is.
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onChange(of: proxy.size.width, initial: true) {
                        measuredWidth.value = proxy.size.width
                        refitSidebar()
                    }
            }
        }
        .environment(\.sidebarControl, SidebarControl(
            isCollapsed: sidebarIsCollapsed,
            isLocked: sidebarFit.isCramped,
            toggle: {
                withAnimation(panelMotion) { shell.sidebarCollapsed.toggle() }
            }))
        // A screen with a wider requirement can arrive without the window
        // changing size at all — opening the Editor is exactly that — so the
        // fit is recomputed from the content too, not only from the frame.
        .onChange(of: contentMinWidth) { refitSidebar() }
        .onChange(of: env.studio.pending) { routeIntent() }
        .onChange(of: env.prefill.pending) { if env.prefill.pending != nil {
            shell.destination = .generate
        } }
        .onChange(of: isRenderingWork) {
            withAnimation(panelMotion) {
                shell.queuePanel.workChanged(isWorking: isRenderingWork)
            }
        }
        .onChange(of: queueIsEmpty) {
            withAnimation(panelMotion) {
                shell.queuePanel.contentsChanged(isEmpty: queueIsEmpty)
            }
        }
        .task { await env.pollTelemetry() }
        .onAppear {
            offerOnboarding()
            wireEditorRouting()
        }
        .confirmationDialog(
            "Revert “\(shell.pendingRevert?.title ?? "")” to the original?",
            isPresented: Binding(get: { shell.pendingRevert != nil },
                                 set: { if !$0 { shell.pendingRevert = nil } })) {
            Button("Revert — discard the edits", role: .destructive) {
                if let song = shell.pendingRevert { actions.revert(song) }
                shell.pendingRevert = nil
            }
        } message: {
            Text("The file goes back to the untouched original and the edit "
                 + "list is cleared. This cannot be undone.")
        }
        .alert("Still rendering",
               isPresented: Binding(get: { shell.revertBlocked != nil },
                                    set: { if !$0 { shell.revertBlocked = nil } })) {
            Button("OK") { shell.revertBlocked = nil }
        } message: {
            Text("“\(shell.revertBlocked ?? "")” is being rendered. Reverting has "
                 + "to wait for it to finish.")
        }
        // The Track menu's Delete, confirmed here for the reason the revert
        // above is: a menu item cannot host a dialog, and the panes that
        // already ask do so from inside a screen this one can be pointed away
        // from. The row menus keep their own — this is the menubar's path to
        // the same deletion, not a replacement for theirs.
        .confirmationDialog(
            "Delete “\(actions.pendingDeleteTitle)”?",
            isPresented: Binding(get: { shell.pendingDelete != nil },
                                 set: { if !$0 { shell.pendingDelete = nil } })) {
            Button("Delete and its files", role: .destructive) {
                if let target = shell.pendingDelete {
                    actions.deleteTarget(target)
                }
                shell.pendingDelete = nil
            }
        }

        .onChange(of: env.catalog.hasLoaded) { offerOnboarding() }
        // Stamped on the way *out* rather than by the sheet's own buttons, so
        // every route closes it for good — including an Escape press, which
        // would otherwise bring the welcome back on every launch.
        .sheet(isPresented: Binding(get: { shell.showOnboarding },
                                    set: { open in
                                        shell.showOnboarding = open
                                        if !open {
                                            onboardingVersion = Self.onboardingVersionCurrent
                                        }
                                    })) {
            OnboardingView(catalog: env.catalog,
                           downloads: env.downloadsStore,
                           backend: env.backendStatus,
                           freeDiskBytes: env.telemetry.freeDiskBytes) {
                shell.showOnboarding = false
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
              !shell.showOnboarding else { return }
        // Only a never-onboarded install opens early. A *re-onboarding* — the
        // version stamp moving in a later release — belongs to someone whose
        // engine is already provisioned and whose catalog lands in under a
        // second, and flashing a welcome at them to conclude "everything
        // recommended is here" is worse than the second's wait.
        guard env.catalog.hasLoaded else {
            if onboardingVersion == 0 { shell.showOnboarding = true }
            return
        }
        let plan = OnboardingPlan.make(models: env.catalog.models,
                                       physicalRAM: ModelCatalogStore.physicalRAM,
                                       hasHFToken: env.catalog.hasHFToken)
        guard !plan.isEmpty else {
            onboardingVersion = Self.onboardingVersionCurrent
            return
        }
        shell.showOnboarding = true
    }

    // MARK: - Sidebar

    // MARK: - Transport corner

    /// What the transport has to say *besides* the queue, which is always
    /// drawn. Comparing two takes is the one thing you do with the transport
    /// itself, so it is what earns the space beside the readout.
    private var transportSlot: TransportBar.Slot {
        if shell.destination == .library, shell.compare.isActive {
            return .compare(isB: shell.compare.isB)
        }
        return .none
    }

    // MARK: - Queue panel

    /// Renders, not transfers. A download is started from the Models screen
    /// with its progress already in front of you; a render is started and then
    /// waited on, which is the wait this panel exists to fill.
    private var isRenderingWork: Bool { env.jobsStore.isWorking }

    /// Nothing left to draw — no work, no transfers, and no finished rows still
    /// waiting to be dismissed. Deliberately not the same as "nothing running":
    /// the take that just landed is still a row, and still worth reading.
    ///
    /// Two gated `Bool`s rather than `load.adding(transfers).isEmpty`: a
    /// reader of `load` is subscribed to `takesLeft` and a reader of
    /// `transfers` to `leadPercent`, both of which move continuously through
    /// a render or a download — so asking this question used to invalidate
    /// the window several times a second while it was being answered "no"
    /// over and over.
    private var queueIsEmpty: Bool {
        env.jobsStore.queueEmpty && env.downloadsStore.transfersEmpty
    }

    /// nil (no animation at all) under Settings' reduce-motion; every use
    /// goes through `withAnimation`, which treats nil as "just do it".
    private var panelMotion: Animation? {
        env.settings.reduceMotion ? nil : .easeOut(duration: 0.22)
    }
    // The old 1100 pt window floor lives on as `SidebarFit.contentMinWidth`
    // plus the sidebar it used to include. It is not a constant here any more
    // because the sidebar is no longer always part of the sum.

    /// Where the panel is sitting right now: the stored preference, unless it
    /// opened itself for a render, which pins it for that showing.
    private var queueIsPinned: Bool { shell.queuePanel.isPinned(preference: shell.queuePinned) }

    /// What the measured content's width requirement can turn on: which
    /// screen is up, and whether the pinned queue is taking a gutter out of
    /// it. Anything else that changes inside a screen is picked up at the
    /// next screen change or window resize — see `FittingWidthLayout`.
    private var contentShapeVersion: Int {
        var hasher = Hasher()
        hasher.combine(shell.destination)
        hasher.combine(queueGutter)
        return hasher.finalize()
    }

    private var queueGutter: CGFloat {
        QueuePanel.gutter(isOpen: shell.queuePanel.isOpen, isPinned: queueIsPinned,
                          width: Bench.Metrics.Inspector.queue)
    }

    /// Showing, and over the screen rather than beside it.
    private var queueFloats: Bool { shell.queuePanel.isOpen && !queueIsPinned }

    /// What the window actually draws — the preference unless the window has
    /// overruled it.
    private var sidebarIsCollapsed: Bool {
        sidebarFit.isCollapsed(preference: shell.sidebarCollapsed)
    }

    /// What the window would have to be to show all of it at once: the screen
    /// at its narrowest useful width, the pinned queue's column, and the
    /// sidebar if the user has not put it away.
    private var requiredWidth: CGFloat {
        SidebarFit.requiredWidth(sidebarPreferredOpen: !shell.sidebarCollapsed,
                                 contentMinWidth: contentMinWidth)
    }

    /// Only touches `sidebarFit`, and `SidebarFit` is `Equatable`, so a drag
    /// that does not cross the threshold writes the same value back and
    /// SwiftUI has nothing to redraw.
    private func refitSidebar() {
        var next = sidebarFit
        next.widthChanged(measuredWidth.value, contentMinWidth: contentMinWidth)
        guard next != sidebarFit else { return }
        withAnimation(panelMotion) { sidebarFit = next }
        // Republished for the View menu, which cannot read a window's
        // measurement: an item offering to bring back a sidebar the window is
        // too narrow to hold has to dim instead.
        shell.sidebarCramped = next.isCramped
    }

    /// Take the user to a track a finished queue row made.
    ///
    /// The scope comes from the song's own origin rather than being assumed to
    /// be Generated: the same row shape carries a recombination, and dropping
    /// the user on the Generated list with a render selected shows an empty
    /// pane over a list the track is not in.
    ///
    /// A floating panel closes on the way, because it is sitting on top of the
    /// list it just sent you to. A pinned one has its own column and stays —
    /// pinning it is a statement that you want it there.
    private func showInLibrary(songId: String) {
        guard let song = env.library.song(id: songId) else { return }
        shell.libraryReveal = LibraryReveal(
            songId: songId, scope: LibraryScope(origin: song.originKind))
        shell.destination = .library
        if queueFloats {
            withAnimation(panelMotion) { shell.queuePanel.close() }
        }
    }

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
        if shell.queuePanel.isOpen {
            BenchInspector(width: Bench.Metrics.Inspector.queue) {
                QueueRail(jobs: env.jobsStore, downloads: env.downloadsStore,
                          catalog: env.catalog, isPinned: queueIsPinned,
                          onClose: {
                              withAnimation(panelMotion) { shell.queuePanel.close() }
                          },
                          onTogglePin: {
                              // Toggling what is *drawn*, not what is stored:
                              // a panel pinned by a render shows a filled pin,
                              // and clicking it has to unpin — flipping the
                              // preference alone would leave it pinned and the
                              // button looking broken.
                              withAnimation(panelMotion) {
                                  shell.queuePinned = !queueIsPinned
                                  shell.queuePanel.pinChanged()
                              }
                          },
                          onShowInLibrary: showInLibrary)
            }
            .shadow(color: .black.opacity(queueIsPinned ? 0 : 0.45), radius: 26, x: -8)
            .transition(.move(edge: .trailing))
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch shell.destination {
        case .generate:
            StudioView(catalog: env.catalog, jobs: env.jobsStore,
                       library: env.library, parts: env.partsStore,
                       playback: env.playback,
                       telemetry: env.telemetry, timings: env.renderTimings,
                       notifications: env.notifications,
                       prefill: env.prefill, actions: songActions,
                       settings: env.settings,
                       onOpenModels: { openModels(for: nil) })
        case .library:
            LibraryScreen(library: env.library, parts: env.partsStore,
                          jobs: env.jobsStore, playback: env.playback,
                          settings: env.settings,
                          scope: $shell.libraryScope, reveal: $shell.libraryReveal,
                          actions: songActions,
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
                          compare: shell.compare,
                          scrollMemory: libraryScroll,
                          selectedSongId: $shell.selectedSongId,
                          selectedPartId: $shell.selectedPartId,
                          checked: $shell.checked)
        case .styleTransfer:
            StyleTransferScreen(model: env.styleTransfer, catalog: env.catalog,
                                library: env.library, parts: env.partsStore,
                                jobs: env.jobsStore, playback: env.playback,
                                telemetry: env.telemetry,
                                timings: env.renderTimings,
                                notifications: env.notifications,
                                onOpenModels: { openModels(for: $0) })
        case .actions:
            ActionsScreen(
                settings: env.settings, tones: env.toneLibrary,
                catalog: env.catalog, library: env.library,
                parts: env.partsStore, jobs: env.jobsStore,
                playback: env.playback, workbench: env.workbench,
                assistant: env.assistant, plans: env.plans,
                textStore: env.textStore, textChain: env.textChain,
                route: $shell.actionsRoute,
                onOpenModels: { openModels(for: $0) },
                onOpenWorkbench: { notes in
                    shell.workbenchNotices = notes
                    shell.destination = .workbench
                },
                onOpenStyleTransfer: { preset, sourceId in
                    openStyleTransfer(preset: preset, sourceId: sourceId)
                },
                onOpenGenerate: { preset, sourceId in
                    openGenerate(preset: preset, sourceId: sourceId)
                },
                onOpenEditor: { materialId in
                    openEditor(materialId: materialId)
                },
                // The assistant's cards carry finished text rather than a
                // preset, so they set the prefill directly instead of going
                // through `openGenerate` — there is no card whose seed this
                // is, only what the user just read and approved.
                onUseText: { prefill in
                    env.prefill.pending = prefill
                    shell.destination = .generate
                })
        case .workbench:
            WorkbenchScreen(model: env.workbench, catalog: env.catalog,
                            library: env.library, parts: env.partsStore,
                            jobs: env.jobsStore, playback: env.playback,
                            telemetry: env.telemetry,
                            timings: env.renderTimings,
                            notifications: env.notifications,
                            notices: $shell.workbenchNotices,
                            onOpenModels: { openModels(for: nil) },
                            onOpenStyleTransfer: { preset, sourceId in
                                openStyleTransfer(preset: preset,
                                                  sourceId: sourceId)
                            })
        case .editor:
            EditorScreen(store: env.editor, catalog: env.catalog,
                         library: env.library, parts: env.partsStore,
                         jobs: env.jobsStore, playback: env.playback,
                         onOpenModels: { openModels(for: nil) },
                         onOpenLibrary: { shell.destination = .library })
        case .models:
            ModelsScreen(catalog: env.catalog, downloads: env.downloadsStore,
                         telemetry: env.telemetry,
                         requirement: $shell.modelRequirement,
                         inspectedId: $shell.modelInspectedId,
                         showAddModel: $shell.showAddModel,
                         // An action named in the properties rail opens on
                         // the Actions shelf, with no source picked — the
                         // errand was "show me this card", not "run it".
                         onOpenAction: { recipe in
                             shell.actionsRoute = .action(recipeId: recipe.id,
                                                    sourceId: nil)
                             shell.destination = .actions
                         })
        }
    }

    /// Go to Models, carrying what was missing. Always assigned — including
    /// `nil` — so an errand from one screen cannot leave its filter behind for
    /// the next visit from another.
    private func openModels(for requirement: ModelRequirement?) {
        shell.modelRequirement = requirement
        shell.destination = .models
    }

    // MARK: - Intents

    /// The jumps a track offers, built once in `ShellActions` so the row
    /// menus, the detail panes and the Track menu are one implementation
    /// rather than three. It used to be assembled here; the menubar needed the
    /// same bundle from outside the view, and two copies of "what a track can
    /// do" would have drifted the first time one gained an entry.
    private var songActions: SongActions { actions.songActions }

    /// The shell's actions, over this window's environment.
    private var actions: ShellActions { ShellActions(env: env) }

    /// Intents arrive as a mailbox write from any screen. With Split &
    /// Recombine dissolved, there is no longer a second-level screen to hand
    /// them to, so the shell both routes *and* consumes them — and must clear
    /// the mailbox, which the old consumer did.
    private func routeIntent() {
        guard let intent = env.studio.pending else { return }
        switch intent {
        case .split(let songId):
            shell.actionsRoute = .action(recipeId: "split-instruments", sourceId: songId)
            shell.destination = .actions
        case .findMatches(let materialId):
            shell.actionsRoute = .action(recipeId: "what-mashes", sourceId: materialId)
            shell.destination = .actions
        case .addToWorkbench(let partId):
            if let material = material(id: partId) {
                env.workbench.add(material: material, parts: env.partsStore)
            }
            shell.destination = .workbench
        case .openMix(let songId):
            shell.workbenchNotices = env.workbench.load(songId: songId,
                                                  parts: env.partsStore,
                                                  library: env.library)
            shell.destination = .workbench
        case .styleTransfer(let materialId, let presetId):
            openStyleTransfer(
                preset: presetId.flatMap(StylePreset.preset(forRecipeId:)),
                sourceId: materialId)
        case .edit(let materialId):
            openEditor(materialId: materialId)
        case .describe(let materialId):
            shell.actionsRoute = .action(recipeId: "describe-song",
                                   sourceId: materialId)
            shell.destination = .actions
        case .generate(let presetId, let materialId):
            if let preset = GeneratePreset.preset(id: presetId) {
                openGenerate(preset: preset, sourceId: materialId)
            }
        }
        env.studio.pending = nil
    }

    /// Open Generate with an Actions preset applied.
    ///
    /// The preset picks the model rather than naming one: a card asks for a
    /// *kind* of model — one that can sing, one that can reach two minutes —
    /// and the best installed answer is chosen here. Naming a specific id in
    /// the table would break the card the moment that model was uninstalled,
    /// and the gallery has already refused to open a card nothing can run.
    private func openGenerate(preset: GeneratePreset, sourceId: String?) {
        let model = preset.need.best(env.catalog.models)
        var prompt = preset.promptSeed
        var notice = preset.notice
        var audioParams: [String: URL] = [:]
        if let key = preset.sourceParamKey, let sourceId,
           let material = material(id: sourceId) {
            // The track itself, into the param the card names. The
            // tempo-and-key prompt line below is for cards whose model never
            // hears the source; this model does, so writing "132 bpm" into
            // the prompt would be describing audio it is already listening to.
            audioParams[key] = material.fileURL
        } else if preset.readsMeasurements, let sourceId,
                  let measured = musicalMeta(of: sourceId) {
            // The track's own words, not its audio: this is a *description*
            // of what to make, and the model never hears the reference.
            prompt = ActionFormat.join([measured.phrase, preset.promptSeed])
                .trimmingCharacters(in: .whitespaces)
            notice = "Matching \(measured.title) — \(measured.phrase). "
                + "None of its audio is used, only what the analysis measured."
        }
        env.prefill.pending = .init(prompt: prompt,
                                    lyrics: preset.lyricsSeed,
                                    modelId: model?.id,
                                    audioParams: audioParams,
                                    durationS: preset.durationS,
                                    takes: preset.takes,
                                    notice: notice)
        shell.destination = .generate
    }

    /// A track's measured tempo and key, phrased for a prompt.
    ///
    /// Nil when the library holds no analysis for it — a card that quietly
    /// dropped the half of its promise it could not keep would be worse than
    /// one that says the tempo is unknown.
    private func musicalMeta(of materialId: String)
        -> (title: String, phrase: String)? {
        guard let material = material(id: materialId),
              let analysis = env.partsStore.analysis(for: materialId)
        else { return nil }
        var fields: [String] = []
        if let bpm = analysis.bpm {
            fields.append("\(Int(bpm.rounded())) bpm")
        }
        if let camelot = analysis.camelot {
            fields.append("in \(camelot)")
        }
        guard !fields.isEmpty else { return nil }
        return (material.name, fields.joined(separator: ", ") + ",")
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

    /// Open the Editor on a song or a part — the id may be either, exactly
    /// as the other material intents accept.
    private func openEditor(materialId: String) {
        if ((try? env.partsStore.repository.part(id: materialId)) ?? nil) != nil {
            env.editor.open(partId: materialId)
        } else {
            env.editor.open(songId: materialId)
        }
        shell.destination = .editor
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
    /// a shell.destination is that its state is worth keeping.
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
        shell.destination = .styleTransfer
    }

    private func useMelody(_ melodyURL: URL) {
        let melodyModel = env.catalog.models.first {
            $0.installState == .installed
                && $0.capabilities.supportedTasks.contains("generate")
                && $0.capabilities.params.contains {
                    $0.type == .audio && $0.key == "melody_audio"
                }
        }
        env.prefill.pending = .init(prompt: "", modelId: melodyModel?.id,
                                    audioParams: ["melody_audio": melodyURL])
        shell.destination = .generate
    }
}

/// Which slice of the library is on screen. Lives here rather than inside the
/// library view because the sidebar card changes with it — Parts swaps the
/// engine readout for the stem-colour legend.
/// "Open the Library here, on this track."
///
/// Carries the scope as well as the id because the two have to move together:
/// selecting a render while the Generated list is showing selects a row that
/// list does not contain, and the pane behind it would stay empty.
struct LibraryReveal: Equatable {
    var songId: String
    var scope: LibraryScope
}

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

    /// Where a song of this origin lives — the inverse of `origin`, for
    /// anything sending the user to a track it already has in hand.
    init(origin: SongOrigin) {
        switch origin {
        case .generated: self = .songs
        case .imported: self = .imported
        case .recombined: self = .renders
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
/// The footer's download slot.
///
/// Its own `View` for one reason: `SidebarDownload.make` needs the raw
/// `downloads` dictionary at full precision, and that dictionary is rewritten
/// on every progress frame — twice a second, for as long as a multi-gigabyte
/// fetch takes. Read from `SidebarFooterCard.body` it subscribed the whole
/// footer — context card, engine card, parts drawer — to those frames, so all
/// three re-rendered to move one byte count. Here the invalidation stops at
/// the card that is actually drawing the number.
private struct SidebarDownloadSlot: View {
    let downloads: DownloadsStore
    let catalog: ModelCatalogStore

    var body: some View {
        if let download = SidebarDownload.make(
            downloads: Array(downloads.downloads.values),
            models: catalog.models) {
            // Keyed on the download it is drawing so the rate smoother inside
            // starts clean for each one: reusing the view across the end of
            // one transfer and the start of the next would carry the old
            // average into the new ETA.
            SidebarDownloadCard(download: download)
                .id(download.info.downloadId)
        }
    }
}

struct SidebarFooterCard: View {
    let env: AppEnvironment
    let destination: Destination
    let libraryScope: LibraryScope

    /// Shared with `ModelsScreen` through the catalog store, so the storage
    /// card can point the list at what is on disk — for this session, not as
    /// a rewritten preference.
    private var onlyInstalled: Bool {
        get { env.catalog.onlyInstalledFilter }
        nonmutating set { env.catalog.onlyInstalledFilter = newValue }
    }

    /// Three slots at most, in order of how local the information is: what you
    /// need *here*, then whatever the machine is fetching, then — on every
    /// screen — what the engine is doing. The last two are worth knowing from
    /// anywhere, because a render started on any screen runs in the same queue
    /// and costs the same memory, and a 57 GB model fetched from the Models
    /// screen is still arriving long after you have left it; screens that used
    /// to hide either behind their own card were the screens where you were
    /// most likely to be waiting on one.
    /// The originals' disk cost, read on appear rather than in `backupsCard`.
    ///
    /// `LibraryRepository.backupUsage()` enumerates the backups folder and
    /// `stat`s every file in it. Computed inside the card's body it ran on
    /// every redraw of this footer — and the footer redraws whenever the
    /// engine card's telemetry moves, which is every three seconds.
    @State private var backupUsage = LibraryRepository.BackupUsage()

    var body: some View {
        VStack(spacing: 10) {
            contextCard
            downloadCard
            engineCard
        }
        .padding(12)
        .task(id: showsBackups) {
            guard showsBackups else { return }
            let usage = await Task.detached(priority: .utility) {
                LibraryRepository.backupUsage()
            }.value
            if usage != backupUsage { backupUsage = usage }
        }
    }

    private var showsBackups: Bool {
        destination == .library && libraryScope == .edited
    }

    /// The local card, or nothing on the screens whose local information *is*
    /// the engine's.
    @ViewBuilder private var contextCard: some View {
        switch destination {
        case .library where libraryScope == .edited:
            backupsCard
        case .library where libraryScope == .parts:
            stemColoursCard
        case .actions, .styleTransfer:
            legendCard
        case .workbench:
            partsDrawerCard
        case .models:
            storageCard
        case .generate, .editor, .library:
            EmptyView()
        }
    }

    // MARK: download

    /// Drawn only while something is actually being fetched, which is not most
    /// of the time — the footer is already two cards tall on the screens that
    /// have a context card, and a permanent third one saying "nothing is
    /// downloading" would cost the nav list a row of height to report an
    /// absence.
    ///
    /// Keyed on the download it is drawing so the rate smoother inside starts
    /// clean for each one: reusing the view across the end of one transfer and
    /// the start of the next would carry the old average into the new ETA.
    private var downloadCard: some View {
        SidebarDownloadSlot(downloads: env.downloadsStore, catalog: env.catalog)
    }

    // MARK: engine

    private var isRendering: Bool { env.jobsStore.isWorking }

    private var engineCard: some View {
        EngineStatusButton(engine: env.engineStatus, arrowEdge: .trailing) {
            engineCardBody
        }
    }

    private var engineCardBody: some View {
        BenchSidebarCard(stroke: isRendering ? Bench.Palette.accent.opacity(0.2)
                                             : Bench.Palette.hairline,
                         margin: 0) {
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
        BenchSidebarCard(margin: 0) {
            Text("BACKUPS").eyebrow()
            Text(TelemetryStore.gigabytes(backupUsage.bytes) + " GB")
                .font(Bench.Typo.valueLarge)
                .foregroundStyle(Bench.Palette.textPrimary)
            Text("\(backupUsage.count) ORIGINAL"
                 + (backupUsage.count == 1 ? "" : "S") + " KEPT\n"
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
        BenchSidebarCard(margin: 0) {
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
        BenchSidebarCard(margin: 0) {
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
        BenchSidebarCard(margin: 0) {
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
        BenchSidebarCard(margin: 0) {
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

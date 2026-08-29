import SwiftUI

/// The whole menubar, assembled.
///
/// Split into one `Commands` conformer per menu below, and gathered here so
/// `LocalMusicApp.body` reads as a scene rather than as a menu definition.
///
/// Two rules run through all of them.
///
/// **Dim, never hide.** Every item is always present and disabled from real
/// state — the same convention the screens follow, and the reason a menubar is
/// worth having at all: it is the one place you can read what the app can do
/// without first arranging for it to be possible.
///
/// **Read cold state in the body, hot state in the closure.** A `Commands`
/// body is re-evaluated like a view body, so touching `JobsStore.load` or
/// `DownloadsStore.transfers` from one would put the entire menubar on a
/// render's progress tick. Enablement therefore reads only the gated
/// projections (`isWorking`, `queueEmpty`, `transfersEmpty`), and anything
/// live is read inside the action, where nothing is subscribed.
struct ShellCommands: Commands {
    let env: AppEnvironment

    var body: some Commands {
        FileCommands(env: env)
        EditCommands(env: env)
        ViewCommands(env: env)
        PlaybackCommands(env: env)
        TrackCommands(env: env)
        QueueCommands(env: env)
        HelpCommands(env: env)
    }
}

// MARK: - File

/// Files in and out. The app has no document model, so `.newItem` and its
/// neighbours are replaced outright rather than added to.
struct FileCommands: Commands {
    let env: AppEnvironment

    private var actions: ShellActions { ShellActions(env: env) }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Import Audio\u{2026}") { actions.importAudio() }
                .keyboardShortcut("o", modifiers: .command)
            Button("Add Model from Hugging Face\u{2026}") {
                // To Models first: the sheet is presented by that screen, so
                // raising the flag from anywhere else would set a boolean
                // nothing was watching. Going there is the right behaviour
                // regardless — a model added from the menubar lands in the
                // list you are then looking at.
                env.shell.openModels(for: nil)
                env.shell.showAddModel = true
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
        }
        CommandGroup(after: .saveItem) {
            ExportItem(env: env)
            RevealItem(env: env)
            Divider()
            DeleteItem(env: env)
        }
    }
}

/// Export is the one File item with two owners: the Editor can save just the
/// selection, and everywhere else it is a copy of the whole file. A view so it
/// can read the focused value that says which.
private struct ExportItem: View {
    let env: AppEnvironment
    @FocusedValue(\.editorCommands) private var editor

    var body: some View {
        let actions = ShellActions(env: env)
        let picked = actions.resolvedTarget
        Button(title(picked)) {
            if let editor, editor.isEditable {
                editor.export()
            } else {
                actions.exportTarget()
            }
        }
        .keyboardShortcut("e", modifiers: [.command, .shift])
        .disabled(editor?.isEditable != true && picked.kind == .none)
    }

    private func title(_ picked: ShellActions.ResolvedTarget) -> String {
        if editor?.isEditable == true { return "Export Selection\u{2026}" }
        guard let name = picked.title else { return "Export\u{2026}" }
        return "Export \u{201C}\(name)\u{201D}\u{2026}"
    }
}

private struct RevealItem: View {
    let env: AppEnvironment
    @FocusedValue(\.editorCommands) private var editor

    var body: some View {
        let actions = ShellActions(env: env)
        let editorReveal = editor?.reveal
        Button("Reveal in Finder") {
            if let editorReveal { editorReveal() }
            else { actions.revealTarget() }
        }
        .keyboardShortcut("r", modifiers: [.command, .shift])
        .disabled(editorReveal == nil && actions.resolvedTarget.fileURL == nil)
    }
}

private struct DeleteItem: View {
    let env: AppEnvironment

    var body: some View {
        let actions = ShellActions(env: env)
        let picked = actions.resolvedTarget
        Button(title(picked), role: .destructive) {
            actions.requestDeleteTarget()
        }
        // ⌘⌫, the Finder's. Not the bare Delete the Editor uses for its
        // selection: that one removes a slice of audio from a program you can
        // undo, and this one removes a file from the disk.
        .keyboardShortcut(.delete, modifiers: .command)
        .disabled(picked.kind == .none)
    }

    private func title(_ picked: ShellActions.ResolvedTarget) -> String {
        guard let name = picked.title else { return "Delete\u{2026}" }
        return "Delete \u{201C}\(name)\u{201D}\u{2026}"
    }
}

// MARK: - Edit

/// The menu macOS users reach for on reflex, made true.
///
/// Undo and Redo are left to the stock items: `EditorStore` registers with the
/// window's own `UndoManager` and names each step, so the system items already
/// read "Undo Trim" and already dim correctly. Everything else here replaces
/// the invisible `Button("")` block the Editor used to carry — same keys, now
/// with somewhere to see them and something to dim when they do not apply.
struct EditCommands: Commands {
    let env: AppEnvironment

    var body: some Commands {
        CommandGroup(replacing: .pasteboard) {
            EditorClipboardItems()
        }
        CommandGroup(replacing: .textEditing) {
            FindItem()
        }
    }
}

private struct EditorClipboardItems: View {
    @FocusedValue(\.editorCommands) private var editor

    var body: some View {
        let commands = editor ?? EditorCommands()
        let live = commands.isEditable
        Group {
            Button("Cut", action: commands.cut)
                .keyboardShortcut("x", modifiers: .command)
                .disabled(!live || !commands.hasSelection)
            Button("Copy", action: commands.copy)
                .keyboardShortcut("c", modifiers: .command)
                .disabled(!live || !commands.hasSelection)
            Button("Paste", action: commands.paste)
                .keyboardShortcut("v", modifiers: .command)
                .disabled(!live || !commands.canPaste)
            Button("Delete", action: commands.delete)
                // Bare Delete, as the Editor already had it.
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(!live || !commands.hasSelection)
            Divider()
            Button("Select All", action: commands.selectAll)
                .keyboardShortcut("a", modifiers: .command)
                .disabled(!live)
        }
    }
}

/// One Find item in place of the four hidden ⌘F buttons the Library, Models,
/// the Actions gallery and Settings each carried.
private struct FindItem: View {
    @FocusedValue(\.searchCommand) private var search

    var body: some View {
        Button(search.map { "Find in \($0.scope)" } ?? "Find") {
            search?.focus()
        }
        .keyboardShortcut("f", modifiers: .command)
        .disabled(search == nil)
    }
}

// MARK: - View

/// Where to go, and how much of the window to spend getting there.
struct ViewCommands: Commands {
    let env: AppEnvironment

    var body: some Commands {
        CommandGroup(before: .toolbar) {
            GoItems(shell: env.shell)
            Divider()
            PanelItems(env: env)
            Divider()
            ZoomItems()
            Divider()
        }
    }
}

private struct GoItems: View {
    @Bindable var shell: ShellState

    var body: some View {
        Group {
            ForEach(Destination.allCases) { destination in
                Button(destination.title) { shell.go(to: destination) }
                    .keyboardShortcut(shortcut(destination.menuKey,
                                               modifiers: .command))
            }
            Menu("Library") {
                ForEach(LibraryScope.allCases) { scope in
                    Button(scope.title) { shell.go(to: scope) }
                        .keyboardShortcut(shortcut(scope.menuKey,
                                                   modifiers: [.command, .option]))
                }
            }
        }
    }

    /// `keyboardShortcut` takes a non-optional, and a destination past the
    /// ninth has no digit — so an absent key means an item with no shortcut
    /// rather than one that cannot be built.
    private func shortcut(_ key: Character?,
                          modifiers: EventModifiers) -> KeyboardShortcut? {
        key.map { KeyboardShortcut(KeyEquivalent($0), modifiers: modifiers) }
    }
}

private struct PanelItems: View {
    let env: AppEnvironment

    var body: some View {
        let actions = ShellActions(env: env)
        let shell = env.shell
        Group {
            Button(ShellCommandRouting
                .sidebarItemTitle(isCollapsed: shell.sidebarIsCollapsed)) {
                actions.toggleSidebar()
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
            // Cramped, not merely collapsed: a window too narrow to hold the
            // sidebar has put it away on the user's behalf, and an item
            // offering to bring it back cannot keep that promise.
            .disabled(shell.sidebarCramped)

            Button(ShellCommandRouting
                .queueItemTitle(isOpen: shell.queuePanel.isOpen)) {
                actions.toggleQueuePanel()
            }
            .keyboardShortcut("q", modifiers: [.command, .option])

            Toggle("Pin Queue Panel", isOn: Binding(
                get: { shell.queueIsPinned },
                set: { actions.setQueuePinned($0) }))
        }
    }
}

private struct ZoomItems: View {
    @FocusedValue(\.editorCommands) private var editor

    var body: some View {
        let commands = editor ?? EditorCommands()
        let live = editor != nil
        Group {
            Button("Zoom In", action: commands.zoomIn)
                .keyboardShortcut("+", modifiers: .command)
                .disabled(!live)
            Button("Zoom Out", action: commands.zoomOut)
                .keyboardShortcut("-", modifiers: .command)
                .disabled(!live)
            Button("Zoom to Fit", action: commands.zoomToFit)
                .keyboardShortcut("0", modifiers: .command)
                .disabled(!live)
            Button("Zoom to Selection", action: commands.zoomToSelection)
                .keyboardShortcut("0", modifiers: [.command, .option])
                .disabled(!live || !commands.hasSelection)
        }
    }
}

// MARK: - Playback

/// The transport, which until now had no keyboard anywhere outside the Editor
/// and no menu presence at all — the media keys were the whole story.
struct PlaybackCommands: Commands {
    let env: AppEnvironment

    var body: some Commands {
        CommandMenu("Playback") {
            PlaybackItems(env: env)
            Divider()
            CompareItems(env: env)
        }
    }
}

private struct PlaybackItems: View {
    let env: AppEnvironment
    @FocusedValue(\.editorCommands) private var editor

    var body: some View {
        let actions = ShellActions(env: env)
        let loaded = actions.hasAudioLoaded
        Group {
            Button(actions.isPlaying ? "Pause" : "Play") {
                actions.togglePlayback()
            }
            // ⌃Space, not bare Space. A menu item's shortcut is installed
            // window-wide and fires ahead of the focused control, so a bare
            // Space here would put a space-eating hole in every prompt box,
            // lyrics field and search field in the app. The Editor keeps its
            // own view-local bare Space, which is scoped to that screen.
            .keyboardShortcut(.space, modifiers: .control)
            .disabled(!loaded)

            Button("Stop", action: actions.stopPlayback)
                .keyboardShortcut(".", modifiers: .control)
                .disabled(!loaded)

            Divider()

            // ⌃⌘ arrows, not the plain ⌃ arrows the plan sketched: bare
            // ⌃←/⌃→ are the system's "move one space left/right" and would
            // have been swallowed by Mission Control on a default Mac. ⌥ and
            // ⇧⌘ are both out too — those are word- and line-wise cursor
            // movement, and a menu shortcut fires ahead of the focused
            // control, so either would have broken text editing app-wide.
            Button("Skip Back 5 Seconds") { actions.skip(by: -5) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .control])
                .disabled(!loaded)
            Button("Skip Forward 5 Seconds") { actions.skip(by: 5) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .control])
                .disabled(!loaded)

            Divider()

            Button("Play Selection") { editor?.playSelection() }
                .keyboardShortcut(.space, modifiers: .option)
                .disabled(editor?.hasSelection != true)
            Button("Audition Original") { editor?.toggleOriginal() }
                .disabled(editor?.isEditable != true)
        }
    }
}

private struct CompareItems: View {
    let env: AppEnvironment

    var body: some View {
        let actions = ShellActions(env: env)
        let active = env.shell.compare.isActive
        Group {
            Button(active ? "Stop A/B Compare" : "Start A/B Compare") {
                actions.toggleCompare()
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])
            // Two ticked *songs*. Two parts are not a comparison — the switch
            // plays whole takes against each other at the same position.
            .disabled(!active && actions.comparablePair == nil)

            Button("Switch A/B Side") {
                env.shell.compare.toggle(playback: env.playback)
            }
            .keyboardShortcut(.tab, modifiers: .option)
            .disabled(!active)
        }
    }
}

// MARK: - Track

/// Everything you can do to the track you have picked, in one menu.
///
/// Each item was already a row context-menu entry or a tile on a detail pane;
/// they are the same actions, reached through `ShellActions.songActions` — the
/// bundle those surfaces already use — so a track behaves identically wherever
/// it is acted on.
struct TrackCommands: Commands {
    let env: AppEnvironment

    var body: some Commands {
        CommandMenu("Track") {
            TrackItems(env: env)
        }
    }
}

private struct TrackItems: View {
    let env: AppEnvironment

    var body: some View {
        let actions = ShellActions(env: env)
        // Resolved once and read from throughout — see
        // `ShellActions.ResolvedTarget`. Six items ask about the same row.
        let picked = actions.resolvedTarget
        let target = picked.kind
        Group {
            Button("Edit in Editor\u{2026}", action: actions.editTarget)
                .keyboardShortcut("e", modifiers: .command)
                .disabled(target == .none)

            Button("Rename\u{2026}", action: actions.renameTarget)
                // Songs only: a part is named from its stem and its source,
                // and its inspector has no field to put the caret in.
                .disabled(!actions.canRenameTarget)

            Button(picked.isFavourite ? "Remove from Favourites"
                                      : "Add to Favourites") {
                actions.toggleFavourite()
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
            .disabled(target == .none)

            // ⌃⌘, not the ⌥⌘ the plan first sketched: ⌥⌘1–6 is spent on the
            // Library scopes in the View menu, and two menus quietly claiming
            // one range means whichever loads last wins. ⌃⌘ digits are free
            // both here and on the system.
            Menu("Rating") {
                ForEach(Array((1...5).reversed()), id: \.self) { stars in
                    Button(ShellCommandRouting.ratingTitle(stars)) {
                        actions.rate(stars)
                    }
                    .keyboardShortcut(KeyboardShortcut(
                        KeyEquivalent(Character("\(stars)")),
                        modifiers: [.command, .control]))
                }
                Divider()
                Button(ShellCommandRouting.ratingTitle(0)) { actions.rate(0) }
                    .keyboardShortcut("0", modifiers: [.command, .control])
            }
            .disabled(target == .none)

            Divider()

            SongOnlyItems(env: env, song: picked.song,
                          hasBackup: picked.hasBackup)

            Divider()

            Button("Add to Workbench") {
                guard case .part(let id) = target else { return }
                env.studio.pending = .addToWorkbench(partId: id)
                ShellWindow.focus()
            }
            .disabled(!target.isPart)
        }
    }
}

/// The jumps that only mean something for a whole track. Split out so the
/// enablement is written once against `song` rather than unwrapped per item.
private struct SongOnlyItems: View {
    let env: AppEnvironment
    let song: SongRecord?
    /// Passed in rather than stat-ed here: the parent has already looked, and
    /// a menu body should touch the filesystem once at most.
    let hasBackup: Bool

    var body: some View {
        let actions = ShellActions(env: env)
        let jumps = actions.songActions
        Group {
            Button("Split into Parts\u{2026}") { song.map(jumps.split) }
                .disabled(song == nil)
            Button("Find Matches") { song.map(jumps.findMatches) }
                .disabled(song == nil)
            Button("Describe with a Model\u{2026}") { song.map(jumps.describe) }
                .disabled(song == nil)
            Button("Restyle\u{2026}") { song.map(jumps.restyle) }
                .disabled(song == nil)
            Button("Open Mix in Workbench") { song.map(jumps.openMix) }
                // Only a render was built from a bench, so only a render can
                // be reopened on one.
                .disabled(song?.originKind != .recombined)

            Divider()

            Menu("Reuse") {
                Button(ReuseScope.prompt.title) { song.map(jumps.reusePrompt) }
                Button(ReuseScope.all.title) { song.map(jumps.reuseAll) }
                Button(ReuseScope.allWithSeed.title) {
                    song.map(jumps.reuseAllWithSeed)
                }
                // No recorded seed, nothing to pin — the row menu dims this
                // one for the same reason rather than offering a repeat it
                // cannot make.
                .disabled(song?.seedUsed == nil)
            }
            .disabled(song?.originKind != .generated)

            Button("Play Original") { song.map(jumps.playOriginal) }
                .disabled(!hasBackup)
            Button("Revert to Original\u{2026}") { song.map(jumps.revertEdits) }
                .disabled(!hasBackup)
        }
    }

}

// MARK: - Queue and engine

/// What is rendering, and what is rendering it.
///
/// One menu rather than two: the queue is work the engine is doing, and
/// splitting them put four items in each of two menus that are always read
/// together.
struct QueueCommands: Commands {
    let env: AppEnvironment

    var body: some Commands {
        CommandMenu("Render") {
            RunItem()
            Divider()
            QueueItems(env: env)
            Divider()
            EngineItems(env: env)
        }
    }
}

/// The ⌘↩ both the composer and the Editor already claimed, now visible and
/// named by whichever of them is on screen.
private struct RunItem: View {
    @FocusedValue(\.runCommand) private var run

    var body: some View {
        Button(run?.title ?? "Generate") { run?.run() }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(run?.isEnabled != true)
    }
}

private struct QueueItems: View {
    let env: AppEnvironment

    var body: some View {
        let actions = ShellActions(env: env)
        // Gated projections only — see the note on `ShellCommands`.
        let working = env.jobsStore.isWorking
        let held = env.jobsStore.queueHeld
        let empty = env.jobsStore.queueEmpty && env.downloadsStore.transfersEmpty
        Group {
            Button("Cancel Current Render", role: .destructive) {
                actions.cancelCurrentRender()
            }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(!working)

            Button(held ? "Resume All" : "Pause All",
                   action: actions.toggleQueueHold)
                .disabled(empty && !held)

            Button("Clear Finished", action: actions.clearFinished)
                .disabled(empty)

            Button("Show Latest Render in Library",
                   action: actions.showLatestRender)
                // Gated on the queue holding anything at all rather than on
                // there being a produced take: finding that out means reading
                // the ordered job list, which is not a thing to do from a menu
                // body. An empty queue is the honest cheap answer, and the
                // action guards itself.
                .disabled(empty)
        }
    }
}

private struct EngineItems: View {
    let env: AppEnvironment

    var body: some View {
        let actions = ShellActions(env: env)
        Group {
            Menu("Engine") {
                // Disabled on purpose — a readout, not a control. It is the
                // one fact Settings is most often opened just to check.
                Button(actions.engineSummary) {}
                    .disabled(true)
                Divider()
                Button("Restart Engine", action: actions.restartEngine)
                Button("Unload Worker Model", action: actions.unloadWorker)
                    // Nothing loaded, nothing to drop.
                    .disabled(env.backendStatus.workerModelId == nil)
                Divider()
                Button("Open Engine Logs", action: actions.openEngineLogs)
                Button("Copy Engine Log", action: actions.copyEngineLog)
            }
        }
    }
}

// MARK: - Help

/// The three buried buttons in Settings that are really "help me get my
/// bearings", plus the way back to the files.
struct HelpCommands: Commands {
    let env: AppEnvironment

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Show Welcome Tour") {
                // Both: the stored stamp is cleared so the tour is offered
                // again on its own terms, and the sheet is opened now, because
                // somebody who chose the item wants to see it now.
                env.settings.showWelcomeAgain()
                env.shell.showOnboarding = true
                ShellWindow.focus()
            }
            Button("Reset Dismissed Hints") { env.settings.resetDismissedHints() }
            Divider()
            Button("Reveal Data Folder in Finder") {
                ShellActions(env: env).revealDataFolder()
            }
        }
    }
}

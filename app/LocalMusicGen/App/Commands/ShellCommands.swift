// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// The whole menubar, assembled.
///
/// Split into one `Commands` conformer per menu below, and gathered here so
/// `LocalMusicGenApp.body` reads as a scene rather than as a menu definition.
///
/// Three rules run through all of them.
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
///
/// **Every key comes from `ShortcutCatalog`.** Not because a literal would be
/// wrong, but because Help ▸ Keyboard Shortcuts draws the same table — a
/// reference sheet that is a second hand-written copy of forty bindings starts
/// lying the first time one of them moves.
struct ShellCommands: Commands {
    let env: AppEnvironment

    var body: some Commands {
        AppInfoCommands(env: env)
        FileCommands(env: env)
        EditCommands(env: env)
        ViewCommands(env: env)
        PlaybackCommands(env: env)
        TrackCommands(env: env)
        AudioCommands()
        QueueCommands(env: env)
        HelpCommands(env: env)
    }
}

// MARK: - About

/// The standard About panel, with the engine in it.
///
/// The stock item is already right about the icon, the name and the copyright;
/// what it was missing is the one fact this app gets asked about — which
/// engine is running, on which port, having restarted how many times.
struct AppInfoCommands: Commands {
    let env: AppEnvironment

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About LocalMusicGen") { ShellActions(env: env).showAbout() }
            #if SPARKLE
            SparkleCheckForUpdatesButton()
            #endif
        }
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
            Button(ShortcutCatalog.importAudio.title) { actions.importAudio() }
                .keyboardShortcut(ShortcutCatalog.importAudio.shortcut)
            Button(ShortcutCatalog.importFolder.title) { actions.importFolder() }
                .keyboardShortcut(ShortcutCatalog.importFolder.shortcut)
            Button(ShortcutCatalog.addModel.title) {
                // To Models first: the sheet is presented by that screen, so
                // raising the flag from anywhere else would set a boolean
                // nothing was watching. Going there is the right behaviour
                // regardless — a model added from the menubar lands in the
                // list you are then looking at.
                env.shell.openModels(for: nil)
                env.shell.showAddModel = true
            }
            .keyboardShortcut(ShortcutCatalog.addModel.shortcut)
        }
        CommandGroup(after: .saveItem) {
            ExportItem(env: env)
            ExportCheckedItem(env: env)
            Divider()
            RevealItem(env: env)
            RevealBackupItem(env: env)
            Divider()
            CloseEditorItem(env: env)
            Divider()
            DeleteItem(env: env)
            DeleteCheckedItem(env: env)
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
        .keyboardShortcut(ShortcutCatalog.export.shortcut)
        .disabled(editor?.isEditable != true && picked.kind == .none)
    }

    private func title(_ picked: ShellActions.ResolvedTarget) -> String {
        if editor?.isEditable == true { return "Export Selection\u{2026}" }
        guard let name = picked.title else { return "Export\u{2026}" }
        return "Export \u{201C}\(name)\u{201D}\u{2026}"
    }
}

/// The ticked rows, into one folder. Named with its count, because "Export
/// Selected Tracks" beside a Delete item is worth being unambiguous about.
private struct ExportCheckedItem: View {
    let env: AppEnvironment

    var body: some View {
        let count = env.shell.checked.count
        Button(count > 1 ? "Export \(count) Tracks\u{2026}"
                         : "Export Selected Tracks\u{2026}") {
            ShellActions(env: env).exportChecked()
        }
        .keyboardShortcut(ShortcutCatalog.exportSelected.shortcut)
        .disabled(count == 0)
    }
}

private struct RevealItem: View {
    let env: AppEnvironment
    @FocusedValue(\.editorCommands) private var editor

    var body: some View {
        let actions = ShellActions(env: env)
        let editorReveal = editor?.reveal
        Button(ShortcutCatalog.reveal.title) {
            if let editorReveal { editorReveal() }
            else { actions.revealTarget() }
        }
        .keyboardShortcut(ShortcutCatalog.reveal.shortcut)
        .disabled(editorReveal == nil && actions.resolvedTarget.fileURL == nil)
    }
}

/// The stashed pre-edit original. Its own item rather than a mode of the one
/// above: they are two different files, and which one you want is not
/// something a menu can infer from where you are standing.
private struct RevealBackupItem: View {
    let env: AppEnvironment

    var body: some View {
        let actions = ShellActions(env: env)
        Button("Reveal Backup in Finder") { actions.revealBackup() }
            .disabled(actions.backupURL == nil)
    }
}

private struct CloseEditorItem: View {
    let env: AppEnvironment

    var body: some View {
        Button(ShortcutCatalog.closeEditor.title) {
            env.editor.close()
            env.shell.go(to: .library)
        }
        .keyboardShortcut(ShortcutCatalog.closeEditor.shortcut)
        // Not `isCommandable`: closing is exactly what you want to do while a
        // render has the document frozen, and the Editor's own ✕ allows it.
        .disabled(env.editor.material == nil)
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
        // ⇧⌘⌫. Not the bare Delete the Editor uses for its selection — that
        // one removes a slice of audio from a program you can undo, and this
        // one removes a file from the disk — and deliberately not the Finder's
        // ⌘⌫ either, which AppKit has already given to
        // `deleteToBeginningOfLine:`. See `ShortcutCatalog.delete`.
        .keyboardShortcut(ShortcutCatalog.delete.shortcut)
        .disabled(picked.kind == .none)
    }

    private func title(_ picked: ShellActions.ResolvedTarget) -> String {
        guard let name = picked.title else { return "Delete\u{2026}" }
        return "Delete \u{201C}\(name)\u{201D}\u{2026}"
    }
}

private struct DeleteCheckedItem: View {
    let env: AppEnvironment

    var body: some View {
        let count = env.shell.checked.count
        Button(count == 0
                ? "Delete Ticked Rows\u{2026}"
                : "Delete \(count) Ticked \(count == 1 ? "Row" : "Rows")\u{2026}",
               role: .destructive) {
            ShellActions(env: env).requestDeleteChecked()
        }
        .disabled(count == 0)
    }
}

// MARK: - Edit

/// The menu macOS users reach for on reflex, made true.
///
/// Undo, Redo and the whole clipboard block are left to the stock items.
/// `EditorStore` registers with the window's own `UndoManager` and names each
/// step, so the system items already read "Undo Trim" and already dim
/// correctly; Cut, Copy, Paste, Delete and Select All are the standard
/// first-responder items, which is the only way ⌘X/⌘C/⌘V/⌘A work in a text
/// field at all — AppKit has no key bindings for them, just the menu, so an
/// app that replaces those items takes the shortcuts away from every field it
/// owns. The Editor is served from the responder chain instead; see
/// `AppDelegate`'s pasteboard actions.
///
/// What is added is the *row* selection, which has no responder at all: the
/// ticked set is shell state, and ⌘A deliberately stays with the first
/// responder rather than being stolen for it.
struct EditCommands: Commands {
    let env: AppEnvironment

    var body: some Commands {
        CommandGroup(replacing: .textEditing) {
            FindItem()
            Divider()
            RowSelectionItems(env: env)
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
        .keyboardShortcut(ShortcutCatalog.find.shortcut)
        .disabled(search == nil)
    }
}

private struct RowSelectionItems: View {
    let env: AppEnvironment

    var body: some View {
        let actions = ShellActions(env: env)
        let inLibrary = env.shell.destination == .library
        Group {
            Button(ShortcutCatalog.selectAllRows.title) {
                actions.selectAllRows()
            }
            .keyboardShortcut(ShortcutCatalog.selectAllRows.shortcut)
            .disabled(!inLibrary)

            Button(ShortcutCatalog.clearSelection.title) {
                actions.clearRowSelection()
            }
            .keyboardShortcut(ShortcutCatalog.clearSelection.shortcut)
            .disabled(env.shell.checked.isEmpty)
        }
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
            ActionsRouteItems(env: env)
            Divider()
            PanelItems(env: env)
            Divider()
            ZoomItems()
            Divider()
            LibraryViewMenu(env: env)
            ScreenViewMenus(env: env)
            Divider()
        }
    }
}

private struct GoItems: View {
    @Bindable var shell: ShellState

    var body: some View {
        Group {
            ForEach(Destination.allCases) { destination in
                Button(destination.title) {
                    // Library is the one destination with places inside it, and
                    // going *there* means all of it — the same thing clicking
                    // the sidebar row does, so the key and the row cannot
                    // disagree about where they land. Anything wanting a slice
                    // asks for the slice, from the submenu below or the row.
                    if destination == .library {
                        shell.go(to: LibraryScope.all)
                    } else {
                        shell.go(to: destination)
                    }
                }
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

/// Getting back out of an Actions page, and back into one you have run.
private struct ActionsRouteItems: View {
    let env: AppEnvironment
    /// The recently-run recipes, decoded from the same log the gallery's
    /// "Recently used" shelf reads.
    @AppStorage("actions.lastRuns") private var runsJSON = "{}"

    var body: some View {
        let shell = env.shell
        Group {
            Button(ShortcutCatalog.backToGallery.title) {
                shell.actionsRoute = nil
                shell.go(to: .actions)
            }
            .keyboardShortcut(ShortcutCatalog.backToGallery.shortcut)
            // The Esc the page already honours, made visible. Dimmed on the
            // gallery itself, where there is nothing to come back from.
            .disabled(shell.actionsRoute == nil)

            Menu("Recent Actions") {
                let recent = ActionRunLog.decoded(runsJSON).recentRecipeIds
                    .compactMap { RecipeCatalog.recipe(id: $0) }
                    .prefix(8)
                ForEach(Array(recent)) { recipe in
                    Button(recipe.name) {
                        shell.actionsRoute = .action(recipeId: recipe.id,
                                                     sourceId: nil)
                        shell.go(to: .actions)
                    }
                }
                if recent.isEmpty {
                    Button("Nothing yet") {}.disabled(true)
                }
            }
        }
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
            .keyboardShortcut(ShortcutCatalog.toggleSidebar.shortcut)
            // Cramped, not merely collapsed: a window too narrow to hold the
            // sidebar has put it away on the user's behalf, and an item
            // offering to bring it back cannot keep that promise.
            .disabled(shell.sidebarCramped)

            Button(ShellCommandRouting
                .queueItemTitle(isOpen: shell.queuePanel.isOpen)) {
                actions.toggleQueuePanel()
            }
            .keyboardShortcut(ShortcutCatalog.toggleQueue.shortcut)

            Toggle("Pin Queue Panel", isOn: Binding(
                get: { shell.queueIsPinned },
                set: { actions.setQueuePinned($0) }))
        }
    }
}

/// The four zoom items, aimed at whichever ruler is on screen — the Editor's
/// waveform or the Workbench's timeline. Both publish `ZoomCommands`; before
/// that these were the Editor's alone and ⌘+ did nothing on the bench.
private struct ZoomItems: View {
    @FocusedValue(\.zoomCommands) private var zoom

    var body: some View {
        let commands = zoom ?? ZoomCommands()
        let live = zoom != nil
        Group {
            Button(ShortcutCatalog.zoomIn.title, action: commands.zoomIn)
                .keyboardShortcut(ShortcutCatalog.zoomIn.shortcut)
                .disabled(!live)
            Button(ShortcutCatalog.zoomOut.title, action: commands.zoomOut)
                .keyboardShortcut(ShortcutCatalog.zoomOut.shortcut)
                .disabled(!live)
            Button(ShortcutCatalog.zoomToFit.title, action: commands.zoomToFit)
                .keyboardShortcut(ShortcutCatalog.zoomToFit.shortcut)
                .disabled(!live)
            Button(ShortcutCatalog.zoomToSelection.title,
                   action: commands.zoomToSelection)
                .keyboardShortcut(ShortcutCatalog.zoomToSelection.shortcut)
                .disabled(!live || !commands.canZoomToSelection)
        }
    }
}

/// How the Library lists what it is showing: the order, the narrowing, and
/// whether parts are gathered under their song.
///
/// A submenu rather than nine more items in View: they are one screen's
/// controls, and they dim together when you are not on it.
private struct LibraryViewMenu: View {
    let env: AppEnvironment

    var body: some View {
        let actions = ShellActions(env: env)
        let library = env.library
        let shell = env.shell
        Menu("Library View") {
            Menu("Sort By") {
                ForEach(LibraryRepository.Sort.allCases, id: \.self) { sort in
                    // The filter bar writes these lower-case inside
                    // "Sort: newest"; a menu item is a label of its own.
                    Toggle(LibraryScreen.label(for: sort).capitalized,
                           isOn: Binding(
                        get: { library.filters.sort == sort },
                        set: { _ in actions.setLibrarySort(sort) }))
                }
            }
            Menu("Filter") {
                Toggle("Favourites Only", isOn: Binding(
                    get: { library.filters.favoritesOnly },
                    set: { library.filters.favoritesOnly = $0 }))
                Toggle("Has Parts", isOn: Binding(
                    get: { library.filters.hasParts },
                    set: { library.filters.hasParts = $0 }))
                Toggle("Has Edits", isOn: Binding(
                    get: { library.filters.hasEdits },
                    set: { library.filters.hasEdits = $0 }))
                Divider()
                Button("Clear Filters") { actions.clearLibraryFilters() }
            }
            Toggle("Group Parts by Song", isOn: Binding(
                get: { shell.libraryGroupsParts },
                set: { shell.libraryGroupsParts = $0 }))
        }
        // The screen puts its filters back on the way out — a scope is a
        // filter set — so an item that changed them from elsewhere would be
        // undone before it could be seen.
        .disabled(shell.destination != .library)
    }
}

/// The display switches that belong to one screen's canvas rather than to the
/// window: the Editor's waveform, the bench's two lenses, the model list's
/// disclosure.
private struct ScreenViewMenus: View {
    let env: AppEnvironment
    @FocusedValue(\.editorAudioCommands) private var audio
    @AppStorage("workbench.lens") private var lens: WorkbenchLens = .rows
    @AppStorage("models.showAll") private var showAllModels = false

    var body: some View {
        let commands = audio ?? EditorAudioCommands()
        Group {
            Menu("Waveform") {
                Toggle("Show Beat Grid", isOn: Binding(
                    get: { commands.showBeatGrid },
                    set: commands.setBeatGrid))
                Toggle("Show Channels Separately", isOn: Binding(
                    get: { commands.stereoView },
                    set: commands.setStereoView))
            }
            .disabled(audio == nil)

            Menu("Workbench Lens") {
                ForEach(WorkbenchLens.allCases) { candidate in
                    Toggle(candidate.rawValue, isOn: Binding(
                        get: { lens == candidate },
                        set: { _ in lens = candidate }))
                }
            }
            .disabled(env.shell.destination != .workbench)

            Menu("Model List") {
                Toggle("Show All Models", isOn: $showAllModels)
                Toggle("Only Installed", isOn: Binding(
                    get: { env.catalog.onlyInstalledFilter },
                    set: { env.catalog.onlyInstalledFilter = $0 }))
            }
            .disabled(env.shell.destination != .models)
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
            VolumeItems(env: env)
            Divider()
            CompareItems(env: env)
        }
    }
}

private struct PlaybackItems: View {
    let env: AppEnvironment
    @FocusedValue(\.editorCommands) private var editor
    @FocusedValue(\.editorAudioCommands) private var audio

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
            .keyboardShortcut(ShortcutCatalog.playPause.shortcut)
            .disabled(!loaded)

            Button("Stop", action: actions.stopPlayback)
                .keyboardShortcut(ShortcutCatalog.stop.shortcut)
                .disabled(!loaded)

            Divider()

            // ⌃⌘ arrows, not the plain ⌃ arrows the plan sketched: bare
            // ⌃←/⌃→ are the system's "move one space left/right" and would
            // have been swallowed by Mission Control on a default Mac. ⌥ and
            // ⇧⌘ are both out too — those are word- and line-wise cursor
            // movement, and a menu shortcut fires ahead of the focused
            // control, so either would have broken text editing app-wide.
            Button(ShortcutCatalog.skipBack.title) { actions.skip(by: -5) }
                .keyboardShortcut(ShortcutCatalog.skipBack.shortcut)
                .disabled(!loaded)
            Button(ShortcutCatalog.skipForward.title) { actions.skip(by: 5) }
                .keyboardShortcut(ShortcutCatalog.skipForward.shortcut)
                .disabled(!loaded)
            Button(ShortcutCatalog.goToStart.title, action: actions.seekToStart)
                .keyboardShortcut(ShortcutCatalog.goToStart.shortcut)
                .disabled(!loaded)
            Button(ShortcutCatalog.goToEnd.title, action: actions.seekToEnd)
                .keyboardShortcut(ShortcutCatalog.goToEnd.shortcut)
                .disabled(!loaded)

            Divider()

            Button("Play Selection") { editor?.playSelection() }
                .keyboardShortcut(ShortcutCatalog.playSelection.shortcut)
                .disabled(editor?.hasSelection != true)
            Toggle("Loop Selection", isOn: Binding(
                get: { audio?.loopSelection ?? false },
                set: { audio?.setLoopSelection($0) }))
                .keyboardShortcut(ShortcutCatalog.loopSelection.shortcut)
                .disabled(audio?.isEditable != true)
            Button("Audition Original") { editor?.toggleOriginal() }
                .disabled(editor?.isEditable != true)

            Divider()

            Button(ShortcutCatalog.showNowPlaying.title,
                   action: actions.showNowPlaying)
                .keyboardShortcut(ShortcutCatalog.showNowPlaying.shortcut)
                .disabled(actions.nowPlayingSongId == nil)
        }
    }
}

/// The app's own level. New capability rather than a promotion: nothing in the
/// app could change the volume before, and the system's own key does not know
/// this app from the browser tab behind it.
private struct VolumeItems: View {
    let env: AppEnvironment

    var body: some View {
        let actions = ShellActions(env: env)
        Group {
            // A readout, not a control — the same trick the engine summary
            // plays, and the reason the two items below need no numbers in
            // their titles.
            Button(actions.volumeSummary) {}.disabled(true)
            Button(ShortcutCatalog.volumeUp.title) {
                actions.adjustVolume(by: PlaybackController.volumeStep)
            }
            .keyboardShortcut(ShortcutCatalog.volumeUp.shortcut)
            .disabled(env.playback.volume >= 1 && !env.playback.isMuted)
            Button(ShortcutCatalog.volumeDown.title) {
                actions.adjustVolume(by: -PlaybackController.volumeStep)
            }
            .keyboardShortcut(ShortcutCatalog.volumeDown.shortcut)
            .disabled(env.playback.volume <= 0)
            Toggle("Mute", isOn: Binding(
                get: { env.playback.isMuted },
                set: { _ in actions.toggleMute() }))
                .keyboardShortcut(ShortcutCatalog.mute.shortcut)
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
            .keyboardShortcut(ShortcutCatalog.compare.shortcut)
            // Two ticked *songs*. Two parts are not a comparison — the switch
            // plays whole takes against each other at the same position.
            .disabled(!active && actions.comparablePair == nil)

            Button("Switch A/B Side") {
                env.shell.compare.toggle(playback: env.playback)
            }
            .keyboardShortcut(ShortcutCatalog.switchSide.shortcut)
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
            Divider()
            CopyItems(env: env)
            Divider()
            CheckedItems(env: env)
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
        // Show Notation's song and whether it has any, off the same snapshot.
        let notationSongId = ShellCommandRouting.notationSongId(
            song: picked.song, part: picked.part)
        let hasNotation = notationSongId.map {
            env.textStore.hasDoc(ownerId: $0, kind: .abc)
        } ?? false
        Group {
            Button("Edit in Editor\u{2026}", action: actions.editTarget)
                .keyboardShortcut(ShortcutCatalog.editInEditor.shortcut)
                .disabled(target == .none)

            Button("Rename\u{2026}", action: actions.renameTarget)
                // Songs only: a part is named from its stem and its source,
                // and its inspector has no field to put the caret in.
                .disabled(!actions.canRenameTarget)

            Button("Edit Notes\u{2026}", action: actions.editTargetNotes)
                .disabled(!actions.canRenameTarget)

            Button(picked.isFavourite ? "Remove from Favourites"
                                      : "Add to Favourites") {
                actions.toggleFavourite()
            }
            .keyboardShortcut(ShortcutCatalog.favourite.shortcut)
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

            // Enabled from a part row too: notation is filed on the song a
            // part came from, and `MainWindow` hosts the sheet, so no pane
            // has to be on screen for the item to work. No shortcut — the
            // catalogue is deliberately small, and keys are the owner's call.
            Button("Show Notation") {
                actions.showNotation(songId: notationSongId)
            }
            .disabled(!hasNotation)
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

/// What a track knows, onto the pasteboard. All three were readable in the
/// inspector and selectable nowhere — a prompt is text you want back, and
/// re-typing forty words off a detail pane is not a workflow.
private struct CopyItems: View {
    let env: AppEnvironment

    var body: some View {
        let actions = ShellActions(env: env)
        // One read for the three of them: `targetPrompt` and `targetSeed`
        // each resolve the row on their own, and a menu body asking the
        // database the same question three times is the trap
        // `ResolvedTarget` exists to close.
        let picked = actions.resolvedTarget
        Group {
            Button("Copy Prompt", action: actions.copyPrompt)
                .keyboardShortcut(ShortcutCatalog.copyPrompt.shortcut)
                .disabled(picked.song?.prompt.trimmingCharacters(
                    in: .whitespacesAndNewlines).isEmpty ?? true)
            Button("Copy Seed", action: actions.copySeed)
                .disabled(picked.song?.seedUsed == nil)
            Button("Copy Track Details", action: actions.copyTrackDetails)
                .disabled(picked.kind == .none)
        }
    }
}

/// The ticked rows, as a submenu — the selection inspector's actions, reached
/// without having to be looking at the inspector.
private struct CheckedItems: View {
    let env: AppEnvironment

    var body: some View {
        let actions = ShellActions(env: env)
        let count = env.shell.checked.count
        Menu(count > 0 ? "\(count) Ticked \(count == 1 ? "Row" : "Rows")"
                       : "Ticked Rows") {
            Button("Favourite / Unfavourite All") {
                actions.toggleCheckedFavourite()
            }
            Menu("Rate All") {
                ForEach(Array((1...5).reversed()), id: \.self) { stars in
                    Button(ShellCommandRouting.ratingTitle(stars)) {
                        actions.rateChecked(stars)
                    }
                }
                Divider()
                Button(ShellCommandRouting.ratingTitle(0)) {
                    actions.rateChecked(0)
                }
            }
            Divider()
            Button("Add Parts to Workbench") {
                actions.addCheckedToWorkbench()
            }
            .disabled(!actions.canAddCheckedToBench)
            Button("Tag All\u{2026}") {
                actions.openBatchAction(recipeId: "tag-library")
            }
            Button("Split All\u{2026}") {
                actions.openBatchAction(recipeId: "batch-split")
            }
            Divider()
            Button("Clear Selection", action: actions.clearRowSelection)
        }
        .disabled(count == 0)
    }
}

// MARK: - Audio

/// The Editor's operations — the one genuinely large gap the first menubar
/// left. Twenty-odd verbs that were toolbar buttons, rail sliders and a `···`
/// overflow, none of which the menubar could see.
///
/// A menu of its own rather than a section of Edit: Edit is the clipboard menu
/// macOS owns, and these are what the app does to a waveform. Every item dims
/// together when the Editor is not the screen you are on, which is the same
/// contract the zoom items keep.
///
/// The bench's clip verbs sit at the bottom for the same reason they are here
/// rather than in Track: this is the menu for the material you are working on,
/// and one of the two screens that has any is always the one dimmed.
struct AudioCommands: Commands {
    var body: some Commands {
        CommandMenu("Audio") {
            SelectionSurgeryItems()
            Divider()
            SelectionShapeItems()
            Divider()
            LevelItems()
            Divider()
            EffectItems()
            Divider()
            SendItems()
            Divider()
            BenchItems()
        }
    }
}

/// The Workbench's clip operations, which had no menu presence because the
/// bench had no lifted selection when the menubar was first built. It has one
/// now — the cards and the timeline share it — so the four clip verbs and the
/// two whole-bench ones can be reached from here.
private struct BenchItems: View {
    @FocusedValue(\.workbenchCommands) private var bench

    var body: some View {
        let commands = bench ?? WorkbenchCommands()
        let live = bench != nil
        Menu("Bench") {
            Button("Add Part\u{2026}", action: commands.addPart)
            Divider()
            Button("Duplicate Clip", action: commands.duplicate)
                .disabled(!commands.hasSelection)
            Button("Split Clip into Sections", action: commands.explode)
                // Sections come from Musical analysis; a clip nobody has
                // analysed has nothing to split on, which is what the
                // timeline's own item says in its tooltip.
                .disabled(!commands.canExplode)
            Button("Crossfade with Neighbour", action: commands.crossfade)
                .disabled(!commands.canCrossfade)
            Button("Remove Clip", role: .destructive, action: commands.remove)
                .disabled(!commands.hasSelection)
            Divider()
            Button("Pull Everything to Bar 1", action: commands.pullToStart)
                .disabled(!commands.hasClips)
            Button("Clear the Bench", role: .destructive,
                   action: commands.clearBench)
                .disabled(!commands.hasLanes)
        }
        .disabled(!live)
    }
}

private struct SelectionSurgeryItems: View {
    @FocusedValue(\.editorAudioCommands) private var audio

    var body: some View {
        let commands = audio ?? EditorAudioCommands()
        let live = commands.isEditable
        let selected = live && commands.hasSelection
        Group {
            Button(ShortcutCatalog.trim.title, action: commands.trim)
                .keyboardShortcut(ShortcutCatalog.trim.shortcut)
                .disabled(!selected)
            Button("Silence Selection", action: commands.silence)
                .disabled(!selected)
            Button("Delete Selection", role: .destructive,
                   action: commands.deleteSelection)
                .disabled(!selected)
            Button("Reverse Selection", action: commands.reverse)
                .disabled(!selected)

            Divider()

            Button(ShortcutCatalog.splitAtPlayhead.title,
                   action: commands.splitAtPlayhead)
                .keyboardShortcut(ShortcutCatalog.splitAtPlayhead.shortcut)
                .disabled(!live)
            Button(ShortcutCatalog.insertGap.title, action: commands.insertGap)
                .keyboardShortcut(ShortcutCatalog.insertGap.shortcut)
                .disabled(!live)
        }
    }
}

/// Where a selection's edges land, and the two ways of finding them for you.
private struct SelectionShapeItems: View {
    @FocusedValue(\.editorAudioCommands) private var audio

    var body: some View {
        let commands = audio ?? EditorAudioCommands()
        let live = commands.isEditable
        let selected = live && commands.hasSelection
        Group {
            Menu("Auto-Trim Silence") {
                ForEach(EditorStore.autoTrimThresholdsDb, id: \.self) { db in
                    Button(String(format: "Below %.0f dB", db)) {
                        commands.autoTrim(db)
                    }
                }
            }
            .disabled(!live)

            Button("Snap Selection to Section", action: commands.snapToSection)
                .disabled(!selected)
            Button("Refine Selection to Zero Crossings",
                   action: commands.refineToZeroCrossings)
                .disabled(!selected)

            Menu("Snap To") {
                ForEach(EditorGeometry.SnapMode.allCases) { mode in
                    Toggle(mode.label, isOn: Binding(
                        get: { commands.snapMode == mode },
                        set: { _ in commands.setSnapMode(mode) }))
                }
            }
            .disabled(!live)
        }
    }
}

/// Fades, level and the two whole-track transforms.
private struct LevelItems: View {
    @FocusedValue(\.editorAudioCommands) private var audio

    var body: some View {
        let commands = audio ?? EditorAudioCommands()
        let live = commands.isEditable
        Group {
            Button("Fade In from Start", action: commands.fadeIn)
                .disabled(!live)
            Button("Fade Out at End", action: commands.fadeOut)
                .disabled(!live)
            Toggle("Normalise Whole Track", isOn: Binding(
                get: { commands.isNormalized },
                set: commands.setNormalized))
                .disabled(!live)

            Menu("Amplify Selection") {
                ForEach([6.0, 3.0, 1.0, -1.0, -3.0, -6.0], id: \.self) { db in
                    Button(String(format: "%+.0f dB", db)) {
                        commands.amplify(db)
                    }
                }
                Divider()
                Button("Reset to 0 dB") { commands.amplify(-commands.amplifyDb) }
            }
            .disabled(!live || !commands.hasSelection)

            Menu("Speed") {
                ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                    Toggle(String(format: "%.2f\u{00D7}", rate), isOn: Binding(
                        get: { abs(commands.speedRate - rate) < 0.005 },
                        set: { _ in commands.setSpeed(rate) }))
                }
            }
            .disabled(!live)

            Menu("Pitch") {
                ForEach([12.0, 7.0, 5.0, 2.0, 1.0, -1.0, -2.0, -5.0, -7.0,
                         -12.0], id: \.self) { semitones in
                    Button(String(format: "%+.0f st", semitones)) {
                        commands.setPitch(semitones)
                    }
                }
                Divider()
                Button("Reset to Original Pitch") { commands.setPitch(0) }
            }
            .disabled(!live)

            Menu("Resample") {
                Toggle("Same as Source", isOn: Binding(
                    get: { commands.resampleHz == nil },
                    set: { _ in commands.setResample(nil) }))
                Divider()
                ForEach([44_100, 48_000, 96_000], id: \.self) { hz in
                    Toggle("\(hz.formatted(.number)) Hz", isOn: Binding(
                        get: { commands.resampleHz == hz },
                        set: { _ in commands.setResample(hz) }))
                }
            }
            .disabled(!live)
        }
    }
}

private struct EffectItems: View {
    @FocusedValue(\.editorAudioCommands) private var audio

    var body: some View {
        let commands = audio ?? EditorAudioCommands()
        let live = commands.isEditable
        Group {
            Menu("Add Effect") {
                ForEach(EffectSetting.Kind.allCases, id: \.self) { kind in
                    Button(kind.label) { commands.addEffect(kind) }
                }
            }
            .disabled(!live)

            Button(commands.allEffectsEnabled ? "Disable All Effects"
                                              : "Enable All Effects") {
                commands.setAllEffects(!commands.allEffectsEnabled)
            }
            .disabled(!live || !commands.hasEffects)

            Toggle("Crossfade Joins", isOn: Binding(
                get: { commands.crossfadeJoins },
                set: commands.setCrossfadeJoins))
                .disabled(!live)

            Button("Clear All Edits", role: .destructive,
                   action: commands.clearAllEdits)
                .disabled(!live || !commands.isDirty)
        }
    }
}

/// The three places a selection can be sent onward, from the rail that offers
/// them. Each renders the selection first, so they need one.
private struct SendItems: View {
    @FocusedValue(\.editorAudioCommands) private var audio

    var body: some View {
        let commands = audio ?? EditorAudioCommands()
        let selected = commands.isEditable && commands.hasSelection
        Menu("Send Selection To") {
            Button("Generate \u{2014} Continue from Here") {
                commands.send(.continueFrom)
            }
            Button("Split Just This Region") { commands.send(.splitRegion) }
            Button("Find Matches for This") { commands.send(.findMatches) }
        }
        .disabled(!selected)
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
            ReimagineItem()
            Divider()
            QueueItems(env: env)
            Divider()
            DownloadItems(env: env)
            Divider()
            EngineItems(env: env)
        }
    }
}

/// The ⌘↩ the composer, the Editor, Style Transfer and the bench all claim,
/// named by whichever of them is on screen.
///
/// The last two publish `RunCommand` now; before that ⌘↩ was silently dead on
/// both, and the item read "Generate" while you were looking at a bench.
private struct RunItem: View {
    @FocusedValue(\.runCommand) private var run

    var body: some View {
        Button(run?.title ?? "Generate") { run?.run() }
            .keyboardShortcut(ShortcutCatalog.run.shortcut)
            .disabled(run?.isEnabled != true)
    }
}

/// The bench's other output — a model rewriting the arrangement rather than
/// the mixer rendering it. Its own item because it is a different act with a
/// different gate, not a mode of the one above.
private struct ReimagineItem: View {
    @FocusedValue(\.workbenchCommands) private var bench

    var body: some View {
        Button("Reimagine") { bench?.reimagine() }
            .keyboardShortcut(ShortcutCatalog.reimagine.shortcut)
            .disabled(bench?.canReimagine != true)
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
            .keyboardShortcut(ShortcutCatalog.cancelRender.shortcut)
            .disabled(!working)

            Button("Cancel All Renders", role: .destructive) {
                actions.cancelAllRenders()
            }
            .keyboardShortcut(ShortcutCatalog.cancelAllRenders.shortcut)
            .disabled(!working)

            Button(held ? "Resume All" : "Pause All",
                   action: actions.toggleQueueHold)
                .disabled(empty && !held)

            Button("Clear Finished", action: actions.clearFinished)
                .disabled(empty)

            Divider()

            Button("Notify When This Render Lands",
                   action: actions.armCurrentRender)
                .disabled(!working)
            Button("Copy Render Log", action: actions.copyRenderLog)
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

/// Transfers, which share the queue rail with renders but not their controls:
/// Pause All above pauses both, and these three are for the times when it is
/// the download you want stopped and the render you want left alone.
private struct DownloadItems: View {
    let env: AppEnvironment

    var body: some View {
        let actions = ShellActions(env: env)
        let noTransfers = env.downloadsStore.transfersEmpty
        Menu("Downloads") {
            Button("Pause All Downloads", action: actions.pauseAllDownloads)
                .disabled(noTransfers)
            Button("Resume All Downloads", action: actions.resumeAllDownloads)
                .disabled(noTransfers)
            Button("Clear Finished Downloads",
                   action: actions.clearFinishedDownloads)
                .disabled(noTransfers)
        }
    }
}

private struct EngineItems: View {
    let env: AppEnvironment

    var body: some View {
        let actions = ShellActions(env: env)
        Group {
            Button(ShortcutCatalog.refreshCatalog.title,
                   action: actions.refreshCatalog)
                .keyboardShortcut(ShortcutCatalog.refreshCatalog.shortcut)

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
                Button("Verify Model Library", action: actions.verifyModelLibrary)
                Button("Reveal Model Library in Finder",
                       action: actions.revealModelLibrary)
                Divider()
                Button("Open Engine Logs", action: actions.openEngineLogs)
                Button("Copy Engine Log", action: actions.copyEngineLog)
                Button("Copy Diagnostics", action: actions.copyDiagnostics)
            }
        }
    }
}

// MARK: - Help

/// The buried buttons in Settings that are really "help me get my bearings",
/// the way back to the files, and — new — the reference sheet.
struct HelpCommands: Commands {
    let env: AppEnvironment

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button(ShortcutCatalog.shortcuts.title) {
                env.shell.showShortcuts = true
                ShellWindow.focus()
            }
            .keyboardShortcut(ShortcutCatalog.shortcuts.shortcut)
            Divider()
            Button("Show Welcome Tour") {
                // Both: the stored stamp is cleared so the tour is offered
                // again on its own terms, and the sheet is opened now, because
                // somebody who chose the item wants to see it now.
                env.settings.showWelcomeAgain()
                env.shell.showOnboarding = true
                ShellWindow.focus()
            }
            Button("Reset Dismissed Hints") { env.settings.resetDismissedHints() }
            Button("Clear Recent Actions") { env.settings.clearRecentActions() }
            Divider()
            Button("Reveal Data Folder in Finder") {
                ShellActions(env: env).revealDataFolder()
            }
            Button("Reveal Model Library in Finder") {
                ShellActions(env: env).revealModelLibrary()
            }
            Button("Open App Logs") {
                ShellActions(env: env).openAppLogs()
            }
        }
    }
}

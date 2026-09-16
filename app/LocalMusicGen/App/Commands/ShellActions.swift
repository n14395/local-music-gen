import AppKit
import Foundation
import SwiftUI

/// What the menubar does, in one place the window can share.
///
/// Every item in the Track menu already existed as a row context-menu button
/// or a tile on the detail pane. The point of this type is that they stay
/// *one* action rather than becoming two implementations that drift: the menu
/// and the row both go through here, and `songActions` — the bundle the
/// Library, the queue and every screen already pass around — is now built here
/// too rather than inside `MainWindow`.
///
/// A struct over a stored `AppEnvironment` rather than an object of its own:
/// it holds no state, and making it a value keeps it cheap enough to build
/// inside a menu body on every evaluation.
@MainActor
struct ShellActions {
    let env: AppEnvironment

    private var shell: ShellState { env.shell }

    // MARK: - What is aimed at

    /// The track the Track menu acts on — see `ShellCommandRouting.target`.
    var target: MenuTarget {
        ShellCommandRouting.target(
            destination: shell.destination,
            scope: shell.libraryScope,
            selectedSongId: shell.selectedSongId,
            selectedPartId: shell.selectedPartId,
            editorMaterialId: env.editor.material?.id,
            editorMaterialIsPart: env.editor.material?.isPart ?? false)
    }

    /// The selected song as a *fresh* record. Re-read rather than cached: a
    /// rating set in the inspector a second ago has to be what Rate ★★★★ sees,
    /// or the menu will write a stale row back over it.
    var targetSong: SongRecord? {
        guard case .song(let id) = target else { return nil }
        return env.library.song(id: id)
    }

    var targetPart: PartRecord? {
        guard case .part(let id) = target else { return nil }
        return (try? env.partsStore.repository.part(id: id)) ?? nil
    }

    /// Everything the Track and File menus need about the picked row, read
    /// once.
    ///
    /// The individual properties above each go to the database, and a menu
    /// body asks six of them — title, heart, rating, kind, file, record — so
    /// building the menu used to be six point queries where one would do.
    /// They are all still there because `ShellActions`' own mutations want a
    /// *fresh* read at the moment they act; this is the snapshot the menu
    /// draws itself from.
    struct ResolvedTarget {
        var kind: MenuTarget = .none
        var song: SongRecord?
        var part: PartRecord?
        var title: String?
        var isFavourite = false
        var rating = 0
        var fileURL: URL?
        /// Whether the stashed pre-edit original is actually on disk. Both
        /// "Play Original" and "Revert" need it to exist — a track that was
        /// never edited has no backup to play or put back.
        var hasBackup = false
    }

    var resolvedTarget: ResolvedTarget {
        var resolved = ResolvedTarget(kind: target)
        switch resolved.kind {
        case .song(let id):
            guard let song = env.library.song(id: id) else { break }
            resolved.song = song
            resolved.title = Self.short(song.title)
            resolved.isFavourite = song.favorite
            resolved.rating = song.rating
            resolved.fileURL = song.fileURL
            resolved.hasBackup = FileManager.default
                .fileExists(atPath: song.backupURL.path)
        case .part(let id):
            guard let part = (try? env.partsStore.repository.part(id: id))
                ?? nil else { break }
            resolved.part = part
            resolved.title = Self.short(part.name)
            resolved.isFavourite = part.favorite
            resolved.rating = part.rating
            resolved.fileURL = part.fileURL
        case .none:
            break
        }
        return resolved
    }

    static func short(_ title: String, limit: Int = 28) -> String {
        title.count <= limit
            ? title
            : String(title.prefix(limit - 1)) + "\u{2026}"
    }

    // MARK: - The shared bundle

    /// The jumps a track offers, wired once so a track behaves the same from a
    /// row menu, a detail pane and the menubar.
    ///
    /// Almost every member is a write to the intent mailbox `MainWindow`
    /// already watches, which is why so little of the routing had to move with
    /// it: the window consumes `studio.pending` and `prefill.pending` exactly
    /// as before, from whichever surface set them.
    var songActions: SongActions {
        SongActions(
            reusePrompt: { reuse($0, scope: .prompt) },
            reuseAll: { reuse($0, scope: .all) },
            reuseAllWithSeed: { reuse($0, scope: .allWithSeed) },
            split: { env.studio.pending = .split(songId: $0.id) },
            findMatches: { env.studio.pending = .findMatches(materialId: $0.id) },
            describe: { env.studio.pending = .describe(materialId: $0.id) },
            openMix: { env.studio.pending = .openMix(songId: $0.id) },
            restyle: {
                env.studio.pending = .styleTransfer(materialId: $0.id,
                                                    presetId: nil)
            },
            edit: { env.studio.pending = .edit(materialId: $0.id) },
            playOriginal: { song in
                env.playback.play(url: song.backupURL,
                                  songId: song.id + ".original",
                                  title: song.title,
                                  duration: song.durationS,
                                  subtitle: "ORIGINAL \u{00B7} "
                                      + song.sourceLabel.uppercased())
            },
            revertEdits: { song in
                // Confirmed here rather than at each call site: this is the
                // one action in the app that discards audio the user cannot
                // get back, and the row menu used to fire it on one click.
                // Settings can waive the asking; the render-in-flight refusal
                // inside `revert` still applies either way.
                if env.settings.confirmRevert {
                    shell.pendingRevert = song
                } else {
                    revert(song)
                }
            })
    }

    /// Fill the composer from a finished take and go there.
    ///
    /// No `destination` write: the window routes on `prefill.pending`
    /// changing, so setting the mailbox is the whole action — and doing it
    /// through one path keeps the menu and the row menu honest with each
    /// other.
    func reuse(_ song: SongRecord, scope: ReuseScope) {
        env.prefill.pending = GenerationSettings.prefill(for: song, scope: scope)
        ShellWindow.focus()
    }

    /// Reverting goes through the Editor's own path: it owns the file swap,
    /// the record rewrite and the peak invalidation, and a second copy here
    /// would drift. It refuses while a render is in flight rather than
    /// resetting a session that is mid-apply.
    func revert(_ song: SongRecord) {
        // By id: the Editor may be holding a different track mid-edit, and
        // taking that session over to act on this one is a surprise.
        if !env.editor.revert(songId: song.id) {
            shell.revertBlocked = env.editor.renderingTitle ?? "another track"
        }
    }

    // MARK: - Track menu

    /// Open the target in the Editor — the ⌘E the row menus have advertised
    /// since the Editor shipped, and which until now did nothing, because a
    /// shortcut declared on a closed context menu is never installed.
    func editTarget() {
        guard let id = target.id else { return }
        env.studio.pending = .edit(materialId: id)
        ShellWindow.focus()
    }

    func toggleFavourite() {
        if var song = targetSong {
            song.favorite.toggle()
            env.library.update(song)
        } else if var part = targetPart {
            part.favorite.toggle()
            env.partsStore.update([part])
        }
    }

    /// Set the rating outright. Unlike the stars in the inspector this does
    /// *not* toggle a repeated value back to zero: picking "★★★" from a menu
    /// is naming a rating, not clicking a star, and having it clear the rating
    /// because it already said three would be baffling. "No Rating" is its own
    /// item for that.
    func rate(_ stars: Int) {
        if var song = targetSong {
            song.rating = stars
            env.library.update(song)
        } else if var part = targetPart {
            part.rating = stars
            env.partsStore.update([part])
        }
    }

    /// Put the caret in the selected track's name field.
    ///
    /// Songs only: a part's name is derived from its stem and its source, and
    /// the part inspector has no field to focus.
    var canRenameTarget: Bool { target.isSong }

    func renameTarget() {
        guard case .song(let id) = target else { return }
        revealSongForEditing(id)
        shell.renameRequest = id
    }

    /// Put the caret in the notes field of the selected track. Songs only, for
    /// the same reason Rename is: a part's inspector has no notes field.
    func editTargetNotes() {
        guard case .song(let id) = target else { return }
        revealSongForEditing(id)
        shell.notesRequest = id
    }

    /// Land on the Library, on the scope that lists this track, with it
    /// selected — what both field-focus mailboxes need before the field they
    /// aim at exists.
    private func revealSongForEditing(_ id: String) {
        shell.libraryScope = LibraryScope(
            origin: env.library.song(id: id)?.originKind ?? .generated)
        shell.selectedSongId = id
        shell.go(to: .library)
    }

    // MARK: - Copying what a track knows

    /// The prompt that made it. Generated tracks only — an import has none,
    /// and a render's provenance is a bench, not a sentence.
    var targetPrompt: String? {
        guard let song = resolvedTarget.song,
              !song.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                  .isEmpty
        else { return nil }
        return song.prompt
    }

    var targetSeed: Int64? { resolvedTarget.song?.seedUsed }

    func copyPrompt() {
        guard let prompt = targetPrompt else { return }
        copyToPasteboard(prompt)
    }

    func copySeed() {
        guard let seed = targetSeed else { return }
        copyToPasteboard("\(seed)")
    }

    /// Everything the inspector shows, as one block — the thing you paste into
    /// a note or a bug report when a take comes out strange.
    func copyTrackDetails() {
        let picked = resolvedTarget
        guard let text = ShellCommandRouting.details(
            song: picked.song, part: picked.part,
            analysis: picked.kind.id.flatMap {
                env.partsStore.analysis(for: $0)
            })
        else { return }
        copyToPasteboard(text)
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Files

    /// Import audio from anywhere in the app.
    ///
    /// The Library's own importer is a `fileImporter` on that screen, so
    /// bringing a file in used to mean going there first. This runs the panel
    /// itself and lands the user on the imported track.
    func importAudio() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = true
        panel.prompt = "Import"
        panel.message = "Choose audio to add to the library"
        panel.begin { response in
            guard response == .OK else { return }
            let urls = panel.urls
            guard !urls.isEmpty else { return }
            Task { @MainActor in
                let imported = await env.library.importSongs(urls: urls)
                shell.libraryScope = .imported
                if let first = imported.first {
                    shell.selectedSongId = first.id
                    shell.libraryReveal = LibraryReveal(songId: first.id,
                                                        scope: .imported)
                }
                shell.go(to: .library)
            }
        }
    }

    /// Show the picked track or part in Finder.
    ///
    /// The Editor wins when it is the screen you are on, for the same reason
    /// it wins the Track menu — but it publishes its own reveal closure (it
    /// knows which source file it has open), so the File menu prefers that and
    /// only falls back to this.
    func revealTarget() {
        guard let url = resolvedTarget.fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Save a copy of the selected track or part.
    ///
    /// Both name the file the way their own inspector does — `exportName` for
    /// a song, the part's name plus its real format — so a track exported from
    /// the menubar and the same track exported from the pane land as the same
    /// file.
    func exportTarget() {
        if let song = targetSong {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = SongDetailView.exportName(
                title: song.title, fileName: song.fileName)
            panel.begin { response in
                guard response == .OK, let url = panel.url else { return }
                try? FileManager.default.removeItem(at: url)
                try? FileManager.default.copyItem(at: song.fileURL, to: url)
            }
        } else if let part = targetPart {
            let ext: String
            switch part.format {
            case "midi": ext = "mid"
            case "json": ext = "json"
            default: ext = "wav"
            }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = part.name
                .replacingOccurrences(of: "/", with: "-") + ".\(ext)"
            panel.begin { response in
                guard response == .OK, let url = panel.url else { return }
                Task { @MainActor in env.partsStore.export(part, to: url) }
            }
        }
    }

    /// Bring in every audio file in a folder, one level down.
    ///
    /// Deliberately not recursive: a folder chosen by hand is an album or a
    /// session, and walking a whole `~/Music` tree is an import nobody asked
    /// for and cannot undo in one gesture. `AudioDrop` decides what counts as
    /// audio, so this takes exactly what a drop of the same files would.
    func importFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        panel.message = "Choose a folder of audio to add to the library"
        panel.begin { response in
            guard response == .OK, let folder = panel.url else { return }
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]))?
                .filter(AudioDrop.isAudio)
                .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
            guard !urls.isEmpty else { return }
            Task { @MainActor in
                let imported = await env.library.importSongs(urls: urls)
                shell.libraryScope = .imported
                if let first = imported.first {
                    shell.selectedSongId = first.id
                    shell.libraryReveal = LibraryReveal(songId: first.id,
                                                        scope: .imported)
                }
                shell.go(to: .library)
            }
        }
    }

    /// The stashed pre-edit original, in Finder.
    ///
    /// Songs only, and only once one exists: a part has no backup, and a track
    /// that was never edited has nothing stashed. Both the row menu and the
    /// Editor's apply panel offer this; this is the same act from the menubar.
    var backupURL: URL? {
        guard let song = resolvedTarget.song,
              FileManager.default.fileExists(atPath: song.backupURL.path)
        else { return nil }
        return song.backupURL
    }

    func revealBackup() {
        guard let url = backupURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Ask to delete, or delete — the same `confirmDeletes` gate the panes
    /// honour, and the same dialog for both kinds.
    func requestDeleteTarget() {
        guard target != .none else { return }
        if env.settings.confirmDeletes {
            shell.pendingDelete = target
        } else {
            deleteTarget(target)
        }
    }

    func deleteTarget(_ which: MenuTarget) {
        switch which {
        case .song(let id):
            guard let song = env.library.song(id: id) else { return }
            env.playback.stop(songId: song.id)
            env.library.delete(song)
            if shell.selectedSongId == id { shell.selectedSongId = nil }
            shell.checked.remove(id)
        case .part(let id):
            guard let part = (try? env.partsStore.repository.part(id: id)) ?? nil
            else { return }
            env.playback.stop(songId: part.id)
            env.partsStore.delete(part)
            if shell.selectedPartId == id { shell.selectedPartId = nil }
            shell.checked.remove(id)
        case .none:
            break
        }
    }

    /// What the delete dialog is about to remove, named.
    ///
    /// Switched on the unwrapped value rather than on the optional: in an
    /// `Optional<MenuTarget>` switch, `.none` binds to `Optional.none` and
    /// leaves `MenuTarget.none` uncovered — the two spellings collide, and
    /// only the compiler notices.
    var pendingDeleteTitle: String {
        guard let pending = shell.pendingDelete else { return "" }
        switch pending {
        case .song(let id): return env.library.song(id: id)?.title
            ?? "this track"
        case .part(let id):
            return ((try? env.partsStore.repository.part(id: id)) ?? nil)?.name
                ?? "this part"
        case .none: return ""
        }
    }

    // MARK: - The ticked rows

    /// What is ticked, resolved against the database rather than against the
    /// list on screen.
    ///
    /// `LibrarySelection.of` resolves from the arrays the Library happens to
    /// be showing, which is right for a panel drawn beside that list and wrong
    /// for a menu: a filter typed after the ticks were made would quietly turn
    /// "Delete 6 tracks" into "delete the 2 that are still visible".
    var checkedSelection: LibrarySelection {
        var selection = LibrarySelection()
        for id in shell.checked.sorted() {
            if let song = env.library.song(id: id) {
                selection.songs.append(song)
            } else if let part = (try? env.partsStore.repository.part(id: id))
                ?? nil {
                selection.parts.append(part)
            } else {
                selection.unresolved += 1
            }
        }
        return selection
    }

    /// Tick every row the Library is listing.
    ///
    /// The visible rows, not the whole table: what the user can see is what a
    /// select-all means, and a filtered list that ticked six hundred hidden
    /// tracks would be a trap with a Delete item three lines below it.
    func selectAllRows() {
        let songs = env.library.results.map(\.id)
        let parts = env.partsStore.results.map(\.id)
        switch shell.libraryScope {
        case .parts: shell.checked = Set(parts)
        // All and Favourites list both kinds, so both are taken.
        case .all, .favourites: shell.checked = Set(songs + parts)
        case .songs, .imported, .edited: shell.checked = Set(songs)
        }
    }

    func clearRowSelection() {
        shell.checked = []
        // A comparison is a pair of ticks; untick them and the transport's
        // A|B is about rows nothing has picked.
        if shell.compare.isActive { shell.compare.end() }
    }

    func toggleCheckedFavourite() {
        let selection = checkedSelection
        let wanted = !selection.allFavourite
        env.library.update(selection.songs.filter { $0.favorite != wanted }
            .map { var song = $0; song.favorite = wanted; return song })
        env.partsStore.update(selection.parts.filter { $0.favorite != wanted }
            .map { var part = $0; part.favorite = wanted; return part })
    }

    func rateChecked(_ rating: Int) {
        let selection = checkedSelection
        env.library.update(selection.songs.filter { $0.rating != rating }
            .map { var song = $0; song.rating = rating; return song })
        env.partsStore.update(selection.parts.filter { $0.rating != rating }
            .map { var part = $0; part.rating = rating; return part })
    }

    /// Ask before deleting several, honouring the same preference one delete
    /// does — and with the count in the question, because this is the item
    /// that can empty a whole afternoon's work in one press.
    func requestDeleteChecked() {
        guard !shell.checked.isEmpty else { return }
        if env.settings.confirmDeletes {
            shell.pendingBatchDelete = shell.checked
        } else {
            deleteChecked(shell.checked)
        }
    }

    func deleteChecked(_ ids: Set<String>) {
        var selection = LibrarySelection()
        for id in ids.sorted() {
            if let song = env.library.song(id: id) {
                selection.songs.append(song)
            } else if let part = (try? env.partsStore.repository.part(id: id))
                ?? nil {
                selection.parts.append(part)
            }
        }
        // Anything playing out of a file about to go is stopped first; a
        // player holding a deleted file is a stall with no error.
        for song in selection.songs { env.playback.stop(songId: song.id) }
        for part in selection.parts { env.playback.stop(songId: part.id) }
        env.library.delete(selection.songs)
        env.partsStore.delete(selection.parts)
        if let picked = shell.selectedSongId, ids.contains(picked) {
            shell.selectedSongId = nil
        }
        if let picked = shell.selectedPartId, ids.contains(picked) {
            shell.selectedPartId = nil
        }
        shell.checked.subtract(ids)
        if shell.compare.isActive { shell.compare.end() }
    }

    /// Copy every ticked file into one folder.
    ///
    /// A folder rather than a save panel per file — twenty save panels is not
    /// a feature — and the same unique-naming the selection inspector uses, so
    /// two tracks called `track042` land as `track042.wav` and `track042-2.wav`
    /// rather than one overwriting the other.
    func exportChecked() {
        let selection = checkedSelection
        guard selection.count > 0 else { return }
        let files = selection.songs.map {
            ($0.fileURL, SongDetailView.exportName(title: $0.title,
                                                   fileName: $0.fileName))
        } + selection.parts.map {
            ($0.fileURL, SongDetailView.exportName(title: $0.name,
                                                   fileName: $0.fileName))
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export here"
        panel.message = "Choose a folder for \(files.count) files"
        panel.begin { response in
            guard response == .OK, let folder = panel.url else { return }
            var used: Set<String> = []
            for (url, name) in files {
                let unique = LibrarySelectionInspector.unique(name, taken: &used)
                let destination = folder.appendingPathComponent(unique)
                try? FileManager.default.removeItem(at: destination)
                try? FileManager.default.copyItem(at: url, to: destination)
            }
        }
    }

    /// Every ticked part onto the bench, in the order they were listed.
    ///
    /// Songs are skipped rather than refused: a mixed selection is a normal
    /// thing to have, and the item says "parts" — see `canAddCheckedToBench`.
    func addCheckedToWorkbench() {
        let parts = checkedSelection.parts
        guard !parts.isEmpty else { return }
        for part in parts {
            let title = env.library.song(id: part.songId)?.title
                ?? part.modelName
            env.workbench.add(
                material: PickedMaterial(part: part, sourceTitle: title),
                parts: env.partsStore)
        }
        shell.go(to: .workbench)
    }

    var canAddCheckedToBench: Bool {
        shell.checked.contains { id in
            ((try? env.partsStore.repository.part(id: id)) ?? nil) != nil
        }
    }

    /// Open a batch Actions page over the ticked rows. The page seeds its own
    /// picker from `shell.checked` — see `ActionsScreen.batchPreselection` —
    /// so this is a jump, not a submission.
    func openBatchAction(recipeId: String) {
        shell.actionsRoute = .action(recipeId: recipeId, sourceId: nil)
        shell.go(to: .actions)
    }

    // MARK: - The Library's own view

    func setLibrarySort(_ sort: LibraryRepository.Sort) {
        env.library.filters.sort = sort
        // The same follow-through the filter bar's menu has: a sort chosen
        // here is a choice, and Settings may want to remember it.
        if env.settings.libraryRemembersSort {
            env.settings.libraryDefaultSort = sort
        }
    }

    /// Put the filters back to what this scope starts from.
    ///
    /// Mirrors `LibraryScreen.scopeBaseline`: a scope *is* a filter set, so
    /// "clear" cannot mean an empty one — clearing inside Imported must leave
    /// you in Imported.
    func clearLibraryFilters() {
        var baseline = LibraryRepository.Filters()
        baseline.sort = env.settings.libraryDefaultSort
        let scope = shell.libraryScope
        baseline.origin = scope.originFilter
        baseline.favoritesOnly = scope == .favourites
        baseline.hasEdits = scope == .edited
        if scope == .edited { baseline.sort = .recentlyEdited }
        env.library.filters = baseline
        var parts = PartsRepository.Filters()
        parts.favoritesOnly = scope == .favourites
        env.partsStore.filters = parts
    }

    // MARK: - Playback

    /// Play/pause whatever is sounding.
    ///
    /// The Editor keeps its own preview player, so while you are in it this
    /// has to reach that one — pressing play in the menubar and hearing the
    /// library's last track instead of the file on screen would be the wrong
    /// player answering.
    func togglePlayback() {
        if shell.destination == .editor, env.editor.material != nil {
            env.editor.togglePlayback()
        } else {
            env.playback.toggle()
        }
    }

    var isPlaying: Bool {
        shell.destination == .editor && env.editor.material != nil
            ? env.editor.isPlaying
            : env.playback.isPlaying
    }

    /// Whether there is anything at all to play or stop.
    var hasAudioLoaded: Bool {
        shell.destination == .editor && env.editor.material != nil
            ? true
            : env.playback.currentSongId != nil
    }

    func stopPlayback() {
        if shell.destination == .editor, env.editor.material != nil {
            env.editor.stopPreview()
        } else {
            env.playback.stop()
        }
    }

    /// Nudge the playhead. Clamped at both ends rather than allowed to run
    /// negative, which `AVPlayer` accepts and then reports back as a garbage
    /// position.
    func skip(by seconds: Double) {
        if shell.destination == .editor, env.editor.material != nil {
            let next = (env.editor.playheadS + seconds)
                .clamped(to: 0...max(0, env.editor.timelineDurationS))
            env.editor.seekPreview(to: next)
        } else {
            guard env.playback.currentSongId != nil else { return }
            let next = (env.playback.currentTime + seconds)
                .clamped(to: 0...max(0, env.playback.duration))
            env.playback.seek(to: next)
        }
    }

    /// Jump to either end of whatever is loaded. The Editor's own timeline
    /// when it is the screen you are on, for the reason `skip` routes there.
    func seekToStart() {
        if shell.destination == .editor, env.editor.material != nil {
            env.editor.seekPreview(to: 0)
        } else if env.playback.currentSongId != nil {
            env.playback.seek(to: 0)
        }
    }

    func seekToEnd() {
        if shell.destination == .editor, env.editor.material != nil {
            env.editor.seekPreview(to: max(0, env.editor.timelineDurationS))
        } else if env.playback.currentSongId != nil {
            env.playback.seek(to: max(0, env.playback.duration))
        }
    }

    // MARK: - Level

    /// One level for the app, told to both players.
    ///
    /// The Editor auditions through its own graph, so a volume applied only to
    /// the transport would leave the Editor loud — turning the app down on the
    /// one screen where you are actually listening would do nothing.
    /// The bench's audition keeps its own per-clip gains and is left alone.
    func setVolume(_ level: Double) {
        env.playback.setVolume(level)
        env.editor.setPreviewVolume(env.playback.isMuted ? 0 : env.playback.volume)
    }

    func adjustVolume(by delta: Double) {
        env.playback.adjustVolume(by: delta)
        env.editor.setPreviewVolume(env.playback.isMuted ? 0 : env.playback.volume)
    }

    func toggleMute() {
        env.playback.toggleMute()
        env.editor.setPreviewVolume(env.playback.isMuted ? 0 : env.playback.volume)
    }

    /// `Volume · 70%`, as a disabled readout above the two items that move it.
    var volumeSummary: String {
        env.playback.isMuted
            ? "Muted"
            : "Volume \(Int((env.playback.volume * 100).rounded()))%"
    }

    // MARK: - Now playing

    /// Show the track that is sounding, wherever it lives.
    ///
    /// The id carries a suffix while an original is being auditioned
    /// (`song.id + ".original"`), so it is trimmed back to the row it belongs
    /// to rather than looked up and missed.
    var nowPlayingSongId: String? {
        guard let id = env.playback.currentSongId else { return nil }
        let suffix = ".original"
        return id.hasSuffix(suffix) ? String(id.dropLast(suffix.count)) : id
    }

    func showNowPlaying() {
        guard let id = nowPlayingSongId else { return }
        if let song = env.library.song(id: id) {
            let scope = LibraryScope(origin: song.originKind)
            shell.libraryReveal = LibraryReveal(songId: id, scope: scope)
            shell.selectedSongId = id
            shell.go(to: scope)
        } else if ((try? env.partsStore.repository.part(id: id)) ?? nil) != nil {
            shell.selectedPartId = id
            shell.go(to: LibraryScope.parts)
        }
    }

    // MARK: - A/B compare

    /// The two ticked rows, when they are two songs — the only thing the A/B
    /// switch can compare.
    var comparablePair: (SongRecord, SongRecord)? {
        let songs = shell.checked.compactMap { env.library.song(id: $0) }
        guard songs.count == 2 else { return nil }
        let ordered = songs.sorted { $0.id < $1.id }
        return (ordered[0], ordered[1])
    }

    func toggleCompare() {
        if shell.compare.isActive {
            shell.compare.end()
        } else if let pair = comparablePair {
            shell.compare.start(a: pair.0, b: pair.1, playback: env.playback)
            shell.go(to: .library)
        }
    }

    // MARK: - Panels

    /// The animation the shell moves its panels with — nil (no animation at
    /// all) under Settings' reduce-motion, which `withAnimation` reads as
    /// "just do it". The same curve `MainWindow` uses, so a panel opened from
    /// the menubar and one opened from the transport bar move identically.
    var panelMotion: Animation? {
        env.settings.reduceMotion ? nil : .easeOut(duration: 0.22)
    }

    func toggleSidebar() {
        // A window too narrow to hold it has already put it away, and
        // flipping the preference underneath that would change nothing the
        // user can see. The menu item dims for this too; the guard is here so
        // the action is safe however it is reached.
        guard !shell.sidebarCramped else { return }
        withAnimation(panelMotion) { shell.sidebarCollapsed.toggle() }
        ShellWindow.focus()
    }

    func toggleQueuePanel() {
        withAnimation(panelMotion) { shell.queuePanel.toggle() }
        ShellWindow.focus()
    }

    /// Pin or unpin what is *drawn*, not what is stored — the queue rail's own
    /// pin button does the same. A panel pinned by a render shows a filled
    /// pin, and flipping only the preference would leave it pinned with the
    /// control looking broken.
    func setQueuePinned(_ pinned: Bool) {
        withAnimation(panelMotion) {
            shell.queuePinned = pinned
            shell.queuePanel.pinChanged()
        }
    }

    // MARK: - Queue

    /// Cancel the render that is actually running, not an arbitrary one.
    ///
    /// `runningJob` is read here, inside the closure, rather than by the menu
    /// item that calls it: that projection carries live progress by design, so
    /// reading it from a `Commands` body would put the whole menubar on the
    /// render's tick. The item gates on `isWorking`, which is a gated `Bool`.
    func cancelCurrentRender() {
        guard let jobId = env.jobsStore.runningJob?.id else { return }
        Task { await env.jobsStore.cancel(jobId) }
    }

    /// Cancel everything that has not finished.
    ///
    /// Read from `displayJobs` inside the action, never from a menu body — the
    /// list carries live progress, and a `Commands` body that touched it would
    /// put the whole menubar on the render's tick.
    func cancelAllRenders() {
        let ids = env.jobsStore.displayJobs
            .filter { !$0.status.isTerminal }
            .map(\.id)
        guard !ids.isEmpty else { return }
        Task {
            for id in ids { await env.jobsStore.cancel(id) }
        }
    }

    /// Ask to be told when the render in flight lands — the queue row's own
    /// bell, from the menubar, for when you are about to walk away.
    func armCurrentRender() {
        guard let jobId = env.jobsStore.runningJob?.id else { return }
        env.jobsStore.setNotifyOnLanding(jobId, true)
    }

    /// The running job's mirrored stderr, on the pasteboard. The engine log
    /// beside it is the whole process; this is one render.
    func copyRenderLog() {
        guard let jobId = env.jobsStore.runningJob?.id
            ?? env.jobsStore.displayJobs.last?.id else { return }
        let text = env.jobsStore.log(for: jobId).lines
            .map(\.text)
            .joined(separator: "\n")
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func pauseAllDownloads() {
        Task { await env.downloadsStore.pauseAll() }
    }

    func resumeAllDownloads() {
        Task { await env.downloadsStore.resumeAll() }
    }

    func clearFinishedDownloads() {
        env.downloadsStore.dismissAllFinished()
    }

    func refreshCatalog() {
        Task { await env.catalog.refresh() }
    }

    func toggleQueueHold() {
        let held = env.jobsStore.queueHeld
        Task {
            await env.jobsStore.holdQueue(!held)
            // Only touch the transfers once the engine has taken the hold:
            // half a pause is worse than none, and a refusal is already on
            // `jobs.lastError`. The same order the queue rail's button uses.
            guard env.jobsStore.queueHeld == !held else { return }
            if held { await env.downloadsStore.resumeAll() }
            else { await env.downloadsStore.pauseAll() }
        }
    }

    func clearFinished() {
        env.jobsStore.dismissFinished()
        env.downloadsStore.dismissAllFinished()
    }

    /// The newest take any job in the queue has produced.
    ///
    /// `displayJobs` is already ordered, so "newest" is the last produced id
    /// on the last job that produced anything — no second sort, and no reading
    /// of the raw `active` dictionary.
    var latestRenderedSongId: String? {
        env.jobsStore.displayJobs.last { !$0.producedSongIds.isEmpty }?
            .producedSongIds.last
    }

    /// Take the user to the track the queue just made.
    ///
    /// The scope comes from the song's own origin rather than being assumed:
    /// the same row shape carries an import, and dropping the user on the
    /// Generated shelf with an import selected shows an empty pane over a list
    /// the track is not in. A render needs no such care any more — it shares
    /// the Generated shelf with the takes — but the rule is written against the
    /// origin rather than against which origins happen to share a shelf today.
    /// The same rule `MainWindow`'s "Show in library" follows.
    func showLatestRender() {
        guard let id = latestRenderedSongId,
              let song = env.library.song(id: id) else { return }
        let scope = LibraryScope(origin: song.originKind)
        shell.libraryReveal = LibraryReveal(songId: id, scope: scope)
        shell.selectedSongId = id
        shell.go(to: scope)
    }

    // MARK: - Engine

    func restartEngine() {
        Task { await env.backendManager.restart() }
    }

    /// Drop the warm worker's model, freeing its memory without restarting the
    /// engine — the Settings debug pane's button, which is several clicks
    /// deeper than a thing you reach for when the Mac starts swapping.
    func unloadWorker() {
        Task {
            guard let client = await env.backendManager.client else { return }
            do {
                try await client.unloadWorker()
            } catch {
                env.backendStatus.appendStderr(
                    "[unload] refused: \(error.localizedDescription)")
            }
        }
    }

    /// `READY · PORT 61247 · 2 RESTARTS` — the engine at a glance, as a
    /// disabled item. Cheap, and the one fact you most often open Settings to
    /// check.
    var engineSummary: String {
        let status = env.backendStatus
        var fields = [status.phase.label.uppercased()]
        if let port = status.port { fields.append("PORT \(port)") }
        if status.restartCount > 0 {
            fields.append("\(status.restartCount) RESTART"
                          + (status.restartCount == 1 ? "" : "S"))
        }
        return fields.joined(separator: " \u{00B7} ")
    }

    func openEngineLogs() {
        NSWorkspace.shared.open(StoragePaths.engineLogs)
    }

    func copyEngineLog() {
        let text = env.backendStatus.stderrTail.joined(separator: "\n")
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func revealDataFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([StoragePaths.root])
    }

    /// Check the model library is where the engine thinks it is, and that what
    /// it holds is intact — the Settings card's button, which is four clicks
    /// deep from a question you ask when a download claims to have finished
    /// and the model still will not load.
    func verifyModelLibrary() {
        Task { await env.modelLibrary.verify() }
    }

    /// The weights folder, not the app's data folder — on this Mac they are
    /// usually on different disks, which is exactly why both are offered.
    func revealModelLibrary() {
        let path = env.modelLibrary.info?.path
            ?? env.settings.hfHomePath
            ?? NSString(string: "~/.cache/huggingface").expandingTildeInPath
        NSWorkspace.shared.activateFileViewerSelecting(
            [URL(fileURLWithPath: path)])
    }

    func openAppLogs() {
        NSWorkspace.shared.open(StoragePaths.appLogs)
    }

    /// Everything worth pasting into a bug report, in one press.
    ///
    /// The engine's state, the machine's, and what is installed — assembled
    /// from the stores that already hold it rather than measured again here.
    func copyDiagnostics() {
        var lines = ["LocalMusicGen \(Self.appVersion)"]
        lines.append("Engine: \(engineSummary)")
        if let modelId = env.backendStatus.workerModelId {
            lines.append("Worker: \(modelId)")
        }
        let installed = env.catalog.models.filter {
            $0.installState == .installed
        }
        lines.append("Models installed: \(installed.count)")
        if let memory = env.telemetry.memoryLine { lines.append("Memory: \(memory)") }
        if let free = env.telemetry.freeDiskBytes {
            lines.append("Free disk (data folder): "
                         + "\(TelemetryStore.gigabytes(free)) GB")
        }
        if let free = env.telemetry.libraryFreeDiskBytes {
            lines.append("Free disk (model library): "
                         + "\(TelemetryStore.gigabytes(free)) GB")
        }
        lines.append("Data folder: \(StoragePaths.root.path)")
        if let path = env.modelLibrary.info?.path {
            lines.append("Model library: \(path)")
        }
        let tail = env.backendStatus.stderrTail.suffix(12)
        if !tail.isEmpty {
            lines.append("")
            lines.append("Last engine output:")
            lines.append(contentsOf: tail)
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"),
                                       forType: .string)
    }

    /// `1.4 (218)` — what the About box and the diagnostics both lead with.
    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }

    /// The About panel, with the engine in it.
    ///
    /// `orderFrontStandardAboutPanel` rather than a window of the app's own:
    /// the standard panel is already right about the icon, the name and the
    /// copyright, and what it was missing is the one thing this app is asked
    /// about — which engine is running, on which port, having restarted how
    /// many times.
    func showAbout() {
        var credits = engineSummary
        if let path = env.modelLibrary.info?.path {
            credits += "\n\(path)"
        }
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationVersion: Self.appVersion,
            .credits: NSAttributedString(
                string: credits,
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 10,
                                                       weight: .regular),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]),
        ])
        NSApp.activate(ignoringOtherApps: true)
    }
}

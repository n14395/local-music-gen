// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

/// What a track's detail pane can do beyond editing it in place: the three
/// jumps into another tab. Wired once by `MainWindow` and handed to every
/// place the pane appears, so they all offer the same actions.
struct SongActions {
    var reusePrompt: (SongRecord) -> Void = { _ in }
    /// Start a new generation from everything the track was made with —
    /// model, length, take count and every Full control value — on a fresh
    /// seed, so it is the same recipe rather than the same render.
    var reuseAll: (SongRecord) -> Void = { _ in }
    /// The same with the seed the engine actually used, which makes the
    /// render repeat instead of vary.
    var reuseAllWithSeed: (SongRecord) -> Void = { _ in }
    var split: (SongRecord) -> Void = { _ in }
    var findMatches: (SongRecord) -> Void = { _ in }
    /// Open "Describe it by listening" on this track.
    var describe: (SongRecord) -> Void = { _ in }
    var openMix: (SongRecord) -> Void = { _ in }
    /// Open the Style Transfer workspace on this track. Every member here has a
    /// default, so adding one is source-compatible with every construction.
    var restyle: (SongRecord) -> Void = { _ in }
    /// Open this track in the Editor.
    var edit: (SongRecord) -> Void = { _ in }
    /// Audition the stashed pre-edit original.
    var playOriginal: (SongRecord) -> Void = { _ in }
    /// Put the original back and clear the program.
    var revertEdits: (SongRecord) -> Void = { _ in }
}

extension SongRecord {
    /// The transport id the stashed pre-edit original plays under. It has to
    /// differ from `id`, or the transport reads an audition as the same track
    /// and merely toggles pause — and it is named once here because every
    /// *stop* site needs the same string as every play site. Deleting a track
    /// while its original was sounding used to leave the transport on a file
    /// that had just been disposed.
    var originalPlaybackId: String { id + ".original" }
}

/// Everything about one track: its waveform, metadata, and the fields that
/// edit it. Shown as the library's 404 pt inspector and, via
/// `songDetailPopover`, over any list row elsewhere in the app — one source so
/// the two never drift.
///
/// The action grid is pinned to the bottom rather than scrolled with the rest,
/// which is the design's `margin-top:auto`: the six things you can do with a
/// track are always in the same place whatever the panel is scrolled to.
struct SongDetailView: View {
    let song: SongRecord
    let library: LibraryStore
    let playback: PlaybackController
    let actions: SongActions
    let onDeleted: () -> Void
    /// "Render notes…" for a score whose MIDI has no preview yet — threaded
    /// in from `MainWindow` the way `LibraryScreen` receives it, and only by
    /// the Library: the popover hosts have no route to a renderer, and the
    /// sheet says so. Defaulted so every existing construction still builds.
    var onRenderNotes: ((PartRecord) -> Void)? = nil

    @State private var editor = SongEditor()
    @State private var confirmDelete = false
    /// True while the stashed original is what the transport is playing —
    /// the pane's own A/B, distinct from the library's two-row compare.
    @State private var playingOriginal = false
    /// Everything the pane prints that is not a field on the row it was
    /// handed: the tag set, the parts a mix was built from, the applied
    /// program, and what the two files measure on disk.
    ///
    /// Held rather than asked for from `body`, for the reason
    /// `EditorStore.hasBackup` sets out at length. Drawing this pane used to
    /// mean two `SELECT`s, a whole `EditDocument` decode and three `stat`s
    /// per pass — and a pane showing a playing track draws four times a
    /// second, because the transport's tick is a property its body reads.
    @State private var tags: [String] = []
    @State private var ingredientRows: [SongIngredientRecord] = []
    @State private var appliedDocument: EditDocument?
    @State private var hasBackup = false
    @State private var backupSize: String?
    @State private var fileSize: String?
    /// Why the last export failed. The save panel closes on its own, so
    /// without this a refused copy was indistinguishable from a finished one.
    @State private var exportError: String?
    /// The score the notation viewer is open on, resolved from a NOTATION
    /// slot's Open — see `NotationSheet`.
    @State private var openScore: NotationDocument?
    /// Ambient, optional: previews and tests host this pane without an
    /// environment, and "no settings" must read as "ask", the safe default.
    @Environment(AppSettings.self) private var appSettings: AppSettings?
    /// Optional, like `appSettings`: previews and the layout tests host this
    /// pane without a shell, and "no shell" has to read as "no rename
    /// requests", not as a crash.
    @Environment(ShellState.self) private var shell: ShellState?
    /// The name field, so Track ▸ Rename can put the caret in it.
    @FocusState private var titleFocused: Bool
    /// Track ▸ Edit Notes, the sibling of `titleFocused` — see the mailbox
    /// consumed below.
    @FocusState private var notesFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 14) {
                        header
                        SongDetailHero(song: song, playback: playback,
                                       onRate: { setRating($0) })
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 20).padding(.bottom, 14)

                    metadata
                        .padding(.horizontal, 20)

                    editsBlock

                    ingredients

                    VStack(alignment: .leading, spacing: 10) {
                        Text("TAGS").eyebrow()
                        LibraryTagField(tags: tags) { edited in
                            editor.tagsText = edited.joined(separator: ", ")
                            editor.commitTags(in: library)
                            // Tags live in a table of their own, so the write
                            // moves nothing this pane is watching. Read back
                            // what was stored rather than what was typed:
                            // `commitTags` trims and drops blanks.
                            tags = library.tags(for: song.id)
                        }
                        TextDocsSection(ownerId: song.id, ownerType: "song",
                                        playback: playback,
                                        onDescribe: { actions.describe(song) },
                                        onOpenNotation: { openScore = score($0) })
                            .padding(.top, 6)
                        Text("NOTES").eyebrow()
                            .padding(.top, 6)
                        notes
                    }
                    .padding(.horizontal, 20).padding(.vertical, 18)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let exportError { exportFailureLine(exportError) }
            actionGrid
                .padding(.horizontal, 20)
                .padding(.top, 16).padding(.bottom, 20)
        }
        .background(Bench.Palette.panel)
        // A failure belongs to the export that caused it, not to the pane: a
        // message still sitting here when you move to another track would be
        // about a file that track has nothing to do with.
        .onChange(of: song.id) { exportError = nil }
        .onChange(of: song.id, initial: true) { editor.load(song, in: library) }
        // Keyed on the whole record rather than its id: applying a program or
        // reverting one rewrites the row under the same track, and the pane
        // has to stop claiming edits it no longer has.
        .onChange(of: song, initial: true) { loadTrackFacts() }
        .task(id: song) { await loadFileFacts() }
        // Nothing on `song` moves when a tag is written from somewhere else in
        // the app, so the list's own refresh is the only signal there is —
        // the hook `LibraryScreen` hangs its derived state on.
        .onChange(of: library.results) { tags = library.tags(for: song.id) }
        // The pane can go away without a field ever losing focus — a popover
        // dismissed, a tab switched — so buffered edits are written on the way out.
        .onDisappear { editor.flush(in: library) }
        // Track ▸ Rename, consumed here because the field is three levels
        // inside the Library and a menu item cannot reach a `FocusState`.
        // `initial` because the request is usually set in the same turn that
        // selects this song, so the first body evaluation already carries it
        // and there is no change left to observe. Cleared on the way out, so
        // one request focuses the field once.
        .onChange(of: shell?.renameRequest, initial: true) {
            guard let shell, shell.renameRequest == song.id else { return }
            titleFocused = true
            shell.renameRequest = nil
        }
        // Track ▸ Edit Notes, on the same contract as Rename above: one
        // request, consumed once, aimed at the other field.
        .onChange(of: shell?.notesRequest, initial: true) {
            guard let shell, shell.notesRequest == song.id else { return }
            notesFocused = true
            shell.notesRequest = nil
        }
        .confirmationDialog("Delete “\(song.title)”?", isPresented: $confirmDelete) {
            Button("Delete song and audio file", role: .destructive) {
                deleteNow()
            }
        }
        .sheet(item: $openScore) { score in
            NotationSheet(document: score, playback: playback,
                          onRenderNotes: onRenderNotes)
        }
    }

    /// A NOTATION slot's document, with the notes the same job produced —
    /// resolved here rather than in the section, because the section knows
    /// nothing about parts and this pane already owns the repository.
    private func score(_ doc: TextDocRecord) -> NotationDocument {
        let parts = ((try? library.partsRepo?.allParts(forSong: song.id)) ?? nil)
            ?? []
        return NotationDocument.resolve(doc: doc, parts: parts,
                                        songTitle: song.title)
    }

    /// The shell's `revertEdits` already confirms (once, for every surface
    /// that offers a revert) — this pane used to hold a dialog of its own in
    /// front of it, so the menu item asked twice.
    private func requestDelete() {
        if appSettings?.confirmDeletes ?? true {
            confirmDelete = true
        } else {
            deleteNow()
        }
    }

    private func deleteNow() {
        // Both ids: the A/B switch auditions the backup under its own id, and
        // `LibraryStore` disposes the backup along with the track, so stopping
        // only `song.id` left the transport on a deleted file.
        playback.stop(songId: song.id)
        playback.stop(songId: song.originalPlaybackId)
        library.delete(song)
        onDeleted()
    }

    // MARK: what the pane knows

    /// Re-read what the row does not carry: its tags, the parts a mix was
    /// built from, and the program that was applied to it.
    private func loadTrackFacts() {
        tags = library.tags(for: song.id)
        appliedDocument = Self.appliedProgram(of: song)
        // A mix's ingredients are fixed the moment it is rendered, but the
        // query is cheap and keying it to the row keeps one reload path
        // rather than two.
        if song.originKind == .recombined, let partsRepo = library.partsRepo {
            ingredientRows = (try? partsRepo.ingredients(songId: song.id)) ?? []
        } else {
            ingredientRows = []
        }
    }

    /// Measure the two files the pane reports on: the audio it plays, and the
    /// stashed original a revert would put back.
    ///
    /// Off the actor because these are syscalls, and a view body has no
    /// business making one. Asked again whenever the row changes, because
    /// applying a program rewrites the audio and stashes the original, and a
    /// revert takes both back the other way.
    private func loadFileFacts() async {
        let audioURL = song.fileURL
        let backupURL = song.backupURL
        let measured = await Task.detached(priority: .userInitiated) {
            (audio: LibraryFormat.fileSize(of: audioURL),
             hasBackup: FileManager.default.fileExists(atPath: backupURL.path),
             backup: LibraryFormat.fileSize(of: backupURL))
        }.value
        fileSize = measured.audio
        hasBackup = measured.hasBackup
        backupSize = measured.backup
    }

    /// The program applied to a track, or nil when it carries none — and nil
    /// too when the stored document decodes to nothing, so an empty program
    /// never draws an empty EDITS block.
    private static func appliedProgram(of song: SongRecord) -> EditDocument? {
        guard song.editedAt != nil, let json = song.editsJSON,
              let document = try? JSONDecoder().decode(
                EditDocument.self, from: Data(json.utf8)),
              !document.isEmpty else { return nil }
        return document
    }

    // MARK: header

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                TextField("Title", text: $editor.title,
                          onCommit: { editor.commitTitle(in: library) })
                    .focused($titleFocused)
                    .textFieldStyle(.plain)
                    .tint(Bench.Palette.accent)
                    .font(Bench.Typo.inspectorTitle)
                    .tracking(-0.17)
                    .foregroundStyle(Bench.Palette.textPrimary)
                if let titleError = editor.titleError {
                    // The field has already sprung back to the stored name by
                    // the time this is read; this says why rather than leaving
                    // the revert looking like dropped input.
                    Text(titleError)
                        .font(Bench.Typo.caption)
                        .foregroundStyle(Bench.Palette.dangerText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !song.prompt.isEmpty {
                    Text(song.prompt)
                        .font(Bench.Typo.secondary)
                        .foregroundStyle(Bench.Palette.textQuaternary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            Button {
                var updated = song
                updated.favorite.toggle()
                library.update(updated)
            } label: {
                Image(systemName: song.favorite ? "heart.fill" : "heart")
                    .font(.system(size: 13))
                    .foregroundStyle(song.favorite ? TrackRow.favouriteHeart
                                                   : Bench.Palette.textFaint)
            }
            .buttonStyle(.plain)
            .help(song.favorite ? "Remove from favourites" : "Mark as a favourite")
            overflowMenu
        }
    }

    /// The `···`. Everything here is also somewhere else on the panel — this is
    /// the second way to reach it, not the only one.
    private var overflowMenu: some View {
        Menu {
            Button("Edit…") { actions.edit(song) }
                .keyboardShortcut("e", modifiers: .command)
            if appliedDocument != nil {
                Button("Play original") {
                    playingOriginal = true
                    playback.play(url: song.backupURL,
                                  songId: song.originalPlaybackId,
                                  title: song.title,
                                  duration: originalDuration ?? song.durationS,
                                  subtitle: "ORIGINAL · "
                                      + song.sourceLabel.uppercased())
                }
                .disabled(!hasBackup)
                Button("Reveal backup in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [song.backupURL])
                }
                .disabled(!hasBackup)
                Button("Revert to original…", role: .destructive) {
                    actions.revertEdits(song)
                }
            }
            if song.originKind == .recombined {
                // Every clip's placement was recorded when this was rendered,
                // so the arrangement can be reopened and edited rather than
                // rebuilt from memory.
                Button("Edit in Workbench") { actions.openMix(song) }
            }
            Divider()
            Button("Export…") { exportSong() }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([song.fileURL])
            }
            Divider()
            Button("Delete…", role: .destructive) { requestDelete() }
        } label: {
            Text("···")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Bench.Palette.textFaintest)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// The transport bar's mono second line: `MUSICGEN SMALL · 9.9 S`. Without
    /// it the bar shows a title over an empty row.
    static func subtitle(for song: SongRecord) -> String {
        "\(song.sourceLabel) · \(LibraryFormat.seconds(song.durationS)) S"
            .uppercased()
    }

    // MARK: metadata

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 9) {
            // An import was not made by a model, so naming one would be a
            // fiction. It gets the field it does have — who played it — and
            // nothing at all when the file arrived without tags.
            if song.originKind == .imported {
                if let artist = song.artist, !artist.isEmpty {
                    BenchInfoRow("Artist", artist)
                }
            } else {
                BenchInfoRow("Model", song.modelName)
            }
            if song.originKind == .generated {
                BenchInfoRow(label: "Prompt") {
                    Text(song.prompt)
                        .foregroundStyle(Bench.Palette.textSecondary)
                        .textSelection(.enabled)
                }
                if let lyrics = song.lyrics, !lyrics.isEmpty {
                    BenchInfoRow(label: "Lyrics") {
                        Text(lyrics)
                            .foregroundStyle(Bench.Palette.textSecondary)
                            .lineLimit(6)
                            .textSelection(.enabled)
                    }
                }
            }
            BenchInfoRow(label: "Length") {
                Text("\(LibraryFormat.seconds(song.durationS)) s · "
                     + "\(song.sampleRate.formatted(.number)) Hz")
                    .font(Bench.Typo.mono(12))
                + Text(originalDuration.map {
                    "  was \(LibraryFormat.seconds($0)) s"
                } ?? "")
                    .font(Bench.Typo.mono(12))
                    .foregroundColor(Bench.Palette.textMuted)
            }
            if song.originKind == .generated, let seed = song.seedUsed {
                BenchInfoRow(label: "Seed") {
                    Text(seed.formatted(.number))
                        .font(Bench.Typo.mono(12))
                        .textSelection(.enabled)
                }
            }
            BenchInfoRow("Created",
                         song.createdAt.formatted(date: .abbreviated,
                                                  time: .shortened))
            if let fileSize {
                BenchInfoRow("Size", fileSize, mono: true)
            }
        }
    }

    // MARK: edits

    /// What an edited track carries: the steps that were applied, an A/B
    /// against the stashed original, and the reassurance that the original
    /// is still there. Absent entirely on a track nobody has edited.
    @ViewBuilder
    private var editsBlock: some View {
        if let document = appliedDocument {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 9) {
                    Text("EDITS").eyebrow()
                    if let appliedAt = song.editedAt {
                        Text("APPLIED \(LibraryFormat.when(appliedAt))")
                            .font(Bench.Typo.mono(10))
                            .foregroundStyle(Bench.Palette.textFaintest)
                    }
                    Spacer()
                    Button("Reopen in Editor") { actions.edit(song) }
                        .buttonStyle(.plain)
                        .font(Bench.Typo.small.weight(.semibold))
                        .foregroundStyle(Bench.Palette.accent)
                }
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(document.ops) { op in
                        HStack(spacing: 9) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(op.kind.tint)
                                .frame(width: 3, height: 14)
                            Text(appliedLine(op.kind))
                                .font(Bench.Typo.secondary)
                                .foregroundStyle(Bench.Palette.textSecondary)
                                .lineLimit(1)
                        }
                    }
                    if !document.enabledEffects.isEmpty {
                        HStack(spacing: 9) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Bench.Palette.violet)
                                .frame(width: 3, height: 14)
                            Text(document.enabledEffects
                                .map(\.kind.label).joined(separator: " → "))
                                .font(Bench.Typo.secondary)
                                .foregroundStyle(Bench.Palette.textSecondary)
                                .lineLimit(1)
                        }
                    }
                }
                if hasBackup {
                    abRow
                    HStack(spacing: 9) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Bench.Palette.ok)
                        Text("Original kept"
                             + (backupSize.map { " · \($0)" } ?? "")
                             + " · revert works forever")
                            .font(Bench.Typo.small)
                            .foregroundStyle(Bench.Palette.textQuaternary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 11).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .benchCard(fill: Bench.Palette.card,
                               stroke: Bench.Palette.cardStrokeSoft, radius: 9)
                }
            }
            .padding(.horizontal, 20).padding(.top, 18)
        }
    }

    /// The A/B switch. Both sides play from the same transport, so the pane
    /// says which one is loaded rather than leaving two play buttons to
    /// disagree with the bar.
    private var abRow: some View {
        HStack(spacing: 4) {
            abKey("EDITED", active: !playingOriginal) {
                playingOriginal = false
                playback.play(url: song.fileURL, songId: song.id,
                              title: song.title, duration: song.durationS,
                              subtitle: SongDetailView.subtitle(for: song))
            }
            abKey("ORIGINAL", active: playingOriginal) {
                playingOriginal = true
                // A distinct songId, or the transport treats this as the
                // same track and just toggles pause.
                playback.play(url: song.backupURL,
                              songId: song.originalPlaybackId,
                              title: song.title,
                              duration: originalDuration ?? song.durationS,
                              subtitle: "ORIGINAL · "
                                  + song.sourceLabel.uppercased())
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.button,
                                     style: .continuous)
            .fill(Bench.Palette.raised))
        .overlay(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.button,
                                  style: .continuous)
            .strokeBorder(Bench.Palette.cardStrokeSoft, lineWidth: 1))
        .fixedSize()
    }

    private func abKey(_ label: String, active: Bool,
                       action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(Bench.Typo.mono(10, .bold))
                .foregroundStyle(active ? Bench.Palette.onAccent
                                        : Bench.Palette.textQuaternary)
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 5,
                                             style: .continuous)
                    .fill(active ? Bench.Palette.accent : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var originalDuration: Double? {
        appliedDocument?.originalDurationS
    }

    /// Past tense, because these already happened: "Deleted 0:38 → 0:52".
    private func appliedLine(_ kind: EditOp.Kind) -> String {
        switch kind {
        case .delete(let range):
            "Deleted \(EditorClock.full(range.start)) → "
                + EditorClock.full(range.end)
        case .trim(let range):
            "Trimmed to \(EditorClock.full(range.start)) → "
                + EditorClock.full(range.end)
        case .silence(let range):
            "Silenced \(EditorClock.full(range.start)) → "
                + EditorClock.full(range.end)
        case .insertGap(let at, let seconds):
            String(format: "Inserted %.1f s of silence at ", seconds)
                + EditorClock.full(at)
        case .splitAt(let at): "Split at \(EditorClock.full(at))"
        case .paste: "Pasted a region"
        case .reverse(let range):
            "Reversed \(EditorClock.full(range.start)) → "
                + EditorClock.full(range.end)
        case .amplify(_, let db): String(format: "Amplified %+.1f dB", db)
        case .fadeIn(let seconds, _):
            String(format: "Fade in %.2f s", seconds)
        case .fadeOut(let seconds, _):
            String(format: "Fade out %.2f s", seconds)
        case .normalize(let lufs):
            String(format: "Normalised to %.0f LUFS", lufs)
        case .speed(let rate):
            String(format: "Speed %d%%", Int((rate * 100).rounded()))
        case .pitch(let semitones):
            String(format: "Pitch %+.0f st", semitones)
        case .resample(let hz): "Resampled to \(hz.formatted(.number)) Hz"
        }
    }

    /// Recombined songs list the parts they were built from. The design has no
    /// slot for this, but it is the only place a mix says what went into it.
    ///
    /// Only a recombined song ever has rows here — `loadTrackFacts` asks the
    /// question, so the origin test lives there rather than in this builder.
    @ViewBuilder
    private var ingredients: some View {
        if !ingredientRows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("INGREDIENTS").eyebrow()
                    Spacer()
                    Button("Edit in Workbench") { actions.openMix(song) }
                        .buttonStyle(.plain)
                        .font(Bench.Typo.caption)
                        .foregroundStyle(Bench.Palette.accent)
                }
                ForEach(ingredientRows, id: \.slotId) { row in
                    HStack(spacing: 8) {
                        StemBar(kind: row.slotId, width: 4, height: 12)
                        Text("\(row.slotId) · \(library.sourceTitle(for: row))")
                            .font(Bench.Typo.secondary)
                            .foregroundStyle(Bench.Palette.textSecondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 20).padding(.top, 18)
        }
    }

    private var notes: some View {
        TextEditor(text: $editor.notes)
            .focused($notesFocused)
            .textEditorStyle(.plain)
            .tint(Bench.Palette.accent)
            .scrollContentBackground(.hidden)
            .font(Bench.Typo.secondary)
            .foregroundStyle(Bench.Palette.textSecondary)
            .frame(minHeight: 52)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Bench.Palette.windowBackground))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Bench.Palette.cardStroke, lineWidth: 1))
            .onChange(of: editor.notes) { editor.notesEdited(in: library) }
    }

    // MARK: actions

    /// One of the three reuse tiles.
    ///
    /// All three are refused on an import for the same reason: there is no
    /// render to repeat. "+ seed" is refused on one more — a take from a model
    /// with no seed of its own has nothing to pin, and the tile says so rather
    /// than pretending to offer it.
    private func reuseTile(_ scope: ReuseScope,
                           action: @escaping () -> Void) -> some View {
        let isGenerated = song.originKind == .generated
        let hasSeed = song.seedUsed != nil
        let isEnabled = isGenerated && (scope != .allWithSeed || hasSeed)
        return LibraryActionTile(
            title: scope.shortTitle,
            isEnabled: isEnabled,
            help: isEnabled ? scope.help
                : isGenerated
                    ? "This track was rendered by a model that has no seed"
                    : "Only generated tracks carry settings to reuse",
            action: action)
    }

    /// Four rows of three, grouped by what the row is for: generate again
    /// from this track, make something else from it, work on the track
    /// itself, then the file it lives in.
    ///
    /// Nine tiles over two rows (five and four) was 66 pt each in this pane's
    /// 364 pt, which is not a width a label survives — the panel read "Reuse
    /// p…", "Split int…", "Reveal in Fi…". Three to a row is 116 pt, and the
    /// grouping is what makes the rows scannable rather than just shorter:
    /// you look for the row before you look for the tile. That 116 pt is also
    /// why the reuse tiles read "Reuse all" where a menu says "Reuse all
    /// parameters" — the longer label only fits by shrinking to a size that
    /// looks like a rendering fault.
    /// Said above the action grid, where the Export tile that caused it is —
    /// same caption-and-danger treatment `PartInspector` gives a refused
    /// rename.
    private func exportFailureLine(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(message)
                .font(Bench.Typo.caption)
                .foregroundStyle(Bench.Palette.dangerText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Dismiss") { exportError = nil }
                .buttonStyle(.bench(.quiet))
        }
        .padding(.horizontal, 20).padding(.top, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actionGrid: some View {
        VStack(spacing: 8) {
            // Generate again from it, in three sizes.
            HStack(spacing: 8) {
                reuseTile(.prompt) { actions.reusePrompt(song) }
                reuseTile(.all) { actions.reuseAll(song) }
                reuseTile(.allWithSeed) { actions.reuseAllWithSeed(song) }
            }
            // Make something new from it. Two tiles and a held-open third
            // slot, so this row's buttons are the same width as every other
            // row's rather than stretching to fill it.
            HStack(spacing: 8) {
                LibraryActionTile(
                    title: "Restyle…",
                    help: "Open this track in Style Transfer"
                ) { actions.restyle(song) }
                LibraryActionTile(
                    title: "Find matches",
                    help: "Find library tracks that combine well with this one"
                ) { actions.findMatches(song) }
                Spacer().frame(maxWidth: .infinity)
            }
            // Work on the track itself.
            HStack(spacing: 8) {
                LibraryActionTile(
                    title: "Edit…",
                    help: "Trim, cut, fade and level this track"
                ) { actions.edit(song) }
                LibraryActionTile(
                    title: "Split into…",
                    help: "Split this track into stems, notes or features"
                ) { actions.split(song) }
                LibraryActionTile(
                    title: "Describe…",
                    help: "A model listens and writes the track down"
                ) { actions.describe(song) }
            }
            // The file on disk. Delete belongs here rather than alone: it is
            // an act on the file, and it is the row you are already in when
            // you have decided the track is not worth keeping.
            HStack(spacing: 8) {
                LibraryActionTile(title: "Export…",
                                  help: "Save a copy of the audio file") {
                    exportSong()
                }
                LibraryActionTile(title: "Reveal in Finder",
                                  help: "Show the audio file in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([song.fileURL])
                }
                LibraryActionTile(title: "Delete…", tone: .destructive,
                                  help: "Delete this track and its audio file") {
                    requestDelete()
                }
            }
        }
    }

    // MARK: persistence

    private func setRating(_ rating: Int) {
        var updated = song
        updated.rating = rating == song.rating ? 0 : rating
        library.update(updated)
    }

    /// Export is a copy, so the offered name has to carry the file's real
    /// extension. It used to say `.wav` for everything, which renamed an
    /// imported mp3 or flac into a lie that nothing downstream could open.
    static func exportName(title: String, fileName: String) -> String {
        let base = title.replacingOccurrences(of: "/", with: "-")
        let ext = (fileName as NSString).pathExtension
        return ext.isEmpty ? base : "\(base).\(ext)"
    }

    private func exportSong() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = Self.exportName(title: song.title,
                                                     fileName: song.fileName)
        let source = song.fileURL
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            exportError = Self.export(source, to: url)
        }
    }

    /// Copy `source` onto `destination`, leaving whatever is already there
    /// untouched unless the copy succeeds. Returns the message to show, nil on
    /// success.
    ///
    /// This used to be `try? removeItem` followed by `try? copyItem`, which got
    /// both halves wrong: answering "Replace" in the save panel deleted the old
    /// file *before* the copy was attempted, so a full disk, a read-only volume
    /// or a source on an unmounted external left the user with neither file —
    /// and both `try?`s meant the panel simply closed and the export looked
    /// like it had worked. Staged beside the destination and swapped in, so
    /// the old file survives a failed export and the failure gets said out loud.
    static func export(_ source: URL, to destination: URL) -> String? {
        let fm = FileManager.default
        let staged = destination.deletingLastPathComponent()
            .appendingPathComponent("." + UUID().uuidString + "-"
                                    + destination.lastPathComponent)
        do {
            try fm.copyItem(at: source, to: staged)
        } catch {
            return "Export failed: \(error.localizedDescription)"
        }
        do {
            if fm.fileExists(atPath: destination.path) {
                // `replaceItemAt` consumes the staged file; it needs the
                // original to exist, hence the branch.
                _ = try fm.replaceItemAt(destination, withItemAt: staged)
            } else {
                try fm.moveItem(at: staged, to: destination)
            }
            return nil
        } catch {
            try? fm.removeItem(at: staged)
            return "Export failed: \(error.localizedDescription)"
        }
    }
}

/// The waveform well and the transport row: everything on the pane that the
/// playhead moves, and nothing else.
///
/// Its own view rather than two properties on the pane, because under
/// Observation a body is subscribed to every property it reads — so reading
/// `playback.currentTime` from `SongDetailView.body` put the whole inspector
/// on the transport's 4 Hz tick, tags query, edit-document decode, file
/// measurements and all. Fenced in here, the tick redraws a waveform and a
/// clock, which is what it is for.
private struct SongDetailHero: View {
    let song: SongRecord
    let playback: PlaybackController
    let onRate: (Int) -> Void

    private var isCurrent: Bool { playback.currentSongId == song.id }

    /// `currentSongId` first and the guard before `currentTime`, exactly as
    /// `LibrarySongRow.playedFraction` explains: the order is the difference
    /// between this view redrawing while its own track plays and it redrawing
    /// while any track does.
    private var playedFraction: Double {
        guard isCurrent, song.durationS > 0 else { return 0 }
        return playback.currentTime / song.durationS
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            hero
            transportLine
        }
    }

    private var hero: some View {
        BenchWaveformWell(height: 96) {
            BenchWaveformLoader(
                audioURL: song.fileURL, cacheURL: song.waveformURL,
                playedFraction: playedFraction,
                barPitch: 2.5,
                onSeek: { fraction in
                    // Load first, seek second: seeking before the item is
                    // replaced moves whatever was playing before.
                    if !isCurrent {
                        playback.play(url: song.fileURL, songId: song.id,
                                      title: song.title,
                                      duration: song.durationS,
                                      subtitle: SongDetailView.subtitle(for: song))
                    }
                    playback.seek(to: fraction * song.durationS)
                })
        }
    }

    private var transportLine: some View {
        HStack(spacing: 12) {
            BenchTransportButton(isPlaying: isCurrent && playback.isPlaying,
                                 size: 32) {
                playback.play(url: song.fileURL, songId: song.id,
                              title: song.title, duration: song.durationS,
                              subtitle: SongDetailView.subtitle(for: song))
            }
            Text("\(LibraryFormat.clock(isCurrent ? playback.currentTime : 0))"
                 + " / \(LibraryFormat.clock(song.durationS))")
                .font(Bench.Typo.mono(12))
                .foregroundStyle(Bench.Palette.textTertiary)
            Spacer(minLength: 8)
            RatingStars(rating: song.rating, size: 15, spacing: 2,
                        onRate: { onRate($0) })
        }
    }
}

extension View {
    /// Show the library's detail pane over this view. Same `SongDetailView` the
    /// library inspector renders, only sized for a popover — anything added to
    /// the pane turns up here too.
    func songDetailPopover(song: SongRecord, isPresented: Binding<Bool>,
                           library: LibraryStore, playback: PlaybackController,
                           actions: SongActions) -> some View {
        popover(isPresented: isPresented) {
            SongDetailView(song: song, library: library, playback: playback,
                           actions: actions,
                           onDeleted: { isPresented.wrappedValue = false })
                // A popover has no size of its own, and the pane's scroll view
                // would collapse to nothing without one.
                .frame(width: 420, height: 560)
        }
    }
}

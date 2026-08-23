import AppKit
import SwiftUI

/// What a track's detail pane can do beyond editing it in place: the three
/// jumps into another tab. Wired once by `MainWindow` and handed to every
/// place the pane appears, so they all offer the same actions.
struct SongActions {
    var reusePrompt: (SongRecord) -> Void = { _ in }
    var split: (SongRecord) -> Void = { _ in }
    var findMatches: (SongRecord) -> Void = { _ in }
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

    @State private var editor = SongEditor()
    @State private var confirmDelete = false
    /// True while the stashed original is what the transport is playing —
    /// the pane's own A/B, distinct from the library's two-row compare.
    @State private var playingOriginal = false
    /// Ambient, optional: previews and tests host this pane without an
    /// environment, and "no settings" must read as "ask", the safe default.
    @Environment(AppSettings.self) private var appSettings: AppSettings?

    private var isCurrent: Bool { playback.currentSongId == song.id }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 14) {
                        header
                        hero
                        transportLine
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 20).padding(.bottom, 14)

                    metadata
                        .padding(.horizontal, 20)

                    editsBlock

                    ingredients

                    VStack(alignment: .leading, spacing: 10) {
                        Text("TAGS").eyebrow()
                        LibraryTagField(tags: library.tags(for: song.id)) { tags in
                            editor.tagsText = tags.joined(separator: ", ")
                            editor.commitTags(in: library)
                        }
                        Text("NOTES").eyebrow()
                            .padding(.top, 6)
                        notes
                    }
                    .padding(.horizontal, 20).padding(.vertical, 18)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            actionGrid
                .padding(.horizontal, 20)
                .padding(.top, 16).padding(.bottom, 20)
        }
        .background(Bench.Palette.panel)
        .onChange(of: song.id, initial: true) { editor.load(song, in: library) }
        // The pane can go away without a field ever losing focus — a popover
        // dismissed, a tab switched — so buffered edits are written on the way out.
        .onDisappear { editor.flush(in: library) }
        .confirmationDialog("Delete “\(song.title)”?", isPresented: $confirmDelete) {
            Button("Delete song and audio file", role: .destructive) {
                deleteNow()
            }
        }
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
        playback.stop(songId: song.id)
        library.delete(song)
        onDeleted()
    }

    // MARK: header

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                TextField("Title", text: $editor.title,
                          onCommit: { editor.commitTitle(in: library) })
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
                                  songId: song.id + ".original",
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

    // MARK: hero

    private var hero: some View {
        BenchWaveformWell(height: 96) {
            BenchWaveformLoader(
                audioURL: song.fileURL, cacheURL: song.waveformURL,
                playedFraction: isCurrent && song.durationS > 0
                    ? playback.currentTime / song.durationS : 0,
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
                        onRate: { setRating($0) })
        }
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
            if let size = LibraryFormat.fileSize(of: song.fileURL) {
                BenchInfoRow("Size", size, mono: true)
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
                              songId: song.id + ".original",
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

    private var appliedDocument: EditDocument? {
        guard song.editedAt != nil, let json = song.editsJSON,
              let document = try? JSONDecoder().decode(
                EditDocument.self, from: Data(json.utf8)),
              !document.isEmpty else { return nil }
        return document
    }

    private var hasBackup: Bool {
        FileManager.default.fileExists(atPath: song.backupURL.path)
    }

    private var backupSize: String? {
        LibraryFormat.fileSize(of: song.backupURL)
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
    @ViewBuilder
    private var ingredients: some View {
        if song.originKind == .recombined, let partsRepo = library.partsRepo,
           let rows = try? partsRepo.ingredients(songId: song.id),
           !rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("INGREDIENTS").eyebrow()
                    Spacer()
                    Button("Edit in Workbench") { actions.openMix(song) }
                        .buttonStyle(.plain)
                        .font(Bench.Typo.caption)
                        .foregroundStyle(Bench.Palette.accent)
                }
                ForEach(rows, id: \.slotId) { row in
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

    /// Two rows of three. Six plain buttons in a single row left only the first
    /// few characters of each title readable in this pane's width.
    private var actionGrid: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                LibraryActionTile(
                    title: "Reuse prompt",
                    isEnabled: song.originKind == .generated,
                    help: song.originKind == .generated
                        ? "Start a new generation from this track's prompt"
                        : "Only generated tracks carry a prompt to reuse"
                ) { actions.reusePrompt(song) }
                LibraryActionTile(
                    title: "Edit…",
                    help: "Trim, cut, fade and level this track"
                ) { actions.edit(song) }
                LibraryActionTile(
                    title: "Restyle…",
                    help: "Open this track in Style Transfer"
                ) { actions.restyle(song) }
                LibraryActionTile(
                    title: "Split into…",
                    help: "Split this track into stems, notes or features"
                ) { actions.split(song) }
                LibraryActionTile(
                    title: "Find matches",
                    help: "Find library tracks that combine well with this one"
                ) { actions.findMatches(song) }
            }
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
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.copyItem(at: song.fileURL, to: url)
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

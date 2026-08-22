import AppKit
import SwiftUI

/// The Parts scope's 404 pt inspector — the part equivalent of
/// `SongDetailView`, and deliberately not the same view: a part has no prompt,
/// no seed and no rating, and it does have a stem colour, a source song and
/// siblings that a song does not.
///
/// The colour is carried through the swatch, the badge, the playhead and the
/// sibling chips, which is the design's rule that stem identity is a colour
/// rather than a label you have to read.
///
/// **The action grid is six tiles, but not the design's six.** The design
/// (full.html:1150) puts `Restyle with AI` third; this grid puts the part's own
/// generative route there instead — `Use as melody` for audio, `Render…` for
/// notes — and that is deliberate rather than an omission. `Restyle` is a
/// recipe (`RecipeCatalog`, `Recipe(id: "restyle")`) with two slots and a model
/// choice, and recipes are launched from Actions, which owns slot filling,
/// model availability and the "you'll get back" narration. Nothing in the app
/// can currently carry a preselected part into an Actions route, so a tile here
/// would either be permanently dimmed or would drop the user on a blank action
/// page having thrown their selection away. When that route exists — an intent
/// like `StudioBox.StudioIntent.findMatches`, but naming a recipe — this tile
/// should come back and take the third slot the design gives it.
struct PartInspector: View {
    let part: PartRecord
    let analysis: AnalysisRecord?
    let sourceTitle: String
    /// The other parts cut from the same song, already fetched by the screen.
    let siblings: [PartRecord]
    let parts: PartsStore
    let playback: PlaybackController
    let onAddToWorkbench: (PartRecord) -> Void
    let onUseMelody: (URL) -> Void
    var onRenderNotes: ((PartRecord) -> Void)?
    let onFindMatches: (String) -> Void
    /// Open this stem in the Editor. Optional so the popover construction
    /// elsewhere stays source-compatible; a nil closure dims the tile.
    var onEdit: ((PartRecord) -> Void)?
    let onSelectSibling: (String) -> Void
    let onDeleted: () -> Void

    @State private var confirmDelete = false
    /// The buffered name and the part it was typed for.
    ///
    /// Keyed by id rather than read straight off `part`, for the reason
    /// `SongEditor` documents at length: a macOS field commits on Return *and*
    /// on losing focus, so a commit can land after the list selection has
    /// already moved. Writing to "the part the pane is showing now" would put
    /// the typed name on the neighbouring stem. Empty id means nothing is
    /// buffered and the field shows what is stored.
    @State private var draft: (id: String, text: String) = ("", "")
    /// Why the last rename was refused, cleared as soon as one succeeds or the
    /// pane moves to another part. The field reverts on refusal, so without
    /// this the name would simply spring back with no explanation.
    @State private var renameError: String?

    private var stem: Color { Bench.Palette.stem(part.kind) }
    private var isCurrent: Bool { playback.currentSongId == part.id }
    private var duration: Double { part.durationS ?? 0 }

    private var playedFraction: Double {
        guard isCurrent, duration > 0 else { return 0 }
        return playback.currentTime / duration
    }

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

                    if !siblings.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("SIBLING PARTS").eyebrow()
                            FlowLayout(spacing: 6, rowSpacing: 6) {
                                ForEach(siblings, id: \.id) { sibling in
                                    Button {
                                        onSelectSibling(sibling.id)
                                    } label: {
                                        BenchTag(
                                            // The kind, not the name: every
                                            // sibling here came out of the
                                            // song this pane is already about,
                                            // so their names all start with
                                            // the same forty characters.
                                            text: PartNaming
                                                .label(kind: sibling.kind),
                                            color: Bench.Palette.stem(sibling.kind),
                                            fill: Bench.Palette.stem(sibling.kind)
                                                .opacity(0.12))
                                    }
                                    .buttonStyle(.plain)
                                    .help("Show \(sibling.name)")
                                }
                            }
                        }
                        .padding(.horizontal, 20).padding(.vertical, 18)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            actionGrid
                .padding(.horizontal, 20)
                .padding(.top, 16).padding(.bottom, 20)
        }
        .background(Bench.Palette.panel)
        .confirmationDialog("Delete “\(part.name)”?", isPresented: $confirmDelete) {
            Button("Delete part and its files", role: .destructive) {
                playback.stop(songId: part.id)
                parts.delete(part)
                onDeleted()
            }
        }
    }

    // MARK: header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            headerRow
            if let renameError {
                // The field has already sprung back to the stored name by the
                // time this is read; this says why rather than leaving the
                // revert looking like dropped input.
                Text(renameError)
                    .font(Bench.Typo.caption)
                    .foregroundStyle(Bench.Palette.dangerText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // Commit for the part it was typed for, then clear, so the field falls
        // back to whatever is stored — the new name on success, the old one on
        // a refusal.
        .onChange(of: part.id) { commitName() }
        .onDisappear { commitName() }
    }

    /// A part's name is its own, editable here exactly as a track's title is
    /// in `SongDetailView`. What KIND of part it is stays on the badge beside
    /// it and in the colour of the bar, so renaming can never cost the reader
    /// the one thing the row has to say.
    private var nameField: some View {
        TextField("Name", text: Binding(
            get: { draft.id == part.id ? draft.text : part.name },
            set: { draft = (part.id, $0) }),
            onCommit: { commitName() })
            .textFieldStyle(.plain)
            .font(Bench.Typo.inspectorTitle)
            .tracking(-0.17)
            .foregroundStyle(Bench.Palette.textPrimary)
            .lineLimit(1)
    }

    private func commitName() {
        let target = draft.id
        guard !target.isEmpty else { renameError = nil; return }
        let typed = draft.text
        draft = ("", "")
        renameError = parts.rename(id: target, to: typed)
    }

    private var headerRow: some View {
        HStack(spacing: 10) {
            StemBar(kind: part.kind, width: 8, height: 22)
            nameField
            LibraryStemBadge(text: kindLabel, color: stem)
            Spacer(minLength: 4)
            Button {
                parts.setFavorite(part, to: !part.favorite)
            } label: {
                Image(systemName: part.favorite ? "heart.fill" : "heart")
                    .font(.system(size: 13))
                    .foregroundStyle(part.favorite ? TrackRow.favouriteHeart
                                                   : Bench.Palette.textFaint)
            }
            .buttonStyle(.plain)
            .help(part.favorite ? "Remove from favourites" : "Mark as a favourite")
            Menu {
                Button("Export…") { exportPart() }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([part.fileURL])
                }
                Divider()
                Button("Delete…", role: .destructive) { confirmDelete = true }
            } label: {
                Text("···")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Bench.Palette.textFaintest)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    /// The first component of the dot-namespaced kind — `stem.drums` is a
    /// STEM, `notes.piano` is NOTES. State is a badge, not a colour alone.
    private var kindLabel: String {
        (part.kind.split(separator: ".").first.map(String.init) ?? part.format)
            .uppercased()
    }

    // MARK: hero

    /// The well draws the part's own signal or nothing at all. For a notes part
    /// that is the WAV the split rendered beside the MIDI — the same file the
    /// play button below plays — so the hero and the transport always describe
    /// one recording rather than two different ideas of the part.
    @ViewBuilder
    private var hero: some View {
        if let url = part.auditionURL {
            BenchWaveformWell(height: 96) {
                BenchWaveformLoader(audioURL: url, cacheURL: part.waveformURL,
                                    playedFraction: playedFraction,
                                    tint: stem, barPitch: 2.5,
                                    onSeek: seek)
            }
        } else {
            BenchWaveformWell(height: 96) {
                Text(emptyHeroMessage)
                    .font(Bench.Typo.small)
                    .foregroundStyle(Bench.Palette.textFaint)
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: .leading)
            }
        }
    }

    /// `auditionURL` is nil for two unrelated reasons, and only one of them is
    /// "not audio": a features part never had any, while a notes part is
    /// waiting for the render the action grid below is offering. Branching on
    /// `format` rather than on the missing URL keeps the well from telling a
    /// MIDI part it is analysis data while the row two panes away offers to
    /// render it. The notes line tracks whether that route is actually live, so
    /// the well never points at a tile that is dimmed.
    private var emptyHeroMessage: String {
        switch part.format {
        case "json":
            return "This part is analysis data, not audio"
        case "midi":
            return onRenderNotes == nil
                ? "No rendered preview yet — needs a model that can render notes"
                : "No rendered preview yet — “Render…” below makes one"
        default:
            return "This part has no audio to play"
        }
    }

    @ViewBuilder
    private var transportLine: some View {
        HStack(spacing: 12) {
            if let url = part.auditionURL {
                BenchTransportButton(isPlaying: isCurrent && playback.isPlaying,
                                     size: 32) {
                    playback.play(url: url, songId: part.id, title: part.name,
                                  duration: duration, subtitle: subtitle)
                }
                Text("\(LibraryFormat.clock(isCurrent ? playback.currentTime : 0))"
                     + " / \(LibraryFormat.clock(duration))")
                    .font(Bench.Typo.mono(12))
                    .foregroundStyle(Bench.Palette.textTertiary)
            }
            Spacer(minLength: 8)
            // Outside the audio branch on purpose. The list draws five stars
            // on every part, so every part needs somewhere to fill them —
            // including the notes and features parts that have no transport
            // to sit beside.
            RatingStars(rating: part.rating, size: 15, spacing: 2,
                        onRate: { parts.setRating(part, to: $0) })
        }
    }

    /// `BAGPIPES PLAYING A… · 107 BPM · 8B` — the transport bar's second line.
    private var subtitle: String {
        var fields = [sourceTitle]
        if let bpm = analysis?.bpm { fields.append("\(Int(bpm.rounded())) BPM") }
        if let camelot = analysis?.camelot { fields.append(camelot) }
        return fields.joined(separator: " · ").uppercased()
    }

    private func seek(_ fraction: Double) {
        guard let url = part.auditionURL else { return }
        // Load first, seek second — seeking before the item is replaced moves
        // whatever was playing before this part.
        if !isCurrent {
            playback.play(url: url, songId: part.id, title: part.name,
                          duration: duration, subtitle: subtitle)
        }
        playback.seek(to: fraction * duration)
    }

    // MARK: metadata

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 9) {
            BenchInfoRow(label: "From") {
                Text(sourceTitle)
                    .foregroundStyle(Bench.Palette.textSecondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            BenchInfoRow("Separator", part.modelName)
            BenchInfoRow("Kind", part.kind, mono: true)
            if let tempoAndKey = LibraryFormat.tempoAndKey(analysis) {
                BenchInfoRow("Tempo · key", tempoAndKey, mono: true)
            }
            let grid = LibraryFormat.beatGrid(analysis)
            BenchInfoRow("Beat grid", grid.text,
                         color: grid.detected ? Bench.Palette.ok
                                              : Bench.Palette.textMuted)
            if let seconds = part.durationS {
                BenchInfoRow("Length", part.sampleRate.map {
                    "\(LibraryFormat.seconds(seconds)) s · "
                        + "\($0.formatted(.number)) Hz"
                } ?? "\(LibraryFormat.seconds(seconds)) s", mono: true)
            }
            if let size = LibraryFormat.fileSize(of: part.fileURL) {
                BenchInfoRow("Size", size, mono: true)
            }
            BenchInfoRow("Created",
                         part.createdAt.formatted(date: .abbreviated,
                                                  time: .shortened))
        }
    }

    // MARK: actions

    /// Two columns, three rows, with the lime tile in the top-left: a part
    /// exists to be put on the bench, and the panel should say so before it
    /// offers anything else.
    private var actionGrid: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                LibraryActionTile(
                    title: "Add to Workbench", tone: .primary,
                    isEnabled: part.format != "json",
                    help: part.format == "json"
                        ? "This part is analysis data, not audio"
                        : "Add this part to the Workbench"
                ) { onAddToWorkbench(part) }
                LibraryActionTile(
                    title: "Find matches",
                    isEnabled: part.format == "wav",
                    help: part.format == "wav"
                        ? "Rank the library by musical compatibility with this part"
                        : "Only audio parts can be ranked for compatibility"
                ) { onFindMatches(part.id) }
            }
            HStack(spacing: 8) {
                secondaryGenerativeTile
                // Stems are editable too: topping and tailing them, and
                // levelling them against each other, is what you do before
                // a mix.
                LibraryActionTile(
                    title: "Edit…",
                    isEnabled: part.format == "wav" && onEdit != nil,
                    help: part.format == "wav"
                        ? "Trim, cut, fade and level this stem"
                        : "Only audio parts can be edited"
                ) { onEdit?(part) }
            }
            HStack(spacing: 8) {
                LibraryActionTile(title: "Export…",
                                  help: "Save a copy of this part's file") {
                    exportPart()
                }
                LibraryActionTile(title: "Reveal in Finder",
                                  help: "Show this part's file in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([part.fileURL])
                }
            }
            LibraryActionTile(title: "Delete…", tone: .destructive,
                              help: "Delete this part and its files") {
                confirmDelete = true
            }
        }
    }

    /// The one tile whose meaning depends on the part: audio can seed a new
    /// generation, notes can be played through a SoundFont. Both stay visible
    /// and say why they are unavailable rather than vanishing, so the panel
    /// does not change shape between parts.
    @ViewBuilder
    private var secondaryGenerativeTile: some View {
        if part.format == "midi" {
            LibraryActionTile(
                title: "Render…",
                isEnabled: onRenderNotes != nil,
                help: onRenderNotes != nil
                    ? "Render these notes with the SoundFont — the audio lands "
                        + "back in Parts, ready to restyle or mix"
                    : "Needs an installed model that can render notes"
            ) { onRenderNotes?(part) }
        } else {
            LibraryActionTile(
                title: "Use as melody",
                isEnabled: part.format == "wav",
                help: part.format == "wav"
                    ? "Start a new song in Generate that follows this part's melody"
                    : "Only audio parts can be used as a melody"
            ) { onUseMelody(part.fileURL) }
        }
    }

    private func exportPart() {
        let ext: String
        switch part.format {
        case "midi": ext = "mid"
        case "json": ext = "json"
        default: ext = "wav"
        }
        let panel = NSSavePanel()
        // The name carries its source now, so prefixing the song title again
        // would export `track042 — vocals-track042.wav`.
        panel.nameFieldStringValue = part.name
            .replacingOccurrences(of: "/", with: "-") + ".\(ext)"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            parts.export(part, to: url)
        }
    }
}

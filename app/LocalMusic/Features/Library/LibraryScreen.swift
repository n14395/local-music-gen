import SwiftUI

/// Library — one screen for Generated Songs, Imported, Parts and Renders.
///
/// The three scopes share a shell, a row grammar and an inspector slot, and
/// that is the point: browsing stems used to be a different screen inside Split
/// & Recombine with its own list, its own filters and its own detail pane, so
/// the same material read as two unrelated things depending on how you arrived.
/// Here a scope is a filter over the same furniture.
///
/// The three whole-track scopes are one table read three ways — they differ
/// only in `origin` — so switching between them only moves
/// `LibraryRepository.Filters.origin`. Parts come from a different table, which
/// is why the Parts scope swaps the whole list and inspector rather than just
/// the query.
struct LibraryScreen: View {
    let library: LibraryStore
    let parts: PartsStore
    let jobs: JobsStore
    let playback: PlaybackController
    @Binding var scope: LibraryScope
    let actions: SongActions
    let onAddToWorkbench: (PartRecord) -> Void
    let onRenderNotes: ((PartRecord) -> Void)?
    let onUseMelody: (URL) -> Void
    let onFindMatches: (String) -> Void
    /// Open a stem in the Editor.
    var onEditPart: ((PartRecord) -> Void)?
    /// Held by the shell when it wants the transport bar's `A|B` switch, since
    /// that bar lives outside this screen. Left nil the comparison still works,
    /// it just has no representation down there.
    var compare: LibraryCompare?

    @State private var selectedSongId: String?
    @State private var selectedPartId: String?
    /// Ticked rows. Two of them is what reveals the A/B affordance.
    @State private var checked: Set<String> = []
    @State private var showImporter = false
    @State private var isDropTargeted = false
    @State private var groupBySong = true
    @State private var ownCompare = LibraryCompare()

    // Derived database reads, refreshed when the stores change rather than on
    // every redraw: the transport clock ticks four times a second and would
    // otherwise drag a fistful of queries along with it.
    @State private var counts = ScopeCounts()
    @State private var partCounts: [String: Int] = [:]
    @State private var songTitles: [String: String] = [:]
    /// Which origin each of those songs has, so the parts filter can group them.
    @State private var songOrigins: [String: SongOrigin] = [:]
    /// Read from the whole table rather than from `results`, so picking an
    /// artist doesn't narrow the menu you picked it from down to that one name.
    @State private var artists: [String] = []
    @State private var partGroups: [LibraryPartGroup] = []
    /// Whether the Edited scope is what set the "recently edited" sort — as
    /// opposed to the user picking it.
    @State private var promotedSort = false
    @State private var siblings: [PartRecord] = []

    private struct ScopeCounts: Equatable {
        var songs = 0
        var imported = 0
        var parts = 0
        var renders = 0
        var edited = 0
        var favourites = 0
    }

    private var box: LibraryCompare { compare ?? ownCompare }
    private var songs: [SongRecord] { library.results }
    private var selectedSong: SongRecord? {
        songs.first { $0.id == selectedSongId }
    }
    private var selectedPart: PartRecord? {
        parts.results.first { $0.id == selectedPartId }
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            filterBar
            HStack(spacing: 0) {
                listPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                BenchInspector(width: Bench.Metrics.Inspector.library) {
                    inspector
                }
            }
            .frame(maxHeight: .infinity)
        }
        .background(Bench.Palette.windowBackground)
        .onAppear {
            applyScope()
            library.refreshSearch()
            parts.refresh()
            refreshDerived()
        }
        // The scope's filters belong to this screen, not to the stores — left
        // set, the sidebar's library count and every picker elsewhere in the
        // app would silently be showing "renders only", or "hearted only".
        .onDisappear {
            library.filters.origin = .any
            library.filters.favoritesOnly = false
            library.filters.hasEdits = false
            if promotedSort, library.filters.sort == .recentlyEdited {
                library.filters.sort = .newest
                promotedSort = false
            }
            library.filters.artist = nil
            parts.filters.favoritesOnly = false
        }
        .onChange(of: scope) { applyScope() }
        .onChange(of: library.results) { refreshDerived() }
        .onChange(of: parts.results) { refreshDerived() }
        .onChange(of: groupBySong) { rebuildGroups() }
        .onChange(of: selectedPartId) { refreshSiblings() }
        .onChange(of: checked) {
            // A comparison is exactly the ticked pair; untick one and there is
            // nothing left to compare.
            if checked.count < 2 { box.end() }
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.audio],
                      allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task { await receive(urls) }
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        BenchTopBar {
            Text("Library")
                .font(Bench.Typo.screenTitle)
                .tracking(-0.15)
                .foregroundStyle(Bench.Palette.textPrimary)
            // Which scope you are in is chosen (and shown) in the sidebar; the
            // title says which one you are looking at rather than repeating
            // the switch here.
            Text(scope.title.uppercased())
                .font(Bench.Typo.counter)
                .foregroundStyle(Bench.Palette.textFaintest)
                .padding(.leading, 2)
        } trailing: {
            HStack(spacing: 9) {
                BenchSearchField(text: searchText,
                                 placeholder: searchPlaceholder,
                                 width: scope == .parts ? 230 : 250)
                // Offered from Generated Songs too: that is where you are when
                // it occurs to you to bring something in, and hiding the button
                // until you have already found the Imported scope makes the
                // feature discoverable only to someone who knows it exists.
                if scope == .songs || scope == .imported {
                    Button("Import audio…") { showImporter = true }
                        .buttonStyle(.benchSecondary)
                        .help("Import audio files as library songs")
                }
            }
        }
    }

    /// The placeholder names what is actually in the index for this scope —
    /// offering to search prompts and lyrics in a list of imported records
    /// would be describing fields none of those rows have.
    private var searchPlaceholder: String {
        switch scope {
        case .parts: "Search parts…"
        case .imported: "Search titles, artists, notes…"
        default: "Search prompts, lyrics, notes…"
        }
    }

    /// One field, two stores: the search box means "search what is on screen".
    private var searchText: Binding<String> {
        scope == .parts
            ? Binding(get: { parts.filters.query },
                      set: { parts.filters.query = $0 })
            : Binding(get: { library.filters.query },
                      set: { library.filters.query = $0 })
    }

    // MARK: - Filter bar

    @ViewBuilder
    private var filterBar: some View {
        BenchFilterBar {
            if scope == .parts { partFilters } else { songFilters }
        }
    }

    @ViewBuilder
    private var songFilters: some View {
        // Imports were all made by "Imported", so the model menu has nothing to
        // narrow there; the equivalent question about a record is who played it.
        if scope == .imported {
            BenchMenu(label: library.filters.artist ?? "Any artist") {
                Button("Any artist") { library.filters.artist = nil }
                if !artists.isEmpty {
                    Divider()
                    ForEach(artists, id: \.self) { artist in
                        Button(artist) { library.filters.artist = artist }
                    }
                }
            }
        } else {
            BenchMenu(label: modelLabel) {
                Button("Any model") { library.filters.modelId = nil }
                Divider()
                ForEach(models, id: \.id) { model in
                    Button(model.name) { library.filters.modelId = model.id }
                }
            }
        }
        BenchMenu(label: ratingLabel) {
            Button("Any rating") { library.filters.minRating = 0 }
            Divider()
            ForEach(Array((1...5).reversed()), id: \.self) { stars in
                Button(String(repeating: "★", count: stars) + " and up") {
                    library.filters.minRating = stars
                }
            }
        }
        BenchFilterChip(label: "Has parts", isSelected: library.filters.hasParts) {
            library.filters.hasParts.toggle()
        }
        // Offered everywhere, not only in the Edited scope: "which of my
        // imports did I top and tail?" is asked from the list you are in.
        BenchFilterChip(label: "Has edits", isSelected: library.filters.hasEdits) {
            library.filters.hasEdits.toggle()
        }
        BenchFilterChip(label: "♥ Favourites",
                        isSelected: library.filters.favoritesOnly) {
            library.filters.favoritesOnly.toggle()
        }
        if !library.allTags.isEmpty {
            BenchMenu(label: library.filters.tag ?? "Any tag") {
                Button("Any tag") { library.filters.tag = nil }
                Divider()
                ForEach(library.allTags, id: \.self) { tag in
                    Button(tag) { library.filters.tag = tag }
                }
            }
        }
        // Unfilled and unstroked (design line 763), unlike every chip before it:
        // the strip reads left to right as "narrow the list, then order it", and
        // the sort control loses its box so that break is visible without
        // reading a single label.
        BenchMenu(label: "Sort: \(sortLabel)", fill: .clear, stroke: .clear) {
            ForEach(LibraryRepository.Sort.allCases, id: \.self) { sort in
                Button(LibraryScreen.label(for: sort)) {
                    library.filters.sort = sort
                }
            }
        }
        if library.filters != scopeBaseline {
            Button("Clear") { library.filters = scopeBaseline }
                .buttonStyle(.bench(.quiet))
        }
        Spacer(minLength: 8)
        selectionControls
    }

    @ViewBuilder
    private var partFilters: some View {
        BenchMenu(label: kindLabel) {
            ForEach(LibraryScreen.kinds, id: \.tag) { kind in
                Button(kind.label) {
                    parts.filters.kindPrefix = kind.prefix
                }
            }
        }
        // Sectioned by origin: a flat list mixes the track you generated on
        // Tuesday with the album you imported and the mix you rendered from
        // both, and their titles give no clue which is which.
        BenchMenu(label: songLabel) {
            Button("Any song") { parts.filters.songId = nil }
            ForEach(SongOrigin.allCases, id: \.self) { origin in
                let entries = songTitles
                    .filter { songOrigins[$0.key] == origin }
                    .sorted { $0.value < $1.value }
                if !entries.isEmpty {
                    Section(origin.title) {
                        ForEach(entries, id: \.key) { id, title in
                            Button(title) { parts.filters.songId = id }
                        }
                    }
                }
            }
        }
        BenchMenu(label: bpmLabel) {
            ForEach(LibraryScreen.bpmPresets, id: \.tag) { preset in
                Button(preset.label) { parts.filters.bpmRange = preset.range }
            }
        }
        BenchMenu(label: parts.filters.camelot ?? "Any key") {
            Button("Any key") { parts.filters.camelot = nil }
            Divider()
            ForEach(availableCamelots, id: \.self) { code in
                Button(code) { parts.filters.camelot = code }
            }
        }
        if parts.filters != .init() {
            Button("Clear") { parts.filters = .init() }
                .buttonStyle(.bench(.quiet))
        }
        Spacer(minLength: 8)
        BenchToggleChip(isOn: $groupBySong, label: "Group by song")
    }

    /// `2 SELECTED · A / B compare`, and once a comparison is running, the
    /// switch itself — the design puts the A|B in the transport bar, but the
    /// bar belongs to the shell, so the keystroke has to live here.
    @ViewBuilder
    private var selectionControls: some View {
        if box.isActive {
            Button {
                box.toggle(playback: playback)
            } label: {
                HStack(spacing: 8) {
                    Text(box.isB ? "B" : "A")
                        .font(Bench.Typo.mono(11, .bold))
                    Text(LibraryCompare.switchKeyLabel)
                        .font(Bench.Typo.mono(10, .semibold))
                        .foregroundStyle(Bench.Palette.textQuaternary)
                }
            }
            .buttonStyle(.bench(.accent))
            // The design writes this as bare Tab, but `keyboardShortcut` is
            // window-scoped rather than view-scoped: a bare Tab claimed here
            // swallows the window's focus chain for as long as a comparison is
            // running, so the search field cannot be left and the lists cannot
            // be reached — and the lists need focus for `onMoveCommand`'s arrow
            // keys. ⌥ is not part of that chain, so the affordance survives
            // with the same finger already on Tab. Both labels have to move
            // with it, hence `LibraryCompare.switchKey`.
            .keyboardShortcut(.tab, modifiers: .option)
            .help("Switch to the other take at the same position")
        } else if checked.count >= 2 {
            HStack(spacing: 10) {
                Text("\(checked.count) SELECTED")
                    .font(Bench.Typo.mono(11, .semibold))
                    .foregroundStyle(Bench.Palette.accent)
                Button("A / B compare") { startCompare() }
                    .buttonStyle(BenchPrimaryButtonStyle(size: .compact,
                                                         glows: false))
            }
            .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.button,
                                         style: .continuous)
                .fill(Bench.Palette.accent.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.button,
                                      style: .continuous)
                .strokeBorder(Bench.Palette.accent.opacity(0.26), lineWidth: 1))
            .fixedSize()
        }
    }

    // MARK: - List

    /// The Imported scope takes files dropped anywhere on its list, not just on
    /// an empty-state well: once you have a hundred records in there the well
    /// is scrolled off, and dropping onto the list you are looking at is the
    /// obvious gesture. The accent border is the only feedback needed — the
    /// rows underneath already say what is in the collection.
    @ViewBuilder
    private var listPane: some View {
        if scope == .imported {
            scopeList
                // The empty state is mostly transparent, and the list has gaps
                // between its rows; without an explicit shape the drop would
                // only register where something happens to be drawn.
                .contentShape(Rectangle())
                .dropDestination(for: URL.self) { urls, _ in
                    let audio = AudioDrop.audioFiles(in: urls)
                    guard !audio.isEmpty else { return false }
                    Task { await receive(audio) }
                    return true
                } isTargeted: { isDropTargeted = $0 }
                .overlay(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.card,
                                          style: .continuous)
                    .strokeBorder(isDropTargeted ? Bench.Palette.accent
                                                 : .clear, lineWidth: 2)
                    .padding(6)
                    .allowsHitTesting(false))
        } else {
            scopeList
        }
    }

    @ViewBuilder
    private var scopeList: some View {
        if scope == .favourites {
            if songs.isEmpty && parts.results.isEmpty {
                LibraryEmptyState(
                    title: library.filters == scopeBaseline
                        ? "Nothing hearted yet" : "No matches",
                    message: library.filters == scopeBaseline
                        ? "Tap the heart on a track or a part and it lands here."
                        : "Try different search terms or filters.")
            } else {
                favouritesList
            }
        } else if scope == .parts {
            if partGroups.isEmpty {
                LibraryEmptyState(
                    title: parts.filters == .init() ? "No parts yet" : "No matches",
                    message: parts.filters == .init()
                        ? "Split a song and its parts will land here."
                        : "Try different filters.")
            } else {
                LibraryPartList(
                    groups: partGroups, analyses: parts.analyses,
                    playback: playback, selectedId: $selectedPartId,
                    onPlay: playPart, onSeek: seekPart,
                    onAddToWorkbench: onAddToWorkbench,
                    onRenderNotes: onRenderNotes)
            }
        } else if songs.isEmpty {
            LibraryEmptyState(title: emptyTitle, message: emptyMessage)
        } else {
            LibrarySongList(
                songs: songs, partCounts: partCounts, splitting: splittingSongs,
                playback: playback, showsCheckboxes: true,
                selectedId: $selectedSongId, checked: $checked,
                actions: actions, onPlay: playSong)
        }
    }

    /// Favourites is the one scope that spans both tables, so it composes the
    /// two row types itself instead of handing off to one of the lists — two
    /// scroll views stacked would each scroll on their own.
    private var favouritesList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if !songs.isEmpty {
                    Text("TRACKS").eyebrow()
                        .padding(.horizontal, 4).padding(.top, 4)
                            .padding(.bottom, 2)
                    ForEach(Array(songs.enumerated()), id: \.element.id) {
                        index, song in
                        LibrarySongRow(
                            song: song, isZebra: index.isMultiple(of: 2),
                            isSelected: song.id == selectedSongId,
                            isChecked: checked.contains(song.id),
                            showsCheckbox: true,
                            partCount: partCounts[song.id] ?? 0,
                            isSplitting: splittingSongs.contains(song.id),
                            playback: playback,
                            onToggleCheck: {
                                if checked.contains(song.id) {
                                    checked.remove(song.id)
                                } else {
                                    checked.insert(song.id)
                                }
                            },
                            onPlay: { playSong(song) },
                            onSelect: {
                                selectedSongId = song.id
                                selectedPartId = nil
                            })
                    }
                }
                if !parts.results.isEmpty {
                    Text("PARTS").eyebrow()
                        .padding(.horizontal, 4).padding(.top, 12)
                            .padding(.bottom, 2)
                    ForEach(Array(parts.results.enumerated()),
                            id: \.element.id) { index, part in
                        LibraryPartRow(
                            part: part, analysis: parts.analysis(for: part.id),
                            isZebra: index.isMultiple(of: 2),
                            isSelected: part.id == selectedPartId,
                            playback: playback,
                            onPlay: { playPart(part) },
                            onSelect: {
                                selectedPartId = part.id
                                selectedSongId = nil
                            },
                            onSeek: { seekPart(part, $0) },
                            onAddToWorkbench: { onAddToWorkbench(part) },
                            onRenderNotes: onRenderNotes.map { render in
                                { render(part) }
                            })
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }

    private var emptyTitle: String {
        if library.filters != scopeBaseline { return "No matches" }
        switch scope {
        case .renders: return "No renders yet"
        case .imported: return "Nothing imported yet"
        case .edited: return "Nothing edited yet"
        default: return "No songs yet"
        }
    }

    private var emptyMessage: String {
        if library.filters != scopeBaseline {
            return "Try different search terms or filters."
        }
        switch scope {
        case .renders:
            return "Combine parts in the Workbench and the mix lands here."
        case .imported:
            return "Import audio files, or drag them onto this list."
        case .edited:
            return "Trim, cut or level a track in the Editor and it "
                + "lands here once you apply."
        default:
            return "Generate something and it will land here."
        }
    }

    // MARK: - Inspector

    @ViewBuilder
    private var inspector: some View {
        // Favourites shows whichever kind you picked; the other scopes only
        // ever contain one.
        if scope == .parts || (scope == .favourites && selectedPartId != nil) {
            if let part = selectedPart {
                PartInspector(
                    part: part, analysis: parts.analysis(for: part.id),
                    sourceTitle: songTitles[part.songId] ?? "Unknown",
                    siblings: siblings, parts: parts, playback: playback,
                    onAddToWorkbench: onAddToWorkbench,
                    onUseMelody: onUseMelody,
                    onRenderNotes: onRenderNotes,
                    onFindMatches: onFindMatches,
                    onEdit: onEditPart,
                    onSelectSibling: { selectedPartId = $0 },
                    onDeleted: { selectedPartId = nil })
            } else {
                LibraryEmptyState(title: "Select a part",
                                  message: "Details appear here.")
            }
        } else if let song = selectedSong {
            SongDetailView(song: song, library: library, playback: playback,
                           actions: actions,
                           onDeleted: { selectedSongId = nil })
        } else {
            LibraryEmptyState(title: "Select a song",
                              message: "Details appear here.")
        }
    }

    // MARK: - Playback

    private func playSong(_ song: SongRecord) {
        // Playing something outside the pair ends the comparison, so the
        // transport bar's A|B never claims to be showing a track it isn't;
        // playing one *of* the pair moves the switch to that side instead.
        if box.isActive, song.id != box.a?.id, song.id != box.b?.id {
            box.end()
        } else {
            box.focus(songId: song.id)
        }
        // The inspector follows what you are hearing. Rows are played by
        // clicking their waveform as often as their play button, and an
        // inspector describing a different track than the speakers is worse
        // than no inspector at all.
        selectedSongId = song.id
        playback.play(url: song.fileURL, songId: song.id, title: song.title,
                      duration: song.durationS,
                      subtitle: box.isActive ? box.subtitle
                                             : SongDetailView.subtitle(for: song))
    }

    private func playPart(_ part: PartRecord) {
        guard let url = part.auditionURL else { return }
        selectedPartId = part.id
        playback.play(url: url, songId: part.id, title: part.name,
                      duration: part.durationS ?? 0,
                      subtitle: partSubtitle(part))
    }

    private func seekPart(_ part: PartRecord, _ fraction: Double) {
        guard let url = part.auditionURL else { return }
        if playback.currentSongId != part.id {
            playback.play(url: url, songId: part.id, title: part.name,
                          duration: part.durationS ?? 0,
                          subtitle: partSubtitle(part))
        }
        playback.seek(to: fraction * (part.durationS ?? 0))
    }

    private func partSubtitle(_ part: PartRecord) -> String {
        var fields = [songTitles[part.songId] ?? part.modelName]
        if let bpm = parts.analyses[part.id]?.bpm {
            fields.append("\(Int(bpm.rounded())) BPM")
        }
        if let camelot = parts.analyses[part.id]?.camelot {
            fields.append(camelot)
        }
        return fields.joined(separator: " · ").uppercased()
    }

    /// Take in dropped or chosen files and show the user where they went.
    ///
    /// The scope move is the point: an import made from Generated Songs lands
    /// in a list you are not looking at, so without this the files appear to
    /// have gone nowhere — and the selection below would be pointing at a row
    /// off screen.
    private func receive(_ urls: [URL]) async {
        let imported = await library.importSongs(urls: urls)
        guard let first = imported.first else { return }
        scope = .imported
        selectedSongId = first.id
    }

    private func startCompare() {
        let picked = songs.filter { checked.contains($0.id) }
        guard picked.count >= 2 else { return }
        box.start(a: picked[0], b: picked[1], playback: playback)
    }

    // MARK: - Scope + derived data

    /// Moves only what the scope owns, so a search term or a sort survives the
    /// switch. The exception is the artist filter: it is offered in the
    /// Imported scope alone, so carrying it out would filter a list by a
    /// control that is no longer on screen.
    private func applyScope() {
        library.filters.origin = scope.origin.map { .only($0.rawValue) } ?? .any
        library.filters.favoritesOnly = scope == .favourites
        library.filters.hasEdits = scope == .edited
        // The Edited scope is a list of edits, so it leads with the newest
        // one — but only as its own default; a sort you chose survives. It
        // is put back on the way out, or every other scope would sit on a
        // sort that only means anything here.
        if scope == .edited {
            if library.filters.sort == .newest {
                library.filters.sort = .recentlyEdited
                promotedSort = true
            }
        } else if promotedSort, library.filters.sort == .recentlyEdited {
            // Only the promotion is undone. Choosing "recently edited"
            // yourself, in any scope, is a choice — putting it back to
            // "newest" on the way out would be overriding it.
            library.filters.sort = .newest
            promotedSort = false
        }
        if scope != .imported { library.filters.artist = nil }
        parts.filters.favoritesOnly = scope == .favourites
        // A selection names a row that the new scope does not contain. Ticks go
        // too, in every direction: the three song scopes are disjoint sets, so a
        // tick carried across would leave "2 SELECTED" showing above a list
        // with nothing ticked in it.
        checked = []
        switch scope {
        case .parts: selectedSongId = nil
        // Favourites can hold either kind, so it starts with neither picked
        // rather than inheriting a row the new list may not contain.
        case .favourites: selectedSongId = nil; selectedPartId = nil
        case .songs, .imported, .renders, .edited: selectedPartId = nil
        }
    }

    /// The filter set this scope starts from, which is what "Clear" restores
    /// and what the empty state compares against — `.init()` alone would read a
    /// freshly opened Renders scope as "filtered".
    private var scopeBaseline: LibraryRepository.Filters {
        var baseline = LibraryRepository.Filters()
        baseline.origin = scope.origin.map { .only($0.rawValue) } ?? .any
        baseline.favoritesOnly = scope == .favourites
        baseline.hasEdits = scope == .edited
        if scope == .edited { baseline.sort = .recentlyEdited }
        return baseline
    }

    private func refreshDerived() {
        // Ticks only mean anything while you can see them. A filter that hides
        // one half of a pair has to end the comparison too, or the transport
        // bar keeps offering an A|B over a row the list no longer contains.
        if scope != .parts {
            let visible = Set(songs.map(\.id))
            if !checked.isSubset(of: visible) { checked.formIntersection(visible) }
        }
        partCounts = (try? parts.repository.partCounts()) ?? [:]
        // Each scope reads its own origin. Counting Generated as "everything
        // that isn't a render" would fold the imports back into it — the very
        // thing the Imported scope exists to undo.
        let byOrigin = (try? library.repository.countsByOrigin()) ?? [:]
        artists = (try? library.repository.distinctArtists()) ?? []
        let favouriteSongs = (try? library.repository.favoriteCount()) ?? 0
        let favouriteParts = (try? parts.repository.favorites().count) ?? 0
        counts = ScopeCounts(songs: byOrigin[SongOrigin.generated.rawValue] ?? 0,
                             imported: byOrigin[SongOrigin.imported.rawValue] ?? 0,
                             parts: partCounts.values.reduce(0, +),
                             renders: byOrigin[SongOrigin.recombined.rawValue] ?? 0,
                             edited: (try? library.repository.editedCount()) ?? 0,
                             favourites: favouriteSongs + favouriteParts)
        rebuildGroups()
        refreshSiblings()
    }

    private func rebuildGroups() {
        let results = parts.results
        var titles: [String: String] = [:]
        var origins: [String: SongOrigin] = [:]
        for id in Set(results.map(\.songId)) {
            let song = (try? library.repository.song(id: id)) ?? nil
            titles[id] = song?.title ?? "Unknown"
            origins[id] = song?.originKind ?? .generated
        }
        songTitles = titles
        songOrigins = origins
        guard !results.isEmpty else {
            partGroups = []
            return
        }
        guard groupBySong else {
            partGroups = [LibraryPartGroup(id: "all", header: nil, parts: results)]
            return
        }
        // Audio parts group under their song; notes and features collect at the
        // end, because they are read differently — a "Render…" and, until that
        // render exists, no strip at all, rather than a waveform and a
        // "＋ Bench".
        let audio = results.filter { $0.format == "wav" }
        let rest = results.filter { $0.format != "wav" }
        var groups: [LibraryPartGroup] = []
        var seen: Set<String> = []
        for part in audio where !seen.contains(part.songId) {
            seen.insert(part.songId)
            let members = audio.filter { $0.songId == part.songId }
            groups.append(LibraryPartGroup(
                id: part.songId,
                header: .song(title: titles[part.songId] ?? "Unknown",
                              meta: groupMeta(songId: part.songId,
                                              members: members)),
                parts: members))
        }
        if !rest.isEmpty {
            groups.append(LibraryPartGroup(
                id: "notes-and-features",
                header: .caption("NOTES & MIDI PARTS · \(rest.count)"),
                parts: rest))
        }
        partGroups = groups
    }

    /// `201 S · 107 BPM · 8B · DEMUCS 6-STEM` — the source's shape and the
    /// separator that produced these parts, so a group header says why the
    /// stems under it sound the way they do.
    private func groupMeta(songId: String, members: [PartRecord]) -> String {
        var fields: [String] = []
        if let song = ((try? library.repository.song(id: songId)) ?? nil) {
            fields.append("\(LibraryFormat.seconds(song.durationS)) S")
        }
        let analysis = ((try? parts.repository.analysis(ownerId: songId)) ?? nil)
        if let bpm = analysis?.bpm { fields.append("\(Int(bpm.rounded())) BPM") }
        if let camelot = analysis?.camelot { fields.append(camelot) }
        var separators: [String] = []
        for name in members.map(\.modelName) where !separators.contains(name) {
            separators.append(name)
        }
        if !separators.isEmpty {
            fields.append(separators.joined(separator: " + "))
        }
        return fields.joined(separator: " · ").uppercased()
    }

    private func refreshSiblings() {
        guard let part = selectedPart else {
            siblings = []
            return
        }
        siblings = ((try? parts.repository.allParts(forSong: part.songId)) ?? [])
            .filter { $0.id != part.id }
    }

    /// Songs a split job is running against, so a row can say it is busy
    /// instead of looking identical to one that has never been split.
    private var splittingSongs: Set<String> {
        var out: Set<String> = []
        for job in jobs.active.values where !job.status.isTerminal {
            if case .split(let songId, _)? = jobs.pendingContext[job.info.jobId] {
                out.insert(songId)
            }
        }
        return out
    }

    // MARK: - Filter labels

    private var models: [(id: String, name: String)] {
        var names: [String: String] = [:]
        for song in library.results + library.recent {
            names[song.modelId] = song.modelName
        }
        return names.map { (id: $0.key, name: $0.value) }
            .sorted { $0.name < $1.name }
    }

    private var modelLabel: String {
        guard let id = library.filters.modelId else { return "Any model" }
        return models.first { $0.id == id }?.name ?? id
    }

    private var ratingLabel: String {
        library.filters.minRating > 0
            ? String(repeating: "★", count: library.filters.minRating) + " and up"
            : "Any rating"
    }

    private var sortLabel: String { LibraryScreen.label(for: library.filters.sort) }

    static func label(for sort: LibraryRepository.Sort) -> String {
        switch sort {
        case .newest: "newest"
        case .oldest: "oldest"
        case .rating: "rating"
        case .title: "name"
        case .longest: "longest"
        case .recentlyEdited: "recently edited"
        }
    }

    static let kinds: [(tag: String, label: String, prefix: String?)] = [
        ("", "All kinds", nil),
        ("stem", "Stems", "stem."),
        ("notes", "Notes", "notes."),
        ("features", "Features", "features."),
    ]

    private var kindLabel: String {
        LibraryScreen.kinds.first { $0.prefix == parts.filters.kindPrefix }?.label
            ?? "All kinds"
    }

    private var songLabel: String {
        parts.filters.songId.flatMap { songTitles[$0] } ?? "Any song"
    }

    static let bpmPresets: [(tag: String, label: String,
                             range: ClosedRange<Double>?)] = [
        ("", "Any tempo", nil),
        ("lt90", "Under 90 BPM", 1...90),
        ("90-110", "90–110 BPM", 90...110),
        ("110-130", "110–130 BPM", 110...130),
        ("gt130", "Over 130 BPM", 130...999),
    ]

    private var bpmLabel: String {
        LibraryScreen.bpmPresets.first { $0.range == parts.filters.bpmRange }?
            .label ?? "Any tempo"
    }

    /// Camelot codes among the currently analyzed parts (plus the active
    /// selection, so a filtered-down list can't strand its own choice).
    private var availableCamelots: [String] {
        var codes = Set(parts.results.compactMap {
            parts.analyses[$0.id]?.camelot
        })
        if let active = parts.filters.camelot { codes.insert(active) }
        return codes.sorted()
    }
}

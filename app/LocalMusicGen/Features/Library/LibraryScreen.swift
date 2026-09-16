import SwiftUI

/// Library — one screen for All, Generated, Imported, Parts, Edited and
/// Favourites.
///
/// The scopes share a shell, a row grammar and an inspector slot, and that is
/// the point: browsing stems used to be a different screen inside Split &
/// Recombine with its own list, its own filters and its own detail pane, so the
/// same material read as two unrelated things depending on how you arrived.
/// Here a scope is a filter over the same furniture.
///
/// The two whole-track scopes are one table read two ways — they differ only in
/// which `SongShelf` they name — so switching between them only moves
/// `LibraryRepository.Filters.origin`. Parts come from a different table, which
/// is why the Parts scope swaps the whole list and inspector rather than just
/// the query.
///
/// Two scopes span both tables (`spansBothTables`): Favourites, and All — the
/// view the sidebar's Library row itself opens. They compose the two row types
/// into one scroll rather than handing off to either dedicated list, and they
/// are the reason the search box writes to both stores.
struct LibraryScreen: View {
    let library: LibraryStore
    let parts: PartsStore
    let jobs: JobsStore
    let playback: PlaybackController
    let settings: AppSettings
    @Binding var scope: LibraryScope
    /// A track the shell wants shown, set from outside and cleared here once
    /// acted on. `nil` the rest of the time, which is most of the time.
    @Binding var reveal: LibraryReveal?
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
    /// How far each scope was scrolled last time. Owned by the window, because
    /// this screen is torn down and rebuilt every time you navigate away from
    /// it — which is precisely the trip the position has to survive.
    var scrollMemory: LibraryScrollMemory?

    /// The row the inspector is showing — one id per kind, because the two
    /// lists come from different tables. Owned by the window for the same
    /// reason as the scroll position above: this screen is torn down and
    /// rebuilt every time you navigate away, so a selection kept here alone is
    /// lost the moment you step out to look something up on another screen.
    @Binding var selectedSongId: String?
    @Binding var selectedPartId: String?
    /// Ticked rows. Two of them is what reveals the A/B affordance. Held
    /// outside as well, so a bulk selection survives the same trip.
    @Binding var checked: Set<String>
    @State private var showImporter = false
    @State private var isDropTargeted = false
    /// Whether parts are gathered under the song they came from. Owned by the
    /// shell rather than by this screen, for the same reason the selection is:
    /// the View menu carries the toggle, and a `Commands` body cannot reach a
    /// view's `@State`.
    @Binding var groupBySong: Bool
    /// Which song groups are open in the Parts scope. Held by the shell for
    /// the same reason as the selection above — a set owned by this screen
    /// would close every group on the way to the Editor and back.
    @Binding var expandedGroups: Set<String>
    @State private var ownCompare = LibraryCompare()

    // Derived database reads, refreshed when the stores change rather than on
    // every redraw: the transport clock ticks four times a second and would
    // otherwise drag a fistful of queries along with it.
    @State private var partCounts: [String: Int] = [:]
    @State private var songTitles: [String: String] = [:]
    /// Which origin each of those songs has, so the parts filter can group them.
    @State private var songOrigins: [String: SongOrigin] = [:]
    /// Read from the whole table rather than from `results`, so picking an
    /// artist doesn't narrow the menu you picked it from down to that one name.
    @State private var artists: [String] = []
    /// The in-flight badge read — see `refreshBadgeCounts`.
    @State private var badgeTask: Task<Void, Never>?
    @State private var models: [ModelChoice] = []
    @State private var camelotCodes: Set<String> = []
    @State private var partGroups: [LibraryPartGroup] = []
    /// Whether the last rebuild found the parts list narrowed by a filter —
    /// see `syncExpansion`.
    @State private var wasNarrowed = false
    /// The part whose group has already been opened for it, so that opening
    /// happens once per selection rather than on every publish — see
    /// `revealSelectedPart`.
    @State private var revealedPartId: String?
    /// Whether the Edited scope is what set the "recently edited" sort — as
    /// opposed to the user picking it.
    @State private var promotedSort = false
    @State private var siblings: [PartRecord] = []
    /// The Parts scope's own four narrowings — kind, source song, tempo and
    /// key — remembered while another scope is showing.
    ///
    /// The controls that set them are drawn only in the Parts scope, but the
    /// values live on the shared `PartsStore`. Left there they went on
    /// narrowing the PARTS half of All and Favourites with no chip on screen,
    /// no Clear to press and an empty state that read "Nothing here yet" over
    /// a full library — and `MixActionView`'s autofill, which reads the same
    /// `parts.results`, silently found nothing. So they are lifted off the
    /// store on the way out of Parts and put back on the way in.
    @State private var partScopeFilters = PartsRepository.Filters()
    @FocusState private var searchFocused: Bool

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
        // ⌘F is the Edit menu's item now, not a hidden button: one item that
        // names where it will land ("Find in Library") instead of four
        // invisible ones that claimed the key with nothing to show for it.
        .focusedSceneValue(\.searchCommand,
                           SearchCommand(scope: "Library") { searchFocused = true })
        .onAppear {
            // `applyScope` already runs the search inline when it actually
            // changes a filter — that is `filtersChanged`'s click path. What
            // is left for arriving on the screen is a confirmation read, and
            // it goes through the coalesced off-actor pair rather than the
            // synchronous siblings: nothing here is a click waiting on a row,
            // and this used to run five unbounded queries plus a full parts
            // read on the main actor for every visit to the tab.
            applyScope()
            library.refreshRecentSoon()
            parts.refreshSoon()
            refreshDerived()
        }
        // The scope's filters belong to this screen, not to the stores — left
        // set, the sidebar's library count and every picker elsewhere in the
        // app would silently be showing "renders only", or "hearted only".
        .onDisappear {
            // One assignment, as in `applyScope`, and for the same reason:
            // five separate writes ran five searches on the way out of a
            // screen nobody is looking at any more.
            var next = library.filters
            next.origin = .any
            next.favoritesOnly = false
            next.hasEdits = false
            if promotedSort, next.sort == .recentlyEdited {
                next.sort = settings.libraryDefaultSort
                promotedSort = false
            }
            next.artist = nil
            library.filters = next
            var nextParts = parts.filters
            nextParts.favoritesOnly = false
            // A spanning scope's search text belongs to the shared box, not to
            // the parts list — left set, every parts picker in the app would
            // open pre-filtered by something typed on a screen you have left.
            if scope.spansBothTables { nextParts.query = "" }
            // And so do kind, song, tempo and key: they are this screen's
            // controls, and Mix autofill reads the same store. Remembered on
            // the way out so coming back to Parts finds the list as you left it.
            if scope == .parts { partScopeFilters = nextParts }
            nextParts = liftingPartScopeFilters(nextParts)
            parts.filters = nextParts
        }
        // `initial` because the reveal is usually set in the same turn that
        // switches to this screen, so the first body evaluation is already
        // carrying it and there is no change left to observe.
        .onChange(of: reveal, initial: true) { consumeReveal() }
        .onChange(of: scope) { previous, _ in
            applyScope(leaving: previous)
            resetSelection()
        }
        .onChange(of: library.results) { refreshDerived() }
        .onChange(of: parts.results) { refreshDerived() }
        .onChange(of: groupBySong) { rebuildGroups() }
        // Filters the results do not move — narrowing to a kind that was
        // already the whole list — still change what the list *is*, and the
        // groups follow that rather than the rows.
        .onChange(of: parts.filters) { syncExpansion(partGroups) }
        .onChange(of: selectedPartId) {
            refreshSiblings()
            revealSelectedPart()
        }
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
            // the switch here. All says nothing, because "Library" already
            // did — an eyebrow reading "LIBRARY ALL" is the word twice.
            if scope != .all {
                Text(scope.title.uppercased())
                    .font(Bench.Typo.counter)
                    .foregroundStyle(Bench.Palette.textFaintest)
                    .padding(.leading, 2)
            }
        } trailing: {
            HStack(spacing: 9) {
                BenchSearchField(text: searchText,
                                 placeholder: searchPlaceholder,
                                 width: scope == .parts ? 230 : 250,
                                 focused: $searchFocused)
                // Offered from All and Generated too: that is where you are
                // when it occurs to you to bring something in, and hiding the
                // button until you have already found the Imported scope makes
                // the feature discoverable only to someone who knows it exists.
                if scope == .all || scope == .songs || scope == .imported {
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
        case .all, .favourites: "Search tracks and parts…"
        default: "Search prompts, lyrics, notes…"
        }
    }

    /// One field, two stores: the search box means "search what is on screen".
    ///
    /// A scope that spans both tables writes to both, which Favourites did not
    /// and should have: typing there narrowed the tracks and left every part
    /// standing, so the list appeared to ignore half of what you typed. It
    /// matters more now that All is the library's front door.
    private var searchText: Binding<String> {
        if scope == .parts {
            return Binding(get: { parts.filters.query },
                           set: { parts.filters.query = $0 })
        }
        return Binding(get: { library.filters.query },
                       set: { text in
                           library.filters.query = text
                           if scope.spansBothTables { parts.filters.query = text }
                       })
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
                    // Picking from the menu is a choice even when it lands on
                    // the value the Edited scope promoted to — the revert on
                    // the way out must not undo it.
                    promotedSort = false
                    if settings.libraryRemembersSort {
                        settings.libraryDefaultSort = sort
                    }
                }
            }
        }
        if library.filters != scopeBaseline {
            Button("Clear") { clearFilters() }
                .buttonStyle(.bench(.quiet))
        }
        Spacer(minLength: 8)
        selectionControls
    }

    /// Back to the scope's own starting filters.
    ///
    /// The parts half has to be cleared with it wherever the two share a search
    /// box, or "Clear" empties the field and leaves the parts list narrowed by
    /// a word that is no longer written anywhere on screen.
    private func clearFilters() {
        library.filters = scopeBaseline
        guard scope.spansBothTables, !parts.filters.query.isEmpty else { return }
        parts.filters.query = ""
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
            // ⌥Tab, not the bare Tab the design writes: a bare Tab shortcut
            // is window-scoped rather than view-scoped and would swallow the
            // window's focus chain for as long as a comparison ran, so the
            // search field could not be left and the lists — which need focus
            // for `onMoveCommand`'s arrow keys — could not be reached. ⌥ is
            // not part of that chain, so the affordance survives with the same
            // finger already on Tab. Both labels move with it, hence
            // `LibraryCompare.switchKey`.
            //
            // The key itself now belongs to Playback ▸ Switch A/B Side. It is
            // not repeated here: two claimants on one shortcut is ambiguous,
            // and the button's own label already names the key.
            .help("Switch to the other take at the same position")
        } else if checked.count >= 2 {
            HStack(spacing: 10) {
                Text("\(checked.count) SELECTED")
                    .font(Bench.Typo.mono(11, .semibold))
                    .foregroundStyle(Bench.Palette.accent)
                // Parts can be ticked now, and two of those are not a
                // comparison — the A/B switch plays whole takes against each
                // other. Dimmed rather than hidden, so the chip keeps its
                // shape while the count is the thing that changed.
                Button("A / B compare") { startCompare() }
                    .buttonStyle(BenchPrimaryButtonStyle(size: .compact,
                                                         glows: false))
                    .disabled(!selection.canCompare)
                    .opacity(selection.canCompare ? 1 : 0.45)
                    .help(selection.canCompare
                          ? "Compare the first two songs against each other"
                          : "Needs two songs — a part has no take to compare")
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
        if scope.spansBothTables {
            if songs.isEmpty && parts.results.isEmpty {
                LibraryEmptyState(title: emptyTitle, message: emptyMessage)
            } else {
                combinedList
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
                    playback: playback, expanded: $expandedGroups,
                    selectedId: $selectedPartId,
                    checked: $checked,
                    onPlay: playPart, onSeek: seekPart,
                    onAddToWorkbench: onAddToWorkbench,
                    onRenderNotes: onRenderNotes,
                    scroll: scrollSlot)
            }
        } else if songs.isEmpty {
            LibraryEmptyState(title: emptyTitle, message: emptyMessage)
        } else {
            LibrarySongList(
                songs: songs, partCounts: partCounts, splitting: splittingSongs,
                playback: playback, showsCheckboxes: true,
                selectedId: $selectedSongId, checked: $checked,
                actions: actions, onPlay: playSong, onSeek: seekSong,
                scroll: scrollSlot)
        }
    }

    /// This scope's place in the window's scroll memory. Per scope rather than
    /// per screen: the scope you were in survives the trip too, so landing at
    /// the top of Parts because you last scrolled Generated would be the same
    /// bug in a smaller room.
    private var scrollSlot: LibraryScrollSlot? {
        scrollMemory.map { LibraryScrollSlot(memory: $0, scope: scope) }
    }

    /// The two scopes that span both tables compose the row types themselves
    /// instead of handing off to one of the dedicated lists — two scroll views
    /// stacked would each scroll on their own.
    private var combinedList: some View {
        // Measured once for the whole list, as the two dedicated lists do —
        // see `LibraryRowMetrics`.
        GeometryReader { pane in
            ScrollViewReader { proxy in
                combinedScroll(
                    contentWidth: LibraryRowMetrics
                        .contentWidth(pane: pane.size.width))
                    .remembersLibraryScroll(scrollSlot, proxy: proxy)
            }
        }
    }

    private func combinedScroll(contentWidth: CGFloat) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if !songs.isEmpty {
                    Text("TRACKS").eyebrow()
                        .padding(.horizontal, 4).padding(.top, 4)
                            .padding(.bottom, 2)
                    ForEach(Array(songs.enumerated()), id: \.element.id) {
                        index, song in
                        LibrarySongRow(
                            song: song, contentWidth: contentWidth,
                            isZebra: index.isMultiple(of: 2),
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
                            },
                            onSeek: { seekSong(song, $0) })
                            .id(song.id)
                            .libraryScrollAnchor(song.id)
                    }
                }
                if !parts.results.isEmpty {
                    Text("PARTS").eyebrow()
                        .padding(.horizontal, 4).padding(.top, 12)
                            .padding(.bottom, 2)
                    ForEach(Array(parts.results.enumerated()),
                            id: \.element.id) { index, part in
                        LibraryPartRow(
                            part: part, contentWidth: contentWidth,
                            analysis: parts.analysis(for: part.id),
                            isZebra: index.isMultiple(of: 2),
                            isSelected: part.id == selectedPartId,
                            isChecked: checked.contains(part.id),
                            showsCheckbox: true,
                            playback: playback,
                            onToggleCheck: {
                                if checked.contains(part.id) {
                                    checked.remove(part.id)
                                } else {
                                    checked.insert(part.id)
                                }
                            },
                            onPlay: { playPart(part) },
                            onSelect: {
                                selectedPartId = part.id
                                selectedSongId = nil
                            },
                            onSeek: { seekPart(part, $0) })
                            // A spanning scope composes the two row types
                            // itself, so it carries the parts menu too — the
                            // same one `LibraryPartList` puts on its rows.
                            .contextMenu {
                                Button("Add to Workbench") {
                                    onAddToWorkbench(part)
                                }
                                .disabled(part.format != "wav")
                                if part.format == "midi" {
                                    Button("Render notes…") {
                                        onRenderNotes?(part)
                                    }
                                    .disabled(onRenderNotes == nil)
                                }
                            }
                            .id(part.id)
                            .libraryScrollAnchor(part.id)
                    }
                }
            }
            .padding(.horizontal, LibraryRowMetrics.listPadding)
            .padding(.vertical, 8)
        }
    }

    private var emptyTitle: String {
        if library.filters != scopeBaseline { return "No matches" }
        switch scope {
        case .all: return "Nothing here yet"
        case .imported: return "Nothing imported yet"
        case .edited: return "Nothing edited yet"
        case .favourites: return "Nothing hearted yet"
        default: return "No songs yet"
        }
    }

    private var emptyMessage: String {
        if library.filters != scopeBaseline {
            return "Try different search terms or filters."
        }
        switch scope {
        case .all:
            return "Everything you generate, import, render or split lands "
                + "here — this is the whole library."
        case .imported:
            return "Import audio files, or drag them onto this list."
        case .edited:
            return "Trim, cut or level a track in the Editor and it "
                + "lands here once you apply."
        case .favourites:
            return "Tap the heart on a track or a part and it lands here."
        default:
            // The Generated shelf: takes from Studio, mixes from the Workbench
            // and selections from the Editor all arrive on it.
            return "Generate something and it will land here."
        }
    }

    // MARK: - Inspector

    /// Everything ticked, resolved against both tables.
    private var selection: LibrarySelection {
        LibrarySelection.of(ids: checked, songs: songs, parts: parts.results)
    }

    @ViewBuilder
    private var inspector: some View {
        // A selection outranks a single row: ticking a second box is a
        // deliberate act, and the pane it wants is the one about all of them.
        // Untick back down to one and the row's own pane returns.
        if selection.isMultiple {
            LibrarySelectionInspector(
                selection: selection, library: library, parts: parts,
                playback: playback,
                onCompare: startCompare,
                onAddToWorkbench: onAddToWorkbench,
                onClear: { checked = [] },
                onDeleted: {
                    // The rows are gone, so the ids must go with them —
                    // otherwise the pane keeps describing files that no longer
                    // exist, and the count never comes down.
                    checked = []
                    selectedSongId = nil
                    selectedPartId = nil
                })
        } else if scope == .parts
                    || (scope.spansBothTables && selectedPartId != nil) {
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
                           onDeleted: { selectedSongId = nil },
                           onRenderNotes: onRenderNotes)
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

    /// Scrub a row's waveform.
    ///
    /// Load first, seek second: seeking before the item is replaced moves
    /// whatever was playing before. It goes through `playSong` rather than
    /// straight to the transport so a scrub keeps the A/B pair and the
    /// inspector honest in exactly the way a click on the play button does.
    private func seekSong(_ song: SongRecord, _ fraction: Double) {
        if playback.currentSongId != song.id { playSong(song) }
        playback.seek(to: fraction * song.durationS)
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

    /// Move to the scope the track lives in and select it.
    ///
    /// Written the same way `receive(_:)` handles a fresh import, and it works
    /// for the same reason: `resetSelection` clears a *part* selection on the
    /// way into a song scope but never a song one, so the id set here survives
    /// the scope change that follows it. Cleared first, so a reveal that names a
    /// deleted track cannot be retried on every redraw.
    private func consumeReveal() {
        guard let reveal else { return }
        self.reveal = nil
        scope = reveal.scope
        selectedPartId = nil
        selectedSongId = reveal.songId
        // The row you were sent here to see is where this scope is now, as far
        // as the scroll memory is concerned — see `LibraryScrollMemory.pin`.
        scrollMemory?.pin(reveal.songId, for: reveal.scope)
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
    /// Built as one value and assigned once.
    ///
    /// `filters` refreshes in its own `didSet`, so writing five properties in
    /// a row ran the search — an FTS match, a tag read and a count, inline on
    /// this actor — five times for one scope change, and four of those against
    /// a half-applied filter set whose results were thrown away.
    private func applyScope(leaving previous: LibraryScope? = nil) {
        var next = library.filters
        next.origin = scope.originFilter
        next.favoritesOnly = scope == .favourites
        next.hasEdits = scope == .edited
        // The Edited scope is a list of edits, so it leads with the newest
        // one — but only as its own default; a sort you chose survives. It
        // is put back on the way out, or every other scope would sit on a
        // sort that only means anything here. "Default" is the Settings
        // default, not `.newest` — a user who defaults to rating has not
        // chosen anything either.
        if scope == .edited {
            if next.sort == settings.libraryDefaultSort {
                next.sort = .recentlyEdited
                promotedSort = true
            }
        } else if promotedSort, next.sort == .recentlyEdited {
            // Only the promotion is undone. Choosing "recently edited"
            // yourself, in any scope, is a choice — putting it back on the
            // way out would be overriding it.
            next.sort = settings.libraryDefaultSort
            promotedSort = false
        }
        if scope != .imported { next.artist = nil }
        library.filters = next
        // One assignment for the parts store too, and for the same reason.
        var nextParts = parts.filters
        nextParts.favoritesOnly = scope == .favourites
        if scope == .parts {
            // Back in the scope that draws the controls: put them back.
            nextParts = restoringPartScopeFilters(nextParts)
        } else {
            // Snapshot taken only on the way *out* of Parts, so it is always
            // the real state of those controls and never an already-cleared
            // one — arriving on the screen must not overwrite the memory.
            if previous == .parts { partScopeFilters = parts.filters }
            nextParts = liftingPartScopeFilters(nextParts)
        }
        if scope.spansBothTables {
            // One box over two lists — see `searchText`.
            nextParts.query = next.query
        } else if previous?.spansBothTables == true {
            // Leaving the shared box: what is in it was never this list's.
            // Only on the way *out* of a spanning scope, so a Parts search
            // still survives a trip to Generated and back.
            nextParts.query = ""
        }
        if nextParts != parts.filters { parts.filters = nextParts }
    }

    /// The four Parts-scope narrowings taken off a filter set — see
    /// `partScopeFilters`.
    private func liftingPartScopeFilters(_ filters: PartsRepository.Filters)
        -> PartsRepository.Filters {
        var next = filters
        next.kindPrefix = nil
        next.songId = nil
        next.bpmRange = nil
        next.camelot = nil
        return next
    }

    /// The same four put back from the screen's memory.
    private func restoringPartScopeFilters(_ filters: PartsRepository.Filters)
        -> PartsRepository.Filters {
        var next = filters
        next.kindPrefix = partScopeFilters.kindPrefix
        next.songId = partScopeFilters.songId
        next.bpmRange = partScopeFilters.bpmRange
        next.camelot = partScopeFilters.camelot
        return next
    }

    /// Drop what was picked under the scope being left.
    ///
    /// Called on a scope change and nowhere else — in particular not when the
    /// screen reappears, which is the whole of the fix: the scope you come
    /// back to is the scope you left, so the row you left selected is still in
    /// its list and re-clearing it here would undo the memory the window is
    /// holding on this screen's behalf.
    private func resetSelection() {
        // A selection names a row that the new scope does not contain. Ticks go
        // too, in every direction: the three song scopes are disjoint sets, so a
        // tick carried across would leave "2 SELECTED" showing above a list
        // with nothing ticked in it.
        checked = []
        switch scope {
        case .parts: selectedSongId = nil
        // All and Favourites hold either kind, so they start with neither
        // picked rather than inheriting a row the new list may not contain.
        case .all, .favourites: selectedSongId = nil; selectedPartId = nil
        case .songs, .imported, .edited: selectedPartId = nil
        }
    }

    /// The filter set this scope starts from, which is what "Clear" restores
    /// and what the empty state compares against — `.init()` alone would read a
    /// freshly opened Imported scope as "filtered".
    private var scopeBaseline: LibraryRepository.Filters {
        var baseline = LibraryRepository.Filters()
        baseline.sort = settings.libraryDefaultSort
        baseline.origin = scope.originFilter
        baseline.favoritesOnly = scope == .favourites
        baseline.hasEdits = scope == .edited
        if scope == .edited { baseline.sort = .recentlyEdited }
        return baseline
    }

    private func refreshDerived() {
        // Ticks only mean anything while you can see them. A filter that hides
        // one half of a pair has to end the comparison too, or the transport
        // bar keeps offering an A|B over a row the list no longer contains.
        // A scope that lists both kinds has to count both as visible, or every
        // ticked part is unticked again the moment either store publishes —
        // which in Favourites it was, so a bulk action over hearted stems could
        // never be assembled.
        if scope != .parts {
            var visible = Set(songs.map(\.id))
            if scope.spansBothTables { visible.formUnion(parts.results.map(\.id)) }
            if !checked.isSubset(of: visible) { checked.formIntersection(visible) }
        }
        refreshBadgeCounts()
        rebuildModelChoices()
        // `countsByOrigin`, `favoriteCount`, the parts' `favorites()` and
        // `editedCount` used to run here too, to fill a `ScopeCounts` that
        // nothing ever read — the sidebar draws its badges from the stores'
        // own cached counts. Four queries per refresh, and a `@State` write
        // that invalidated the screen again, for a value with no readers.
        rebuildGroups()
        refreshSiblings()
    }

    /// The two whole-table reads behind the row badges and the artist menu.
    ///
    /// Off the actor and coalesced, because `refreshDerived` runs on every
    /// publish of either store — which includes every settled keystroke while
    /// searching — and these two are a `GROUP BY` over the part table and a
    /// `DISTINCT` over the song table. Neither is on the path of a click:
    /// they fill a count badge and a filter menu, so arriving a frame later
    /// than the rows is invisible, and a stale answer is never wrong for
    /// longer than the query takes.
    private func refreshBadgeCounts() {
        badgeTask?.cancel()
        let partsRepo = parts.repository
        let libraryRepo = library.repository
        badgeTask = Task {
            let answer = await Task.detached(priority: .userInitiated) {
                (counts: (try? partsRepo.partCounts()) ?? [:],
                 artists: (try? libraryRepo.distinctArtists()) ?? [])
            }.value
            guard !Task.isCancelled else { return }
            if partCounts != answer.counts { partCounts = answer.counts }
            if artists != answer.artists { artists = answer.artists }
        }
    }

    private func rebuildGroups() {
        let results = parts.results
        // Two queries for the whole list, not three per distinct song. The
        // titles pass used to fetch each song and `groupMeta` then fetched the
        // very same row again with an analysis beside it, so a parts list
        // drawn from fifty songs issued about a hundred and fifty synchronous
        // queries — on the main actor, every time either store published.
        let songIds = Array(Set(results.map(\.songId)))
        let songs = (try? library.repository.songs(ids: songIds)) ?? [:]
        let analyses = (try? parts.repository.analyses(ownerIds: songIds)) ?? [:]
        var titles: [String: String] = [:]
        var origins: [String: SongOrigin] = [:]
        for id in songIds {
            titles[id] = songs[id]?.title ?? "Unknown"
            origins[id] = songs[id]?.originKind ?? .generated
        }
        if titles != songTitles { songTitles = titles }
        if origins != songOrigins { songOrigins = origins }
        guard !results.isEmpty else {
            if !partGroups.isEmpty { partGroups = [] }
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
        // Grouped in one pass. The inner `audio.filter` this replaces made the
        // loop quadratic in the number of parts on screen.
        let bySong = Dictionary(grouping: audio, by: \.songId)
        var groups: [LibraryPartGroup] = []
        var seen: Set<String> = []
        for part in audio where !seen.contains(part.songId) {
            seen.insert(part.songId)
            let members = bySong[part.songId] ?? []
            groups.append(LibraryPartGroup(
                id: part.songId,
                header: .song(title: titles[part.songId] ?? "Unknown",
                              meta: groupMeta(song: songs[part.songId],
                                              analysis: analyses[part.songId],
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
        syncExpansion(groups)
        revealSelectedPart()
    }

    /// A narrowed list opens itself.
    ///
    /// The groups are closed by default, which is the point of them — but a
    /// filter is a search *for parts*, and answering "vocal" with fifty closed
    /// song headings reads as no matches at all. So while anything is filtering
    /// the list, every group in it is open; clear the filters and it goes back
    /// to the list of songs it started as.
    private func syncExpansion(_ groups: [LibraryPartGroup]) {
        guard parts.filters != .init() else {
            // Only on the way out of a filtered list, so this never closes
            // groups the user opened by hand on an unfiltered one.
            if wasNarrowed {
                expandedGroups = []
                wasNarrowed = false
            }
            return
        }
        wasNarrowed = true
        let ids = Set(groups.filter { $0.header != nil }.map(\.id))
        // Checked rather than written every time: this runs on every publish
        // of either store, and an unconditional write to the shell would
        // invalidate the screen on each one.
        guard !expandedGroups.isSuperset(of: ids) else { return }
        expandedGroups.formUnion(ids)
    }

    /// Open the group holding the inspected part.
    ///
    /// "Show now playing" can land on this screen with a stem selected and the
    /// song it came from closed, which would otherwise be a list with nothing
    /// visibly picked and an inspector describing a row you cannot see.
    ///
    /// Once per part: closing a group whose stem you are listening to has to
    /// stay closed, or the group springs open again on the next publish.
    private func revealSelectedPart() {
        guard let id = selectedPartId else {
            revealedPartId = nil
            return
        }
        guard id != revealedPartId else { return }
        guard let group = partGroups.first(where: { group in
            group.header != nil && group.parts.contains { $0.id == id }
        }) else { return }
        revealedPartId = id
        if !expandedGroups.contains(group.id) {
            expandedGroups.insert(group.id)
        }
    }

    /// `201 S · 107 BPM · 8B · DEMUCS 6-STEM` — the source's shape and the
    /// separator that produced these parts, so a group header says why the
    /// stems under it sound the way they do.
    /// Takes the song and its analysis rather than fetching them: both were
    /// already read once, in one batch, by `rebuildGroups`.
    private func groupMeta(song: SongRecord?, analysis: AnalysisRecord?,
                           members: [PartRecord]) -> String {
        var fields: [String] = []
        if let song {
            fields.append("\(LibraryFormat.seconds(song.durationS)) S")
        }
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
    ///
    /// The store keeps this set. Walking `active` here instead subscribed the
    /// whole song grid to every progress frame in the app, which is the one
    /// thing a list of a few hundred rows must not be subscribed to.
    private var splittingSongs: Set<String> { jobs.splittingSongIds }

    // MARK: - Filter labels

    /// The model filter's menu, built in `refreshDerived` rather than here.
    ///
    /// It concatenated the whole search result with the whole recents list,
    /// built a dictionary and sorted it — and `modelLabel`, which the filter
    /// bar draws on every pass, read it to resolve one id.
    struct ModelChoice: Identifiable, Equatable {
        var id: String
        var name: String
    }

    private func rebuildModelChoices() {
        var names: [String: String] = [:]
        for song in library.results + library.recent {
            names[song.modelId] = song.modelName
        }
        let next = names.map { ModelChoice(id: $0.key, name: $0.value) }
            .sorted { $0.name < $1.name }
        if next != models { models = next }
        let camelots = Set(parts.results.compactMap {
            parts.analyses[$0.id]?.camelot
        })
        if camelots != camelotCodes { camelotCodes = camelots }
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
    /// The key menu's options. The scan over every part's analysis lives in
    /// `rebuildModelChoices`; the active filter is folded in here because it
    /// can be set to a code no visible part carries.
    private var availableCamelots: [String] {
        var codes = camelotCodes
        if let active = parts.filters.camelot { codes.insert(active) }
        return codes.sorted()
    }
}

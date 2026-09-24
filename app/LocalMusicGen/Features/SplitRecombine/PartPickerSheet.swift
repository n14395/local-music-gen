// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// Slot-fillable material: a part, or a whole library song ("song.mix").
struct PickedMaterial: Identifiable, Equatable {
    var id: String            // part id or song id
    var songId: String        // the owning song (== id for song.mix rows)
    var name: String
    var kind: String          // part kind, or "song.mix"
    var sourceTitle: String
    var fileURL: URL
    var durationS: Double?
    var auditionURL: URL?

    init(part: PartRecord, sourceTitle: String) {
        id = part.id
        songId = part.songId
        name = part.name
        kind = part.kind
        self.sourceTitle = sourceTitle
        fileURL = part.fileURL
        durationS = part.durationS
        auditionURL = part.auditionURL
    }

    init(song: SongRecord) {
        id = song.id
        songId = song.id
        name = song.title
        kind = "song.mix"
        sourceTitle = song.title
        fileURL = song.fileURL
        durationS = song.durationS
        auditionURL = song.fileURL
    }

    /// Placeholder for material a recombined song references that no longer
    /// exists. It carries the recorded title so the clip can say what is
    /// missing, and a file URL that deliberately points nowhere.
    init(missingId: String, title: String, role: String) {
        id = missingId
        songId = missingId
        name = role.capitalized
        kind = "stem.\(role)"
        sourceTitle = title
        fileURL = URL(fileURLWithPath: "/dev/null")
        durationS = nil
        auditionURL = nil
    }

    /// A part rather than a whole song. `song.mix` is the one kind that is not
    /// a part, which is what makes it the test.
    var isPart: Bool { kind != "song.mix" }

    /// Who a measurement of this material belongs to, in the two columns the
    /// `analysis` table keys on.
    ///
    /// It has to be the *material's* own id, not `songId`. A part's `songId`
    /// is the song it came out of, so attributing a stem's analysis that way
    /// writes its tempo and key onto the whole song — and `JobsStore` then
    /// propagates a song's analysis down to every part of it, so one stem's
    /// measurements would overwrite all its siblings'. Nothing would report an
    /// error; the library would simply start lying.
    var analysisOwner: (id: String, type: String) {
        (id, isPart ? "part" : "song")
    }

    /// Cached peaks live under one id-keyed name for songs and parts alike, so
    /// a picked material can find its own waveform without knowing which it is.
    var waveformURL: URL {
        StoragePaths.libraryWaveforms.appendingPathComponent(id + ".peaks")
    }

    /// A part or a song by id — the same lookup the workbench and the studio
    /// intents both need.
    @MainActor
    static func resolve(id: String, parts: PartsStore,
                        library: LibraryStore) -> PickedMaterial? {
        if let part = ((try? parts.repository.part(id: id)) ?? nil) {
            let title = ((try? library.repository.song(id: part.songId)) ?? nil)?
                .title ?? part.modelName
            return PickedMaterial(part: part, sourceTitle: title)
        }
        if let song = ((try? library.repository.song(id: id)) ?? nil) {
            return PickedMaterial(song: song)
        }
        return nil
    }
}

/// The waveform strip beside a picked material, wherever one is listed.
///
/// The rule is one line long and worth stating, because getting it wrong is
/// how a redesign starts lying: draw the audio that exists, and when there is
/// none, say so. A `notes.*` part has no waveform of its own — its `fileURL`
/// is a MIDI file — but the split that produced it usually also produced a
/// rendered `preview.wav`, which is what `auditionURL` points at and what this
/// row's own play button plays. When that render is absent there is nothing
/// true to draw, so nothing is drawn.
struct MaterialStrip: View {
    let material: PickedMaterial
    var playedFraction: Double = 0
    var height: CGFloat = 24
    var barPitch: CGFloat = 3
    var onSeek: ((Double) -> Void)?

    var body: some View {
        Group {
            if let url = audioURL {
                BenchWaveformLoader(audioURL: url, cacheURL: material.waveformURL,
                                    playedFraction: playedFraction,
                                    tint: Bench.Palette.stem(material.kind),
                                    barPitch: barPitch, onSeek: onSeek)
            } else {
                Text(missingLabel)
                    .font(Bench.Typo.mono(10))
                    .foregroundStyle(Bench.Palette.textFaintest)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(height: height)
    }

    /// A MIDI or features part only has audio if something rendered it; every
    /// other kind is audio already.
    private var audioURL: URL? {
        if material.kind.hasPrefix("notes.") || material.kind.hasPrefix("features") {
            return material.auditionURL
        }
        return material.auditionURL ?? material.fileURL
    }

    private var missingLabel: String {
        material.kind.hasPrefix("notes.") ? "NO RENDERED PREVIEW YET" : "NO AUDIO"
    }

}

/// What the picker's strip is narrowing the list to.
///
/// One strip over both halves of the sheet rather than one over each: the
/// question it answers is "which of my stuff?", and the answer "a drum stem I
/// made this morning" is not a different kind of question from "one of my
/// imports". Parts joins the shelves as a peer for that reason, even though it
/// is a different table underneath.
///
/// The slices are `SongShelf`s, not `SongOrigin`s: the strip used to carry
/// Generated, Imported *and* Renders, so picking a mix you had made meant
/// knowing which of two tabs the app had filed it under. It names the same
/// shelves the Library's sidebar does, from the same enum, so the two surfaces
/// cannot drift into disagreeing about where a track lives.
enum PickerTab: Hashable {
    case all
    case songs(SongShelf)
    case parts
    /// Not a slice of the list like the ones above, but a filter across all of
    /// it: a song is on one shelf or the other, and either — or a part — may
    /// also have been edited or hearted. They carry a mark for that reason, so
    /// a strip of four places and two adjectives does not read as six places.
    case edited
    case loved

    var title: String {
        switch self {
        case .all: "All"
        case .songs(let shelf): shelf.title
        case .parts: "Parts"
        case .edited: "Edited"
        case .loved: "Loved"
        }
    }

    /// The same marks the sidebar's scopes use, because they mean the same
    /// thing in both places.
    var symbol: String? {
        switch self {
        case .all, .songs, .parts: nil
        case .edited: "scissors"
        case .loved: "heart.fill"
        }
    }

    /// Whether a row belongs on this tab. The origins and Parts decide by
    /// which list a row came from; these two decide per row.
    func admits(edited: Bool, loved: Bool) -> Bool {
        switch self {
        case .all, .songs, .parts: true
        case .edited: edited
        case .loved: loved
        }
    }

    /// What the tab calls the things it is not showing you, for the empty
    /// state. Plural and lowercase: "No renders match “kick”."
    var noun: String {
        switch self {
        case .all: "material"
        case .songs(let shelf): shelf.noun
        case .parts: "parts"
        case .edited: "edited material"
        case .loved: "loved material"
        }
    }

    var showsSongs: Bool {
        switch self {
        case .all, .songs, .edited, .loved: true
        case .parts: false
        }
    }

    var showsParts: Bool {
        switch self {
        case .all, .parts, .edited, .loved: true
        case .songs: false
        }
    }

    /// Drawn as one merged list of parts and songs rather than as sections.
    var isMerged: Bool {
        switch self {
        case .all, .edited, .loved: true
        case .songs, .parts: false
        }
    }

    /// The strip, and what each tab counts.
    ///
    /// `partCount` is nil where the slot takes no parts at all, which is the
    /// difference between a tab reading "Parts 0" — there are none *yet* — and
    /// no tab, meaning this slot would not take one anyway. The shelves are
    /// listed even at zero for the same reason the library's scopes are: a
    /// fixed strip you can learn beats one that reshuffles itself as the
    /// library fills up.
    ///
    /// No songs to show means no strip at all: the only tabs left would be All
    /// and Parts, which is one list and a synonym for it.
    static func strip(songCounts: [SongShelf: Int], showsSongs: Bool,
                      partCount: Int?, editedCount: Int,
                      lovedCount: Int) -> [(tab: PickerTab, count: Int)] {
        guard showsSongs else { return [] }
        let songs = SongShelf.allCases.map { ($0, songCounts[$0] ?? 0) }
        let total = songs.reduce(0) { $0 + $1.1 } + (partCount ?? 0)
        var strip: [(tab: PickerTab, count: Int)] = [(.all, total)]
        strip += songs.map { (PickerTab.songs($0.0), $0.1) }
        if let partCount { strip.append((.parts, partCount)) }
        // After the slices, and marked, because they overlap them: All is the
        // union of the tabs to its left and *not* the sum of all of them.
        strip.append((.edited, editedCount))
        strip.append((.loved, lovedCount))
        return strip
    }
}

/// Pick material for a slot: matching parts and (when accepted) full songs;
/// incompatible rows stay visible with the reason, and songs that could
/// produce a match offer the one-click "Split now" fix.
///
/// This is the one thing in Actions that stays a sheet. It is a modal question
/// with a modal answer — "which of these?" — asked from inside a page that is
/// still there underneath, and it is asked from the Workbench too, which has no
/// page to give it.
struct PartPickerSheet: View {
    let slotLabel: String
    let accepts: [KindPattern]
    let autoDerive: AutoDerive?
    let catalog: ModelCatalogStore
    let library: LibraryStore
    let parts: PartsStore
    let jobs: JobsStore
    let playback: PlaybackController
    let onOpenModels: () -> Void
    let onPick: (PickedMaterial) -> Void
    /// Fired after a "Split now" was enqueued for a song, so the caller can
    /// auto-fill the slot once matching parts arrive.
    var onSplitStarted: ((String) -> Void)?
    /// Which tab the strip opens on.
    ///
    /// `.all` wherever the slot is honestly "any of my stuff". A caller passes
    /// something else when its *button* already named a kind — the Workbench's
    /// "Add part" is a click aimed at parts, and answering it with a list led
    /// by songs makes the user narrow a filter they had already set by
    /// clicking. It is a starting tab and not a restriction: everything else
    /// is one click away, where it always was.
    var opensOn: PickerTab = .all

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var splittingSongIds: Set<String> = []
    /// What the strip is showing, once the user has said. Nil until then, so
    /// that `opensOn` can be honoured without an `onAppear` that would fight
    /// the user's own choice every time the sheet re-renders.
    @State private var chosenTab: PickerTab?
    /// Every part in the library, read once when the sheet opens.
    ///
    /// The whole table on purpose — see `hasPartsForThisSlot` — but read as
    /// state rather than as a computed property. Both the tab decision and the
    /// list itself were fetching it from inside `body`, so opening this sheet
    /// and typing into its search field re-read the entire parts table on
    /// every keystroke, twice, and again on every redraw in between.
    @State private var everyPart: [PartRecord] = []
    /// Song titles by song id — the second line of every part row.
    ///
    /// Read with `everyPart` and for the same reason. A part names the song it
    /// came out of by id only, so the list was resolving one title per row
    /// with a single-row query from inside `body`: a hundred parts meant a
    /// hundred queries on every keystroke and every redraw, twice over. One
    /// read of the song table answers all of them. Nothing can rename a song
    /// while this sheet is up — it is modal — so a map that refreshes with the
    /// parts is as live as the rows it labels.
    @State private var sourceTitles: [String: String] = [:]

    /// The tab on screen: the user's, or the caller's opening one while it
    /// still has something on it.
    private var tab: PickerTab { chosenTab ?? opening }

    private var tabBinding: Binding<PickerTab> {
        Binding(get: { tab }, set: { chosenTab = $0 })
    }

    /// `opensOn`, demoted to `.all` when it would open on nothing.
    ///
    /// A Parts default in a library with no splits yet would hide every song
    /// the slot *would* have taken behind a tab the user never asked for —
    /// which is the thing opening on `.all` was protecting against in the
    /// first place. The strip itself is absent when the slot shows no songs,
    /// and then the tab means nothing either way.
    private var opening: PickerTab {
        guard showsSongs else { return .all }
        guard case .parts = opensOn else { return opensOn }
        guard partsAccepted, hasPartsForThisSlot else { return .all }
        return .parts
    }

    /// Whether the parts table holds anything this slot would actually take —
    /// asked of the whole table rather than of `matchingParts`, because what
    /// the strip opens on must not move under the user as they type.
    private var hasPartsForThisSlot: Bool {
        everyPart.contains { part in accepts.contains { $0.matches(part.kind) } }
    }

    private var songAccepted: Bool {
        accepts.contains { $0.matches("song.mix") }
    }

    /// Whether this slot would take a part at all — as opposed to having none
    /// to offer today. Decides whether the Parts tab exists, not whether it
    /// has anything in it.
    private var partsAccepted: Bool {
        accepts.contains { $0.pattern != "song.mix" }
    }

    /// The songs half of the sheet is listed either to be picked or to be
    /// split; with neither there is nothing for a strip to narrow.
    private var showsSongs: Bool { songAccepted || autoDerive != nil }

    private var allParts: [PartRecord] {
        guard !query.isEmpty else { return everyPart }
        return everyPart.filter {
            $0.name.localizedCaseInsensitiveContains(query)
        }
    }

    /// Everything the search matches, before the origin tab narrows it. Kept
    /// whole so the tab counts stay live as you type — a tab reading "Imported
    /// 0" is the answer to "is there anything of mine in here?", and it can
    /// only say that if the search has already been applied to it.
    private var matchingSongs: [SongRecord] {
        var filters = LibraryRepository.Filters()
        filters.query = query
        return (try? library.repository.search(filters)) ?? []
    }

    /// `matchingSongs`, narrowed by the shelf tab when one is showing.
    /// Takes the search results rather than reaching for them, because the
    /// pass that draws this list has already paid for them once.
    private func songsOnTab(_ matched: [SongRecord]) -> [SongRecord] {
        guard case .songs(let shelf) = tab else { return matched }
        return matched.filter { SongShelf(origin: $0.originKind) == shelf }
    }

    /// `All 132 · Generated 98 · Imported 30 · Parts 4`.
    private func tabs(_ rows: [Listed]) -> [BenchSegmented<PickerTab>.Option] {
        var counts: [SongShelf: Int] = [:]
        for row in rows {
            if let origin = row.origin {
                counts[SongShelf(origin: origin), default: 0] += 1
            }
        }
        return PickerTab.strip(
            songCounts: counts, showsSongs: showsSongs,
            partCount: partsAccepted ? rows.filter { $0.origin == nil }.count : nil,
            editedCount: rows.filter(\.isEdited).count,
            lovedCount: rows.filter(\.isLoved).count)
            .map { .init(value: $0.tab, label: $0.tab.title,
                         detail: "\($0.count)", symbol: $0.tab.symbol) }
    }

    private var splitModel: ModelInfo? {
        guard let autoDerive else { return nil }
        return catalog.models.first {
            $0.installState == .installed
                && $0.capabilities.supportedTasks.contains(autoDerive.splitTask)
        }
    }

    var body: some View {
        content
            .task { reloadParts() }
            // A split started from this sheet lands as new parts, and the list
            // it lands in is the one in front of the user.
            .onChange(of: parts.results) { reloadParts() }
    }

    private func reloadParts() {
        everyPart = (try? parts.repository.parts(.init())) ?? []
        let songs = (try? library.repository.search(.init())) ?? []
        sourceTitles = Dictionary(songs.map { ($0.id, $0.title) },
                                  uniquingKeysWith: { first, _ in first })
    }

    private var content: some View {
        // The whole list, read once and handed down. The tab strip's counts
        // and the rows underneath it are two views of the same thing, and
        // building it is a library search plus a row per part — asked for
        // separately, as they were, every keystroke in the search field paid
        // for all of it twice.
        let matched = showsSongs ? matchingSongs : []
        let rows = allListed(matched)
        let options = tabs(rows)
        return VStack(spacing: 0) {
            BenchPanelHeader {
                Text(slotLabel)
                    .font(Bench.Typo.inspectorTitle)
                    .foregroundStyle(Bench.Palette.textPrimary)
                Spacer(minLength: 8)
                BenchSearchField(text: $query, placeholder: "Search…",
                                 width: 200)
                Button("Cancel") { dismiss() }
                    .buttonStyle(.benchSecondary)
                    .keyboardShortcut(.cancelAction)
            }
            // Above the list rather than inside it, because it now governs the
            // whole list: a filter you have to scroll back to is one you stop
            // reaching for, and it sits beside the search box that feeds its
            // counts.
            if !options.isEmpty {
                BenchSegmented(selection: tabBinding, options: options,
                               fills: true)
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(Bench.Palette.hairline).frame(height: 1)
                    }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if tab.isMerged { mergedSection(rows) }
                    else if tab == .parts { partsSection }
                    else { songsSection(matched) }
                    if tab.showsParts { otherPartsSection }
                    if matchingParts.isEmpty && !songAccepted
                        && autoDerive == nil {
                        Text("Nothing in the library fits this slot yet.")
                            .font(Bench.Typo.body)
                            .foregroundStyle(Bench.Palette.textFaint)
                            .padding(.top, 30)
                    }
                }
                .padding(.horizontal, 18).padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // Wider than it was: seven tabs carrying counts need about 600 pt of
        // strip before the longest label starts giving up letters, and the
        // rows underneath spend the rest on waveform.
        .frame(width: 660, height: 520)
        .background(Bench.Palette.windowBackground)
        .preferredColorScheme(.dark)
    }

    // MARK: everything, together

    /// One row of the All list: what to draw, when it was made so the two
    /// tables can be interleaved, and — for a song that can only be split —
    /// the record the Split now button needs.
    struct Listed: Identifiable {
        let material: PickedMaterial
        /// When this was last *touched* — made, or edited since. Sorting on it
        /// is what makes the list answer "what was I just working on", which
        /// `createdAt` alone could not: an edit leaves the row exactly where
        /// it was, which for a song made last month is a long way down.
        let touchedAt: Date
        /// nil for a part, which came from no one origin.
        let origin: SongOrigin?
        let isEdited: Bool
        let isLoved: Bool
        let splittable: SongRecord?
        var id: String { material.id }
    }

    /// Parts and songs in one list, newest first.
    ///
    /// Both tables already come back `createdAt DESC`, and the origins have
    /// always been mixed together rather than shelved apart — a render made
    /// this morning sits above an import from last year. Parts were the one
    /// kind kept in their own aisle, which meant the freshest thing in the
    /// library could be six rows below the oldest. The tabs are where you go
    /// when you want one kind; All is where you go when you want the newest.
    /// Every row the sheet could list, before a tab narrows it.
    private func allListed(_ songs: [SongRecord]) -> [Listed] {
        Self.merge(parts: matchingParts, sourceTitle: sourceTitle,
                   songs: songs, songsArePickable: songAccepted)
    }

    private func listed(_ rows: [Listed]) -> [Listed] {
        rows.filter { tab.admits(edited: $0.isEdited, loved: $0.isLoved) }
    }

    /// The interleave, kept out of the view so the rule can be read and tested
    /// on its own: most recently touched first, whichever table it came from.
    static func merge(parts: [PartRecord], sourceTitle: (PartRecord) -> String,
                      songs: [SongRecord],
                      songsArePickable: Bool) -> [Listed] {
        var rows = parts.map { part in
            Listed(material: PickedMaterial(part: part,
                                            sourceTitle: sourceTitle(part)),
                   touchedAt: max(part.createdAt, part.editedAt ?? .distantPast),
                   origin: nil, isEdited: part.editedAt != nil,
                   isLoved: part.favorite, splittable: nil)
        }
        rows += songs.map { song in
            Listed(material: PickedMaterial(song: song),
                   touchedAt: max(song.createdAt, song.editedAt ?? .distantPast),
                   origin: song.originKind, isEdited: song.editedAt != nil,
                   isLoved: song.favorite,
                   splittable: songsArePickable ? nil : song)
        }
        return rows.sorted { $0.touchedAt > $1.touchedAt }
    }

    /// No eyebrow: the tab above is the heading, and "PARTS"/"SONGS" over a
    /// list that is both would be a label for something else. The caption
    /// stays, because what happens when you pick a *song* is not obvious from
    /// the row and is the one thing the old heading was really saying.
    private func mergedSection(_ all: [Listed]) -> some View {
        let rows = listed(all)
        return VStack(alignment: .leading, spacing: 8) {
            if !mergedCaption.isEmpty {
                Text(mergedCaption.uppercased()).metaLine()
            }
            if rows.isEmpty {
                Text(emptyTabMessage)
                    .font(Bench.Typo.small)
                    .foregroundStyle(Bench.Palette.textFaint)
                    .padding(.vertical, 10)
            }
            VStack(spacing: 6) {
                ForEach(rows) { row in
                    if let song = row.splittable {
                        HStack(spacing: 10) {
                            PickerMaterialRow(material: row.material,
                                              origin: row.origin,
                                              parts: parts, playback: playback)
                                .opacity(0.6)
                            splitNowButton(song)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                    } else {
                        // Carried on the row rather than looked up per draw:
                        // `matchingSongs` is a database query, and asking it
                        // once per row turned one search into a hundred.
                        pickRow(row.material, origin: row.origin)
                    }
                }
            }
        }
    }

    /// Said as a sentence rather than as the "SONGS ·" label it replaces: over
    /// a mixed list the label would be describing only some of the rows.
    private var mergedCaption: String {
        // On every merged tab, not only All: what picking a song does is the
        // same fact whether you found it among everything or among the ones
        // you have hearted.
        guard showsSongs, tab.isMerged else { return "" }
        return songAccepted ? "a song is picked as its whole mix"
                            : (autoDerive?.note ?? "")
    }

    // MARK: parts

    private var matchingParts: [PartRecord] {
        allParts.filter { part in accepts.contains { $0.matches(part.kind) } }
    }

    private var otherParts: [PartRecord] {
        allParts.filter { part in !accepts.contains { $0.matches(part.kind) } }
    }

    private func sourceTitle(_ part: PartRecord) -> String {
        sourceTitles[part.songId] ?? part.modelName
    }

    @ViewBuilder
    private var partsSection: some View {
        if !matchingParts.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("PARTS").eyebrow()
                VStack(spacing: 6) {
                    ForEach(matchingParts) { part in
                        let title = sourceTitle(part)
                        pickRow(PickedMaterial(part: part, sourceTitle: title))
                    }
                }
            }
        } else if tab == .parts {
            // Only on its own tab. On All an empty parts list is answered by
            // the songs underneath it; here there is nothing else on screen,
            // and a blank sheet does not say whether it is the library or the
            // search that came up empty.
            VStack(alignment: .leading, spacing: 8) {
                Text("PARTS").eyebrow()
                Text(emptyTabMessage)
                    .font(Bench.Typo.small)
                    .foregroundStyle(Bench.Palette.textFaint)
                    .padding(.vertical, 10)
            }
        }
    }

    @ViewBuilder
    private var otherPartsSection: some View {
        if !otherParts.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("DOESN'T FIT THIS SLOT").eyebrow()
                VStack(spacing: 6) {
                    ForEach(otherParts) { part in
                        HStack(spacing: 11) {
                            StemBar(kind: part.kind, width: 5, height: 18)
                            Text(part.name)
                                .font(Bench.Typo.secondary)
                                .foregroundStyle(Bench.Palette.textMuted)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(reason(for: part).uppercased()).metaLine()
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        // The fifth rule at row scale: an item that cannot be
                        // picked dims and says why rather than vanishing, so
                        // "where did my drum part go?" never happens.
                        .opacity(0.45)
                    }
                }
            }
        }
    }

    private func reason(for part: PartRecord) -> String {
        let friendly = part.kind
            .replacingOccurrences(of: "stem.", with: "")
            .replacingOccurrences(of: "notes.", with: "")
            .replacingOccurrences(of: "features.", with: "")
        return "this is a \(friendly) part"
    }

    // MARK: songs

    @ViewBuilder
    private func songsSection(_ matched: [SongRecord]) -> some View {
        if songAccepted || autoDerive != nil {
            let songs = songsOnTab(matched)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Text("SONGS").eyebrow()
                    Text((songAccepted ? "picked as the full mix"
                                       : (autoDerive?.note ?? "")).uppercased())
                        .metaLine()
                    Spacer(minLength: 0)
                }
                if songs.isEmpty {
                    Text(emptyTabMessage)
                        .font(Bench.Typo.small)
                        .foregroundStyle(Bench.Palette.textFaint)
                        .padding(.vertical, 10)
                }
                VStack(spacing: 6) {
                    ForEach(songs) { song in
                        if songAccepted {
                            pickRow(PickedMaterial(song: song))
                        } else if autoDerive != nil {
                            HStack(spacing: 10) {
                                PickerMaterialRow(
                                    material: PickedMaterial(song: song),
                                    parts: parts, playback: playback)
                                    .opacity(0.6)
                                splitNowButton(song)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 8)
                        }
                    }
                }
            }
        }
    }

    // MARK: rows

    /// What the empty tab says. "Nothing here" is unhelpful when the reason is
    /// a search term rather than an empty collection.
    private var emptyTabMessage: String {
        let what = tab.noun
        return query.isEmpty
            ? "No \(what) in the library yet."
            : "No \(what) match “\(query)”."
    }

    private func pickRow(_ material: PickedMaterial,
                         origin: SongOrigin? = nil) -> some View {
        Button {
            onPick(material)
            dismiss()
        } label: {
            PickerMaterialRow(material: material, origin: origin,
                              parts: parts, playback: playback)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.row,
                                             style: .continuous)
                    .fill(Bench.Palette.rowZebra))
                // Transparent padding takes no hits in SwiftUI: without this
                // only the text is clickable.
                .contentShape(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.row,
                                               style: .continuous))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func splitNowButton(_ song: SongRecord) -> some View {
        if splittingSongIds.contains(song.id) {
            HStack(spacing: 6) {
                BenchSpinner(size: 12)
                Text("SPLITTING…").metaLine()
            }
        } else if let model = splitModel {
            Button("Split now") {
                splittingSongIds.insert(song.id)
                onSplitStarted?(song.id)
                Task {
                    await jobs.submitSplit(
                        modelId: model.id, songId: song.id,
                        sourceTitle: song.title, sourceURL: song.fileURL,
                        params: [:])
                }
            }
            .buttonStyle(.bench(.accent))
        } else {
            Button("Get a separation model") {
                onOpenModels()
                dismiss()
            }
            .buttonStyle(.benchSecondary)
        }
    }
}

/// One row of the picker: audition button, stem colour, the words, the
/// waveform, and whatever has been measured about it.
///
/// A view of its own rather than a method on the sheet, because that is what
/// decides how much of the screen a transport tick touches. SwiftUI's
/// granularity is the body that read the property, and read from inside
/// `PartPickerSheet.body` the playhead rebuilt the *whole sheet* four times a
/// second for the length of every audition — search, tab counts and forty
/// other rows included. Here the tick reaches the one row that is playing.
/// Same shape and same reason as `ActionMaterialRow`.
private struct PickerMaterialRow: View {
    let material: PickedMaterial
    var origin: SongOrigin?
    let parts: PartsStore
    let playback: PlaybackController

    /// Read before the play position everywhere below, and short-circuited
    /// with a ternary rather than folded into the strip: a body only observes
    /// what it actually read, so on every row but the one playing
    /// `playedFraction` — and through it `currentTime` — is never touched, and
    /// the tick redraws one row instead of the list. `LibrarySongRow` keeps
    /// the same rule for the same reason.
    private var isCurrent: Bool { playback.currentSongId == material.id }

    var body: some View {
        let analysis = parts.analysis(for: material.id)
        HStack(spacing: 11) {
            BenchPlayButton(isPlaying: isCurrent && playback.isPlaying,
                            isCurrent: isCurrent, size: 26) {
                guard let url = material.auditionURL else { return }
                playback.play(url: url, songId: material.id,
                              title: material.name,
                              duration: material.durationS ?? 0)
            }
            StemBar(kind: material.kind, width: 5, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(material.name)
                    .font(Bench.Typo.secondaryEmphasis)
                    .foregroundStyle(Bench.Palette.textPrimary)
                    .lineLimit(1)
                Text(ActionFormat.join([
                    // Generated is the unmarked case: it is what most of the
                    // list is, and labelling every row of it says nothing.
                    origin == .generated ? nil : origin?.rowLabel.uppercased(),
                    material.kind == "song.mix" ? nil
                        : material.sourceTitle.uppercased(),
                    material.durationS.map(ActionFormat.length)]))
                    .metaLine()
                    .lineLimit(1)
            }
            .frame(width: 190, alignment: .leading)
            // Seekable only on the row you are listening to. Everywhere else
            // in this sheet a click means "pick this", and the waveform is the
            // widest thing in the row — quietly turning it into a scrubber on
            // forty rows would make most of the list unpickable. On the row
            // that is playing there is nothing to lose: it is the one you have
            // already chosen to hear.
            MaterialStrip(material: material,
                          playedFraction: isCurrent ? playback.playedFraction : 0,
                          height: 24,
                          onSeek: isCurrent ? { fraction in
                              guard playback.duration > 0 else { return }
                              playback.seek(to: fraction * playback.duration)
                          } : nil)
            if let camelot = analysis?.camelot { BenchBadge(camelot) }
            if let bpm = analysis?.bpm {
                BenchBadge("\(Int(bpm.rounded())) BPM")
            }
        }
    }
}

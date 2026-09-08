import AppKit
import SwiftUI

/// One heading plus the parts under it. The library screen builds these; the
/// list only draws them, so the database work (song titles, per-song analysis,
/// which separator produced them) happens once per refresh rather than once per
/// redraw.
struct LibraryPartGroup: Identifiable {
    let id: String
    let header: Header?
    let parts: [PartRecord]

    enum Header {
        /// `bagpipes playing a soulful… ` + `201 S · 107 BPM · 8B · DEMUCS 6-STEM`
        case song(title: String, meta: String)
        /// `NOTES & MIDI PARTS · 5`
        case caption(String)

        /// The notes-and-features heading. It is not a song, and it sits apart
        /// from the ones that are, so it keeps a little more air above it.
        var isCaption: Bool {
            if case .caption = self { return true }
            return false
        }
    }
}

/// The Parts scope. Same shell and the same row rhythm as Songs, but the rows
/// are grouped under the song they were cut from, because a flat list of forty
/// stems named Vocals / Drums / Bass reads as repetition rather than material.
///
/// The groups are closed until asked for, so the scope opens as a list of the
/// songs that have parts rather than as every stem the library holds — forty
/// rows of Vocals / Drums / Bass is the same repetition again, just sorted.
struct LibraryPartList: View {
    let groups: [LibraryPartGroup]
    let analyses: [String: AnalysisRecord]
    let playback: PlaybackController
    /// Which groups are open, by `LibraryPartGroup.id`. Held by the window,
    /// like the selection and the scroll position and for the same reason:
    /// this screen is rebuilt on every navigation, so a set owned here would
    /// close every group the moment you stepped out to the Editor and back.
    @Binding var expanded: Set<String>
    @Binding var selectedId: String?
    /// Ticked rows, shared with the songs list: one selection spans both
    /// kinds, because Favourites shows both and "delete these" means the same
    /// thing either way.
    @Binding var checked: Set<String>
    let onPlay: (PartRecord) -> Void
    let onSeek: (PartRecord, Double) -> Void
    let onAddToWorkbench: (PartRecord) -> Void
    let onRenderNotes: ((PartRecord) -> Void)?
    /// Where this list files its scroll position — see `LibraryScrollMemory`.
    var scroll: LibraryScrollSlot?

    /// The heading under the pointer, if any. One id rather than a flag per
    /// header: only one of them can be hovered.
    @State private var hovered: String?

    /// Flattened once so arrow keys can step across group boundaries. Only
    /// what is on screen: an arrow key that walked into a closed group would
    /// move the selection somewhere the eye cannot follow it.
    private var flat: [PartRecord] {
        groups.filter { isOpen($0) }.flatMap(\.parts)
    }

    /// A group with no header is the ungrouped list — "Group by song" is off,
    /// there is no heading to click and nothing to gather the rows under, so
    /// it is always open.
    private func isOpen(_ group: LibraryPartGroup) -> Bool {
        group.header == nil || expanded.contains(group.id)
    }

    var body: some View {
        // Measured once for the whole list — see `LibraryRowMetrics`.
        GeometryReader { pane in
            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(groups) { group in
                        if let header = group.header {
                            headerView(header, group: group)
                                .id(group.id)
                                // Anchored like a row: closed, the headings
                                // are the only thing in the list, and without
                                // this the scroll memory would have nothing to
                                // remember the Parts scope by.
                                .libraryScrollAnchor(group.id)
                        }
                        if isOpen(group) {
                            ForEach(Array(group.parts.enumerated()),
                                    id: \.element.id) { index, part in
                                LibraryPartRow(
                                    part: part,
                                    contentWidth: LibraryRowMetrics
                                        .contentWidth(pane: pane.size.width),
                                    analysis: analyses[part.id],
                                    isZebra: index.isMultiple(of: 2),
                                    isSelected: part.id == selectedId,
                                    isChecked: checked.contains(part.id),
                                    showsCheckbox: true,
                                    playback: playback,
                                    onToggleCheck: { toggleCheck(part) },
                                    onPlay: { onPlay(part) },
                                    onSelect: { selectedId = part.id },
                                    onSeek: { onSeek(part, $0) })
                                    .id(part.id)
                                    .libraryScrollAnchor(part.id)
                                    .contextMenu { menu(for: part) }
                            }
                        }
                    }
                }
                .padding(.horizontal, LibraryRowMetrics.listPadding)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .remembersLibraryScroll(scroll, proxy: proxy)
            .focusable()
            .focusEffectDisabled()
            .onMoveCommand(perform: move)
            // No anchor: `scrollTo` without one does the documented minimum
            // scroll to make the row visible, which is what the `List` this
            // replaced did. A `.center` anchor fires on *every* selection
            // change, so clicking a row that is already on screen — or its play
            // button, or its waveform — would slide the list out from under the
            // pointer.
            .onChange(of: selectedId) {
                guard let selectedId else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(selectedId)
                }
            }
            }
        }
    }

    /// What the row used to carry as buttons. Owned by the list rather than
    /// the row, which is how `LibrarySongList` does it and for the same
    /// reason: a menu is about the row's place in a list, not about the row.
    @ViewBuilder
    private func menu(for part: PartRecord) -> some View {
        if part.auditionURL != nil {
            Button("Play") { onPlay(part) }
            Divider()
        }
        // Only audio goes on the bench — a notes part has to be rendered
        // first, which is the item below it.
        Button("Add to Workbench") { onAddToWorkbench(part) }
            .disabled(part.format != "wav")
        if part.format == "midi" {
            // Dimmed rather than absent when there is no renderer installed:
            // absent reads as "this part cannot be rendered", which is a
            // different and wrong claim.
            Button("Render notes…") { onRenderNotes?(part) }
                .disabled(onRenderNotes == nil)
        }
        Divider()
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([part.fileURL])
        }
    }

    /// The heading, and the control that opens what is under it. The whole
    /// width is the target rather than the chevron alone — the heading *is*
    /// the row while the group is closed, and a list you have to hit a
    /// 9-point glyph to read is a list you fight.
    private func headerView(_ header: LibraryPartGroup.Header,
                            group: LibraryPartGroup) -> some View {
        let isOpen = expanded.contains(group.id)
        let pad = Self.headerPadding(isCaption: header.isCaption, isOpen: isOpen)
        return Button {
            toggle(group.id)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Bench.Palette.textQuaternary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    // The chevron turns, the rows do not slide: animating the
                    // insertion of forty lazy rows costs a great deal more
                    // than the turn is worth.
                    .animation(.easeOut(duration: 0.15), value: isOpen)
                    .frame(width: 11, alignment: .leading)
                headerLabel(header, count: group.parts.count, isOpen: isOpen)
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 12)
            .padding(.top, pad.top).padding(.bottom, pad.bottom)
            .frame(maxWidth: .infinity, alignment: .leading)
            // A plain button says nothing on hover, and a closed list is
            // nothing but these — without a lit row the headings read as
            // titles printed over the list rather than as the way into it.
            .background(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.row,
                                         style: .continuous)
                .fill(hovered == group.id ? Bench.Palette.rowZebra : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? group.id : (hovered == group.id ? nil : hovered) }
        .help(isOpen ? "Hide these parts" : "Show these parts")
        .contextMenu { headerMenu(group) }
    }

    /// Open, a heading is the top of a block and takes its air above it.
    /// Closed, the headings *are* the list, and even padding is what makes
    /// them read as rows to walk down rather than as a stack of titles.
    private static func headerPadding(isCaption: Bool, isOpen: Bool)
        -> (top: CGFloat, bottom: CGFloat) {
        guard isOpen else { return (isCaption ? 11 : 7, 7) }
        return isCaption ? (16, 4) : (12, 6)
    }

    @ViewBuilder
    private func headerLabel(_ header: LibraryPartGroup.Header,
                             count: Int, isOpen: Bool) -> some View {
        switch header {
        case .song(let title, let meta):
            HStack(spacing: 10) {
                Text(title)
                    .font(Bench.Typo.secondaryEmphasis)
                    .foregroundStyle(Bench.Palette.textSecondary)
                    .lineLimit(1).truncationMode(.tail)
                Text(isOpen ? meta : Self.closedMeta(meta, count: count))
                    .metaLine()
                    .lineLimit(1)
                    .fixedSize()
            }
        case .caption(let text):
            // The caption counts its own parts — `NOTES & MIDI PARTS · 5` —
            // so it needs nothing added when it closes.
            Text(text)
                .font(Bench.Typo.mono(11))
                .foregroundStyle(Bench.Palette.textFaintest)
        }
    }

    /// What a closed group is holding, on the end of its meta line. Open, the
    /// rows say it themselves; closed, the heading is otherwise all about the
    /// song and says nothing about how much is folded under it.
    private static func closedMeta(_ meta: String, count: Int) -> String {
        let held = "\(count) PART\(count == 1 ? "" : "S")"
        return meta.isEmpty ? held : "\(meta) · \(held)"
    }

    @ViewBuilder
    private func headerMenu(_ group: LibraryPartGroup) -> some View {
        Button(expanded.contains(group.id) ? "Collapse" : "Expand") {
            toggle(group.id)
        }
        Divider()
        // Opening fifty groups one at a time is not a gesture anyone should
        // have to make, and neither is closing them again.
        Button("Expand All") { expanded = Set(headed.map(\.id)) }
        Button("Collapse All") { expanded = [] }
    }

    /// The groups a heading can open. The ungrouped list has none.
    private var headed: [LibraryPartGroup] {
        groups.filter { $0.header != nil }
    }

    private func toggle(_ id: String) {
        if expanded.contains(id) {
            expanded.remove(id)
        } else {
            expanded.insert(id)
        }
    }

    private func toggleCheck(_ part: PartRecord) {
        if checked.contains(part.id) {
            checked.remove(part.id)
        } else {
            checked.insert(part.id)
        }
    }

    private func move(_ direction: MoveCommandDirection) {
        switch direction {
        // The sideways pair open and close the group the selection is in,
        // which is what they do in every outline on the system.
        case .left, .right:
            guard let selectedId,
                  let group = headed.first(where: { group in
                      group.parts.contains { $0.id == selectedId }
                  }) else { return }
            if direction == .right {
                expanded.insert(group.id)
            } else {
                expanded.remove(group.id)
            }
        case .up, .down:
            let parts = flat
            guard !parts.isEmpty else { return }
            let current = parts.firstIndex { $0.id == selectedId }
            if direction == .down {
                selectedId = parts[current.map { min($0 + 1, parts.count - 1) } ?? 0].id
            } else {
                selectedId = parts[current.map { max($0 - 1, 0) } ?? parts.count - 1].id
            }
        @unknown default:
            return
        }
    }
}

// MARK: - Row

/// One part, in the row grammar every other library scope uses: a tick box, a
/// two-line title block, the signal, five stars, a heart.
///
/// It used to be its own thing — a single-line name, key/tempo badges where
/// the stars belong, and a `＋ Bench` button on the end — which made Parts read
/// as a different kind of list rather than the same library seen through a
/// different filter. The actions it carried moved to the row's context menu,
/// where every song action already lives.
///
/// The stem colour is what survives of the old row, and deliberately: it is
/// the same colour this part's swatch, waveform, workbench slider and timeline
/// clip carry, so a glance down the list still reads as instrumentation.
struct LibraryPartRow: View {
    let part: PartRecord
    /// The width this row's content has to draw in — see `LibraryRowMetrics`.
    var contentWidth: CGFloat = .infinity
    let analysis: AnalysisRecord?
    let isZebra: Bool
    let isSelected: Bool
    var isChecked = false
    var showsCheckbox = false
    let playback: PlaybackController
    var onToggleCheck: () -> Void = {}
    let onPlay: () -> Void
    let onSelect: () -> Void
    let onSeek: (Double) -> Void

    private var stem: Color { Bench.Palette.stem(part.kind) }
    private var isCurrent: Bool { playback.currentSongId == part.id }

    private var playedFraction: Double {
        guard isCurrent, let duration = part.durationS, duration > 0 else {
            return 0
        }
        return playback.currentTime / duration
    }

    /// Under this, a waveform is thirty bars of noise: it has stopped being a
    /// signal and is only taking room from the label beside it.
    static let minStripWidth: CGFloat = 96

    /// What this row needs before the strip is affordable without asking. A
    /// parts row carries no badge and no spinner, so its shape varies only by
    /// the tick box.
    private var widthForStrip: CGFloat {
        Self.stripIdealWidth
            + (showsCheckbox ? LibrarySongRow.checkboxSlot : 0)
    }

    /// A plain parts row's strip variant. Wider than the song row's by the
    /// stem bar in front of the title.
    static let stripIdealWidth: CGFloat = 400

    var body: some View {
        // Wide enough and the strip is taken without asking; near the edge the
        // ladder decides, as it always did — the strip is the one thing in the
        // row that degrades to nothing gracefully, the inspector draws the same
        // signal at a size worth aiming at, while half a title identifies
        // nothing.
        Group {
            if contentWidth >= widthForStrip {
                content(showsStrip: true)
            } else {
                ViewThatFits(in: .horizontal) {
                    content(showsStrip: true)
                    content(showsStrip: false)
                }
            }
        }
        .padding(.horizontal, LibraryRowMetrics.rowPadding)
        .padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.row,
                                     style: .continuous)
            .fill(fill))
        // Accented in the stem's own colour rather than the app accent the
        // song rows use: in a list where colour means instrument, a selection
        // ring in some other colour is the one thing that would read as a
        // sixth stem.
        .overlay(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.row,
                                  style: .continuous)
            .strokeBorder(isSelected ? stem.opacity(0.3) : .clear, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.row,
                                       style: .continuous))
        .onTapGesture(perform: onSelect)
    }

    private var fill: Color {
        if isSelected { return Bench.Palette.rowSelected }
        return isZebra ? Bench.Palette.rowZebra : .clear
    }

    func content(showsStrip: Bool) -> some View {
        HStack(spacing: 12) {
            if showsCheckbox {
                LibraryCheckbox(isOn: isChecked, action: onToggleCheck)
            }
            if part.auditionURL != nil {
                BenchPlayButton(isPlaying: isCurrent && playback.isPlaying,
                                isCurrent: isCurrent, size: 26, tint: stem,
                                action: onPlay)
            } else {
                // Features parts are numbers, not sound; the slot keeps its
                // width so the colour bars still line up down the list.
                Color.clear.frame(width: 26, height: 26)
            }
            StemBar(kind: part.kind, width: 6, height: 26)
            titleBlock
                // Bounded exactly as the song row's is, and from its constants
                // rather than a second set: the two lists sit one sidebar
                // click apart, and a title column that changed width when you
                // moved between them would read as a different app.
                .frame(minWidth: showsStrip ? LibrarySongRow.minTitleWidth : nil,
                       idealWidth: showsStrip ? LibrarySongRow.minTitleWidth : nil,
                       maxWidth: showsStrip ? LibrarySongRow.maxTitleWidth : .infinity,
                       alignment: .leading)
            if showsStrip {
                // The floor is what makes this a choice rather than a
                // formality: the loader is a `GeometryReader`, so its ideal
                // width is nearly nothing, and without one both variants would
                // measure as fitting and the first would always win.
                strip
                    .frame(height: 28)
                    .frame(minWidth: Self.minStripWidth, maxWidth: .infinity)
            }
            RatingStars(rating: part.rating, size: 12)
                .frame(width: 76, alignment: .trailing)
            FavouriteHeart(isFavourite: part.favorite)
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(part.name)
                .font(isSelected ? Bench.Typo.bodyEmphasis : Bench.Typo.body)
                .foregroundStyle(Bench.Palette.textPrimary)
                .lineLimit(1).truncationMode(.tail)
            Text(LibraryPartRow.metaLine(for: part, analysis: analysis))
                .metaLine()
                .lineLimit(1)
        }
    }

    /// `STEM · DEMUCS 4-STEM · 201 S · 124 BPM · 5A` — the parts answer to
    /// `LibrarySongRow.metaLine`, in the same order and the same units: what
    /// it is, what made it, how long it runs, then what has been measured of
    /// it.
    ///
    /// It also carries the two things the *name* stopped saying when part
    /// names became `other-track042`: what "Other" actually holds, and that a
    /// notes part is symbols rather than sound.
    static func metaLine(for part: PartRecord,
                         analysis: AnalysisRecord?) -> String {
        var fields = [PartNaming.family(kind: part.kind).uppercased()]
        if let qualifier = PartNaming.qualifier(kind: part.kind) {
            fields.append(qualifier.uppercased())
        } else if part.format == "midi" {
            fields.append("MIDI")
        } else if part.format == "json" {
            fields.append("DATA")
        }
        fields.append(part.modelName.uppercased())
        if let duration = part.durationS, duration > 0 {
            fields.append("\(LibraryFormat.seconds(duration)) S")
        }
        if let bpm = analysis?.bpm {
            fields.append("\(Int(bpm.rounded())) BPM")
        }
        if let camelot = analysis?.camelot { fields.append(camelot) }
        return fields.joined(separator: " · ")
    }

    /// This slot is where every other row shows a real signal, so it only ever
    /// draws one: the part's own audio, or — for a notes part — the WAV the
    /// split rendered beside the MIDI, which is the same file this row's play
    /// button plays. Nothing measured, nothing drawn.
    @ViewBuilder
    private var strip: some View {
        if let url = part.auditionURL {
            BenchWaveformLoader(audioURL: url, cacheURL: part.waveformURL,
                                playedFraction: playedFraction, tint: stem,
                                onSeek: onSeek)
        } else {
            Text(silentLabel)
                .font(Bench.Typo.mono(10))
                .foregroundStyle(Bench.Palette.textFaintest)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Why the strip is empty, and the two reasons are not the same: a features
    /// part never had audio, while a notes part is one "Render notes…" — now in
    /// the row's context menu — away from having some.
    private var silentLabel: String {
        part.format == "midi" ? "NO RENDERED PREVIEW YET" : "NO AUDIO"
    }

    /// `Other (keys, synths, rest)` → `Other` + `keys, synths, rest`.
    ///
    /// Kept for the sibling chips and anything else holding a name a user may
    /// have typed a parenthetical into; the row itself no longer splits its
    /// title, because the second line says what the qualifier used to.
    static func split(name: String) -> (base: String, qualifier: String?) {
        guard let open = name.firstIndex(of: "("), name.hasSuffix(")") else {
            return (name, nil)
        }
        let base = String(name[..<open]).trimmingCharacters(in: .whitespaces)
        let inner = name[name.index(after: open)...].dropLast()
        return (base.isEmpty ? name : base,
                inner.isEmpty ? nil : String(inner))
    }
}

// MARK: - Compact row

/// A part reduced to two lines, no waveform and no actions — the shape a
/// *picker* wants, where the job is choosing one part rather than hearing it.
/// `TrackRow` is the same idea for songs.
///
/// The library's own rows are `LibraryPartRow`, which is a different object
/// entirely (a waveform, badges, a bench button). Kept separate deliberately:
/// collapsing the two would give the picker a waveform it has no room for and
/// the library a row you cannot audition.
///
/// No caller as of the Bench redesign — `PartPickerSheet` grew its own
/// slot-aware row with a "doesn't fit this slot" state. Delete it if nothing
/// picks it up.
struct PartRow: View {
    let part: PartRecord
    let sourceTitle: String
    let analysis: AnalysisRecord?
    let playback: PlaybackController

    private var isCurrent: Bool { playback.currentSongId == part.id }

    var body: some View {
        HStack(spacing: 10) {
            if let url = part.auditionURL {
                BenchPlayButton(isPlaying: isCurrent && playback.isPlaying,
                                isCurrent: isCurrent, size: 22,
                                tint: Bench.Palette.stem(part.kind)) {
                    playback.play(url: url, songId: part.id, title: part.name,
                                  duration: part.durationS ?? 0,
                                  subtitle: sourceTitle.uppercased())
                }
            } else {
                Color.clear.frame(width: 22, height: 22)
            }
            StemBar(kind: part.kind, width: 4, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(part.name)
                    .font(Bench.Typo.body)
                    .foregroundStyle(Bench.Palette.textPrimary)
                    .lineLimit(1)
                Text(metaLine)
                    .metaLine()
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if let camelot = analysis?.camelot { BenchBadge(camelot) }
            if let bpm = analysis?.bpm { BenchBadge("\(Int(bpm.rounded())) BPM") }
        }
        .padding(.vertical, 3)
    }

    private var metaLine: String {
        var fields = [sourceTitle.uppercased()]
        if let duration = part.durationS {
            fields.append("\(LibraryFormat.seconds(duration)) S")
        }
        return fields.joined(separator: " · ")
    }
}

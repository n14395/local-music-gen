import AppKit
import SwiftUI

/// The Generated Songs, Imported and Renders lists — the same row grammar over
/// the same table, which is why one view serves all three scopes.
///
/// Not a `List`: the design's rows are 9 pt-radius cards separated by 2 pt with
/// their own zebra and their own accent selection ring, and `List` insists on
/// drawing its own selection over the top of that in the system's blue. Arrow
/// keys are kept by hand — see `onMoveCommand` — because losing them is the one
/// thing a hand-rolled list usually gets wrong.
struct LibrarySongList: View {
    let songs: [SongRecord]
    /// How many parts each song has been split into, for the `6 PARTS` clause.
    let partCounts: [String: Int]
    /// Songs a split job is running against right now.
    let splitting: Set<String>
    let playback: PlaybackController
    /// Only the whole-track scopes tick rows; the checkbox is what builds an
    /// A/B pair.
    let showsCheckboxes: Bool
    @Binding var selectedId: String?
    @Binding var checked: Set<String>
    let actions: SongActions
    let onPlay: (SongRecord) -> Void
    /// Scrubbing a row's waveform. Separate from `onPlay` because a scrub on a
    /// track that is not the one playing has to start it *and* land at the
    /// point you clicked, which is two calls into the transport rather than
    /// one.
    let onSeek: (SongRecord, Double) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                        LibrarySongRow(
                            song: song,
                            isZebra: !index.isMultiple(of: 2),
                            isSelected: song.id == selectedId,
                            isChecked: checked.contains(song.id),
                            showsCheckbox: showsCheckboxes,
                            partCount: partCounts[song.id] ?? 0,
                            isSplitting: splitting.contains(song.id),
                            playback: playback,
                            onToggleCheck: { toggleCheck(song) },
                            onPlay: { onPlay(song) },
                            onSelect: { selectedId = song.id },
                            onSeek: { onSeek(song, $0) })
                            .id(song.id)
                            .contextMenu { menu(for: song) }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
            .focusable()
            .focusEffectDisabled()
            .onMoveCommand(perform: move)
            // No anchor: `scrollTo` without one does the documented minimum
            // scroll to make the row visible, which is what the `List` this
            // replaced did. A `.center` anchor fires on *every* selection
            // change, so clicking a row that is already on screen — or its play
            // button — would slide the list out from under the pointer.
            .onChange(of: selectedId) {
                guard let selectedId else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(selectedId)
                }
            }
        }
    }

    @ViewBuilder
    private func menu(for song: SongRecord) -> some View {
        Button("Play") { onPlay(song) }
        Divider()
        Button("Edit…") { actions.edit(song) }
            .keyboardShortcut("e", modifiers: .command)
        if let count = LibrarySongRow.editCount(of: song), count > 0 {
            Button("Reopen the \(count) "
                   + (count == 1 ? "edit" : "edits")) { actions.edit(song) }
            Divider()
            Button("Play original") { actions.playOriginal(song) }
                .disabled(!FileManager.default
                    .fileExists(atPath: song.backupURL.path))
            Button("Reveal backup in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([song.backupURL])
            }
            .disabled(!FileManager.default
                .fileExists(atPath: song.backupURL.path))
            Divider()
            Button("Revert to original…", role: .destructive) {
                actions.revertEdits(song)
            }
        }
        Divider()
        Button("Reuse prompt") { actions.reusePrompt(song) }
            .disabled(song.originKind != .generated)
        Button("Restyle…") { actions.restyle(song) }
        Button("Split into…") { actions.split(song) }
        Button("Find matches") { actions.findMatches(song) }
        if song.originKind == .recombined {
            Button("Edit in Workbench") { actions.openMix(song) }
        }
        Divider()
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([song.fileURL])
        }
    }

    private func toggleCheck(_ song: SongRecord) {
        if checked.contains(song.id) {
            checked.remove(song.id)
        } else {
            checked.insert(song.id)
        }
    }

    /// Arrow keys move the selection, exactly as the `List` this replaced did.
    /// `onMoveCommand` only fires while this view holds focus, so typing in the
    /// search field still moves the caret rather than the selection.
    private func move(_ direction: MoveCommandDirection) {
        guard !songs.isEmpty else { return }
        let current = songs.firstIndex { $0.id == selectedId }
        let next: Int
        switch direction {
        case .down: next = current.map { min($0 + 1, songs.count - 1) } ?? 0
        case .up: next = current.map { max($0 - 1, 0) } ?? songs.count - 1
        default: return
        }
        selectedId = songs[next].id
    }
}

// MARK: - Row

/// checkbox · play · title block · waveform · stars · heart.
///
/// The strip is the same object the parts rows draw: one `BenchWaveformLoader`
/// over the track's own cached peaks, tinted up to the play position and
/// scrubbable where you click it. It sits in the same slot Parts puts it in,
/// between the words and the trailing controls, so the two scopes read as one
/// list with different material in them rather than as two designs.
///
/// It was dropped once, on the argument that forty little envelopes told you
/// less than the words they were squeezing. What answers that is not the
/// waveform being worth more than it was — it is that it no longer does the
/// squeezing: the title block has a floor and a ceiling of its own, and in a
/// pane too narrow to honour both, the ladder in `body` drops the strip and
/// gives the words back every point of it.
///
/// The stars keep a fixed trailing column and the heart its own slot after
/// them, so both line up down the list whether or not a given track has one —
/// and a long title cannot squeeze either, the failure `TrackTitleLayoutTests`
/// pins.
struct LibrarySongRow: View {
    let song: SongRecord
    let isZebra: Bool
    let isSelected: Bool
    let isChecked: Bool
    let showsCheckbox: Bool
    let partCount: Int
    let isSplitting: Bool
    let playback: PlaybackController
    let onToggleCheck: () -> Void
    let onPlay: () -> Void
    let onSelect: () -> Void
    /// Scrubbing the strip.
    let onSeek: (Double) -> Void

    private var isCurrent: Bool { playback.currentSongId == song.id }

    /// `currentSongId` is read first and the guard returns before
    /// `currentTime` on every row that is not the one playing. SwiftUI tracks
    /// the properties a body actually reads, so the order here is the
    /// difference between one row redrawing on each transport tick and every
    /// visible row doing it.
    private var playedFraction: Double {
        guard isCurrent, song.durationS > 0 else { return 0 }
        return playback.currentTime / song.durationS
    }

    /// Under this a strip is bars of noise rather than something you can tell
    /// two takes apart by. Read from the parts row rather than retyped: it is
    /// the same judgement about the same drawing, and two copies of it would
    /// drift the moment either list was tuned.
    static let minStripWidth = LibraryPartRow.minStripWidth

    /// The title block's floor and ceiling.
    ///
    /// The floor is deliberately tight, and the number is not a taste: at the
    /// window's 1100 pt floor the library pane is 442 pt, and a row that wants
    /// one point more than that is a row whose waveform nobody ever sees.
    /// `SongRowFitTests` measures the whole row against that budget, which is
    /// what this figure is left over from. It only ever binds at that width
    /// anyway, and there a truncated prompt beside a waveform reads better
    /// than a roomy prompt beside nothing.
    ///
    /// The ceiling is where a prompt pasted out of the Studio stops being
    /// worth more row than the sound it describes.
    static let minTitleWidth: CGFloat = 122
    static let maxTitleWidth: CGFloat = 480

    var body: some View {
        // The same ladder the parts rows climb, in the same order: the strip
        // is the one thing in the row that degrades to nothing gracefully —
        // the detail pane draws the same signal at a size worth aiming at —
        // while half a title identifies nothing.
        ViewThatFits(in: .horizontal) {
            content(showsStrip: true)
            content(showsStrip: false)
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.row,
                                     style: .continuous)
            .fill(fill))
        .overlay(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.row,
                                  style: .continuous)
            .strokeBorder(isSelected ? Bench.Palette.accent.opacity(0.22) : .clear,
                          lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.row,
                                       style: .continuous))
        .onTapGesture(perform: onSelect)
    }

    private func content(showsStrip: Bool) -> some View {
        HStack(spacing: 12) {
            if showsCheckbox {
                LibraryCheckbox(isOn: isChecked, action: onToggleCheck)
            }
            BenchPlayButton(isPlaying: isCurrent && playback.isPlaying,
                            isCurrent: isCurrent, size: 26, action: onPlay)
            titleBlock
                // With no strip beside it the block takes all the slack, which
                // is what this row did before it had one. With a strip it is
                // bounded at both ends: the ideal is pinned to the floor so the
                // variant measures at a width that does not depend on how long
                // this particular prompt happens to be — otherwise one pasted
                // paragraph would decide that no row in the list gets a
                // waveform.
                .frame(minWidth: showsStrip ? Self.minTitleWidth : nil,
                       idealWidth: showsStrip ? Self.minTitleWidth : nil,
                       maxWidth: showsStrip ? Self.maxTitleWidth : .infinity,
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
            if isSplitting {
                HStack(spacing: 6) {
                    BenchSpinner(size: 12)
                    Text("SPLITTING")
                        .font(Bench.Typo.mono(10, .semibold))
                        .foregroundStyle(Bench.Palette.accent)
                }
                .fixedSize()
            }
            if let count = LibrarySongRow.editCount(of: song), count > 0 {
                EditsBadge(count: count, isCurrent: isCurrent)
            }
            // 76, not 70: five stars at this size measure 73.5 pt, and
            // `RatingStars` is `.fixedSize()`, so a 70 pt column did not clip
            // them — it let them hang 3.5 pt out over whatever was to their
            // left. That was invisible while the neighbour was a text block
            // whose words stopped short of their own frame. The waveform fills
            // its frame exactly, so the same overhang now reads as bars
            // touching the first star.
            RatingStars(rating: song.rating, size: 12)
                .frame(width: 76, alignment: .trailing)
            FavouriteHeart(isFavourite: song.favorite)
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            TrackTitle(song: song, font: Bench.Typo.body, weight: .semibold)
            Text(LibrarySongRow.metaLine(for: song, partCount: partCount))
                .metaLine()
                .lineLimit(1)
        }
    }

    /// The track's own waveform. A whole track is always audio — there is no
    /// silent case to draw around, which is the one thing this slot has
    /// simpler than the parts row's.
    private var strip: some View {
        BenchWaveformLoader(audioURL: song.fileURL, cacheURL: song.waveformURL,
                            playedFraction: playedFraction, onSeek: onSeek)
    }

    private var fill: Color {
        if isSelected { return Bench.Palette.rowSelected }
        return isZebra ? Bench.Palette.rowZebra : .clear
    }

    /// `MUSICGEN SMALL · 9.9 S · 6 PARTS · TODAY 13:00` — the mono second line
    /// the design gives every row. The parts clause only appears once a song
    /// has been split, which is what makes it worth reading.
    ///
    /// An imported row leads with its artist instead of its model, since
    /// "IMPORTED" repeated down a list of imports says nothing.
    static func metaLine(for song: SongRecord, partCount: Int) -> String {
        var fields = [song.sourceLabel.uppercased(),
                      "\(LibraryFormat.seconds(song.durationS)) S"]
        if partCount > 0 {
            fields.append("\(partCount) PART" + (partCount == 1 ? "" : "S"))
        }
        // An edited row leads its date with the edit rather than the
        // generation: what you are looking for in this list is the change.
        if let editedAt = song.editedAt {
            fields.append("EDITED " + LibraryFormat.when(editedAt))
        } else {
            fields.append(LibraryFormat.when(song.createdAt))
        }
        return fields.joined(separator: " · ")
    }

    /// How many steps a track's applied program has, or nil when it has
    /// none. Reads `editedAt` first: a pending program is not something the
    /// file carries yet, and a row must not claim edits it cannot play.
    static func editCount(of song: SongRecord) -> Int? {
        guard song.editedAt != nil, let json = song.editsJSON,
              let document = try? JSONDecoder().decode(
                EditDocument.self, from: Data(json.utf8)) else { return nil }
        return document.editCount
    }
}

/// The scissors badge an edited row carries, with its step count.
struct EditsBadge: View {
    let count: Int
    var isCurrent = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "scissors")
                .font(.system(size: 9, weight: .semibold))
            Text(count == 1 ? "1 EDIT" : "\(count) EDITS")
                .font(Bench.Typo.mono(9, .semibold))
                .tracking(0.9)
        }
        .foregroundStyle(isCurrent ? Bench.Palette.accent
                                   : Bench.Palette.textTertiary)
        .padding(.horizontal, 7).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(isCurrent ? Bench.Palette.accent.opacity(0.12)
                            : Bench.Palette.raised))
        .fixedSize()
    }
}

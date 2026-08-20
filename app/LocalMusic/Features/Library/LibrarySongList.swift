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
                            onSelect: { selectedId = song.id })
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

/// checkbox · play · title block · stars · heart.
///
/// The title block takes the slack the waveform used to: a row is read by its
/// name and prompt, and forty little envelopes down a list told you far less
/// than the words they were squeezing. Scrubbing lives on the detail pane's
/// waveform, which is big enough to aim at.
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

    private var isCurrent: Bool { playback.currentSongId == song.id }

    var body: some View {
        HStack(spacing: 12) {
            if showsCheckbox {
                LibraryCheckbox(isOn: isChecked, action: onToggleCheck)
            }
            BenchPlayButton(isPlaying: isCurrent && playback.isPlaying,
                            isCurrent: isCurrent, size: 26, action: onPlay)
            VStack(alignment: .leading, spacing: 3) {
                TrackTitle(song: song, font: Bench.Typo.body, weight: .semibold)
                Text(LibrarySongRow.metaLine(for: song, partCount: partCount))
                    .metaLine()
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if isSplitting {
                HStack(spacing: 6) {
                    BenchSpinner(size: 12)
                    Text("SPLITTING")
                        .font(Bench.Typo.mono(10, .semibold))
                        .foregroundStyle(Bench.Palette.accent)
                }
                .fixedSize()
            }
            RatingStars(rating: song.rating, size: 12)
                .frame(width: 70, alignment: .trailing)
            FavouriteHeart(isFavourite: song.favorite)
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
        fields.append(LibraryFormat.when(song.createdAt))
        return fields.joined(separator: " · ")
    }
}

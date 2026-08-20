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
    }
}

/// The Parts scope. Same shell and the same row rhythm as Songs, but the rows
/// are grouped under the song they were cut from, because a flat list of forty
/// stems named Vocals / Drums / Bass reads as repetition rather than material.
struct LibraryPartList: View {
    let groups: [LibraryPartGroup]
    let analyses: [String: AnalysisRecord]
    let playback: PlaybackController
    @Binding var selectedId: String?
    let onPlay: (PartRecord) -> Void
    let onSeek: (PartRecord, Double) -> Void
    let onAddToWorkbench: (PartRecord) -> Void
    let onRenderNotes: ((PartRecord) -> Void)?

    /// Flattened once so arrow keys can step across group boundaries.
    private var flat: [PartRecord] { groups.flatMap(\.parts) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(groups) { group in
                        if let header = group.header { headerView(header) }
                        ForEach(Array(group.parts.enumerated()),
                                id: \.element.id) { index, part in
                            LibraryPartRow(
                                part: part,
                                analysis: analyses[part.id],
                                isZebra: index.isMultiple(of: 2),
                                isSelected: part.id == selectedId,
                                playback: playback,
                                onPlay: { onPlay(part) },
                                onSelect: { selectedId = part.id },
                                onSeek: { onSeek(part, $0) },
                                onAddToWorkbench: { onAddToWorkbench(part) },
                                onRenderNotes: onRenderNotes.map { render in
                                    { render(part) }
                                })
                                .id(part.id)
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
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

    @ViewBuilder
    private func headerView(_ header: LibraryPartGroup.Header) -> some View {
        switch header {
        case .song(let title, let meta):
            HStack(spacing: 10) {
                Text(title)
                    .font(Bench.Typo.secondaryEmphasis)
                    .foregroundStyle(Bench.Palette.textSecondary)
                    .lineLimit(1).truncationMode(.tail)
                Text(meta)
                    .metaLine()
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.top, 12).padding(.bottom, 6)
        case .caption(let text):
            Text(text)
                .font(Bench.Typo.mono(11))
                .foregroundStyle(Bench.Palette.textFaintest)
                .padding(.horizontal, 12)
                .padding(.top, 16).padding(.bottom, 4)
        }
    }

    private func move(_ direction: MoveCommandDirection) {
        let parts = flat
        guard !parts.isEmpty else { return }
        let current = parts.firstIndex { $0.id == selectedId }
        switch direction {
        case .down:
            selectedId = parts[current.map { min($0 + 1, parts.count - 1) } ?? 0].id
        case .up:
            selectedId = parts[current.map { max($0 - 1, 0) } ?? parts.count - 1].id
        default:
            return
        }
    }
}

// MARK: - Row

/// play · stem colour bar · 132 pt name · strip · heart · key · tempo · `＋ Bench`.
///
/// The stem colour is the whole point of the row: it is the same colour this
/// part's swatch, waveform, workbench slider and timeline clip carry, so a
/// glance down the list reads as instrumentation rather than as text.
struct LibraryPartRow: View {
    let part: PartRecord
    let analysis: AnalysisRecord?
    let isZebra: Bool
    let isSelected: Bool
    let playback: PlaybackController
    let onPlay: () -> Void
    let onSelect: () -> Void
    let onSeek: (Double) -> Void
    let onAddToWorkbench: () -> Void
    let onRenderNotes: (() -> Void)?

    private var stem: Color { Bench.Palette.stem(part.kind) }
    private var isCurrent: Bool { playback.currentSongId == part.id }

    private var playedFraction: Double {
        guard isCurrent, let duration = part.durationS, duration > 0 else {
            return 0
        }
        return playback.currentTime / duration
    }

    var body: some View {
        HStack(spacing: 12) {
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
            name
                .frame(width: 132, alignment: .leading)
            strip
                .frame(height: 24)
                .frame(maxWidth: .infinity)
            FavouriteHeart(isFavourite: part.favorite, size: 10)
            badges
            action
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.row,
                                     style: .continuous)
            .fill(isSelected ? Bench.Palette.rowSelected
                             : (isZebra ? Bench.Palette.rowZebra : .clear)))
        .overlay(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.row,
                                  style: .continuous)
            .strokeBorder(isSelected ? stem.opacity(0.3) : .clear, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.row,
                                       style: .continuous))
        .onTapGesture(perform: onSelect)
    }

    private var name: some View {
        HStack(spacing: 0) {
            Text(LibraryPartRow.split(name: part.name).base)
                .font(isSelected ? Bench.Typo.bodyEmphasis : Bench.Typo.body)
                .foregroundStyle(Bench.Palette.textPrimary)
                .lineLimit(1)
            if let qualifier {
                Text(" " + qualifier)
                    .font(Bench.Typo.body)
                    .foregroundStyle(Bench.Palette.textMuted)
                    .lineLimit(1).truncationMode(.tail)
            }
        }
    }

    /// The dim half of the name: what "Other" actually contains, or — when the
    /// part is not audio — what it is instead.
    private var qualifier: String? {
        if let parenthetical = LibraryPartRow.split(name: part.name).qualifier {
            return parenthetical
        }
        switch part.format {
        case "midi": return "MIDI"
        case "json": return "DATA"
        default: return nil
        }
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
    /// part never had audio, while a notes part is one "Render…" — the button
    /// immediately to its right — away from having some.
    private var silentLabel: String {
        part.format == "midi" ? "NO RENDERED PREVIEW YET" : "NO AUDIO"
    }

    @ViewBuilder
    private var badges: some View {
        if part.format == "wav" {
            if let camelot = analysis?.camelot { BenchBadge(camelot) }
            if let bpm = analysis?.bpm {
                BenchBadge("\(Int(bpm.rounded())) BPM")
            }
        } else {
            BenchBadge(part.modelName.uppercased(),
                       tone: part.format == "midi" ? .cyan : .neutral)
        }
    }

    @ViewBuilder
    private var action: some View {
        if part.format == "midi" {
            // Rule 5: with no route to the renderer the button dims and says
            // why rather than vanishing, so a notes row keeps the same shape
            // as every other row in the group.
            Button("Render…") { onRenderNotes?() }
                .buttonStyle(.bench(.quiet))
                .disabled(onRenderNotes == nil)
                .opacity(onRenderNotes == nil ? 0.45 : 1)
                .help(onRenderNotes == nil
                      ? "Needs an installed model that can render notes"
                      : "Render these notes with the SoundFont — the audio "
                        + "lands back in Parts, ready to restyle or mix")
        } else if part.format == "wav" {
            Button("＋ Bench", action: onAddToWorkbench)
                .buttonStyle(.bench(.quiet))
                .help("Add this part to the Workbench")
        }
    }

    /// `Other (keys, synths, rest)` → `Other` + `keys, synths, rest`.
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

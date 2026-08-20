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

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var splittingSongIds: Set<String> = []
    /// Which origin the song list is showing; nil is "all of them", the tab
    /// this opens on so that nothing which used to be pickable disappears
    /// behind a filter the user never asked for.
    @State private var originTab: SongOrigin?

    private var songAccepted: Bool {
        accepts.contains { $0.matches("song.mix") }
    }

    private var allParts: [PartRecord] {
        let list = (try? parts.repository.parts(.init())) ?? []
        guard !query.isEmpty else { return list }
        return list.filter {
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

    private var songs: [SongRecord] {
        guard let originTab else { return matchingSongs }
        return matchingSongs.filter { $0.originKind == originTab }
    }

    /// `All 128 · Generated 96 · Imported 30 · Renders 2`. Origins with nothing
    /// in them still get a tab: a fixed strip you can learn beats one that
    /// reshuffles itself as the library fills up.
    private var originTabs: [BenchSegmented<SongOrigin?>.Option] {
        let all = matchingSongs
        var options: [BenchSegmented<SongOrigin?>.Option] = [
            .init(value: nil, label: "All", detail: "\(all.count)")
        ]
        for origin in SongOrigin.allCases {
            let count = all.filter { $0.originKind == origin }.count
            options.append(.init(value: origin, label: origin.title,
                                 detail: "\(count)"))
        }
        return options
    }

    private var splitModel: ModelInfo? {
        guard let autoDerive else { return nil }
        return catalog.models.first {
            $0.installState == .installed
                && $0.capabilities.supportedTasks.contains(autoDerive.splitTask)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
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
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    partsSection
                    songsSection
                    otherPartsSection
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
        .frame(width: 560, height: 520)
        .background(Bench.Palette.windowBackground)
        .preferredColorScheme(.dark)
    }

    // MARK: parts

    private var matchingParts: [PartRecord] {
        allParts.filter { part in accepts.contains { $0.matches(part.kind) } }
    }

    private var otherParts: [PartRecord] {
        allParts.filter { part in !accepts.contains { $0.matches(part.kind) } }
    }

    private func sourceTitle(_ part: PartRecord) -> String {
        ((try? library.repository.song(id: part.songId)) ?? nil)?.title
            ?? part.modelName
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
    private var songsSection: some View {
        if songAccepted || autoDerive != nil {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Text("SONGS").eyebrow()
                    Text((songAccepted ? "picked as the full mix"
                                       : (autoDerive?.note ?? "")).uppercased())
                        .metaLine()
                    Spacer(minLength: 8)
                    BenchSegmented(selection: $originTab, options: originTabs)
                }
                if songs.isEmpty {
                    Text(emptyTabMessage)
                        .font(Bench.Typo.small)
                        .foregroundStyle(Bench.Palette.textFaint)
                        .padding(.vertical, 10)
                }
                VStack(spacing: 6) {
                    ForEach(songs) { song in
                        // Only worth saying on the All tab. Inside a single
                        // origin's tab every row would carry the same word,
                        // which is the tab's own label repeated down the list.
                        let mark = originTab == nil ? song.originKind : nil
                        if songAccepted {
                            pickRow(PickedMaterial(song: song), origin: mark)
                        } else if autoDerive != nil {
                            HStack(spacing: 10) {
                                materialRow(PickedMaterial(song: song),
                                            origin: mark)
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
        let what = originTab.map { $0.title.lowercased() } ?? "songs"
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
            materialRow(material, origin: origin)
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

    private func materialRow(_ material: PickedMaterial,
                             origin: SongOrigin? = nil) -> some View {
        let isCurrent = playback.currentSongId == material.id
        let analysis = parts.analysis(for: material.id)
        return HStack(spacing: 11) {
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
            MaterialStrip(material: material,
                          playedFraction: isCurrent ? playback.playedFraction : 0,
                          height: 24)
            if let camelot = analysis?.camelot { BenchBadge(camelot) }
            if let bpm = analysis?.bpm {
                BenchBadge("\(Int(bpm.rounded())) BPM")
            }
        }
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

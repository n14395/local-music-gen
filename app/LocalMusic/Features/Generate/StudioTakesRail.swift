import SwiftUI

/// The takes rail beside the Simple composer.
///
/// The old screen listed recent results as two lines of text. The design's
/// argument is that you cannot compare music by reading it: every take gets its
/// own waveform, the one you are playing is lit, and the newest carries its
/// actions inline so "that one — again, but…" is one click. Older takes fade
/// rather than disappearing, which keeps the rail a history instead of a stack.
struct StudioTakesRail: View {
    let library: LibraryStore
    let playback: PlaybackController
    let catalog: ModelCatalogStore
    let actions: SongActions
    let onReuse: (SongRecord, ReuseScope) -> Void

    /// Only what this Studio made. `library.recent` is every recent row of any
    /// origin, so without the filter an album you imported this morning would
    /// sit in the takes rail between two of your own generations — and its
    /// card would offer to reuse a prompt it never had.
    private var generated: [SongRecord] {
        library.recent.filter { $0.originKind == .generated }
    }

    /// Enough to hold a full batch: a job may render up to `TAKES_MAX` takes,
    /// and a rail that showed half of them would hide takes the run you are
    /// watching just made. The rail scrolls, so this is a history window
    /// rather than a layout ceiling.
    private var takes: [SongRecord] { Array(generated.prefix(16)) }

    private var todayCount: Int {
        let start = Calendar.current.startOfDay(for: Date())
        return generated.filter { $0.createdAt >= start }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Takes")
                    .font(Bench.Typo.sectionTitle)
                    .foregroundStyle(Bench.Palette.textPrimary)
                if todayCount > 0 {
                    Text("\(todayCount) TODAY")
                        .font(Bench.Typo.mono(11))
                        .foregroundStyle(Bench.Palette.textFaintest)
                }
                Spacer()
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 12)

            if takes.isEmpty {
                VStack(spacing: 8) {
                    Text("Nothing yet")
                        .font(Bench.Typo.secondaryEmphasis)
                        .foregroundStyle(Bench.Palette.textQuaternary)
                    Text("Takes land here as they finish.")
                        .font(Bench.Typo.caption)
                        .foregroundStyle(Bench.Palette.textFaintest)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(Array(takes.enumerated()), id: \.element.id) { index, song in
                            TakeCard(song: song,
                                     modelName: catalog.models
                                        .first { $0.id == song.modelId }?.displayName
                                        ?? song.modelName,
                                     isCurrent: playback.currentSongId == song.id,
                                     isPlaying: playback.currentSongId == song.id
                                        && playback.isPlaying,
                                     isLead: index == 0,
                                     playedFraction: playback.currentSongId == song.id
                                        ? playback.playedFraction : 0,
                                     library: library, playback: playback,
                                     actions: actions,
                                     onPlay: { play(song) },
                                     onSeek: { seek(song, to: $0) },
                                     onReuse: { onReuse(song, $0) })
                                // The rail is a history: the further down, the
                                // quieter, bottoming out rather than vanishing.
                                .opacity(index >= 3 ? 0.62 : 1)
                        }
                    }
                    .padding(.horizontal, 16).padding(.bottom, 16)
                }
            }
        }
    }

    private func play(_ song: SongRecord) {
        playback.play(url: song.fileURL, songId: song.id, title: song.title,
                      duration: song.durationS,
                      subtitle: "\(song.modelName) · \(Int(song.durationS.rounded())) s")
    }

    /// Scrubbing a track that is not loaded must load it first, or the seek
    /// lands on whatever is currently playing.
    private func seek(_ song: SongRecord, to fraction: Double) {
        if playback.currentSongId != song.id { play(song) }
        playback.seek(to: fraction * song.durationS)
    }
}

private struct TakeCard: View {
    let song: SongRecord
    let modelName: String
    let isCurrent: Bool
    let isPlaying: Bool
    let isLead: Bool
    let playedFraction: Double
    let library: LibraryStore
    let playback: PlaybackController
    let actions: SongActions
    let onPlay: () -> Void
    let onSeek: (Double) -> Void
    let onReuse: (ReuseScope) -> Void

    @State private var showingDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 10) {
                BenchPlayButton(isPlaying: isPlaying, isCurrent: isCurrent,
                                size: 30, action: onPlay)
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title)
                        .font(isLead ? Bench.Typo.bodyEmphasis : Bench.Typo.body)
                        .foregroundStyle(Bench.Palette.textPrimary)
                        .lineLimit(1)
                    Text(metaLine)
                        .metaLine()
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Button { showingDetails = true } label: {
                    Text("···")
                        .font(.system(size: 15))
                        .foregroundStyle(Bench.Palette.textFaintest)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Details — rename, rate, tag, split…")
                .songDetailPopover(song: song, isPresented: $showingDetails,
                                   library: library, playback: playback,
                                   actions: actions)
            }

            BenchWaveformLoader(audioURL: song.fileURL,
                                cacheURL: song.waveformURL,
                                playedFraction: playedFraction,
                                tint: isCurrent ? Bench.Palette.accent
                                                : Bench.Palette.textQuaternary,
                                rest: Color.white.opacity(0.13),
                                onSeek: onSeek)
                .frame(height: isLead ? 46 : 38)

            if isLead {
                HStack(spacing: 8) {
                    RatingStars(rating: song.rating, size: 13, spacing: 2) { rating in
                        var updated = song
                        updated.rating = rating
                        library.update(updated)
                    }
                    Spacer()
                }
            }
            // Their own row rather than the stars' — three of them and a
            // rating do not fit across a 392 pt rail, and the reuse buttons
            // are what the card is for. They share the whole row instead of
            // huddling at its trailing edge: the rail has the width, and a
            // wider target is a better one.
            HStack(spacing: 8) {
                reuseButton(.prompt)
                reuseButton(.all)
                reuseButton(.allWithSeed)
            }
        }
        .padding(14)
        .benchCard(fill: isCurrent ? Bench.Palette.cardSelected : Bench.Palette.card,
                   stroke: isCurrent ? Bench.Palette.accent.opacity(0.28)
                                     : Bench.Palette.cardStrokeSoft)
    }

    /// A take rendered by a model with no seed of its own has nothing to pin,
    /// so "+ seed" dims and says why rather than repeating the other button.
    @ViewBuilder
    private func reuseButton(_ scope: ReuseScope) -> some View {
        let isEnabled = scope != .allWithSeed || song.seedUsed != nil
        Button { onReuse(scope) } label: {
            // `fixedSize` under `maxWidth: .infinity` is what keeps "Reuse
            // all + seed" on one line: the text holds its ideal width as the
            // button's floor, and only the slack left over is shared out. An
            // equal-thirds split would give it 116 pt and break it in two.
            Text(scope.shortTitle)
                .lineLimit(1)
                .fixedSize()
                .frame(maxWidth: .infinity)
        }
            .buttonStyle(.bench(.quiet))
            .disabled(!isEnabled)
            .opacity(isEnabled ? 1 : 0.45)
            .help(isEnabled ? scope.help
                : "This take was rendered by a model that has no seed")
    }

    private var metaLine: String {
        var parts = [modelName.uppercased()]
        parts.append(String(format: "%.1f S", song.durationS))
        parts.append(Self.stamp.string(from: song.createdAt).uppercased())
        return parts.joined(separator: " · ")
    }

    /// Today's takes get a clock; older ones get a date. The rail is mostly
    /// "the last hour", so a bare time is the useful reading.
    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}

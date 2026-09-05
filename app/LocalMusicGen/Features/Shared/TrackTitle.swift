import SwiftUI

/// A track's name followed by its prompt in a lighter style —
/// `track007 - warm lo-fi beat with vinyl crackle`.
///
/// Generated tracks are named `trackNNN`, so the prompt is what actually tells
/// them apart at a glance. The name is served first and the prompt takes
/// whatever width is left, so it is the prompt that truncates — until the name
/// alone outruns the row, and then it truncates too rather than spilling over
/// whatever shares the line.
struct TrackTitle: View {
    let title: String
    let prompt: String
    var font: Font = Bench.Typo.body
    var weight: Font.Weight?

    init(song: SongRecord, font: Font = Bench.Typo.body,
         weight: Font.Weight? = nil) {
        self.title = song.title
        self.prompt = song.prompt
        self.font = font
        self.weight = weight
    }

    init(title: String, prompt: String, font: Font = Bench.Typo.body,
         weight: Font.Weight? = nil) {
        self.title = title
        self.prompt = prompt
        self.font = font
        self.weight = weight
    }

    var body: some View {
        HStack(spacing: 0) {
            Text(title)
                .font(weight.map { font.weight($0) } ?? font)
                .foregroundStyle(Bench.Palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                // Priority, not `fixedSize`: the name is served first out of
                // the row's width, so a `trackNNN` still comes through whole
                // and the prompt beside it truncates — but a name longer than
                // the row itself now takes an ellipsis of its own instead of
                // running out over the waveform and the stars.
                .layoutPriority(keepsTitleWhole ? 1 : 0)
            if let promptSuffix {
                Text(promptSuffix)
                    .font(font)
                    .foregroundStyle(Bench.Palette.textQuaternary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    /// The name is served first only while the prompt trails it and can absorb
    /// the truncation. Alone, it has to yield like any other label — otherwise
    /// a long title with no prompt suffix squeezes whatever shares its row (the
    /// library's rating stars wrapped one per line, then vanished). Either way
    /// the name is bounded by the width it is offered: it truncates there
    /// rather than overflowing.
    var keepsTitleWhole: Bool { promptSuffix != nil }

    /// nil when the prompt would add nothing: imported and recombined tracks
    /// carry no prompt, and tracks generated before `trackNNN` naming were
    /// titled with the prompt itself — repeating it would just read as
    /// "warm lo-fi beat - warm lo-fi beat".
    var promptSuffix: String? {
        let prompt = self.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = self.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !title.isEmpty else { return nil }
        guard !prompt.hasPrefix(title), !title.hasPrefix(prompt) else { return nil }
        return " - " + prompt.replacingOccurrences(of: "\n", with: " ")
    }
}

/// How a track appears in every list, picker and selection: its name and
/// prompt on the first line, then heart, stars and model · length · when on
/// the second. Heart and stars appear only when set, so an unrated track reads
/// exactly as it did before.
///
/// The library's own rows are drawn by `LibrarySongRow` against the design's
/// row grammar; this is the compact form the pickers and the Studio's takes
/// list still use.
struct TrackRow: View {
    let song: SongRecord
    var titleFont: Font = Bench.Typo.body
    var titleWeight: Font.Weight?
    /// Origin marker (imported / recombined), shown before the name.
    var glyph: String?
    var glyphHelp: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                if let glyph {
                    Image(systemName: glyph)
                        .font(.system(size: 10))
                        .foregroundStyle(Bench.Palette.textMuted)
                        .help(glyphHelp ?? "")
                }
                TrackTitle(song: song, font: titleFont, weight: titleWeight)
            }
            HStack(spacing: 6) {
                if song.favorite {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(TrackRow.favouriteHeart)
                        .help("Favorite")
                }
                if song.rating > 0 {
                    // RatingStars carries the .lineLimit(1).fixedSize() that
                    // keeps the stars from being squeezed by the text beside
                    // them until they wrap one per line and disappear.
                    RatingStars(rating: song.rating, size: 9, spacing: 1)
                        .help("Rated \(song.rating) out of 5")
                }
                Text(TrackRow.metadata(for: song).uppercased())
                    .metaLine()
                    .lineLimit(1)
            }
        }
    }

    /// The design paints the favourite heart in the same pink it gives the
    /// vocals stem (`#FF8FA3`), so it is read from the palette rather than
    /// retyped as a literal.
    static let favouriteHeart = Bench.Palette.stem("vocals")

    /// "MusicGen Small · 10 s · 18 Aug 2026 at 14:03", or the artist in the
    /// model's place for an imported track.
    static func metadata(for song: SongRecord) -> String {
        [song.sourceLabel,
         "\(Int(song.durationS.rounded())) s",
         song.createdAt.formatted(date: .abbreviated, time: .shortened)]
            .joined(separator: " · ")
    }
}

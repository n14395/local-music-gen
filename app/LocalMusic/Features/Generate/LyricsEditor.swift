import SwiftUI

/// Lyrics input with per-model section-tag buttons and a usage hint, both
/// driven by the catalog (`capabilities.lyrics_tags` / `lyrics_hint`) — the app
/// keeps zero hardcoded per-model knowledge.
///
/// The tags are violet here and violet in the text, because that is the colour
/// this design gives to "a model decided this" — the section tags are the one
/// part of the lyric box that is structure rather than words. Syntax
/// highlighting inside the editor itself would need an `AttributedString`
/// binding, which is macOS 15; the palette carries the colour instead.
struct LyricsEditor: View {
    @Binding var lyrics: String
    let tags: [String]
    let hint: String?
    /// Fills its container in Studio's Full-control column; a fixed height in
    /// the narrower action sheets.
    var fills = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("LYRICS").eyebrow()
                Text("optional")
                    .font(Bench.Typo.caption)
                    .foregroundStyle(Bench.Palette.textFaintest)
                Spacer()
            }

            if !tags.isEmpty {
                FlowLayout(spacing: 5) {
                    ForEach(tags, id: \.self) { tag in
                        Button { insert(tag) } label: {
                            Text(tag)
                                .font(Bench.Typo.mono(11))
                                .foregroundStyle(Bench.Palette.violet)
                                .padding(.horizontal, 8).padding(.vertical, 6)
                                .background(RoundedRectangle(cornerRadius: 6)
                                    .fill(Bench.Palette.violet.opacity(0.12)))
                                .contentShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .help("Insert \(tag) as a new section")
                    }
                }
            }

            TextEditor(text: $lyrics)
                .font(Bench.Typo.mono(14))
                .lineSpacing(6)
                .scrollContentBackground(.hidden)
                .foregroundStyle(Bench.Palette.textSecondary)
                .frame(minHeight: fills ? 120 : 100,
                       maxHeight: fills ? .infinity : 100)

            if let hint {
                Text(hint)
                    .font(Bench.Typo.caption)
                    .foregroundStyle(Bench.Palette.textFaintest)
                    .padding(.top, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .top) {
                        Rectangle().fill(Bench.Palette.hairline).frame(height: 1)
                    }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: fills ? .infinity : nil,
               alignment: .leading)
        .benchCard(radius: 13)
    }

    /// Tags go on their own line at the end — lyrics are written top-down, so
    /// appending the next section is the natural flow.
    private func insert(_ tag: String) {
        var text = lyrics
        if !text.isEmpty && !text.hasSuffix("\n") {
            text += "\n"
        }
        if !text.isEmpty {
            text += "\n"  // blank line between sections
        }
        text += tag + "\n"
        lyrics = text
    }
}

// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Everything the viewer knows about one score, resolved once from the
/// database so the views never re-derive it.
struct NotationDocument: Equatable, Identifiable {
    /// The ABC document itself.
    let doc: TextDocRecord
    /// The header fields, parsed from the text — for the chrome only.
    let header: ABCHeader
    /// The MIDI part the same job produced, if it is still in the library.
    /// Linked by `jobId`, which is the only link the ingest leaves between a
    /// score and its notes — and it is enough: a transcription writes one
    /// `abc:<track>` document beside one `notes.<track>` part, and compose
    /// writes one of each.
    let notesPart: PartRecord?
    /// The title of the song the document sits on, for a score whose ABC
    /// carries no `T:` line.
    let songTitle: String

    var id: String { doc.id }

    /// Audio of those notes, if any: the part's own preview render.
    var previewURL: URL? { notesPart?.previewURL }

    /// What the sheet calls the score: the tune's own title when it has one,
    /// otherwise the track it was taken from.
    var title: String {
        if let title = header.title, !title.isEmpty { return title }
        return songTitle
    }

    /// Pick the notes for `doc` out of `parts` — the parts of the song the
    /// document sits on, already fetched by the host.
    ///
    /// The same job id wins; the format guard matters because a transcription
    /// also lands a `.preview.wav` *audio* part under the same job on some
    /// engines, and that one is not the notes. No job id — a document typed
    /// by hand — links to nothing.
    static func resolve(doc: TextDocRecord, parts: [PartRecord],
                        songTitle: String) -> NotationDocument {
        let notes = doc.jobId.flatMap { jobId in
            parts.first { $0.jobId == jobId && $0.format == "midi" }
        }
        return NotationDocument(doc: doc, header: ABCHeader.parse(doc.text),
                                notesPart: notes, songTitle: songTitle)
    }

    /// The document to open when a song has several: the most recent one.
    /// `TextStore` keeps its mirror newest-first per kind, but nothing here
    /// should depend on an ordering it does not own.
    static func newest(in docs: [TextDocRecord]) -> TextDocRecord? {
        docs.max { $0.createdAt < $1.createdAt }
    }
}

/// The ABC header fields worth a title bar.
///
/// ABC is line-oriented and its fields are one letter and a colon, so this is
/// a dozen lines of parsing — and it is *only* for the chrome. abcjs does the
/// real parse; if the two ever disagree, abcjs is right and this is a label.
struct ABCHeader: Equatable {
    var title: String?      // T:
    var key: String?        // K:
    var meter: String?      // M:
    var tempo: String?      // Q:
    /// Number of `X:` headers. abcjs renders every tune in the text, so the
    /// chrome can say "3 tunes" rather than pretending there is one.
    var tuneCount = 0

    static func parse(_ abc: String) -> ABCHeader {
        var header = ABCHeader()
        for rawLine in abc.split(omittingEmptySubsequences: false,
                                 whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // `%` opens a comment, and `%%` a directive; neither is a field.
            guard !line.hasPrefix("%") else { continue }
            guard line.count >= 2, line[line.index(after: line.startIndex)] == ":",
                  let letter = line.first, letter.isLetter else { continue }
            let value = Self.fieldValue(line.dropFirst(2))
            switch letter {
            case "X": header.tuneCount += 1
            case "T": if header.title == nil { header.title = value }
            case "K": if header.key == nil { header.key = value }
            case "M": if header.meter == nil { header.meter = value }
            case "Q": if header.tempo == nil { header.tempo = value }
            default: break
            }
        }
        return header
    }

    /// The field's text with a trailing `% comment` removed. A `%` inside
    /// quotes would be part of the value, but no header field this reads
    /// takes a quoted string except Q:, where the quote is a name and a `%`
    /// in it is vanishingly rare.
    private static func fieldValue(_ text: Substring) -> String? {
        let cut = text.split(separator: "%", maxSplits: 1,
                             omittingEmptySubsequences: false).first ?? ""
        let trimmed = cut.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Transposition

    /// The key `K:` names, moved by `semitones`, so the sheet's key line can
    /// agree with the key signature abcjs draws under `visualTranspose`.
    ///
    /// Spelling follows the circle of fifths rather than a sharps-only or
    /// flats-only table: +1 from D is Eb, not D#, and +1 from A minor is Bb
    /// minor, because those are the keys anyone would write. Modes other than
    /// minor keep their word and take the major spelling — close enough for a
    /// label, and abcjs, not this, decides the accidentals on the page.
    static func transposedKey(_ key: String, by semitones: Int) -> String {
        let trimmed = key.trimmingCharacters(in: .whitespaces)
        guard semitones % 12 != 0, let first = trimmed.first,
              let index = Self.noteIndex[first.uppercased()] else {
            return trimmed
        }
        var rest = trimmed.dropFirst()
        var pitch = index
        if let accidental = rest.first {
            if accidental == "#" || accidental == "^" {
                pitch += 1; rest = rest.dropFirst()
            } else if accidental == "b" || accidental == "_" {
                pitch -= 1; rest = rest.dropFirst()
            }
        }
        let mode = String(rest)
        let isMinor = Self.isMinorMode(mode)
        let moved = ((pitch + semitones) % 12 + 12) % 12
        let table = isMinor ? Self.minorNames : Self.majorNames
        return table[moved] + mode
    }

    private static let noteIndex: [String: Int] = [
        "C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11,
    ]
    private static let majorNames = [
        "C", "Db", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B",
    ]
    private static let minorNames = [
        "C", "C#", "D", "Eb", "E", "F", "F#", "G", "G#", "A", "Bb", "B",
    ]

    /// `m`, `min`, `minor`, `aeo`, `aeolian` — anything ABC treats as minor.
    /// `maj`, `mix` and the other modes start with the same letter and are
    /// not, which is why this looks past it.
    private static func isMinorMode(_ mode: String) -> Bool {
        let word = mode.trimmingCharacters(in: .whitespaces).lowercased()
            .prefix { $0.isLetter }
        if word.isEmpty { return false }
        if word.hasPrefix("maj") || word.hasPrefix("mix") { return false }
        return word.hasPrefix("m") || word.hasPrefix("aeo")
    }
}

// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import XCTest
@testable import LocalMusicGen

/// The notation viewer's pure parts: the header the chrome reads, the job-id
/// link between a score and its notes, the key line under transposition,
/// and the palette-to-CSS conversion. The engraving itself is WebKit and is
/// checked by hand — nothing here drives a `WKWebView`.
final class NotationDocumentTests: XCTestCase {

    // MARK: - Header

    func testHeaderFieldsAreRead() {
        let header = ABCHeader.parse("""
            X:1
            T:Cooley's
            M:4/4
            L:1/8
            Q:1/4=120
            K:Edor
            |:D2|EB{c}BA B2 EB|
            """)
        XCTAssertEqual(header.title, "Cooley's")
        XCTAssertEqual(header.key, "Edor")
        XCTAssertEqual(header.meter, "4/4")
        XCTAssertEqual(header.tempo, "1/4=120")
        XCTAssertEqual(header.tuneCount, 1)
    }

    func testAbsentFieldsAreNil() {
        let header = ABCHeader.parse("X:1\nK:C\nCDEF|")
        XCTAssertNil(header.title)
        XCTAssertNil(header.meter)
        XCTAssertNil(header.tempo)
        XCTAssertEqual(header.key, "C")
    }

    /// `%` opens a comment: a whole commented line is not a field, and a
    /// trailing comment is not part of the value.
    func testCommentsAreIgnored() {
        let header = ABCHeader.parse("""
            % T:Not the title
            %%score 1
            X:1
            T:Real title % said twice
            K:G
            """)
        XCTAssertEqual(header.title, "Real title")
        XCTAssertEqual(header.key, "G")
    }

    /// abcjs renders every tune in the text, so the chrome counts them.
    func testTwoTunesAreCounted() {
        let header = ABCHeader.parse("X:1\nT:One\nK:C\nC|\n\nX:2\nT:Two\nK:D\nD|")
        XCTAssertEqual(header.tuneCount, 2)
        // The first title names the document; the second is another tune's.
        XCTAssertEqual(header.title, "One")
    }

    func testMusicLinesAreNotFields() {
        // A bar starting with a letter and a colon — `A:` is a legitimate
        // field, but `|:` and note text are not, and neither may be misread.
        let header = ABCHeader.parse("X:1\nK:C\n|:CDEF|GABc:|")
        XCTAssertEqual(header.key, "C")
        XCTAssertNil(header.title)
    }

    // MARK: - Linking a score to its notes

    private func part(id: String, jobId: String?, format: String,
                      preview: String? = nil) -> PartRecord {
        PartRecord(id: id, songId: "song1", kind: "notes.piano", name: id,
                   fileName: id + "." + (format == "midi" ? "mid" : format),
                   format: format, previewFileName: preview,
                   modelId: "bp", modelName: "Basic Pitch", jobId: jobId,
                   splitParamsJSON: "{}", durationS: 12, sampleRate: nil,
                   createdAt: Date())
    }

    private func doc(jobId: String?, text: String = "X:1\nT:Tune\nK:C\nC|")
        -> TextDocRecord {
        TextDocRecord(id: "doc-" + (jobId ?? "hand"), ownerId: "song1",
                      ownerType: "song", kind: "abc", text: text,
                      segmentsJSON: nil, question: nil, language: nil,
                      modelId: "bp", modelName: "Basic Pitch", jobId: jobId,
                      edited: false, createdAt: Date(), updatedAt: Date())
    }

    func testNotesPartWithTheSameJobWins() {
        let resolved = NotationDocument.resolve(
            doc: doc(jobId: "job_7"),
            parts: [part(id: "other", jobId: "job_1", format: "midi"),
                    part(id: "mine", jobId: "job_7", format: "midi",
                         preview: "mine.preview.wav")],
            songTitle: "track042")
        XCTAssertEqual(resolved.notesPart?.id, "mine")
        XCTAssertEqual(resolved.previewURL?.lastPathComponent,
                       "mine.preview.wav")
    }

    /// The preview audio some engines land under the same job is a wav part;
    /// it is not the notes, and must not be picked as them.
    func testAnAudioPartWithTheSameJobIsNotTheNotes() {
        let resolved = NotationDocument.resolve(
            doc: doc(jobId: "job_7"),
            parts: [part(id: "audio", jobId: "job_7", format: "wav")],
            songTitle: "track042")
        XCTAssertNil(resolved.notesPart)
        XCTAssertNil(resolved.previewURL)
    }

    func testNoJobIdLinksToNothing() {
        let resolved = NotationDocument.resolve(
            doc: doc(jobId: nil),
            parts: [part(id: "mine", jobId: nil, format: "midi")],
            songTitle: "track042")
        XCTAssertNil(resolved.notesPart)
    }

    func testTitleFallsBackToTheSong() {
        let titled = NotationDocument.resolve(doc: doc(jobId: nil), parts: [],
                                              songTitle: "track042")
        XCTAssertEqual(titled.title, "Tune")
        let untitled = NotationDocument.resolve(
            doc: doc(jobId: nil, text: "X:1\nK:C\nC|"), parts: [],
            songTitle: "track042")
        XCTAssertEqual(untitled.title, "track042")
    }

    func testNewestDocumentWins() {
        var old = doc(jobId: "job_1")
        old.createdAt = Date(timeIntervalSince1970: 1_000)
        var new = doc(jobId: "job_2")
        new.createdAt = Date(timeIntervalSince1970: 2_000)
        XCTAssertEqual(NotationDocument.newest(in: [old, new])?.id, new.id)
        XCTAssertEqual(NotationDocument.newest(in: [new, old])?.id, new.id)
        XCTAssertNil(NotationDocument.newest(in: []))
    }

    // MARK: - Transposition

    /// The spelling follows the circle of fifths: sharps where a sharp key
    /// is what anyone would write, flats where a flat key is.
    func testTransposedKeysSpellTheCircleOfFifths() {
        XCTAssertEqual(ABCHeader.transposedKey("C", by: 2), "D")
        XCTAssertEqual(ABCHeader.transposedKey("G", by: 5), "C")
        XCTAssertEqual(ABCHeader.transposedKey("D", by: 1), "Eb")
        XCTAssertEqual(ABCHeader.transposedKey("D", by: 6), "Ab")
        XCTAssertEqual(ABCHeader.transposedKey("F#", by: 1), "G")
        XCTAssertEqual(ABCHeader.transposedKey("Bb", by: 1), "B")
        XCTAssertEqual(ABCHeader.transposedKey("Bb", by: -1), "A")
        XCTAssertEqual(ABCHeader.transposedKey("C", by: -1), "B")
    }

    func testMinorKeysKeepTheirMode() {
        XCTAssertEqual(ABCHeader.transposedKey("Am", by: -3), "F#m")
        XCTAssertEqual(ABCHeader.transposedKey("Am", by: 1), "Bbm")
        XCTAssertEqual(ABCHeader.transposedKey("Emin", by: 3), "Gmin")
        XCTAssertEqual(ABCHeader.transposedKey("Edor", by: 2), "F#dor")
        XCTAssertEqual(ABCHeader.transposedKey("Gmaj", by: 1), "Abmaj")
    }

    /// Twelve semitones is the same key; a key that is not a key stays as
    /// written rather than being mangled into one.
    func testWholeOctavesAndOddKeysAreLeftAlone() {
        XCTAssertEqual(ABCHeader.transposedKey("Em", by: 12), "Em")
        XCTAssertEqual(ABCHeader.transposedKey("Em", by: 0), "Em")
        XCTAssertEqual(ABCHeader.transposedKey("none", by: 3), "none")
        XCTAssertEqual(ABCHeader.transposedKey("HP", by: 3), "HP")
        XCTAssertEqual(ABCHeader.transposedKey("", by: 3), "")
    }

    // MARK: - Palette to CSS

    func testPaletteColoursRoundTripToHex() {
        XCTAssertEqual(NotationTheme.hex(Color(hex: 0xD8FF5A)), "#d8ff5a")
        XCTAssertEqual(NotationTheme.hex(Color(hex: 0x000000)), "#000000")
        XCTAssertEqual(NotationTheme.hex(Color(hex: 0xFFFFFF)), "#ffffff")
        // The page draws in the app's own text colour, not black.
        XCTAssertEqual(NotationTheme.bench.foreground,
                       NotationTheme.hex(Bench.Palette.textPrimary))
        XCTAssertNotEqual(NotationTheme.bench.foreground, "#000000")
    }

    /// The request is what crosses into the page as JSON; every field has to
    /// survive the trip, and equality is what stops a redraw storm.
    func testRequestsRoundTripThroughJSONAndCompare() throws {
        let request = NotationRequest(abc: "X:1\nK:C\n\"quoted\" C\\|",
                                      width: 344, scale: 0.8, transpose: -2,
                                      theme: .bench, background: nil)
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(NotationRequest.self, from: data)
        XCTAssertEqual(decoded, request)
        var moved = request
        moved.transpose = 0
        XCTAssertNotEqual(moved, request)
    }
}

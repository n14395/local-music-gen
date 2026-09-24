// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// What a part is called, and what kind of thing it is — two jobs that used to
/// be one field.
///
/// `PartRecord.name` held the separator's own label: `Vocals`, `Drums`,
/// `Other (keys, synths, rest)`. That is a *kind*, not a name. A library with
/// a dozen split songs in it showed a dozen rows called "Vocals", none of
/// which identified anything, while every song — generated, imported or
/// rendered — has carried a real name since v1.
///
/// So the two are separated. `name` becomes identity: `vocals-track042` —
/// what it is, then where it came from — unique across the parts library and
/// editable in the inspector, in the same identifier style as
/// `SongRecord.trackName(number:)`. The kind is derived
/// from the taxonomy rather than stored, by `label(kind:)`, for the places
/// that have already established which song they mean — the sibling chips, a
/// workbench lane, a Style Transfer stem chip — where the full name would
/// only be the heading read back out.
///
/// Pure and value-typed throughout, so the repository, the migration and the
/// rename cascade all quote one rule rather than three that agree today.
enum PartNaming {
    /// How much of the song's title a part's name carries.
    ///
    /// A prompt pasted into the Name field makes a legal title and a useless
    /// name — `vocals-a-lonely-trumpet-over-rain-slicked-neon-streets-at-…`
    /// fills every row it appears in. Cut here instead, where the cut can
    /// land on a word boundary.
    static let songSlugLimit = 40

    // MARK: kinds

    /// The last component of a dot-namespaced kind: `stem.vocals` → `vocals`.
    /// A kind with no dot is its own leaf; an empty one answers `part`, so
    /// callers never have to hold an empty string.
    static func leaf(kind: String) -> String {
        kind.split(separator: ".").last.map(String.init) ?? "part"
    }

    /// The first component: `stem.vocals` → `stem`.
    static func family(kind: String) -> String {
        kind.split(separator: ".").first.map(String.init) ?? "part"
    }

    /// `stem.vocals` → `Vocals`; `stem.other` → `Other (keys, synths, rest)`;
    /// `layer.lead-synth` → `Lead Synth`.
    ///
    /// "other" is separation jargon for the residual — everything the model
    /// could not name — so it is spelled out. (This is `JobsStore`'s old
    /// `partDisplayName`, moved here now that the label is derived on demand
    /// instead of being frozen into the row at split time.)
    static func label(kind: String) -> String {
        let leaf = leaf(kind: kind)
        guard leaf.lowercased() != "other" else {
            return "Other (keys, synths, rest)"
        }
        return leaf.replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }

    /// The dim half of a part's name in a list: what "Other" actually holds.
    /// nil for every kind that says what it is on its own.
    static func qualifier(kind: String) -> String? {
        leaf(kind: kind).lowercased() == "other" ? "keys, synths, rest" : nil
    }

    /// The half of a name that says what the part is — the half that leads it.
    ///
    /// A stem is the unmarked case — `vocals-track042` — because stems are
    /// most of what a parts library holds. Everything else carries its family,
    /// so a piano's MIDI notes and the audio rendered from them get two names
    /// rather than one name and a collision: `piano-notes-track042` beside
    /// `piano-layer-track042`.
    static func kindSegment(kind: String) -> String {
        let family = family(kind: kind)
        let leaf = leaf(kind: kind)
        if family == leaf { return slug(family) }
        if family == "stem" { return slug(leaf) }
        return slug(leaf) + "-" + slug(family)
    }

    // MARK: names

    /// `stem.vocals` + `track042` → `vocals-track042`.
    ///
    /// What it is leads, where it came from follows. The kind is the short,
    /// bounded half — a word from a fixed vocabulary — so putting it first
    /// means the part of the name that distinguishes a row from its
    /// neighbours is the part that survives a narrow column, and a long song
    /// title truncates from the end where it costs least.
    ///
    /// Not unique on its own: one song split twice by two separators has two
    /// parts with a fair claim to `vocals-track042`. `PartsRepository`
    /// resolves that, because only it can see the rest of the library.
    static func defaultName(songTitle: String, kind: String) -> String {
        let song = slug(songTitle, limit: songSlugLimit)
        let kind = kindSegment(kind: kind)
        if kind.isEmpty { return song.isEmpty ? "part" : song }
        if song.isEmpty { return kind }
        return kind + "-" + song
    }

    /// Lowercase, hyphen-joined, letters and numbers only.
    ///
    /// Deliberately not an ASCII fold: the point is a name a person reads in
    /// a list, so "Café Sessions" should stay `café-sessions` rather than
    /// become `caf-sessions`.
    static func slug(_ text: String, limit: Int = .max) -> String {
        var out = ""
        for character in text.lowercased() {
            if character.isLetter || character.isNumber {
                out.append(character)
            } else if !out.isEmpty, !out.hasSuffix("-") {
                out.append("-")
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        guard out.count > limit, limit > 0 else { return out }
        var cut = String(out.prefix(limit))
        // Cut on a word boundary when there is one late enough to leave a
        // recognisable name; a title chopped mid-word reads as a typo.
        if let hyphen = cut.lastIndex(of: "-"),
           cut.distance(from: cut.startIndex, to: hyphen) >= limit / 2 {
            cut = String(cut[..<hyphen])
        }
        while cut.hasSuffix("-") { cut.removeLast() }
        return cut
    }

    /// Whether `name` is still the one this type would have chosen — either
    /// exactly, or with the `-2`, `-3` a collision added.
    ///
    /// This is what makes "follow the song's rename, unless I named it myself"
    /// decidable without a second column to record who last wrote the name: a
    /// part the user has typed into stops matching, and stops being rewritten.
    ///
    /// It can be fooled, and the failure is the harmless direction: type
    /// `vocals-track042-5` by hand and the cascade will treat it as automatic
    /// and move it. Typing the exact name the machine would have picked is not
    /// a way of asking for it to stay behind.
    static func isDefault(_ name: String, songTitle: String,
                          kind: String) -> Bool {
        matches(name, base: defaultName(songTitle: songTitle, kind: kind))
    }

    /// `name` is `base`, or `base` with the `-2`, `-3` a collision added.
    private static func matches(_ name: String, base: String) -> Bool {
        let base = base.lowercased()
        let name = name.lowercased()
        if name == base { return true }
        guard name.hasPrefix(base + "-") else { return false }
        let tail = name.dropFirst(base.count + 1)
        return !tail.isEmpty && tail.allSatisfy(\.isNumber)
    }

    // MARK: - The order v7 used

    /// The name migration v7 gave a part: the song first, the kind last.
    ///
    /// Kept only so that v8 can recognise what it is replacing. A database
    /// that reached v7 has `track042-vocals` in it and will never run v7
    /// again — GRDB records migrations by name — so the reorder needs a
    /// migration of its own, and that migration needs to be able to tell
    /// v7's output from a name the user typed in between. Nothing else
    /// should call either of these.
    static func songFirstName(songTitle: String, kind: String) -> String {
        let song = slug(songTitle, limit: songSlugLimit)
        let kind = kindSegment(kind: kind)
        if song.isEmpty { return kind.isEmpty ? "part" : kind }
        if kind.isEmpty { return song }
        return song + "-" + kind
    }

    static func isSongFirst(_ name: String, songTitle: String,
                            kind: String) -> Bool {
        matches(name, base: songFirstName(songTitle: songTitle, kind: kind))
    }

    /// `name`, or the first `name-2`, `name-3`… that `isTaken` says is free.
    ///
    /// The suffix is a hyphen and a number rather than the ` (2)` a song's
    /// title takes (`LibraryRepository.uniqueTitle`). A part's name is an
    /// identifier — `vocals-track042` — and `vocals-track042 (2)` puts two
    /// conventions in one string.
    static func firstFree(_ name: String, isTaken: (String) -> Bool) -> String {
        guard isTaken(name) else { return name }
        var suffix = 2
        while suffix <= 9999 {
            let candidate = "\(name)-\(suffix)"
            if !isTaken(candidate) { return candidate }
            suffix += 1
        }
        // A library cannot hold this many collisions; the bound is here so a
        // bug upstream cannot spin forever.
        return "\(name)-\(UUID().uuidString.prefix(4))"
    }
}

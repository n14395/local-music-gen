import Foundation

/// What is ticked in the library, and what can honestly be done to all of it.
///
/// The tick boxes have been there since the A/B comparison, and until now that
/// was the only thing they were for: tick two rows, compare them, untick. But
/// "these ones" is the question a library is asked all day — delete these,
/// export these, heart these — and answering it one row at a time is the kind
/// of tedium a list is supposed to remove.
///
/// A value, computed from the ticked ids and the two stores, so the panel that
/// draws it holds no opinion of its own and the arithmetic here can be checked
/// without a window.
struct LibrarySelection: Equatable {
    var songs: [SongRecord] = []
    var parts: [PartRecord] = []

    /// Ticked rows the stores could not resolve — a row deleted in another
    /// pane, most often. Counted rather than ignored, because a panel saying
    /// "4 selected" over three files is worse than one that quietly says 3.
    var unresolved: Int = 0

    var count: Int { songs.count + parts.count }

    /// One row is not a selection — the single-row inspector is better at it
    /// in every way, since it can rename, rate, restyle and explain.
    var isMultiple: Bool { count > 1 }

    static func of(ids: Set<String>, songs allSongs: [SongRecord],
                   parts allParts: [PartRecord]) -> LibrarySelection {
        let songsById = Dictionary(allSongs.map { ($0.id, $0) },
                                   uniquingKeysWith: { first, _ in first })
        let partsById = Dictionary(allParts.map { ($0.id, $0) },
                                   uniquingKeysWith: { first, _ in first })
        var selection = LibrarySelection()
        // Sorted so the panel and the confirmation dialog list them in the
        // same order twice running, whatever order the set iterates in.
        for id in ids.sorted() {
            if let song = songsById[id] {
                selection.songs.append(song)
            } else if let part = partsById[id] {
                selection.parts.append(part)
            } else {
                selection.unresolved += 1
            }
        }
        return selection
    }

    /// `3 SONGS` · `2 PARTS` · `1 SONG · 2 PARTS`. Says which kinds are in
    /// hand, because the actions below differ by kind and a bare count would
    /// leave "Add to Workbench" looking like it had gone missing.
    var kindLine: String {
        var fields: [String] = []
        if !songs.isEmpty {
            fields.append("\(songs.count) SONG" + (songs.count == 1 ? "" : "S"))
        }
        if !parts.isEmpty {
            fields.append("\(parts.count) PART" + (parts.count == 1 ? "" : "S"))
        }
        return fields.joined(separator: " · ")
    }

    /// Total playing time, or nil when any of it is unknown.
    ///
    /// Nil rather than a partial sum: a part whose duration was never measured
    /// contributes nothing to an addition, so a total quietly missing one
    /// track looks exactly like a correct one.
    var durationS: Double? {
        var total = 0.0
        for song in songs { total += song.durationS }
        for part in parts {
            guard let duration = part.durationS else { return nil }
            total += duration
        }
        return total
    }

    /// Whether every one of them is already hearted. Drives the toggle's
    /// direction: "Remove from favourites" only once there is nothing left to
    /// add, so a mixed selection fills in rather than emptying out.
    var allFavourite: Bool {
        guard count > 0 else { return false }
        return songs.allSatisfy(\.favorite) && parts.allSatisfy(\.favorite)
    }

    /// The one rating they share, or nil when they disagree. The stars show it
    /// filled only when it is true of all of them.
    var sharedRating: Int? {
        let ratings = Set(songs.map(\.rating) + parts.map(\.rating))
        return ratings.count == 1 ? ratings.first : nil
    }

    /// Files on disk, for "Reveal in Finder" — which takes an array and
    /// selects the lot in one window.
    var fileURLs: [URL] { songs.map(\.fileURL) + parts.map(\.fileURL) }

    /// Every part in the selection can go on the bench; a song cannot go
    /// there as one thing, so a mixed selection does not offer it.
    var canAddToWorkbench: Bool { songs.isEmpty && !parts.isEmpty }

    /// A comparison is between two takes. More than two ticked is not a
    /// three-way comparison, it is a pair and some spectators — which is what
    /// the existing button already did quietly, and now says.
    var canCompare: Bool { songs.count >= 2 }
}

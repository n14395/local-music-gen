import Foundation

/// The arithmetic behind the menubar, kept out of the menus themselves.
///
/// Menu bodies are `some Commands` and cannot be instantiated in a test, so
/// everything a menu item *decides* lives here as a pure function and the item
/// is left holding only a title and a closure. What the menus needed deciding
/// was small but easy to get subtly wrong: which key opens which destination,
/// and — the one that actually bites — which track the Track menu is aimed at
/// when the Library has a song selected, a part selected, and the Editor is
/// open on a third thing.

extension Destination {
    /// The digit this destination answers to, 1-based, or nil past the ninth.
    ///
    /// Derived from `allCases` rather than written out, because `allCases`
    /// order *is* sidebar order — the declaration comments say so — and a
    /// hand-written table would be a second place for that order to live.
    var menuIndex: Int? {
        guard let offset = Self.allCases.firstIndex(of: self) else { return nil }
        let index = offset + 1
        return index <= 9 ? index : nil
    }

    /// The character `keyboardShortcut` wants for it.
    var menuKey: Character? {
        menuIndex.map { Character("\($0)") }
    }
}

extension LibraryScope {
    /// Same rule as `Destination.menuIndex`, on the ⌥⌘ range.
    var menuIndex: Int? {
        guard let offset = Self.allCases.firstIndex(of: self) else { return nil }
        let index = offset + 1
        return index <= 9 ? index : nil
    }

    var menuKey: Character? {
        menuIndex.map { Character("\($0)") }
    }
}

/// What the Track menu is pointed at.
///
/// Ids rather than records, because resolution happens against stores the
/// menu reads at click time — holding a `SongRecord` in a focused value would
/// be holding a copy that a rename or a rating in another pane has already
/// invalidated.
enum MenuTarget: Equatable {
    case song(id: String)
    case part(id: String)
    case none

    var isSong: Bool { if case .song = self { return true }; return false }
    var isPart: Bool { if case .part = self { return true }; return false }

    var id: String? {
        switch self {
        case .song(let id), .part(let id): id
        case .none: nil
        }
    }
}

enum ShellCommandRouting {
    /// Which track the Track menu acts on.
    ///
    /// The rule, in order:
    ///
    /// 1. **The Editor, when it is the screen you are on.** It holds exactly
    ///    one thing and that thing is in front of you, so a Track menu aimed
    ///    anywhere else while you are editing would be aimed at something you
    ///    cannot see.
    /// 2. **The Library's selection, of the kind the current scope lists.**
    ///    The two selections are kept separately and both survive a scope
    ///    switch — deliberately, so going Parts → Generated → Parts does not
    ///    lose your place — which means "the selected row" is only meaningful
    ///    once you say which list is showing.
    /// 3. **Nothing.** Every item dims. Note what this is *not*: a fallback to
    ///    whatever was selected last. A menu that acted on a row from a list
    ///    that is not on screen is worse than one that is greyed out.
    ///
    /// Deliberately independent of playback: the track that happens to be
    /// sounding is not the track you have picked, and using it would make
    /// Delete a coin toss.
    static func target(destination: Destination,
                       scope: LibraryScope,
                       selectedSongId: String?,
                       selectedPartId: String?,
                       editorMaterialId: String?,
                       editorMaterialIsPart: Bool) -> MenuTarget {
        if destination == .editor, let id = editorMaterialId {
            return editorMaterialIsPart ? .part(id: id) : .song(id: id)
        }
        guard destination == .library else { return .none }
        if scope == .parts {
            return selectedPartId.map { MenuTarget.part(id: $0) } ?? .none
        }
        return selectedSongId.map { MenuTarget.song(id: $0) } ?? .none
    }

    /// `Rate ★★★` and friends — the item titles, so the stars are built in one
    /// place rather than five call sites.
    static func ratingTitle(_ stars: Int) -> String {
        stars <= 0
            ? "No Rating"
            : String(repeating: "\u{2605}", count: stars)
    }

    /// What "Show/Hide Sidebar" should say next.
    ///
    /// Takes the *effective* state, not the preference: a window too narrow to
    /// hold the sidebar has it hidden whatever the preference says, and an
    /// item offering to hide something already gone is a lie the user will
    /// click once.
    static func sidebarItemTitle(isCollapsed: Bool) -> String {
        isCollapsed ? "Show Sidebar" : "Hide Sidebar"
    }

    static func queueItemTitle(isOpen: Bool) -> String {
        isOpen ? "Hide Queue" : "Show Queue"
    }

    /// What Track ▸ Copy Track Details puts on the pasteboard.
    ///
    /// Plain `KEY: value` lines rather than JSON: this is pasted into a note,
    /// a message or a bug report, and the fields that are unknown are left out
    /// entirely — a block half full of `nil` reads as a broken export rather
    /// than as a track nobody has analysed yet.
    static func details(song: SongRecord?, part: PartRecord?,
                        analysis: AnalysisRecord?) -> String? {
        var lines: [String] = []
        if let song {
            lines.append("Title: \(song.title)")
            lines.append("Source: \(song.sourceLabel)")
            lines.append("Origin: \(song.originKind.rawValue)")
            lines.append("Duration: " + duration(song.durationS))
            if !song.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty {
                lines.append("Prompt: \(song.prompt)")
            }
            if let seed = song.seedUsed { lines.append("Seed: \(seed)") }
            if song.rating > 0 { lines.append("Rating: \(song.rating)/5") }
            lines.append("File: \(song.fileName)")
        } else if let part {
            lines.append("Part: \(part.name)")
            lines.append("Kind: \(part.kind)")
            lines.append("Source: \(part.modelName)")
            if let seconds = part.durationS {
                lines.append("Duration: " + duration(seconds))
            }
            if part.rating > 0 { lines.append("Rating: \(part.rating)/5") }
            lines.append("File: \(part.fileName)")
        } else {
            return nil
        }
        if let bpm = analysis?.bpm {
            lines.append("Tempo: \(Int(bpm.rounded())) BPM")
        }
        if let camelot = analysis?.camelot {
            let key = analysis?.keyName.map { "\($0) (\(camelot))" } ?? camelot
            lines.append("Key: \(key)")
        }
        return lines.joined(separator: "\n")
    }

    /// `3:07`. Minutes and seconds, because that is how the app writes a
    /// length everywhere else it prints one.
    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

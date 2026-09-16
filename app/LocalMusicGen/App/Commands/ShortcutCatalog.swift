import SwiftUI

/// Every key the menubar claims, in one table.
///
/// This is the *source*, not a description of one: each menu item takes its
/// `KeyboardShortcut` from an entry here, and Help ▸ Keyboard Shortcuts draws
/// the same entries. That is the whole reason the reference sheet was worth
/// building this time — a second hand-written list of forty bindings would
/// have started drifting from the menus the first time one moved, which is
/// exactly why it was declined when the menubar was first filled out.
///
/// What the table cannot own is the shortcuts macOS installs itself (Undo,
/// Cut, ⌘W, Full Screen) and the two the Editor binds view-locally. Those are
/// carried as `reference` entries: shown in the sheet, owned elsewhere, and
/// marked so nobody goes looking for the menu item that declares them.
struct MenuShortcut: Identifiable {
    var title: String
    var key: KeyEquivalent
    var modifiers: EventModifiers
    /// When the key only works somewhere in particular — "in the Editor",
    /// "while comparing". Drawn beside the row in the sheet.
    var note: String?

    init(_ title: String, _ key: KeyEquivalent, _ modifiers: EventModifiers,
         note: String? = nil) {
        self.title = title
        self.key = key
        self.modifiers = modifiers
        self.note = note
    }

    var id: String { "\(display)|\(title)" }

    var shortcut: KeyboardShortcut { KeyboardShortcut(key, modifiers: modifiers) }

    /// `⌃⌘←`, `⇧⌘E`. Modifiers in the order macOS prints them, which is not
    /// the order `EventModifiers` declares them in.
    var display: String {
        var out = ""
        if modifiers.contains(.control) { out += "\u{2303}" }
        if modifiers.contains(.option) { out += "\u{2325}" }
        if modifiers.contains(.shift) { out += "\u{21E7}" }
        if modifiers.contains(.command) { out += "\u{2318}" }
        return out + Self.glyph(key)
    }

    /// What a key equivalent looks like on a menu. The arrows, Return and
    /// Delete arrive as private-use or control characters, and printing those
    /// raw would put replacement boxes in the sheet.
    static func glyph(_ key: KeyEquivalent) -> String {
        switch key.character {
        case " ": return "Space"
        case "\r": return "\u{23CE}"
        case "\u{8}", "\u{7F}": return "\u{232B}"
        case "\t": return "\u{21E5}"
        case "\u{1B}": return "esc"
        case "\u{F700}": return "\u{2191}"
        case "\u{F701}": return "\u{2193}"
        case "\u{F702}": return "\u{2190}"
        case "\u{F703}": return "\u{2192}"
        default: return String(key.character).uppercased()
        }
    }
}

/// One line of the reference sheet: a title, the keys, and where it applies.
///
/// Built from a `MenuShortcut` for everything the menubar owns, and by hand
/// for the ranges (⌘1–⌘7) and the keys the system or a screen owns — a range
/// is one line in the sheet and seven items in the menu, so it cannot be a
/// single `MenuShortcut`.
struct ShortcutLine: Identifiable {
    var title: String
    var keys: String
    var note: String?

    var id: String { "\(keys)|\(title)" }

    init(_ shortcut: MenuShortcut) {
        self.title = shortcut.title
        self.keys = shortcut.display
        self.note = shortcut.note
    }

    init(_ title: String, _ keys: String, note: String? = nil) {
        self.title = title
        self.keys = keys
        self.note = note
    }
}

struct ShortcutSection: Identifiable {
    var title: String
    var lines: [ShortcutLine]
    var id: String { title }
}

enum ShortcutCatalog {

    // MARK: - File

    static let importAudio = MenuShortcut("Import Audio\u{2026}", "o", .command)
    static let importFolder = MenuShortcut("Import Folder\u{2026}", "o",
                                           [.command, .control])
    static let addModel = MenuShortcut("Add Model from Hugging Face\u{2026}",
                                       "o", [.command, .shift])
    static let export = MenuShortcut("Export\u{2026}", "e", [.command, .shift])
    static let exportSelected = MenuShortcut("Export Selected Tracks\u{2026}",
                                             "e", [.command, .option])
    static let reveal = MenuShortcut("Reveal in Finder", "r",
                                     [.command, .shift])
    /// ⇧⌘⌫, not the Finder's ⌘⌫.
    ///
    /// ⌘⌫ is a *standard text-editing binding* — AppKit's
    /// `StandardKeyBinding.dict` maps it to `deleteToBeginningOfLine:` — and a
    /// menu key equivalent is resolved by `NSApplication` before the event ever
    /// reaches the field editor, so the menu wins. This item is enabled exactly
    /// when a Library row is picked, which is exactly when the Title field and
    /// the notes editor are on screen: clearing a line while renaming a track
    /// raised "Delete "<title>"?" over the field, and with confirmations turned
    /// off in Settings it deleted the track and its audio file outright.
    /// ⇧⌘⌫ appears nowhere in that table, so the field editor keeps its keys.
    static let delete = MenuShortcut("Delete\u{2026}", .delete,
                                     [.command, .shift])
    static let closeEditor = MenuShortcut("Close Editor", "w",
                                          [.command, .shift])

    // MARK: - Edit

    static let find = MenuShortcut("Find", "f", .command)
    static let selectAllRows = MenuShortcut("Select All Rows", "a",
                                            [.command, .control],
                                            note: "Library")
    static let clearSelection = MenuShortcut("Clear Selection", "d",
                                             [.command, .shift],
                                             note: "Library")

    // MARK: - View

    static let toggleSidebar = MenuShortcut("Show/Hide Sidebar", "s",
                                            [.command, .control])
    static let toggleQueue = MenuShortcut("Show/Hide Queue", "q",
                                          [.command, .option])
    static let zoomIn = MenuShortcut("Zoom In", "+", .command)
    static let zoomOut = MenuShortcut("Zoom Out", "-", .command)
    static let zoomToFit = MenuShortcut("Zoom to Fit", "0", .command)
    static let zoomToSelection = MenuShortcut("Zoom to Selection", "0",
                                              [.command, .option])
    static let backToGallery = MenuShortcut("Back to Actions Gallery", "[",
                                            .command)

    // MARK: - Playback

    static let playPause = MenuShortcut("Play / Pause", .space, .control)
    static let stop = MenuShortcut("Stop", ".", .control)
    static let skipBack = MenuShortcut("Skip Back 5 Seconds", .leftArrow,
                                       [.command, .control])
    static let skipForward = MenuShortcut("Skip Forward 5 Seconds",
                                          .rightArrow, [.command, .control])
    static let goToStart = MenuShortcut("Go to Start", .upArrow,
                                        [.command, .control])
    static let goToEnd = MenuShortcut("Go to End", .downArrow,
                                      [.command, .control])
    static let playSelection = MenuShortcut("Play Selection", .space, .option,
                                            note: "in the Editor")
    static let loopSelection = MenuShortcut("Loop Selection", "l",
                                            [.command, .control],
                                            note: "in the Editor")
    static let volumeUp = MenuShortcut("Volume Up", .upArrow,
                                       [.command, .option])
    static let volumeDown = MenuShortcut("Volume Down", .downArrow,
                                         [.command, .option])
    static let mute = MenuShortcut("Mute", "m", [.command, .option])
    static let showNowPlaying = MenuShortcut("Show Now Playing in Library",
                                             "n", [.command, .shift])
    static let compare = MenuShortcut("Start / Stop A/B Compare", "a",
                                      [.command, .shift])
    static let switchSide = MenuShortcut("Switch A/B Side", .tab, .option,
                                         note: "while comparing")

    // MARK: - Track

    static let editInEditor = MenuShortcut("Edit in Editor\u{2026}", "e",
                                           .command)
    static let favourite = MenuShortcut("Add to / Remove from Favourites",
                                        "l", [.command, .shift])
    static let copyPrompt = MenuShortcut("Copy Prompt", "p",
                                         [.command, .option])

    // MARK: - Audio

    static let trim = MenuShortcut("Trim to Selection", "t",
                                   [.command, .option])
    static let splitAtPlayhead = MenuShortcut("Split at Playhead", "s",
                                              [.command, .option])
    static let insertGap = MenuShortcut("Insert Gap at Playhead", "g",
                                        [.command, .option])

    // MARK: - Render

    static let run = MenuShortcut("Generate / Apply / Create Mix", .return,
                                  .command)
    static let reimagine = MenuShortcut("Reimagine", .return,
                                        [.command, .option])
    static let cancelRender = MenuShortcut("Cancel Current Render", ".",
                                           .command)
    static let cancelAllRenders = MenuShortcut("Cancel All Renders", ".",
                                               [.command, .shift])
    static let refreshCatalog = MenuShortcut("Refresh Model Catalog", "r",
                                             .command)

    // MARK: - Help

    static let shortcuts = MenuShortcut("Keyboard Shortcuts", "/", .command)

    // MARK: - Everything, for the sheet

    /// The whole reference, in menubar order.
    ///
    /// Ranges and system keys are written as lines rather than derived,
    /// because neither is a single binding this table installs: ⌘1–⌘7 is seven
    /// items built from `Destination.menuKey`, and ⌘Z belongs to AppKit.
    static var sections: [ShortcutSection] {
        [
            ShortcutSection(title: "File", lines: [
                ShortcutLine(importAudio), ShortcutLine(importFolder),
                ShortcutLine(addModel), ShortcutLine(export),
                ShortcutLine(exportSelected), ShortcutLine(reveal),
                ShortcutLine(delete), ShortcutLine(closeEditor),
                ShortcutLine("Close Window", "\u{2318}W", note: "system"),
            ]),
            ShortcutSection(title: "Edit", lines: [
                ShortcutLine(find), ShortcutLine(selectAllRows),
                ShortcutLine(clearSelection),
                ShortcutLine("Undo / Redo", "\u{2318}Z  \u{21E7}\u{2318}Z",
                             note: "system"),
                ShortcutLine("Cut / Copy / Paste",
                             "\u{2318}X  \u{2318}C  \u{2318}V",
                             note: "system"),
                ShortcutLine("Select All", "\u{2318}A", note: "system"),
            ]),
            ShortcutSection(title: "View", lines: [
                ShortcutLine("Go to a destination",
                             "\u{2318}1 \u{2013} \u{2318}7",
                             note: "sidebar order"),
                ShortcutLine("Go to a Library scope",
                             "\u{2325}\u{2318}1 \u{2013} \u{2325}\u{2318}6"),
                ShortcutLine(toggleSidebar), ShortcutLine(toggleQueue),
                ShortcutLine(zoomIn), ShortcutLine(zoomOut),
                ShortcutLine(zoomToFit), ShortcutLine(zoomToSelection),
                ShortcutLine(backToGallery),
                ShortcutLine("Enter Full Screen", "\u{2303}\u{2318}F",
                             note: "system"),
            ]),
            ShortcutSection(title: "Playback", lines: [
                ShortcutLine(playPause), ShortcutLine(stop),
                ShortcutLine(skipBack), ShortcutLine(skipForward),
                ShortcutLine(goToStart), ShortcutLine(goToEnd),
                ShortcutLine(playSelection), ShortcutLine(loopSelection),
                ShortcutLine(volumeUp), ShortcutLine(volumeDown),
                ShortcutLine(mute), ShortcutLine(showNowPlaying),
                ShortcutLine(compare), ShortcutLine(switchSide),
            ]),
            ShortcutSection(title: "Track", lines: [
                ShortcutLine(editInEditor), ShortcutLine(favourite),
                ShortcutLine("Rate the picked track",
                             "\u{2303}\u{2318}1 \u{2013} \u{2303}\u{2318}5",
                             note: "\u{2303}\u{2318}0 clears it"),
                ShortcutLine(copyPrompt),
            ]),
            ShortcutSection(title: "Audio", lines: [
                ShortcutLine(trim), ShortcutLine(splitAtPlayhead),
                ShortcutLine(insertGap),
            ]),
            ShortcutSection(title: "Render", lines: [
                ShortcutLine(run), ShortcutLine(reimagine),
                ShortcutLine(cancelRender), ShortcutLine(cancelAllRenders),
                ShortcutLine(refreshCatalog),
            ]),
            ShortcutSection(title: "App", lines: [
                ShortcutLine("Settings", "\u{2318},"),
                ShortcutLine(shortcuts),
                ShortcutLine("Hide / Quit", "\u{2318}H  \u{2318}Q",
                             note: "system"),
            ]),
            ShortcutSection(title: "On the screen itself", lines: [
                ShortcutLine("Play / pause the Editor", "Space",
                             note: "not a menu item, so it stays out of "
                                 + "every text field"),
                ShortcutLine("Delete the Editor's selection", "\u{232B}"),
                ShortcutLine("Leave an Actions page", "esc"),
                ShortcutLine("Drop a part at the playhead",
                             "\u{2325}-drag", note: "Workbench"),
            ]),
        ]
    }

    /// Every binding the menubar itself installs — the ranges and the system
    /// and view-local keys excluded, since this is what the app claims.
    ///
    /// Exists for the test that no two of them collide, which is the failure
    /// this table was built to make impossible: two menus claiming one key is
    /// silent at runtime, and whichever loads last wins.
    static var installed: [MenuShortcut] {
        [importAudio, importFolder, addModel, export, exportSelected, reveal,
         delete, closeEditor, find, selectAllRows, clearSelection,
         toggleSidebar, toggleQueue, zoomIn, zoomOut, zoomToFit,
         zoomToSelection, backToGallery, playPause, stop, skipBack,
         skipForward, goToStart, goToEnd, playSelection, loopSelection,
         volumeUp, volumeDown, mute, showNowPlaying, compare, switchSide,
         editInEditor, favourite, copyPrompt, trim, splitAtPlayhead,
         insertGap, run, reimagine, cancelRender, cancelAllRenders,
         refreshCatalog, shortcuts]
    }
}

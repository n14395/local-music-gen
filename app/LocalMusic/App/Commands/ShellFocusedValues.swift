import AppKit
import SwiftUI

/// What the screen currently on show lets the menubar do to it.
///
/// Menu commands are declared on the scene and so know nothing about which of
/// the seven destinations is up. The three values here are how a screen says
/// "these items are mine now": it publishes one with `focusedSceneValue`, the
/// matching menu item reads it, and every screen that publishes nothing leaves
/// those items correctly dimmed rather than silently dead.
///
/// Scene-scoped rather than view-scoped (`focusedSceneValue`, not
/// `focusedValue`): these belong to the window, not to whichever text field
/// happens to hold the keyboard. Typing in the prompt box must not take Cut
/// and Copy away from the Editor's waveform — nor give the Editor's Cut to the
/// text field, which is why `EditorCommands` is published only while the
/// Editor is the destination on screen.

// MARK: - Editor

/// The Editor's clipboard, selection and zoom, lifted where the menubar can
/// reach them.
///
/// A bundle rather than one focused value each: they arrive and leave
/// together — the Editor either has material open or it does not — and eleven
/// separate keys would be eleven separate chances for one to go stale.
struct EditorCommands {
    /// False while the Editor is applying a render, or while another track's
    /// apply has it frozen. Every item below dims together, because the
    /// document is not editable at all in that state.
    var isEditable: Bool = false
    /// Whether there is a selection to act on — Cut, Copy and Delete need one.
    var hasSelection: Bool = false
    var canPaste: Bool = false

    var cut: () -> Void = {}
    var copy: () -> Void = {}
    var paste: () -> Void = {}
    var delete: () -> Void = {}
    var selectAll: () -> Void = {}

    var zoomIn: () -> Void = {}
    var zoomOut: () -> Void = {}
    var zoomToFit: () -> Void = {}
    var zoomToSelection: () -> Void = {}

    /// Audition the untouched source instead of the edited program.
    var toggleOriginal: () -> Void = {}
    var isAuditioningOriginal: Bool = false
    /// Play just what is selected — the Editor's ⌥Space, promoted to an item.
    var playSelection: () -> Void = {}

    /// Save a copy of the selection (or the whole edited file) to disk.
    var export: () -> Void = {}
    /// Show the file the Editor is working on in Finder.
    var reveal: (() -> Void)?
}

extension EditorCommands {
    /// The bundle, read straight from the store — which is where every fact in
    /// it already lives.
    ///
    /// One initialiser because there are two callers and they must agree: the
    /// Editor publishes it as a focused value for the menus that only exist
    /// while that screen is up, and `AppDelegate` builds it again when a stock
    /// Edit-menu item comes down the responder chain with nothing else to
    /// service it. Two hand-written copies of "is there a selection" would be
    /// two chances for the menu to offer a cut the screen cannot make.
    @MainActor
    init(store: EditorStore) {
        self.init(
            isEditable: store.isCommandable,
            hasSelection: (store.selection?.length ?? 0) > 0,
            canPaste: store.canPaste,
            cut: { store.cutSelection() },
            copy: { store.copySelection() },
            paste: { store.paste() },
            delete: { store.deleteSelection() },
            selectAll: { store.selectAll() },
            zoomIn: { store.zoomIn() },
            zoomOut: { store.zoomOut() },
            zoomToFit: { store.zoomToFit() },
            zoomToSelection: { store.zoomToSelection() },
            toggleOriginal: { store.toggleOriginalAudition() },
            isAuditioningOriginal: store.auditioningOriginal,
            playSelection: { store.playSelection() },
            export: { store.exportSheetOpen = true },
            // Nil, not a closure that does nothing, when there is no file yet
            // — the File menu dims Reveal on exactly this.
            reveal: store.sourceURL.map { url in
                { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            })
    }
}

private struct EditorCommandsKey: FocusedValueKey {
    typealias Value = EditorCommands
}

// MARK: - Search

/// "This screen has a search field, and here is how to put the caret in it."
///
/// One menu item replaces the four hidden `Button("")`s that used to claim ⌘F
/// on the Library, Models, the Actions gallery and Settings — none of which
/// appeared anywhere a user could find them.
struct SearchCommand {
    /// What the field is called, so the item can read "Find in Library" rather
    /// than a bare "Find" that says nothing about where it will land.
    var scope: String
    var focus: () -> Void
}

private struct SearchCommandKey: FocusedValueKey {
    typealias Value = SearchCommand
}

// MARK: - The primary action

/// The one thing ⌘↩ does on the screen you are looking at: Generate on the
/// composer, Apply Edits in the Editor.
///
/// Both keep the binding they already had — this only makes the item visible
/// and correctly titled, and stops the two hidden buttons from having to be
/// the sole record of a shortcut the app relies on.
struct RunCommand {
    /// The menu item's title — "Generate 4 takes", "Apply 3 edits". Written by
    /// the screen because only it knows the count.
    var title: String
    var isEnabled: Bool
    var run: () -> Void
}

private struct RunCommandKey: FocusedValueKey {
    typealias Value = RunCommand
}

extension FocusedValues {
    var editorCommands: EditorCommands? {
        get { self[EditorCommandsKey.self] }
        set { self[EditorCommandsKey.self] = newValue }
    }

    var searchCommand: SearchCommand? {
        get { self[SearchCommandKey.self] }
        set { self[SearchCommandKey.self] = newValue }
    }

    var runCommand: RunCommand? {
        get { self[RunCommandKey.self] }
        set { self[RunCommandKey.self] = newValue }
    }
}

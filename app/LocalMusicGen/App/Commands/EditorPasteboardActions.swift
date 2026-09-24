// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

/// Cut, Copy, Paste, Delete and Select All, routed the way macOS routes them.
///
/// These five used to be SwiftUI items wired straight to the Editor's
/// waveform, installed with `CommandGroup(replacing: .pasteboard)`. That took
/// ⌘X/⌘C/⌘V/⌘A away from every text field in the app: AppKit has no key
/// bindings for those four — the *menu items* are the whole mechanism, and
/// they work because their action is sent to the first responder, which for a
/// field being edited is the field editor. Replace the group and a prompt box
/// gets ⌘V handed to a menu item that was disabled because the Editor was not
/// on screen, with nothing else listening.
///
/// So the stock items are back, and the Editor is served the way any AppKit
/// document is: from the responder chain. A focused text control answers first
/// and keeps its keys; when nothing in the window answers, the chain ends at
/// the application's delegate, and these methods hand the action to the
/// Editor. `validateMenuItem` does the dimming — AppKit asks at menu-open and
/// key-equivalent time, so unlike a SwiftUI `disabled` fed from a global the
/// answer is never stale.
extension AppDelegate: NSMenuItemValidation {
    /// The Editor's clipboard, or nil when it is not the screen being looked
    /// at.
    ///
    /// Gated as the focused value was — on the Editor being the destination —
    /// plus the main window being frontmost, so a ⌘V typed at the Settings
    /// window with nothing text-like focused cannot land in a waveform.
    @MainActor
    private var editorClipboard: EditorCommands? {
        guard ShellWindow.isFrontmost, env.shell.destination == .editor,
              env.editor.isCommandable else { return nil }
        return EditorCommands(store: env.editor)
    }

    @MainActor @objc func cut(_ sender: Any?) { editorClipboard?.cut() }
    @MainActor @objc func copy(_ sender: Any?) { editorClipboard?.copy() }
    @MainActor @objc func paste(_ sender: Any?) { editorClipboard?.paste() }
    @MainActor @objc func delete(_ sender: Any?) { editorClipboard?.delete() }
    @MainActor @objc func selectAll(_ sender: Any?) {
        editorClipboard?.selectAll()
    }

    /// Only asked about items that resolved to *this* target — i.e. the five
    /// above, and only once every responder ahead of the delegate has declined
    /// them. Anything else the app delegate is ever asked about is not ours to
    /// dim, so it stays enabled.
    @MainActor
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let action = menuItem.action,
              Self.pasteboardActions.contains(action) else { return true }
        guard let clipboard = editorClipboard else { return false }
        switch action {
        case #selector(paste(_:)): return clipboard.canPaste
        case #selector(selectAll(_:)): return true
        // Cut, Copy and Delete: a span of audio has to be picked first.
        default: return clipboard.hasSelection
        }
    }

    private static let pasteboardActions: Set<Selector> = [
        #selector(cut(_:)), #selector(copy(_:)), #selector(paste(_:)),
        #selector(delete(_:)), #selector(selectAll(_:)),
    ]
}

extension EditorStore {
    /// An apply is running on *this* material — the document is frozen while
    /// it lands.
    var applyIsFrozen: Bool { currentApplyStage.isBusy }

    /// A render is running somewhere — possibly for a track that is not open.
    /// Only one runs at a time, so Apply and Revert wait for it wherever they
    /// are offered.
    var blockedByAnotherRender: Bool {
        isRenderingAnything && !applyBelongsToCurrentMaterial
    }

    /// There is a file open and nothing is rendering: the menubar may act on
    /// it. Every clipboard, zoom and transport item dims together on this,
    /// because in the other states the document is not editable at all.
    var isCommandable: Bool {
        material != nil && !applyIsFrozen && !blockedByAnotherRender
    }
}

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

// MARK: - The Editor's operations

/// Everything the Audio menu does — the twenty-odd operations that were
/// toolbar buttons, rail sliders and one `···` overflow, and had no menubar
/// presence at all.
///
/// A value bundle rather than the store itself, following `EditorCommands`:
/// a menu that read `EditorStore.document` directly would be subscribed to
/// every frame of a speed drag, and the `Commands` doctrine is that a menu
/// reads cold state in its body and live state in its closures. The screen
/// already redraws on these values, so publishing them costs nothing new.
struct EditorAudioCommands {
    /// The one gate every item shares: a file is open and nothing is
    /// rendering it.
    var isEditable = false
    var hasSelection = false
    /// Whether there is a program to clear or send onward.
    var isDirty = false

    // Settings the menu draws checkmarks from.
    var snapMode: EditorGeometry.SnapMode = .beats
    var crossfadeJoins = false
    var isNormalized = false
    var speedRate: Double = 1
    var pitchSemitones: Double = 0
    var resampleHz: Int?
    var amplifyDb: Double = 0
    var hasEffects = false
    var allEffectsEnabled = false
    var showBeatGrid = false
    var stereoView = false
    var loopSelection = false

    // Selection surgery.
    var trim: () -> Void = {}
    var silence: () -> Void = {}
    var deleteSelection: () -> Void = {}
    var insertGap: () -> Void = {}
    var splitAtPlayhead: () -> Void = {}
    var reverse: () -> Void = {}
    var autoTrim: (Double) -> Void = { _ in }
    var snapToSection: () -> Void = {}
    var refineToZeroCrossings: () -> Void = {}
    var setSnapMode: (EditorGeometry.SnapMode) -> Void = { _ in }

    // Levels and shape.
    var fadeIn: () -> Void = {}
    var fadeOut: () -> Void = {}
    var setNormalized: (Bool) -> Void = { _ in }
    var amplify: (Double) -> Void = { _ in }
    var setSpeed: (Double) -> Void = { _ in }
    var setPitch: (Double) -> Void = { _ in }
    var setResample: (Int?) -> Void = { _ in }
    var addEffect: (EffectSetting.Kind) -> Void = { _ in }
    var setAllEffects: (Bool) -> Void = { _ in }
    var setCrossfadeJoins: (Bool) -> Void = { _ in }
    var clearAllEdits: () -> Void = {}

    // Where a selection can be sent.
    var send: (EditorStore.SnippetIntent) -> Void = { _ in }

    // View toggles that belong to the waveform rather than to the window.
    var setBeatGrid: (Bool) -> Void = { _ in }
    var setStereoView: (Bool) -> Void = { _ in }
    var setLoopSelection: (Bool) -> Void = { _ in }
}

extension EditorAudioCommands {
    @MainActor
    init(store: EditorStore) {
        self.init(
            isEditable: store.isCommandable,
            hasSelection: (store.selection?.length ?? 0) > 0,
            isDirty: store.isDirty,
            snapMode: store.snapMode,
            crossfadeJoins: store.crossfadeJoins,
            isNormalized: store.document.normalizeLufs != nil,
            speedRate: store.document.speedRate,
            pitchSemitones: store.document.pitchSemitones,
            resampleHz: store.document.resampleHz,
            amplifyDb: store.amplifyDbForSelection,
            hasEffects: !store.document.effects.isEmpty,
            // "Disable all" is offered while any of them is on, which is the
            // same rule the rail's own switch follows.
            allEffectsEnabled: !store.document.effects.isEmpty
                && store.document.effects.allSatisfy(\.enabled),
            showBeatGrid: store.showBeatGrid,
            stereoView: store.stereoView,
            loopSelection: store.loopSelection,
            trim: { store.trimToSelection() },
            silence: { store.silenceSelection() },
            deleteSelection: { store.deleteSelection() },
            insertGap: { store.insertGap() },
            splitAtPlayhead: { store.splitAtCursor() },
            reverse: { store.reverseSelection() },
            autoTrim: { db in
                Task { await store.autoTrimSilence(thresholdDb: db) }
            },
            snapToSection: { store.snapSelectionToSection() },
            refineToZeroCrossings: {
                Task { await store.refineSelectionToZeroCrossings() }
            },
            setSnapMode: { store.snapMode = $0 },
            fadeIn: { store.addFadeInFromContext() },
            fadeOut: { store.addFadeOutFromContext() },
            // The house target, not a number of the menu's own: the same
            // value the rail's radio button writes, so the two agree.
            setNormalized: { on in
                store.setNormalize(lufs: on ? store.houseTargetLufs() : nil)
            },
            // A nudge, not an absolute: "+3 dB" on a menu means three more
            // than it is now, and the rail's slider reads the same figure.
            amplify: { delta in
                store.setAmplify(
                    db: (store.amplifyDbForSelection + delta)
                        .clamped(to: -24...24))
                store.endInteraction()
            },
            setSpeed: { store.setSpeed(rate: $0); store.endInteraction() },
            setPitch: { store.setPitch(semitones: $0); store.endInteraction() },
            setResample: { store.setResample(hz: $0) },
            addEffect: { store.addEffect($0) },
            setAllEffects: { store.setAllEffectsEnabled($0) },
            setCrossfadeJoins: { store.setCrossfadeJoins($0) },
            clearAllEdits: { store.clearAllOps() },
            send: { intent in
                Task { await store.sendSelection(intent) }
            },
            setBeatGrid: { store.showBeatGrid = $0 },
            setStereoView: { store.stereoView = $0 },
            setLoopSelection: { store.loopSelection = $0 })
    }
}

private struct EditorAudioCommandsKey: FocusedValueKey {
    typealias Value = EditorAudioCommands
}

// MARK: - Zoom

/// "This screen has a ruler you can zoom."
///
/// Published by the Editor *and* by the Workbench's timeline, which is the
/// whole point of it being its own value: the View menu's four items belong to
/// whichever of them is on screen, and before this they belonged to the Editor
/// alone — ⌘+ on the bench did nothing at all.
struct ZoomCommands {
    /// The timeline has no time selection to frame, so it publishes false and
    /// that one item dims while the other three work.
    var canZoomToSelection = false
    var zoomIn: () -> Void = {}
    var zoomOut: () -> Void = {}
    var zoomToFit: () -> Void = {}
    var zoomToSelection: () -> Void = {}
}

private struct ZoomCommandsKey: FocusedValueKey {
    typealias Value = ZoomCommands
}

// MARK: - Workbench

/// The bench's arrangement, where the menubar can reach it.
///
/// Clip operations were ruled out when the menubar was first built because the
/// bench had no lifted selection. It has one now — the cards and the timeline
/// share `selection` — so the four clip verbs, the two whole-bench ones and
/// Reimagine can all be reached from the menu.
struct WorkbenchCommands {
    var hasClips = false
    var hasLanes = false
    var hasSelection = false
    /// The picked clip has an analysis with sections to split on.
    var canExplode = false
    /// It overlaps a neighbour on its own lane — the pair a crossfade joins.
    var canCrossfade = false
    var canReimagine = false

    var addPart: () -> Void = {}
    var duplicate: () -> Void = {}
    var remove: () -> Void = {}
    var explode: () -> Void = {}
    var crossfade: () -> Void = {}
    var pullToStart: () -> Void = {}
    var clearBench: () -> Void = {}
    var reimagine: () -> Void = {}
}

private struct WorkbenchCommandsKey: FocusedValueKey {
    typealias Value = WorkbenchCommands
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

    var editorAudioCommands: EditorAudioCommands? {
        get { self[EditorAudioCommandsKey.self] }
        set { self[EditorAudioCommandsKey.self] = newValue }
    }

    var zoomCommands: ZoomCommands? {
        get { self[ZoomCommandsKey.self] }
        set { self[ZoomCommandsKey.self] = newValue }
    }

    var workbenchCommands: WorkbenchCommands? {
        get { self[WorkbenchCommandsKey.self] }
        set { self[WorkbenchCommandsKey.self] = newValue }
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

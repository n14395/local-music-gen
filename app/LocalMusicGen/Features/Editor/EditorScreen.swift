// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

/// The Editor destination: one file in detail. Everything the design's E01,
/// E02, E03 and E05 screens show — the Workbench remains the place many
/// files are arranged, and this screen never grows a second lane.
struct EditorScreen: View {
    @Bindable var store: EditorStore
    let catalog: ModelCatalogStore
    let library: LibraryStore
    let parts: PartsStore
    let jobs: JobsStore
    let playback: PlaybackController
    var onOpenModels: () -> Void = {}
    /// Only the apply card uses this, and only for "notify me and go to
    /// Library" — which is a genuine navigation: the render is running, take
    /// me somewhere useful and tell me when it lands. Choosing what to edit
    /// is not, and no longer goes through here.
    var onOpenLibrary: () -> Void = {}

    @Environment(\.undoManager) private var undoManager
    @State private var confirmRevert = false
    @State private var showImporter = false
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            if store.material == nil {
                EditorEmptyState(store: store, catalog: catalog,
                                 library: library, parts: parts, jobs: jobs,
                                 playback: playback,
                                 onOpenModels: onOpenModels,
                                 showImporter: $showImporter,
                                 isDropTargeted: $isDropTargeted)
            } else {
                topBar
                workspace
            }
        }
        .background(Bench.Palette.windowBackground)
        .onAppear { store.undoManager = undoManager }
        .onChange(of: playback.isPlaying) {
            // The app's main transport started something: one player at a
            // time, so the preview yields.
            if playback.isPlaying { store.pausePreview() }
        }
        .sheet(isPresented: Binding(get: { store.exportSheetOpen },
                                    set: { store.exportSheetOpen = $0 })) {
            EditorExportSheet(store: store)
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.audio],
                      allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first
            else { return }
            Task {
                let imported = await library.importSongs(urls: [url])
                if let song = imported.first { store.open(songId: song.id) }
            }
        }
        .confirmationDialog(
            "Revert to the original?", isPresented: $confirmRevert) {
            Button("Revert — discard the edits", role: .destructive) {
                store.revertToOriginal()
            }
        } message: {
            Text(store.hasBackup
                 ? "The file goes back to the untouched original and the "
                   + "edit list is cleared."
                 : "The edit list is cleared. Nothing has been applied, so "
                   + "the file is already the original.")
        }
        // Bare Space and bare Delete stay here rather than going to the
        // menubar: a menu item's shortcut is installed window-wide and fires
        // ahead of the focused control, so either in the menubar would eat the
        // key in every prompt box and search field in the app. Scoped to this
        // screen they are safe, because the Editor has no free-text field
        // anywhere in it. Cut, Copy, Paste, Select All and ⌥Space are menu
        // items — the first four the system's own, reached through the
        // responder chain, the last fed by the focused value below.
        .background { keyCommands }
        // What the Edit, View and Playback menus may do to this screen while
        // it is the one on show. Published from here rather than assembled in
        // the menus, because only the Editor knows whether there is a
        // selection, whether the clipboard came from this track, and whether a
        // render has frozen the document.
        .focusedSceneValue(\.editorCommands, editorCommands)
        // The Audio menu — every operation the toolbar, the rail and the ···
        // overflow offer, which until now the menubar could not see at all.
        .focusedSceneValue(\.editorAudioCommands,
                           EditorAudioCommands(store: store))
        // The View menu's four zoom items, which the Workbench's timeline
        // publishes too — whichever ruler is on screen owns them.
        .focusedSceneValue(\.zoomCommands, ZoomCommands(
            canZoomToSelection: (store.selection?.length ?? 0) > 0,
            zoomIn: { store.zoomIn() },
            zoomOut: { store.zoomOut() },
            zoomToFit: { store.zoomToFit() },
            zoomToSelection: { store.zoomToSelection() }))
        // The Editor's ⌘↩, named by the screen so the item can read
        // "Apply 3 edits" rather than a generic verb.
        .focusedSceneValue(\.runCommand, RunCommand(
            title: applyLabel,
            isEnabled: store.isDirty && store.mixdownModel != nil
                && !isBlockedByAnotherRender,
            run: { Task { await store.applyEdits() } }))
    }

    // MARK: key commands

    private var keyCommands: some View {
        Group {
            Button("") { store.togglePlayback() }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(!store.isCommandable)
            // The Edit menu's Delete item carries no key equivalent — that is
            // ⌫'s day job in a text field, and the stock menu leaves it alone.
            // The waveform's ⌫ is therefore claimed here, where it is live
            // only while this screen is up.
            Button("") { store.deleteSelection() }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(!store.isCommandable
                          || (store.selection?.length ?? 0) == 0)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
    }

    /// The bundle the menubar reads. Rebuilt on each body evaluation, which is
    /// what keeps `hasSelection` and `canPaste` honest — they change as you
    /// drag, and an item that stayed enabled after the selection was cleared
    /// would delete the wrong thing.
    ///
    /// Assembled by `EditorCommands(store:)` rather than here, because the
    /// same bundle is built a second time by `AppDelegate` when a stock Edit
    /// menu item reaches the responder chain.
    private var editorCommands: EditorCommands { EditorCommands(store: store) }

    // MARK: top bar

    private var topBar: some View {
        BenchTopBar {
            AnyView(HStack(spacing: 12) {
                Text("Editor")
                    .font(Bench.Typo.screenTitle)
                    .tracking(-0.15)
                    .foregroundStyle(Bench.Palette.textPrimary)
                Rectangle().fill(Color.white.opacity(0.1))
                    .frame(width: 1, height: 18)
                if let material = store.material {
                    if material.isPart {
                        StemBar(kind: material.stemKind, width: 5, height: 18)
                    }
                    Text(titleLine(material))
                        .font(Bench.Typo.body)
                        .foregroundStyle(Bench.Palette.textSecondary)
                        .lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: 260, alignment: .leading)
                    BenchBadge(material.isPart ? "PART · STEM" : "SONG",
                               tone: material.isPart ? .warn : .neutral,
                               emphasised: true)
                    statusBadge
                    Text(statsLine(material))
                        .font(Bench.Typo.mono(11))
                        .foregroundStyle(Bench.Palette.textFaintest)
                        .lineLimit(1)
                }
            })
        } trailing: {
            HStack(spacing: 9) {
                // Everything except Close freezes while a render is in
                // flight; Close is the one action that stays legal then, so
                // the freeze wraps this group rather than the row.
                Group {
                    Button {
                        undoManager?.undo()
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.system(size: 11, weight: .medium))
                            Text("⌘Z").font(Bench.Typo.mono(11))
                            Text("Undo")
                        }
                    }
                    .buttonStyle(.benchSecondary)
                    .disabled(undoManager?.canUndo != true)
                    Button {
                        undoManager?.redo()
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "arrow.uturn.forward")
                                .font(.system(size: 11, weight: .medium))
                            Text("Redo")
                        }
                    }
                    .buttonStyle(.benchSecondary)
                    .disabled(undoManager?.canRedo != true)
                    Rectangle().fill(Color.white.opacity(0.1))
                        .frame(width: 1, height: 20)
                    Button {
                        confirmRevert = true
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 11, weight: .medium))
                            Text("Revert to original")
                        }
                    }
                    .buttonStyle(.benchSecondary)
                    .disabled((!store.hasBackup && store.document.isEmpty)
                              || isBlockedByAnotherRender)
                    .help(isBlockedByAnotherRender ? blockedNote : "")
                }
                .disabled(isFrozen)
                .opacity(isFrozen ? 0.4 : 1)
                if store.material != nil { closeButton }
                applyButton
                    .disabled(isFrozen)
                    .opacity(isFrozen ? 0.4 : 1)
            }
        }
    }

    /// Puts the track away and returns to the welcome screen.
    ///
    /// It sits with the actions but outside their freeze: the rest of the row
    /// is disabled and dimmed while a render is in flight, and closing is the
    /// one thing that stays legal then. `close()` leaves an in-flight apply
    /// running and owning its own material, so the take still lands in the
    /// Library — the screen is what you are putting away, not the work.
    ///
    /// No confirmation and no warning about unapplied edits: `close()` flushes
    /// the edit list to the row on the way out, so reopening the track brings
    /// every pending edit back. Nothing is lost, so nothing needs asking.
    private var closeButton: some View {
        Button {
            store.close()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                Text("Close")
            }
        }
        .buttonStyle(.benchSecondary)
        .help("Close this track — pending edits are kept and come back "
              + "when you reopen it")
        .accessibilityLabel("Close track")
    }

    private var statusBadge: some View {
        Group {
            if isFrozen {
                HStack(spacing: 7) {
                    BenchSpinner(size: 11)
                    Text("APPLYING")
                        .font(Bench.Typo.mono(9, .semibold)).tracking(0.9)
                        .foregroundStyle(Bench.Palette.accent)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 4)
                    .fill(Bench.Palette.accent.opacity(0.12)))
            } else if store.isDirty {
                BenchBadge("EDITED · NOT APPLIED", tone: .warn,
                           emphasised: true)
            } else if store.appliedDocument != nil {
                BenchBadge("EDITED · APPLIED", tone: .accent, emphasised: true)
            }
        }
    }

    private var applyButton: some View {
        Button {
            Task { await store.applyEdits() }
        } label: {
            HStack(spacing: 9) {
                Text(applyLabel)
                Text("⌘⏎")
                    .font(Bench.Typo.mono(10, .semibold))
                    .opacity(0.6)
            }
        }
        .buttonStyle(BenchPrimaryButtonStyle(size: .compact,
                                             glows: store.isDirty))
        // ⌘↩ is the Render menu's item — see `runCommand` above. The label
        // still prints "⌘⏎", and still tells the truth.
        .disabled(!store.isDirty || store.mixdownModel == nil
                  || isBlockedByAnotherRender)
        .opacity(store.isDirty && !isBlockedByAnotherRender ? 1 : 0.5)
        .help(applyHelp)
    }

    private var applyHelp: String {
        if isBlockedByAnotherRender { return blockedNote }
        if store.mixdownModel == nil {
            return "Install Mixdown & Align (DSP) to render edits"
        }
        return "Render the edits from the original and replace the file"
    }

    private var applyLabel: String {
        let count = store.document.editCount
        return count == 1 ? "Apply 1 edit" : "Apply \(count) edits"
    }

    private func titleLine(_ material: EditorStore.Material) -> String {
        if material.isPart, let songTitle = material.songTitle {
            return "\(material.title) — \(songTitle)"
        }
        if let prompt = material.promptLine, !prompt.isEmpty {
            return "\(material.title) — \(prompt)"
        }
        return material.title
    }

    private func statsLine(_ material: EditorStore.Material) -> String {
        var fields = [String(format: "%.1f S", store.sourceDurationS)]
        if store.isDirty || store.appliedDocument != nil {
            fields[0] = String(format: "%.1f → %.1f S", store.sourceDurationS,
                               store.resultDurationS)
        }
        if let bpm = store.bpm {
            fields.append("\(Int(bpm.rounded())) BPM")
        }
        if let camelot = store.camelot { fields.append(camelot) }
        fields.append(String(format: "%.1f KHZ",
                             Double(material.sampleRate) / 1000))
        return fields.joined(separator: " · ")
    }

    // MARK: workspace

    private var workspace: some View {
        HStack(spacing: 0) {
            VStack(spacing: 12) {
                // Outside the freeze below: while a render runs, the card IS
                // the live control — Cancel and "notify me" have to work,
                // and dimming them with the editing surface made an
                // in-flight apply impossible to stop.
                if showsApplyCard {
                    EditorApplyCard(store: store,
                                    onOpenLibrary: onOpenLibrary)
                } else {
                    if let note = store.actionNote { noteBanner(note) }
                    if previewCaveats.count > 0 { honestyBanner }
                }
                Group {
                    // Tighter than the column's own spacing: the strip and
                    // the seek row read as one unit — what you are looking
                    // at, then what you are hearing — and the strip's
                    // playhead line runs into the knob below it.
                    VStack(spacing: 9) {
                        EditorOverviewStrip(store: store)
                        EditorSeekRow(store: store)
                    }
                    EditorWellView(store: store)
                        .frame(maxHeight: .infinity)
                    toolbar
                }
                .disabled(isFrozen)
                .opacity(isFrozen ? 0.55 : 1)
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            EditorRail(store: store)
                .disabled(isFrozen)
        }
    }

    private var isApplyFailed: Bool {
        if case .failed = store.currentApplyStage { return true }
        return false
    }

    /// The card belongs to the track it was started for: a render that
    /// survives navigating elsewhere must not describe whatever is opened
    /// next.
    private var showsApplyCard: Bool {
        store.currentApplyStage.isBusy || isApplyFailed
    }

    private var isFrozen: Bool { store.applyIsFrozen }

    /// A render is running somewhere — possibly for a track that is not
    /// open. Only one runs at a time, so Apply and Revert wait for it
    /// wherever they are offered.
    private var isBlockedByAnotherRender: Bool {
        store.blockedByAnotherRender
    }

    private var blockedNote: String {
        store.renderingTitle.map { "Rendering “\($0)” — one at a time" }
            ?? "A render is already running"
    }

    /// What the preview cannot play (the known trade-off the design bans
    /// hiding): named explicitly, not implied.
    private var previewCaveats: [String] {
        var out: [String] = []
        if store.document.fadeIn != nil || store.document.fadeOut != nil {
            out.append("fades")
        }
        if store.document.normalizeLufs != nil { out.append("normalise") }
        if abs(store.document.speedRate - 1) > 1e-6 { out.append("speed") }
        if abs(store.document.pitchSemitones) > 1e-6 { out.append("pitch") }
        if !store.document.enabledEffects.isEmpty { out.append("effects") }
        return out
    }

    /// What an action did, when it would otherwise have done nothing
    /// visible — an auto-trim that found no silence, say.
    private func noteBanner(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 12))
                .foregroundStyle(Bench.Palette.textQuaternary)
            Text(text)
                .font(Bench.Typo.secondary)
                .foregroundStyle(Bench.Palette.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 13).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Bench.Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Bench.Palette.cardStrokeSoft, lineWidth: 1))
    }

    private var honestyBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle")
                .font(.system(size: 12))
                .foregroundStyle(Bench.Palette.cyan)
            Text(bannerText)
                .font(Bench.Typo.secondary)
                .foregroundStyle(Bench.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 13).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Bench.Palette.cyan.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Bench.Palette.cyan.opacity(0.2), lineWidth: 1))
    }

    private var bannerText: String {
        "Preview plays the cuts and levels exactly. "
            + previewCaveats.joined(separator: ", ").capitalized
            + (previewCaveats.count == 1 ? " is" : " are")
            + " drawn here and heard after Apply."
    }

    // MARK: toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                toolButton("Trim", enabled: store.selection != nil,
                           help: "Keep only the selection") {
                    store.trimToSelection()
                }
                toolButton("Fade in", enabled: true,
                           help: "Fade the track in from the start") {
                    store.addFadeInFromContext()
                }
                toolButton("Fade out", enabled: true,
                           help: "Fade the track out at the end") {
                    store.addFadeOutFromContext()
                }
                divider
                toolButton("Split", enabled: true,
                           help: "Split at the playhead — makes a region "
                               + "boundary, changes nothing audible") {
                    store.splitAtCursor()
                }
                toolButton("Insert gap", enabled: true,
                           help: "Insert two seconds of silence at the "
                               + "playhead") {
                    store.insertGap()
                }
                divider
                overflowMenu
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Bench.Palette.card))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Bench.Palette.cardStroke, lineWidth: 1))
            Spacer(minLength: 8)
            HStack(spacing: 5) {
                destructiveButton("Silence",
                                  help: "Replace the selection with silence") {
                    store.silenceSelection()
                }
                destructiveButton("Delete ⌫",
                                  help: "Remove the selection and close the "
                                      + "gap") {
                    store.deleteSelection()
                }
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Bench.Palette.danger.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Bench.Palette.danger.opacity(0.18),
                              lineWidth: 1))
            .opacity(hasRange ? 1 : 0.5)
            .disabled(!hasRange)
        }
    }

    /// A selection with no length is not something a range action can act on.
    ///
    /// `EditProgram.apply` refuses a zero-length range, so these buttons used
    /// to record a "0:00.00 → 0:00.00" no-op row, an undo step and an
    /// "Apply 1 edit" for a render that changes nothing. The ⌫ key command
    /// always gated on length; the toolbar and the overflow menu did not.
    private var hasRange: Bool { (store.selection?.length ?? 0) > 0 }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.09))
            .frame(width: 1, height: 22)
            .padding(.horizontal, 3)
    }

    private func toolButton(_ title: String, enabled: Bool, help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Bench.Typo.secondary)
                .foregroundStyle(enabled ? Bench.Palette.textSecondary
                                         : Bench.Palette.textFaintest)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .contentShape(RoundedRectangle(cornerRadius: 7,
                                               style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }

    private func destructiveButton(_ title: String, help: String,
                                   action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Bench.Typo.secondary)
                .foregroundStyle(Bench.Palette.dangerText)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .contentShape(RoundedRectangle(cornerRadius: 7,
                                               style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// The ··· overflow the toolbar earned (E07): clipboard, reverse,
    /// auto-trim, and the two view toggles.
    private var overflowMenu: some View {
        Menu {
            Button("Cut") { store.cutSelection() }
                .disabled(!hasRange)
            Button("Copy") { store.copySelection() }
                .disabled(!hasRange)
            Button("Paste") { store.paste() }
                .disabled(!store.canPaste)
            // A copied slice points into the file it came from, so it cannot
            // be pasted elsewhere. Said out loud: a greyed Paste with no
            // explanation is a small mystery every time.
            if !store.clipboard.isEmpty, !store.canPaste,
               let from = store.clipboardSourceTitle {
                Text("Copied from “\(from)” — paste works in that track")
            }
            Divider()
            Button("Reverse selection") { store.reverseSelection() }
                .disabled(!hasRange)
            Menu("Auto-trim silence") {
                ForEach(EditorStore.autoTrimThresholdsDb, id: \.self) { db in
                    Button(String(format: "Below %.0f dB", db)) {
                        Task { await store.autoTrimSilence(thresholdDb: db) }
                    }
                }
            }
            Divider()
            Toggle("Show beat grid", isOn: Binding(
                get: { store.showBeatGrid },
                set: { store.showBeatGrid = $0 }))
            Toggle("Show channels separately", isOn: Binding(
                get: { store.stereoView },
                set: { store.stereoView = $0 }))
        } label: {
            Text("···")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Bench.Palette.textSecondary)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

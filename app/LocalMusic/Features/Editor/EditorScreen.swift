import AppKit
import SwiftUI

/// The Editor destination: one file in detail. Everything the design's E01,
/// E02, E03 and E05 screens show — the Workbench remains the place many
/// files are arranged, and this screen never grows a second lane.
struct EditorScreen: View {
    @Bindable var store: EditorStore
    let library: LibraryStore
    let parts: PartsStore
    let playback: PlaybackController
    var onOpenLibrary: () -> Void = {}

    @Environment(\.undoManager) private var undoManager
    @State private var confirmRevert = false
    @State private var showImporter = false
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            if store.material == nil {
                EditorEmptyState(store: store, library: library, parts: parts,
                                 onOpenLibrary: onOpenLibrary,
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
        // Key commands (Tier 0.4): the app had none anywhere; these are
        // window-wide while the Editor is frontmost.
        .background {
            keyCommands
        }
    }

    // MARK: key commands

    private var keyCommands: some View {
        Group {
            Button("") { store.togglePlayback() }
                .keyboardShortcut(.space, modifiers: [])
            Button("") { store.playSelection() }
                .keyboardShortcut(.space, modifiers: .option)
            Button("") { store.selectAll() }
                .keyboardShortcut("a", modifiers: .command)
            Button("") { store.deleteSelection() }
                .keyboardShortcut(.delete, modifiers: [])
            Button("") { store.cutSelection() }
                .keyboardShortcut("x", modifiers: .command)
            Button("") { store.copySelection() }
                .keyboardShortcut("c", modifiers: .command)
            Button("") { store.paste() }
                .keyboardShortcut("v", modifiers: .command)
                .disabled(!store.canPaste)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .disabled(store.material == nil || isFrozen
                  || isBlockedByAnotherRender)
    }

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
                Button {
                    undoManager?.undo()
                } label: {
                    HStack(spacing: 7) {
                        Text("⌘Z").font(Bench.Typo.mono(11))
                        Text("Undo")
                    }
                }
                .buttonStyle(.benchSecondary)
                .disabled(undoManager?.canUndo != true)
                Button("Redo") { undoManager?.redo() }
                    .buttonStyle(.benchSecondary)
                    .disabled(undoManager?.canRedo != true)
                Rectangle().fill(Color.white.opacity(0.1))
                    .frame(width: 1, height: 20)
                Button("Revert to original") { confirmRevert = true }
                    .buttonStyle(.benchSecondary)
                    .disabled((!store.hasBackup && store.document.isEmpty)
                              || isBlockedByAnotherRender)
                    .help(isBlockedByAnotherRender ? blockedNote : "")
                applyButton
            }
            .disabled(isFrozen)
            .opacity(isFrozen ? 0.4 : 1)
        }
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
        .keyboardShortcut(.return, modifiers: .command)
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
                    EditorOverviewStrip(store: store)
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

    private var isFrozen: Bool { store.currentApplyStage.isBusy }

    /// A render is running somewhere — possibly for a track that is not
    /// open. Only one runs at a time, so Apply and Revert wait for it
    /// wherever they are offered.
    private var isBlockedByAnotherRender: Bool {
        store.isRenderingAnything && !store.applyBelongsToCurrentMaterial
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
            .opacity(store.selection == nil ? 0.5 : 1)
            .disabled(store.selection == nil)
        }
    }

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
                .disabled(store.selection == nil)
            Button("Copy") { store.copySelection() }
                .disabled(store.selection == nil)
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
                .disabled(store.selection == nil)
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

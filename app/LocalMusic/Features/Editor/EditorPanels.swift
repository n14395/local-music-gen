import AppKit
import SwiftUI

// The Editor's three secondary faces: the empty state (E05), the applying
// card (E03), and the export dialog (E04).

// MARK: - Empty state

struct EditorEmptyState: View {
    @Bindable var store: EditorStore
    let catalog: ModelCatalogStore
    let library: LibraryStore
    let parts: PartsStore
    let jobs: JobsStore
    let playback: PlaybackController
    var onOpenModels: () -> Void
    @Binding var showImporter: Bool
    @Binding var isDropTargeted: Bool

    @State private var query = ""
    /// Choosing something to edit used to switch the app to the Library tab
    /// and leave you there — a navigation, not a choice, with nothing tying
    /// the two screens together and no way back but the sidebar. Every other
    /// slot in the app fills from `PartPickerSheet`, which searches, auditions
    /// and filters by origin without taking the screen away.
    @State private var picking = false
    /// The recents list, built off the view update.
    ///
    /// This was a computed property read from `body`, and building it runs a
    /// library search, a parts search and a `JSONDecoder` per row. The field
    /// above it is a live search box, so that was three synchronous database
    /// round trips per keystroke — and the same again on every unrelated
    /// redraw of the panel, for a list that had not changed.
    @State private var rows: [Row] = []

    var body: some View {
        VStack(spacing: 0) {
            BenchTopBar(title: "Editor") {
                BenchSearchField(text: $query,
                                 placeholder: "Find a track or part…")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    headline
                    dropZone
                    recentList
                    shortcutLegend
                }
                .frame(maxWidth: 820)
                .padding(.vertical, 40)
                .frame(maxWidth: .infinity)
            }
        }
        .contentShape(Rectangle())
        // Rebuilt when the question changes, not when the panel redraws. The
        // `id:` restarts the task per keystroke and the sleep is what makes a
        // typed word one search instead of one per letter.
        .task(id: query) {
            if !rows.isEmpty || !query.isEmpty {
                try? await Task.sleep(for: LibraryStore.searchDebounce)
                guard !Task.isCancelled else { return }
            }
            rows = buildRows()
        }
        // A take landing while the Editor sits on its empty state should show
        // up in RECENT without needing a keystroke to dislodge it.
        .onChange(of: library.recent) { rows = buildRows() }
        .sheet(isPresented: $picking) {
            PartPickerSheet(
                slotLabel: "Any part or song",
                // Audio only, declared next to the method that enforces it.
                accepts: EditorStore.pickerAccepts,
                // Nothing to derive: songs are directly editable, so there is
                // no unfillable row here to offer a split for.
                autoDerive: nil,
                catalog: catalog, library: library, parts: parts, jobs: jobs,
                playback: playback, onOpenModels: onOpenModels,
                onPick: { store.open($0) })
        }
        .dropDestination(for: URL.self) { urls, _ in
            let audio = AudioDrop.audioFiles(in: urls)
            guard let first = audio.first else { return false }
            Task {
                let imported = await library.importSongs(urls: [first])
                if let song = imported.first { store.open(songId: song.id) }
            }
            return true
        } isTargeted: { isDropTargeted = $0 }
    }

    private var headline: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Bench.Palette.card)
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(Bench.Palette.cardStroke, lineWidth: 1)
                // The same glyph the sidebar draws, not a second drawing of
                // the same idea. This tile used to hand-build a rule with two
                // cut marks, so when the Editor's icon changed the nav moved
                // and this did not — the two sat a few hundred points apart
                // claiming to be the same destination. `BenchNavGlyph` scales
                // off `size`, which is the whole reason it takes one.
                BenchNavGlyph(kind: .editor, color: Bench.Palette.accent,
                              size: 22)
            }
            .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 5) {
                Text("Trim, cut, fade and level one file")
                    .font(.system(size: 22, weight: .semibold))
                    .tracking(-0.3)
                    .foregroundStyle(Bench.Palette.textPrimary)
                Text("Editing is non-destructive: your original is always "
                     + "kept, and edits stay adjustable. ")
                    .font(Bench.Typo.body)
                    .foregroundStyle(Bench.Palette.textQuaternary)
                + Text("Arranging several files together is the Workbench.")
                    .font(Bench.Typo.body)
                    .foregroundStyle(Bench.Palette.textFaint)
            }
        }
    }

    private var dropZone: some View {
        VStack(spacing: 12) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach([12, 24, 34, 18, 28, 9], id: \.self) { height in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Bench.Palette.textFaintest)
                        .frame(width: 4, height: CGFloat(height))
                }
            }
            .opacity(0.5)
            Text("Drop an audio file to edit it")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Bench.Palette.textPrimary)
            HStack(spacing: 9) {
                Button("Choose from Library…") { picking = true }
                    .buttonStyle(BenchPrimaryButtonStyle(size: .compact,
                                                         glows: false))
                Button("Import a file…") { showImporter = true }
                    .buttonStyle(.benchSecondary)
            }
            Text("WAV · AIFF · FLAC · MP3 · M4A")
                .font(Bench.Typo.mono(10))
                .foregroundStyle(Bench.Palette.textFaintest)
        }
        .frame(maxWidth: .infinity)
        .padding(30)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(isDropTargeted ? Bench.Palette.accent.opacity(0.05)
                                 : Color(hex: 0x111519)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(isDropTargeted ? Bench.Palette.accent.opacity(0.5)
                                         : Color.white.opacity(0.14),
                          style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }

    // MARK: recents

    private struct Row: Identifiable {
        var id: String
        var title: String
        var meta: String
        var stemKind: String?
        var audioURL: URL
        var cacheURL: URL
        var editCount: Int
        var isPart: Bool
    }

    private func buildRows() -> [Row] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        var songs: [SongRecord]
        if trimmed.isEmpty {
            songs = Array(library.recent.prefix(4))
        } else {
            var filters = LibraryRepository.Filters()
            filters.query = trimmed
            songs = Array(((try? library.repository.search(filters)) ?? [])
                .prefix(6))
        }
        var out: [Row] = songs.map { song in
            Row(id: song.id, title: song.title,
                meta: LibrarySongRow.metaLine(for: song, partCount: 0),
                stemKind: nil, audioURL: song.fileURL,
                cacheURL: song.waveformURL,
                editCount: editCount(of: song.editsJSON), isPart: false)
        }
        if !trimmed.isEmpty {
            var filters = PartsRepository.Filters()
            filters.query = trimmed
            let matched = ((try? parts.repository.parts(filters)) ?? [])
                .filter { $0.format == "wav" }
                .prefix(4)
            out += matched.map { part in
                Row(id: part.id, title: part.name,
                    meta: "PART · \(part.modelName.uppercased())",
                    stemKind: part.kind, audioURL: part.fileURL,
                    cacheURL: part.waveformURL,
                    editCount: editCount(of: part.editsJSON), isPart: true)
            }
        }
        return out
    }

    private func editCount(of json: String?) -> Int {
        guard let json,
              let document = try? JSONDecoder().decode(
                EditDocument.self, from: Data(json.utf8)) else { return 0 }
        return document.editCount
    }

    private var recentList: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(query.isEmpty ? "RECENT" : "MATCHES").eyebrow()
                Spacer()
                // Same sheet. This is the "what I want isn't in RECENT"
                // affordance, which is a choice too — and the ellipsis is
                // this app's mark for one that opens rather than navigates.
                Button("Browse all \(library.results.count)…") { picking = true }
                    .buttonStyle(.plain)
                    .font(Bench.Typo.secondary)
                    .foregroundStyle(Bench.Palette.textQuaternary)
            }
            ForEach(rows) { row in
                recentRow(row)
            }
            if rows.isEmpty {
                Text(query.isEmpty
                     ? "Nothing in the library yet — generate or import "
                       + "something first."
                     : "No matches.")
                    .font(Bench.Typo.small)
                    .foregroundStyle(Bench.Palette.textFaint)
            }
        }
    }

    private func recentRow(_ row: Row) -> some View {
        Button {
            row.isPart ? store.open(partId: row.id)
                       : store.open(songId: row.id)
        } label: {
            HStack(spacing: 13) {
                if let kind = row.stemKind {
                    StemBar(kind: kind, width: 4, height: 22)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.title)
                        .font(Bench.Typo.secondaryEmphasis)
                        .foregroundStyle(Bench.Palette.textPrimary)
                        .lineLimit(1)
                    Text(row.meta)
                        .metaLine()
                        .lineLimit(1)
                }
                .frame(width: 210, alignment: .leading)
                BenchWaveformLoader(audioURL: row.audioURL,
                                    cacheURL: row.cacheURL)
                    .frame(height: 26)
                    .frame(maxWidth: .infinity)
                    .allowsHitTesting(false)
                if row.editCount > 0 {
                    BenchBadge(row.editCount == 1 ? "1 EDIT"
                                                  : "\(row.editCount) EDITS",
                               tone: .warn, emphasised: true)
                    Text("Continue editing")
                        .font(Bench.Typo.small.weight(.semibold))
                        .foregroundStyle(Bench.Palette.onAccent)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 7)
                            .fill(Bench.Palette.accent))
                } else {
                    Text("Open")
                        .font(Bench.Typo.small)
                        .foregroundStyle(Bench.Palette.textSecondary)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 7)
                            .fill(Bench.Palette.control))
                }
            }
            .padding(.horizontal, 13).padding(.vertical, 11)
            .benchCard(fill: Bench.Palette.card,
                       stroke: Bench.Palette.cardStrokeSoft, radius: 11)
            .contentShape(RoundedRectangle(cornerRadius: 11,
                                           style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var shortcutLegend: some View {
        HStack(spacing: 22) {
            legend("␣", "Play / pause")
            legend("⌘A", "Select all")
            legend("⌫", "Delete selection")
            legend("⌘⏎", "Apply")
        }
        .padding(.top, 4)
    }

    private func legend(_ key: String, _ label: String) -> some View {
        HStack(spacing: 8) {
            Text(key)
                .font(Bench.Typo.mono(10, .semibold))
                .foregroundStyle(Bench.Palette.textTertiary)
                .padding(.horizontal, 7).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 5)
                    .fill(Bench.Palette.raised))
                .overlay(RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Bench.Palette.cardStroke, lineWidth: 1))
            Text(label)
                .font(Bench.Typo.small)
                .foregroundStyle(Bench.Palette.textFaint)
        }
    }
}

// MARK: - Applying card (E03)

struct EditorApplyCard: View {
    @Bindable var store: EditorStore
    var onOpenLibrary: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            stages
            footerRow
        }
        .padding(.horizontal, 20).padding(.vertical, 18)
        .benchCard(fill: Bench.Palette.card,
                   stroke: isFailed ? Bench.Palette.danger.opacity(0.3)
                                    : Bench.Palette.accent.opacity(0.24),
                   radius: 12)
        .shadow(color: isFailed ? .clear : Bench.Palette.accent.opacity(0.14),
                radius: 34, y: 6)
    }

    private var isFailed: Bool {
        if case .failed = store.currentApplyStage { return true }
        return false
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                if case .failed(let message) = store.currentApplyStage {
                    Text("The render failed")
                        .font(.system(size: 16, weight: .semibold))
                        .tracking(-0.16)
                        .foregroundStyle(Bench.Palette.textPrimary)
                    Text(message)
                        .font(Bench.Typo.secondary)
                        .foregroundStyle(Bench.Palette.dangerText)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Rendering \(store.document.editCount) "
                         + (store.document.editCount == 1 ? "edit" : "edits")
                         + " from the original")
                        .font(.system(size: 16, weight: .semibold))
                        .tracking(-0.16)
                        .foregroundStyle(Bench.Palette.textPrimary)
                    Text(specLine)
                        .font(Bench.Typo.mono(11))
                        .foregroundStyle(Bench.Palette.textMuted)
                }
            }
            Spacer()
            if let fraction = renderingFraction {
                VStack(alignment: .trailing, spacing: 4) {
                    Text("\(Int((fraction * 100).rounded()))%")
                        .font(Bench.Typo.mono(24, .semibold))
                        .foregroundStyle(Bench.Palette.accent)
                    if let eta = renderingEta {
                        Text("≈ \(Int(eta.rounded())) S LEFT")
                            .font(Bench.Typo.mono(11))
                            .foregroundStyle(Bench.Palette.textQuaternary)
                    }
                }
            } else if !isFailed {
                BenchSpinner(size: 22)
            }
        }
    }

    private var specLine: String {
        let trackCount = store.segments.filter { !$0.silent }.count
        var fields = ["DSP-MIXDOWN", "1 SOURCE",
                      "\(trackCount) SEGMENT" + (trackCount == 1 ? "" : "S")]
        if let lufs = store.document.normalizeLufs {
            fields.append(String(format: "%.0f LUFS · −1 DBTP", lufs))
        }
        return fields.joined(separator: " · ")
    }

    private var renderingFraction: Double? {
        if case .rendering(_, let fraction, _, _) = store.currentApplyStage {
            return fraction
        }
        return nil
    }

    private var renderingEta: Double? {
        if case .rendering(_, _, let eta, _) = store.currentApplyStage {
            return eta
        }
        return nil
    }

    private var stages: some View {
        HStack(spacing: 10) {
            stage("Backup stashed", state: stageState(0))
            stage("Job queued", state: stageState(1))
            stage("Mixdown & loudness", state: stageState(2), wide: true,
                  fraction: renderingFraction)
            stage("Replace file", state: stageState(3))
            stage("Rebuild peaks", state: stageState(4))
        }
    }

    private enum StageState { case done, active, pending }

    private func stageState(_ index: Int) -> StageState {
        let current: Int
        switch store.currentApplyStage {
        case .idle, .failed: current = -1
        case .stashingBackup: current = 0
        case .uploading, .queued: current = 1
        case .rendering: current = 2
        case .replacing: current = 3
        case .rebuildingPeaks: current = 4
        }
        if current > index { return .done }
        if current == index { return .active }
        return .pending
    }

    private func stage(_ label: String, state: StageState, wide: Bool = false,
                       fraction: Double? = nil) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                switch state {
                case .done:
                    ZStack {
                        Circle().fill(Bench.Palette.ok.opacity(0.16))
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Bench.Palette.ok)
                    }
                    .frame(width: 15, height: 15)
                case .active:
                    BenchSpinner(size: 15)
                case .pending:
                    Circle()
                        .strokeBorder(Color.white.opacity(0.16),
                                      lineWidth: 1.5)
                        .frame(width: 15, height: 15)
                }
                Text(label)
                    .font(Bench.Typo.caption
                        .weight(state == .active ? .semibold : .regular))
                    .foregroundStyle(state == .active ? Bench.Palette.accent
                        : state == .done ? Bench.Palette.textQuaternary
                        : Bench.Palette.textFaintest)
                    .lineLimit(1)
            }
            Group {
                switch state {
                case .done:
                    Rectangle().fill(Bench.Palette.ok)
                case .active:
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(Color.white.opacity(0.1))
                            Rectangle().fill(Bench.Palette.accent)
                                .frame(width: geo.size.width
                                       * (fraction ?? 0.35))
                        }
                    }
                case .pending:
                    Rectangle().fill(Color.white.opacity(0.08))
                }
            }
            .frame(height: 2)
            .clipShape(Capsule())
        }
        .frame(maxWidth: wide ? .infinity : nil)
        .frame(minWidth: wide ? 120 : 100)
    }

    private var footerRow: some View {
        HStack(spacing: 10) {
            if store.hasBackup {
                HStack(spacing: 7) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Bench.Palette.ok)
                    Text("Backup kept · revert works forever")
                        .font(Bench.Typo.small)
                        .foregroundStyle(Bench.Palette.textQuaternary)
                }
                Button("Reveal backup") {
                    if let url = store.material?.backupURL {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
                .buttonStyle(.bench(.quiet))
            }
            Spacer()
            if isFailed {
                Button("Dismiss") { store.dismissApplyStage() }
                    .buttonStyle(.benchSecondary)
            } else {
                Button("Notify me and go to Library") {
                    store.notifyWhenApplied = true
                    onOpenLibrary()
                }
                .buttonStyle(.benchSecondary)
                Button("Cancel render") {
                    Task { await store.cancelApply() }
                }
                .buttonStyle(.bench(.destructive))
            }
        }
    }
}

// MARK: - Export sheet (E04)

struct EditorExportSheet: View {
    @Bindable var store: EditorStore
    @Environment(\.dismiss) private var dismiss
    /// Ambient, optional: absent (previews, tests) leaves the struct's own
    /// wav/pcm24 defaults.
    @Environment(AppSettings.self) private var appSettings: AppSettings?

    @State private var choice = EditorStore.ExportChoice()

    var body: some View {
        content.onAppear {
            // Settings' preferred format/depth, as the sheet's starting
            // point; the pickers below still override per export.
            if let settings = appSettings {
                choice.format = settings.exportFormat
                choice.bitDepth = settings.exportDepth
            }
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Export selection")
                    .font(.system(size: 15, weight: .semibold))
                    .tracking(-0.15)
                    .foregroundStyle(Bench.Palette.textPrimary)
                Text(subtitle)
                    .font(Bench.Typo.mono(11))
                    .foregroundStyle(Bench.Palette.textMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 14)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Bench.Palette.hairline).frame(height: 1)
            }

            VStack(alignment: .leading, spacing: 14) {
                labelled("Format") {
                    BenchSegmented(
                        selection: $choice.format,
                        options: ["wav", "aiff", "flac", "mp3"].map {
                            .init(value: $0, label: $0.uppercased())
                        })
                }
                labelled("Bit depth") {
                    BenchSegmented(
                        selection: $choice.bitDepth,
                        options: [("pcm16", "16-bit"), ("pcm24", "24-bit"),
                                  ("float32", "32-bit float")].map {
                            .init(value: $0.0, label: $0.1)
                        })
                    .opacity(choice.format == "mp3" ? 0.45 : 1)
                    .disabled(choice.format == "mp3")
                }
                labelled("Sample rate") {
                    BenchMenu(label: sampleRateLabel) {
                        Button("Same as source") { choice.sampleRateHz = nil }
                        Divider()
                        ForEach([44100, 48000, 96000], id: \.self) { hz in
                            Button("\(hz.formatted(.number)) Hz") {
                                choice.sampleRateHz = hz
                            }
                        }
                    }
                }
                labelled("Apply edits") {
                    Toggle(isOn: $choice.applyEdits) {
                        Text(applyEditsNote)
                            .font(Bench.Typo.small)
                            .foregroundStyle(Bench.Palette.textQuaternary)
                    }
                    .toggleStyle(.bench)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(fileName.uppercased())
                        .font(Bench.Typo.mono(11))
                        .foregroundStyle(Bench.Palette.textQuaternary)
                        .lineLimit(1).truncationMode(.middle)
                    Text(shapeLine)
                        .font(Bench.Typo.mono(11))
                        .foregroundStyle(Bench.Palette.textFaintest)
                }
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 9,
                                             style: .continuous)
                    .fill(Color(hex: 0x131820)))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Bench.Palette.hairline, lineWidth: 1))
                if choice.format == "flac", choice.bitDepth == "float32" {
                    Text("FLAC cannot hold 32-bit float samples — pick "
                         + "24-bit, or WAV/AIFF.")
                        .font(Bench.Typo.caption)
                        .foregroundStyle(Bench.Palette.dangerText)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 16)

            HStack(spacing: 9) {
                Text("Renders through the engine · ≈ "
                     + "\(max(2, Int((exportSeconds * 0.06).rounded()))) s")
                    .font(Bench.Typo.small)
                    .foregroundStyle(Bench.Palette.textFaint)
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bench(.quiet))
                Button("Export") { runExport() }
                    .buttonStyle(BenchPrimaryButtonStyle(size: .compact,
                                                         glows: false))
                    .disabled(choice.format == "flac"
                              && choice.bitDepth == "float32")
            }
            .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 18)
            .overlay(alignment: .top) {
                Rectangle().fill(Bench.Palette.hairline).frame(height: 1)
            }
        }
        .frame(width: 468)
        .background(Bench.Palette.card)
    }

    private var exportSeconds: Double {
        store.selection?.length ?? store.resultDurationS
    }

    private var subtitle: String {
        if let selection = store.selection {
            return "\(EditorClock.full(selection.start)) → "
                + "\(EditorClock.full(selection.end)) · "
                + String(format: "%.2f S OF ", selection.length)
                + (store.material?.title.uppercased() ?? "")
        }
        return "THE WHOLE EDITED "
            + (store.material?.isPart == true ? "PART" : "TRACK")
    }

    private var applyEditsNote: String {
        let count = store.document.editCount
        guard count > 0 else { return "No pending edits" }
        return choice.applyEdits
            ? "Export with the \(count) pending "
                + (count == 1 ? "edit" : "edits") + " baked in"
            : "Export the untouched material under the selection"
    }

    private var sampleRateLabel: String {
        choice.sampleRateHz.map { "\($0.formatted(.number)) Hz" }
            ?? "\((store.material?.sampleRate ?? 44100).formatted(.number)) "
                + "Hz — same as source"
    }

    private var fileName: String {
        EditorStore.exportName(title: store.material?.title ?? "export",
                               songTitle: store.material?.songTitle,
                               selection: store.selection,
                               format: choice.format)
    }

    private var shapeLine: String {
        let depth = ["pcm16": "16-BIT", "pcm24": "24-BIT",
                     "float32": "32-BIT FLOAT"][choice.bitDepth] ?? ""
        let rate = Double(choice.sampleRateHz
                          ?? store.material?.sampleRate ?? 44100) / 1000
        return (choice.format == "mp3" ? "" : depth + " · ")
            + String(format: "%.1f KHZ · STEREO", rate)
    }

    private func labelled<Content: View>(
        _ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(Bench.Typo.secondary)
                .foregroundStyle(Bench.Palette.textSecondary)
                .frame(width: 86, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    private func runExport() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileName
        let picked = choice
        dismiss()
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                await store.exportSelection(choice: picked, destination: url)
            }
        }
    }
}

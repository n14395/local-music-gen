import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The viewer: one score, large, zoomable, transposable, with a way to hear
/// it. Presented with `.sheet(item:)` from whichever surface holds a
/// `NotationDocument` — the Library panes, the Words pages, and the Track
/// menu through `MainWindow`.
///
/// Resizable, unlike `PartPickerSheet`, because scores are wide: a four-voice
/// transcription at 100 % wants every point the window can give it.
struct NotationSheet: View {
    let document: NotationDocument
    let playback: PlaybackController
    /// "Render notes…" for a score whose MIDI has no preview yet — the same
    /// route the Library's part rows take, threaded in from `MainWindow`. nil
    /// when the host has no route to a renderer, and the button says so
    /// rather than vanishing.
    var onRenderNotes: ((PartRecord) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var zoom = 100
    @State private var transpose = 0
    @State private var showABC = false
    @State private var warnings: [String] = []
    @State private var drewNothing = false
    /// Render notes… submits a job and the queue takes it from there; the
    /// button only has to stop offering the same job twice.
    @State private var renderRequested = false
    @State private var exportError: String?
    @State private var exporting = false
    /// The handle the export path uses to reach the page — see
    /// `NotationBridge`. A class in `@State` so the sheet owns exactly one.
    @State private var bridge = NotationBridge()

    private static let zooms = [75, 100, 125, 150]

    var body: some View {
        VStack(spacing: 0) {
            header
            controls
            if !warnings.isEmpty { warningsStrip }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    NotationView(abc: document.doc.text,
                                 scale: Double(zoom) / 100,
                                 transpose: transpose, bridge: bridge,
                                 onRendered: { report in
                                     warnings = report.warnings
                                     drewNothing = report.isEmpty
                                 })
                    if showABC { source }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let exportError { exportFailureLine(exportError) }
        }
        .frame(minWidth: 760, idealWidth: 920, maxWidth: .infinity,
               minHeight: 560, idealHeight: 720, maxHeight: .infinity)
        .background(Bench.Palette.panel)
    }

    // MARK: header

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("NOTATION").eyebrow()
                    if document.header.tuneCount > 1 {
                        Text("\(document.header.tuneCount) TUNES")
                            .font(Bench.Typo.mono(10))
                            .foregroundStyle(Bench.Palette.textFaintest)
                    }
                }
                Text(document.title)
                    .font(Bench.Typo.screenTitle)
                    .tracking(-0.15)
                    .foregroundStyle(Bench.Palette.textPrimary)
                    .lineLimit(1)
                Text(keyLine)
                    .font(Bench.Typo.mono(11))
                    .foregroundStyle(Bench.Palette.textMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                hearButton
                Button("Copy ABC") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(document.doc.text,
                                                   forType: .string)
                }
                .buttonStyle(BenchSecondaryButtonStyle(tone: .quiet))
                exportMenu
                Button("Done") { dismiss() }
                    .buttonStyle(BenchSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Bench.Palette.hairline).frame(height: 1)
        }
    }

    /// `K: G → A · 4/4 · 1/4=120 · BASIC PITCH`. The key follows the
    /// transposition so the chrome agrees with the key signature abcjs is
    /// already drawing under `visualTranspose`.
    private var keyLine: String {
        var bits: [String] = []
        if let key = document.header.key {
            bits.append(transpose == 0
                        ? key
                        : "\(key) → \(ABCHeader.transposedKey(key, by: transpose))")
        }
        if let meter = document.header.meter { bits.append(meter) }
        if let tempo = document.header.tempo { bits.append(tempo) }
        bits.append(document.doc.modelName.uppercased())
        if document.doc.edited { bits.append("EDITED") }
        return bits.joined(separator: " · ")
    }

    // MARK: controls

    private var controls: some View {
        HStack(spacing: 16) {
            BenchSegmented(selection: $zoom, options: Self.zooms.map {
                .init(value: $0, label: "\($0)%")
            })
            HStack(spacing: 8) {
                Text("TRANSPOSE").eyebrow()
                BenchStepper(value: $transpose, range: -12...12, width: 30)
                Text(transpose == 0 ? "0 st" : String(format: "%+d st", transpose))
                    .font(Bench.Typo.mono(11))
                    .foregroundStyle(Bench.Palette.textMuted)
                    .frame(width: 44, alignment: .leading)
                if transpose != 0 {
                    Button("Reset") { transpose = 0 }
                        .buttonStyle(.bench(.quiet))
                }
            }
            Spacer(minLength: 8)
            // Read-only here: editing stays where it is today, in the Library
            // slot, so there is one place a score can be changed.
            BenchToggleChip(isOn: $showABC, label: "Show ABC")
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Bench.Palette.hairlineFaint).frame(height: 1)
        }
    }

    /// The page's complaints, in the same vocabulary as the Models screen's
    /// action-error strip: the first three, and how many more.
    private var warningsStrip: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("✕")
                .font(Bench.Typo.mono(11, .semibold))
                .foregroundStyle(Bench.Palette.dangerText)
            NotationWarnings(warnings: warnings,
                             tone: Bench.Palette.textSecondary)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 20).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Bench.Palette.danger.opacity(0.09))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Bench.Palette.danger.opacity(0.30))
                .frame(height: 1)
        }
    }

    private var source: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ABC").eyebrow()
            Text(document.doc.text)
                .font(Bench.Typo.mono(12))
                .foregroundStyle(Bench.Palette.textPrimary)
                .lineSpacing(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10)
                    .fill(Bench.Palette.inset))
        }
    }

    // MARK: hear it

    /// The one transport, never a second synthesiser. A preview plays through
    /// `PlaybackController` under the part's own id, so the Library's row and
    /// the transport bar agree it is the same thing sounding; notes with no
    /// preview offer the render the Library offers; a score with no notes at
    /// all — typed, or edited past its job — says what would make it audible.
    @ViewBuilder
    private var hearButton: some View {
        if let part = document.notesPart, let url = document.previewURL {
            let isCurrent = playback.currentSongId == part.id
            Button(isCurrent && playback.isPlaying ? "Pause" : "Hear it") {
                playback.play(url: url, songId: part.id, title: document.title,
                              duration: part.durationS ?? 0,
                              subtitle: "NOTATION · "
                                  + part.modelName.uppercased())
            }
            .buttonStyle(BenchSecondaryButtonStyle(tone: .accent))
            .help("Play the rendered preview of these notes")
        } else if let part = document.notesPart {
            Button(renderRequested ? "Rendering…" : "Render notes…") {
                onRenderNotes?(part)
                renderRequested = true
            }
            .buttonStyle(BenchSecondaryButtonStyle(tone: .accent))
            .disabled(onRenderNotes == nil || renderRequested)
            .help(renderHelp)
        } else {
            Button("Hear it") {}
                .buttonStyle(BenchSecondaryButtonStyle(tone: .quiet))
                .disabled(true)
                .help("Compose this notation first to hear it")
        }
    }

    private var renderHelp: String {
        if renderRequested {
            return "Queued — the audio lands in Library › Parts"
        }
        if onRenderNotes == nil {
            return "No rendered preview yet — Library › Parts › Render… "
                + "makes one once a model that can render notes is installed"
        }
        return "Render these notes with the SoundFont — the audio lands in "
            + "Library › Parts"
    }

    // MARK: export

    private enum ExportFormat {
        case svg, png

        var type: UTType { self == .svg ? .svg : .png }
        var fileExtension: String { self == .svg ? "svg" : "png" }
    }

    /// Four items rather than a save-panel accessory: a format popup and an
    /// "on white" checkbox is what the panel would need, and `NSSavePanel`
    /// grows those only through an AppKit accessory view. On white leads —
    /// a score people export is usually for paper.
    private var exportMenu: some View {
        BenchMenu(label: exporting ? "Exporting…" : "Export…") {
            Button("SVG, black on white") { export(.svg, paper: true) }
            Button("PNG, black on white") { export(.png, paper: true) }
            Divider()
            Button("SVG, in the app's colours") { export(.svg, paper: false) }
            Button("PNG, in the app's colours") { export(.png, paper: false) }
        }
        .disabled(drewNothing || exporting)
    }

    private func export(_ format: ExportFormat, paper: Bool) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.type]
        panel.nameFieldStringValue = document.title
            .replacingOccurrences(of: "/", with: "-")
            + "." + format.fileExtension
        let theme: NotationTheme = paper ? .paper : .bench
        let background = paper ? "#ffffff"
                               : NotationTheme.hex(Bench.Palette.panel)
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            exporting = true
            Task {
                let data: Data?
                switch format {
                case .svg:
                    data = await bridge.svg(theme: theme, background: background)
                        .map { Data($0.utf8) }
                case .png:
                    data = await bridge.png(theme: theme, background: background)
                }
                if let data {
                    exportError = Self.write(data, to: url)
                } else {
                    exportError = "Export failed: the score could not be drawn."
                }
                exporting = false
            }
        }
    }

    /// Staged beside the destination and swapped in, as `SongDetailView
    /// .export` does for audio and for the same reason: an export that fails
    /// halfway must leave whatever was there, and must say so. Returns the
    /// message to show, nil on success.
    static func write(_ data: Data, to destination: URL) -> String? {
        let fm = FileManager.default
        let staged = destination.deletingLastPathComponent()
            .appendingPathComponent("." + UUID().uuidString + "-"
                                    + destination.lastPathComponent)
        do {
            try data.write(to: staged)
        } catch {
            return "Export failed: \(error.localizedDescription)"
        }
        do {
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: staged)
            } else {
                try fm.moveItem(at: staged, to: destination)
            }
            return nil
        } catch {
            try? fm.removeItem(at: staged)
            return "Export failed: \(error.localizedDescription)"
        }
    }

    /// Said under the score, where the menu that caused it is — the same
    /// caption-and-danger treatment the Library panes give a refused export.
    private func exportFailureLine(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(message)
                .font(Bench.Typo.caption)
                .foregroundStyle(Bench.Palette.dangerText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Dismiss") { exportError = nil }
                .buttonStyle(.bench(.quiet))
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) {
            Rectangle().fill(Bench.Palette.hairline).frame(height: 1)
        }
    }
}

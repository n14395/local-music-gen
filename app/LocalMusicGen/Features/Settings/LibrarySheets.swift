// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// Change the library folder, and decide what becomes of the models in the old
/// one.
///
/// The choice is the whole sheet. Moving the folder without one is what the old
/// Engine-pane control did — it changed a path and left the weights behind,
/// silently, so the next visit to Models showed a catalog that had apparently
/// un-downloaded itself. Each option below states its consequence in the same
/// breath as its name.
struct LibraryRelocateSheet: View {
    let info: LibraryInfo
    let destination: URL
    let onConfirm: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var disposition = "move"

    private var affected: [LibraryRepo] { info.repos }
    /// Auxiliary directories travel with the folder, so they are part of every
    /// figure and every decision on this sheet.
    private var auxDirs: [LibraryRootDir] { info.aux.dirs }
    private var hasModels: Bool { !affected.isEmpty || !auxDirs.isEmpty }
    /// What a move actually moves. ModelScope weights are excluded on purpose:
    /// they live in the app's own folder and never travel.
    private var movingBytes: Int64 { info.bytes + info.aux.bytes }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            pathSummary
            if hasModels {
                if !affected.isEmpty {
                    Text("THE \(affected.count) THAT ARE THERE NOW").eyebrow()
                    LibraryRepoList(repos: affected)
                }
                if !auxDirs.isEmpty {
                    Text("AND \(auxDirs.count) AUXILIARY FOLDER"
                         + (auxDirs.count == 1 ? "" : "S")).eyebrow()
                    LibraryDirList(dirs: auxDirs)
                }
                choices
                if disposition == "delete" && info.isDefault {
                    SharedFolderWarning(verb: "delete")
                }
                consequence
            } else {
                Text("There are no models of ours to move, so the new folder "
                     + "is simply where the next download goes.")
                    .font(Bench.Typo.secondary)
                    .foregroundStyle(Bench.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(20)
        .frame(width: 540)
        .background(Bench.Palette.panel)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("MODEL LIBRARY").eyebrow()
            Text("Move the library folder")
                .font(Bench.Typo.inspectorTitle)
                .foregroundStyle(Bench.Palette.textPrimary)
        }
    }

    private var pathSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            BenchInfoRow("From", info.path, mono: true, labelWidth: 44,
                         color: Bench.Palette.textSecondary)
            BenchInfoRow("To", destination.path, mono: true, labelWidth: 44,
                         color: Bench.Palette.textPrimary)
            Text("Weights land in a \u{201C}hub\u{201D} folder inside it, the "
                 + "layout Hugging Face tools expect. " + auxNote)
                .font(Bench.Typo.caption)
                .foregroundStyle(Bench.Palette.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Where the auxiliary weights end up, in words rather than a path: the
    /// engine decides the folder, and the one thing the app can say for
    /// certain is the rule it already applies to the library folder itself —
    /// the shared Hugging Face cache is the one destination we never write our
    /// own directories into.
    private var auxNote: String {
        AppEnvironment.librarySetting(for: destination.path) == nil
            ? "Weights the app downloads directly go back to its own folder, "
              + "which is where they live when the library is the shared cache."
            : "Weights the app downloads directly move too, into a "
              + "\u{201C}localmusic-aux\u{201D} folder beside the hub."
    }

    private var choices: some View {
        VStack(alignment: .leading, spacing: 7) {
            choice("move", "Move them to the new folder",
                   "Nothing is re-downloaded. On the same disk this is instant; "
                   + "onto a different disk it copies "
                   + "\(ByteFormat.gb(movingBytes)) and takes as long as that "
                   + "does.")
            choice("delete", "Delete them from the old folder",
                   "Frees \(ByteFormat.gb(movingBytes)) now. The new folder "
                   + "starts empty and every model you want is downloaded again.")
            choice("leave", "Leave them where they are",
                   "Nothing is moved or deleted. "
                   + "\(ByteFormat.gb(movingBytes)) stays where it is doing "
                   + "nothing, and the new folder starts empty.")
        }
    }

    private func choice(_ value: String, _ title: String,
                        _ detail: String) -> some View {
        let selected = disposition == value
        return Button {
            disposition = value
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? Bench.Palette.accent
                                              : Bench.Palette.textQuaternary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(Bench.Typo.body)
                        .foregroundStyle(Bench.Palette.textPrimary)
                    Text(detail)
                        .font(Bench.Typo.caption)
                        .foregroundStyle(Bench.Palette.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .benchCard(fill: selected ? Bench.Palette.accent.opacity(0.07)
                                  : Bench.Palette.well,
                   stroke: selected ? Bench.Palette.accent.opacity(0.30)
                                    : Bench.Palette.cardStrokeSoft)
    }

    /// Said once, plainly, under whichever option is selected: the engine has
    /// to come back before any of this is in effect.
    private var consequence: some View {
        Text("The engine restarts when this finishes — renders and downloads "
             + "must be stopped first.")
            .font(Bench.Typo.caption)
            .foregroundStyle(Bench.Palette.textFaint)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer()
            Button("Cancel") { dismiss() }
                .buttonStyle(.benchSecondary)
            // Two buttons rather than one with a conditional style: a
            // ButtonStyle is a type, not a value, so the destructive variant
            // cannot be swapped in on a boolean without erasing it.
            if hasModels && disposition == "delete" {
                Button(confirmLabel, action: confirm)
                    .buttonStyle(.bench(.destructive))
            } else {
                Button(confirmLabel, action: confirm)
                    .buttonStyle(BenchPrimaryButtonStyle(size: .compact,
                                                         glows: false))
            }
        }
    }

    private func confirm() {
        onConfirm(hasModels ? disposition : "leave")
        dismiss()
    }

    private var confirmLabel: String {
        guard hasModels else { return "Use this folder" }
        switch disposition {
        case "move": return "Move library"
        case "delete": return "Delete and switch"
        default: return "Switch and leave them"
        }
    }
}

/// Remove every model of ours from the library folder.
struct LibraryClearSheet: View {
    let info: LibraryInfo
    /// "all" or "partial" — see `BackendClient.clearLibrary(scope:)`.
    let onConfirm: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var typed = ""

    private var finished: [LibraryRepo] { info.repos.filter { !$0.isPartial } }
    /// The roots we own outright. "All" clears these too — they are ours
    /// without qualification, so a sheet that hid them would be under-stating
    /// what the button does.
    private var otherDirs: [LibraryRootDir] { info.clearableDirs }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("MODEL LIBRARY").eyebrow()
                Text("Delete every downloaded model")
                    .font(Bench.Typo.inspectorTitle)
                    .foregroundStyle(Bench.Palette.textPrimary)
                Text("Frees \(ByteFormat.gb(info.clearableBytes)), most of it "
                     + "in \(info.path). Each model has to be downloaded "
                     + "again before it can be used — for the largest that is "
                     + "a several-hour download.")
                    .font(Bench.Typo.secondary)
                    .foregroundStyle(Bench.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("WHAT GOES").eyebrow()
            LibraryRepoList(repos: info.repos)
            if !otherDirs.isEmpty {
                LibraryDirList(dirs: otherDirs)
            }
            if info.isDefault { SharedFolderWarning(verb: "delete") }
            Text("Your songs, parts and renders are somewhere else entirely and "
                 + "are not touched. Family runtimes are removed with the last "
                 + "model that needed them."
                 + (info.keptBytes > 0
                    ? " Your downloaded amp captures "
                      + "(\(ByteFormat.gb(info.keptBytes))) are kept — remove "
                      + "those from the capture picker in a re-amp action."
                    : ""))
                .font(Bench.Typo.caption)
                .foregroundStyle(Bench.Palette.textFaint)
                .fixedSize(horizontal: false, vertical: true)
            confirmField
            footer
        }
        .padding(20)
        .frame(width: 540)
        .background(Bench.Palette.panel)
    }

    /// Typed confirmation, because this is the one control in Settings that can
    /// destroy hours of downloading with a single click and has no undo.
    private var confirmField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Type DELETE to confirm")
                .font(Bench.Typo.caption)
                .foregroundStyle(Bench.Palette.textMuted)
            TextField("", text: $typed)
                .textFieldStyle(.plain)
                .tint(Bench.Palette.danger)
                .font(Bench.Typo.mono(12))
                .foregroundStyle(Bench.Palette.textPrimary)
                .padding(.horizontal, 11).padding(.vertical, 8)
                .background(RoundedRectangle(
                    cornerRadius: Bench.Metrics.Radius.control, style: .continuous)
                    .fill(Bench.Palette.windowBackground))
                .overlay(RoundedRectangle(
                    cornerRadius: Bench.Metrics.Radius.control, style: .continuous)
                    .strokeBorder(Bench.Palette.cardStroke, lineWidth: 1))
        }
    }

    private var footer: some View {
        let armed = typed.trimmingCharacters(in: .whitespaces).uppercased() == "DELETE"
        return HStack(spacing: 8) {
            if !finished.isEmpty && info.partialCount > 0 {
                Button("Only the unfinished ones") {
                    onConfirm("partial")
                    dismiss()
                }
                .buttonStyle(.bench(.quiet))
                .help("Removes \(ByteFormat.gb(info.partialBytes)) of "
                      + "interrupted downloads and keeps every finished model.")
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .buttonStyle(.benchSecondary)
            Button("Delete \(info.modelCount) model"
                   + (info.modelCount == 1 ? "" : "s")) {
                onConfirm("all")
                dismiss()
            }
            .buttonStyle(.bench(.destructive))
            .disabled(!armed)
            .opacity(armed ? 1 : 0.45)
        }
    }
}

/// What "Verify library" found: the models whose install marker is a claim the
/// bytes on disk no longer support.
struct LibraryVerifySheet: View {
    let report: LibraryVerifyReport

    @Environment(\.dismiss) private var dismiss

    private var problems: [LibraryVerifyFinding] { report.models.filter(\.isProblem) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("MODEL LIBRARY").eyebrow()
                Text(problems.isEmpty ? "Everything checks out"
                                      : "\(problems.count) model"
                                        + (problems.count == 1 ? "" : "s")
                                        + " need attention")
                    .font(Bench.Typo.inspectorTitle)
                    .foregroundStyle(Bench.Palette.textPrimary)
                Text("Checked \(report.models.count) downloaded model"
                     + (report.models.count == 1 ? "" : "s")
                     + " against the files actually in the library folder.")
                    .font(Bench.Typo.secondary)
                    .foregroundStyle(Bench.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if problems.isEmpty {
                Text("Every model that says it is downloaded has its weights "
                     + "where the engine expects them.")
                    .font(Bench.Typo.secondary)
                    .foregroundStyle(Bench.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(problems) { finding in
                            findingRow(finding)
                        }
                    }
                }
                .frame(maxHeight: 220)
                Text("Download each one again from Models to repair it — the "
                     + "row will offer to.")
                    .font(Bench.Typo.caption)
                    .foregroundStyle(Bench.Palette.textFaint)
            }
            if !report.partialRepos.isEmpty {
                Text("UNFINISHED DOWNLOADS").eyebrow()
                LibraryRepoList(repos: report.partialRepos, limit: 5)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(BenchPrimaryButtonStyle(size: .compact,
                                                         glows: false))
            }
        }
        .padding(20)
        .frame(width: 540)
        .background(Bench.Palette.panel)
    }

    private func findingRow(_ finding: LibraryVerifyFinding) -> some View {
        HStack(alignment: .top, spacing: 10) {
            StatusDot(color: finding.state == "missing" ? Bench.Palette.danger
                                                        : Bench.Palette.warn,
                      size: 6)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                Text(finding.displayName)
                    .font(Bench.Typo.bodyEmphasis)
                    .foregroundStyle(Bench.Palette.textPrimary)
                Text(finding.explanation)
                    .font(Bench.Typo.caption)
                    .foregroundStyle(Bench.Palette.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if finding.expectedBytes > 0 {
                Text("\(ByteFormat.gb(finding.actualBytes)) of "
                     + ByteFormat.gb(finding.expectedBytes))
                    .font(Bench.Typo.mono(11))
                    .foregroundStyle(Bench.Palette.textMuted)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .benchCard(fill: Bench.Palette.well)
    }
}

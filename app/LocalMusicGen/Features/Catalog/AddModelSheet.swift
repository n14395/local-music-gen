// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// Add an arbitrary Hugging Face model: inspect (dry run) → review → add.
///
/// The dry run is the point of the sheet. The engine refuses repos that need
/// remote code and can only guess a size and a family from the repo's files,
/// so what comes back is a *candidate* the user gets to look at before
/// anything is written to the catalog.
struct AddModelSheet: View {
    let catalog: ModelCatalogStore
    @Environment(\.dismiss) private var dismiss

    @State private var repoId = ""
    @State private var inspecting = false
    @State private var candidate: ModelInfo?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("ADD A MODEL").eyebrow()
                Text("From Hugging Face")
                    .font(Bench.Typo.inspectorTitle)
                    .foregroundStyle(Bench.Palette.textPrimary)
                Text("Supported: MusicGen-style models and diffusers audio "
                     + "pipelines (Stable Audio, AudioLDM 1/2, MusicLDM). "
                     + "Models requiring remote code are refused.")
                    .font(Bench.Typo.caption)
                    .foregroundStyle(Bench.Palette.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                TextField("org/model-name", text: $repoId)
                    .textFieldStyle(.plain)
                    .tint(Bench.Palette.accent)
                    .font(Bench.Typo.mono(12))
                    .foregroundStyle(Bench.Palette.textPrimary)
                    .padding(.horizontal, 11).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.control,
                                                 style: .continuous)
                        .fill(Bench.Palette.windowBackground))
                    .overlay(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.control,
                                              style: .continuous)
                        .strokeBorder(Bench.Palette.cardStroke, lineWidth: 1))
                    .onSubmit { inspect() }
                // `.disabled` alone is invisible here: `.benchSecondary` is a
                // custom ButtonStyle, and SwiftUI dims only its own styles for
                // the disabled environment. SPEC §4.5 wants inapplicable
                // controls at ~45%, so it is done by hand, as on "Add to
                // catalog" below.
                let canCheck = !repoId.trimmingCharacters(in: .whitespaces).isEmpty
                    && !inspecting
                Button("Check") { inspect() }
                    .buttonStyle(.benchSecondary)
                    .disabled(!canCheck)
                    .opacity(canCheck ? 1 : 0.45)
            }

            if inspecting {
                HStack(spacing: 8) {
                    BenchSpinner(size: 13)
                    Text("INSPECTING REPOSITORY…")
                        .font(Bench.Typo.badge)
                        .foregroundStyle(Bench.Palette.textMuted)
                }
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(Bench.Typo.secondary)
                    .foregroundStyle(Bench.Palette.dangerText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .benchCard(fill: Bench.Palette.danger.opacity(0.09),
                               stroke: Bench.Palette.danger.opacity(0.22))
            }
            if let model = candidate {
                candidateCard(model)
            }

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.benchSecondary)
                Button("Add to catalog") { add() }
                    .buttonStyle(BenchPrimaryButtonStyle(size: .compact, glows: false))
                    .disabled(candidate == nil)
                    .opacity(candidate == nil ? 0.45 : 1)
            }
        }
        .padding(20)
        .frame(width: 500)
        .background(Bench.Palette.panel)
    }

    private func candidateCard(_ model: ModelInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.displayName)
                .font(Bench.Typo.bodyEmphasis)
                .foregroundStyle(Bench.Palette.textPrimary)
            Text(model.description)
                .font(Bench.Typo.secondary)
                .foregroundStyle(Bench.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            FlowLayout(spacing: 6, rowSpacing: 6) {
                BenchBadge(ByteFormat.gb(model.sizeBytes).uppercased())
                BenchBadge(model.family.uppercased())
                if model.license.requiresHfToken {
                    BenchBadge("NEEDS HF TOKEN", tone: .warn)
                }
            }
            if let notes = model.notes {
                Text(notes)
                    .font(Bench.Typo.caption)
                    .foregroundStyle(Bench.Palette.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .benchCard()
    }

    private func inspect() {
        // Both buttons used to bail on a bare `guard` when the engine was down:
        // no spinner, no message, nothing. Say so instead of being inert.
        guard let client = catalog.client else {
            errorMessage = APIError.notConnected.localizedDescription
            return
        }
        let repo = repoId.trimmingCharacters(in: .whitespaces)
        inspecting = true
        errorMessage = nil
        candidate = nil
        Task {
            defer { inspecting = false }
            do {
                candidate = try await client.inspectModel(repoId: repo)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func add() {
        guard let client = catalog.client else {
            errorMessage = APIError.notConnected.localizedDescription
            return
        }
        guard let repo = candidate?.hfRepos.first?.repoId else {
            errorMessage = "That repository has nothing to download — press "
                + "Check again."
            return
        }
        Task {
            do {
                _ = try await client.addCustomModel(repoId: repo)
                await catalog.refresh()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

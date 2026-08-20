import AppKit
import SwiftUI

/// The `Settings` scene.
///
/// A separate window, so it keeps its own chrome and its own colour scheme —
/// but it is painted from the same tokens as the main window, because a
/// settings sheet that arrives in system grey reads as a different app bolted
/// onto this one. `Form(.grouped)` is not used for exactly that reason: it
/// draws its own materials, which the Bench palette has no light variant of.
struct SettingsView: View {
    let env: AppEnvironment

    @State private var pane: Pane = .general
    @State private var hfToken = ""
    @State private var tokenSaved = false

    enum Pane: Hashable { case general, engine }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch pane {
                    case .general:
                        huggingFaceCard
                        storageCard
                        engineSummaryCard
                    case .engine:
                        BackendDebugView(status: env.backendStatus,
                                         manager: env.backendManager,
                                         telemetry: env.telemetry)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
            }
        }
        .frame(width: 540, height: 520)
        .background(Bench.Palette.windowBackground)
        .preferredColorScheme(.dark)
        .onAppear {
            if let token = Keychain.get(account: "hf-token") {
                hfToken = token
                tokenSaved = true
            }
        }
    }

    // MARK: - Chrome

    private var header: some View {
        BenchTopBar(title: "Settings") {
            BenchSegmented(selection: $pane, options: [
                .init(value: .general, label: "General", detail: nil),
                .init(value: .engine, label: "Engine", detail: nil),
            ])
        }
    }

    private func card<Content: View>(_ title: String,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(title).eyebrow()
            content()
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .benchCard()
    }

    // MARK: - Hugging Face

    private var huggingFaceCard: some View {
        card("HUGGING FACE") {
            SecureField("Access token (hf_…)", text: $hfToken)
                .textFieldStyle(.plain)
                .font(Bench.Typo.mono(12))
                .foregroundStyle(Bench.Palette.textPrimary)
                .padding(.horizontal, 11).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.control,
                                             style: .continuous)
                    .fill(Bench.Palette.windowBackground))
                .overlay(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.control,
                                          style: .continuous)
                    .strokeBorder(Bench.Palette.cardStroke, lineWidth: 1))
            HStack(spacing: 8) {
                Button("Save token", action: saveToken)
                    .buttonStyle(.benchSecondary)
                Button("Remove", action: removeToken)
                    .buttonStyle(.bench(.quiet))
                if tokenSaved {
                    HStack(spacing: 6) {
                        StatusDot(color: Bench.Palette.ok, size: 6)
                        Text("SAVED TO KEYCHAIN")
                            .font(Bench.Typo.badge)
                            .foregroundStyle(Bench.Palette.ok)
                    }
                }
                Spacer(minLength: 0)
            }
            Text("Needed for gated models like Stable Audio Open. Stored only "
                 + "in your Keychain and handed to the local engine at launch.")
                .font(Bench.Typo.caption)
                .foregroundStyle(Bench.Palette.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func saveToken() {
        let trimmed = hfToken.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        Keychain.set(trimmed, account: "hf-token")
        Task {
            if let client = await env.backendManager.client {
                try? await client.setHFToken(trimmed)
            }
        }
        tokenSaved = true
        // Settings is its own window, so a Models screen open behind it is not
        // re-created by this. Tell the store, or every gated row goes on
        // reading HF TOKEN NEEDED until the user navigates away and back.
        env.catalog.refreshHFToken()
    }

    private func removeToken() {
        Keychain.delete(account: "hf-token")
        hfToken = ""
        tokenSaved = false
        env.catalog.refreshHFToken()
    }

    // MARK: - Storage

    private var storageCard: some View {
        card("STORAGE") {
            BenchInfoRow(label: "Data folder", labelWidth: 92) {
                Text(StoragePaths.root.path)
                    .font(Bench.Typo.mono(11))
                    .foregroundStyle(Bench.Palette.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([StoragePaths.root])
            }
            .buttonStyle(.benchSecondary)
        }
    }

    // MARK: - Engine summary

    private var engineSummaryCard: some View {
        card("ENGINE") {
            BenchInfoRow("Status", env.backendStatus.phase.label, labelWidth: 92)
            BenchInfoRow("Version", env.backendStatus.engineVersion ?? "—",
                         mono: true, labelWidth: 92)
            Button("Show engine details") { pane = .engine }
                .buttonStyle(.bench(.quiet))
        }
    }
}

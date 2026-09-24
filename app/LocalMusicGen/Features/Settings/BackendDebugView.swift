// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

/// What the engine is doing, in numbers — the panel you open when something is
/// wrong.
///
/// It now carries the machine readings too. The sidebar card shows one
/// smoothed line of them because that is all it has room for; when a render
/// falls over for want of memory, the question is which of `workingSetBytes`,
/// `workerBytes` and `acceleratorBytes` was actually near its ceiling, and
/// that needs them laid out separately. Every reading is optional and a
/// missing one prints "—" rather than a zero, because an engine build that
/// does not report GPU utilisation is not a GPU sitting at 0%.
struct BackendDebugView: View {
    let status: BackendStatusStore
    let manager: BackendProcessManager
    let telemetry: TelemetryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            section("PROCESS") {
                BenchInfoRow("State", status.phase.label, labelWidth: 96)
                if case .failed(let reason) = status.phase {
                    BenchInfoRow(label: "Reason", labelWidth: 96) {
                        Text(reason)
                            .font(Bench.Typo.secondary)
                            .foregroundStyle(Bench.Palette.dangerText)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                BenchInfoRow("Port", status.port.map(String.init) ?? "—",
                             mono: true, labelWidth: 96)
                BenchInfoRow("Version", status.engineVersion ?? "—",
                             mono: true, labelWidth: 96)
                BenchInfoRow(label: "Events", labelWidth: 96) {
                    HStack(spacing: 7) {
                        StatusDot(color: status.eventStreamConnected
                                      ? Bench.Palette.ok : Bench.Palette.warn,
                                  size: 6)
                        Text(status.eventStreamConnected ? "CONNECTED" : "DISCONNECTED")
                            .font(Bench.Typo.badge)
                            .foregroundStyle(Bench.Palette.textSecondary)
                    }
                }
                BenchInfoRow("Restarts", "\(status.restartCount)",
                             mono: true, labelWidth: 96)
                if let modelId = status.workerModelId {
                    BenchInfoRow(label: "Worker", labelWidth: 96) {
                        HStack(spacing: 10) {
                            Text(modelId + (status.workerModelState
                                    .map { " · \($0)" } ?? ""))
                                .font(Bench.Typo.mono(12))
                                .foregroundStyle(Bench.Palette.textPrimary)
                            // The eject that used to live in the titlebar and
                            // was lost in the sidebar-footer refactor. The
                            // engine 409s while a job runs; the refusal is
                            // echoed into the log tail below rather than
                            // swallowed.
                            Button("Unload") { unloadWorker() }
                                .buttonStyle(.bench(.quiet))
                                .disabled(status.workerModelState == "loading")
                                .help("Free the resident model's memory now")
                        }
                    }
                }
            }

            section("MACHINE") {
                BenchInfoRow("Model", telemetry.machine ?? "—",
                             mono: true, labelWidth: 96)
                BenchInfoRow("Accelerator", acceleratorLine, mono: true,
                             labelWidth: 96)
                BenchInfoRow("Memory", memoryLine, mono: true, labelWidth: 96)
                if let fraction = telemetry.memoryFraction {
                    BenchProgressBar(fraction: fraction,
                                     tint: fraction > 0.9 ? Bench.Palette.danger
                                                          : Bench.Palette.ok)
                        .padding(.leading, 108)
                }
                BenchInfoRow("GPU", telemetry.gpuPercent
                                .map { "\(Int($0.rounded()))% (DEVICE-WIDE)" } ?? "—",
                             mono: true, labelWidth: 96)
                BenchInfoRow("On accelerator", telemetry.acceleratorBytes
                                .map { "\(TelemetryStore.gigabytes($0)) GB" } ?? "—",
                             mono: true, labelWidth: 96)
                BenchInfoRow("Free disk", telemetry.freeDiskBytes
                                .map { "\(TelemetryStore.gigabytes($0)) GB" } ?? "—",
                             mono: true, labelWidth: 96)
                BenchInfoRow("Library disk", telemetry.libraryFreeDiskBytes
                                .map { "\(TelemetryStore.gigabytes($0)) GB" } ?? "—",
                             mono: true, labelWidth: 96)
            }

            section("ENGINE LOG") {
                ScrollView {
                    Text(status.stderrTail.suffix(50).joined(separator: "\n"))
                        .font(Bench.Typo.mono(11))
                        .foregroundStyle(Bench.Palette.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(10)
                }
                .frame(height: 150)
                .background(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.control,
                                             style: .continuous)
                    .fill(Bench.Palette.well))
                .overlay(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.control,
                                          style: .continuous)
                    .strokeBorder(Bench.Palette.cardStrokeSoft, lineWidth: 1))
                HStack(spacing: 8) {
                    Button("Restart engine") { Task { await manager.restart() } }
                        .buttonStyle(.benchSecondary)
                    Button("Open logs") {
                        NSWorkspace.shared.open(StoragePaths.engineLogs)
                    }
                    .buttonStyle(.bench(.quiet))
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func unloadWorker() {
        Task {
            guard let client = await manager.client else { return }
            do {
                try await client.unloadWorker()
            } catch {
                status.appendStderr(
                    "[unload] refused: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Readings

    /// `MLX · APPLE M3 MAX · 36.0 GB WORKING SET`, dropping whatever the
    /// engine did not report rather than guessing "Metal".
    private var acceleratorLine: String {
        var parts: [String] = []
        if let backend = telemetry.backend {
            parts.append(TelemetryStore.backendLabel(backend).uppercased())
        }
        if let name = telemetry.acceleratorName { parts.append(name.uppercased()) }
        if let workingSet = telemetry.workingSetBytes {
            parts.append("\(TelemetryStore.gigabytes(workingSet)) GB WORKING SET")
        }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    /// Worker footprint over the ceiling it can actually reach, plus the
    /// machine's physical RAM for context — the three are routinely different
    /// numbers and conflating them is how a memory bug gets misdiagnosed.
    private var memoryLine: String {
        guard let ceiling = telemetry.memoryCeilingBytes else { return "—" }
        let used = telemetry.workerBytes ?? telemetry.acceleratorBytes
        let usedText = used.map { TelemetryStore.gigabytes($0) } ?? "—"
        var line = "\(usedText) / \(TelemetryStore.gigabytes(ceiling)) GB"
        if let ram = telemetry.ramBytes, ram != ceiling {
            line += " · \(TelemetryStore.gigabytes(ram)) GB INSTALLED"
        }
        return line
    }

    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).eyebrow()
            content()
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .benchCard()
    }
}

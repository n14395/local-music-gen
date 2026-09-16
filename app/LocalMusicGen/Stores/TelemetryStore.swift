import Foundation
import Observation

/// What the sidebar card knows about the machine.
///
/// The design puts a live readout in the same corner on every screen —
/// `Metal · 2.2 / 36 GB` when idle, `GPU 92% · 11.8 / 36 GB` while rendering.
/// Every field here is optional, and the card omits a line rather than
/// inventing one: an engine build that reports no accelerator gets no
/// accelerator line, not a guessed "Metal".
///
/// One honesty note that the UI copy must respect: `gpuPercent` is **device
/// wide**. Apple Silicon exposes no per-process GPU utilisation without root,
/// so this number includes anything else using the GPU. It is labelled "GPU",
/// never "this job".
@MainActor @Observable
final class TelemetryStore {
    private(set) var acceleratorName: String?
    private(set) var backend: String?
    private(set) var workingSetBytes: Int64?
    private(set) var gpuPercent: Double?
    private(set) var workerBytes: Int64?
    private(set) var acceleratorBytes: Int64?
    private(set) var ramBytes: Int64?
    private(set) var freeDiskBytes: Int64?
    /// The library volume's free space — the figure for "will this model
    /// fit". Falls back to `freeDiskBytes` against an engine (or the stub)
    /// that does not report one, which was the only figure there used to be
    /// and is the wrong disk whenever the library has been relocated.
    private(set) var libraryFreeDiskBytes: Int64?
    private(set) var machine: String?

    /// Each assignment gated.
    ///
    /// This is polled every three seconds for the whole session — every three
    /// seconds *while rendering*, which is when the UI is busiest — and most
    /// of what it carries never moves at all: the machine's name, its RAM, the
    /// accelerator, its backend. Assigning them unconditionally republished
    /// nine observable properties on every poll, and the sidebar's engine card
    /// and the transport strip read them, so an idle machine redrew its
    /// chrome twenty times a minute to say nothing had changed.
    func apply(_ system: SystemInfo) {
        set(&ramBytes, system.ramBytes)
        set(&freeDiskBytes, system.freeDiskBytes)
        set(&libraryFreeDiskBytes,
            system.libraryFreeDiskBytes ?? system.freeDiskBytes)
        set(&machine, system.machine)
        set(&acceleratorName, system.accelerator?.name)
        set(&backend, system.accelerator?.backend)
        set(&workingSetBytes, system.accelerator?.workingSetBytes)
        set(&gpuPercent, system.usage?.gpuPercent)
        set(&acceleratorBytes, system.usage?.acceleratorBytes)
        // The memory guard has always carried the worker's bytes; prefer the
        // richer `usage` reading when the engine sends it.
        set(&workerBytes,
            system.usage?.workerBytes ?? system.memoryGuard?.workerBytes)
    }

    /// The three readings the engine pushes on its own, without a poll.
    ///
    /// Same gating as `apply`, and deliberately narrower: a telemetry frame
    /// carries only what moves, so nothing here may clear a field the poll
    /// filled in — assigning the static facts from an event that does not
    /// carry them would blank the sidebar every two seconds.
    func applyUsage(_ usage: SystemInfo.Usage) {
        set(&gpuPercent, usage.gpuPercent)
        set(&acceleratorBytes, usage.acceleratorBytes)
        if let bytes = usage.workerBytes { set(&workerBytes, bytes) }
    }

    private func set<T: Equatable>(_ stored: inout T, _ next: T) {
        if stored != next { stored = next }
    }

    /// Memory the engine is using, over the ceiling it can actually reach.
    /// Falls back to physical RAM when Metal's working set is unknown.
    var memoryCeilingBytes: Int64? { workingSetBytes ?? ramBytes }

    var memoryFraction: Double? {
        guard let used = workerBytes ?? acceleratorBytes,
              let ceiling = memoryCeilingBytes, ceiling > 0 else { return nil }
        return Double(used) / Double(ceiling)
    }

    /// `Metal · 2.2 / 36 GB`, or just `2.2 / 36 GB` when the backend is
    /// unknown, or nil when there is nothing true to say.
    var memoryLine: String? {
        guard let ceiling = memoryCeilingBytes else { return nil }
        let used = workerBytes ?? acceleratorBytes
        let usedText = used.map { Self.gigabytes($0) } ?? "—"
        let line = "\(usedText) / \(Self.gigabytes(ceiling)) GB"
        guard let backend else { return line }
        return "\(Self.backendLabel(backend)) · \(line)"
    }

    /// `GPU 92% · 11.8 / 36 GB` — the rendering variant.
    var busyLine: String? {
        guard let ceiling = memoryCeilingBytes else { return nil }
        let used = workerBytes ?? acceleratorBytes
        let usedText = used.map { Self.gigabytes($0) } ?? "—"
        let memory = "\(usedText) / \(Self.gigabytes(ceiling)) GB"
        guard let gpuPercent else { return memory }
        return "GPU \(Int(gpuPercent.rounded()))% · \(memory)"
    }

    // Pure formatting, called from queue rows and download rows that are not
    // themselves on the main actor.
    nonisolated static func backendLabel(_ raw: String) -> String {
        switch raw.lowercased() {
        case "mlx": "MLX"
        case "metal", "mps": "Metal"
        case "cpu": "CPU"
        default: raw.uppercased()
        }
    }

    /// One decimal place, no unit — the unit is printed once at the end of the
    /// line (`2.2 / 36 GB`), which is how the design writes it.
    nonisolated static func gigabytes(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_000_000_000
        // A round figure keeps no decimal: memory ceilings and disk sizes are
        // usually whole numbers, and "36.0 GB" reads like a measurement when
        // it is really just 36.
        if gb >= 100 || gb == gb.rounded() { return String(format: "%.0f", gb) }
        return String(format: "%.1f", gb)
    }
}

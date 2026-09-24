// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Observation

/// Peak caches shared across every clip that draws the same material.
///
/// `BenchWaveformLoader` loads its own peaks, which is right for one strip per row and
/// wrong for a timeline: forty clips over six sources would open six files
/// forty times. Each material gets ONE handle, and because the handle is itself
/// observable, a late-arriving load redraws only the clips that use it — a
/// shared dictionary would invalidate every clip on screen.
@MainActor @Observable
final class PeaksStore {
    @MainActor @Observable
    final class Handle {
        var peaks: WaveformExtractor.Peaks?
        var failed = false
    }

    /// `@ObservationIgnored` because `handle(id:…)` is called from inside a
    /// view body — a timeline of forty clips asks for one per clip — and it
    /// inserts on first ask. An observed dictionary written during body
    /// evaluation is the "modifying state during view update" trap: the
    /// insert would invalidate the body that caused it. Nothing observes this
    /// dictionary anyway; the *handles* are what redraw a clip, and they are
    /// observable in their own right, which is the whole design.
    @ObservationIgnored private var handles: [String: Handle] = [:]

    /// The handle for a material, starting the load on first ask.
    func handle(id: String, audioURL: URL, cacheURL: URL) -> Handle {
        if let existing = handles[id] { return existing }
        let handle = Handle()
        handles[id] = handle
        Task { [weak handle] in
            let peaks = try? await WaveformExtractor.shared
                .peaks(for: audioURL, cacheURL: cacheURL)
            guard let handle else { return }
            handle.peaks = peaks
            handle.failed = peaks == nil
        }
        return handle
    }

    /// Drop handles for materials no longer on the bench.
    func retain(ids: Set<String>) {
        handles = handles.filter { ids.contains($0.key) }
    }
}

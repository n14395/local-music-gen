// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Observation

/// How much disk the library is using, for the Models screen's storage card.
///
/// There is no size column on `song` or `part`, and adding one would need a
/// migration plus a backfill for every existing row — so this walks the two
/// audio directories instead. That is slow enough to be worth doing off the
/// main actor and caching, and cheap enough that a refresh on entering the
/// Models screen is plenty: the number is a rough "what is this costing me",
/// not an accounting figure.
@MainActor @Observable
final class StorageStore {
    private(set) var audioBytes: Int64 = 0
    private(set) var refreshedAt: Date?

    private var inFlight: Task<Void, Never>?

    /// Recompute unless a recent figure is already in hand.
    func refresh(maxAge: TimeInterval = 60) {
        if let refreshedAt, Date().timeIntervalSince(refreshedAt) < maxAge { return }
        guard inFlight == nil else { return }
        let directories = [StoragePaths.libraryAudio, StoragePaths.libraryParts]
        inFlight = Task { [weak self] in
            let total = await Task.detached(priority: .utility) {
                directories.reduce(0) { $0 + Self.directoryBytes($1) }
            }.value
            guard let self else { return }
            self.audioBytes = total
            self.refreshedAt = Date()
            self.inFlight = nil
        }
    }

    /// Sum of allocated sizes under `url`, recursively. Errors are swallowed:
    /// a missing directory means zero, which is the truth on a fresh install.
    nonisolated static func directoryBytes(_ url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: keys)
            // Allocated size, not logical: this is a question about the disk.
            let bytes = values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0
            total += Int64(bytes)
        }
        return total
    }
}

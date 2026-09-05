import Foundation

/// Housekeeping for the app-owned file piles that only ever grew: the daily
/// engine stderr logs and the Editor's stashed originals. Selection is pure
/// and separately testable; the deleting wrappers stay thin.
enum FilePruning {
    struct Entry {
        var url: URL
        var modifiedAt: Date
        var bytes: Int64
    }

    /// Which of `entries` are older than `days` days. 0 disables.
    static func expired(_ entries: [Entry], olderThanDays days: Int,
                        now: Date = Date()) -> [URL] {
        guard days > 0 else { return [] }
        let cutoff = now.addingTimeInterval(-Double(days) * 86400)
        return entries.filter { $0.modifiedAt < cutoff }.map(\.url)
    }

    /// Which of `entries` must go, oldest first, for the rest to fit
    /// `capBytes`. 0 disables. The newest files always survive — the cap
    /// trims history, it does not empty the drawer.
    static func overflow(_ entries: [Entry], capBytes: Int64) -> [URL] {
        guard capBytes > 0 else { return [] }
        var total = entries.reduce(Int64(0)) { $0 + $1.bytes }
        guard total > capBytes else { return [] }
        var evicted: [URL] = []
        // `dropLast` is the guarantee: however small the cap, the newest
        // file is never the one evicted to satisfy it.
        for entry in entries.sorted(by: { $0.modifiedAt < $1.modifiedAt })
            .dropLast() {
            guard total > capBytes else { break }
            evicted.append(entry.url)
            total -= entry.bytes
        }
        return evicted
    }

    /// The directory's immediate files, with the attributes selection needs.
    static func entries(in dir: URL) -> [Entry] {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey,
                                         .totalFileAllocatedSizeKey,
                                         .isRegularFileKey]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles])) ?? []
        return files.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { return nil }
            return Entry(url: url,
                         modifiedAt: values.contentModificationDate ?? .distantPast,
                         bytes: Int64(values.totalFileAllocatedSize ?? 0))
        }
    }

    static func pruneByAge(in dir: URL, olderThanDays days: Int) {
        for url in expired(entries(in: dir), olderThanDays: days) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func capBySize(in dir: URL, capBytes: Int64) {
        for url in overflow(entries(in: dir), capBytes: capBytes) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

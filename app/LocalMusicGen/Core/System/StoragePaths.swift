import Foundation

/// Single authority for every on-disk location. See docs/api-contract.md §7.
enum StoragePaths {
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory,
                                 in: .userDomainMask)[0]
            .appendingPathComponent("LocalMusicGen", isDirectory: true)
    }

    // App-owned
    static var database: URL { root.appendingPathComponent("Database/library.sqlite") }
    static var libraryAudio: URL { root.appendingPathComponent("Library/Audio", isDirectory: true) }
    static var libraryParts: URL { root.appendingPathComponent("Library/Parts", isDirectory: true) }
    static var libraryWaveforms: URL { root.appendingPathComponent("Library/Waveforms", isDirectory: true) }
    static var libraryBackups: URL { root.appendingPathComponent("Library/Backups", isDirectory: true) }
    static var appLogs: URL { root.appendingPathComponent("Logs", isDirectory: true) }

    // Engine-owned (we create the roots; the engine populates them)
    static var engineData: URL { root }
    static var engineOutputs: URL { root.appendingPathComponent("Outputs", isDirectory: true) }
    static var engineLogs: URL { root.appendingPathComponent("Backend/logs", isDirectory: true) }
    static var enginePidFile: URL { root.appendingPathComponent("Backend/backend.pid") }
    static var engineHandshake: URL { root.appendingPathComponent("Backend/handshake.json") }

    /// The backup file name for a track that has none recorded yet — the
    /// pre-v6 derivation, kept so old rows still resolve.
    static func backupName(id: String, fileName: String) -> String {
        let ext = (fileName as NSString).pathExtension
        return id + "." + (ext.isEmpty ? "wav" : ext)
    }

    /// Every stashed original belonging to this id, whatever it is called.
    /// Deletion matches on the id prefix rather than on a recomputed name,
    /// so a rename can never leave one behind.
    /// The whole backups folder, grouped by the id each file belongs to.
    ///
    /// `backups(forId:)` lists the directory on every call, and the delete
    /// path calls it once per part *and* once per song — so removing twenty
    /// tracks with six parts each listed the folder a hundred and forty
    /// times. Deleting a batch lists it once and looks ids up in here.
    ///
    /// The grouping key is the filename up to its first `.`, which is the
    /// same partition `backups(forId:)` produces by prefix-matching.
    static func backupIndex() -> [String: [URL]] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: libraryBackups, includingPropertiesForKeys: nil)) ?? []
        return Dictionary(grouping: files) { url in
            let name = url.lastPathComponent
            return name.split(separator: ".", maxSplits: 1)
                .first.map(String.init) ?? name
        }
    }

    static func backups(forId id: String) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: libraryBackups, includingPropertiesForKeys: nil)) ?? []
        return files.filter {
            $0.lastPathComponent == id
                || $0.lastPathComponent.hasPrefix(id + ".")
        }
    }

    static func ensureDirectories() throws {
        let dirs = [database.deletingLastPathComponent(), libraryAudio,
                    libraryParts, libraryWaveforms, libraryBackups, appLogs,
                    engineOutputs, engineLogs]
        for dir in dirs {
            try FileManager.default.createDirectory(at: dir,
                                                    withIntermediateDirectories: true)
        }
    }
}

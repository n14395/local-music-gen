import Foundation

/// Single authority for every on-disk location. See docs/api-contract.md §7.
enum StoragePaths {
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory,
                                 in: .userDomainMask)[0]
            .appendingPathComponent("LocalMusic", isDirectory: true)
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

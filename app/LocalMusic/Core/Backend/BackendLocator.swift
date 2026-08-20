import Foundation

/// How to reach the engine. Resolution order (docs in README):
/// 1. LOCALMUSIC_BACKEND_HANDSHAKE (+ LOCALMUSIC_BACKEND_TOKEN) — attach to a
///    manually run engine/stub; the primary dev loop. No spawning, no supervision.
/// 2. LOCALMUSIC_BACKEND_CMD — spawn this shell command as the engine (dev spawn mode,
///    e.g. the stub's run-stub.sh).
/// 3. Contents/Resources/backend/bin/local-music-backend — the bundled engine.
enum BackendLaunchMode {
    case attach(handshake: URL, token: String)
    case spawn(command: [String])

    static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment)
        -> BackendLaunchMode?
    {
        if let path = environment["LOCALMUSIC_BACKEND_HANDSHAKE"] {
            let token = environment["LOCALMUSIC_BACKEND_TOKEN"] ?? "localmusic-dev"
            return .attach(handshake: URL(fileURLWithPath: path), token: token)
        }
        if let cmd = environment["LOCALMUSIC_BACKEND_CMD"] {
            // "$@" forwards the manager's appended engine args to the command.
            return .spawn(command: ["/bin/bash", "-lc", "\(cmd) \"$@\"",
                                    "local-music-engine"])
        }
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("backend/bin/local-music-engine"),
            FileManager.default.isExecutableFile(atPath: bundled.path)
        {
            return .spawn(command: [bundled.path])
        }
        return nil
    }
}

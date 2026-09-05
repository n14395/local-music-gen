import Foundation

/// How to reach the engine. Resolution order (docs in README):
/// 1. LOCALMUSICGEN_BACKEND_HANDSHAKE (+ LOCALMUSICGEN_BACKEND_TOKEN) — attach to a
///    manually run engine/stub; the primary dev loop. No spawning, no supervision.
/// 2. LOCALMUSICGEN_BACKEND_CMD — spawn this shell command as the engine (dev spawn mode,
///    e.g. the stub's run-stub.sh).
/// 3. Contents/Resources/backend/bin/local-music-gen-engine — the bundled engine.
enum BackendLaunchMode {
    case attach(handshake: URL, token: String)
    case spawn(command: [String])

    static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment)
        -> BackendLaunchMode?
    {
        if let path = environment["LOCALMUSICGEN_BACKEND_HANDSHAKE"] {
            let token = environment["LOCALMUSICGEN_BACKEND_TOKEN"] ?? "localmusicgen-dev"
            return .attach(handshake: URL(fileURLWithPath: path), token: token)
        }
        if let cmd = environment["LOCALMUSICGEN_BACKEND_CMD"] {
            // "$@" forwards the manager's appended engine args to the command.
            return .spawn(command: ["/bin/bash", "-lc", "\(cmd) \"$@\"",
                                    "local-music-gen-engine"])
        }
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("backend/bin/local-music-gen-engine"),
            FileManager.default.isExecutableFile(atPath: bundled.path)
        {
            return .spawn(command: [bundled.path])
        }
        return nil
    }
}

import Foundation

/// Everything Settings can say about how the engine process is launched —
/// the env vars and CLI flags of `docs/api-contract.md` §engine invocation.
///
/// A value, deliberately: the process manager records the config it actually
/// launched with, Settings compares that against what it would launch with
/// *now*, and the difference is exactly the "applies after an engine restart"
/// banner. Every field is always emitted (mirroring the engine's own
/// defaults) so two configs differ only when a knob really moved.
struct EngineLaunchConfig: Equatable, Sendable {
    /// Accelerator-memory warning level in bytes; 0 disables the guard.
    var memGuardBytes: Int
    /// Warm slots for small models (`LOCALMUSICGEN_SMALL_WARM_SLOTS`).
    var smallWarmSlots: Int
    /// Idle seconds before a warm small worker is reaped; 0 = drop when idle.
    var smallWarmTTLS: Int
    /// The size below which a model runs in the transient slot.
    var smallModelBytes: Int
    var maxActiveDownloads: Int
    /// Model-weights cache root; nil = the engine's own resolution
    /// (inherited `HF_HOME`, else `~/.cache/huggingface`).
    var hfHome: String?
    /// Root for weights the adapters fetch themselves; nil = the engine's own
    /// resolution (`<data dir>/aux-cache`). Moves with `hfHome`, but not to
    /// the same place — see the engine's `aux_destination`.
    var auxCache: String?
    /// uvicorn log level: "info" | "debug" | "warning".
    var logLevel: String
    /// Days the engine keeps finished jobs' Outputs dirs; 0 = forever.
    var outputsRetentionDays: Int

    var environment: [String: String] {
        var env = [
            "LOCALMUSICGEN_MEM_GUARD_BYTES": String(memGuardBytes),
            "LOCALMUSICGEN_SMALL_WARM_SLOTS": String(smallWarmSlots),
            "LOCALMUSICGEN_SMALL_WARM_TTL_S": String(smallWarmTTLS),
            "LOCALMUSICGEN_SMALL_MODEL_BYTES": String(smallModelBytes),
            "LOCALMUSICGEN_MAX_ACTIVE_DOWNLOADS": String(maxActiveDownloads),
            "LOCALMUSICGEN_OUTPUTS_RETENTION_DAYS": String(outputsRetentionDays),
        ]
        if let hfHome { env["HF_HOME"] = hfHome }
        if let auxCache { env["LOCALMUSICGEN_AUX_CACHE"] = auxCache }
        return env
    }

    var arguments: [String] { ["--log-level", logLevel] }
}

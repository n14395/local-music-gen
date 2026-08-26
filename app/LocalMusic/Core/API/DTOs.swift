import Foundation

// Codable mirrors of docs/api-contract.md. Field names follow the wire format via
// a snake_case decoding strategy configured in BackendClient.

// MARK: - Heterogeneous JSON values (param defaults / values)

enum JSONValue: Codable, Equatable, Sendable {
    case int(Int)
    case double(Double)
    case bool(Bool)
    case string(String)
    case null
    // Containers exist for DECODING nested engine values (e.g. task-result
    // meta like {"tracks": {"melody": 4}}). Job params stay flat scalars on
    // the wire — structured params ride "json"-type ParamSpecs as strings.
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let i = try? c.decode(Int.self) { self = .int(i) }
        else if let d = try? c.decode(Double.self) { self = .double(d) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription:
                "unsupported JSON value for a param")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .null: try c.encodeNil()
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    var doubleValue: Double? {
        switch self {
        case .int(let v): Double(v)
        case .double(let v): v
        default: nil
        }
    }

    // The rest of the readers, for the free-form `result.meta` dictionaries
    // the engine returns from assist and plan jobs. Deliberately lenient in
    // one direction only — a double that happens to be whole reads as an int,
    // because a language model writing JSON emits `8` and `8.0`
    // interchangeably — and strict everywhere else, so a wrong-typed field
    // reads as absent rather than as a coerced value nobody intended.

    var intValue: Int? {
        switch self {
        case .int(let v): v
        case .double(let v): v.rounded() == v ? Int(v) : nil
        default: nil
        }
    }

    var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let v) = self { return v }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let v) = self { return v }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let v) = self { return v }
        return nil
    }
}

// MARK: - Health & system

struct HealthResponse: Codable, Sendable {
    let status: String
    let version: String
    let uptimeS: Double
}

struct SystemInfo: Codable, Sendable {
    let ramBytes: Int64
    let freeDiskBytes: Int64
    let machine: String
    let warmFamily: String?
    let warmModelId: String?
    /// The small side-worker's model. The engine and the stub have always sent
    /// this; there was simply no field here, so it was silently dropped.
    let transientModelId: String?
    let pinnedModelId: String?
    let activeJobId: String?
    /// The queue hold (contract §5.7). Optional so an older engine still
    /// decodes. It can be true while `activeJobId` is set: a hold stops the
    /// queue starting work, and never interrupts work already running.
    let queueHeld: Bool?
    let memoryGuard: MemoryGuard?
    let engineVersions: [String: String]

    /// Which accelerator the engine is actually using. Optional: an engine
    /// that does not report it leaves the sidebar readout off rather than
    /// guessing "Metal".
    let accelerator: Accelerator?
    /// Live resource usage. Also optional, and each field independently so —
    /// GPU utilisation in particular is unavailable on some configurations.
    let usage: Usage?

    struct MemoryGuard: Codable, Sendable {
        let limitBytes: Int64
        let workerBytes: Int64?
    }

    struct Accelerator: Codable, Sendable {
        let name: String?
        /// `mlx` | `metal` | `cpu`
        let backend: String?
        /// Metal's recommended working set, which is the real ceiling for a
        /// model — always well below `hw.memsize`.
        let workingSetBytes: Int64?
    }

    struct Usage: Codable, Sendable {
        /// **Device-wide**, not per-process: Apple Silicon does not expose
        /// per-process GPU utilisation without root. Label it accordingly.
        let gpuPercent: Double?
        /// Physical footprint of the live worker process.
        let workerBytes: Int64?
        /// Bytes the worker has allocated on the accelerator.
        let acceleratorBytes: Int64?
    }
}

// MARK: - Models

struct ModelInfo: Codable, Identifiable, Sendable {
    let id: String
    let family: String
    let featured: Bool?
    let format: String?
    let variantOf: String?
    /// What the model is FOR, in app terms ("Songs with vocals", "Stem
    /// separation", …). Optional so an engine that predates tags still
    /// decodes; the app renders whatever strings arrive and never maps them.
    let tags: [String]?
    let displayName: String
    let description: String
    let hfRepos: [HFRepo]
    let sizeBytes: Int64
    let installState: InstallState
    let installedBytes: Int64
    /// Whether this model's *family runtime* — the adapter's package
    /// environment — is installed (contract §4.1). Weights alone are not
    /// enough to run anything: the runtime is a torch-sized install of its own,
    /// and until this reads `installed` the first generation would stop and
    /// build it. Optional so an engine that predates the field decodes; absent
    /// ⇒ treated as present, because an engine that cannot say must not have
    /// every model accused of a missing runtime.
    let runtimeState: RuntimeState?
    let pinned: Bool?
    let capabilities: Capabilities
    let requirements: Requirements
    let license: LicenseInfo
    let notes: String?

    var isFeatured: Bool { featured ?? false }
    var isPinned: Bool { pinned ?? false }
    var modelTags: [String] { tags ?? [] }
    var runtime: RuntimeState { runtimeState ?? .installed }

    /// Defaults for every optional field, for the same reason `Capabilities`
    /// has one: the contract grows by adding optional keys, and a memberwise
    /// initialiser turns each addition into a breaking change for every
    /// fixture that builds a model.
    init(id: String, family: String, featured: Bool? = nil, format: String? = nil,
         variantOf: String? = nil, tags: [String]? = nil, displayName: String,
         description: String, hfRepos: [HFRepo], sizeBytes: Int64,
         installState: InstallState, installedBytes: Int64,
         runtimeState: RuntimeState? = nil, pinned: Bool? = nil,
         capabilities: Capabilities, requirements: Requirements,
         license: LicenseInfo, notes: String? = nil) {
        self.id = id
        self.family = family
        self.featured = featured
        self.format = format
        self.variantOf = variantOf
        self.tags = tags
        self.displayName = displayName
        self.description = description
        self.hfRepos = hfRepos
        self.sizeBytes = sizeBytes
        self.installState = installState
        self.installedBytes = installedBytes
        self.runtimeState = runtimeState
        self.pinned = pinned
        self.capabilities = capabilities
        self.requirements = requirements
        self.license = license
        self.notes = notes
    }
}

enum InstallState: String, Codable, Sendable {
    case notInstalled = "not_installed"
    case downloading
    case partial
    case installed
}

/// The family runtime's side of "is this model ready to run" (contract §4.1).
/// A family property reported per model: two entries of one family are ready or
/// not together, and the second one costs nothing once the first has paid.
enum RuntimeState: String, Codable, Sendable {
    case notInstalled = "not_installed"
    /// Being built right now — by this model's own runtime install, or by the
    /// provisioning step of any download of the same family.
    case installing
    case installed
}

struct HFRepo: Codable, Sendable {
    let repoId: String
    let gated: Bool
}

struct Capabilities: Codable, Sendable {
    let supportsLyrics: Bool
    let instrumentalOnly: Bool
    let duration: DurationSpec
    let sampleRate: Int
    let outputsPerJobMax: Int
    let estSecondsPerAudioSecond: Double
    let lyricsTags: [String]?
    let lyricsHint: String?
    /// Whether the model REFUSES a bare prompt with no lyrics — SongBloom
    /// sings a structured lyric sheet and has nothing to do without one.
    /// Distinct from `supportsLyrics`, which the instrumental-capable
    /// singers (ACE-Step, YuE) also set. Absent ⇒ lyrics are optional.
    let requiresLyrics: Bool?
    /// Job tasks the model accepts; absent ⇒ ["generate"] (contract §5.4).
    let tasks: [String]?
    /// Rough processing-time / input-duration ratio for task models (estimates only).
    let estRealtimeFactor: Double?
    /// Whether this model can publish partial audio while it renders
    /// (contract 5.6). Declared per model, not per family: only some adapters
    /// can decode audio the model has genuinely produced part-way through, and
    /// the MLX and transformers builds of MusicGen differ on it. Absent ⇒ no —
    /// the app offers no streaming controls, and submitting `preview` would be
    /// refused.
    let supportsPreview: Bool?
    /// The stages this model's adapter passes through, declared up front so the
    /// renderer can draw the whole pipeline — with the stages it has not
    /// reached yet greyed out — before the job starts. A progress event alone
    /// could never do that. Absent ⇒ one indeterminate bar.
    let pipeline: [PipelineStage]?
    let params: [ParamSpec]

    var supportedTasks: [String] { tasks ?? ["generate"] }
    var canPreview: Bool { supportsPreview ?? false }

    /// True when the model cannot run from a bare prompt: it requires an
    /// audio input (a non-nullable audio param). Anything that auto-runs a
    /// roster with only a prompt must skip these — the job would only fail
    /// at the adapter.
    var needsSourceAudio: Bool {
        params.contains { $0.type == .audio && !$0.nullable }
    }

    /// True when the model cannot run from a prompt alone, for any reason —
    /// the roster gate anything auto-running a bare prompt should consult.
    var needsLyrics: Bool { requiresLyrics ?? false }

    /// Defaults for every optional field, for the same reason `ParamSpec` has
    /// one: the contract grows by adding optional capabilities, and a
    /// memberwise initialiser turns each addition into a breaking change for
    /// every fixture in the test suite.
    init(supportsLyrics: Bool, instrumentalOnly: Bool, duration: DurationSpec,
         sampleRate: Int, outputsPerJobMax: Int, estSecondsPerAudioSecond: Double,
         lyricsTags: [String]? = nil, lyricsHint: String? = nil,
         requiresLyrics: Bool? = nil,
         tasks: [String]? = nil, estRealtimeFactor: Double? = nil,
         supportsPreview: Bool? = nil,
         pipeline: [PipelineStage]? = nil, params: [ParamSpec]) {
        self.supportsLyrics = supportsLyrics
        self.instrumentalOnly = instrumentalOnly
        self.duration = duration
        self.sampleRate = sampleRate
        self.outputsPerJobMax = outputsPerJobMax
        self.estSecondsPerAudioSecond = estSecondsPerAudioSecond
        self.lyricsTags = lyricsTags
        self.lyricsHint = lyricsHint
        self.requiresLyrics = requiresLyrics
        self.tasks = tasks
        self.estRealtimeFactor = estRealtimeFactor
        self.supportsPreview = supportsPreview
        self.pipeline = pipeline
        self.params = params
    }
}

struct PipelineStage: Codable, Identifiable, Sendable {
    let id: String
    let label: String
    /// May be skipped for a given job (e.g. LM reasoning when the model's
    /// reasoning toggle is off). Drawn dimmed, and quietly dropped if the job
    /// never reports it.
    let optional: Bool?
}

struct DurationSpec: Codable, Sendable {
    let minS: Double
    let maxS: Double
    let defaultS: Double
}

struct ParamSpec: Codable, Identifiable, Sendable {
    var id: String { key }
    let key: String
    let type: ParamType
    let label: String
    let help: String?
    let `default`: JSONValue
    let nullable: Bool
    let min: Double?
    let max: Double?
    let step: Double?
    let placeholder: String?
    let choices: [EnumChoice]?
    /// json params only: not rendered by the generic form (populated in code).
    let isInternal: Bool?
    let resolveUploads: Bool?

    /// Which named group this control belongs to on the parameters panel —
    /// `sampling`, `musical`, `task`. Free-form: the app groups by whatever
    /// ids it is given, in first-seen order, and falls back to classifying by
    /// key name when a model declares none. Keeping this on the wire is what
    /// lets the panel be grouped without any per-model UI in the app.
    let group: String?
    let groupLabel: String?
    /// "This control only means anything when `param` currently holds one of
    /// `values`." The app dims the row to 45% and explains why rather than
    /// hiding it — a control that vanishes teaches you nothing.
    let appliesWhen: AppliesWhen?

    struct AppliesWhen: Codable, Sendable {
        let param: String
        let values: [String]
    }

    enum CodingKeys: String, CodingKey {
        case key, type, label, help, `default`, nullable, min, max, step,
             placeholder, choices, resolveUploads, group, groupLabel, appliesWhen
        case isInternal = "internal"
    }

    /// Spelled out with defaults rather than left to the memberwise
    /// initialiser: this type gains optional fields as the contract grows, and
    /// every added field would otherwise break every hand-built fixture.
    init(key: String, type: ParamType, label: String, help: String? = nil,
         default: JSONValue, nullable: Bool = false,
         min: Double? = nil, max: Double? = nil, step: Double? = nil,
         placeholder: String? = nil, choices: [EnumChoice]? = nil,
         isInternal: Bool? = nil, resolveUploads: Bool? = nil,
         group: String? = nil, groupLabel: String? = nil,
         appliesWhen: AppliesWhen? = nil) {
        self.key = key
        self.type = type
        self.label = label
        self.help = help
        self.default = `default`
        self.nullable = nullable
        self.min = min
        self.max = max
        self.step = step
        self.placeholder = placeholder
        self.choices = choices
        self.isInternal = isInternal
        self.resolveUploads = resolveUploads
        self.group = group
        self.groupLabel = groupLabel
        self.appliesWhen = appliesWhen
    }
}

enum ParamType: String, Codable, Sendable {
    case int, float, bool, string, `enum`, audio, midi, json
}

struct UploadInfo: Codable, Sendable {
    let uploadId: String
    let bytes: Int64
    let filename: String
}

struct EnumChoice: Codable, Identifiable, Sendable {
    var id: String { value }
    let value: String
    let label: String
}

struct Requirements: Codable, Sendable {
    let minRamBytes: Int64
    let diskBytes: Int64
    let speedTier: SpeedTier
}

enum SpeedTier: String, Codable, Sendable {
    case fast, medium, slow, experimental
}

struct LicenseInfo: Codable, Sendable {
    let name: String
    let commercialUse: Bool
    let requiresHfToken: Bool
    let url: String?
}

struct ModelsResponse: Codable, Sendable {
    let models: [ModelInfo]
}

// MARK: - Downloads

struct DownloadInfo: Codable, Identifiable, Sendable, Equatable {
    var id: String { downloadId }
    let downloadId: String
    let modelId: String
    let state: DownloadState
    let bytesDone: Int64
    let bytesTotal: Int64
    let speedBps: Int64
    let stage: String
    let message: String?
    /// This install is the family runtime alone — no weights are being fetched
    /// (contract §4.2), so there are no bytes to count and nothing to pause.
    /// Absent ⇒ false.
    let runtimeOnly: Bool?

    var isRuntimeOnly: Bool { runtimeOnly ?? false }
}

enum DownloadState: String, Codable, Sendable {
    /// Waiting for the download ahead of it: transfers run one at a time
    /// (contract §4.2). Nothing is moving, so no rate is drawn — the point of
    /// the state is that a waiting download must not look like a stalled one.
    case queued
    case downloading, paused, provisioning
}

struct DownloadsResponse: Codable, Sendable {
    let downloads: [DownloadInfo]
}

struct DownloadStarted: Codable, Sendable {
    let downloadId: String
}

// MARK: - Jobs

struct JobSubmission: Codable, Sendable {
    /// Wire format keeps `model_ids` for contract stability; exactly one entry.
    var modelIds: [String]
    /// Contract §5.4; "generate" is the classic prompt→audio pipeline.
    var task: String = "generate"
    var prompt: String
    var lyrics: String?
    var durationS: Double
    var count: Int
    var params: [String: JSONValue]
    var force: Bool
    /// Ask for partial audio while the take renders (contract 5.6). Off by
    /// default because each frame costs a real decode; `true` against a model
    /// whose `capabilities.supports_preview` is false is refused with 422.
    var preview: Bool = false
}

struct JobsCreated: Codable, Sendable {
    let groupId: String
    let jobs: [JobRef]

    struct JobRef: Codable, Sendable {
        let jobId: String
        let modelId: String
    }
}

enum JobStatus: String, Codable, Sendable {
    case queued, loading, generating, encoding, succeeded, failed, canceled

    var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .canceled: true
        default: false
        }
    }
}

struct JobInfo: Codable, Identifiable, Sendable {
    var id: String { jobId }
    let jobId: String
    let groupId: String
    let modelId: String
    /// nil from pre-task engines; treat as "generate". Read `effectiveTask` or
    /// `isGenerate` rather than testing this directly.
    let task: String?
    /// Echo of the submitted `preview` flag: whether THIS take is publishing
    /// partial audio. Distinct from the model's `supports_preview` — a model
    /// that can preview was not necessarily asked to.
    ///
    /// `var`, alone among these fields, so the synthesized memberwise
    /// initialiser defaults it to nil: an optional `let` has no default, and
    /// this type has no hand-written init, so declaring it otherwise would
    /// break every hand-built JobInfo fixture in the test suite.
    var preview: Bool?
    /// Explicit user run order (contract §5.8); 0 (or absent, from an older
    /// engine) means "no opinion", which is the only place the scheduler is
    /// free to reorder for a warm worker. `var` for the same reason `preview`
    /// is one.
    var priority: Int?
    let status: JobStatus

    /// The task this job is, with the pre-task engines' nil resolved to what it
    /// has always meant.
    ///
    /// Use this, never a bare `task == nil` test. A current engine *echoes*
    /// `"generate"` for an ordinary render (contract §5.4), so `task == nil` is
    /// false for every job it looks like it would catch — which is exactly how
    /// the sidebar came to spin Actions while Studio was generating.
    var effectiveTask: String { task ?? "generate" }

    /// An ordinary render, as opposed to one of the transforms in Actions.
    var isGenerate: Bool { effectiveTask == "generate" }
    /// `var`: a reorder re-announces every queued job's position over SSE, and
    /// the row's "#N in queue" is the only thing that changed — re-fetching
    /// each JobInfo to learn one integer would be a request per job per drag.
    var queuePosition: Int?
    let prompt: String
    let lyrics: String?
    /// null for task jobs (output length derives from the input).
    let durationS: Double?
    let count: Int
    let params: [String: JSONValue]
    let createdAt: String
    let progress: JobProgress?
    let result: JobResult?
    let error: APIErrorBody?
}

struct JobProgress: Codable, Sendable {
    /// Supervisor-assigned coarse stage: `loading` | `generating` | `encoding`.
    let stage: String
    /// Nullable on purpose. An adapter that genuinely does not know its
    /// progress used to be flattened to `0.0`, so the UI drew a bar stuck at
    /// zero for minutes. Nil means indeterminate — draw a spinner and say so.
    let fraction: Double?
    let etaS: Double?
    let message: String?

    /// Which of the job's `count` takes is rendering, 0-based (contract §5.5).
    /// Null before the first take starts and for task jobs. `fraction` is the
    /// average across every take, so this is the only honest way to say "take
    /// 2 of 4" — and the only one that survives a null fraction.
    let take: Int?

    /// Id of the entry in `capabilities.pipeline` currently running, when the
    /// adapter can name it. Absent ⇒ the app falls back to one bar.
    let phase: String?
    /// Position within the current phase, e.g. diffusion step 6 of 8. Present
    /// only when the adapter really counts steps — never synthesised.
    let step: Int?
    let steps: Int?
}

/// One frame of a take that is still rendering (contract 5.6).
///
/// Real audio, decoded from the state the model is genuinely in at `step` — not
/// an interpolation of the finished take. It lives under the engine's
/// `Outputs/<job_id>/` and is deleted when the take succeeds, so the app either
/// draws it now or keeps it explicitly.
struct JobPreview: Codable, Sendable {
    /// Which take of a multi-take job this belongs to.
    let take: Int
    let path: String
    let sampleRate: Int
    let durationS: Double
    /// Position in the phase that produced it; null where the adapter counts
    /// no steps.
    let step: Int?

    var fileURL: URL { URL(fileURLWithPath: path) }
}

struct JobResult: Codable, Sendable {
    /// generate jobs only; task jobs return `artifacts` instead (contract §5.4).
    let outputs: [JobOutput]?
    let artifacts: [JobArtifact]?
    let meta: [String: JSONValue]?
    let timings: [String: Double]
}

struct JobArtifact: Codable, Sendable {
    let kind: String          // stem | midi | analysis | audio (open set)
    let label: String         // stem name / instrument; "preview:<label>" pairs
                              // an audition render with its same-label midi
    let path: String
    let format: String        // wav | mid | json
    let sampleRate: Int?
    let durationS: Double?
}

struct JobOutput: Codable, Sendable {
    let path: String
    let format: String
    let sampleRate: Int
    let durationS: Double
    let seedUsed: Int64?
    /// Whatever the adapter had to say about THIS take beyond the audio — for
    /// ACE-Step, the plan its language model wrote before the renderer drew it
    /// (`lm_metadata` + `audio_codes`). Per-take rather than per-job because
    /// four takes of one prompt are four different plans, and "render this one
    /// again differently" needs the plan belonging to the take that was picked.
    ///
    /// `var` so the memberwise initialiser defaults it, the way `preview` and
    /// `priority` on JobInfo do: every hand-built fixture predates this field.
    var meta: [String: JSONValue]?
}

struct JobsResponse: Codable, Sendable {
    let jobs: [JobInfo]
}

// MARK: - Model library

/// The model library folder, measured through our own catalog (contract §4.6).
///
/// `bytes` and `folderBytes` are both here on purpose. The default library is
/// the shared `~/.cache/huggingface`, so the folder usually holds repos other
/// Hugging Face tools put there — which this app must neither count as its own
/// nor touch. Showing only our figure would disagree with the Finder for
/// reasons the user cannot see; showing both explains the gap.
struct LibraryInfo: Codable, Sendable {
    let path: String
    /// Whether this is the shared `~/.cache/huggingface` default, which is
    /// what makes the destructive actions worth a louder warning.
    let isDefault: Bool
    let bytes: Int64
    let installedBytes: Int64
    /// Bytes from interrupted downloads with no finished model to show for it.
    let partialBytes: Int64
    /// Everything in the folder, ours and everyone else's.
    let folderBytes: Int64
    let modelCount: Int
    let partialCount: Int
    let diskTotalBytes: Int64?
    let diskFreeBytes: Int64?
    let repos: [LibraryRepo]
    let operation: LibraryOperation?

    var url: URL { URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }
    /// What the folder holds for anything that is not this app.
    var foreignBytes: Int64 { max(0, folderBytes - bytes) }
}

struct LibraryOperationStarted: Codable, Sendable {
    let operationId: String
}

struct LibraryRepo: Codable, Sendable, Identifiable {
    let repoId: String
    let path: String
    let bytes: Int64
    /// `installed` | `partial`
    let state: String
    let modelIds: [String]

    var id: String { repoId }
    var isPartial: Bool { state == "partial" }
}

/// A clear or a relocate, while it runs. Long enough on a real library to need
/// a progress bar rather than a spinner: a cross-disk move is a copy.
struct LibraryOperation: Codable, Sendable {
    let operationId: String
    /// `clear` | `relocate`
    let mode: String
    /// `running` | `succeeded` | `failed`
    let state: String
    /// Null while the total is unknown; see `JobProgress` for the same rule.
    let fraction: Double?
    let bytesDone: Int64
    let bytesTotal: Int64
    let message: String
    let error: APIErrorBody?
    let destination: String?
    /// `move` | `delete` | `leave` — what became of the models left behind.
    let disposition: String?
    let repoCount: Int?
    let restartRequired: Bool?
    let canceled: Bool?
    let removedModelIds: [String]?
    let movedRepoIds: [String]?
    let skippedRepoIds: [String]?

    var isRunning: Bool { state == "running" }
}

struct LibraryVerifyReport: Codable, Sendable {
    let checkedAt: String
    let models: [LibraryVerifyFinding]
    let problemCount: Int
    let partialRepos: [LibraryRepo]
}

struct LibraryVerifyFinding: Codable, Sendable, Identifiable {
    let modelId: String
    let displayName: String
    /// `ok` | `missing` | `incomplete` | `shrunk`
    let state: String
    let expectedBytes: Int64
    let actualBytes: Int64

    var id: String { modelId }
    var isProblem: Bool { state != "ok" }

    var explanation: String {
        switch state {
        case "missing":
            "Downloaded, but its files are no longer in the library folder."
        case "incomplete":
            "Some of its files are missing — a download that was interrupted, "
            + "or a folder tidied up by hand."
        case "shrunk":
            "Smaller on disk than when it was downloaded."
        default:
            "Ready."
        }
    }
}

// MARK: - Errors

struct APIErrorBody: Codable, Sendable {
    let code: String
    let message: String
}

struct APIErrorEnvelope: Codable, Sendable {
    let error: APIErrorBody
}

// MARK: - Handshake

struct Handshake: Codable, Sendable {
    let port: Int
    let pid: Int32
    let version: String
    let contract: Int
}

// MARK: - SSE events

enum EngineEvent: Sendable {
    case downloadProgress(DownloadInfo)
    /// `runtimeOnly` distinguishes "the model arrived" from "its runtime did":
    /// a runtime install completing must not announce a model nobody
    /// downloaded (contract §4.2).
    case downloadCompleted(downloadId: String, modelId: String, runtimeOnly: Bool)
    case downloadFailed(downloadId: String, modelId: String, error: APIErrorBody)
    case jobQueued(jobId: String, groupId: String, modelId: String, queuePosition: Int)
    case jobStarted(jobId: String)
    case jobProgress(jobId: String, progress: JobProgress)
    /// Partial audio for a take that is still rendering (contract 5.6). The
    /// path is an absolute local file the engine has finished writing; each one
    /// replaces the last for that take.
    case jobPreview(jobId: String, preview: JobPreview)
    case jobLog(jobId: String, line: String)
    /// One take of a multi-take generate job finished and its file is final
    /// (contract §5.5). The library can land it now; `job.completed` remains
    /// the source of truth and re-lists every output, so a listener dedups
    /// by take index — and one that never saw this event loses nothing.
    case jobTakeDone(jobId: String, take: Int, output: JobOutput)
    case jobCompleted(jobId: String)
    case jobFailed(jobId: String, error: APIErrorBody)
    case jobCanceled(jobId: String)
    /// The queue hold (contract §5.7). `activeJobId` is the job the hold could
    /// *not* stop, which is what the UI has to say out loud.
    case queueState(held: Bool, activeJobId: String?)
    case modelsChanged
    /// A library clear/relocate: progress, then exactly one terminal event.
    case libraryProgress(LibraryOperation)
    case libraryFinished(LibraryOperation)
    case workerState(state: String, modelId: String?, family: String?)
    case engineWarning(message: String)

    /// nil for unknown event names (forward compatibility: ignore, don't fail).
    static func parse(name: String, data: Data, decoder: JSONDecoder) -> EngineEvent? {
        struct DL: Codable { let downloadId: String; let modelId: String; let error: APIErrorBody?; let runtimeOnly: Bool? }
        struct JQ: Codable { let jobId: String; let groupId: String; let modelId: String; let queuePosition: Int }
        struct J: Codable { let jobId: String; let error: APIErrorBody?; let line: String? }
        struct WS: Codable { let state: String; let modelId: String?; let family: String? }
        struct QS: Codable { let held: Bool; let activeJobId: String? }
        struct W: Codable { let message: String }
        do {
            switch name {
            case "download.progress":
                return .downloadProgress(try decoder.decode(DownloadInfo.self, from: data))
            case "download.completed":
                let d = try decoder.decode(DL.self, from: data)
                return .downloadCompleted(downloadId: d.downloadId, modelId: d.modelId,
                                          runtimeOnly: d.runtimeOnly ?? false)
            case "download.failed":
                let d = try decoder.decode(DL.self, from: data)
                return .downloadFailed(downloadId: d.downloadId, modelId: d.modelId,
                                       error: d.error ?? APIErrorBody(code: "INTERNAL", message: "unknown"))
            case "job.queued":
                let d = try decoder.decode(JQ.self, from: data)
                return .jobQueued(jobId: d.jobId, groupId: d.groupId,
                                  modelId: d.modelId, queuePosition: d.queuePosition)
            case "job.started":
                return .jobStarted(jobId: try decoder.decode(J.self, from: data).jobId)
            case "job.progress":
                let j = try decoder.decode(J.self, from: data)
                let p = try decoder.decode(JobProgress.self, from: data)
                return .jobProgress(jobId: j.jobId, progress: p)
            case "job.preview":
                let j = try decoder.decode(J.self, from: data)
                let p = try decoder.decode(JobPreview.self, from: data)
                return .jobPreview(jobId: j.jobId, preview: p)
            case "job.log":
                let j = try decoder.decode(J.self, from: data)
                return .jobLog(jobId: j.jobId, line: j.line ?? "")
            case "job.take_done":
                struct TD: Codable {
                    let jobId: String
                    let take: Int
                    let output: JobOutput
                }
                let d = try decoder.decode(TD.self, from: data)
                return .jobTakeDone(jobId: d.jobId, take: d.take,
                                    output: d.output)
            case "job.completed":
                return .jobCompleted(jobId: try decoder.decode(J.self, from: data).jobId)
            case "job.failed":
                let j = try decoder.decode(J.self, from: data)
                return .jobFailed(jobId: j.jobId,
                                  error: j.error ?? APIErrorBody(code: "INTERNAL", message: "unknown"))
            case "job.canceled":
                return .jobCanceled(jobId: try decoder.decode(J.self, from: data).jobId)
            case "queue.state":
                let q = try decoder.decode(QS.self, from: data)
                return .queueState(held: q.held, activeJobId: q.activeJobId)
            case "models.changed":
                return .modelsChanged
            case "library.progress":
                return .libraryProgress(
                    try decoder.decode(LibraryOperation.self, from: data))
            case "library.completed", "library.failed":
                return .libraryFinished(
                    try decoder.decode(LibraryOperation.self, from: data))
            case "worker.state":
                let d = try decoder.decode(WS.self, from: data)
                return .workerState(state: d.state, modelId: d.modelId,
                                    family: d.family)
            case "engine.warning":
                return .engineWarning(message: try decoder.decode(W.self, from: data).message)
            default:
                return nil
            }
        } catch {
            return nil
        }
    }
}

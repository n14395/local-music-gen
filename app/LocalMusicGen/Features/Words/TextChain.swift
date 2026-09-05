import Foundation

/// The multi-stage music↔text runs — caption-then-generate, transcribe-then-
/// compose, and the editable pauses between them — planned as a sequence of
/// ordinary jobs.
///
/// Pure and store-free, the way `StyleTransferChain` is, and for the same
/// reason: "which jobs, in which order, and what stops the run" is a decision
/// worth a test, and the expensive way to discover it is wrong is to watch a
/// describer load, a generator load, and a describer load again before
/// finding out the third stage was never runnable.
struct TextChain: Equatable {

    /// Which pipeline a card is. Raw values are wire-adjacent (they ride
    /// `ActionRunLog` and future provenance), so they never change.
    enum Kind: String, Equatable, Sendable, CaseIterable {
        /// Transcribe the sung words, optionally separating the vocal first.
        case lyrics
        /// Caption the source, then generate from the caption unedited.
        case roundTrip
        /// The same, pausing for the user to rewrite the caption first.
        case roundTripEdited
        /// Caption → generate → caption the result → … for N rounds.
        case telephone
        /// Transcribe to notes + ABC, then compose from the ABC unedited.
        case abcRoundTrip
        /// The same, pausing for the user to edit the notation first.
        case abcEdited

        /// The wire tasks this kind cannot run without, in the order a
        /// missing one should be reported. Generate capability is checked
        /// separately (it is a `GenerateNeed`, not a task).
        var requiredTasks: [String] {
            switch self {
            case .lyrics: ["lyrics"]
            case .roundTrip, .roundTripEdited, .telephone: ["caption"]
            case .abcRoundTrip, .abcEdited: ["transcribe", "compose"]
            }
        }

        /// Whether the kind ends in (or loops through) a generate job.
        var needsGenerator: Bool {
            switch self {
            case .roundTrip, .roundTripEdited, .telephone: true
            case .lyrics, .abcRoundTrip, .abcEdited: false
            }
        }

        /// Whether the run pauses to let the user rewrite what came back.
        var pausesForEdit: Bool {
            self == .roundTripEdited || self == .abcEdited
        }

        /// Rounds are only meaningful for the telephone game; everything else
        /// runs its stages once.
        var repeats: Bool { self == .telephone }
    }

    /// One job in the run, named in the user's terms rather than the wire's.
    enum Stage: Equatable, Identifiable, Sendable {
        /// Isolate the vocal before transcribing it — absent when the user
        /// did not ask, or when a vocals stem already exists.
        case separate(modelId: String, modelName: String)
        case caption(modelId: String, modelName: String)
        case transcribeLyrics(modelId: String, modelName: String)
        /// Extract notes and notation. `transcribe` with `emit_abc`.
        case extractABC(modelId: String, modelName: String)
        /// Hand control back so the user can rewrite the text. No model, no
        /// job — the run stops here until they say continue.
        case editText(seeds: TextDocKind)
        case generate(modelId: String, modelName: String, durationS: Double)
        case composeABC(modelId: String, modelName: String)

        var id: String {
            switch self {
            case .separate: "separate"
            case .caption: "caption"
            case .transcribeLyrics: "lyrics"
            case .extractABC: "abc"
            case .editText: "edit"
            case .generate: "generate"
            case .composeABC: "compose"
            }
        }

        var title: String {
            switch self {
            case .separate: "Isolate the vocal"
            case .caption: "Listen and describe"
            case .transcribeLyrics: "Transcribe the words"
            case .extractABC: "Extract the notation"
            case .editText: "Your turn to edit"
            case .generate: "Generate from the text"
            case .composeABC: "Compose from the notation"
            }
        }

        var detail: String {
            switch self {
            case .separate:
                "Splits the song and keeps the vocal — words transcribe far "
                    + "more cleanly without a band over them."
            case .caption:
                "A model listens to the audio and writes what it hears."
            case .transcribeLyrics:
                "The sung words, with a timing on every line."
            case .extractABC:
                "Notes per instrument, and each track written out as ABC."
            case .editText:
                "The run stops here. Rewrite what the model wrote, then "
                    + "press continue — nothing is generated until you do."
            case .generate(_, _, let seconds):
                "\(Int(seconds.rounded())) seconds of new audio from those "
                    + "words alone. The original is never heard by it."
            case .composeABC:
                "The notation becomes a new piece — notes first, then audio "
                    + "through the SoundFont renderer."
            }
        }

        /// The model this stage runs on, where it has one.
        var modelId: String? {
            switch self {
            case .separate(let id, _), .caption(let id, _),
                 .transcribeLyrics(let id, _), .extractABC(let id, _),
                 .generate(let id, _, _), .composeABC(let id, _):
                id
            case .editText:
                nil
            }
        }

        var modelName: String? {
            switch self {
            case .separate(_, let name), .caption(_, let name),
                 .transcribeLyrics(_, let name), .extractABC(_, let name),
                 .generate(_, let name, _), .composeABC(_, let name):
                name
            case .editText:
                nil
            }
        }
    }

    // MARK: - The plan

    let kind: Kind
    /// Stages in run order. The telephone game's caption/generate pair is
    /// unrolled here rather than looped at run time, so "step 4 of 6" is a
    /// fact about the plan rather than arithmetic done in the commit bar.
    let stages: [Stage]
    let rounds: Int
    /// Why the run cannot start. Nil when it can.
    let blockedReason: String?
    /// True things worth saying that do not stop the run.
    let warnings: [String]

    var isRunnable: Bool { blockedReason == nil && !stages.isEmpty }

    /// Jobs this will submit — the edit pause is a stage but not a job.
    var jobCount: Int { stages.filter { $0.modelId != nil }.count }

    // MARK: - Building

    /// Everything the planner needs from the catalog and the library.
    struct Inputs {
        var models: [ModelInfo] = []
        var captionerId: String?
        var transcriberId: String?
        var lyricsModelId: String?
        var composerId: String?
        var separatorId: String?
        var generatorId: String?
        /// Whether the user asked for the vocal to be isolated first.
        var separateVocalsFirst = false
        /// Whether the source already is (or already has) a vocals stem.
        var hasVocalsStem = false
        var rounds = 3
        var durationS: Double = 20

        init() {}
    }

    /// Plan a run, or explain why it cannot happen.
    ///
    /// Every missing piece is reported at once: told about them one at a
    /// time, the user installs a model, comes back, and is told about the
    /// next one — the lesson `StyleTransferChain.make` already learned.
    static func make(kind: Kind, inputs: Inputs) -> TextChain {
        let rounds = kind.repeats ? max(2, min(6, inputs.rounds)) : 1

        func pick(_ task: String, preferred: String?) -> ModelInfo? {
            let eligible = inputs.models.filter {
                $0.installState == .installed
                    && $0.capabilities.supportedTasks.contains(task)
            }
            return eligible.first { $0.id == preferred } ?? eligible.first
        }

        let generator = kind.needsGenerator
            ? (GenerateNeed().eligible(inputs.models)
                .first { $0.id == inputs.generatorId }
                ?? GenerateNeed().eligible(inputs.models).first)
            : nil

        var missing: [String] = []
        var byTask: [String: ModelInfo] = [:]
        for task in kind.requiredTasks {
            let preferred: String? = switch task {
            case "caption": inputs.captionerId
            case "lyrics": inputs.lyricsModelId
            case "transcribe": inputs.transcriberId
            case "compose": inputs.composerId
            default: nil
            }
            if let model = pick(task, preferred: preferred) {
                byTask[task] = model
            } else {
                missing.append(name(forTask: task))
            }
        }
        if kind.needsGenerator && generator == nil {
            missing.append("a model that generates audio")
        }

        // The separation pre-step is optional, so a missing separator is a
        // warning rather than a blocker: transcribing the full mix is worse,
        // not impossible.
        let wantsSeparation = kind == .lyrics && inputs.separateVocalsFirst
            && !inputs.hasVocalsStem
        let separator = wantsSeparation
            ? pick("separate", preferred: inputs.separatorId) : nil

        guard missing.isEmpty else {
            return TextChain(kind: kind, stages: [], rounds: rounds,
                             blockedReason: "Needs \(list(missing)).",
                             warnings: [])
        }

        var stages: [Stage] = []
        var warnings: [String] = []

        if wantsSeparation {
            if let separator {
                stages.append(.separate(modelId: separator.id,
                                        modelName: separator.displayName))
            } else {
                warnings.append("No separation model is installed, so the "
                    + "words are transcribed from the full mix — expect the "
                    + "band to confuse it.")
            }
        } else if kind == .lyrics && inputs.hasVocalsStem
                    && inputs.separateVocalsFirst {
            warnings.append("This already is a vocal, so nothing needs "
                + "separating first.")
        }

        switch kind {
        case .lyrics:
            if let model = byTask["lyrics"] {
                stages.append(.transcribeLyrics(modelId: model.id,
                                                modelName: model.displayName))
            }
        case .roundTrip, .roundTripEdited, .telephone:
            guard let captioner = byTask["caption"], let generator else { break }
            for round in 0..<rounds {
                stages.append(.caption(modelId: captioner.id,
                                       modelName: captioner.displayName))
                if kind.pausesForEdit && round == 0 {
                    stages.append(.editText(seeds: .caption))
                }
                stages.append(.generate(modelId: generator.id,
                                        modelName: generator.displayName,
                                        durationS: inputs.durationS))
            }
        case .abcRoundTrip, .abcEdited:
            guard let transcriber = byTask["transcribe"],
                  let composer = byTask["compose"] else { break }
            stages.append(.extractABC(modelId: transcriber.id,
                                      modelName: transcriber.displayName))
            if kind.pausesForEdit {
                stages.append(.editText(seeds: .abc))
            }
            stages.append(.composeABC(modelId: composer.id,
                                      modelName: composer.displayName))
        }

        if kind.repeats {
            warnings.append("Each round swaps between a describer and a "
                + "generator. A describer big enough to be good unloads the "
                + "music model every time, so rounds are slower than they "
                + "look.")
        }
        if kind == .abcRoundTrip || kind == .abcEdited {
            warnings.append("Notation from audio is a sketch, not a "
                + "transcription — a separated stem reads far more cleanly "
                + "than a full mix.")
        }

        return TextChain(kind: kind, stages: stages, rounds: rounds,
                         blockedReason: stages.isEmpty
                            ? "Nothing to run." : nil,
                         warnings: warnings)
    }

    // MARK: - Progress

    /// Where a partly-run pipeline has got to. Codable so a run survives
    /// being navigated away from and back.
    struct Progress: Equatable, Codable, Sendable {
        var stageIndex = 0
        /// Which repeat of the telephone loop, 0-based.
        var round = 0
        /// The job the run is waiting on, so a completion can be matched.
        var jobId: String?
        /// The most recent text a stage produced — what the next stage reads.
        var text: String?
        /// What the user rewrote it to, when they did.
        var editedText: String?
        /// True while the run is parked at an `.editText` stage.
        var awaitingEdit = false
        var producedSongIds: [String] = []
        var producedDocIds: [String] = []
        var failure: String?

        init() {}

        var isFailed: Bool { failure != nil }
        /// What the next stage should actually use.
        var effectiveText: String? { editedText ?? text }
    }

    /// "Step 2 of 4 — Listen and describe", or the round when there is one.
    func statusLine(_ progress: Progress) -> String {
        guard !stages.isEmpty else { return "" }
        if let failure = progress.failure {
            return "Stopped at step \(progress.stageIndex + 1): \(failure)"
        }
        let index = min(progress.stageIndex, stages.count - 1)
        let step = "Step \(index + 1) of \(stages.count) — \(stages[index].title)"
        guard kind.repeats else { return step }
        return "Round \(progress.round + 1) of \(rounds) · \(step)"
    }

    // MARK: - Copy helpers

    static func name(forTask task: String) -> String {
        switch task {
        case "caption": "a describer model"
        case "lyrics": "a lyric transcriber"
        case "transcribe": "a note transcriber"
        case "compose": "a notation composer"
        case "separate": "a separation model"
        default: "a \(task) model"
        }
    }

    /// "a describer", "a describer and a generator", "a, b and c".
    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: ""
        case 1: items[0]
        case 2: "\(items[0]) and \(items[1])"
        default: items.dropLast().joined(separator: ", ")
            + " and \(items[items.count - 1])"
        }
    }
}

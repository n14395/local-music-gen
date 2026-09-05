import Foundation

/// The single-stage music-to-text jobs, one case per card — the same shape
/// `TrackTransform` gives the DSP cards: what changes between them is which
/// wire task runs and how the result is presented, and both of those are
/// properties of the case, so one page type (`TextActionView`) renders all
/// of them.
///
/// Not here: `lyrics`. The transcribe-lyrics card is a pipeline
/// (`TextChain.Kind.lyrics`) because of its optional separate-vocals-first
/// pre-stage — a single-stage case for it would be a second, slightly wrong
/// way to run the same job.
enum TextAction: String, Equatable, Sendable, CaseIterable {
    /// Caption → a description slot on the source (saved).
    case describe
    /// Caption → shown on the page; kept only if the user says so.
    case freeCaption
    /// Caption with a `question` param → a Q&A document.
    case ask
    /// Task "tag" → labels merged into the song's own tags + a tags doc.
    case tags
    /// Transcribe with `emit_abc` → notes parts + an ABC document.
    case extractABC

    /// The wire task this action submits — and the capability the card's
    /// model picker and gating filter on.
    var task: String {
        switch self {
        case .describe, .freeCaption, .ask: "caption"
        case .tags: "tag"
        case .extractABC: "transcribe"
        }
    }

    /// Whether the result becomes a library row as a matter of course, or
    /// stays on the page until the user keeps it. Decides which of the two
    /// submission paths runs: JobsStore ingest, or MetaJobRunner.
    var savesByDefault: Bool {
        switch self {
        case .describe, .tags, .extractABC: true
        case .freeCaption, .ask: false
        }
    }

    /// A param the model must *declare* to be offered for this action.
    ///
    /// Declaring the task is not always enough. Both LP-MusicCaps and
    /// Qwen2-Audio answer `caption`, but only one of them can be asked a
    /// question — the other is a captioner with no instruction channel at
    /// all. The engine drops params a model does not declare (contract
    /// §5.1), so a question sent to the wrong model is not refused, it is
    /// silently ignored and the user gets a general description with no sign
    /// that their question went nowhere. The declared param is the honest
    /// test, exactly as `mix_spec` distinguishes a mixdown from a splicer.
    var requiredParam: String? {
        self == .ask ? "question" : nil
    }

    /// Whether this model can serve this action — task plus, where it
    /// matters, the param that makes the task mean what the card says.
    func canRun(_ model: ModelInfo) -> Bool {
        guard model.capabilities.supportedTasks.contains(task) else {
            return false
        }
        guard let requiredParam else { return true }
        return model.capabilities.params.contains { $0.key == requiredParam }
    }
}

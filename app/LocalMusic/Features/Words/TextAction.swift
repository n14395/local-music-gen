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
}

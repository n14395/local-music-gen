import Foundation

/// What a gated feature needs before it can run — the same predicate that
/// dimmed it, carried to the Models screen so the list there can be narrowed
/// to exactly the models that would ungate it.
///
/// Routing used to stop at "open Models", which left you in a 64-row catalog
/// with no indication of which row you had been sent for. The tempting fix is
/// to filter on the tag bar, but tags are an open vocabulary owned by the
/// catalog (`ModelTagFilter` knows the meaning of none of them), and they do
/// not line up: `transcribe` and `render` share "Notes & MIDI" though only one
/// model of the five can render, and a style mode's eligibility depends on the
/// *params* a model exposes, which no tag records. Capability is the exact
/// answer and is already what the gate tested, so it is what travels.
///
/// Carrying the predicate rather than a model id is what makes the multi-model
/// cases honest: five models can separate stems and they differ in size, speed
/// and licence. Choosing one silently is a decision the Models screen exists to
/// let you make.
enum ModelRequirement: Equatable, Hashable, Identifiable {
    /// A job task the model must declare: `separate`, `transcribe`, `analyze`
    /// or `render` (contract §5.4).
    case task(String)
    /// Mixdown and Token Splice both declare `mix`; the param they consume is
    /// what tells them apart, so both go through `MixModels`.
    case mixdown
    case splicer
    case style(StyleTransferMode)
    /// What a Generate card needs before it can run — see `GenerateNeed`.
    /// Only the gating half travels here; the preferred families decide which
    /// model a card *arrives* on and gate nothing, so they have no business in
    /// a filter that answers "what do I download".
    case generate(GenerateNeed)

    var id: String {
        switch self {
        case .task(let task): "task:" + task
        case .mixdown: "mixdown"
        case .splicer: "splicer"
        case .style(let mode): "style:" + mode.rawValue
        case .generate(let need): "generate:" + need.key
        }
    }

    /// Named as the thing you were trying to do, because that is what the user
    /// just clicked — the chip reads "Needed for: Separate stems".
    var title: String {
        switch self {
        case .task("separate"): "Separate stems"
        case .task("transcribe"): "Transcribe to notes"
        case .task("analyze"): "Musical analysis"
        case .task("render"): "Render notes to audio"
        case .task("assist"): "Help me write"
        case .task("plan"): "Plan before rendering"
        case .task(let task): task.capitalized
        case .mixdown: "Create a mix"
        case .splicer: "Token splice"
        case .style(let mode): mode.title
        case .generate(let need): need.title
        }
    }

    func matches(_ model: ModelInfo) -> Bool {
        switch self {
        case .task(let task):
            model.capabilities.supportedTasks.contains(task)
        case .mixdown:
            MixModels.isMixdown(model)
        case .splicer:
            MixModels.isSplicer(model)
        // Deliberately not filtering variants out here, unlike the featured
        // check this replaced: a quantised build that can run the mode is a
        // real answer to "what do I download", and the list nests it under its
        // base rather than hiding it.
        case .style(let mode):
            mode.canRun(model)
        case .generate(let need):
            need.canRun(model)
        }
    }

    /// Everything that would satisfy this, installed or not, smallest first —
    /// the answer to "which one do I download" is almost always "the cheapest
    /// one that works".
    func candidates(_ models: [ModelInfo]) -> [ModelInfo] {
        models.filter(matches).sorted { $0.sizeBytes < $1.sizeBytes }
    }

    /// Shown in place of the list when the catalog has nothing to offer. An
    /// empty list with an active filter and no explanation reads as a bug.
    var emptyMessage: String {
        "No model in the catalog can do this yet."
    }
}

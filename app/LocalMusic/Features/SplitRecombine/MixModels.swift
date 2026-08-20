import Foundation

/// Which installed model can render a mixdown.
///
/// "Supports task mix" is not enough: Token Splice also declares `mix`, but it
/// consumes a `splice_spec` and knows nothing about tracks — picking it for a
/// Create Mix fails the job with "missing required input 'splice_spec'". The
/// param a model consumes is what actually distinguishes them.
enum MixModels {
    /// Split from the lookups below so callers can ask "could any model in the
    /// catalog do this?" — not only "is one installed?". The gallery needs the
    /// first question to know whether routing you to Models will actually show
    /// you the model it just told you to get.
    static func isMixdown(_ model: ModelInfo) -> Bool {
        model.capabilities.supportedTasks.contains("mix")
            && model.capabilities.params.contains { $0.key == "mix_spec" }
    }

    static func isSplicer(_ model: ModelInfo) -> Bool {
        model.capabilities.supportedTasks.contains("mix")
            && model.capabilities.params.contains { $0.key == "splice_spec" }
    }

    static func mixdown(in models: [ModelInfo]) -> ModelInfo? {
        models.first { $0.installState == .installed && isMixdown($0) }
    }

    static func splicer(in models: [ModelInfo]) -> ModelInfo? {
        models.first { $0.installState == .installed && isSplicer($0) }
    }
}

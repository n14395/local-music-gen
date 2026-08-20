import Foundation

/// Filter maths for the Models screen's tag bar, kept out of the view so it is
/// unit-testable.
///
/// Tags are an open vocabulary owned by the catalog ("Songs with vocals",
/// "Stem separation", …): nothing here knows what any individual tag means, so
/// the engine can add tags without an app change.
enum ModelTagFilter {
    /// Unique tags in catalog order, first appearance winning — deterministic
    /// button order without a hardcoded ordering table.
    static func orderedTags(from models: [ModelInfo]) -> [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        for model in models {
            for tag in model.modelTags where seen.insert(tag).inserted {
                ordered.append(tag)
            }
        }
        return ordered
    }

    /// How many models carry each tag (a model counts once per distinct tag).
    static func counts(from models: [ModelInfo]) -> [String: Int] {
        models.reduce(into: [:]) { counts, model in
            for tag in Set(model.modelTags) { counts[tag, default: 0] += 1 }
        }
    }

    /// OR semantics: a model matches if it carries any selected tag. An empty
    /// selection matches everything.
    static func matches(_ model: ModelInfo, selection: Set<String>) -> Bool {
        guard !selection.isEmpty else { return true }
        return model.modelTags.contains { selection.contains($0) }
    }
}

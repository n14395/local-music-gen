import Foundation

/// How many of the app's actions a model unlocks — the `14 ACTIONS` badge on a
/// model row.
///
/// The number is derived, never stored. `RecipeCatalog` is the list of things
/// the app can do, and every recipe names the engine it needs; a model enables
/// a recipe when it can execute that engine, which is a question about the
/// tasks and params the model *declares* — never about its id. Adding a recipe
/// to the catalog therefore moves this badge with no change here.
///
/// Two deliberate exclusions:
///   * recipes that need no model at all (Open in Workbench, What Mashes With
///     This?) are attributed to nobody — counting them against every model
///     would make the badge a constant and tell you nothing,
///   * a recipe whose `autoDerive` a model could satisfy is *not* counted: a
///     separator makes "Swap the Vocals" easier to fill, but it is the mixdown
///     model that runs it.
enum ModelActions {
    static func count(for model: ModelInfo,
                      in recipes: [Recipe] = RecipeCatalog.all) -> Int {
        recipes.filter { enables(model, $0) }.count
    }

    static func enables(_ model: ModelInfo, _ recipe: Recipe) -> Bool {
        // Phase ≥3 recipes are drawn "coming soon"; nothing can run them yet,
        // so no model can claim them.
        guard recipe.isAvailable else { return false }
        let capabilities = model.capabilities
        let tasks = capabilities.supportedTasks
        switch recipe.engine {
        case .mix, .arrange:
            // "Supports task mix" is not enough — Token Splice also declares
            // it. The param a model consumes is what separates them, exactly
            // as `MixModels` decides at run time.
            return tasks.contains("mix")
                && capabilities.params.contains { $0.key == "mix_spec" }
        case .tokenSplice:
            return tasks.contains("mix")
                && capabilities.params.contains { $0.key == "splice_spec" }
        case .split(let task, _):
            return tasks.contains(task)
        case .render:
            return tasks.contains("render")
        case .styleTransfer(let preset):
            // One definition of "can this model serve this transformation",
            // shared with the workspace itself. This file used to restate it,
            // because the only other copy lived inside a view and this one has
            // to stay unit-testable; `StyleTransferMode` is pure and tested, so
            // the two copies could finally become one.
            return preset.mode.canRun(model)
        case .generate(let preset):
            return preset.need.canRun(model)
        case .compareModels:
            // Any generative model is a candidate for a comparison — the card
            // needs two of them, but that is a fact about the machine rather
            // than about this model.
            return GenerateNeed().canRun(model)
        case .workbench, .match:
            return false
        }
    }
}

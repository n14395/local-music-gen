// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A configured starting point for the Style Transfer workspace.
///
/// This is what an Actions card becomes. The gallery is a good place to *find*
/// a transformation — nine cards with musician language on them beat one screen
/// with a mode picker — and a bad place to *do* one, because a card is a
/// one-shot: pick, press, leave, and everything you set is gone. So the card
/// stays, and stops being a page.
///
/// Carried in `RecipeEngine.styleTransfer(preset:)`, following the existing
/// `.mix(defaults:)` and `.split(task:note:)` precedent of putting a recipe's
/// configuration in its engine's associated value rather than in a parallel
/// table that can fall out of step with it.
struct StylePreset: Equatable, Identifiable, Sendable {
    /// Matches the recipe id that carries it, so a preset and its card cannot
    /// drift apart. **Wire value** by inheritance: recipe ids are written into
    /// song provenance and key `actions.lastRuns`, so these are re-pointed,
    /// never renamed.
    let id: String
    let mode: StyleTransferMode
    /// Text dropped into the prompt on arrival. Empty leaves it blank — most
    /// presets should, because a prompt the user did not write is a prompt they
    /// will not read before pressing go.
    var promptSeed: String = ""
    /// Where the `Original ←→ Style` dial starts, when this preset means
    /// something more specific than the model's default.
    var styleAmount: Double?
    /// A line shown above the workspace once, explaining what arriving here
    /// changed. Nil for presets that need no explanation.
    var notice: String?

    init(id: String, mode: StyleTransferMode, promptSeed: String = "",
         styleAmount: Double? = nil, notice: String? = nil) {
        self.id = id
        self.mode = mode
        self.promptSeed = promptSeed
        self.styleAmount = styleAmount
        self.notice = notice
    }
}

extension StylePreset {

    /// Every preset, keyed by the recipe id that opens it.
    ///
    /// Deliberately derived from the recipe table rather than duplicated: the
    /// recipes are the source of truth for what exists, and this is only the
    /// lookup the workspace needs when it is handed an id from a deep link.
    static func preset(forRecipeId id: String) -> StylePreset? {
        guard let recipe = RecipeCatalog.recipe(id: id),
              case .styleTransfer(let preset) = recipe.engine else { return nil }
        return preset
    }

    /// The recipe that carries a given preset, for the workspace's top bar.
    static func recipe(for preset: StylePreset) -> Recipe? {
        RecipeCatalog.recipe(id: preset.id)
    }
}

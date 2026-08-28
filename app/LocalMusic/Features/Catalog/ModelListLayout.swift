import Foundation

/// One rendered line of the Models list.
struct ModelListRow: Identifiable, Equatable {
    let model: ModelInfo
    /// Variants are indented 26 pt under their base and carry a VARIANT badge.
    let isVariant: Bool
    /// Whether to print the model's build string (`GGUF · XL base`) beside the
    /// name. Only interesting where a family has more than one build — on a
    /// model that stands alone it is noise.
    let showsFormat: Bool

    var id: String { model.id }

    static func == (lhs: ModelListRow, rhs: ModelListRow) -> Bool {
        lhs.model.id == rhs.model.id
            && lhs.isVariant == rhs.isVariant
            && lhs.showsFormat == rhs.showsFormat
    }
}

struct ModelListPlan: Equatable {
    /// The models the caller marked recommended, with their variants nested
    /// underneath.
    let recommended: [ModelListRow]
    /// Everything else, fully expanded. The view draws these only when the
    /// "Show all" disclosure is open.
    let other: [ModelListRow]
    /// How many rows the disclosure controls — the `EVERYTHING ELSE · 58`
    /// count. Deliberately *not* `other.count`: opening the disclosure also
    /// reveals the un-installed variants tucked under recommended models, and
    /// the number has to add up to the catalog the chip row is counting.
    let hidden: Int
}

/// Turns a flat catalog into the two-section, one-level-of-nesting list the
/// design draws.
///
/// Pure and id-driven so it can be tested without a store: `matching` is the
/// set of models that survive the search / tag / installed filters, and
/// `recommended` the set that belongs in the top section — ids only, so what
/// counts as recommended stays the screen's judgement, not this file's.
enum ModelListLayout {
    /// The ids that belong in the top section: the featured ones, and nothing
    /// else.
    ///
    /// Downloads used to be folded in here so a running one could not hide
    /// behind the closed disclosure. It kept them visible at the cost of
    /// *moving* them: clicking Download on a model in the long tail lifted its
    /// row into the section above, out from under the pointer — and dropped it
    /// back down when the transfer ended. Section membership now depends only
    /// on the catalog, so a row stays where it was put; `holdsTailOpen`
    /// carries the reachability concern instead.
    static func recommendedIds(in models: [ModelInfo]) -> Set<String> {
        Set(models.filter(\.isFeatured).map(\.id))
    }

    /// The row a model is drawn under: the ROOT of its variant chain, not its
    /// immediate parent.
    ///
    /// The list draws one level of nesting — it loops over the bases and asks
    /// each for its variants — so the only ids that can carry a row are the
    /// ones with no base of their own. Two rules follow, and they are the same
    /// rule:
    ///
    /// - A variant whose base is missing from the catalog stands for itself.
    ///   Nesting it under an id nobody has would make it unreachable: no
    ///   header would ever be drawn to hang it from.
    /// - A variant whose base is present but is *itself* a variant hangs off
    ///   that base's base. Keyed by the immediate parent, its bucket would be
    ///   filled and never read — which is exactly what happened: the Models
    ///   screen could draw only 125 of 129 models, and the four it could not
    ///   (SCNet XL, two MOSS-Music quants, Anticipation medium) were
    ///   undrawable at any filter setting, with only the sidebar's count to
    ///   say they existed. Beside its parent is also where a grandchild
    ///   belongs: an XL checkpoint of SCNet is another build of the same
    ///   separator.
    ///
    /// The `seen` guard is for a catalog that names a cycle. It cannot be
    /// right, but a hang is worse than a model promoted to a base.
    static func rootId(of model: ModelInfo, in byId: [String: ModelInfo]) -> String {
        var current = model
        var seen: Set<String> = [model.id]
        while let parent = current.variantOf, let next = byId[parent],
              seen.insert(parent).inserted {
            current = next
        }
        return current.id
    }

    /// The base each of these models hangs off — `rootId` for a set of ids.
    static func baseIds(of ids: Set<String>, in models: [ModelInfo]) -> Set<String> {
        let byId = Dictionary(models.map { ($0.id, $0) },
                              uniquingKeysWith: { first, _ in first })
        return Set(models.filter { ids.contains($0.id) }
            .map { rootId(of: $0, in: byId) })
    }

    /// Whether the disclosure must stay open whatever the stored preference
    /// says. This list is the only place to pause or cancel a download, so one
    /// running in the long tail cannot be left behind a closed section —
    /// including when it was started somewhere else entirely, from a gated
    /// action or the first-run sheet.
    static func holdsTailOpen(models: [ModelInfo],
                              downloadingBaseIds: Set<String>) -> Bool {
        !downloadingBaseIds.subtracting(recommendedIds(in: models)).isEmpty
    }

    static func plan(models: [ModelInfo],
                     matching: Set<String>,
                     recommended: Set<String>,
                     expanded: Bool) -> ModelListPlan {
        let byId = Dictionary(models.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // The root of the variant chain, so a grandchild hangs off the row
        // that is actually drawn rather than off a bucket nobody reads. See
        // `rootId`.
        func baseId(of model: ModelInfo) -> String {
            rootId(of: model, in: byId)
        }

        var variantsByBase: [String: [ModelInfo]] = [:]
        var bases: [ModelInfo] = []
        for model in models {
            if baseId(of: model) == model.id {
                bases.append(model)
            } else {
                variantsByBase[baseId(of: model), default: []].append(model)
            }
        }
        bases.sort { ($0.displayName, $0.id) < ($1.displayName, $1.id) }

        var recommendedRows: [ModelListRow] = []
        var otherRows: [ModelListRow] = []
        var expandedTotal = 0
        var collapsedTotal = 0

        for base in bases {
            let variants = (variantsByBase[base.id] ?? [])
                .filter { matching.contains($0.id) }
                .sorted { ($0.format ?? "", $0.id) < ($1.format ?? "", $1.id) }
            // A group survives filtering when the base *or* any of its variants
            // matches. When only a variant matches the base still draws, as
            // the group's header — otherwise a matching variant is orphaned
            // and unreachable.
            guard matching.contains(base.id) || !variants.isEmpty else { continue }

            // Collapsed, a group shows only the variants you already have.
            // Otherwise all thirteen ACE-Step quantisations are on screen
            // before you have asked for any of them.
            let owned = variants.filter {
                $0.installState == .installed || $0.installState == .downloading
            }
            let showsFormat = !variants.isEmpty
            let isRecommended = recommended.contains(base.id)

            expandedTotal += 1 + variants.count
            if isRecommended { collapsedTotal += 1 + owned.count }

            let header = ModelListRow(model: base, isVariant: false,
                                      showsFormat: showsFormat)
            if isRecommended {
                let shown = expanded ? variants : owned
                recommendedRows.append(header)
                recommendedRows += shown.map {
                    ModelListRow(model: $0, isVariant: true, showsFormat: true)
                }
            } else {
                otherRows.append(header)
                otherRows += variants.map {
                    ModelListRow(model: $0, isVariant: true, showsFormat: true)
                }
            }
        }

        return ModelListPlan(recommended: recommendedRows, other: otherRows,
                             hidden: max(0, expandedTotal - collapsedTotal))
    }
}

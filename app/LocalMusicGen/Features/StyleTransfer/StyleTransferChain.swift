// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// "Keep the vocal: split → restyle → mix back" — planned as a sequence of
/// ordinary jobs.
///
/// This is the only mode in Style Transfer whose preservation is *literal*
/// rather than statistical: the stems you keep are the original recording,
/// bit for bit, and only the rest is re-performed. That reliability is worth
/// the extra machinery, and none of the machinery is new — separation, a
/// generative restyle and a beat-aligned mixdown all already exist as jobs.
/// What was missing was something to hold them in a line.
///
/// Pure and store-free, for the usual reason: "which jobs, in which order, and
/// what happens when the stems already exist" is a decision worth a test, and
/// the expensive way to discover it is wrong is to watch Demucs run for four
/// minutes before finding out.
struct StyleTransferChain: Equatable {

    // MARK: - Inputs

    /// A stem as the planner sees it. Deliberately not `PartRecord`: the
    /// planner needs an id, a taxonomy kind and something to print, and taking
    /// the database record would drag persistence into a pure type.
    struct Stem: Equatable, Identifiable, Sendable {
        let id: String        // part id
        let kind: String      // "stem.vocals", "layer.strings"
        let name: String
        let durationS: Double?

        init(id: String, kind: String, name: String, durationS: Double? = nil) {
            self.id = id
            self.kind = kind
            self.name = name
            self.durationS = durationS
        }

        /// "stem.vocals" → "vocals". What the checkbox says.
        var label: String {
            guard let dot = kind.firstIndex(of: ".") else { return kind }
            return String(kind[kind.index(after: dot)...])
        }
    }

    // MARK: - Steps

    /// One job in the chain, named in the user's terms rather than the wire's.
    enum Step: Equatable, Identifiable, Sendable {
        /// Separate the song. Absent when usable stems already exist — Demucs
        /// takes minutes, and re-running it to produce files that are already
        /// on disk is the single most expensive mistake this planner can make.
        case split(modelId: String, modelName: String)
        /// Fold the stems that are *not* being kept into one file, because the
        /// restyle models take a single source audio. Absent when exactly one
        /// stem is being replaced and can be sent as-is.
        case fold(modelId: String, modelName: String, kinds: [String])
        /// Re-perform the folded remainder.
        case restyle(modelId: String, modelName: String, kinds: [String])
        /// Put the kept originals back against the restyled remainder.
        case remix(modelId: String, modelName: String, keptKinds: [String])

        var id: String {
            switch self {
            case .split: "split"
            case .fold: "fold"
            case .restyle: "restyle"
            case .remix: "remix"
            }
        }

        var title: String {
            switch self {
            case .split: "Split into stems"
            case .fold: "Fold the rest together"
            case .restyle: "Restyle the rest"
            case .remix: "Mix it back together"
            }
        }

        var modelName: String {
            switch self {
            case .split(_, let name), .fold(_, let name, _),
                 .restyle(_, let name, _), .remix(_, let name, _):
                name
            }
        }

        var modelId: String {
            switch self {
            case .split(let id, _), .fold(let id, _, _),
                 .restyle(let id, _, _), .remix(let id, _, _):
                id
            }
        }

        var detail: String {
            switch self {
            case .split:
                "Vocals, drums, bass and the rest, written to Library › Parts."
            case .fold(_, _, let kinds):
                "\(StyleTransferChain.list(kinds)) become one file for the "
                    + "model to work on."
            case .restyle(_, _, let kinds):
                "The model re-performs \(StyleTransferChain.list(kinds))."
            case .remix(_, _, let kept):
                "\(StyleTransferChain.list(kept).capitalizedFirst) go back in "
                    + "untouched, beat-aligned against the new audio."
            }
        }
    }

    // MARK: - The plan

    let steps: [Step]
    /// The kinds surviving as original audio.
    let keptKinds: [String]
    /// The kinds being re-performed.
    let replacedKinds: [String]
    /// Why the chain cannot run at all. Nil when it can.
    let blockedReason: String?
    /// Things that will happen that the user should know about but that do not
    /// stop the run.
    let warnings: [String]
    /// True while the stem list is still unknown — the song has never been
    /// split, so which stems exist is a question only the split can answer.
    let needsSplitFirst: Bool

    var isRunnable: Bool { blockedReason == nil && !steps.isEmpty }

    /// What the commit bar counts: "step 2 of 3".
    var jobCount: Int { steps.count }

    // MARK: - Building

    /// - Parameters:
    ///   - stems: the stem-like parts the source song already has. Pass the
    ///     result of `PartsRepository.allParts(forSong:)` filtered to audio.
    ///   - keep: the kinds the user ticked to preserve.
    ///   - models: the catalog as the engine reported it.
    ///   - restyleModelId: the model chosen for the middle step; nil takes the
    ///     first installed model that can cover.
    ///   - sourceIsAnalyzed: whether tempo/beats are known for the source.
    ///     Without them `JobsStore.planMix` silently drops to `stretch.mode =
    ///     "none"` and the mix renders unaligned, which is exactly the kind of
    ///     quiet degradation that reads as "the feature is bad".
    static func make(stems: [Stem],
                     keep: Set<String>,
                     models: [ModelInfo],
                     restyleModelId: String? = nil,
                     sourceIsAnalyzed: Bool = true) -> StyleTransferChain {

        let audioStems = stems.filter {
            $0.kind.hasPrefix("stem.") || $0.kind.hasPrefix("layer.")
        }
        let hasStems = !audioStems.isEmpty

        let separator = models.first {
            $0.installState == .installed
                && $0.capabilities.supportedTasks.contains("separate")
        }
        let mixer = MixModels.mixdown(in: models)
        let restyler = StyleTransferMode.cover.eligible(models).first {
            $0.id == restyleModelId
        } ?? StyleTransferMode.cover.eligible(models).first

        // Report every missing piece at once. Told about them one at a time,
        // the user installs a model, comes back, and is told about the next.
        var missing: [String] = []
        if !hasStems && separator == nil { missing.append("a separation model") }
        if restyler == nil { missing.append("a model that can cover") }
        if mixer == nil { missing.append("a mixdown model") }
        guard missing.isEmpty else {
            return StyleTransferChain(
                steps: [], keptKinds: [], replacedKinds: [],
                blockedReason: "Needs \(list(missing)).",
                warnings: [], needsSplitFirst: !hasStems)
        }

        // No stems yet: the split is the whole plan. Which stems exist is not
        // knowable in advance — the catalog does not declare a separation
        // model's outputs, and Demucs' six-stem build, the four-stem builds and
        // the RoFormer vocals/instrumental builds all disagree. Guessing here
        // and reconciling later would mean showing the user checkboxes for
        // stems their model will never produce.
        if !hasStems {
            guard let separator else {
                return StyleTransferChain(
                    steps: [], keptKinds: [], replacedKinds: [],
                    blockedReason: "Needs a separation model.",
                    warnings: [], needsSplitFirst: true)
            }
            return StyleTransferChain(
                steps: [.split(modelId: separator.id,
                               modelName: separator.displayName)],
                keptKinds: [], replacedKinds: [],
                blockedReason: nil,
                warnings: ["Which stems this song has is not known until it is "
                           + "split. Choose what to keep once the stems arrive."],
                needsSplitFirst: true)
        }

        let kept = audioStems.filter { keep.contains($0.kind) }
        let replaced = audioStems.filter { !keep.contains($0.kind) }

        if kept.isEmpty {
            return StyleTransferChain(
                steps: [], keptKinds: [], replacedKinds: [],
                blockedReason: "Choose at least one stem to keep — otherwise "
                    + "this is a plain restyle of the whole song.",
                warnings: [], needsSplitFirst: false)
        }
        if replaced.isEmpty {
            return StyleTransferChain(
                steps: [], keptKinds: kept.map(\.kind), replacedKinds: [],
                blockedReason: "Leave at least one stem for the model to "
                    + "replace.",
                warnings: [], needsSplitFirst: false)
        }

        guard let restyler, let mixer else {
            return StyleTransferChain(
                steps: [], keptKinds: kept.map(\.kind),
                replacedKinds: replaced.map(\.kind),
                blockedReason: "Needs a model that can cover and a mixdown "
                    + "model.",
                warnings: [], needsSplitFirst: false)
        }

        var steps: [Step] = []
        // One stem to replace goes to the model as it is; two or more have to
        // become one file first, because every restyle model takes a single
        // source audio.
        if replaced.count > 1 {
            steps.append(.fold(modelId: mixer.id, modelName: mixer.displayName,
                               kinds: replaced.map(\.label)))
        }
        steps.append(.restyle(modelId: restyler.id,
                              modelName: restyler.displayName,
                              kinds: replaced.map(\.label)))
        steps.append(.remix(modelId: mixer.id, modelName: mixer.displayName,
                            keptKinds: kept.map(\.label)))

        var warnings: [String] = []
        if !sourceIsAnalyzed {
            warnings.append(
                "This song has no tempo analysis yet, so the final mix will "
                    + "line the parts up by their start rather than by beat.")
        }
        // Worth saying out loud once rather than letting it be discovered: the
        // restyle model is handed audio, not a description of what that audio
        // is. Stem-aware conditioning would be a contract change.
        warnings.append(
            "The model is not told which instruments it is replacing — it "
                + "hears the mix of them and re-performs what it hears.")

        return StyleTransferChain(
            steps: steps,
            keptKinds: kept.map(\.kind),
            replacedKinds: replaced.map(\.kind),
            blockedReason: nil,
            warnings: warnings,
            needsSplitFirst: false)
    }

    // MARK: - Progress

    /// Where a partially-run chain has got to, for the commit bar and so that
    /// navigating away and back does not lose the thread.
    struct Progress: Equatable, Codable, Sendable {
        /// Index into `steps` of the job currently running.
        var stepIndex: Int = 0
        /// The job id of the step currently running, so a completion event can
        /// be matched back to the chain.
        var jobId: String?
        /// Part ids produced along the way, in step order. Left in place on
        /// failure: a half-finished chain still leaves usable stems in the
        /// Library, and throwing them away to keep the state tidy would be
        /// destroying the expensive half of the work.
        var producedPartIds: [String] = []
        /// The song id the restyle step produced, once it has.
        var restyledSongId: String?
        var failure: String?

        init() {}

        var isFailed: Bool { failure != nil }
    }

    /// "Step 2 of 3 — Restyle the rest".
    func statusLine(_ progress: Progress) -> String {
        guard !steps.isEmpty else { return "" }
        if let failure = progress.failure {
            return "Stopped at step \(progress.stepIndex + 1): \(failure)"
        }
        let index = min(progress.stepIndex, steps.count - 1)
        return "Step \(index + 1) of \(steps.count) — \(steps[index].title)"
    }

    // MARK: - Copy helpers

    /// "vocals", "vocals and drums", "vocals, drums and bass".
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

private extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}

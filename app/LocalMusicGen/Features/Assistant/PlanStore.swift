import Foundation
import Observation

/// Asks a model to plan before it renders.
///
/// The counterpart to `AssistantStore`, and deliberately shaped the same way:
/// one slot per page, a short task job, an answer that lives in `result.meta`
/// and never becomes a library row.
///
/// What makes it worth a store of its own is that the model is different. An
/// assist job runs on the small writing assistant; a plan job runs on the
/// *music* model whose plan is being asked for, because the plan is that
/// model's own — a plan written by anything else would render as something
/// else entirely.
@MainActor
@Observable
final class PlanStore {
    enum Phase: Equatable {
        case idle
        case working
        case done([SongPlan])
        case failed(String)

        var isWorking: Bool { self == .working }

        var plans: [SongPlan] {
            if case .done(let plans) = self { return plans }
            return []
        }
    }

    private(set) var phases: [String: Phase] = [:]
    var client: BackendClient?

    private var tasks: [String: Task<Void, Never>] = [:]

    func phase(_ slot: String) -> Phase { phases[slot] ?? .idle }

    func clear(_ slot: String) {
        tasks[slot]?.cancel()
        tasks[slot] = nil
        phases[slot] = .idle
    }

    /// Ask `model` for `count` plans of the described song.
    ///
    /// Nothing is rendered. Each plan comes back with the facts the model
    /// chose — tempo, key, time signature, its own rewrite of the caption —
    /// and an opaque sketch that can later be handed back to render that exact
    /// plan.
    func plan(slot: String, model: ModelInfo, caption: String,
              lyrics: String, durationS: Double, count: Int,
              pinned: PinnedFacts = PinnedFacts()) {
        tasks[slot]?.cancel()
        guard let client else {
            phases[slot] = .failed(MetaJobRunner.Failure.notConnected.message)
            return
        }
        guard PlanModels.canPlan(model) else {
            phases[slot] = .failed("\(model.displayName) does not plan ahead.")
            return
        }

        var params: [String: JSONValue] = [
            "plan_caption": .string(caption),
            "plan_count": .int(max(1, min(6, count))),
        ]
        if !lyrics.isEmpty { params["plan_lyrics"] = .string(lyrics) }
        if durationS > 0 { params["plan_duration_s"] = .double(durationS) }
        // Only what the user actually pinned. A value sent here is a value the
        // planner stops choosing, so sending our own defaults would quietly
        // switch off the planning this whole screen exists to show.
        if let bpm = pinned.bpm { params["bpm"] = .int(bpm) }
        if let key = pinned.keyscale { params["keyscale"] = .string(key) }
        if let time = pinned.timeSignature {
            params["timesignature"] = .string(time)
        }

        phases[slot] = .working
        tasks[slot] = Task { [weak self] in
            let outcome = await MetaJobRunner.run(
                client: client, modelId: model.id, task: "plan",
                params: params.filter { model.declares($0.key) })
            guard let self, !Task.isCancelled else { return }
            switch outcome {
            case .success(let job):
                let plans = SongPlan.all(meta: job.result?.meta)
                self.phases[slot] = plans.isEmpty
                    ? .failed(MetaJobRunner.Failure.empty.message)
                    : .done(plans)
            case .failure(let failure):
                self.phases[slot] = .failed(failure.message)
            }
            self.tasks[slot] = nil
        }
    }

    /// The facts a user has taken out of the model's hands.
    struct PinnedFacts: Equatable, Sendable {
        var bpm: Int?
        var keyscale: String?
        var timeSignature: String?

        var isEmpty: Bool {
            bpm == nil && keyscale == nil && timeSignature == nil
        }

        /// As generate params, for the render that follows a chosen plan.
        var params: [String: JSONValue] {
            var out: [String: JSONValue] = [:]
            if let bpm { out["bpm"] = .int(bpm) }
            if let keyscale { out["keyscale"] = .string(keyscale) }
            if let timeSignature {
                out["timesignature"] = .string(timeSignature)
            }
            return out
        }
    }
}

extension ModelInfo {
    /// Whether this model declares a param, so the app can drop keys it would
    /// not understand.
    ///
    /// The engine discards undeclared params *silently* (contract §5.1), which
    /// means a mistyped or model-inappropriate key runs, is ignored, and looks
    /// exactly like a setting that did not work. Filtering here turns that
    /// into nothing happening for a visible reason.
    func declares(_ key: String) -> Bool {
        capabilities.params.contains { $0.key == key }
    }
}

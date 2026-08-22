import Foundation
import Observation

/// Wall-clock measurement of one render's stages.
///
/// The engine says *which* phase is running and never how long any of them
/// took: `job.progress` carries a phase id, sometimes a step count, and
/// nothing else (contract §5.5). The render panel prints "0.4 s" beside a
/// finished stage, so those seconds are measured here — stamped when the
/// reported phase changes — rather than asked for. It is the only honest
/// source available: there is no field for a duration, and inventing one from
/// the job's overall fraction would be reporting arithmetic as observation.
///
/// A value type on purpose. It holds no clock of its own — every method takes
/// `now` — so the whole thing is testable without waiting for time to pass.
struct RenderStageTiming: Equatable {
    struct Mark: Equatable {
        let phase: String
        let startedAt: Date
    }

    private(set) var marks: [Mark] = []

    /// Record that `phase` is running as of `now`.
    ///
    /// Repeats and nils are not transitions and are dropped. The stream
    /// repeats the same phase on every progress event — about once a second —
    /// and a nil phase means the adapter cannot name what it is doing, which
    /// is not the same as having moved on from what it named last.
    mutating func observe(phase: String?, at now: Date) {
        guard let phase, marks.last?.phase != phase else { return }
        marks.append(Mark(phase: phase, startedAt: now))
    }

    /// How long a phase took, or how long it has been running.
    ///
    /// A phase followed by another one is finished, and its duration is the
    /// gap between the two stamps. The last is still going, so it is measured
    /// against `now`. A phase that never arrived returns nil — *not* zero: a
    /// stage the model skipped and a stage that took no time are different
    /// claims, and only one of them is ever true.
    func elapsed(_ phase: String, now: Date) -> TimeInterval? {
        guard let index = marks.lastIndex(where: { $0.phase == phase }) else {
            return nil
        }
        let end = index + 1 < marks.count ? marks[index + 1].startedAt : now
        return max(0, end.timeIntervalSince(marks[index].startedAt))
    }

    /// The phase the engine last named, which the panel draws as running.
    var current: String? { marks.last?.phase }

    /// When the first phase was seen — the start of everything measured here.
    var startedAt: Date? { marks.first?.startedAt }

    /// Total time across every phase, running one included.
    func total(now: Date) -> TimeInterval? {
        guard let startedAt else { return nil }
        return max(0, now.timeIntervalSince(startedAt))
    }

    /// Seconds per step of the running phase.
    ///
    /// `step` counts steps *finished*, which is how the rest of the app reads
    /// it — `step / steps` is drawn as the phase's completed fraction — and
    /// how the runtime that actually reports counts means it: acestep.cpp
    /// prints `[DiT] Step 6/8` on its way out of the sixth iteration. So the
    /// rate is the phase's elapsed divided by that count, and there is no rate
    /// to quote before the first one lands.
    func secondsPerStep(step: Int?, now: Date) -> TimeInterval? {
        guard let current, let step, step > 0,
              let elapsed = elapsed(current, now: now) else { return nil }
        return elapsed / Double(step)
    }

    /// Every phase that has finished, with what it took. This is what a run
    /// contributes back to `RenderTimingStore` for the next one to estimate
    /// from.
    func finished() -> [(phase: String, seconds: TimeInterval)] {
        guard marks.count > 1 else { return [] }
        return (0..<(marks.count - 1)).map {
            (marks[$0].phase,
             marks[$0 + 1].startedAt.timeIntervalSince(marks[$0].startedAt))
        }
    }
}

/// What this machine's stages have actually taken, this session.
///
/// The panel wants "≈ 14 s" against a stage that has not started, and nothing
/// in the contract carries one. `est_seconds_per_audio_second` describes a
/// whole render; splitting it across five stages would be inventing four
/// numbers and printing them with a confidence none of them earned — exactly
/// what §5.5 forbids an engine from doing, and no more honest coming from the
/// app.
///
/// So the estimate is a *memory*: the last time this model ran this stage on
/// this Mac, measured by `RenderStageTiming`. A stage nobody has watched yet
/// shows no estimate at all, which is the truth and reads as one.
///
/// Deliberately not persisted. Stage times move with thermal state, what else
/// holds the GPU, and whether the model was already warm — a figure recovered
/// from last week would be quoted with more authority than it deserves. A
/// session is about as far as this kind of number travels.
@MainActor @Observable
final class RenderTimingStore {
    struct Key: Hashable {
        let modelId: String
        let phase: String
    }

    private(set) var seconds: [Key: TimeInterval] = [:]

    /// Last observation wins rather than a running average: a machine that has
    /// warmed up, or a queue that has stopped competing for the GPU, has
    /// genuinely changed the answer, and an average would take several renders
    /// to admit it.
    func record(modelId: String, phase: String, seconds value: TimeInterval) {
        guard value > 0, value.isFinite else { return }
        seconds[Key(modelId: modelId, phase: phase)] = value
    }

    func record(modelId: String, timing: RenderStageTiming) {
        for stage in timing.finished() {
            record(modelId: modelId, phase: stage.phase, seconds: stage.seconds)
        }
    }

    func estimate(modelId: String, phase: String) -> TimeInterval? {
        seconds[Key(modelId: modelId, phase: phase)]
    }
}

import SwiftUI
import XCTest
@testable import LocalMusic

/// The render card's two panes are fed by numbers the engine never sends.
///
/// `job.progress` names a phase and sometimes counts steps; it carries no
/// durations at all (contract §5.5). Every second the panel prints is measured
/// here instead, and the point of these tests is that the measuring stays
/// honest — a stage that never ran has no duration, not a zero, and an
/// estimate is a memory of a real run rather than a share of a total.
final class RenderStageTimingTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func timing() -> RenderStageTiming {
        var timing = RenderStageTiming()
        timing.observe(phase: "prompt_encode", at: t0)
        timing.observe(phase: "lm_reasoning", at: t0.addingTimeInterval(0.4))
        timing.observe(phase: "diffusion", at: t0.addingTimeInterval(6.5))
        return timing
    }

    func testAFinishedStageIsMeasuredBetweenItsOwnStampAndTheNextOne() {
        let now = t0.addingTimeInterval(60)
        XCTAssertEqual(timing().elapsed("prompt_encode", now: now) ?? 0,
                       0.4, accuracy: 0.001)
        XCTAssertEqual(timing().elapsed("lm_reasoning", now: now) ?? 0,
                       6.1, accuracy: 0.001)
    }

    func testTheRunningStageIsMeasuredAgainstNow() {
        XCTAssertEqual(timing().elapsed("diffusion",
                                        now: t0.addingTimeInterval(57.7)) ?? 0,
                       51.2, accuracy: 0.001)
    }

    /// The distinction the panel is built on: a stage the model skipped and a
    /// stage that took no time are different claims, and printing "0.0 s"
    /// against the first one is the wrong one.
    func testAStageThatNeverRanHasNoDurationRatherThanZero() {
        XCTAssertNil(timing().elapsed("vocoder", now: t0.addingTimeInterval(60)))
    }

    /// Progress events repeat the same phase about once a second for the
    /// length of a render. Treating each as a transition would restart the
    /// stage's clock on every one of them.
    func testRepeatsAndNilsAreNotTransitions() {
        var timing = self.timing()
        timing.observe(phase: "diffusion", at: t0.addingTimeInterval(30))
        timing.observe(phase: nil, at: t0.addingTimeInterval(40))
        XCTAssertEqual(timing.marks.count, 3)
        XCTAssertEqual(timing.current, "diffusion")
        XCTAssertEqual(timing.elapsed("diffusion",
                                      now: t0.addingTimeInterval(57.7)) ?? 0,
                       51.2, accuracy: 0.001)
    }

    /// `step` counts steps finished — the reading `step / steps` as a
    /// completed fraction already commits the app to, and what acestep.cpp
    /// means when it prints `[DiT] Step 6/8`.
    func testSecondsPerStepDividesByTheStepsActuallyFinished() {
        let now = t0.addingTimeInterval(6.5 + 48)
        XCTAssertEqual(timing().secondsPerStep(step: 6, now: now) ?? 0,
                       8, accuracy: 0.001)
        XCTAssertNil(timing().secondsPerStep(step: 0, now: now))
        XCTAssertNil(timing().secondsPerStep(step: nil, now: now))
    }

    func testFinishedStagesAreWhatARunHandsBack() {
        let finished = timing().finished()
        XCTAssertEqual(finished.map(\.phase), ["prompt_encode", "lm_reasoning"])
        XCTAssertEqual(finished[1].seconds, 6.1, accuracy: 0.001)
    }

    func testTotalSpansEveryStageIncludingTheRunningOne() {
        XCTAssertEqual(timing().total(now: t0.addingTimeInterval(57.7)) ?? 0,
                       57.7, accuracy: 0.001)
        XCTAssertNil(RenderStageTiming().total(now: t0))
    }
}

@MainActor
final class RenderTimingStoreTests: XCTestCase {
    func testAStageNobodyHasWatchedHasNoEstimate() {
        let store = RenderTimingStore()
        XCTAssertNil(store.estimate(modelId: "acestep-base", phase: "vocoder"))
    }

    func testARunTeachesTheStoreItsFinishedStages() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var timing = RenderStageTiming()
        timing.observe(phase: "prompt_encode", at: t0)
        timing.observe(phase: "diffusion", at: t0.addingTimeInterval(0.4))
        let store = RenderTimingStore()
        store.record(modelId: "m", timing: timing)
        XCTAssertEqual(store.estimate(modelId: "m", phase: "prompt_encode") ?? 0,
                       0.4, accuracy: 0.001)
        // Still running, so nothing to teach yet.
        XCTAssertNil(store.estimate(modelId: "m", phase: "diffusion"))
    }

    func testEstimatesAreKeyedPerModel() {
        let store = RenderTimingStore()
        store.record(modelId: "fast", phase: "diffusion", seconds: 4)
        store.record(modelId: "slow", phase: "diffusion", seconds: 90)
        XCTAssertEqual(store.estimate(modelId: "fast", phase: "diffusion"), 4)
        XCTAssertEqual(store.estimate(modelId: "slow", phase: "diffusion"), 90)
    }

    /// A zero or a NaN is not an observation, and printing "≈ 0 s" against a
    /// stage would promise something no render can keep.
    func testNonMeasurementsAreRefused() {
        let store = RenderTimingStore()
        store.record(modelId: "m", phase: "vocoder", seconds: 0)
        store.record(modelId: "m", phase: "master", seconds: .nan)
        XCTAssertNil(store.estimate(modelId: "m", phase: "vocoder"))
        XCTAssertNil(store.estimate(modelId: "m", phase: "master"))
    }
}

/// The log pane, and the drift readout under it.
@MainActor
final class EngineLogPaneTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func pane(elapsed: TimeInterval, eta: Double?, estimate: Double?,
                      stagesFinished: Int) -> EngineLogPane {
        var timing = RenderStageTiming()
        timing.observe(phase: "a", at: Date().addingTimeInterval(-elapsed))
        for stage in 0..<stagesFinished {
            timing.observe(phase: "s\(stage)",
                           at: Date().addingTimeInterval(-elapsed + 1))
        }
        return EngineLogPane(
            log: JobLog(), telemetry: TelemetryStore(), timing: timing,
            progress: JobProgress(stage: "generating", fraction: 0.5,
                                  etaS: eta, message: nil, take: 0,
                                  phase: nil, step: nil, steps: nil),
            estimateS: estimate, isLive: true)
    }

    /// Before a stage has finished the projection is the estimate plus
    /// nothing, so it would read "0 S VS EST" for the length of a cold model
    /// load and then lurch when the real work started.
    func testDriftIsHeldBackUntilAStageHasFinished() {
        XCTAssertNil(pane(elapsed: 40, eta: 60, estimate: 190,
                          stagesFinished: 0).drift)
        XCTAssertNotNil(pane(elapsed: 40, eta: 60, estimate: 190,
                             stagesFinished: 1).drift)
    }

    func testAheadOfTheEstimateReadsGreenAndBehindReadsAmber() {
        let ahead = pane(elapsed: 40, eta: 60, estimate: 190, stagesFinished: 1)
        XCTAssertEqual(ahead.drift?.text, "−90 S VS EST")
        XCTAssertEqual(ahead.drift?.tone, Bench.Palette.ok)

        let behind = pane(elapsed: 200, eta: 60, estimate: 190, stagesFinished: 1)
        XCTAssertEqual(behind.drift?.text, "+70 S VS EST")
        XCTAssertEqual(behind.drift?.tone, Bench.Palette.warn)
    }

    /// A model that declares no estimate gets no readout, rather than being
    /// compared against a number invented for the occasion.
    func testNoEstimateMeansNoReadout() {
        XCTAssertNil(pane(elapsed: 40, eta: 60, estimate: nil,
                          stagesFinished: 1).drift)
    }

    func testTheFadeRampBottomsOutRatherThanDisappearing() {
        XCTAssertEqual(EngineLogPane.fade(fromEnd: 0), Bench.Palette.textPrimary)
        XCTAssertEqual(EngineLogPane.fade(fromEnd: 3), Bench.Palette.textDimmest)
        XCTAssertEqual(EngineLogPane.fade(fromEnd: 199), Bench.Palette.textDimmest)
    }
}

/// Worker stderr, kept for the pane that draws it.
@MainActor
final class RenderLogRetentionTests: XCTestCase {
    private func store(jobId: String) throws -> JobsStore {
        let store = JobsStore(
            repo: LibraryRepository(db: try DatabaseManager.inMemory()))
        let info = JobInfo(
            jobId: jobId, groupId: "grp", modelId: "acestep-cpp-xl-sft",
            task: "generate", status: .generating, prompt: "p", lyrics: nil,
            durationS: 120, count: 1, params: [:],
            createdAt: "2026-08-22T13:00:00Z", progress: nil, result: nil,
            error: nil)
        store.adopt(JobsStore.ActiveJob(info: info, progress: nil,
                                        status: .generating))
        return store
    }

    func testLinesAreKeptInOrderAndStamped() throws {
        let store = try store(jobId: "job_1")
        store.apply(.jobLog(jobId: "job_1", line: "[DiT] Step 1/8"))
        store.apply(.jobLog(jobId: "job_1", line: "  [DiT] Step 2/8  "))
        let log = store.log(for: "job_1").lines
        XCTAssertEqual(log.map(\.text), ["[DiT] Step 1/8", "[DiT] Step 2/8"])
        XCTAssertEqual(Set(log.map(\.id)).count, 2, "ids must not collide")
    }

    func testBlankLinesAndUnknownJobsAreDropped() throws {
        let store = try store(jobId: "job_1")
        store.apply(.jobLog(jobId: "job_1", line: "   "))
        store.apply(.jobLog(jobId: "nobody", line: "orphan"))
        XCTAssertEqual(store.log(for: "job_1").lines.count, 0)
        XCTAssertFalse(store.log(for: "job_1").hasLines)
        XCTAssertNil(store.active["nobody"])
    }

    /// ggml prints dozens of lines while it mmaps a GGUF and one per step
    /// after that. The buffer is a tail, not a transcript.
    func testTheBufferIsCappedAndKeepsTheNewest() throws {
        let store = try store(jobId: "job_1")
        for line in 0..<(JobsStore.logCap + 50) {
            store.apply(.jobLog(jobId: "job_1", line: "line \(line)"))
        }
        let log = store.log(for: "job_1").lines
        XCTAssertEqual(log.count, JobsStore.logCap)
        XCTAssertEqual(log.last?.text, "line \(JobsStore.logCap + 49)")
        XCTAssertEqual(log.first?.text, "line 50")
    }

    /// The arming is what "Notify me when it lands" writes, and it has to be
    /// spent when the job ends or a long session accumulates every job id.
    func testNotifyArmingClearsWhenTheJobEnds() throws {
        let store = try store(jobId: "job_1")
        store.setNotifyOnLanding("job_1", true)
        XCTAssertTrue(store.notifyOnLanding.contains("job_1"))
        store.apply(.jobCanceled(jobId: "job_1"))
        XCTAssertFalse(store.notifyOnLanding.contains("job_1"))
    }
}

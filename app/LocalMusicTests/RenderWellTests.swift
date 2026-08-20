import XCTest
@testable import LocalMusic

/// The render card's playhead runs on the generating stage and nothing else.
///
/// The bug these pin down: the well used to be driven by the job's overall
/// fraction, which every adapter maps its own way — ACE-Step's llama.cpp
/// runtime gives the denoising loop 0.55…0.95 — so a take on denoising step
/// 11 of 50 drew a well two thirds full. The well now says what the model has
/// made, so at step 11 of 50 it is 22% across whatever the job fraction says.
final class RenderWellTests: XCTestCase {

    private func stage(_ id: String) -> PipelineStage {
        PipelineStage(id: id, label: id, optional: nil)
    }

    /// ACE-Step's llama.cpp runtime, the one in the screenshot.
    private var acestepcpp: [PipelineStage] {
        ["lm_reasoning", "diffusion", "vocoder", "master"].map(stage)
    }

    private var musicgen: [PipelineStage] {
        ["prompt_encode", "lm_decode", "master"].map(stage)
    }

    func testHoldsAtZeroBeforeTheGeneratingStage() {
        // The LM half reports fractions up to 0.55; none of it is audio.
        XCTAssertEqual(RenderWell.edge(stages: acestepcpp, phase: "lm_reasoning",
                                       step: 240, steps: nil, fraction: 0.42), 0)
        XCTAssertEqual(RenderWell.edge(stages: musicgen, phase: "prompt_encode",
                                       step: nil, steps: nil, fraction: 0.1), 0)
    }

    func testRunsOnTheGeneratingStagesOwnSteps() {
        XCTAssertEqual(RenderWell.edge(stages: acestepcpp, phase: "diffusion",
                                       step: 11, steps: 50, fraction: 0.64),
                       0.22, accuracy: 0.0001)
        XCTAssertEqual(RenderWell.edge(stages: musicgen, phase: "lm_decode",
                                       step: 3, steps: 4, fraction: 0.5),
                       0.75, accuracy: 0.0001)
    }

    func testFullOnceGenerationIsPast() {
        // The audio exists in full by the time the vocoder runs — the well
        // stops moving rather than filling in during the tail.
        XCTAssertEqual(RenderWell.edge(stages: acestepcpp, phase: "vocoder",
                                       step: nil, steps: nil, fraction: 0.97), 1)
        XCTAssertEqual(RenderWell.edge(stages: acestepcpp, phase: "master",
                                       step: nil, steps: nil, fraction: 1), 1)
    }

    func testLoadingAndUnknownPhasesDrawAnEmptyWell() {
        XCTAssertEqual(RenderWell.edge(stages: acestepcpp, phase: nil,
                                       step: nil, steps: nil, fraction: 0.3), 0)
        XCTAssertEqual(RenderWell.edge(stages: acestepcpp, phase: "tokenising",
                                       step: nil, steps: nil, fraction: 0.3), 0)
    }

    /// Adapters that name the stage but count nothing inside it (ACE-Step on
    /// torch, MiniMax) keep the old approximation rather than freezing.
    func testUncountedGeneratingStageFallsBackToTheJobFraction() {
        XCTAssertEqual(RenderWell.edge(stages: acestepcpp, phase: "diffusion",
                                       step: nil, steps: nil, fraction: 0.6),
                       0.6, accuracy: 0.0001)
        // A step with no total is not a fraction — it is not treated as one.
        XCTAssertEqual(RenderWell.edge(stages: acestepcpp, phase: "diffusion",
                                       step: 900, steps: nil, fraction: 0.6),
                       0.6, accuracy: 0.0001)
    }

    /// Families that declare no pipeline still get a moving bar.
    func testNoPipelineKeepsTheOverallFraction() {
        XCTAssertEqual(RenderWell.edge(stages: nil, phase: nil, step: nil,
                                       steps: nil, fraction: 0.4),
                       0.4, accuracy: 0.0001)
        XCTAssertEqual(RenderWell.edge(stages: [], phase: nil, step: nil,
                                       steps: nil, fraction: nil), 0)
    }

    /// MiniMax and MLX Audio declare both an LM and a diffusion stage: the
    /// diffusion is the one that writes audio.
    func testDiffusionWinsOverLMDecodeWhenBothAreDeclared() {
        let minimax = ["lm_decode", "diffusion", "vocoder", "master"].map(stage)
        XCTAssertEqual(RenderWell.generativeIndex(in: minimax), 1)
        XCTAssertEqual(RenderWell.edge(stages: minimax, phase: "lm_decode",
                                       step: nil, steps: nil, fraction: 0.5), 0)
    }

    /// Every family the catalog builder declares a pipeline for has a stage
    /// the well can follow — a new family that forgets one would silently fall
    /// back to the overall fraction.
    func testEveryDeclaredPipelineHasAGeneratingStage() {
        let pipelines = [
            ["prompt_encode", "lm_decode", "master"],                       // musicgen
            ["prompt_encode", "diffusion", "master"],                       // stableaudio
            ["lm_reasoning", "prompt_encode", "diffusion", "vocoder",
             "master"],                                                     // acestep
            ["lm_reasoning", "diffusion", "vocoder", "master"],             // acestepcpp
            ["lm_decode", "diffusion", "vocoder", "master"],                // minimax
            ["lm_decode", "diffusion", "master"],                           // mlxaudio
        ]
        for pipeline in pipelines {
            XCTAssertNotNil(RenderWell.generativeIndex(in: pipeline.map(stage)),
                            "no generating stage in \(pipeline)")
        }
    }

    /// Steps outside 0…n never push the playhead off the well.
    func testEdgeStaysInRange() {
        XCTAssertEqual(RenderWell.edge(stages: acestepcpp, phase: "diffusion",
                                       step: 60, steps: 50, fraction: 1), 1)
        XCTAssertEqual(RenderWell.edge(stages: acestepcpp, phase: "diffusion",
                                       step: -2, steps: 50, fraction: 0), 0)
    }
}

import XCTest
@testable import LocalMusicGen

/// What runs unasked when new audio lands — and, more importantly, what does
/// not. Each pass's own ingest re-enters the hooks that started it, so a
/// missing idempotence guard is an infinite loop rather than a duplicate row.
final class AutoRunPlannerTests: XCTestCase {
    private func installed(_ map: [String: [String]]) -> (String) -> [String] {
        { map[$0] ?? [] }
    }

    private let everything = AutoRunPlanner.Preferences(
        autoAnalyze: true, autoDescribe: true, autoTagScan: true,
        autoLyrics: true)

    private let allModels = ["analyze": ["analysis-basic"],
                             "caption": ["caption-lpmusiccaps"],
                             "tag": ["tag-clap"],
                             "lyrics": ["lyrics-whisper-turbo"]]

    /// The default install: analysis only, and the three text passes off.
    func testDefaultsPlanAnalysisAlone() {
        let passes = AutoRunPlanner.passes(
            preferences: .init(), existing: .init(),
            installed: installed(allModels))
        XCTAssertEqual(passes, [.analyze(modelId: "analysis-basic")])
    }

    /// Analysis first: it is the cheapest pass and everything else reads it,
    /// so the heavyweight describer loads once, at the end.
    func testEverythingOnRunsAnalysisFirst() {
        let passes = AutoRunPlanner.passes(
            preferences: everything, existing: .init(),
            installed: installed(allModels))
        XCTAssertEqual(passes, [.analyze(modelId: "analysis-basic"),
                                .describe(modelId: "caption-lpmusiccaps"),
                                .tag(modelId: "tag-clap"),
                                .lyrics(modelId: "lyrics-whisper-turbo")])
    }

    /// The loop guard: everything already present plans nothing at all.
    func testNothingIsRedone() {
        let passes = AutoRunPlanner.passes(
            preferences: everything,
            existing: .init(hasAnalysis: true, hasDescription: true,
                            hasTags: true, hasLyrics: true),
            installed: installed(allModels))
        XCTAssertTrue(passes.isEmpty)
    }

    /// Each guard is independent — a described song with no tags still gets
    /// tagged, and nothing else.
    func testGuardsAreIndependent() {
        let passes = AutoRunPlanner.passes(
            preferences: everything,
            existing: .init(hasAnalysis: true, hasDescription: true,
                            hasTags: false, hasLyrics: true),
            installed: installed(allModels))
        XCTAssertEqual(passes, [.tag(modelId: "tag-clap")])
    }

    /// A preference for work the machine cannot do is not an error, and not
    /// a pass: the passes with no installed model simply do not appear.
    func testUninstallableTasksAreSkipped() {
        let passes = AutoRunPlanner.passes(
            preferences: everything, existing: .init(),
            installed: installed(["analyze": ["analysis-basic"]]))
        XCTAssertEqual(passes, [.analyze(modelId: "analysis-basic")])
    }

    /// A named model wins while it is installed…
    func testANamedModelIsPreferred() {
        var preferences = everything
        preferences.describerModelId = "caption-qwen2audio"
        let passes = AutoRunPlanner.passes(
            preferences: preferences, existing: .init(),
            installed: installed(["caption": ["caption-lpmusiccaps",
                                              "caption-qwen2audio"]]))
        XCTAssertEqual(passes, [.describe(modelId: "caption-qwen2audio")])
    }

    /// …and once it is gone the pass falls back rather than submitting a
    /// model that is not there, or silently stopping.
    func testANamedModelThatIsGoneFallsBack() {
        var preferences = everything
        preferences.describerModelId = "caption-uninstalled"
        let passes = AutoRunPlanner.passes(
            preferences: preferences, existing: .init(),
            installed: installed(["caption": ["caption-lpmusiccaps"]]))
        XCTAssertEqual(passes, [.describe(modelId: "caption-lpmusiccaps")])
    }

    /// Parts are measured like anything else, but describing, tagging and
    /// transcribing every stem of every split would be four model loads per
    /// song and a library full of text nobody asked for.
    func testAPartOnlyEverGetsAnalysis() {
        let passes = AutoRunPlanner.passes(
            preferences: everything, existing: .init(), isPart: true,
            installed: installed(allModels))
        XCTAssertEqual(passes, [.analyze(modelId: "analysis-basic")])
    }
}

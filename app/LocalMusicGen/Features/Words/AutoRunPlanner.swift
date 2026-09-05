import Foundation

/// What should run, unasked, when new audio lands.
///
/// Pure and store-free for the same reason `StyleTransferChain` is: "which
/// passes, on what, and when not to" is a decision worth a test, and the
/// expensive way to find out it is wrong is to watch four models load in
/// sequence behind a render that was supposed to be next.
///
/// The rule every pass obeys: **never redo work that is already there.**
/// Without a per-kind idempotence check, each pass's own ingest re-enters the
/// hooks that started it and the library grinds through an infinite loop of
/// describing what it has just described.
enum AutoRunPlanner {

    /// One thing to run. Model ids are resolved by the caller's catalog, so
    /// a pass in this list is always runnable.
    enum Pass: Equatable {
        case analyze(modelId: String)
        case describe(modelId: String)
        case tag(modelId: String)
        case lyrics(modelId: String)
    }

    /// The settings this reads, snapshotted so the planner never touches the
    /// live store (and so a test can state its inputs in one literal).
    struct Preferences: Equatable {
        var autoAnalyze = true
        var analyzerModelId: String?
        var autoDescribe = false
        var describerModelId: String?
        var autoTagScan = false
        var taggerModelId: String?
        var autoLyrics = false
        var lyricsTranscriberModelId: String?

        init(autoAnalyze: Bool = true, analyzerModelId: String? = nil,
             autoDescribe: Bool = false, describerModelId: String? = nil,
             autoTagScan: Bool = false, taggerModelId: String? = nil,
             autoLyrics: Bool = false,
             lyricsTranscriberModelId: String? = nil) {
            self.autoAnalyze = autoAnalyze
            self.analyzerModelId = analyzerModelId
            self.autoDescribe = autoDescribe
            self.describerModelId = describerModelId
            self.autoTagScan = autoTagScan
            self.taggerModelId = taggerModelId
            self.autoLyrics = autoLyrics
            self.lyricsTranscriberModelId = lyricsTranscriberModelId
        }
    }

    /// What the owner already carries, so nothing is done twice.
    struct Existing: Equatable {
        var hasAnalysis = false
        var hasDescription = false
        var hasTags = false
        var hasLyrics = false

        init(hasAnalysis: Bool = false, hasDescription: Bool = false,
             hasTags: Bool = false, hasLyrics: Bool = false) {
            self.hasAnalysis = hasAnalysis
            self.hasDescription = hasDescription
            self.hasTags = hasTags
            self.hasLyrics = hasLyrics
        }
    }

    /// The passes to submit, in the order they should run.
    ///
    /// Analysis first, always: it is the cheapest, it is the one everything
    /// else in the app reads, and running it before a describer means the
    /// heavyweight model is loaded once at the end rather than in the middle.
    ///
    /// `installed` lists the installed model ids that can run a task, best
    /// first — a pass with no candidate is simply not planned, because a
    /// preference for work the machine cannot do is not an error to report.
    ///
    /// `isPart` narrows the list to analysis: a stem is measured like
    /// anything else, but describing, tagging and transcribing every stem of
    /// every split would be four model loads per song and a library full of
    /// text nobody asked for. The Words cards run those on a part on request.
    static func passes(preferences: Preferences, existing: Existing,
                       isPart: Bool = false,
                       installed: (String) -> [String]) -> [Pass] {
        var passes: [Pass] = []
        if preferences.autoAnalyze, !existing.hasAnalysis,
           let model = resolve(preferences.analyzerModelId, "analyze",
                               installed) {
            passes.append(.analyze(modelId: model))
        }
        guard !isPart else { return passes }
        if preferences.autoDescribe, !existing.hasDescription,
           let model = resolve(preferences.describerModelId, "caption",
                               installed) {
            passes.append(.describe(modelId: model))
        }
        if preferences.autoTagScan, !existing.hasTags,
           let model = resolve(preferences.taggerModelId, "tag", installed) {
            passes.append(.tag(modelId: model))
        }
        if preferences.autoLyrics, !existing.hasLyrics,
           let model = resolve(preferences.lyricsTranscriberModelId, "lyrics",
                               installed) {
            passes.append(.lyrics(modelId: model))
        }
        return passes
    }

    /// The chosen model when it is *still installed*, else the first that can
    /// do the job — the fallback the analyzer preference has always had: a
    /// model uninstalled since the setting was made should not silently stop
    /// the pass it was chosen for, nor be submitted as though it were there.
    private static func resolve(_ preferred: String?, _ task: String,
                                _ installed: (String) -> [String]) -> String? {
        let candidates = installed(task)
        if let preferred, candidates.contains(preferred) { return preferred }
        return candidates.first
    }
}

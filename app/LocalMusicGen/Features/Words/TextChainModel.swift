import Foundation
import Observation

/// The live state of a music↔text pipeline run.
///
/// Owned by `AppEnvironment`, not by the page: a run outlives the view that
/// started it. The telephone game is minutes of work, and leaving Actions to
/// listen to round two must not cancel round three — nor lose the caption the
/// run is parked on, waiting for an edit.
///
/// One run at a time, like `StyleTransferModel.chain`. Two pipelines racing
/// through one serial engine queue would take twice as long and read as
/// nothing happening.
@MainActor @Observable
final class TextChainModel {

    /// A run in flight.
    struct Run: Equatable {
        /// Guards against a stale step writing into an abandoned run — every
        /// submit and ingest re-reads this before touching anything.
        let id: String
        var recipeId: String
        var plan: TextChain
        var progress: TextChain.Progress
        var sourceId: String
        var sourceSongId: String
        var sourceTitle: String
        /// What the finished audio is called; rounds get a suffix.
        var name: String

        var currentStage: TextChain.Stage? {
            guard progress.stageIndex < plan.stages.count else { return nil }
            return plan.stages[progress.stageIndex]
        }

        var isFinished: Bool {
            progress.stageIndex >= plan.stages.count
        }
    }

    /// Everything a run needs from the outside — the stores arrive as
    /// parameters rather than as stored references, as they do for the style
    /// transfer chain.
    struct RunContext {
        let jobs: JobsStore
        let parts: PartsStore
        let library: LibraryStore
        let textStore: TextStore
        let models: [ModelInfo]
    }

    private(set) var run: Run?
    /// A line the page shows once, when a run ends or is dismissed.
    var notice: String?

    var isRunning: Bool {
        guard let run else { return false }
        return !run.isFinished && !run.progress.isFailed
    }

    /// Whether the run is parked, waiting for the user to edit the text.
    var isAwaitingEdit: Bool { run?.progress.awaitingEdit ?? false }

    /// The run belonging to this card, if the live one does.
    func run(forRecipe recipeId: String) -> Run? {
        run?.recipeId == recipeId ? run : nil
    }

    // MARK: - Starting

    @discardableResult
    func start(recipeId: String, plan: TextChain, source: PickedMaterial,
               name: String, context: RunContext) async -> String? {
        guard plan.isRunnable else { return nil }
        run = Run(id: UUID().uuidString, recipeId: recipeId, plan: plan,
                  progress: .init(), sourceId: source.id,
                  sourceSongId: source.songId, sourceTitle: source.name,
                  name: name)
        notice = nil
        return await submitCurrentStage(context)
    }

    func dismiss() {
        run = nil
        notice = nil
    }

    // MARK: - Running

    /// Fire the stage the run is pointing at, or park on an edit.
    @discardableResult
    func submitCurrentStage(_ context: RunContext) async -> String? {
        guard let started = run, let stage = started.currentStage else {
            return nil
        }
        let runId = started.id

        // An edit stage submits nothing: it hands control back and waits,
        // exactly as the stem chain does after a split. The run stays alive
        // so the page (or another page) can continue it.
        if case .editText = stage {
            guard var current = run, current.id == runId else { return nil }
            current.progress.awaitingEdit = true
            current.progress.jobId = nil
            run = current
            return nil
        }

        guard let source = material(in: context) else {
            fail("The source is no longer in the library.")
            return nil
        }

        let jobId: String?
        switch stage {
        case .separate(let modelId, _):
            jobId = (await context.jobs.submitSplit(
                modelId: modelId, songId: source.songId,
                sourceTitle: source.sourceTitle, sourceURL: source.fileURL,
                params: [:]))?.jobs.first?.jobId

        case .transcribeLyrics(let modelId, _):
            jobId = (await context.jobs.submitLyrics(
                modelId: modelId, ownerId: source.id,
                ownerType: source.kind == "song.mix" ? "song" : "part",
                title: source.name,
                sourceURL: source.fileURL))?.jobs.first?.jobId

        case .caption(let modelId, _):
            jobId = (await context.jobs.submitCaption(
                modelId: modelId, ownerId: source.id,
                ownerType: source.kind == "song.mix" ? "song" : "part",
                title: source.name, sourceURL: source.fileURL,
                kind: .caption))?.jobs.first?.jobId

        case .extractABC(let modelId, _):
            jobId = (await context.jobs.submitTranscribe(
                modelId: modelId, songId: source.songId,
                sourceTitle: source.sourceTitle, sourceURL: source.fileURL,
                params: ["emit_abc": .bool(true)]))?.jobs.first?.jobId

        case .generate(let modelId, _, let durationS):
            guard let text = started.progress.effectiveText, !text.isEmpty else {
                fail("There were no words to generate from.")
                return nil
            }
            jobId = (await context.jobs.submit(
                modelId: modelId, prompt: text, lyrics: nil,
                durationS: durationS, count: 1, params: [:],
                name: roundName(started)))?.jobs.first?.jobId

        case .composeABC(let modelId, _):
            guard let text = started.progress.effectiveText, !text.isEmpty else {
                fail("There was no notation to compose from.")
                return nil
            }
            jobId = (await context.jobs.submitComposeABC(
                modelId: modelId, abc: text, songId: source.songId,
                sourceTitle: source.sourceTitle))?.jobs.first?.jobId

        case .editText:
            jobId = nil   // handled above
        }

        // Re-read: uploads and submits are awaits, and the user was never
        // frozen while they ran.
        guard var current = run, current.id == runId else { return nil }
        guard let jobId else {
            current.progress.failure = context.jobs.lastError
                ?? "The engine would not take the job."
            run = current
            return nil
        }
        current.progress.jobId = jobId
        current.progress.awaitingEdit = false
        run = current
        return jobId
    }

    /// The user rewrote the text; carry on from there.
    @discardableResult
    func continueAfterEdit(_ text: String,
                           context: RunContext) async -> String? {
        guard var current = run, current.progress.awaitingEdit else {
            return nil
        }
        current.progress.editedText = text
        current.progress.awaitingEdit = false
        current.progress.stageIndex += 1
        run = current
        return await submitCurrentStage(context)
    }

    // MARK: - Landing

    /// Something landed; work out whether it was ours and move on if so.
    ///
    /// Matching mirrors the style-transfer chain: parts and text documents
    /// carry their `jobId`, songs do not — but `ingestGenerate` sets the job
    /// to `.succeeded` immediately before the hook fires, so a tracked job
    /// reading succeeded at this moment is the one that produced them.
    func ingested(songs: [SongRecord], parts: [PartRecord],
                  texts: [TextDocRecord], context: RunContext) async {
        guard var current = run, let stage = current.currentStage,
              let waitingFor = current.progress.jobId else { return }
        let mine = texts.contains { $0.jobId == waitingFor }
            || parts.contains { $0.jobId == waitingFor }
            || (!songs.isEmpty
                && context.jobs.job(waitingFor)?.status == .succeeded)
        guard mine else { return }

        current.progress.producedDocIds += texts.map(\.id)
        current.progress.producedSongIds += songs.map(\.id)

        switch stage {
        case .separate:
            // The vocal is what the next stage should listen to. A stem the
            // separator just produced is a better source than the mix that
            // was picked, so the run re-points itself at it.
            if let vocal = parts.first(where: {
                $0.kind.hasPrefix("stem.vocals")
            }) {
                current.sourceId = vocal.id
            }
        case .caption, .transcribeLyrics, .extractABC:
            // The words the next stage reads. An empty result stops the run
            // rather than generating from nothing.
            var landed = texts.first?.text
            // ...unless this is the notation step, which is fed by a job that
            // lands midi parts *and* an ABC document. Those reach the chain as
            // two deliveries, and only one of them carries text: if the
            // parts-only one is seen first, "the model wrote nothing" is not
            // what happened. Every row is written before either delivery is
            // sent, so the database is the authority here.
            if landed == nil, stage.id == "abc" {
                landed = abcFromJob(waitingFor, context: context)
            }
            if let landed, !landed.isEmpty {
                current.progress.text = landed
                current.progress.editedText = nil
            } else if stage.id != "lyrics" {
                current.progress.failure = "The model wrote nothing to go on."
            }
        case .generate:
            // The new take becomes the source for the next round's caption:
            // hand-off by record id, never by upload id — those do not
            // survive an engine restart.
            if let song = songs.first {
                current.sourceId = song.id
                current.sourceSongId = song.id
                current.sourceTitle = song.title
                current.progress.round += 1
                current.progress.text = nil
                current.progress.editedText = nil
            }
        case .composeABC, .editText:
            break
        }

        current.progress.jobId = nil
        current.progress.stageIndex += 1
        run = current

        if current.progress.isFailed { return }
        if current.isFinished {
            notice = Self.finishedNotice(current)
            return
        }
        await submitCurrentStage(context)
    }

    /// A job the run was waiting on failed or was cancelled.
    func stepFailed(jobId: String, message: String) {
        guard var current = run, current.progress.jobId == jobId else { return }
        current.progress.failure = message
        current.progress.jobId = nil
        run = current
    }

    // MARK: - Helpers

    private func fail(_ message: String) {
        guard var current = run else { return }
        current.progress.failure = message
        current.progress.jobId = nil
        run = current
    }

    /// The notation a transcribe job wrote, read back from the database.
    ///
    /// The ABC ingest files the document on the *source song* (the `.split`
    /// job context's owner), which is where `extractABC` submitted from — so
    /// this asks the same question the delivery would have answered.
    private func abcFromJob(_ jobId: String, context: RunContext) -> String? {
        guard let ownerId = material(in: context)?.songId else { return nil }
        let docs = (try? context.textStore.repository
            .textDocs(ownerId: ownerId)) ?? []
        // Newest first within a kind (`PartsRepository.textDocs`), which is
        // the same one `texts.first` would have handed over.
        return docs.first { $0.jobId == jobId }?.text
    }

    private func material(in context: RunContext) -> PickedMaterial? {
        guard let run else { return nil }
        return PickedMaterial.resolve(id: run.sourceId, parts: context.parts,
                                      library: context.library)
    }

    /// Rounds are named so the library reads as a sequence rather than as
    /// four unrelated tracks with the same title.
    private func roundName(_ run: Run) -> String? {
        guard run.plan.kind.repeats else { return run.name.isEmpty ? nil : run.name }
        let base = run.name.isEmpty ? run.sourceTitle : run.name
        return "\(base) — round \(run.progress.round + 1)"
    }

    private static func finishedNotice(_ run: Run) -> String {
        let songs = run.progress.producedSongIds.count
        switch run.plan.kind {
        case .lyrics:
            return "The words are on the track, in the Library."
        case .abcRoundTrip, .abcEdited:
            return "The notation became a new part — find it in Library › "
                + "Parts, and render it to hear it."
        default:
            return songs == 1
                ? "The new take is in your Library."
                : "\(songs) takes are in your Library."
        }
    }
}

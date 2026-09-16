import Foundation

/// Submission and the multi-step chain.
///
/// Split out from the document itself so `StyleTransferModel` stays a
/// value-shaped thing in the mould of `WorkbenchModel`, and so the stores
/// arrive as parameters rather than as stored references — the chain needs four
/// of them, and a document that holds four stores is not a document.
extension StyleTransferModel {

    // MARK: - One-shot submission

    /// Everything the workspace needs from the outside to run.
    struct RunContext {
        let jobs: JobsStore
        let parts: PartsStore
        let library: LibraryStore
        let models: [ModelInfo]
    }

    /// Submit the configured transformation.
    ///
    /// The wire semantics below are ported wholesale from
    /// `GenerativeActionView.submit(back:)`, whose own comment flagged it as
    /// expensive-to-get-right: which key carries the audio, the extract quirk
    /// of sending the human title as the prompt so the adapter can drop it from
    /// the caption, and the extend-audio length arithmetic. What changed is
    /// where the params come from — a mode plus an overrides dict rather than a
    /// form state that dies with the view.
    ///
    /// Returns the job id, or nil if it never left.
    @discardableResult
    func run(_ context: RunContext) async -> String? {
        guard let model = model(in: context.models) else { return nil }
        if mode.isChain {
            return await startChain(context)
        }
        guard let source = source ?? reference else { return nil }

        submitting = true
        defer { submitting = false }

        // Uploads are made fresh at submit rather than cached: an upload id
        // does not survive an engine restart, because `uploads/` is purged at
        // startup. The workspace persists file URLs for exactly this reason.
        // A model with no input for the source in this mode gets no upload:
        // the param would be filtered out below anyway, and the screen has
        // already told the user the track is ignored — spending a round-trip
        // shipping megabytes the job cannot read helps nobody.
        let sourceReaches = model.capabilities.params
            .contains { $0.key == mode.sourceAudioKey }
        var sourceUpload: String?
        if self.source != nil, sourceReaches,
           let uploaded = await context.jobs.uploadAudio(fileURL: source.fileURL) {
            sourceUpload = uploaded
        } else if self.source != nil, sourceReaches {
            return nil          // uploadAudio has already set jobs.lastError
        }
        var referenceUpload: String?
        if mode.referenceNeed.isNeeded, let reference {
            referenceUpload = await context.jobs.uploadAudio(
                fileURL: reference.fileURL)
            // The source arm above returns when its upload fails; this one used
            // to carry straight on. `wireParams` then simply omitted the
            // reference key — and for `.reference` with no source,
            // `wireTask(hasSource:)` flips to "text2music" — so the mode whose
            // whole promise is "sound like this" rendered an ordinary
            // text-to-music take that had never heard the reference, and the
            // only hint was a stale-looking error beside a job that was already
            // running.
            if referenceUpload == nil {
                guard mode.referenceNeed != .required else {
                    return nil      // uploadAudio has already set jobs.lastError
                }
                notice = "The reference track could not be uploaded"
                    + (context.jobs.lastError.map { " — \($0)" } ?? ".")
                    + " This run went ahead without it."
            }
        }

        // Order matters: the user's advanced knobs go down first, then the
        // mode's own keys over the top, so a stale override of a key the
        // workspace owns can never win. Both halves are filtered against what
        // the model declares — the engine drops unknown keys silently, so a
        // typo would otherwise vanish with only a job.log line to show for it.
        var params = applicableOverrides(in: context.models)
        let wire = mode.wireParams(
            .init(sourceUploadId: sourceUpload,
                  referenceUploadId: referenceUpload,
                  track: track,
                  regionStartS: regionStartS, regionEndS: regionEndS,
                  // Always explicit, never implicit: the engine substitutes
                  // no defaults of its own, so omitting the dial would hand
                  // the job upstream's value rather than the one the slider is
                  // sitting on. What the user sees is what is sent.
                  styleAmount: mode.dial == nil
                      ? nil : effectiveStyleAmount(in: context.models),
                  sourceCaption: mode == .morph ? sourceCaption : nil),
            model: model, spec: mode.dialSpec(for: model))
        for (key, value) in wire { params[key] = value }

        let title = effectiveName
        // Generate jobs require a prompt; extract has no prompt field, and
        // sends the human title instead — which the adapter drops from the
        // caption so it cannot bias the stem it is pulling out.
        let wirePrompt = mode.needsPrompt ? prompt : title

        var jobContext: JobContext?
        if mode.outputsPart {
            let trackName = track ?? "layer"
            jobContext = .generativePart(
                songId: source.songId, sourceTitle: source.sourceTitle,
                kind: mode == .extract ? "stem.\(trackName)"
                                       : "layer.\(trackName)",
                name: mode == .extract ? "AI \(trackName.capitalized)"
                                       : "\(trackName.capitalized) layer")
        } else {
            jobContext = .generate(name: outputName.isEmpty ? nil : outputName)
        }

        let created = await context.jobs.submitGenerative(
            modelId: model.id, prompt: wirePrompt,
            lyrics: wantsLyrics(in: context.models) && !lyrics.isEmpty
                ? lyrics : nil,
            durationS: requestedDurationS(model: model),
            params: params, context: jobContext)
        if let jobId = created?.jobs.first?.jobId {
            pendingRuns[jobId] = .init(modeTitle: mode.title,
                                       styleAmount: styleAmount)
            return jobId
        }
        return nil
    }

    // `requestedDurationS` lives on the document (`StyleTransferModel`, MARK:
    // Length) beside the `lengthS` the user sets and the policy that says what
    // it means. It used to be here, returning the model's nominal default for
    // every mode but `continue` — which was right for the ACE-Step families,
    // whose adapters resolve length from the source, and silently truncated
    // everywhere else.

    /// Whether the lyrics editor belongs on screen: the mode has words to
    /// change *and* the chosen model can sing them.
    func wantsLyrics(in models: [ModelInfo]) -> Bool {
        mode.allowsLyrics && (model(in: models)?.capabilities.supportsLyrics ?? false)
    }

    // MARK: - The chain

    /// Plan and start "keep chosen stems".
    @discardableResult
    func startChain(_ context: RunContext) async -> String? {
        refreshPlannerInput(parts: context.parts)
        guard let plan = plannedChain(in: context.models), plan.isRunnable else {
            return nil
        }
        let stems = plannerInput
        var run = ChainRun(id: UUID().uuidString, plan: plan, progress: .init(),
                           prompt: prompt, name: effectiveName,
                           styleAmount: styleAmount)
        // The part ids are resolved once, here. Re-resolving them per step
        // would let a split finishing in another tab re-target the mix
        // half-way through it.
        //
        // Split on the tick rather than on the kind: re-splitting a song with a
        // different separator leaves two `stem.vocals` parts on it, and
        // matching by kind would put both of them in — the original vocal
        // mixed against itself, and then again against the restyled backing.
        let kept = Set(keptStems)
        run.keptPartIds = stems.filter { kept.contains($0.kind) }.map(\.id)
        run.replacedPartIds = stems.filter { !kept.contains($0.kind) }.map(\.id)
        chain = run
        // Only the chain's own leftovers are cleared: an un-applied preset is
        // still waiting on an answer, and its buttons live in the same strip.
        if pendingPreset == nil { notice = nil }
        return await submitCurrentChainStep(context)
    }

    /// Fire the step the chain is currently pointing at.
    @discardableResult
    func submitCurrentChainStep(_ context: RunContext) async -> String? {
        guard let started = chain, let step = started.currentStep else {
            return nil
        }
        let runId = started.id
        submitting = true
        defer { submitting = false }

        let jobId: String?
        switch step {
        case .split(let modelId, _):
            guard let source,
                  let song = ((try? context.library.repository
                      .song(id: source.songId)) ?? nil) else {
                jobId = nil
                break
            }
            jobId = (await context.jobs.submitSplit(
                modelId: modelId, songId: song.id, sourceTitle: song.title,
                sourceURL: song.fileURL, params: [:]))?.jobs.first?.jobId

        case .fold(let modelId, _, _):
            // Stems of one song already share a grid, so nothing is matched or
            // stretched — doing so would drift them against each other for no
            // reason. This is a sum, not a mix.
            var options = RecombineOptions()
            options.autoMatchTempo = false
            options.autoMatchKey = false
            let ingredients = started.replacedPartIds.enumerated()
                .map { index, id in
                    IngredientSubmission(slotId: "replace\(index)", partId: id)
                }
            jobId = (await context.jobs.submitRecombine(
                modelId: modelId, recipeId: "keep-stems",
                title: "\(started.name) — backing",
                ingredients: ingredients, options: options))?.jobs.first?.jobId

        case .restyle(let modelId, _, _):
            jobId = await submitChainRestyle(modelId: modelId, run: started,
                                             context: context)

        case .remix(let modelId, _, _):
            guard let restyledSongId = started.restyledSongId else {
                jobId = nil
                break
            }
            var ingredients = started.keptPartIds.enumerated()
                .map { index, id in
                    IngredientSubmission(slotId: "keep\(index)", partId: id)
                }
            // A song id is legal in `partId`; it resolves as a "song.mix" row.
            ingredients.append(IngredientSubmission(slotId: "restyled",
                                                    partId: restyledSongId))
            jobId = (await context.jobs.submitRecombine(
                modelId: modelId, recipeId: "keep-stems", title: started.name,
                ingredients: ingredients))?.jobs.first?.jobId
        }

        // Uploading and submitting are awaits, and the user is not frozen
        // while they run. Re-read the chain rather than writing back the copy
        // taken before them: Clear, a new preset or a second run in between
        // would otherwise be undone by a step that finished dispatching after
        // the workspace had already moved on.
        guard var run = chain, run.id == runId else { return nil }
        guard let jobId else {
            run.progress.failure = context.jobs.lastError
                ?? "Could not start \(step.title.lowercased())."
            chain = run
            return nil
        }
        run.progress.jobId = jobId
        chain = run
        return jobId
    }

    /// The middle step: re-perform whatever is not being kept.
    private func submitChainRestyle(modelId: String, run: ChainRun,
                                    context: RunContext) async -> String? {
        // One stem goes to the model as it is; several were folded into a song
        // by the previous step.
        let fileURL: URL?
        if let foldedSongId = run.foldedSongId {
            fileURL = ((try? context.library.repository.song(id: foldedSongId))
                ?? nil)?.fileURL
        } else if let partId = run.replacedPartIds.first {
            fileURL = ((try? context.parts.repository.part(id: partId))
                ?? nil)?.fileURL
        } else {
            fileURL = nil
        }
        guard let fileURL,
              let upload = await context.jobs.uploadAudio(fileURL: fileURL),
              let model = context.models.first(where: { $0.id == modelId })
        else { return nil }

        var params = applicableOverrides(in: context.models)
        let amount = run.styleAmount
            ?? StyleTransferMode.cover.dial?
                .defaultStyleAmount(spec: StyleTransferMode.cover
                    .dialSpec(for: model))
        let wire = StyleTransferMode.cover.wireParams(
            .init(sourceUploadId: upload, styleAmount: amount),
            model: model,
            spec: StyleTransferMode.cover.dialSpec(for: model))
        for (key, value) in wire { params[key] = value }

        // No lyrics: this step re-performs the stems being *replaced*, which
        // for "keep the vocal" is the band. Words sung over the band would
        // fight the vocal that is about to be mixed back in.
        let created = await context.jobs.submitGenerative(
            modelId: modelId,
            prompt: run.prompt.isEmpty ? "the same song, new arrangement"
                                       : run.prompt,
            lyrics: nil,
            // Left at the nominal default rather than taken from the length
            // control, and not an oversight: this step is a `cover` on a
            // cover-capable model, every one of which is in
            // `sourceLengthFamilies` — the adapter resolves the length from the
            // folded song it is handed and discards this number. The chain's
            // output is as long as the song it is rebuilding, by construction.
            durationS: model.capabilities.duration.defaultS,
            params: params,
            context: .generate(name: "\(run.name) — restyled backing"))
        return created?.jobs.first?.jobId
    }

    /// Anything this workspace was waiting on has landed.
    ///
    /// One entry point for both a one-shot run and a chain step, because the
    /// dependency container has one place to call from: `JobsStore`'s ingest
    /// hooks are single-assignment properties already owned by
    /// `AppEnvironment`, so a feature that claims one deletes the auto-analyze
    /// wiring rather than joining it.
    func ingested(songs: [SongRecord], parts: [PartRecord],
                  jobs: JobsStore, partsStore: PartsStore,
                  library: LibraryStore, models: [ModelInfo]) async {
        recordLandedTakes(songs: songs, parts: parts, jobs: jobs)
        guard isChainRunning else { return }
        await advanceChain(songs: songs, parts: parts, jobs: jobs,
                           partsStore: partsStore, library: library,
                           models: models)
    }

    /// Turn a landed one-shot run into a take.
    ///
    /// Parts carry their `jobId`, so they match exactly. Songs do not — but
    /// the job row records what it put in the library (`producedSongIds`,
    /// written before the ingest hook fires), so each song still names exactly
    /// one job.
    ///
    /// That last part used to be "whichever tracked job reads succeeded",
    /// taking `landed.values.first`. Two runs finishing together is not exotic
    /// — `reconcile()` marks every finished job succeeded in one block and
    /// only then ingests them one at a time — and then the take was stamped
    /// with a dictionary-order stamp (so take A wore B's mode and dial, the
    /// one number the rail uses to tell takes apart) and *both* entries were
    /// dropped, so B's own hook returned at the guard above and its take never
    /// appeared at all. Comparing two takes back to back is the workspace's
    /// whole purpose.
    private func recordLandedTakes(songs: [SongRecord], parts: [PartRecord],
                                   jobs: JobsStore) {
        guard !pendingRuns.isEmpty else { return }
        for part in parts {
            guard let jobId = part.jobId, let stamp = pendingRuns[jobId] else {
                continue
            }
            recordTake(part: part, stamp: stamp)
            pendingRuns.removeValue(forKey: jobId)
        }
        var landed: Set<String> = []
        for song in songs {
            guard let run = pendingRuns.first(where: { entry in
                jobs.job(entry.key)?.producedSongIds.contains(song.id) == true
            }) else { continue }
            recordTake(song: song, stamp: run.value)
            landed.insert(run.key)
        }
        for jobId in landed { pendingRuns.removeValue(forKey: jobId) }
        forgetRunsThatWillNeverLand(jobs)
    }

    /// Stop waiting on one run — the engine has forgotten it, or it finished
    /// without leaving anything behind. `chainStepFailed` covers the jobs that
    /// fail; the sweep below covers the rest.
    func forgetPendingJob(_ jobId: String) {
        pendingRuns.removeValue(forKey: jobId)
    }

    /// Drop the runs that have finished without giving this workspace a take.
    ///
    /// The sidebar's Style Transfer row spins on `pendingRuns`, and one shape
    /// of finished job never cleared an entry: an `extract`/`layer` run whose
    /// result carries no audio artifact at all is marked succeeded and
    /// delivers `onPartsIngested([])`, so nothing above matched and the
    /// spinner ran until the app was relaunched. (A failed or cancelled job
    /// clears through `chainStepFailed`, which `AppEnvironment.noteJobFailed`
    /// now calls for every settled-badly row; this is the other end of it.)
    ///
    /// Safe to sweep every settled row because a job hands its results over
    /// exactly once, in the same turn its row is marked terminal — so anything
    /// still pending here has already had its delivery, and a row that has
    /// vanished from the queue entirely (dismissed, or pruned by retention)
    /// will never have one.
    private func forgetRunsThatWillNeverLand(_ jobs: JobsStore) {
        for jobId in Array(pendingRuns.keys) {
            guard let job = jobs.job(jobId) else {
                forgetPendingJob(jobId)     // the row is gone from the queue
                continue
            }
            if job.status.isTerminal { forgetPendingJob(jobId) }
        }
    }

    /// A job landed; work out whether it was ours and move on if so.
    ///
    /// Matching is exact for parts, which carry their `jobId`, and by job
    /// status for songs, which do not — `ingestGenerate` sets the active job to
    /// `.succeeded` immediately before calling the ingest hook, so a tracked
    /// job reading succeeded at this moment is the one that produced them.
    /// Imperfect only if two jobs land in the same tick, which a
    /// user-sequenced chain does not do.
    func advanceChain(songs: [SongRecord], parts: [PartRecord],
                      jobs: JobsStore, partsStore: PartsStore,
                      library: LibraryStore, models: [ModelInfo]) async {
        guard var run = chain, let step = run.currentStep,
              let waitingFor = run.progress.jobId else { return }

        let context = RunContext(jobs: jobs, parts: partsStore,
                                 library: library, models: models)
        let mine = parts.contains { $0.jobId == waitingFor }
            || (!songs.isEmpty && jobs.job(waitingFor)?.status == .succeeded)
        guard mine else { return }

        run.progress.producedPartIds.append(contentsOf: parts.map(\.id))

        switch step {
        case .split:
            // The stem list is only knowable now. Stop here and let the user
            // choose what to keep rather than guessing on their behalf —
            // separation models disagree about which stems they produce.
            chain = nil
            refreshPlannerInput(parts: partsStore)
            notice = "Stems are ready. Tick the ones to keep, then run again."
            return

        case .fold:
            run.foldedSongId = songs.first?.id

        case .restyle:
            run.restyledSongId = songs.first?.id

        case .remix:
            if let song = songs.first {
                recordTake(song: song,
                           stamp: .init(modeTitle: StyleTransferMode.stems.title,
                                        styleAmount: run.styleAmount))
            }
            run.progress.stepIndex = run.plan.steps.count
            run.progress.jobId = nil
            chain = run
            notice = "Done — the stems you kept are the original recording."
            return
        }

        run.progress.stepIndex += 1
        run.progress.jobId = nil
        chain = run
        await submitCurrentChainStep(context)
    }

    /// A tracked job failed. Partial results are left in the Library on
    /// purpose: a chain that stopped after the split still produced stems worth
    /// having, and deleting them to keep the state tidy would throw away the
    /// expensive half of the work.
    func chainStepFailed(jobId: String, message: String) {
        pendingRuns.removeValue(forKey: jobId)
        guard var run = chain, run.progress.jobId == jobId else { return }
        run.progress.failure = message
        run.progress.jobId = nil
        chain = run
    }

    /// Forget a chain without touching what it made.
    ///
    /// Deliberately unconditional. A chain waiting on a job the engine has
    /// forgotten — a result that never ingested, a backend restart mid-run —
    /// would otherwise hold the workspace hostage, because every other way out
    /// is gated behind `isChainRunning`. Whatever its jobs still produce lands
    /// in the Library regardless.
    func dismissChain() {
        chain = nil
    }

    // MARK: - Recording a one-shot result

    /// A landed result becomes a take, labelled with what the run *asked* for
    /// rather than with whatever the controls say now.
    func recordTake(song: SongRecord, stamp: RunStamp) {
        record(take: .init(id: song.id, isPart: false, title: song.title,
                           fileURL: song.fileURL, durationS: song.durationS,
                           modelName: song.modelName,
                           modeTitle: stamp.modeTitle,
                           styleAmount: stamp.styleAmount, createdAt: Date()))
    }

    func recordTake(part: PartRecord, stamp: RunStamp) {
        record(take: .init(id: part.id, isPart: true, title: part.name,
                           fileURL: part.fileURL, durationS: part.durationS,
                           modelName: part.modelName,
                           modeTitle: stamp.modeTitle,
                           styleAmount: stamp.styleAmount, createdAt: Date()))
    }
}

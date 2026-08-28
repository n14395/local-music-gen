import Foundation
import Observation

/// What a non-generate job was submitted *for*, so its artifacts can be routed
/// on completion (parts library vs song library). In-memory only: contexts die
/// with the app, matching the engine's in-memory queue semantics.
enum JobContext {
    /// `name` is what the Studio's Name field held at submit — the title the
    /// finished takes get. nil means the field was left at its `trackNNN`
    /// default, which is resolved at *ingest* rather than carried from here:
    /// the number is a high-water mark over the library, and a job queued
    /// behind three others would otherwise claim a number those three are
    /// about to take.
    case generate(name: String?)
    case split(songId: String, sourceTitle: String)
    case analyze(ownerId: String, ownerType: String, title: String)
    case recombine(recipeId: String?, title: String,
                   applied: [AppliedIngredient])
    /// A generative job whose output is a PART of an existing song, not a new
    /// library song: ACE-Step extract ("stem.vocals"), lego ("layer.strings"),
    /// and SoundFont renders of notes parts ("layer.<name>").
    case generativePart(songId: String, sourceTitle: String, kind: String,
                        name: String)
    /// A render the Editor asked for. The artifact never lands in the library
    /// by itself — what happens to it (replace a file in place, save a copy,
    /// become a snippet) is the Editor's decision, made in `onEditorArtifact`.
    case editor(purpose: EditorRenderPurpose)
    /// A music-to-text job (caption / lyrics / tag) whose result becomes a
    /// text document on `ownerId`. Read-once text jobs — a caption shown on a
    /// page and thrown away — run through `MetaJobRunner` instead and never
    /// carry a context; this case exists precisely for the results that
    /// become library rows and must land with nobody watching (auto-runs,
    /// pipeline stages, a page the user has already left).
    case text(TextJobContext)
}

/// Where a text-producing job's words belong. A struct rather than loose
/// associated values so the three context switches stay one-line arms.
struct TextJobContext {
    var ownerId: String
    var ownerType: String         // "song" | "part"
    var title: String             // what the queue row calls the source
    var kind: TextDocKind         // the doc kind to write — authoritative
                                  // over the payload's own `kind`
    /// Merge the payload's tags into the song's tag records (tag jobs).
    var applyTags = false
    /// The question a QA caption asked, echoed onto the stored doc.
    var question: String?
}

/// Why the Editor submitted a mix, carried through the queue so completion
/// knows where the audio goes and the queue rail knows what to call it.
enum EditorRenderPurpose {
    /// Replace `ownerId`'s file with the render (ownerType "song" | "part").
    /// The submitted program travels with the job: the user can open another
    /// track while this renders, and what lands must be recorded against the
    /// document that was actually sent.
    case apply(ownerId: String, ownerType: String, title: String,
               documentJSON: String?)
    /// Save the render at a destination the user already chose.
    case export(destination: URL, title: String)
    /// Import the render as a new library song named `title`; the Editor
    /// routes it onward (continue / split / find matches) itself.
    case snippet(title: String)

    var title: String {
        switch self {
        case .apply(_, _, let title, _): title
        case .export(_, let title): title
        case .snippet(let title): title
        }
    }
}

/// One filled slot / workbench row of a recombination, both the wire payload
/// (inside mix_spec) and the provenance transform recorded on the result.
struct IngredientSubmission: Codable, Equatable, Sendable {
    var slotId: String
    var partId: String            // part id, or a song id for "song.mix" rows
    var gainDb: Double = 0
    var muted = false
    var offsetBeats: Double = 0
    var sectionStartS: Double?
    var sectionEndS: Double?
    // Optional, not defaulted non-optional: this type is nested inside every
    // stored AppliedIngredient, and Swift's synthesized decoder does NOT fall
    // back to a property default — a non-optional here would fail to decode
    // every provenance row written before fades existed.
    var fadeInS: Double?
    var fadeOutS: Double?
}

/// An ingredient after resolution + auto-match planning: what actually went
/// into the mix. `transformJSON`-serialized onto songIngredient rows so a
/// future timeline view (or a re-mix) can reconstruct the placement.
struct AppliedIngredient: Codable, Equatable, Sendable {
    var submission: IngredientSubmission
    var sourceSongTitle: String
    var role: String
    var stretchRatio: Double?
    var pitchShiftSt: Double = 0
}

/// Knobs the recipe flow / workbench footer exposes for a literal mixdown.
struct RecombineOptions: Sendable {
    var autoMatchTempo = true
    var autoMatchKey = true
    var targetBpm: Double?
    var targetCamelot: String?
    var targetLufs: Double = -14.0
    var keepTracks = false
    /// Explicit arrangement length, so trailing silence on the timeline is
    /// rendered rather than trimmed to the last clip.
    var targetDurationS: Double?

    // MARK: single-source transforms
    //
    // `mix_spec` can reverse a track, stretch it, shift its key, ramp it and
    // run it through a processor chain (contract §5.4) — everything the
    // Editor renders with. Until the Actions transform cards, the only way to
    // ask for any of it was to open a workspace. These apply to *every* track
    // in the job, which is exactly right for a one-source card and would be
    // wrong for the bench; the bench never sets them.
    var reverse = false
    /// 1 is untouched. Rides as a bpm ratio the way the Editor's does — see
    /// `planMix` — so the engine stretches uniformly rather than to a grid.
    var speedRate: Double = 1
    /// Added to whatever key-matching already worked out, so the two compose
    /// rather than one silently winning.
    var pitchShiftSt: Double = 0
    var fadeInS: Double?
    var fadeOutS: Double?
    var effects: [MixSpec.Effect] = []
}

// MARK: mix_spec wire shape (contract §5.4) — encoded with
// BackendClient.encoder so property names become snake_case.

struct MixSpec: Codable, Sendable, Equatable {
    struct Target: Codable, Sendable, Equatable {
        var bpm: Double?
        var key: String?
        var sampleRate: Int
        var downbeats: [Double]?
        /// Pads the mix to at least this length, so trailing silence the user
        /// drew on the timeline is actually rendered.
        var durationS: Double?
    }

    struct Stretch: Codable, Sendable, Equatable {
        var mode: String                 // beat | uniform | none
        var transientMode: String        // crisp | smooth
        var preserveFormants: Bool
    }

    struct Section: Codable, Sendable, Equatable {
        var startS: Double
        var endS: Double
    }

    struct Track: Codable, Sendable, Equatable {
        var source: String               // upload id; engine resolves to a path
        var role: String
        var gainDb: Double
        var mute: Bool
        var offsetS: Double
        var section: Section?
        var fadeInS: Double?
        var fadeOutS: Double?
        /// Per ramp, not per track: an Editor track routinely carries a
        /// curved head fade and a linear crossfade tail (contract §5.4).
        var fadeInCurve: String?
        var fadeOutCurve: String?
        var sourceBpm: Double?
        var sourceDownbeats: [Double]?
        var stretch: Stretch
        var pitchShiftSt: Double
        /// Sample-for-sample reversal of the section, before stretching.
        var reverse: Bool?
        /// The Editor's ordered processor chain (contract §5.4).
        var effects: [Effect]?
    }

    /// One processor of a track's chain. All fields optional on the wire;
    /// which ones an effect requires is the contract's table, and the worker
    /// fails the job on a missing one rather than guessing.
    struct Effect: Codable, Sendable, Equatable {
        var type: String
        var cutoffHz: Double?
        var lowDb: Double?
        var midDb: Double?
        var highDb: Double?
        var thresholdDb: Double?
        var ratio: Double?
        var attackMs: Double?
        var releaseMs: Double?
        /// "convolve" only: the impulse response. Built with a local file
        /// path; the submit paths swap it for an upload id before the spec
        /// goes on the wire.
        var ir: String?
        /// "convolve" only: dry/wet, 0–1.
        var mix: Double?
    }

    var target: Target
    var tracks: [Track]
}

/// One mirrored line of a worker's stderr (`job.log`, contract §6).
///
/// The engine sends the raw line and nothing else — no level, no timestamp,
/// capped at 500 characters — so the time is stamped on arrival here. That is
/// honest about what the clock means: when the app heard the line, not when
/// the model printed it. Close enough to read a render by, and not pretending
/// to be the engine's own clock.
struct RenderLogLine: Identifiable, Equatable, Sendable {
    /// Monotonic per store, so `ForEach` keeps its identity as the buffer
    /// scrolls. Two identical lines a second apart are two lines.
    let id: Int
    let at: Date
    let text: String
}

/// Active generation jobs: submission, SSE-fed progress, cancellation, and ingest of
/// finished audio into the library.
@MainActor @Observable
final class JobsStore {
    struct ActiveJob: Identifiable {
        var info: JobInfo
        var progress: JobProgress?
        var status: JobStatus
        var error: APIErrorBody?
        /// Newest partial-audio frame for this job, when it asked for previews.
        /// Each frame replaces the last; the engine deletes them all when the
        /// take succeeds, so this is only ever worth keeping on a cancel.
        var preview: JobPreview?
        /// The tail of this job's worker stderr, newest last.
        ///
        /// Capped at `logCap`: an adapter that prints a line per step is the
        /// quiet case, and ggml prints dozens while it mmaps a GGUF. The
        /// render panel draws the last handful and a cancel throws the rest
        /// away, so keeping a whole render's output would be holding megabytes
        /// nobody reads.
        var log: [RenderLogLine] = []
        /// What this job put in the library, recorded at ingest so a finished
        /// row can offer to show it. In submission order, so `first` is take
        /// a. Empty for the jobs that produce parts or an analysis rather
        /// than a track.
        var producedSongIds: [String] = []
        var id: String { info.jobId }
    }

    var client: BackendClient?
    private(set) var active: [String: ActiveJob] = [:]
    var pendingContext: [String: JobContext] = [:]
    var lastError: String?

    /// The engine's queue hold (contract §5.7): nothing new starts. It does not
    /// stop the take already running and there is no verb that would, so any
    /// control bound to this has to say "finishing the current render" — see
    /// `runningWhileHeld`.
    private(set) var queueHeld = false
    /// Set while a pause/resume of our own is outstanding — see `applyHold`.
    private var holdInFlight = false
    /// Jobs the user asked to be told about by hand.
    ///
    /// The app already notifies when a take lands while it is in the
    /// background, so arming a job can only add one thing: tell me *even if I
    /// am looking at the app*. Kept here rather than in the render panel
    /// because the whole point is to walk away from that panel.
    private(set) var notifyOnLanding: Set<String> = []

    func setNotifyOnLanding(_ jobId: String, _ armed: Bool) {
        if armed { notifyOnLanding.insert(jobId) } else { notifyOnLanding.remove(jobId) }
    }

    /// Whether this job was armed — and clears the arming as it answers.
    ///
    /// A read that consumes, because the alternative is what this used to do.
    /// `apply` dropped the id the instant a job completed and the notifier
    /// checked the set afterwards (`AppEnvironment.route` calls
    /// `jobsStore.apply(event)` and *then* `notify(for:)`), so the check was
    /// always false and the button had no effect whatsoever. Whoever acts on
    /// the arming is the one who should spend it.
    func takeNotifyOnLanding(_ jobId: String) -> Bool {
        notifyOnLanding.remove(jobId) != nil
    }

    /// Settings' "always tell me when a render lands": every Generate submit
    /// arrives pre-armed, exactly as if the render card's button had been
    /// pressed on it. Task jobs are not armed — the button never was on them.
    var autoArm: @MainActor () -> Bool = { false }

    /// The seed of the newest generated take (take a of its batch) — what
    /// Settings' "hold the seed" reuses on the next submit. Session-scoped,
    /// like the queue itself.
    private(set) var lastSeedUsed: Int64?

    /// Ever-increasing id for `RenderLogLine`. Store-wide rather than
    /// per-job: ids only have to be unique within the list that draws them,
    /// and one counter cannot collide across a queue.
    private var logSequence = 0

    /// Set by AppEnvironment: display name lookup + post-ingest notification.
    var modelName: (String) -> String = { $0 }
    var onSongsIngested: ([SongRecord]) -> Void = { _ in }
    var onPartsIngested: ([PartRecord]) -> Void = { _ in }
    /// Text documents that just landed (descriptions, lyrics, tags, ABC).
    /// Single-assignment like its two siblings — AppEnvironment owns it.
    var onTextIngested: ([TextDocRecord]) -> Void = { _ in }
    /// A finished Editor render, with why it was made. The audio artifact's
    /// file still sits in the engine's Outputs directory; the handler moves
    /// it, or the engine's retention sweep collects it eventually.
    var onEditorArtifact: (JobInfo, JobResult, EditorRenderPurpose) -> Void = {
        _, _, _ in }

    private let repo: LibraryRepository
    /// Present when the parts library exists (nil in some legacy tests).
    var partsRepo: PartsRepository?

    init(repo: LibraryRepository, partsRepo: PartsRepository? = nil) {
        self.repo = repo
        self.partsRepo = partsRepo
    }

    var displayJobs: [ActiveJob] { Self.ordered(active.values) }

    /// Work first, in the order it will run; then what has finished, newest
    /// first.
    ///
    /// Two groups rather than one comparator, because the halves answer
    /// different questions. The unfinished rows are a *plan*: the engine's
    /// queue position is the whole point of them, a drag reorders against it,
    /// and a row saying `#3 IN QUEUE` above one saying `#1` would be a lie
    /// about what happens next. The finished rows are a *record*, and a record
    /// reads newest first — the take that just landed is the one you came to
    /// click, and it should not be at the bottom of everything you made today.
    ///
    /// Which also puts a new submission above every finished row, which is
    /// what makes the list usable now that finished rows stay until dismissed.
    ///
    /// `id` breaks both ties so the order is total: two jobs submitted in the
    /// same millisecond must not be able to swap places between redraws.
    static func ordered(_ jobs: some Collection<ActiveJob>) -> [ActiveJob] {
        let working = jobs.filter { !$0.status.isTerminal }.sorted {
            ($0.info.queuePosition ?? 99, $0.info.createdAt, $0.id)
                < ($1.info.queuePosition ?? 99, $1.info.createdAt, $1.id)
        }
        let finished = jobs.filter(\.status.isTerminal).sorted {
            ($0.info.createdAt, $0.id) > ($1.info.createdAt, $1.id)
        }
        return working + finished
    }

    /// Jobs a drag may reorder: the queued ones, in the order the engine says
    /// they will run. The running job is not among them — its place in the
    /// queue is no longer a question, and the engine answers `409` for it.
    var reorderableJobs: [ActiveJob] {
        displayJobs.filter { $0.status == .queued }
    }

    /// The take a hold could not stop. Non-nil is exactly the case where the
    /// UI must not say the queue has stopped.
    var runningWhileHeld: ActiveJob? {
        guard queueHeld else { return nil }
        return displayJobs.first { !$0.status.isTerminal && $0.status != .queued }
    }

    /// Every take of one submission, in take order.
    ///
    /// A render of four takes is four jobs sharing a `groupId` (contract
    /// §5.1), so this is what puts them back together — for the queue's batch
    /// header, for "cancel all takes", and for deciding which take is the last
    /// one to land.
    func batch(_ groupId: String) -> [ActiveJob] {
        active.values
            .filter { $0.info.groupId == groupId }
            .sorted { ($0.info.takeIndexInBatch, $0.info.createdAt, $0.id)
                        < ($1.info.takeIndexInBatch, $1.info.createdAt, $1.id) }
    }

    /// Takes of this submission that have not finished yet.
    func unfinishedBatchJobs(_ groupId: String) -> [ActiveJob] {
        batch(groupId).filter { !$0.status.isTerminal }
    }

    /// Whether nothing of this job's submission is still running — which is
    /// what "the render is done" means once a batch is several jobs, and the
    /// only honest moment to say so once rather than once per take.
    func isFinalOfBatch(_ jobId: String) -> Bool {
        guard let info = active[jobId]?.info else { return true }
        return unfinishedBatchJobs(info.groupId).isEmpty
    }

    /// Cancel every take of one submission (contract §5.3, once per job).
    ///
    /// Sent take by take rather than as one verb because that is all the
    /// engine has: a group is a grouping key, not a queue entry. Terminal
    /// takes are skipped — cancelling one is a 409, and a batch that is
    /// half-finished is exactly when this button gets pressed.
    func cancelBatch(_ groupId: String) async {
        for job in unfinishedBatchJobs(groupId) {
            await cancel(job.id)
        }
    }

    // MARK: actions

    @discardableResult
    func submit(modelId: String, prompt: String, lyrics: String?,
                durationS: Double, count: Int,
                params: [String: JSONValue],
                preview: Bool = false, name: String? = nil) async -> JobsCreated? {
        guard let client else { return nil }
        // A blank field is not a name — it means "use the default", which is
        // resolved at ingest.
        let chosen = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let created = try await client.submit(JobSubmission(
                modelIds: [modelId], prompt: prompt, lyrics: lyrics,
                durationS: durationS, count: count, params: params,
                force: false, preview: preview))
            lastError = nil
            let armed = autoArm()
            for ref in created.jobs {
                if let chosen, !chosen.isEmpty {
                    pendingContext[ref.jobId] = .generate(name: chosen)
                }
                if armed { setNotifyOnLanding(ref.jobId, true) }
                await track(jobId: ref.jobId)
            }
            return created
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// Upload a local audio file for an "audio" param; nil (with lastError set)
    /// if the file is unreadable or the engine rejects it.
    func uploadAudio(fileURL: URL) async -> String? {
        guard let client else { return nil }
        let accessing = fileURL.startAccessingSecurityScopedResource()
        defer { if accessing { fileURL.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: fileURL) else {
            lastError = "Could not read \(fileURL.lastPathComponent)"
            return nil
        }
        do {
            let info = try await client.upload(data: data,
                                               filename: fileURL.lastPathComponent)
            return info.uploadId
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// Split a library song into parts (task "separate").
    @discardableResult
    func submitSplit(modelId: String, songId: String, sourceTitle: String,
                     sourceURL: URL,
                     params: [String: JSONValue]) async -> JobsCreated? {
        await submitTask(
            "separate", modelId: modelId, sourceURL: sourceURL,
            params: params,
            context: .split(songId: songId, sourceTitle: sourceTitle))
    }

    /// Transcribe a song into notes parts (task "transcribe"); artifacts
    /// route exactly like a split (midi parts + previews onto the song).
    @discardableResult
    func submitTranscribe(modelId: String, songId: String, sourceTitle: String,
                          sourceURL: URL,
                          params: [String: JSONValue]) async -> JobsCreated? {
        await submitTask(
            "transcribe", modelId: modelId, sourceURL: sourceURL,
            params: params,
            context: .split(songId: songId, sourceTitle: sourceTitle))
    }

    /// One of the audio-transformation tasks (timbre / reamp / convert-voice /
    /// sing): audio in, one transformed `stem` artifact out, filed as a part
    /// of the source song through the same `.split` routing a separation
    /// uses — which is why these need no ingest arm of their own.
    @discardableResult
    func submitAudioTransform(task: String, modelId: String, songId: String,
                              sourceTitle: String, sourceURL: URL,
                              params: [String: JSONValue]) async -> JobsCreated? {
        await submitTask(
            task, modelId: modelId, sourceURL: sourceURL, params: params,
            context: .split(songId: songId, sourceTitle: sourceTitle))
    }

    /// Analyze a song or part (task "analyze"): tempo/key/beats/structure.
    @discardableResult
    func submitAnalyze(modelId: String, ownerId: String, ownerType: String,
                       title: String, sourceURL: URL,
                       params: [String: JSONValue] = [:]) async -> JobsCreated? {
        await submitTask(
            "analyze", modelId: modelId, sourceURL: sourceURL, params: params,
            context: .analyze(ownerId: ownerId, ownerType: ownerType,
                              title: title))
    }

    /// Describe a song or part in prose (task "caption") and keep the words
    /// as a text document. `question` turns it into QA on models that take
    /// one. Pages that only want to *show* a caption go through
    /// `MetaJobRunner` instead — this path is for words that become rows.
    @discardableResult
    func submitCaption(modelId: String, ownerId: String, ownerType: String,
                       title: String, sourceURL: URL,
                       kind: TextDocKind = .description,
                       question: String? = nil,
                       params: [String: JSONValue] = [:]) async -> JobsCreated? {
        var params = params
        if let question, !question.isEmpty {
            params["question"] = .string(question)
        }
        return await submitTask(
            "caption", modelId: modelId, sourceURL: sourceURL, params: params,
            context: .text(TextJobContext(
                ownerId: ownerId, ownerType: ownerType, title: title,
                kind: kind, question: question)))
    }

    /// Transcribe the sung words (task "lyrics") into a lyrics document with
    /// timed segments. Never touches `song.lyrics` — that column is what the
    /// generator was given, and a transcription is a different fact.
    @discardableResult
    func submitLyrics(modelId: String, ownerId: String, ownerType: String,
                      title: String, sourceURL: URL,
                      language: String? = nil) async -> JobsCreated? {
        var params: [String: JSONValue] = [:]
        if let language, !language.isEmpty {
            params["language"] = .string(language)
        }
        return await submitTask(
            "lyrics", modelId: modelId, sourceURL: sourceURL, params: params,
            context: .text(TextJobContext(
                ownerId: ownerId, ownerType: ownerType, title: title,
                kind: .lyrics)))
    }

    /// Tag a song's genre / mood / instrumentation (task "tag"). The labels
    /// merge into the same tag records the user edits by hand, and the full
    /// scored list is kept as a tags document.
    @discardableResult
    func submitTag(modelId: String, ownerId: String, ownerType: String,
                   title: String, sourceURL: URL,
                   params: [String: JSONValue] = [:]) async -> JobsCreated? {
        await submitTask(
            "tag", modelId: modelId, sourceURL: sourceURL, params: params,
            context: .text(TextJobContext(
                ownerId: ownerId, ownerType: ownerType, title: title,
                kind: .tags, applyTags: ownerType == "song")))
    }

    /// Compose against an existing notes part (task "compose"): the part's
    /// MIDI file rides `inputKey` ("melody_midi" for the anticipation
    /// family), and the composed MIDI files back as a notes part of the
    /// same song through the `.split` routing every transcription uses.
    @discardableResult
    func submitComposeFromNotes(modelId: String, songId: String,
                                sourceTitle: String, sourceURL: URL,
                                inputKey: String,
                                params: [String: JSONValue]) async
        -> JobsCreated? {
        await submitTask(
            "compose", modelId: modelId, sourceURL: sourceURL, params: params,
            inputKey: inputKey,
            context: .split(songId: songId, sourceTitle: sourceTitle))
    }

    /// Compose from notation (task "compose"): ABC text in, ABC + midi out.
    ///
    /// The midi artifact lands as a notes part of `songId` through the same
    /// `.split` routing every transcription uses, and the ABC text rides the
    /// split arm's text case — zero ingest code of its own. No audio upload:
    /// the model's input is the string param `prompt` (contract 5.4).
    @discardableResult
    func submitComposeABC(modelId: String, abc: String, songId: String,
                          sourceTitle: String,
                          params: [String: JSONValue] = [:]) async
        -> JobsCreated? {
        var params = params
        params["prompt"] = .string(abc)
        return await submitTextOnlyTask(
            "compose", modelId: modelId, params: params,
            context: .split(songId: songId, sourceTitle: sourceTitle))
    }

    /// Resolved material for one ingredient: the payload file plus its stored
    /// musical profile. `partId` may name a part or a whole library song.
    struct ResolvedIngredient {
        var submission: IngredientSubmission
        var kind: String              // part kind, or "song.mix"
        var role: String
        var fileURL: URL
        var sampleRate: Int?
        var sourceSongTitle: String
        var summary: AnalysisSummary?
    }

    func resolveIngredient(_ sub: IngredientSubmission) -> ResolvedIngredient? {
        guard let partsRepo else { return nil }
        if let part = ((try? partsRepo.part(id: sub.partId)) ?? nil) {
            let songTitle = ((try? repo.song(id: part.songId)) ?? nil)?.title
                ?? part.modelName
            let summary = AnalysisSummary(
                record: (try? partsRepo.analysis(ownerId: part.id)) ?? nil)
            // The kind's leaf, and only the kind's leaf: `role` names the
            // file `keep_tracks` writes and the progress line the engine
            // prints, so a renamed part must not be able to change it.
            let role = PartNaming.leaf(kind: part.kind)
            return ResolvedIngredient(
                submission: sub, kind: part.kind, role: role,
                fileURL: part.fileURL, sampleRate: part.sampleRate,
                sourceSongTitle: songTitle, summary: summary)
        }
        if let song = ((try? repo.song(id: sub.partId)) ?? nil) {
            let summary = AnalysisSummary(
                record: (try? partsRepo.analysis(ownerId: song.id)) ?? nil)
            return ResolvedIngredient(
                submission: sub, kind: "song.mix", role: "mix",
                fileURL: song.fileURL, sampleRate: song.sampleRate,
                sourceSongTitle: song.title, summary: summary)
        }
        return nil
    }

    /// Pure planning half of a recombination (unit-testable): auto-match every
    /// resolved ingredient against the target grid. Track `source` fields hold
    /// placeholders — submitRecombine swaps in upload ids.
    nonisolated static func planMix(resolved: [ResolvedIngredient],
                                    options: RecombineOptions)
        -> (spec: MixSpec, applied: [AppliedIngredient]) {
        let targetBpm = options.targetBpm
            ?? resolved.first(where: { $0.summary?.bpm != nil })?.summary?.bpm
        let targetCamelot = options.targetCamelot
            ?? resolved.first(where: { $0.summary?.camelot != nil })?
                .summary?.camelot
        let target = AnalysisSummary(bpm: targetBpm, camelot: targetCamelot)
        let sampleRate = resolved.compactMap(\.sampleRate).max() ?? 44100
        // Speed rides as a bpm ratio, the same carrier trick the Editor uses:
        // "this source at bpm B belongs on a grid at B × rate". A real bpm
        // when one was measured — it reads honestly in provenance — else a
        // plain 120, since only the ratio is doing any work.
        let speeding = abs(options.speedRate - 1) > 1e-6
        let carrierBpm = resolved.first?.summary?.bpm ?? 120

        var tracks: [MixSpec.Track] = []
        var applied: [AppliedIngredient] = []
        var roleCounts: [String: Int] = [:]
        for item in resolved {
            let isDrums = item.kind.hasPrefix("stem.drums")
            let planned = item.summary.map {
                Mashability.plan(source: $0, target: target, isDrums: isDrums)
            }
            let wantsStretch = options.autoMatchTempo
                && item.summary?.bpm != nil && targetBpm != nil
            let mode = wantsStretch
                ? ((item.summary?.downbeats?.isEmpty == false) ? "beat" : "uniform")
                : "none"
            // The engine recomputes target/source itself, so it must be given
            // the tempo the match was actually made against — handing it the
            // unfolded BPM of a half-time source renders at double speed while
            // every badge says "no stretch".
            let sourceBpm = planned?.badges.tempo?.foldedSourceBpm
                ?? item.summary?.bpm
            // keep_tracks writes one file per role, so repeated roles would
            // overwrite each other's stems (the timeline makes repeats routine).
            let count = (roleCounts[item.role] ?? 0) + 1
            roleCounts[item.role] = count
            let role = count == 1 ? item.role : "\(item.role)-\(count)"
            let shift = options.autoMatchKey ? (planned?.pitchShiftSt ?? 0) : 0
            let sub = item.submission
            let section: MixSpec.Section? = sub.sectionStartS.flatMap { start in
                sub.sectionEndS.map { MixSpec.Section(startS: start, endS: $0) }
            }
            tracks.append(MixSpec.Track(
                source: sub.partId, role: role, gainDb: sub.gainDb,
                mute: sub.muted,
                offsetS: targetBpm.map { sub.offsetBeats * 60.0 / $0 } ?? 0,
                section: section,
                fadeInS: (sub.fadeInS ?? options.fadeInS ?? 0) > 0
                    ? (sub.fadeInS ?? options.fadeInS) : nil,
                fadeOutS: (sub.fadeOutS ?? options.fadeOutS ?? 0) > 0
                    ? (sub.fadeOutS ?? options.fadeOutS) : nil,
                sourceBpm: speeding ? carrierBpm : sourceBpm,
                sourceDownbeats: item.summary?.downbeats,
                stretch: MixSpec.Stretch(
                    mode: speeding ? "uniform" : mode,
                    transientMode: isDrums ? "crisp" : "smooth",
                    preserveFormants: item.kind.hasPrefix("stem.vocals")),
                pitchShiftSt: shift + options.pitchShiftSt,
                reverse: options.reverse ? true : nil,
                effects: options.effects.isEmpty ? nil : options.effects))
            // Record the ratio the ENGINE will apply, not the one Mashability
            // considers good enough to recommend: it nils out red-quality
            // matches, so provenance used to claim "no stretch" for mixes that
            // were audibly stretched. Auto-match on means aligned — the badge
            // is where quality gets flagged.
            applied.append(AppliedIngredient(
                submission: sub, sourceSongTitle: item.sourceSongTitle,
                role: role,
                stretchRatio: wantsStretch
                    ? planned?.badges.tempo?.stretchRatio : nil,
                pitchShiftSt: shift))
        }
        let spec = MixSpec(
            target: MixSpec.Target(bpm: speeding ? carrierBpm * options.speedRate
                                                 : targetBpm,
                                   key: targetCamelot,
                                   sampleRate: sampleRate, downbeats: nil,
                                   durationS: options.targetDurationS),
            tracks: tracks)
        return (spec, applied)
    }

    /// Literal recombination (task "mix"): resolve ingredients, plan the
    /// auto-match against the target grid, upload payloads, build mix_spec.
    ///
    /// `context` overrides where the result lands — the default is a new
    /// recombined library song; section slicing passes `.generativePart` so
    /// each cut lands as a part of the song it was cut from.
    @discardableResult
    func submitRecombine(modelId: String, recipeId: String?, title: String,
                         ingredients: [IngredientSubmission],
                         options: RecombineOptions = RecombineOptions(),
                         context: JobContext? = nil)
        async -> JobsCreated? {
        guard let client else { return nil }
        let resolved = ingredients.compactMap(resolveIngredient)
        guard resolved.count == ingredients.count, !resolved.isEmpty else {
            lastError = "Some parts could not be found in the library"
            return nil
        }
        let plan = Self.planMix(resolved: resolved, options: options)
        var spec = plan.spec
        let applied = plan.applied
        // one upload per distinct file: the structure arranger sends the same
        // source once per section
        var uploaded: [URL: String] = [:]
        for (index, item) in resolved.enumerated() {
            if let cached = uploaded[item.fileURL] {
                spec.tracks[index].source = cached
                continue
            }
            guard let uploadId = await uploadAudio(fileURL: item.fileURL) else {
                return nil
            }
            uploaded[item.fileURL] = uploadId
            spec.tracks[index].source = uploadId
        }
        guard let specData = try? BackendClient.encoder.encode(spec) else {
            lastError = "Could not encode the mix"
            return nil
        }
        let params: [String: JSONValue] = [
            "mix_spec": .string(String(decoding: specData, as: UTF8.self)),
            "target_lufs": .double(options.targetLufs),
            "keep_tracks": .bool(options.keepTracks),
        ]
        do {
            let created = try await client.submit(JobSubmission(
                modelIds: [modelId], task: "mix", prompt: "", lyrics: nil,
                durationS: 0, count: 1, params: params, force: false))
            lastError = nil
            for ref in created.jobs {
                pendingContext[ref.jobId] = context ?? .recombine(
                    recipeId: recipeId, title: title, applied: applied)
                await track(jobId: ref.jobId)
            }
            return created
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// A one-track mix the Editor planned (apply / export / snippet). The
    /// spec arrives with upload ids already in place — the Editor uploads its
    /// one source itself, because the same upload serves repeated renders.
    @discardableResult
    func submitEditorRender(modelId: String, spec: MixSpec, normalize: Bool,
                            limiter: Bool, targetLufs: Double,
                            outputFormat: String? = nil,
                            bitDepth: String? = nil,
                            purpose: EditorRenderPurpose) async -> JobsCreated? {
        guard let client else { return nil }
        guard let specData = try? BackendClient.encoder.encode(spec) else {
            lastError = "Could not encode the edit"
            return nil
        }
        var params: [String: JSONValue] = [
            "mix_spec": .string(String(decoding: specData, as: UTF8.self)),
            "normalize": .bool(normalize),
            "limiter": .bool(limiter),
            "target_lufs": .double(targetLufs),
        ]
        if let outputFormat { params["output_format"] = .string(outputFormat) }
        if let bitDepth { params["bit_depth"] = .string(bitDepth) }
        do {
            let created = try await client.submit(JobSubmission(
                modelIds: [modelId], task: "mix", prompt: "", lyrics: nil,
                durationS: 0, count: 1, params: params, force: false))
            lastError = nil
            for ref in created.jobs {
                pendingContext[ref.jobId] = .editor(purpose: purpose)
                await track(jobId: ref.jobId)
            }
            return created
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// Token Splice Playground: EnCodec codebook recombination of two songs
    /// (experimental). Rides task "mix" with a splice_spec instead of a
    /// mix_spec; the result is an ordinary recombined song.
    @discardableResult
    func submitTokenSplice(modelId: String, title: String,
                           aId: String, bId: String, coarseFrom: String,
                           splitCodebook: Int) async -> JobsCreated? {
        guard let client else { return nil }
        guard let a = resolveIngredient(IngredientSubmission(slotId: "a",
                                                            partId: aId)),
              let b = resolveIngredient(IngredientSubmission(slotId: "b",
                                                             partId: bId))
        else {
            lastError = "Some parts could not be found in the library"
            return nil
        }
        guard let upA = await uploadAudio(fileURL: a.fileURL),
              let upB = await uploadAudio(fileURL: b.fileURL) else { return nil }
        let spec: [String: JSONValue] = [
            "a": .string(upA), "b": .string(upB),
            "coarse_from": .string(coarseFrom),
            "split_codebook": .int(splitCodebook),
        ]
        guard let specData = try? BackendClient.encoder.encode(spec) else {
            lastError = "Could not encode the splice"
            return nil
        }
        let params: [String: JSONValue] = [
            "splice_spec": .string(String(decoding: specData, as: UTF8.self)),
        ]
        do {
            let created = try await client.submit(JobSubmission(
                modelIds: [modelId], task: "mix", prompt: "", lyrics: nil,
                durationS: 0, count: 1, params: params, force: false))
            lastError = nil
            let applied = [a, b].map {
                AppliedIngredient(submission: $0.submission,
                                  sourceSongTitle: $0.sourceSongTitle,
                                  role: $0.role, stretchRatio: nil,
                                  pitchShiftSt: 0)
            }
            for ref in created.jobs {
                pendingContext[ref.jobId] = .recombine(
                    recipeId: "token-splice", title: title, applied: applied)
                await track(jobId: ref.jobId)
            }
            return created
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// Render a notes part to audio through a SoundFont model; the result
    /// lands back in the Parts library as a "layer.*" part of the same song.
    @discardableResult
    func submitRender(modelId: String, part: PartRecord, sourceTitle: String)
        async -> JobsCreated? {
        await submitTask(
            "render", modelId: modelId, sourceURL: part.fileURL, params: [:],
            inputKey: "midi_file",
            context: .generativePart(
                songId: part.songId, sourceTitle: sourceTitle,
                // From the kind, never from the name: a name is now
                // `piano-notes-track042` and is about to become whatever the
                // user retypes it as, and neither is a taxonomy.
                kind: "layer.\(PartNaming.leaf(kind: part.kind))",
                name: "Render: \(part.name)"))
    }

    /// A generate job with a routing context (Reimagine recipes): the caller
    /// builds the full params (task_type/src_audio/…) programmatically.
    @discardableResult
    func submitGenerative(modelId: String, prompt: String, lyrics: String?,
                          durationS: Double, params: [String: JSONValue],
                          context: JobContext?) async -> JobsCreated? {
        guard let client else { return nil }
        do {
            let created = try await client.submit(JobSubmission(
                modelIds: [modelId], prompt: prompt, lyrics: lyrics,
                durationS: durationS, count: 1, params: params, force: false))
            lastError = nil
            for ref in created.jobs {
                if let context { pendingContext[ref.jobId] = context }
                await track(jobId: ref.jobId)
            }
            return created
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// `submitTask` without the upload, for the tasks whose input is already
    /// in `params` (compose's `prompt`). A sibling rather than an optional
    /// sourceURL on `submitTask`, because "forgot to pass the source" must
    /// stay a compile error on every task that needs one.
    private func submitTextOnlyTask(_ task: String, modelId: String,
                                    params: [String: JSONValue],
                                    context: JobContext) async -> JobsCreated? {
        guard let client else { return nil }
        do {
            let created = try await client.submit(JobSubmission(
                modelIds: [modelId], task: task, prompt: "", lyrics: nil,
                durationS: 0, count: 1, params: params, force: false))
            lastError = nil
            for ref in created.jobs {
                pendingContext[ref.jobId] = context
                await track(jobId: ref.jobId)
            }
            return created
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    private func submitTask(_ task: String, modelId: String, sourceURL: URL,
                            params: [String: JSONValue],
                            inputKey: String = "source_audio",
                            context: JobContext) async -> JobsCreated? {
        guard let client else { return nil }
        guard let uploadId = await uploadAudio(fileURL: sourceURL) else {
            return nil
        }
        var params = params
        params[inputKey] = .string(uploadId)
        do {
            let created = try await client.submit(JobSubmission(
                modelIds: [modelId], task: task, prompt: "", lyrics: nil,
                durationS: 0, count: 1, params: params, force: false))
            lastError = nil
            for ref in created.jobs {
                pendingContext[ref.jobId] = context
                await track(jobId: ref.jobId)
            }
            return created
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// Remember what a job left in the library, for the row's "Show in
    /// library". Written before `onSongsIngested` so anything that redraws off
    /// that callback already sees it.
    private func record(_ songs: [SongRecord], for jobId: String) {
        active[jobId]?.producedSongIds = songs.map(\.id)
    }

    /// Human title for job rows/notifications — prompt for generations, an
    /// action description for promptless task jobs.
    func displayTitle(for info: JobInfo) -> String {
        switch pendingContext[info.jobId] {
        case .split(_, let sourceTitle):
            return info.task == "transcribe"
                ? "Transcribe: \(sourceTitle)" : "Split: \(sourceTitle)"
        case .analyze(_, _, let title):
            return "Analyze: \(title)"
        case .text(let context):
            switch context.kind {
            case .description, .caption: return "Describe: \(context.title)"
            case .qa: return "Ask: \(context.title)"
            case .lyrics: return "Lyrics: \(context.title)"
            case .tags: return "Tag: \(context.title)"
            case .abc: return "ABC: \(context.title)"
            }
        case .recombine(_, let title, _):
            return title
        case .generativePart(_, let sourceTitle, _, let name):
            return "\(name): \(sourceTitle)"
        case .editor(let purpose):
            switch purpose {
            case .apply: return "Apply edits: \(purpose.title)"
            case .export: return "Export: \(purpose.title)"
            case .snippet: return "Selection: \(purpose.title)"
            }
        case .generate, .none:
            // Deliberately the prompt, not the name: what identifies a render
            // in the queue is what you asked for, and the name is on the track
            // the moment it lands.
            let task = info.task ?? "generate"
            if task == "generate" { return info.prompt }
            return task.prefix(1).uppercased() + task.dropFirst()
        }
    }

    /// What the finished take will be *called* — as distinct from
    /// `displayTitle`, which says what was asked for.
    ///
    /// The two differ wherever a render is identified by its prompt: a Studio
    /// take says "a heavy drop with techno drums" in the queue and lands as
    /// `track042`. Nil when the context fixes no name — a Studio submit that
    /// left the field on its default carries none on purpose (the number is a
    /// high-water mark resolved at ingest, so pinning it here would hand the
    /// same one to every job queued behind this), and callers that want to
    /// *predict* it supply the library's own next name.
    func landingBaseTitle(for jobId: String) -> String? {
        switch pendingContext[jobId] {
        case .generate(let name): return name
        case .recombine(_, let title, _): return title
        case .generativePart(_, _, _, let name): return name
        case .editor(let purpose): return purpose.title
        // None of these produce a library song: a split makes parts, an
        // analysis makes a row of numbers, a text job makes a document.
        case .split, .analyze, .text, .none: return nil
        }
    }

    /// Whether this job was submitted by the Editor. The Actions sidebar row
    /// spins for "any task job", which an edit render otherwise satisfies —
    /// and the queue's generic completion banner would double up with the
    /// Editor's own.
    func isEditorJob(_ jobId: String) -> Bool {
        if case .editor = pendingContext[jobId] { return true }
        return false
    }

    /// Jobs whose cancel has been asked for and not yet landed.
    ///
    /// The request is the fast half; stopping a model mid-take is not. Between
    /// the two there used to be nothing to look at — the button kept saying
    /// "Cancel take", the percentage sat where the last progress event left it,
    /// and a cancel that was working perfectly well was indistinguishable from
    /// a dead button. Pressing it twice was the only thing left to try.
    private(set) var canceling: Set<String> = []

    func isCanceling(_ jobId: String) -> Bool { canceling.contains(jobId) }

    /// Ask the engine to stop this job (contract §5.3).
    ///
    /// The id stays in `canceling` until the job reaches a terminal state,
    /// which is the engine's answer rather than ours — a 202 only means the
    /// request was accepted, and the take is still running when it arrives.
    func cancel(_ jobId: String) async {
        guard let client else { return }
        canceling.insert(jobId)
        do {
            try await client.cancelJob(jobId)
        } catch {
            canceling.remove(jobId)
            // 409 JOB_NOT_CANCELABLE: it finished between the click and the
            // request. Nothing went wrong and there is nothing to say — the
            // row is about to settle into whatever it became.
            if (error as? APIError)?.code == "JOB_NOT_CANCELABLE" { return }
            lastError = error.localizedDescription
        }
    }

    /// Hold the render queue, or release it (contract §5.7).
    func holdQueue(_ held: Bool) async {
        guard let client else { return }
        holdInFlight = true
        defer { holdInFlight = false }
        do {
            try await client.holdQueue(held)
            // Set from the answer, not before it: the engine applies the hold
            // before replying, so this is the state it is now in rather than a
            // guess a failed request would leave standing. `queue.state`
            // re-asserts the same fact, including when another client is what
            // changed it.
            queueHeld = held
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Run these queued jobs in this order, ahead of every queued job not named
    /// (contract §5.8).
    ///
    /// Nothing is reordered locally on the way out: the engine re-announces the
    /// position of *every* queued job, including the ones nobody dragged, and a
    /// local guess would fight that answer for a frame.
    func reorder(_ jobIds: [String]) async {
        guard let client else { return }
        do { try await client.reorderQueue(jobIds) }
        catch { lastError = error.localizedDescription }
    }

    /// The same hold, read on demand — `/v1/system` is how a hold that was set
    /// before this app launched, or while its event stream was down, gets seen.
    ///
    /// Skipped while a pause/resume of our own is outstanding: `/v1/system` is
    /// polled every few seconds, and a snapshot that left the engine before the
    /// toggle did would otherwise flip the button back under the pointer.
    func applyHold(from system: SystemInfo) {
        guard !holdInFlight else { return }
        queueHeld = system.queueHeld ?? false
    }

    /// How many stderr lines a running job keeps. Ten fit the panel; the rest
    /// are here so "Copy log" hands over something worth pasting into a bug
    /// report rather than the last screenful.
    static let logCap = 200

    private func appendLog(jobId: String, line: String) {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        // A job the app is not tracking has no panel to draw this in, and
        // holding lines against an id that will never be looked up is a leak
        // with extra steps.
        guard !text.isEmpty, active[jobId] != nil else { return }
        logSequence += 1
        active[jobId]?.log.append(
            RenderLogLine(id: logSequence, at: Date(), text: text))
        if let overflow = active[jobId].map({ $0.log.count - Self.logCap }),
           overflow > 0 {
            active[jobId]?.log.removeFirst(overflow)
        }
    }

    /// "Keep partial": stop the take, and adopt the last preview frame it sent
    /// as a library song.
    ///
    /// `canceled` keeps meaning "no output": the engine's job result stays null
    /// and nothing here infers a song from a cancel event. Keeping the partial
    /// is a separate act, on a file the app was already handed and told the
    /// duration of — which is why it does not wait for the cancel to land, and
    /// why an ordinary cancel still leaves nothing behind.
    @discardableResult
    func keepPartial(_ jobId: String) async -> SongRecord? {
        let preview = active[jobId]?.preview
        let info = active[jobId]?.info
        await cancel(jobId)
        guard let preview, let info else { return nil }
        return ingestPreview(job: info, preview: preview)
    }

    private func ingestPreview(job: JobInfo, preview: JobPreview) -> SongRecord? {
        let songId = UUID().uuidString.lowercased()
        let fileName = songId + ".wav"
        let dest = StoragePaths.libraryAudio.appendingPathComponent(fileName)
        do {
            try FileManager.default.createDirectory(
                at: StoragePaths.libraryAudio, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: preview.fileURL, to: dest)
        } catch {
            lastError = "Could not keep the partial take: \(error.localizedDescription)"
            return nil
        }
        // The name you typed applies to a take you kept part-way through just
        // as much as to a finished one. No letter: this is one track, whatever
        // the job was going to produce.
        var chosen: String?
        if case .generate(let name)? = pendingContext[job.jobId] { chosen = name }
        let wanted = chosen ?? SongRecord.trackName(
            number: ((try? repo.highestTrackNumber()) ?? 0) + 1)
        let title = (try? repo.uniqueTitle(wanted)) ?? wanted
        let paramsJSON = (try? String(
            decoding: BackendClient.encoder.encode(job.params),
            as: UTF8.self)) ?? "{}"
        // Recorded in notes rather than left to look like a finished take: this
        // is audio the model had not finished making, and six months later
        // nothing else on the row would say so.
        let song = SongRecord(
            id: songId, title: title,
            prompt: job.prompt, lyrics: job.lyrics, modelId: job.modelId,
            modelName: modelName(job.modelId), groupId: job.groupId,
            paramsJSON: paramsJSON, durationS: preview.durationS,
            sampleRate: preview.sampleRate, fileName: fileName,
            seedUsed: nil, createdAt: Date(), rating: 0,
            notes: "Partial render kept after cancelling.", favorite: false)
        do {
            try repo.insert(song)
        } catch {
            lastError = "Could not save the partial take: \(error.localizedDescription)"
            return nil
        }
        record([song], for: job.jobId)
        onSongsIngested([song])
        return song
    }

    /// Take one row off the list.
    ///
    /// The routing context goes with it, and not before: `displayTitle` reads
    /// it, so a split or a recombination that dropped its context on success
    /// would sit there afterwards under a blank name.
    func dismiss(_ jobId: String) {
        active.removeValue(forKey: jobId)
        pendingContext.removeValue(forKey: jobId)
        canceling.remove(jobId)
        // And the auto-clear stamp: a row dismissed by hand and somehow
        // re-adopted starts its grace over rather than expiring on sight.
        finishedSeenAt.removeValue(forKey: jobId)
    }

    /// Clear every row that has stopped — succeeded, failed or cancelled.
    ///
    /// Finished rows wait to be dismissed rather than disappearing on a
    /// timer by default; but a day's work is fifty of them, and "manually
    /// dismissed" should not have to mean fifty clicks.
    func dismissFinished() {
        for job in active.values where job.status.isTerminal { dismiss(job.id) }
    }

    // MARK: auto-clear

    /// How long a finished row stays before being dismissed on the user's
    /// behalf; nil (the default) keeps rows until dismissed by hand. A closure
    /// into Settings so a change applies to rows already finished.
    var autoClearAfterS: @MainActor () -> TimeInterval? = { nil }

    /// When each terminal row was first *seen* terminal. Stamped by the sweep
    /// rather than at every status assignment — terminal transitions happen in
    /// a dozen ingest paths, and a row kept for minutes does not care about a
    /// few seconds of stamping slack.
    private var finishedSeenAt: [String: Date] = [:]
    private var autoClearTask: Task<Void, Never>?

    /// Kick the sweeper. Called on every engine event and on a Settings
    /// change; cheap when the timer is already running or the policy is off.
    func ensureAutoClearRunning() {
        guard autoClearTask == nil, autoClearAfterS() != nil,
              !active.isEmpty else { return }
        // Inherits the store's MainActor context; only the sleeps yield.
        autoClearTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, self.sweepFinished() else { break }
            }
            self?.autoClearTask = nil
        }
    }

    /// One tick: stamp newly-terminal rows, dismiss the expired, and say
    /// whether there is anything left to watch.
    @discardableResult
    func sweepFinished(now: Date = Date()) -> Bool {
        finishedSeenAt = finishedSeenAt.filter { active[$0.key] != nil }
        guard let after = autoClearAfterS() else { return false }
        for job in active.values where job.status.isTerminal {
            let seen = finishedSeenAt[job.id] ?? now
            finishedSeenAt[job.id] = seen
            if now.timeIntervalSince(seen) >= after { dismiss(job.id) }
        }
        return !active.isEmpty
    }

    /// Put a row on the list that this store did not submit.
    ///
    /// The one way in besides `submit`: `reconcile` uses it for work already
    /// running when the app came back, and tests use it to stand a queue up
    /// with no engine behind it. `active`'s setter stays private so that
    /// remains the whole list of ways a row can appear.
    func adopt(_ job: ActiveJob) {
        active[job.id] = job
    }

    func reconcile() async {
        guard let client else { return }
        if let jobs = try? await client.jobs() {
            for job in jobs where active[job.jobId] == nil {
                adopt(ActiveJob(info: job, progress: job.progress,
                                status: job.status))
            }
        }
    }

    private func track(jobId: String) async {
        guard let client, let info = try? await client.job(jobId) else { return }
        active[jobId] = ActiveJob(info: info, progress: info.progress,
                                  status: info.status)
    }

    // MARK: event routing

    func apply(_ event: EngineEvent) {
        switch event {
        case .jobQueued(let jobId, _, _, let queuePosition):
            if active[jobId] == nil {
                Task { await track(jobId: jobId) }
            } else {
                // A reorder re-announces every queued job (§5.8) and the only
                // thing that changed is this integer, which is what the rail
                // sorts on. Re-fetching each JobInfo would be a request per job
                // per drag.
                active[jobId]?.info.queuePosition = queuePosition
            }
        case .jobStarted(let jobId):
            active[jobId]?.status = .loading
        case .jobProgress(let jobId, let progress):
            active[jobId]?.progress = progress
            if let stage = JobStatus(rawValue: progress.stage) {
                active[jobId]?.status = stage
            }
        case .jobPreview(let jobId, let preview):
            active[jobId]?.preview = preview
        case .jobLog(let jobId, let line):
            appendLog(jobId: jobId, line: line)
        case .jobTakeDone(let jobId, let take, let output):
            ingestTake(jobId: jobId, take: take, output: output)
        case .jobCompleted(let jobId):
            // the engine drops a succeeded job's previews; keeping the path
            // would leave the card drawing from a file that is gone
            active[jobId]?.preview = nil
            // A take that landed while the cancel was in flight: the request
            // lost, and the row must stop claiming otherwise.
            canceling.remove(jobId)
            // The arming is NOT cleared here: this runs before the notifier
            // reads it. `takeNotifyOnLanding` spends it instead.
            Task { await ingest(jobId: jobId) }
        case .jobFailed(let jobId, let error):
            active[jobId]?.status = .failed
            active[jobId]?.error = error
            canceling.remove(jobId)
            // Takes that landed incrementally before the failure stay in the
            // library — they are finished audio; only the bookkeeping goes.
            dropBatchIngestIfFinished(jobId)
        case .jobCanceled(let jobId):
            active[jobId]?.status = .canceled
            notifyOnLanding.remove(jobId)
            canceling.remove(jobId)
            dropBatchIngestIfFinished(jobId)
        case .queueState(let held, _):
            queueHeld = held
        default:
            break
        }
        // Any of the cases above can be the one that made a row terminal.
        ensureAutoClearRunning()
    }

    // MARK: ingest

    private func ingest(jobId: String) async {
        guard let client, let job = try? await client.job(jobId),
              let result = job.result else {
            active[jobId]?.status = .failed
            active[jobId]?.error = APIErrorBody(
                code: "INTERNAL", message: "finished job had no result")
            return
        }
        if let task = job.task, task != "generate" {
            ingestArtifacts(job: job, result: result)
            return
        }
        ingestGenerate(job: job, result: result)
    }

    /// Generate-job ingest (internal for tests): library songs, unless a
    /// generativePart context routes the take into the Parts library.
    func ingestGenerate(job: JobInfo, result: JobResult) {
        let jobId = job.jobId
        // Reimagine recipes that produce material, not songs (AI extract,
        // lego layers): route the take into the Parts library.
        if case .generativePart(let songId, _, let kind, _)? =
            pendingContext[jobId] {
            var parts: [PartRecord] = []
            if let output = (result.outputs ?? []).first {
                if let part = insertGenerativePart(
                    songId: songId, kind: kind,
                    filePath: output.path, sampleRate: output.sampleRate,
                    durationS: output.durationS, job: job) {
                    parts.append(part)
                }
            }
            active[jobId]?.status = .succeeded
            active[jobId]?.progress = nil
            onPartsIngested(parts)
            return
        }
        let outputs = result.outputs ?? []
        // The seed is taken in `landTake`, from take a of the batch — not
        // here. Read off "this job's first output", it was take a's seed only
        // while a batch was one job: now every take is a job, so each landing
        // would overwrite it and "hold the seed" would reuse whichever take
        // finished last.
        // Takes may have landed one by one while the batch ran
        // (`job.take_done`); this pass ingests only what is left, so a
        // client that saw every event and one that saw none converge on the
        // same library.
        var fresh: [SongRecord] = []
        for (offset, output) in outputs.enumerated() {
            if let song = landTake(job: job, index: job.batchIndex(of: offset),
                                   output: output) {
                fresh.append(song)
            }
        }
        active[jobId]?.status = .succeeded
        active[jobId]?.progress = nil
        active[jobId]?.producedSongIds += fresh.map(\.id)
        // The batch's shared naming state outlives this job — its siblings are
        // still rendering under the same base name — so it goes only when the
        // whole submission has stopped.
        dropBatchIngestIfFinished(jobId)
        // Only the takes this pass created: the incremental ones were
        // announced when they landed, and announcing a song twice makes
        // anything counting arrivals count it twice.
        onSongsIngested(fresh)
    }

    // MARK: Incremental takes

    /// Bookkeeping for a batch whose takes land one at a time. `names` are
    /// the batch's raw letter names (track042a…d); titles are made unique
    /// per insert, so the set of already-used ones travels along.
    private struct TakeIngest {
        var names: [String]
        var ingested: Set<Int> = []
        var usedTitles: Set<String> = []
    }

    /// Keyed by `groupId`, not by job: the takes of one submission are
    /// separate jobs now (contract §5.1) and they have to keep sharing a base
    /// name. Keyed per job, four takes landed as four unrelated `trackNNN`s —
    /// and each would have read the library's high-water mark *after* the
    /// previous take was already in it, so they would not even have been
    /// consecutive.
    private var takeIngests: [String: TakeIngest] = [:]

    /// A finished take of a still-running batch (`job.take_done`): land it in
    /// the library now, so DONE fills while the next take renders. The
    /// completion pass skips whatever landed here.
    private func ingestTake(jobId: String, take: Int, output: JobOutput) {
        guard let info = active[jobId]?.info, info.isGenerate else { return }
        // Generative parts route through their own ingest at completion, and
        // are single-take by construction — nothing to land early.
        if case .generativePart? = pendingContext[jobId] { return }
        guard let song = landTake(job: info, index: info.batchIndex(of: take),
                                  output: output) else { return }
        active[jobId]?.producedSongIds.append(song.id)
        onSongsIngested([song])
    }

    /// Move one take into the library under its batch's shared name, or nil if
    /// it already landed (both the incremental event and the completion pass
    /// offer it) or its file could not be moved.
    private func landTake(job: JobInfo, index: Int,
                          output: JobOutput) -> SongRecord? {
        var state = takeIngests[job.groupId]
            ?? TakeIngest(names: allocateTakeNames(
                jobId: job.jobId,
                count: max(job.takesInBatch, index + 1)))
        guard !state.ingested.contains(index),
              index < state.names.count else { return nil }
        if index == 0, let seed = output.seedUsed { lastSeedUsed = seed }
        let title = (try? repo.uniqueTitle(state.names[index],
                                           reserved: state.usedTitles))
            ?? state.names[index]
        guard let song = ingestOneTake(job: job, output: output,
                                       title: title) else { return nil }
        state.ingested.insert(index)
        state.usedTitles.insert(title)
        takeIngests[job.groupId] = state
        return song
    }

    /// Let go of a batch's shared naming state once no take of it is still
    /// running. Nothing in the library is touched: takes that landed before a
    /// failure or a cancel are finished audio and stay.
    private func dropBatchIngestIfFinished(_ jobId: String) {
        guard let info = active[jobId]?.info,
              unfinishedBatchJobs(info.groupId).isEmpty else { return }
        takeIngests.removeValue(forKey: info.groupId)
    }

    /// Names are allocated up front, and the whole submission shares one
    /// base: four takes of one prompt are four attempts at the same thing,
    /// so they read as track042a…d — or "Warehouse jam (a)"…"(d)" under a
    /// typed name — rather than as four unrelated tracks. The DB is
    /// consulted once, and only when the name was left at its default.
    private func allocateTakeNames(jobId: String, count: Int) -> [String] {
        let chosen: String?
        if case .generate(let name)? = pendingContext[jobId] { chosen = name }
        else { chosen = nil }
        let base = chosen ?? SongRecord.trackName(
            number: ((try? repo.highestTrackNumber()) ?? 0) + 1)
        return SongRecord.takeNames(base: base, count: count)
    }

    /// Move one finished take into the library and insert its record. The
    /// letter is keyed to the take's position, so a take whose file could
    /// not be moved leaves a gap rather than shifting every take after it
    /// onto the wrong letter.
    private func ingestOneTake(job: JobInfo, output: JobOutput,
                               title: String) -> SongRecord? {
        let songId = UUID().uuidString.lowercased()
        let fileName = songId + ".wav"
        let dest = StoragePaths.libraryAudio.appendingPathComponent(fileName)
        do {
            try FileManager.default.createDirectory(
                at: StoragePaths.libraryAudio, withIntermediateDirectories: true)
            // same volume → atomic rename
            try FileManager.default.moveItem(
                at: URL(fileURLWithPath: output.path), to: dest)
        } catch {
            lastError = "Could not move finished audio: \(error.localizedDescription)"
            return nil
        }
        // The take's own `meta` is stored alongside the params it was made
        // with. For a model that plans before it renders, that is the plan
        // — tempo, key, and the sketch the renderer worked from — and it
        // is the only record of it: the engine keeps no history, so a plan
        // not written down here is gone the moment the job ages out.
        //
        // It rides *inside* paramsJSON under "meta" rather than in a
        // column of its own because that field is already the bag of
        // everything-about-this-render, and only these cards read it.
        var stored = job.params
        if let meta = output.meta ?? job.result?.meta, !meta.isEmpty {
            stored[GenerationSettings.metaKey] = .object(meta)
        }
        // Length and take count are arguments of the submission rather than
        // params, so without this the bag remembers every knob and neither of
        // the two numbers the composer asks for first. `job.durationS` is what
        // was *asked for*: the row's own `durationS` is what came back, and a
        // model that pads or trims to its own frame size does not return the
        // length it was given.
        stored[GenerationSettings.requestKey] = GenerationSettings
            .requestEnvelope(durationS: job.durationS, takes: job.takesInBatch)
        let paramsJSON = (try? String(
            decoding: BackendClient.encoder.encode(stored),
            as: UTF8.self)) ?? "{}"
        let song = SongRecord(
            id: songId, title: title, prompt: job.prompt,
            lyrics: job.lyrics, modelId: job.modelId,
            modelName: modelName(job.modelId), groupId: job.groupId,
            paramsJSON: paramsJSON, durationS: output.durationS,
            sampleRate: output.sampleRate, fileName: fileName,
            seedUsed: output.seedUsed, createdAt: Date(), rating: 0,
            notes: "", favorite: false)
        do {
            try repo.insert(song)
            return song
        } catch {
            lastError = "Could not save song: \(error.localizedDescription)"
            return nil
        }
    }

    /// Route a task job's typed artifacts: stems/notes → parts library,
    /// analysis → the owner's analysis attachment. Internal for tests.
    func ingestArtifacts(job: JobInfo, result: JobResult) {
        let jobId = job.jobId
        let context = pendingContext[jobId]
        guard let partsRepo else {
            active[jobId]?.status = .failed
            active[jobId]?.error = APIErrorBody(
                code: "INTERNAL", message: "no parts library available")
            return
        }
        let artifacts = result.artifacts ?? []
        let fm = FileManager.default
        try? fm.createDirectory(at: StoragePaths.libraryParts,
                                withIntermediateDirectories: true)

        let songId: String
        switch context {
        case .split(let id, _):
            songId = id
        case .analyze(let ownerId, let ownerType, _):
            // Analysis-only job: no parts are created.
            ingestAnalysis(artifacts, ownerId: ownerId, ownerType: ownerType,
                           modelId: job.modelId, repo: partsRepo,
                           meta: result.meta)
            // Late analysis of an already-split song: stems share its grid,
            // so propagate (mirrors the split-time copy below).
            if ownerType == "song",
               let songAnalysis = ((try? partsRepo.analysis(ownerId: ownerId))
                                   ?? nil),
               let songParts = try? partsRepo.allParts(forSong: ownerId) {
                for part in songParts where part.format == "wav" {
                    var copy = propagatedCopy(songAnalysis)
                    copy.ownerId = part.id
                    copy.ownerType = "part"
                    try? partsRepo.upsertAnalysis(copy)
                }
            }
            active[jobId]?.status = .succeeded
            active[jobId]?.progress = nil
            onPartsIngested([])   // refresh part badges with the new analysis
            return
        case .text(let textContext):
            let docs = ingestText(artifacts, context: textContext, job: job,
                                  result: result, repo: partsRepo)
            active[jobId]?.status = .succeeded
            active[jobId]?.progress = nil
            onTextIngested(docs)
            return
        case .recombine(let recipeId, let title, let applied):
            ingestRecombine(job: job, result: result, recipeId: recipeId,
                            title: title, applied: applied, repo: partsRepo)
            return
        case .editor(let purpose):
            guard artifacts.contains(where: { $0.kind == "audio" }) else {
                active[jobId]?.status = .failed
                active[jobId]?.error = APIErrorBody(
                    code: "INTERNAL", message: "edit render produced no audio")
                return
            }
            onEditorArtifact(job, result, purpose)
            active[jobId]?.status = .succeeded
            active[jobId]?.progress = nil
            return
        case .generativePart(let ownerSongId, _, let kind, _):
            // Render task jobs (notes → SoundFont audio): the single audio
            // artifact becomes a part of the source song.
            var parts: [PartRecord] = []
            if let artifact = artifacts.first(where: { $0.kind == "audio" }),
               let part = insertGenerativePart(
                   songId: ownerSongId, kind: kind,
                   filePath: artifact.path, sampleRate: artifact.sampleRate,
                   durationS: artifact.durationS, job: job) {
                parts.append(part)
            }
            active[jobId]?.status = .succeeded
            active[jobId]?.progress = nil
            onPartsIngested(parts)
            return
        default:
            // Unknown contexts (post-relaunch reconciliation) have nowhere to
            // route artifacts.
            active[jobId]?.status = .succeeded
            active[jobId]?.progress = nil
            return
        }

        // Previews pair to same-label midi parts: "preview:<label>".
        var previews: [String: JobArtifact] = [:]
        for artifact in artifacts where artifact.label.hasPrefix("preview:") {
            previews[String(artifact.label.dropFirst("preview:".count))] = artifact
        }

        // Job params minus resolved absolute paths (provenance, not plumbing).
        let provenanceParams = job.params.filter { _, value in
            if case .string(let s) = value, s.hasPrefix("/") { return false }
            return true
        }
        let paramsJSON = (try? String(
            decoding: BackendClient.encoder.encode(provenanceParams),
            as: UTF8.self)) ?? "{}"

        // Read once, not per stem: every part of this split is named after
        // the same song, and the name is the only thing the row needs it for.
        let songTitle = ((try? repo.song(id: songId)) ?? nil)?.title ?? ""

        var parts: [PartRecord] = []
        var textDocs: [TextDocRecord] = []
        for artifact in artifacts {
            switch artifact.kind {
            case "stem", "midi":
                let partId = UUID().uuidString.lowercased()
                let ext = artifact.kind == "midi" ? "mid" : artifact.format
                let fileName = "\(partId).\(ext)"
                let dest = StoragePaths.libraryParts.appendingPathComponent(fileName)
                do {
                    try fm.moveItem(at: URL(fileURLWithPath: artifact.path),
                                    to: dest)
                } catch {
                    lastError = "Could not move part: \(error.localizedDescription)"
                    continue
                }
                var previewFileName: String?
                if artifact.kind == "midi", let preview = previews[artifact.label] {
                    let name = "\(partId).preview.wav"
                    let previewDest = StoragePaths.libraryParts
                        .appendingPathComponent(name)
                    if (try? fm.moveItem(
                        at: URL(fileURLWithPath: preview.path),
                        to: previewDest)) != nil {
                        previewFileName = name
                    }
                }
                let label = artifact.label.isEmpty ? artifact.kind : artifact.label
                let kind = artifact.kind == "stem"
                    ? "stem.\(Self.sanitize(label))"
                    : "notes.\(Self.sanitize(label))"
                let part = PartRecord(
                    id: partId, songId: songId, kind: kind,
                    name: partName(songTitle: songTitle, kind: kind,
                                   repo: partsRepo),
                    fileName: fileName,
                    format: artifact.kind == "midi" ? "midi" : "wav",
                    previewFileName: previewFileName, modelId: job.modelId,
                    modelName: modelName(job.modelId), jobId: jobId,
                    splitParamsJSON: paramsJSON,
                    durationS: artifact.durationS,
                    sampleRate: artifact.sampleRate, createdAt: Date())
                do {
                    try partsRepo.insert(part)
                    parts.append(part)
                } catch {
                    lastError = "Could not save part: \(error.localizedDescription)"
                }
            case "analysis":
                ingestAnalysis([artifact], ownerId: songId, ownerType: "song",
                               modelId: job.modelId, repo: partsRepo,
                               meta: result.meta)
            case "text":
                // A transcribe run with emit_abc writes each track's notation
                // beside its midi ("abc:<label>"); a compose lands its ABC
                // beside the composition midi. Either way the words belong on
                // the source song as an "abc" document — this arm is the
                // entire ingest story for extracted notation.
                textDocs += ingestText(
                    [artifact],
                    context: TextJobContext(
                        ownerId: songId, ownerType: "song",
                        title: songTitle, kind: .abc),
                    job: job, result: result, repo: partsRepo)
            default:
                break   // audio artifacts (recombine output) land in SR2
            }
        }
        // A split-time analysis describes the source; stems share its grid.
        if let songAnalysis = try? partsRepo.analysis(ownerId: songId) {
            for part in parts where part.format == "wav" {
                var copy = propagatedCopy(songAnalysis)
                copy.ownerId = part.id
                copy.ownerType = "part"
                try? partsRepo.upsertAnalysis(copy)
            }
        }
        active[jobId]?.status = .succeeded
        active[jobId]?.progress = nil
        onPartsIngested(parts)
        if !textDocs.isEmpty { onTextIngested(textDocs) }
    }

    /// A finished mix: the mixdown becomes a library song (origin
    /// "recombined") with ingredient provenance; keep_tracks stems become
    /// parts of the NEW song so the result is immediately re-mixable.
    private func ingestRecombine(job: JobInfo, result: JobResult,
                                 recipeId: String?, title: String,
                                 applied: [AppliedIngredient],
                                 repo partsRepo: PartsRepository) {
        let jobId = job.jobId
        let artifacts = result.artifacts ?? []
        guard let mixdown = artifacts.first(where: { $0.kind == "audio" })
        else {
            active[jobId]?.status = .failed
            active[jobId]?.error = APIErrorBody(
                code: "INTERNAL", message: "mix finished without audio")
            return
        }
        let fm = FileManager.default
        let songId = UUID().uuidString.lowercased()
        let fileName = songId + ".wav"
        let dest = StoragePaths.libraryAudio.appendingPathComponent(fileName)
        do {
            try fm.createDirectory(at: StoragePaths.libraryAudio,
                                   withIntermediateDirectories: true)
            try fm.moveItem(at: URL(fileURLWithPath: mixdown.path), to: dest)
        } catch {
            active[jobId]?.status = .failed
            active[jobId]?.error = APIErrorBody(
                code: "INTERNAL",
                message: "could not move the mix: \(error.localizedDescription)")
            return
        }
        let song = SongRecord(
            id: songId, title: (try? repo.uniqueTitle(title)) ?? title,
            prompt: "", lyrics: nil,
            modelId: job.modelId, modelName: modelName(job.modelId),
            groupId: job.groupId, paramsJSON: "{}",
            durationS: mixdown.durationS ?? 0,
            sampleRate: mixdown.sampleRate ?? 44100, fileName: fileName,
            seedUsed: nil, createdAt: Date(), rating: 0, notes: "",
            favorite: false, origin: "recombined", recipeId: recipeId)
        var songs: [SongRecord] = []
        do {
            try repo.insert(song)
            songs.append(song)
            let rows = applied.map { item in
                SongIngredientRecord(
                    songId: songId, slotId: item.submission.slotId,
                    partId: item.submission.partId,
                    sourceSongTitle: item.sourceSongTitle,
                    transformJSON: (try? String(
                        decoding: BackendClient.encoder.encode(item),
                        as: UTF8.self)) ?? "{}")
            }
            try partsRepo.setIngredients(rows, songId: songId)
        } catch {
            lastError = "Could not save the mix: \(error.localizedDescription)"
        }

        // keep_tracks: post-processed per-role stems arrive as "stem" artifacts
        var parts: [PartRecord] = []
        try? fm.createDirectory(at: StoragePaths.libraryParts,
                                withIntermediateDirectories: true)
        for artifact in artifacts where artifact.kind == "stem" {
            let partId = UUID().uuidString.lowercased()
            let partFile = "\(partId).wav"
            let partDest = StoragePaths.libraryParts
                .appendingPathComponent(partFile)
            guard (try? fm.moveItem(at: URL(fileURLWithPath: artifact.path),
                                    to: partDest)) != nil else { continue }
            let label = artifact.label.isEmpty ? "track" : artifact.label
            let kind = "stem.\(Self.sanitize(label))"
            let part = PartRecord(
                id: partId, songId: songId,
                kind: kind,
                name: partName(songTitle: song.title, kind: kind,
                               repo: partsRepo),
                fileName: partFile, format: "wav", previewFileName: nil,
                modelId: job.modelId, modelName: modelName(job.modelId),
                jobId: jobId, splitParamsJSON: "{}",
                durationS: artifact.durationS,
                sampleRate: artifact.sampleRate, createdAt: Date())
            if (try? partsRepo.insert(part)) != nil { parts.append(part) }
        }

        active[jobId]?.status = .succeeded
        active[jobId]?.progress = nil
        record(songs, for: jobId)
        onSongsIngested(songs)
        if !parts.isEmpty { onPartsIngested(parts) }
    }

    /// Land `text` artifacts as documents on the context's owner.
    ///
    /// The context's `kind` is authoritative — the payload's own `kind` is
    /// advisory (a captioner asked to describe writes "caption" whether the
    /// result is bound for a description slot or not). Empty text inserts
    /// nothing: an instrumental transcribed for lyrics is a model that heard
    /// no words, not a failure worth a blank row. The artifact file is
    /// deleted after decode, like an analysis artifact.
    private func ingestText(_ artifacts: [JobArtifact],
                            context: TextJobContext, job: JobInfo,
                            result: JobResult,
                            repo: PartsRepository) -> [TextDocRecord] {
        var docs: [TextDocRecord] = []
        for artifact in artifacts where artifact.kind == "text" {
            let url = URL(fileURLWithPath: artifact.path)
            var payload: TextPayload?
            if let data = try? Data(contentsOf: url) {
                payload = try? BackendClient.decoder.decode(
                    TextPayload.self, from: data)
                try? FileManager.default.removeItem(at: url)
            }
            if payload == nil, let metaText = result.meta?["text"],
               let data = try? BackendClient.encoder.encode(metaText) {
                // The payload also rides result.meta (contract 5.4) — the
                // same fallback ingestAnalysis makes for headline numbers.
                payload = try? BackendClient.decoder.decode(
                    TextPayload.self, from: data)
            }
            guard let payload else { continue }
            guard let doc = Self.textDoc(from: payload, context: context,
                                         modelId: job.modelId,
                                         modelName: modelName(job.modelId),
                                         jobId: job.jobId) else { continue }
            do {
                try repo.insertTextDoc(doc)
                docs.append(doc)
            } catch {
                lastError = "Could not save text: \(error.localizedDescription)"
                continue
            }
            if context.applyTags, context.ownerType == "song" {
                applyTags(payload.tags ?? [], songId: context.ownerId)
            }
        }
        return docs
    }

    /// Build the stored document for one payload, or nil when there is
    /// nothing worth storing. Internal (not private) for tests, like
    /// `ingestGenerate`.
    static func textDoc(from payload: TextPayload, context: TextJobContext,
                        modelId: String, modelName: String,
                        jobId: String?) -> TextDocRecord? {
        let text: String
        if context.kind == .tags {
            // A tags document's text is its labels, one per line — readable
            // in any slot that shows it, and searchable like the rest.
            text = (payload.tags ?? []).map(\.label)
                .joined(separator: "\n")
        } else {
            text = (payload.text ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !text.isEmpty else { return nil }
        let segmentsJSON = payload.segments.flatMap { segments -> String? in
            guard !segments.isEmpty,
                  let data = try? JSONEncoder().encode(segments)
            else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
        return TextDocRecord(
            id: UUID().uuidString.lowercased(),
            ownerId: context.ownerId, ownerType: context.ownerType,
            kind: context.kind.rawValue, text: text,
            segmentsJSON: segmentsJSON,
            question: context.question ?? payload.question,
            language: payload.language,
            modelId: modelId, modelName: modelName, jobId: jobId,
            edited: false, createdAt: Date(), updatedAt: Date())
    }

    /// Merge model tags into the song's own tag records — the same rows the
    /// user edits by hand, so the labels are findable exactly where typed
    /// ones are. Union, capped: a tagger's fifteenth-best guess is noise,
    /// and nothing the user already chose is ever removed.
    private func applyTags(_ tags: [TextPayload.Tag], songId: String) {
        let confident = tags
            .filter { ($0.score ?? 1.0) >= 0.35 }
            .prefix(6)
            .map { $0.label.lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !confident.isEmpty else { return }
        let existing = (try? repo.tags(for: songId)) ?? []
        var merged = existing
        for label in confident where !merged.contains(where: {
            $0.caseInsensitiveCompare(label) == .orderedSame
        }) {
            merged.append(label)
        }
        guard merged != existing else { return }
        try? repo.setTags(merged, for: songId)
    }

    private func ingestAnalysis(_ artifacts: [JobArtifact], ownerId: String,
                                ownerType: String, modelId: String,
                                repo: PartsRepository,
                                meta: [String: JSONValue]?) {
        for artifact in artifacts where artifact.kind == "analysis" {
            let url = URL(fileURLWithPath: artifact.path)
            guard let data = try? Data(contentsOf: url) else { continue }
            // Specialist analyzers (chords, quality) describe one facet;
            // their payload merges into the owner's stored analysis so the
            // beat grid and key the workbench reads survive the run.
            if let raw = (try? JSONSerialization.jsonObject(with: data))
                as? [String: Any],
               raw["analysis_version"] == nil,
               raw["chords_version"] != nil || raw["quality_version"] != nil {
                mergeSpecialistAnalysis(raw, ownerId: ownerId,
                                        ownerType: ownerType,
                                        modelId: modelId, repo: repo)
                try? FileManager.default.removeItem(at: url)
                continue
            }
            let payload = try? BackendClient.decoder.decode(
                AnalysisPayload.self, from: data)
            let record = AnalysisRecord(
                ownerId: ownerId, ownerType: ownerType,
                bpm: payload?.tempoBpm ?? meta?["tempo_bpm"]?.doubleValue,
                keyName: payload?.key,
                camelot: payload?.camelot,
                analysisJSON: String(decoding: data, as: UTF8.self),
                modelId: modelId, createdAt: Date())
            try? repo.upsertAnalysis(record)
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// A part inherits its song's grid, key, and chords — but not its
    /// quality scores: SQUIM measured the mix, not the stem.
    private func propagatedCopy(_ record: AnalysisRecord) -> AnalysisRecord {
        guard record.analysisJSON.contains("\"quality\"") else { return record }
        guard var obj = (try? JSONSerialization.jsonObject(
                  with: Data(record.analysisJSON.utf8))) as? [String: Any],
              obj["quality"] != nil
        else { return record }
        obj.removeValue(forKey: "quality")
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let json = String(data: data, encoding: .utf8)
        else { return record }
        var copy = record
        copy.analysisJSON = json
        return copy
    }

    /// Fold a chords or quality payload into the owner's analysis record
    /// under top-level "chords" / "quality" keys, preserving everything the
    /// musical analyzer wrote. A fresh record (bpm/key nil) is only created
    /// when the owner has never been analyzed.
    private func mergeSpecialistAnalysis(_ raw: [String: Any], ownerId: String,
                                         ownerType: String, modelId: String,
                                         repo: PartsRepository) {
        let existing = (try? repo.analysis(ownerId: ownerId)) ?? nil
        var merged: [String: Any] = [:]
        if let existing,
           let stored = (try? JSONSerialization.jsonObject(
               with: Data(existing.analysisJSON.utf8))) as? [String: Any] {
            merged = stored
        }
        if raw["chords_version"] != nil {
            merged["chords"] = raw["segments"] ?? []
        }
        if raw["quality_version"] != nil {
            var quality: [String: Any] = [:]
            for key in ["stoi", "pesq", "si_sdr", "caveat"] {
                if let value = raw[key] { quality[key] = value }
            }
            merged["quality"] = quality
        }
        guard let data = try? JSONSerialization.data(withJSONObject: merged),
              let json = String(data: data, encoding: .utf8) else { return }
        if var record = existing {
            record.analysisJSON = json
            try? repo.upsertAnalysis(record)
        } else {
            try? repo.upsertAnalysis(AnalysisRecord(
                ownerId: ownerId, ownerType: ownerType,
                bpm: nil, keyName: nil, camelot: nil,
                analysisJSON: json, modelId: modelId, createdAt: Date()))
        }
    }

    /// Move one generative output/artifact into the Parts library.
    ///
    /// The context's `name` is deliberately not used for the row: it is the
    /// queue card's title ("AI Vocals"), written for a job that is running,
    /// while the part it leaves behind is named like every other part — after
    /// its source song and its kind. Where that collides with a stem the
    /// separator already cut, the `-2` is the honest reading: they are two
    /// versions of the same thing, told apart by the model badge beside them
    /// and renameable to whatever the user prefers.
    private func insertGenerativePart(songId: String, kind: String,
                                      filePath: String,
                                      sampleRate: Int?, durationS: Double?,
                                      job: JobInfo) -> PartRecord? {
        guard let partsRepo else { return nil }
        let partId = UUID().uuidString.lowercased()
        let fileName = "\(partId).wav"
        let fm = FileManager.default
        try? fm.createDirectory(at: StoragePaths.libraryParts,
                                withIntermediateDirectories: true)
        do {
            try fm.moveItem(at: URL(fileURLWithPath: filePath),
                            to: StoragePaths.libraryParts
                                .appendingPathComponent(fileName))
        } catch {
            lastError = "Could not move part: \(error.localizedDescription)"
            return nil
        }
        let provenance = job.params.filter { _, value in
            if case .string(let s) = value, s.hasPrefix("/") { return false }
            return true
        }
        let paramsJSON = (try? String(
            decoding: BackendClient.encoder.encode(provenance),
            as: UTF8.self)) ?? "{}"
        let songTitle = ((try? repo.song(id: songId)) ?? nil)?.title ?? ""
        let part = PartRecord(
            id: partId, songId: songId, kind: kind,
            name: partName(songTitle: songTitle, kind: kind, repo: partsRepo),
            fileName: fileName, format: "wav", previewFileName: nil,
            modelId: job.modelId, modelName: modelName(job.modelId),
            jobId: job.jobId, splitParamsJSON: paramsJSON,
            durationS: durationS, sampleRate: sampleRate, createdAt: Date())
        do {
            try partsRepo.insert(part)
            return part
        } catch {
            lastError = "Could not save part: \(error.localizedDescription)"
            return nil
        }
    }

    /// The name a freshly cut part is filed under: `vocals-track042`, made
    /// free of whatever the library already holds.
    ///
    /// Ingest never refuses a name — see `PartsRepository.uniqueName` — so the
    /// fallback here is the unresolved default rather than nothing. A part
    /// whose name collides is still a part the user can hear and rename; a
    /// part that failed to be written is work thrown away.
    private func partName(songTitle: String, kind: String,
                          repo: PartsRepository) -> String {
        let wanted = PartNaming.defaultName(songTitle: songTitle, kind: kind)
        return (try? repo.uniqueName(wanted)) ?? wanted
    }

    private static func sanitize(_ label: String) -> String {
        label.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }
}

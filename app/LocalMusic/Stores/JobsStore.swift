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
    }

    var target: Target
    var tracks: [Track]
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

    /// Set by AppEnvironment: display name lookup + post-ingest notification.
    var modelName: (String) -> String = { $0 }
    var onSongsIngested: ([SongRecord]) -> Void = { _ in }
    var onPartsIngested: ([PartRecord]) -> Void = { _ in }
    /// A finished Editor render, with why it was made. The audio artifact's
    /// file still sits in the engine's Outputs directory; the handler moves
    /// it or the 24 h GC takes it.
    var onEditorArtifact: (JobInfo, JobResult, EditorRenderPurpose) -> Void = {
        _, _, _ in }

    private let repo: LibraryRepository
    /// Present when the parts library exists (nil in some legacy tests).
    var partsRepo: PartsRepository?

    init(repo: LibraryRepository, partsRepo: PartsRepository? = nil) {
        self.repo = repo
        self.partsRepo = partsRepo
    }

    var displayJobs: [ActiveJob] {
        active.values.sorted {
            ($0.info.queuePosition ?? 99, $0.info.createdAt)
                < ($1.info.queuePosition ?? 99, $1.info.createdAt)
        }
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
            for ref in created.jobs {
                if let chosen, !chosen.isEmpty {
                    pendingContext[ref.jobId] = .generate(name: chosen)
                }
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
            let role = part.kind.split(separator: ".").last.map(String.init)
                ?? part.name.lowercased()
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
                fadeInS: (sub.fadeInS ?? 0) > 0 ? sub.fadeInS : nil,
                fadeOutS: (sub.fadeOutS ?? 0) > 0 ? sub.fadeOutS : nil,
                sourceBpm: sourceBpm,
                sourceDownbeats: item.summary?.downbeats,
                stretch: MixSpec.Stretch(
                    mode: mode,
                    transientMode: isDrums ? "crisp" : "smooth",
                    preserveFormants: item.kind.hasPrefix("stem.vocals")),
                pitchShiftSt: shift))
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
            target: MixSpec.Target(bpm: targetBpm, key: targetCamelot,
                                   sampleRate: sampleRate, downbeats: nil,
                                   durationS: options.targetDurationS),
            tracks: tracks)
        return (spec, applied)
    }

    /// Literal recombination (task "mix"): resolve ingredients, plan the
    /// auto-match against the target grid, upload payloads, build mix_spec.
    @discardableResult
    func submitRecombine(modelId: String, recipeId: String?, title: String,
                         ingredients: [IngredientSubmission],
                         options: RecombineOptions = RecombineOptions())
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
                pendingContext[ref.jobId] = .recombine(
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
                kind: "layer.\(part.name.lowercased())",
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

    /// Human title for job rows/notifications — prompt for generations, an
    /// action description for promptless task jobs.
    func displayTitle(for info: JobInfo) -> String {
        switch pendingContext[info.jobId] {
        case .split(_, let sourceTitle):
            return info.task == "transcribe"
                ? "Transcribe: \(sourceTitle)" : "Split: \(sourceTitle)"
        case .analyze(_, _, let title):
            return "Analyze: \(title)"
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

    /// Whether this job was submitted by the Editor. The Actions sidebar row
    /// spins for "any task job", which an edit render otherwise satisfies —
    /// and the queue's generic completion banner would double up with the
    /// Editor's own.
    func isEditorJob(_ jobId: String) -> Bool {
        if case .editor = pendingContext[jobId] { return true }
        return false
    }

    func cancel(_ jobId: String) async {
        try? await client?.cancelJob(jobId)
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
        let title = chosen ?? SongRecord.trackName(
            number: ((try? repo.highestTrackNumber()) ?? 0) + 1)
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
        onSongsIngested([song])
        return song
    }

    func dismiss(_ jobId: String) {
        active.removeValue(forKey: jobId)
    }

    func reconcile() async {
        guard let client else { return }
        if let jobs = try? await client.jobs() {
            for job in jobs where active[job.jobId] == nil {
                active[job.jobId] = ActiveJob(info: job, progress: job.progress,
                                              status: job.status)
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
        case .jobCompleted(let jobId):
            // the engine drops a succeeded job's previews; keeping the path
            // would leave the well drawing from a file that is gone
            active[jobId]?.preview = nil
            Task { await ingest(jobId: jobId) }
        case .jobFailed(let jobId, let error):
            active[jobId]?.status = .failed
            active[jobId]?.error = error
        case .jobCanceled(let jobId):
            active[jobId]?.status = .canceled
        case .queueState(let held, _):
            queueHeld = held
        default:
            break
        }
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
        if case .generativePart(let songId, _, let kind, let name)? =
            pendingContext[jobId] {
            var parts: [PartRecord] = []
            if let output = (result.outputs ?? []).first {
                if let part = insertGenerativePart(
                    songId: songId, kind: kind, name: name,
                    filePath: output.path, sampleRate: output.sampleRate,
                    durationS: output.durationS, job: job) {
                    parts.append(part)
                }
            }
            active[jobId]?.status = .succeeded
            active[jobId]?.progress = nil
            onPartsIngested(parts)
            finish(jobId)
            return
        }
        var songs: [SongRecord] = []
        // Names are allocated up front, and the whole submission shares one
        // base: four takes of one prompt are four attempts at the same thing,
        // so they read as track042a…d — or "Warehouse jam (a)"…"(d)" under a
        // typed name — rather than as four unrelated tracks. The DB is
        // consulted once, and only when the name was left at its default.
        let outputs = result.outputs ?? []
        let chosen: String?
        if case .generate(let name)? = pendingContext[jobId] { chosen = name }
        else { chosen = nil }
        let base = chosen ?? SongRecord.trackName(
            number: ((try? repo.highestTrackNumber()) ?? 0) + 1)
        let names = SongRecord.takeNames(base: base, count: outputs.count)
        for (take, output) in outputs.enumerated() {
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
                continue
            }
            let paramsJSON = (try? String(
                decoding: BackendClient.encoder.encode(job.params),
                as: UTF8.self)) ?? "{}"
            // Generated tracks are named trackNNN; the prompt identifies them
            // in the UI, shown after the name rather than baked into it. The
            // letter is keyed to the take's position, so a take whose file
            // could not be moved leaves a gap rather than shifting every take
            // after it onto the wrong letter.
            let title = names[take]
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
                songs.append(song)
            } catch {
                lastError = "Could not save song: \(error.localizedDescription)"
            }
        }
        active[jobId]?.status = .succeeded
        active[jobId]?.progress = nil
        onSongsIngested(songs)
        finish(jobId)
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
                    var copy = songAnalysis
                    copy.ownerId = part.id
                    copy.ownerType = "part"
                    try? partsRepo.upsertAnalysis(copy)
                }
            }
            active[jobId]?.status = .succeeded
            active[jobId]?.progress = nil
            onPartsIngested([])   // refresh part badges with the new analysis
            finish(jobId)
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
            finish(jobId)
            return
        case .generativePart(let ownerSongId, _, let kind, let name):
            // Render task jobs (notes → SoundFont audio): the single audio
            // artifact becomes a part of the source song.
            var parts: [PartRecord] = []
            if let artifact = artifacts.first(where: { $0.kind == "audio" }),
               let part = insertGenerativePart(
                   songId: ownerSongId, kind: kind, name: name,
                   filePath: artifact.path, sampleRate: artifact.sampleRate,
                   durationS: artifact.durationS, job: job) {
                parts.append(part)
            }
            active[jobId]?.status = .succeeded
            active[jobId]?.progress = nil
            onPartsIngested(parts)
            finish(jobId)
            return
        default:
            // Unknown contexts (post-relaunch reconciliation) have nowhere to
            // route artifacts.
            active[jobId]?.status = .succeeded
            active[jobId]?.progress = nil
            finish(jobId)
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

        var parts: [PartRecord] = []
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
                    name: Self.partDisplayName(for: label), fileName: fileName,
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
            default:
                break   // audio artifacts (recombine output) land in SR2
            }
        }
        // A split-time analysis describes the source; stems share its grid.
        if let songAnalysis = try? partsRepo.analysis(ownerId: songId) {
            for part in parts where part.format == "wav" {
                var copy = songAnalysis
                copy.ownerId = part.id
                copy.ownerType = "part"
                try? partsRepo.upsertAnalysis(copy)
            }
        }
        active[jobId]?.status = .succeeded
        active[jobId]?.progress = nil
        onPartsIngested(parts)
        finish(jobId)
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
            id: songId, title: title, prompt: "", lyrics: nil,
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
            let part = PartRecord(
                id: partId, songId: songId,
                kind: "stem.\(Self.sanitize(label))",
                name: Self.partDisplayName(for: label),
                fileName: partFile, format: "wav", previewFileName: nil,
                modelId: job.modelId, modelName: modelName(job.modelId),
                jobId: jobId, splitParamsJSON: "{}",
                durationS: artifact.durationS,
                sampleRate: artifact.sampleRate, createdAt: Date())
            if (try? partsRepo.insert(part)) != nil { parts.append(part) }
        }

        active[jobId]?.status = .succeeded
        active[jobId]?.progress = nil
        onSongsIngested(songs)
        if !parts.isEmpty { onPartsIngested(parts) }
        finish(jobId)
    }

    private func ingestAnalysis(_ artifacts: [JobArtifact], ownerId: String,
                                ownerType: String, modelId: String,
                                repo: PartsRepository,
                                meta: [String: JSONValue]?) {
        for artifact in artifacts where artifact.kind == "analysis" {
            let url = URL(fileURLWithPath: artifact.path)
            guard let data = try? Data(contentsOf: url) else { continue }
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

    /// Move one generative output/artifact into the Parts library.
    private func insertGenerativePart(songId: String, kind: String,
                                      name: String, filePath: String,
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
        let part = PartRecord(
            id: partId, songId: songId, kind: kind, name: name,
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

    /// Display name for a stem/track label. "other" is separation jargon for
    /// the residual — spell out what actually lives in it.
    static func partDisplayName(for label: String) -> String {
        label.lowercased() == "other" ? "Other (keys, synths, rest)"
                                      : label.capitalized
    }

    private static func sanitize(_ label: String) -> String {
        label.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    /// Finished jobs leave the queue view after a short grace period.
    private func finish(_ jobId: String) {
        Task {
            try? await Task.sleep(for: .seconds(8))
            if active[jobId]?.status == .succeeded {
                dismiss(jobId)
                pendingContext.removeValue(forKey: jobId)
            }
        }
    }
}

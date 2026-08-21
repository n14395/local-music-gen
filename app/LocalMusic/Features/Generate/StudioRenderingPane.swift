import SwiftUI

/// Studio while something is rendering.
///
/// The complaint this answers is "no sense of progress". So: the take being
/// made gets the whole top of the screen with a percentage you can read from
/// across the room, the pipeline says which stage is running rather than
/// hiding it in a message string, and finished takes stay playable underneath.
///
/// The queue used to be a rail down the right of this pane. It is the shell's
/// panel now (`QueueRail`), which the transport bar opens from any screen and
/// which opens itself when a batch starts — so it still arrives unasked when
/// you press Generate, and it no longer disappears the moment you look at
/// something else.
struct StudioRenderingPane: View {
    let jobs: JobsStore
    let library: LibraryStore
    let playback: PlaybackController
    let catalog: ModelCatalogStore
    let actions: SongActions
    let renderingJobs: [JobsStore.ActiveJob]

    /// Shared with StudioView, which reads it when it submits: previews are
    /// decided at submit time, so this toggle arms takes rather than switching
    /// the running one.
    @AppStorage("studio.streamPreview") private var streamPreview = false

    private var lead: JobsStore.ActiveJob? { renderingJobs.first }

    /// Takes that finished while this batch was running, newest first —
    /// generations only, since a file imported half an hour ago did not come
    /// out of this run and reading as though it had would misreport the batch.
    private var doneRecently: [SongRecord] {
        library.recent.filter {
            $0.originKind == .generated
                && Date().timeIntervalSince($0.createdAt) < 1800
        }
        .prefix(3).map { $0 }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let lead { heroCard(lead) }
                if !doneRecently.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("DONE").eyebrow()
                        ForEach(doneRecently) { song in
                            doneRow(song)
                        }
                    }
                }
            }
            .padding(.horizontal, 30).padding(.vertical, 26)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Hero

    private func heroCard(_ job: JobsStore.ActiveJob) -> some View {
        let model = catalog.models.first { $0.id == job.info.modelId }
        let fraction = job.progress?.fraction
        let title = jobs.displayTitle(for: job.info)
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    // "Take 2 of 4 · <prompt>" — the percentage beside it is
                    // the average over every take, so without this the card
                    // never says which one you are actually listening to.
                    Text(job.takeLabel.map { "\($0) · \(title)" } ?? title)
                        .font(.system(size: 17, weight: .semibold))
                        .tracking(-0.15)
                        .foregroundStyle(Bench.Palette.textPrimary)
                        .lineLimit(2)
                    Text(heroMeta(job, model: model))
                        .metaLine()
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 4) {
                    if let fraction {
                        Text("\(Int((fraction * 100).rounded()))%")
                            .font(Bench.Typo.mono(26, .semibold))
                            .foregroundStyle(Bench.Palette.accent)
                    } else {
                        BenchSpinner(size: 24, lineWidth: 2.5)
                    }
                    if let eta = job.progress?.etaS, eta > 1 {
                        Text("\(JobRow.duration(eta)) LEFT")
                            .font(Bench.Typo.mono(11))
                            .foregroundStyle(Bench.Palette.textQuaternary)
                    }
                }
            }

            GenerationWell(job: job, stages: model?.capabilities.pipeline)

            RenderPipelineView(stages: model?.capabilities.pipeline,
                               progress: job.progress,
                               status: job.status)

            HStack(spacing: 10) {
                // Only offered where the model can actually decode partial
                // audio: for every other family there is nothing real to show,
                // and the engine refuses the flag (contract 5.6).
                if model?.capabilities.canPreview == true {
                    BenchToggleChip(isOn: $streamPreview,
                                    label: "Preview as it renders")
                    if streamPreview && job.info.preview != true {
                        Text("FROM THE NEXT TAKE")
                            .font(Bench.Typo.mono(10))
                            .foregroundStyle(Bench.Palette.textFaintest)
                    }
                }
                Spacer()
                if job.preview != nil {
                    Button("Keep partial") {
                        Task { await jobs.keepPartial(job.id) }
                    }
                    .buttonStyle(.bench(.accent))
                    .help("Stop here and save the audio rendered so far.")
                }
                Button("Cancel take") {
                    Task { await jobs.cancel(job.id) }
                }
                .buttonStyle(.bench(.destructive))
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .benchCard(stroke: Bench.Palette.accent.opacity(0.22),
                   radius: Bench.Metrics.Radius.cardLarge)
        .shadow(color: Bench.Palette.accent.opacity(0.18), radius: 30, y: 8)
    }

    private func heroMeta(_ job: JobsStore.ActiveJob, model: ModelInfo?) -> String {
        var parts = [(model?.displayName ?? job.info.modelId).uppercased()]
        if let duration = job.info.durationS {
            parts.append("\(Int(duration.rounded())) S")
        }
        if let seed = job.info.params["seed"]?.doubleValue, seed > 0 {
            parts.append("SEED \(Int(seed).formatted(.number.grouping(.automatic)))")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Done rows

    private func doneRow(_ song: SongRecord) -> some View {
        let isCurrent = playback.currentSongId == song.id
        return HStack(spacing: 16) {
            BenchPlayButton(isPlaying: isCurrent && playback.isPlaying,
                            isCurrent: isCurrent, size: 36) {
                playback.play(url: song.fileURL, songId: song.id, title: song.title,
                              duration: song.durationS,
                              subtitle: "\(song.modelName) · \(Int(song.durationS.rounded())) s")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(Bench.Typo.bodyEmphasis)
                    .foregroundStyle(Bench.Palette.textPrimary)
                    .lineLimit(1)
                Text("\(Int(song.durationS.rounded())) S"
                     + (song.seedUsed.map { " · SEED \($0.formatted(.number.grouping(.automatic)))" } ?? ""))
                    .metaLine()
            }
            .frame(width: 170, alignment: .leading)
            BenchWaveformLoader(audioURL: song.fileURL, cacheURL: song.waveformURL,
                                playedFraction: isCurrent ? playback.playedFraction : 0,
                                tint: isCurrent ? Bench.Palette.accent
                                                : Bench.Palette.textQuaternary)
                .frame(height: 44)
                .frame(maxWidth: .infinity)
            RatingStars(rating: song.rating, size: 13) { rating in
                var updated = song
                updated.rating = rating
                library.update(updated)
            }
        }
        .padding(16)
        .benchCard()
    }
}

// MARK: - Generation well

/// How far across the render card's well the playhead sits.
///
/// Deliberately *not* the job's overall fraction. That number spans the whole
/// pipeline, and each adapter maps its stages into it however it likes — the
/// llama.cpp ACE-Step runtime gives the denoising loop 0.55…0.95 — so a well
/// driven by it was already two thirds full before the model had denoised a
/// single step, then crawled the last third while the vocoder ran. The well
/// draws the take being *made*, so it runs on the one stage that makes it:
/// still and empty through prompt encode and LM reasoning, sweeping across
/// the generating stage, full while the vocoder and master finish up.
enum RenderWell {
    /// The pipeline ids that produce audio, best first. Order decides the two
    /// families that declare both (MiniMax, MLX Audio): the LM writes codes,
    /// the diffusion writes the audio those codes describe, so where there is
    /// a diffusion stage that is the one the well follows.
    static let generativeStageIds = ["diffusion", "lm_decode"]

    static func generativeIndex(in stages: [PipelineStage]) -> Int? {
        for id in generativeStageIds {
            if let index = stages.firstIndex(where: { $0.id == id }) { return index }
        }
        return nil
    }

    /// 0…1 across the well.
    static func edge(stages: [PipelineStage]?, phase: String?,
                     step: Int?, steps: Int?, fraction: Double?) -> Double {
        guard let stages, !stages.isEmpty,
              let generative = generativeIndex(in: stages) else {
            // No declared pipeline (yue scraping a log, the task-only
            // families): there is no stage to single out, so the well keeps
            // the one number the job has, exactly as it did before.
            return (fraction ?? 0).clamped(to: 0...1)
        }
        // No phase yet — the engine is still loading weights — or one this
        // build's catalog does not name. Either way the model has generated
        // nothing, and an empty well is the truth.
        guard let phase,
              let index = stages.firstIndex(where: { $0.id == phase }) else { return 0 }
        if index < generative { return 0 }
        if index > generative { return 1 }
        if let step, let steps, steps > 0 {
            return (Double(step) / Double(steps)).clamped(to: 0...1)
        }
        // Generating, but this adapter counts nothing (ACE-Step's torch
        // runtime, MiniMax). The stage's own progress is genuinely unknown, so
        // the job fraction drives the well rather than freezing it at zero —
        // the same approximation the pipeline strip's bar falls back to.
        return (fraction ?? 0).clamped(to: 0...1)
    }
}

/// The tall well at the top of the render card: the audio the model has
/// genuinely made so far, cut off at a playhead that tracks the generating
/// stage.
///
/// The waveform is real — `job.preview` is a wav the engine decoded from the
/// state the model is actually in, never an interpolation of the finished
/// take. It is drawn at the width the preview covers of the take, which keeps
/// both shapes of preview honest: a diffusion model's frame covers the whole
/// clip from the first step (it gets cleaner, not longer) while MusicGen's
/// grows a bar at a time. Nothing is drawn to the right of the playhead —
/// there is no ghost of audio that does not exist yet. A take that was not
/// asked to preview, or cannot, gets the plain filled region: a span of work
/// done, drawn as such rather than as an invented envelope.
private struct GenerationWell: View {
    let job: JobsStore.ActiveJob
    let stages: [PipelineStage]?

    /// Held for the reason `RenderPipelineView` holds it: the supervisor's own
    /// terminal event (`stage: "encoding"`) carries no phase, and recomputing
    /// from a nil phase would snap the playhead back to the left for the frame
    /// or two before the job ends.
    @State private var lastPhase: String?

    private var edge: Double {
        RenderWell.edge(stages: stages,
                        phase: job.progress?.phase ?? lastPhase,
                        step: job.progress?.step,
                        steps: job.progress?.steps,
                        fraction: job.progress?.fraction)
    }

    var body: some View {
        GeometryReader { geo in
            let x = geo.size.width * edge
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 10).fill(Bench.Palette.well)
                if let preview = job.preview {
                    PreviewWaveform(url: preview.fileURL)
                        .frame(width: geo.size.width * previewSpan(preview))
                        .padding(.vertical, 14)
                        .mask(alignment: .leading) { Rectangle().frame(width: x) }
                } else {
                    Rectangle()
                        .fill(Bench.Palette.accent.opacity(0.07))
                        .frame(width: x)
                }
                if edge > 0 {
                    Rectangle()
                        .fill(Bench.Palette.accent)
                        .frame(width: 1.5)
                        .shadow(color: Bench.Palette.accent.opacity(0.6), radius: 7)
                        .offset(x: x)
                }
                Text(label)
                    .font(Bench.Typo.mono(10, .semibold))
                    .tracking(1)
                    .foregroundStyle(edge > 0 ? Bench.Palette.accent
                                              : Bench.Palette.textFaintest)
                    .padding(.leading, 12)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 10)
                    .offset(x: min(x, max(geo.size.width - 150, 0)))
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            // Progress events land about once a second and steps are discrete,
            // so without this the playhead jumps rather than sweeps.
            .animation(.easeInOut(duration: 0.3), value: edge)
        }
        .frame(height: 132)
        .onChange(of: job.progress?.phase) {
            if let phase = job.progress?.phase { lastPhase = phase }
        }
    }

    /// How much of the well the decoded audio covers. A job with no declared
    /// duration (nothing to divide by) gets the whole width, because the
    /// preview is all there is to say about its length.
    private func previewSpan(_ preview: JobPreview) -> Double {
        guard let duration = job.info.durationS, duration > 0 else { return 1 }
        return min(1, preview.durationS / duration)
    }

    private var label: String {
        if let message = job.progress?.message, !message.isEmpty {
            return message.uppercased()
        }
        guard let duration = job.info.durationS,
              let fraction = job.progress?.fraction, fraction > 0 else {
            return job.status == .queued ? "QUEUED" : "WORKING"
        }
        return "\(Int((duration * fraction).rounded())) S OF \(Int(duration.rounded())) S"
    }
}

// MARK: - Preview waveform

/// The partial take, redrawn whenever a new frame lands.
///
/// Peaks are extracted without the on-disk cache the library rows use: a
/// preview file is superseded seconds after it is written, so caching would
/// leave one stale `.peaks` file behind per frame. Nothing is drawn until the
/// file has actually been read — a placeholder waveform for audio nobody has
/// looked at yet is exactly the sort of stand-in previews exist to remove.
private struct PreviewWaveform: View {
    let url: URL

    @State private var peaks: WaveformExtractor.Peaks?

    var body: some View {
        BenchWaveform(peaks: peaks, playedFraction: 1,
                      tint: Bench.Palette.accent,
                      rest: Bench.Palette.accent.opacity(0.2))
            .opacity(peaks == nil ? 0 : 1)
            .task(id: url) {
                peaks = try? await WaveformExtractor.shared.peaks(for: url)
            }
    }
}

// MARK: - Pipeline

/// The five-stage strip: done / active / pending.
///
/// The stage list comes from the model's declared `capabilities.pipeline`, so
/// the whole pipeline can be drawn greyed out *before* the job reaches any of
/// it — a progress event alone could never do that. A model that declares no
/// pipeline gets one honest bar instead of five invented ones.
struct RenderPipelineView: View {
    let stages: [PipelineStage]?
    let progress: JobProgress?
    let status: JobStatus

    /// How much wider the running stage's column is than a waiting one. Taken
    /// from the design, where the step-counting stage is about a third wider
    /// than its neighbours — enough for `· step 6 of 8` without turning the
    /// rest of the pipeline into punctuation.
    private static let activeStageShare: CGFloat = 1.35

    /// The supervisor's own terminal event (`stage: "encoding", fraction: 1.0`)
    /// carries no phase, because at that point it does not know the model's
    /// pipeline ids. Recomputing from a nil phase would flip every stage back
    /// to pending — the whole row resetting to empty circles for the frame or
    /// two before `job.completed` lands. So the last phase the adapter named
    /// is held until the job actually ends.
    @State private var lastPhase: String?

    private var activeIndex: Int? {
        guard let stages else { return nil }
        guard let phase = progress?.phase ?? lastPhase else { return nil }
        return stages.firstIndex { $0.id == phase }
    }

    var body: some View {
        content
            .onChange(of: progress?.phase) {
                if let phase = progress?.phase { lastPhase = phase }
            }
    }

    @ViewBuilder
    private var content: some View {
        if let stages, !stages.isEmpty {
            // Every stage holds its own column for the whole render: the strip
            // exists to say what the model *will* do, and a pipeline that
            // shrank to one running stage and a row of anonymous circles says
            // nothing. The running stage gets a slightly wider share — it is
            // the one carrying a step count worth reading — but a share, not
            // the row.
            WeightedRowLayout(weights: stages.indices.map {
                $0 == activeIndex ? Self.activeStageShare : 1
            }, spacing: 10) {
                ForEach(Array(stages.enumerated()), id: \.element.id) { index, stage in
                    stageColumn(stage, index: index)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: activeIndex)
        } else {
            VStack(alignment: .leading, spacing: 7) {
                Text(progress?.message ?? "Working…")
                    .font(Bench.Typo.caption)
                    .foregroundStyle(Bench.Palette.textQuaternary)
                if let fraction = progress?.fraction {
                    BenchProgressBar(fraction: fraction, height: 2)
                } else {
                    BenchProgressBar(fraction: 0, height: 2, tint: .clear,
                                     track: Color.white.opacity(0.1))
                }
            }
        }
    }

    private func stageColumn(_ stage: PipelineStage, index: Int) -> some View {
        let state = state(at: index)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                switch state {
                case .done:
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Bench.Palette.ok)
                        .frame(width: 15, height: 15)
                        .background(Circle().fill(Bench.Palette.ok.opacity(0.16)))
                case .active:
                    BenchSpinner(size: 15)
                case .pending:
                    Circle()
                        .strokeBorder(Color.white.opacity(0.16), lineWidth: 1.5)
                        .frame(width: 15, height: 15)
                }
                // In a narrow window the step count is what has to give, not
                // the stage's name: `Diffusi… step 4 o…` names nothing. The
                // count is still on the render card's own line above.
                ViewThatFits(in: .horizontal) {
                    Text(label(stage, index: index)).lineLimit(1)
                    Text(stage.label).lineLimit(1)
                }
                .font(Bench.Typo.caption)
                .fontWeight(state == .active ? .semibold : .regular)
                .foregroundStyle(state == .active ? Bench.Palette.accent
                                 : state == .done ? Bench.Palette.textQuaternary
                                 : Bench.Palette.textFaintest)
            }
            Rectangle()
                .fill(state == .done ? Bench.Palette.ok : Color.white.opacity(0.08))
                .frame(height: 2)
                .overlay(alignment: .leading) {
                    if state == .active {
                        GeometryReader { geo in
                            Rectangle()
                                .fill(Bench.Palette.accent)
                                .frame(width: geo.size.width * stageFraction)
                        }
                    }
                }
                .clipShape(Capsule())
        }
        .opacity(stage.optional == true && state == .pending ? 0.55 : 1)
    }

    private enum StageState { case done, active, pending }

    private func state(at index: Int) -> StageState {
        if status.isTerminal { return .done }
        guard let activeIndex else { return .pending }
        if index < activeIndex { return .done }
        return index == activeIndex ? .active : .pending
    }

    /// `Diffusion · step 6 of 8` — only when the adapter genuinely counts
    /// steps. A phase reported without them keeps its plain name.
    private func label(_ stage: PipelineStage, index: Int) -> String {
        guard index == activeIndex, let step = progress?.step,
              let steps = progress?.steps, steps > 0 else { return stage.label }
        return "\(stage.label) · step \(step) of \(steps)"
    }

    private var stageFraction: Double {
        if let step = progress?.step, let steps = progress?.steps, steps > 0 {
            return Double(step) / Double(steps)
        }
        return progress?.fraction ?? 0
    }
}

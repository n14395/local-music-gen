import AppKit
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
    let telemetry: TelemetryStore
    let timings: RenderTimingStore
    let notifications: NotificationService
    let renderingJobs: [JobsStore.ActiveJob]

    /// Wall-clock stamps for the take on screen. Held here rather than in the
    /// pane below because it has to survive that pane being rebuilt on every
    /// progress event — which is roughly once a second.
    @State private var timing = RenderStageTiming()

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
        return VStack(alignment: .leading, spacing: 18) {
            header(job, model: model)
            RenderSplitPane(
                job: job, stages: model?.capabilities.pipeline,
                timing: timing, timings: timings, telemetry: telemetry,
                modelId: job.info.modelId,
                estimateS: ActionEstimate.generativeSeconds(
                    model: model, durationS: job.info.durationS ?? 0))
            actionRow(job)
            notifyDeniedNote(job)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .benchCard(stroke: Bench.Palette.accent.opacity(0.22),
                   radius: Bench.Metrics.Radius.cardLarge)
        .shadow(color: Bench.Palette.accent.opacity(0.18), radius: 30, y: 8)
        // The stamps are taken where the phase changes rather than inside the
        // pane, so one measurement serves both panes and the footer's drift.
        .onChange(of: job.progress?.phase) {
            timing.observe(phase: job.progress?.phase, at: Date())
            timings.record(modelId: job.info.modelId, timing: timing)
        }
        // A new take reuses this card, and carrying take 1's stamps into take
        // 2 would report a stage as having started a minute before it did.
        .onChange(of: job.id) { timing = RenderStageTiming() }
        .onChange(of: job.progress?.take) { timing = RenderStageTiming() }
    }

    private func header(_ job: JobsStore.ActiveJob,
                        model: ModelInfo?) -> some View {
        let title = jobs.displayTitle(for: job.info)
        return HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                // "Take 2 of 4 · <prompt>" — the percentage beside it is the
                // average over every take, so without this the card never says
                // which one you are actually listening to. One line: a prompt
                // is arbitrary prose and the card has a fixed shape to keep.
                Text(job.takeLabel.map { "\($0) · \(title)" } ?? title)
                    .font(Bench.Typo.inspectorTitle)
                    .tracking(-0.15)
                    .foregroundStyle(Bench.Palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(heroMeta(job, model: model))
                    .font(Bench.Typo.mono(11))
                    .foregroundStyle(Bench.Palette.textMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 4) {
                if let fraction = job.progress?.fraction {
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
            .fixedSize()
        }
    }

    /// Copy the log · arm a notification · cancel.
    ///
    /// Cancel keeps the right edge on its own, away from the two that are
    /// safe to press. The other two are the render card admitting that a long
    /// render is something you leave: one hands the engine's own words to a
    /// bug report, the other means you do not have to keep watching.
    private func actionRow(_ job: JobsStore.ActiveJob) -> some View {
        HStack(spacing: 10) {
            Button("Copy log") { copyLog(job) }
                .buttonStyle(.bench(.quiet))
                .disabled(job.log.isEmpty)
                .opacity(job.log.isEmpty ? 0.45 : 1)
                .help(job.log.isEmpty
                      ? "This model has printed nothing yet"
                      : "Copy the engine output for this take")
            Button(armed(job) ? "Notifying when it lands"
                              : "Notify me when it lands") {
                let arming = !armed(job)
                jobs.setNotifyOnLanding(job.id, arming)
                // Asked here rather than at launch: pressing this button is
                // the one moment the request explains itself, and macOS only
                // ever shows the prompt once.
                if arming { Task { await notifications.request() } }
            }
            .buttonStyle(.bench(armed(job) ? .accent : .quiet))
            .help("Post a notification when this take finishes, even if the "
                  + "app is in front of you")
            Spacer(minLength: 8)
            Button("Cancel take") {
                Task { await jobs.cancel(job.id) }
            }
            .buttonStyle(.bench(.destructive))
        }
    }

    private func armed(_ job: JobsStore.ActiveJob) -> Bool {
        jobs.notifyOnLanding.contains(job.id)
    }

    /// Said only once the user has armed something, because until then it is
    /// not their problem. A button that claims it will notify you while the
    /// system has notifications switched off is the exact failure this whole
    /// change is about — so when that is the situation, the row says so and
    /// offers the one place it can be fixed.
    @ViewBuilder
    private func notifyDeniedNote(_ job: JobsStore.ActiveJob) -> some View {
        if armed(job), notifications.isDenied {
            HStack(spacing: 6) {
                Image(systemName: "bell.slash")
                    .font(.system(size: 10))
                Text("Notifications are turned off for LocalMusic, so this "
                     + "take will land quietly.")
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Settings") { notifications.openSystemSettings() }
                    .buttonStyle(.bench(.quiet))
                    .controlSize(.small)
            }
            .font(Bench.Typo.caption)
            .foregroundStyle(Bench.Palette.warn)
        }
    }

    /// `7` · `7.5` — a parameter value in the meta line, without the trailing
    /// zero that makes a whole number look like a measurement.
    static func numeric(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value))
                                 : String(format: "%.1f", value)
    }

    /// Everything the engine has said about this take, timestamped as the app
    /// heard it — the shape you would want pasted into a bug report.
    private func copyLog(_ job: JobsStore.ActiveJob) {
        let text = job.log
            .map { EngineLogPane.clockText($0.at) + "  " + $0.text }
            .joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func heroMeta(_ job: JobsStore.ActiveJob, model: ModelInfo?) -> String {
        var parts = [(model?.displayName ?? job.info.modelId).uppercased()]
        if let duration = job.info.durationS {
            parts.append("\(Int(duration.rounded())) S")
        }
        if let seed = job.info.params["seed"]?.doubleValue, seed > 0 {
            parts.append("SEED \(Int(seed).formatted(.number.grouping(.automatic)))")
        }
        // The one sampling knob worth repeating here: it is the value most
        // often changed between takes of the same prompt, so a card that
        // omitted it could not tell two of them apart.
        if let guidance = job.info.params["guidance_scale"]?.doubleValue,
           guidance > 0 {
            parts.append("GUIDANCE " + Self.numeric(guidance))
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

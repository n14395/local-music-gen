import AppKit
import SwiftUI

/// A screen while something it started is rendering.
///
/// The complaint this answers is "no sense of progress". So: the take being
/// made gets the whole top of the screen with a percentage you can read from
/// across the room, the pipeline says which stage is running rather than
/// hiding it in a message string, and finished takes stay playable underneath.
///
/// Grown in Generate, now shared: Style Transfer and the Workbench hand it
/// their own `renderingJobs` and get the identical treatment, which is the
/// point — a render looks like a render whichever workspace asked for it.
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
    let telemetry: TelemetryStore
    let timings: RenderTimingStore
    let notifications: NotificationService
    let renderingJobs: [JobsStore.ActiveJob]
    /// Which library rows count as "this run's" under DONE. Generate makes
    /// `.generated` tracks; a Workbench mix lands as `.recombined`; empty
    /// hides the section for a host that lists results its own way.
    var doneOrigins: Set<SongOrigin> = [.generated]
    /// Drawn in the hero's place when there is momentarily no job to show —
    /// a chain between steps, a submit in flight. Without it the pane would
    /// blink back to the workspace and forward again at every seam.
    var waitingLine: String?

    /// Wall-clock stamps for the take on screen. Held here rather than in the
    /// pane below because it has to survive that pane being rebuilt on every
    /// progress event — which is roughly once a second.
    @State private var timing = RenderStageTiming()

    private var lead: JobsStore.ActiveJob? { renderingJobs.first }

    /// Takes that finished while this batch was running, newest first — from
    /// this pane's own origins only, since a file imported half an hour ago
    /// did not come out of this run and reading as though it had would
    /// misreport the batch.
    private var doneRecently: [SongRecord] {
        library.recent.filter {
            doneOrigins.contains($0.originKind)
                && Date().timeIntervalSince($0.createdAt) < 1800
        }
        .prefix(3).map { $0 }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let lead {
                    heroCard(lead)
                } else if let waitingLine {
                    waitingCard(waitingLine)
                }
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

    /// The seam between two chain steps, drawn with the hero's own weight so
    /// the page does not collapse and re-grow around a one-second gap.
    private func waitingCard(_ line: String) -> some View {
        HStack(spacing: 14) {
            BenchSpinner(size: 24, lineWidth: 2.5)
            Text(line)
                .font(Bench.Typo.inspectorTitle)
                .tracking(-0.15)
                .foregroundStyle(Bench.Palette.textPrimary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .benchCard(stroke: Bench.Palette.accent.opacity(0.22),
                   radius: Bench.Metrics.Radius.cardLarge)
        .shadow(color: Bench.Palette.accent.opacity(0.18), radius: 30, y: 8)
    }

    private func heroCard(_ job: JobsStore.ActiveJob) -> some View {
        let model = catalog.model(id: job.info.modelId)
        return VStack(alignment: .leading, spacing: 18) {
            header(job, model: model)
            batchStrip(job)
            RenderSplitPane(
                job: job, log: jobs.log(for: job.id),
                stages: model?.capabilities.pipeline,
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
        let landing = landingTitle(job)
        return HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                // What this will be called when it lands, over what was
                // asked for. A prompt identifies a render *while* it runs,
                // but it is not what you go looking for afterwards — and the
                // name the take was about to take appeared nowhere on the
                // screen watching it being made.
                //
                // Drawn on every render that has a name, including the ones
                // whose title below says the same thing (a recombine is
                // identified by the name it lands under). The line is in the
                // same place on every screen for the same reason the sidebar's
                // engine card is: something you read at a glance has to be
                // where you last found it, and a label that comes and goes is
                // one you stop looking for.
                if let eyebrow = eyebrowLine(landing: landing) {
                    Text(eyebrow)
                        .eyebrow()
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
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

    /// `TRACK042B` — what the take on screen will be called when it lands.
    ///
    /// Which take it is stays off this line: the title under it already says
    /// "Take 2 of 4", and saying it twice, one line apart, only reads as two
    /// different facts that happen to agree.
    private func eyebrowLine(landing: String?) -> String? {
        guard let landing = landing?.uppercased(), !landing.isEmpty else {
            return nil
        }
        return landing
    }

    /// Every take of this submission, as one chip each: what is done, what is
    /// rendering now, what is still to come.
    ///
    /// The point of the strip is the sentence the user asked for — *these are
    /// takes of one prompt* — which the hero alone cannot make, since it shows
    /// whichever take the engine happens to be on. Drawn from the batch's
    /// sibling jobs (contract §5.1), and from the take count where a sibling
    /// has already been dismissed off the queue.
    @ViewBuilder
    private func batchStrip(_ job: JobsStore.ActiveJob) -> some View {
        let takes = job.info.takesInBatch
        if takes > 1 {
            let siblings = jobs.batch(job.info.groupId)
            HStack(spacing: 7) {
                Text("TAKES OF THIS PROMPT").eyebrow()
                ForEach(Array(0..<takes), id: \.self) { index in
                    let sibling = siblings.first {
                        $0.info.takeIndexInBatch == index
                    }
                    takeChip(index: index, take: sibling,
                             isCurrent: sibling?.id == job.id)
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// One take's chip: its letter, in the colour of what became of it. The
    /// letter rather than a number because it is the letter the track lands
    /// under — `track042c` is on the chip and in the library.
    private func takeChip(index: Int, take: JobsStore.ActiveJob?,
                          isCurrent: Bool) -> some View {
        let tint: Color = switch take?.status {
        case .succeeded: Bench.Palette.ok
        case .failed: Bench.Palette.danger
        case .canceled: Bench.Palette.textMuted
        case .loading, .generating, .encoding: Bench.Palette.accent
        // Queued, or a take whose row has been dismissed: neither is a
        // colour, and pretending otherwise would report an outcome.
        case .queued, nil: Bench.Palette.textFaintest
        }
        return Text(SongRecord.takeSuffix(index))
            .font(Bench.Typo.mono(10, .semibold))
            .foregroundStyle(tint)
            .frame(width: 17, height: 17)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(tint.opacity(isCurrent ? 0.18 : 0.08)))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(tint.opacity(isCurrent ? 0.7 : 0.25),
                                  lineWidth: 1))
            .help(chipHelp(index: index, take: take))
    }

    private func chipHelp(index: Int, take: JobsStore.ActiveJob?) -> String {
        let name = "Take \(index + 1)"
        return switch take?.status {
        case .succeeded: "\(name) — done, in the Library"
        case .failed: "\(name) — failed"
        case .canceled: "\(name) — canceled"
        case .loading, .generating, .encoding: "\(name) — rendering now"
        case .queued: "\(name) — waiting its turn"
        case nil: "\(name) — no longer in the queue"
        }
    }

    /// The title the take on screen will land under.
    ///
    /// Known outright wherever the submission carried a name; predicted from
    /// the library's own next `trackNNN` for a Studio take that left the Name
    /// field alone — the same string that field was showing as its
    /// placeholder when the user pressed Generate. A prediction can be
    /// overtaken (three jobs queued ahead of this one land first, or the name
    /// is taken while this renders, and ingest makes it unique), which is why
    /// it is drawn as a label over the render and not as a promise.
    private func landingTitle(_ job: JobsStore.ActiveJob) -> String? {
        let base = jobs.landingBaseTitle(for: job.id)
            ?? (job.info.isGenerate ? library.nextTrackName : nil)
        guard let base, !base.isEmpty else { return nil }
        let takes = job.info.takesInBatch
        guard takes > 1 else { return base }
        // A batch shares one base and separates on the letter, so the card
        // has to name *this* take: track042b, not the base it came from.
        // Which take that is comes off the job itself now that a batch is one
        // job per take; `progress.take` is the fallback for a job carrying a
        // whole batch, where it is the only thing that knows.
        let names = SongRecord.takeNames(base: base, count: takes)
        let index = job.info.takeOf == nil
            ? (job.progress?.take ?? 0) : job.info.takeIndexInBatch
        return names.indices.contains(index) ? names[index] : names.first
    }

    /// Copy the log · arm a notification · cancel.
    ///
    /// Cancel keeps the right edge on its own, away from the two that are
    /// safe to press. The other two are the render card admitting that a long
    /// render is something you leave: one hands the engine's own words to a
    /// bug report, the other means you do not have to keep watching.
    private func actionRow(_ job: JobsStore.ActiveJob) -> some View {
        HStack(spacing: 10) {
            // `hasLines`, not `lines.isEmpty`: this row sits beside the log
            // pane and reading the lines would redraw the buttons on every
            // one of them. The box flips this once, when the first line
            // arrives, which is all the button needs to know.
            let printed = jobs.log(for: job.id).hasLines
            Button("Copy log") { copyLog(job) }
                .buttonStyle(.bench(.quiet))
                .disabled(!printed)
                .opacity(printed ? 1 : 0.45)
                .help(printed
                      ? "Copy the engine output for this take"
                      : "This model has printed nothing yet")
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
            let canceling = jobs.isCanceling(job.id)
            Button(canceling ? "Canceling…" : "Cancel take") {
                Task { await jobs.cancel(job.id) }
            }
            .buttonStyle(.bench(.destructive))
            // Disabled rather than merely relabelled: the second press had
            // nothing to do, and a button that stays live through a wait it
            // cannot shorten invites one.
            .disabled(canceling)
            .opacity(canceling ? 0.6 : 1)
            .help(canceling
                  ? "Asked the engine to stop — some models only stop at the "
                    + "end of a step, and the take is dropped either way"
                  : "Stop this take")
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
        let text = jobs.log(for: job.id).lines
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
                load(song)
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
                                                : Bench.Palette.textQuaternary,
                                // Every other waveform in the app seeks on
                                // click; these did not, so the one place you
                                // are looking at a take you just made was the
                                // one place you could not jump into it.
                                onSeek: { fraction in
                                    if !isCurrent { load(song) }
                                    playback.seek(to: fraction * song.durationS)
                                })
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

    /// Make this take the transport's current item. Shared by the play
    /// button and the waveform, so a click into a take that is not loaded
    /// yet lands on the same subtitle the play button would have given it.
    private func load(_ song: SongRecord) {
        playback.play(url: song.fileURL, songId: song.id, title: song.title,
                      duration: song.durationS,
                      subtitle: "\(song.modelName) · "
                                + "\(Int(song.durationS.rounded())) s")
    }
}

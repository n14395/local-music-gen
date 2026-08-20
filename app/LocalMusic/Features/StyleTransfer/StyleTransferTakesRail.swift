import SwiftUI

/// The inspector beside the workspace: what this configuration has produced,
/// and a one-key comparison against the source.
///
/// A/B is the reason the rail exists. Judging a restyle means hearing the same
/// bar of the original and the result back to back — and every other way the
/// app offers to do that costs a trip to the Library and loses your place in
/// both files. Here the switch keeps the playhead.
struct StyleTransferTakesRail: View {
    let model: StyleTransferModel
    let playback: PlaybackController
    var lastRun: ActionRunLog.Entry?
    var onReplay: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if model.takes.isEmpty && model.chain == nil {
                empty
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if let chain = model.chain { chainCard(chain) }
                        ForEach(model.takes) { take in
                            takeCard(take)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
            }
            Spacer(minLength: 0)
            if let lastRun { lastRunFooter(lastRun) }
        }
    }

    // MARK: - Header

    private var header: some View {
        BenchPanelHeader {
            HStack(spacing: 8) {
                Text("Takes").font(Bench.Typo.sectionTitle)
                    .foregroundStyle(Bench.Palette.textPrimary)
                if !model.takes.isEmpty {
                    BenchBadge("\(model.takes.count)")
                }
                Spacer(minLength: 0)
                if model.comparingTakeId != nil {
                    Button("Stop A/B") { model.comparingTakeId = nil }
                        .buttonStyle(.bench(.quiet))
                }
            }
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Nothing yet")
                .font(Bench.Typo.bodyEmphasis)
                .foregroundStyle(Bench.Palette.textSecondary)
            Text("Results appear here as they finish, so you can hear them "
                 + "against the original without leaving the controls that "
                 + "made them.")
                .font(Bench.Typo.secondary)
                .foregroundStyle(Bench.Palette.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }

    // MARK: - Chain progress

    private func chainCard(_ chain: StyleTransferModel.ChainRun) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if !chain.progress.isFailed && !chain.isFinished {
                    BenchSpinner(size: 12)
                }
                Text(chain.plan.statusLine(chain.progress))
                    .font(Bench.Typo.secondaryEmphasis)
                    .foregroundStyle(chain.progress.isFailed
                                     ? Bench.Palette.dangerText
                                     : Bench.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            BenchProgressBar(
                fraction: chain.plan.steps.isEmpty ? 0
                    : Double(chain.progress.stepIndex)
                        / Double(chain.plan.steps.count))
            if chain.progress.isFailed {
                // Partials are left in the Library on purpose: a chain that
                // stopped after the split still produced stems worth having.
                Text("Anything it finished is already in the Library.")
                    .font(Bench.Typo.micro)
                    .foregroundStyle(Bench.Palette.textFaint)
            }
            // Dismissable once it has stopped for any reason — a finished chain
            // that could only be cleared by failing would sit at 100 % forever.
            if chain.progress.isFailed || chain.isFinished {
                Button("Dismiss") { model.dismissChain() }
                    .buttonStyle(.bench(.quiet))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .benchCard()
    }

    // MARK: - Takes

    private func takeCard(_ take: StyleTransferModel.Take) -> some View {
        let isComparing = model.comparingTakeId == take.id
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                BenchPlayButton(
                    isPlaying: playback.isPlaying
                        && playback.currentSongId == take.id,
                    isCurrent: playback.currentSongId == take.id,
                    size: 24) {
                        play(take)
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(take.title)
                        .font(Bench.Typo.bodyEmphasis)
                        .foregroundStyle(take.isDiscarded
                                         ? Bench.Palette.textFaint
                                         : Bench.Palette.textPrimary)
                        .strikethrough(take.isDiscarded)
                        .lineLimit(1)
                    Text(metaLine(take)).metaLine()
                }
                Spacer(minLength: 0)
                if take.isPart { BenchBadge("PART", tone: .cyan) }
            }
            HStack(spacing: 8) {
                RatingStars(rating: take.rating) { rating in
                    model.rate(takeId: take.id, rating: rating)
                }
                Spacer(minLength: 0)
                if model.source != nil {
                    Button(isComparing ? "A/B ON" : "A/B") {
                        toggleCompare(take)
                    }
                    .buttonStyle(.bench(isComparing ? .accent : .quiet))
                }
                Button(take.isDiscarded ? "Restore" : "Discard") {
                    model.toggleDiscarded(takeId: take.id)
                }
                .buttonStyle(.bench(.quiet))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .benchCard(fill: isComparing ? Bench.Palette.cardSelected
                                     : Bench.Palette.card)
    }

    private func metaLine(_ take: StyleTransferModel.Take) -> String {
        ActionFormat.join([
            take.modeTitle.uppercased(),
            take.modelName.uppercased(),
            take.styleAmount.map { String(format: "%.0f%% STYLE", $0 * 100) },
            take.durationS.map(ActionFormat.length),
            ActionFormat.ago(take.createdAt),
        ])
    }

    // MARK: - Playback

    private func play(_ take: StyleTransferModel.Take) {
        playback.play(url: take.fileURL, songId: take.id, title: take.title,
                      duration: take.durationS ?? 0,
                      subtitle: take.modeTitle.uppercased())
    }

    /// Switch between the source and the take **at the same position**.
    ///
    /// `PlaybackController.play` treats a repeat of the *current* song id as a
    /// play/pause toggle rather than as a load — so calling it for something
    /// already loaded pauses the comparison instead of making it. Both sides
    /// are checked before deciding, and the position is read first because
    /// loading a new item resets the clock.
    private func toggleCompare(_ take: StyleTransferModel.Take) {
        guard let source = model.source else { return }
        let position = playback.currentTime
        let wasPlaying = playback.isPlaying

        let wantsSource = model.comparingTakeId != take.id
        model.comparingTakeId = wantsSource ? take.id : nil
        let targetId = wantsSource ? source.id : take.id

        if playback.currentSongId == targetId {
            // Already the loaded item: nothing to swap, only somewhere to be.
            if !playback.isPlaying { playback.toggle() }
        } else if wantsSource {
            playback.play(url: source.fileURL, songId: source.id,
                          title: source.sourceTitle,
                          duration: source.durationS ?? 0,
                          subtitle: "ORIGINAL")
        } else {
            playback.play(url: take.fileURL, songId: take.id,
                          title: take.title, duration: take.durationS ?? 0,
                          subtitle: take.modeTitle.uppercased())
        }
        playback.seek(to: position)
        // A/B on a paused comparison stays paused: the point is to hear the
        // same bar twice, and starting playback under someone who deliberately
        // stopped it is not that.
        if !wasPlaying && playback.isPlaying { playback.toggle() }
    }

    // MARK: - Last run

    private func lastRunFooter(_ entry: ActionRunLog.Entry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("LAST RUN OF THIS PRESET").eyebrow()
            Text(entry.summary)
                .font(Bench.Typo.secondary)
                .foregroundStyle(Bench.Palette.textSecondary)
                .lineLimit(1)
            HStack(spacing: 8) {
                Text(ActionFormat.join([entry.detail,
                                        ActionFormat.ago(entry.at)]))
                    .metaLine()
                Spacer(minLength: 0)
                // Locked with everything else while a chain runs: this
                // swaps the source, which would leave the remaining steps
                // mixing parts of a song nobody is looking at.
                if let onReplay {
                    Button("Set up again") { onReplay() }
                        .buttonStyle(.bench(.quiet))
                        .disabled(model.isChainRunning)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) {
            Rectangle().fill(Bench.Palette.hairline).frame(height: 1)
        }
    }
}

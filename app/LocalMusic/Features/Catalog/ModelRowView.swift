import SwiftUI

/// One model card on the Models screen.
///
/// The card is the same rectangle in every state — installed, downloading,
/// paused, absent — because the design uses badges rather than layout to say
/// which state you are looking at. Only two things move: the stroke goes
/// accent while bytes are arriving, and the trailing control changes.
struct ModelRowView: View {
    let row: ModelListRow
    /// Live download, when the engine is currently fetching this model. Drives
    /// the row in preference to `installState`, which lags a paused/cancelled
    /// download by one catalog refresh.
    let download: DownloadInfo?
    /// Why the last attempt stopped, when it stopped badly. Outlives the
    /// download it came from — the whole point is that it is still on screen
    /// after the progress row has gone.
    var failure: DownloadsStore.DownloadFailure?
    /// Whether a Hugging Face token is in the Keychain, so a gated model can
    /// say `HF TOKEN ✓` instead of demanding one you already gave it.
    let hasHFToken: Bool
    let physicalMemory: Int64
    /// From the engine's `/v1/system`; nil on an engine that does not report
    /// it, in which case the disk warning is simply not drawn.
    let freeDiskBytes: Int64?
    let actionCount: Int
    let onDownload: () -> Void
    let onPause: (String) -> Void
    let onResume: (String) -> Void
    let onCancelDownload: (String) -> Void
    let onDelete: () -> Void
    let onInstallRuntime: () -> Void
    let onTogglePin: (Bool) -> Void
    var onDismissFailure: () -> Void = {}
    /// Hearted models sort to the top of Studio's picker. Unrelated to the
    /// Library's Favourites, which is for music and parts.
    var isFavourite: Bool = false
    var onToggleFavourite: () -> Void = {}
    /// Whether the properties rail is showing this model.
    var isInspected: Bool = false
    /// Clicking the row's body — not its buttons — opens the rail on it.
    var onInspect: (() -> Void)?

    private var model: ModelInfo { row.model }
    private var isInstalled: Bool { model.installState == .installed }
    /// Weights *and* runtime, which is what the card's green tick claims.
    private var readiness: ModelReadiness { ModelReadiness.of(model) }
    /// The accent-stroked card is "this one is coming down", and that has to
    /// agree with `stateBadge`, which also says DOWNLOADING from the catalog's
    /// own state before the first progress event arrives. Reading only
    /// `download` drew that badge and the STARTING spinner on a plain card.
    private var isDownloading: Bool {
        download != nil || model.installState == .downloading
    }

    /// Experimental models are dimmed to 72% so the eye skips them — but not
    /// while one is downloading, where the progress bar and the byte counter
    /// are the whole point of the row.
    private var isDimmed: Bool {
        model.requirements.speedTier == .experimental && !isDownloading
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                titleRow
                Text(model.description)
                    .font(Bench.Typo.secondary)
                    .foregroundStyle(Bench.Palette.textTertiary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                if let download {
                    DownloadProgressLine(download: download)
                }
                if download == nil, let failure {
                    DownloadFailureLine(failure: failure, model: model,
                                        onDismiss: onDismissFailure)
                }
                badgeRow
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            controls
        }
        .padding(.horizontal, 16).padding(.vertical, 15)
        .benchCard(fill: isDownloading || isInspected ? Bench.Palette.cardSelected
                                                     : Bench.Palette.card,
                   stroke: isInspected ? Bench.Palette.accent.opacity(0.45)
                       : isDownloading ? Bench.Palette.accent.opacity(0.24)
                                       : Bench.Palette.cardStroke)
        .opacity(isDimmed ? 0.72 : 1)
        .padding(.leading, row.isVariant ? 26 : 0)
        // The whole card is the target, but it goes on last and at low
        // priority so the Download, Pause and heart buttons inside it keep
        // their own taps — a row-level gesture added above them would eat
        // every click before they saw it.
        .contentShape(Rectangle())
        .onTapGesture { onInspect?() }
        .help(onInspect == nil ? "" : "Show this model's properties")
    }

    // MARK: - Title

    private var titleRow: some View {
        HStack(spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(model.displayName)
                    .font(row.isVariant ? .system(size: 13, weight: .medium)
                                        : .system(size: 14, weight: .semibold))
                    .foregroundStyle(Bench.Palette.textPrimary)
                    .lineLimit(1)
                if row.showsFormat, let format = model.format, !format.isEmpty {
                    Text(format.uppercased())
                        .font(Bench.Typo.mono(10))
                        .foregroundStyle(Bench.Palette.textMuted)
                        .lineLimit(1)
                }
            }
            if readiness == .ready { InstalledCheck() }
            if let state = stateBadge {
                BenchBadge(state.text, tone: state.tone, emphasised: true)
            }
            if model.isPinned {
                // The app's only "this is my main model" flag. It is about
                // memory residency, so it says so rather than "DEFAULT".
                BenchBadge("PINNED", tone: .accent, emphasised: true)
                    .help("Kept loaded in memory")
            }
            Spacer(minLength: 0)
            favouriteHeart
        }
    }

    /// Deliberately not the same idea as PINNED beside it: the pin is about
    /// memory residency and the engine enforces it, while this is only about
    /// the order Studio offers models in.
    private var favouriteHeart: some View {
        Button(action: onToggleFavourite) {
            Image(systemName: isFavourite ? "heart.fill" : "heart")
                .font(.system(size: 12))
                .foregroundStyle(isFavourite ? TrackRow.favouriteHeart
                                             : Bench.Palette.textFaint)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isFavourite ? "Remove from favourite models"
                          : "Show this model first in Generate's picker")
    }

    private var stateBadge: (text: String, tone: BenchBadge.Tone)? {
        switch download?.state {
        case .downloading: return ("DOWNLOADING", .accent)
        case .paused: return ("PAUSED", .warn)
        case .provisioning: return ("SETTING UP", .accent)
        // Downloads transfer one at a time (contract §4.2), so a queued one is
        // genuinely not moving. Neutral rather than accent: the accent tone is
        // this screen's "bytes are arriving now".
        case .queued: return ("WAITING", .neutral)
        case nil: break
        }
        if model.installState == .downloading { return ("DOWNLOADING", .accent) }
        // A failure the user has not dismissed outranks whatever the catalog
        // says the row is: "not installed" is the consequence, not the news.
        if let failure {
            return failure.needsAccess ? ("LICENCE NEEDED", .warn)
                                       : ("DOWNLOAD FAILED", .warn)
        }
        // Said on the card rather than only on the control: a model whose
        // runtime is missing looks installed from across the room, and the
        // first thing that would tell you otherwise is a four-minute pause in
        // the middle of a generation.
        switch readiness {
        // "NEEDED" rather than "MISSING": the same state covers a runtime that
        // was never built and one an app update has left behind, and both are
        // fixed by the same button.
        case .runtimeMissing: return ("RUNTIME NEEDED", .warn)
        case .runtimeInstalling: return ("SETTING UP", .accent)
        default: break
        }
        if model.requirements.speedTier == .experimental {
            return ("EXPERIMENTAL", .warn)
        }
        return nil
    }

    // MARK: - Badges

    /// Everything the catalog actually knows about this model. Shared with
    /// Studio, which shows the same model and has to say the same things about
    /// it — see `ModelBadges`.
    private var badgeRow: some View {
        FlowLayout(spacing: 6, rowSpacing: 6) {
            ForEach(ModelBadges.list(for: model, isVariant: row.isVariant,
                                     physicalMemory: physicalMemory,
                                     freeDiskBytes: freeDiskBytes,
                                     hasHFToken: hasHFToken,
                                     actionCount: actionCount)) { badge in
                BenchBadge(badge.text, tone: badge.tone)
            }
        }
    }

    // MARK: - Trailing controls

    @ViewBuilder
    private var controls: some View {
        if let download {
            HStack(spacing: 8) {
                if download.isRuntimeOnly {
                    // Nothing is transferring and nothing ever will be on this
                    // one, so a Pause that is documented to do nothing is not
                    // worth the width — a runtime install can only be let run
                    // or stopped.
                    EmptyView()
                } else if download.state == .paused {
                    Button("Resume") { onResume(download.id) }
                        .buttonStyle(BenchSecondaryButtonStyle(tone: .quiet,
                                                               padding: Self.buttonPadding))
                } else {
                    // Two states have no transfer to suspend, and the engine
                    // accepts pause over both and does nothing (contract §4.2).
                    // Dimmed and explained rather than removed, so the row does
                    // not reshuffle under the pointer when the bytes start.
                    let blocked = DownloadFormat.pauseBlockedReason(download.state)
                    Button("Pause") { onPause(download.id) }
                        .buttonStyle(BenchSecondaryButtonStyle(tone: .quiet,
                                                               padding: Self.buttonPadding))
                        .disabled(blocked != nil)
                        .opacity(blocked == nil ? 1 : 0.45)
                        .help(blocked ?? "")
                }
                Button("Cancel") { onCancelDownload(download.id) }
                    .buttonStyle(BenchSecondaryButtonStyle(tone: .destructive,
                                                           padding: Self.buttonPadding))
            }
            .fixedSize()
        } else {
            switch readiness {
            case .ready:
                stateMenu(label: "Downloaded")
            case .runtimeMissing:
                // The runtime is the other half of the install, so it gets the
                // primary button — and the state control beside it keeps
                // saying which half is actually here.
                HStack(spacing: 8) {
                    Button("Download runtime", action: onInstallRuntime)
                        .buttonStyle(BenchPrimaryButtonStyle(size: .compact,
                                                             glows: false))
                        .help("Install the \(model.family) runtime packages now, "
                              + "instead of during your first generation")
                    stateMenu(label: "Model downloaded")
                }
                .fixedSize()
            case .runtimeInstalling:
                // Another download is building this family's runtime; joining
                // it is the engine's job, not a second button's.
                HStack(spacing: 8) {
                    BenchSpinner(size: 13)
                    Text("SETTING UP RUNTIME")
                        .font(Bench.Typo.badge)
                        .foregroundStyle(Bench.Palette.textMuted)
                    stateMenu(label: "Model downloaded")
                }
                .fixedSize()
            case .starting:
                // The catalog says it is downloading but no progress event has
                // arrived for it, so there is no download id to pause or
                // cancel. Say what is true and offer nothing that would fail.
                HStack(spacing: 8) {
                    BenchSpinner(size: 13)
                    Text("STARTING")
                        .font(Bench.Typo.badge)
                        .foregroundStyle(Bench.Palette.textMuted)
                }
                .fixedSize()
            case .download, .resumeDownload:
                Button(readiness == .resumeDownload ? "Resume download" : "Download",
                       action: onDownload)
                    .buttonStyle(BenchPrimaryButtonStyle(size: .compact, glows: false))
                    .fixedSize()
            }
        }
    }

    /// The trailing control for a model whose weights are here: it names what
    /// the row has, and holds the two things you can do to it.
    private func stateMenu(label: String) -> some View {
        BenchMenu(label: label) {
            Toggle("Keep loaded in memory",
                   isOn: Binding(get: { model.isPinned },
                                 set: { onTogglePin($0) }))
            Divider()
            Button("Delete model files…", role: .destructive, action: onDelete)
        }
    }

    private static let buttonPadding = EdgeInsets(top: 8, leading: 13,
                                                  bottom: 8, trailing: 13)
}

// MARK: - Progress line

/// Why the last attempt stopped, said on the row it belongs to.
///
/// The engine already works out exactly what went wrong — a gated repo names
/// itself in the message — and until this view existed every word of that was
/// discarded, leaving a download that simply disappeared. A vanishing progress
/// bar reads as success, which is how a model that had fetched nothing but a
/// README came to look installed.
///
/// A gate is the one failure with somewhere to go: the token is fine, the
/// licence has not been accepted, and no amount of retrying changes that. So
/// that case gets a link to the page where it can be, and the others get the
/// message alone.
private struct DownloadFailureLine: View {
    let failure: DownloadsStore.DownloadFailure
    let model: ModelInfo
    let onDismiss: () -> Void

    /// The repo that needs accepting. Gated entries can ride alongside open
    /// ones, so it is the gated one that is linked, not simply the first.
    private var gatedRepo: String? {
        model.hfRepos.first { $0.gated }?.repoId ?? model.hfRepos.first?.repoId
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(failure.needsAccess ? "⚠" : "✕")
                .font(Bench.Typo.mono(11, .semibold))
                .foregroundStyle(Bench.Palette.warn)
            VStack(alignment: .leading, spacing: 5) {
                Text(message)
                    .font(Bench.Typo.small)
                    .foregroundStyle(Bench.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if failure.needsAccess, let gatedRepo,
                   let url = URL(string: "https://huggingface.co/" + gatedRepo) {
                    Link("Accept the licence on Hugging Face", destination: url)
                        .font(Bench.Typo.small)
                        .foregroundStyle(Bench.Palette.accent)
                }
            }
            Spacer(minLength: 8)
            Button("Dismiss", action: onDismiss)
                .buttonStyle(.bench(.quiet))
        }
        .padding(.horizontal, 11).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.control,
                                     style: .continuous)
            .fill(Bench.Palette.warn.opacity(0.09)))
        .overlay(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.control,
                                  style: .continuous)
            .strokeBorder(Bench.Palette.warn.opacity(0.30), lineWidth: 1))
    }

    /// The engine's own words, with the one thing it cannot know said first:
    /// having a token and having access to a particular repo are different
    /// questions, and the badge beside this says `HF TOKEN ✓` for both.
    private var message: String {
        guard failure.needsAccess else { return failure.message }
        return "This model is gated. Your Hugging Face token is not enough on "
            + "its own — the licence has to be accepted for this repository "
            + "before the weights can be fetched."
    }
}

/// `▓▓▓▓▓░░░░  18.1 / 53.4 GB · 12 MB/S · 48 MIN LEFT`
///
/// The rate is smoothed and the ETA derived here rather than in the store, so
/// the smoothing window belongs to the thing being looked at: the estimate
/// resets when the row appears instead of carrying a stale average across a
/// pause, a cancel and a fresh start.
private struct DownloadProgressLine: View {
    let download: DownloadInfo
    @State private var rate = DownloadRate()

    private var fraction: Double {
        guard download.bytesTotal > 0 else { return 0 }
        return Double(download.bytesDone) / Double(download.bytesTotal)
    }

    var body: some View {
        HStack(spacing: 11) {
            if download.state == .provisioning {
                BenchSpinner(size: 13)
                Text((download.message ?? "Setting up the runtime…").uppercased())
                    .font(Bench.Typo.mono(11, .semibold))
                    .foregroundStyle(Bench.Palette.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            } else {
                // The bar is flexible and the stats are not, so on a narrow
                // card the bar was the thing that vanished. Side by side only
                // while the bar keeps a readable width; below that it takes a
                // full line of its own with the stats underneath.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 11) {
                        bar.frame(minWidth: 120)
                        lineText.fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 7) {
                        bar
                        lineText.lineLimit(1)
                    }
                }
            }
        }
        .onAppear { rate.ingest(download.speedBps) }
        // The sampled quantity is the speed, so that is what is fed to the
        // smoother — one ingest per engine sample, no double counting.
        .onChange(of: download.speedBps) { _, sample in rate.ingest(sample) }
    }

    private var bar: some View {
        let moving = download.state == .downloading
        return BenchProgressBar(fraction: fraction, height: 5,
                                tint: moving ? Bench.Palette.accent
                                             : Bench.Palette.textMuted,
                                track: Bench.Palette.windowStroke)
    }

    private var lineText: some View {
        Text(line)
            .font(Bench.Typo.mono(11, .semibold))
            .foregroundStyle(Bench.Palette.textSecondary)
    }

    private var line: String {
        DownloadFormat.transferLine(download, rate: rate)
    }
}

// MARK: - Pieces

/// The green tick beside an installed model: a 15 pt disc of `ok` at 16% with
/// the glyph on top, as drawn.
private struct InstalledCheck: View {
    var body: some View {
        ZStack {
            Circle().fill(Bench.Palette.ok.opacity(0.16))
            Image(systemName: "checkmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Bench.Palette.ok)
        }
        .frame(width: 15, height: 15)
        .help("Downloaded — model files and runtime both here")
    }
}


// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

// MARK: - What the card says

/// The one download the sidebar reports, chosen out of everything in flight.
///
/// Transfers run one at a time (contract §4.2), so there is usually exactly
/// one download worth a card and a queue of others waiting behind it. "Usually"
/// is why this picks rather than assumes: a download that has moved on to
/// provisioning has given its transfer slot back, so the next one can be
/// pulling bytes while the first is still building its runtime.
///
/// Pure and value-typed, for the reason the rest of `CatalogFormatting` is:
/// every decision here is about which of several true things to say, and that
/// is a unit test's job rather than a screenshot's.
struct SidebarDownload: Equatable {
    let info: DownloadInfo
    /// The model's name as the catalogue writes it, falling back to the id — a
    /// download outlives a catalogue that has not refreshed yet, and an id is
    /// still an answer to "what is this".
    let title: String
    /// How many other transfers are in flight behind this one.
    let others: Int

    /// Ranked by what is actually happening, so the card follows the machine
    /// rather than whichever id sorts first: transferring beats installing
    /// beats suspended beats waiting. Ties break on the id, because progress
    /// events arrive twice a second and a card that swapped between two equals
    /// on every one of them would be unreadable.
    static func make(downloads: [DownloadInfo],
                     models: [ModelInfo]) -> SidebarDownload? {
        guard let featured = downloads.min(by: {
            (rank($0.state), $0.downloadId) < (rank($1.state), $1.downloadId)
        }) else { return nil }
        let name = models.first { $0.id == featured.modelId }?.displayName
            ?? featured.modelId
        return SidebarDownload(info: featured, title: name,
                               others: downloads.count - 1)
    }

    private static func rank(_ state: DownloadState) -> Int {
        switch state {
        case .downloading: 0
        case .provisioning: 1
        case .paused: 2
        case .queued: 3
        }
    }

    /// The family runtime rather than the weights: an environment being built,
    /// with no bytes to count. Either half of the contract can say so — the
    /// state for a download that has reached its provisioning step, the
    /// `runtime_only` flag for an install that was never fetching weights at
    /// all (contract §4.2).
    var isRuntimeInstall: Bool {
        info.state == .provisioning || info.stage == "provisioning"
            || info.isRuntimeOnly
    }

    /// The word above the name. Suspended and waiting come first: those are
    /// true of a runtime install as much as of a transfer, and "INSTALLING
    /// RUNTIME" over something that has stopped would be a lie of tense.
    var eyebrow: String {
        switch info.state {
        case .paused: "PAUSED"
        case .queued: "QUEUED"
        case .downloading, .provisioning:
            isRuntimeInstall ? "INSTALLING RUNTIME" : "DOWNLOADING"
        }
    }

    /// Nil when there is nothing to measure — a runtime install has no byte
    /// total, and neither does a transfer whose first progress event has not
    /// landed. A bar drawn at zero in either case reads as a stall.
    var fraction: Double? {
        guard info.bytesTotal > 0 else { return nil }
        return Double(info.bytesDone) / Double(info.bytesTotal)
    }

    /// The card keeps one thing moving so it cannot be mistaken for a frozen
    /// readout: the bar where there are bytes, a spinner where there are not.
    /// Nothing spins for a download that is genuinely stopped.
    var showsSpinner: Bool {
        fraction == nil && (info.state == .downloading || info.state == .provisioning)
    }

    /// The mono line, where it can be written without the smoothed rate that
    /// lives with the view. Nil means "this one is transferring" — see
    /// `SidebarDownloadCard`, which owns the smoother.
    var staticDetail: String? {
        guard fraction == nil else { return nil }
        switch info.state {
        case .queued: return "WAITING ITS TURN"
        case .paused: return "PAUSED"
        case .downloading, .provisioning:
            guard isRuntimeInstall else { return "STARTING…" }
            return info.message?.uppercased() ?? "SETTING UP THE RUNTIME"
        }
    }

    /// What is behind this one, so a queue of six does not look like a single
    /// download that will be over in a minute.
    var othersLine: String? {
        others > 0 ? "+\(others) MORE WAITING" : nil
    }
}

// MARK: - The card

/// The sidebar's download readout: what is being fetched, how far in and how
/// much longer — from wherever in the app you happen to be standing.
///
/// It sits between the screen's own card and the engine's, because that is the
/// order of how local the information is: this screen, then what the machine is
/// fetching, then the engine underneath both. A 57 GB model is worth knowing
/// about from Studio, and until this card existed the only place that said so
/// was the Models screen you had left.
///
/// The rate is smoothed here rather than in the store, so the estimate belongs
/// to what is on screen: it resets when the card appears instead of carrying a
/// stale average across the end of one download and the start of the next.
struct SidebarDownloadCard: View {
    let download: SidebarDownload

    @State private var rate = DownloadRate()

    private var isMoving: Bool {
        download.info.state == .downloading || download.info.state == .provisioning
    }

    var body: some View {
        BenchSidebarCard(stroke: isMoving ? Bench.Palette.accent.opacity(0.2)
                                          : Bench.Palette.hairline,
                         margin: 0) {
            HStack(spacing: 6) {
                Text(download.eyebrow)
                    .eyebrow(isMoving ? Bench.Palette.accent
                                      : Bench.Palette.textFaint)
                Spacer(minLength: 0)
                if let fraction = download.fraction {
                    Text("\(Int((fraction * 100).rounded()))%")
                        .font(Bench.Typo.mono(10, .semibold))
                        .foregroundStyle(isMoving ? Bench.Palette.accent
                                                  : Bench.Palette.textMuted)
                }
            }
            Text(download.title)
                .font(Bench.Typo.secondaryEmphasis)
                .foregroundStyle(Bench.Palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(download.title)
            if let fraction = download.fraction {
                BenchProgressBar(fraction: fraction, height: 4,
                                 tint: isMoving ? Bench.Palette.accent
                                                : Bench.Palette.textMuted)
            }
            HStack(alignment: .top, spacing: 7) {
                if download.showsSpinner { BenchSpinner(size: 11) }
                Text(detail)
                    .font(Bench.Typo.mono(10))
                    .lineSpacing(3)
                    .foregroundStyle(Bench.Palette.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
        // One ingest per engine sample, no double counting: the sampled
        // quantity is the speed, so that is what is fed to the smoother.
        .onChange(of: download.info.speedBps, initial: true) {
            rate.ingest(download.info.speedBps)
        }
    }

    private var detail: String {
        var lines = [download.staticDetail
                     ?? DownloadFormat.transferLine(download.info, rate: rate)]
        if let others = download.othersLine { lines.append(others) }
        return lines.joined(separator: "\n")
    }
}

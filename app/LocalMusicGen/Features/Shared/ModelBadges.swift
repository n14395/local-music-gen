// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Everything the catalog knows about a model, as the row of tokens the design
/// draws under its name.
///
/// It lives here rather than inside the Models row because Studio shows the
/// same model and has to say the same things about it. Two lists built from one
/// catalog entry drift — Studio was quoting modality and length while the
/// Models screen quoted size, speed and what the model unlocks, so the same
/// model described itself differently depending on which screen you asked.
///
/// The order is the design's: what is wrong with it first, then what it is,
/// then what it costs, then what it unlocks.
enum ModelBadges {
    struct Badge: Identifiable, Equatable {
        let id: String
        let text: String
        let tone: BenchBadge.Tone

        init(_ id: String, _ text: String, _ tone: BenchBadge.Tone = .neutral) {
            self.id = id
            self.text = text
            self.tone = tone
        }
    }

    /// - Parameters:
    ///   - isVariant: this entry repackages another (a quantised or
    ///     runtime-specific build), which the Models list draws as a nested row
    ///     and everywhere else has to say in a token.
    ///   - freeDiskBytes: nil where the caller has no reading, in which case no
    ///     disk warning is drawn rather than a guess.
    ///   - actionCount: how many of the app's actions this model unlocks; 0
    ///     drops the badge.
    static func list(for model: ModelInfo,
                     isVariant: Bool = false,
                     physicalMemory: Int64,
                     freeDiskBytes: Int64? = nil,
                     hasHFToken: Bool = false,
                     actionCount: Int = 0) -> [Badge] {
        var badges: [Badge] = []
        if isVariant { badges.append(Badge("variant", "VARIANT")) }
        if let ram = ramBadge(model, physicalMemory: physicalMemory) {
            badges.append(Badge("ram", ram, .danger))
        }
        if let disk = diskBadge(model, freeDiskBytes: freeDiskBytes) {
            badges.append(Badge("disk", disk, .danger))
        }
        // Modality and length describe *generation*. A stem separator declares
        // `instrumental_only` and a one-second maximum because neither field
        // means anything to it, and printing "INSTRUMENTAL · ≤ 1 S" on Demucs
        // would be a lie assembled out of true numbers.
        if model.capabilities.supportedTasks.contains("generate") {
            if model.capabilities.instrumentalOnly {
                badges.append(Badge("modality", "INSTRUMENTAL"))
            } else if model.capabilities.supportsLyrics {
                badges.append(Badge("modality", "VOCALS + LYRICS"))
            }
            let maxS = model.capabilities.duration.maxS
            if maxS > 0 {
                badges.append(Badge("duration", "≤ \(Int(maxS)) S"))
            }
        }
        badges.append(Badge("size", ByteFormat.gb(model.sizeBytes).uppercased()))
        badges.append(Badge("speed", model.requirements.speedTier.badgeLabel,
                            model.requirements.speedTier.badgeTone))
        if model.license.requiresHfToken {
            badges.append(hasHFToken
                          ? Badge("hf", "HF TOKEN ✓", .violet)
                          : Badge("hf", "HF TOKEN NEEDED", .warn))
        }
        if actionCount > 0 {
            badges.append(Badge("actions",
                                "\(actionCount) ACTION\(actionCount == 1 ? "" : "S")"))
        }
        return badges
    }

    /// The two tokens that survive a narrow header: what it makes, and how long
    /// it can make it. Everything else is a cost or a caveat, and a top bar
    /// that wraps is worse than one that says less.
    static func essential(for model: ModelInfo, physicalMemory: Int64) -> [Badge] {
        let keep: Set<String> = ["variant", "ram", "modality", "duration"]
        return list(for: model, physicalMemory: physicalMemory)
            .filter { keep.contains($0.id) }
    }

    /// `NEEDS 48 GB · YOU HAVE 36`.
    private static func ramBadge(_ model: ModelInfo,
                                 physicalMemory: Int64) -> String? {
        let needed = model.requirements.minRamBytes
        guard needed > physicalMemory else { return nil }
        return "NEEDS \(ByteFormat.wholeGB(needed)) GB · YOU HAVE "
            + ByteFormat.wholeGB(physicalMemory)
    }

    /// The other way a download fails halfway: the bytes fit in memory but not
    /// on the disk. Only drawn for a model you have not got yet — the check is
    /// meaningless once its files are already on the volume.
    private static func diskBadge(_ model: ModelInfo,
                                  freeDiskBytes: Int64?) -> String? {
        guard model.installState != .installed, let free = freeDiskBytes else {
            return nil
        }
        let needed = model.requirements.diskBytes
        guard needed > 0, needed > free else { return nil }
        return "NEEDS \(ByteFormat.gb(needed).uppercased()) DISK · "
            + ByteFormat.gb(free).uppercased() + " FREE"
    }
}

extension SpeedTier {
    var badgeLabel: String {
        switch self {
        case .fast: "FAST"
        case .medium: "MEDIUM"
        case .slow: "SLOW"
        case .experimental: "VERY SLOW"
        }
    }

    var badgeTone: BenchBadge.Tone {
        switch self {
        case .fast: .ok
        case .medium: .warn
        case .slow, .experimental: .danger
        }
    }
}

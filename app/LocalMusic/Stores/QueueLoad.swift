import Foundation

/// What the queue counters count.
///
/// A submission with **Takes: 3** is *one* job that renders three takes one
/// after another. Counting jobs is therefore true and useless: every readout
/// said "1 job" while three tracks were being made, which is not the unit the
/// user chose when they typed 3 into the Takes card.
///
/// So the counters speak in takes, and name jobs only when there is more than
/// one of them. Pure and value-typed so the arithmetic can be tested without a
/// store or a running engine.
struct QueueLoad: Equatable {
    /// Non-terminal jobs.
    var jobs: Int = 0
    /// Takes those jobs will produce in total.
    var takes: Int = 0
    /// Takes not finished yet, including the one rendering now. Falls back to
    /// the whole job wherever the engine has not said which take it is on —
    /// a job that has not started, or an engine too old to report it.
    var takesLeft: Int = 0
    /// Transfers in flight or waiting.
    var downloads: Int = 0
    /// Rows that have finished and are still on the list — a render that
    /// succeeded, failed or was cancelled, or a transfer that has stopped,
    /// waiting for the user to dismiss them.
    ///
    /// Counted separately from `jobs` because the two answer different
    /// questions. `jobs` is outstanding work, which is what the counters and
    /// the "Rendering 3 takes" pill are about; this is how many ROWS the queue
    /// has, which is what "is there anything to show" is about. Conflating
    /// them is what made a failed render vanish: the job stayed in the store
    /// with its error, the rail drew "Nothing queued" over the top of it, and
    /// the card only reappeared once a later submission made the count
    /// non-zero again.
    var finished: Int = 0
    /// …of which actually failed. Cancelling is something the user did and
    /// needs no announcement; a failure is something that happened to them.
    var failed: Int = 0

    /// Nothing to draw — as opposed to nothing *running*.
    var isEmpty: Bool { jobs == 0 && finished == 0 && downloads == 0 }

    /// `downloads` counts the transfers still moving or waiting;
    /// `finishedDownloads` the stopped ones the list is still holding, of which
    /// `failedDownloads` are failures. Those two fold in beside the renders,
    /// because `finished` and `failed` are counts of ROWS and a row is a row —
    /// whichever half of the queue it came from.
    static func of(jobs: [JobsStore.ActiveJob], downloads: Int = 0,
                   finishedDownloads: Int = 0,
                   failedDownloads: Int = 0) -> QueueLoad {
        var load = QueueLoad(downloads: downloads)
        load.finished = finishedDownloads
        load.failed = failedDownloads
        for job in jobs {
            guard !job.status.isTerminal else {
                load.finished += 1
                if job.status == .failed { load.failed += 1 }
                continue
            }
            // `count` is 1 on anything that predates multi-take and on every
            // task job, so this is the same number as before for them.
            let count = max(1, job.info.count)
            load.jobs += 1
            load.takes += count
            // `take` is 0-based, so a job reporting take 1 of 4 has 3 left.
            load.takesLeft += count - (job.progress?.take ?? 0)
        }
        return load
    }

    /// The same count, taken straight off the downloads store — the two
    /// places that draw the whole queue both need all three of its numbers,
    /// and picking them apart at each call site is how they drift.
    @MainActor
    static func of(jobs: [JobsStore.ActiveJob],
                   downloads: DownloadsStore) -> QueueLoad {
        of(jobs: jobs, downloads: downloads.downloads.count,
           finishedDownloads: downloads.finished.count,
           failedDownloads: downloads.finished.filter(\.isFailure).count)
    }

    /// "Rendering 3 takes" / "Rendering 2 jobs · 5 takes".
    ///
    /// One job is described by its takes alone: saying "1 job · 3 takes" makes
    /// the reader do arithmetic to learn nothing, and the job is not the thing
    /// they asked for.
    var renderingLabel: String {
        guard jobs > 0 else { return "Rendering" }
        if jobs == 1 {
            return takes == 1 ? "Rendering 1 take" : "Rendering \(takes) takes"
        }
        return "Rendering \(jobs) jobs · \(takes) takes"
    }

    /// The queue rail's header count, which spans renders and transfers.
    /// `3 TAKES · 1 DOWNLOAD`, either half dropped when it is zero.
    var headerLabel: String {
        var parts: [String] = []
        if takes > 0 { parts.append("\(takes) TAKE\(takes == 1 ? "" : "S")") }
        if downloads > 0 {
            parts.append("\(downloads) DOWNLOAD\(downloads == 1 ? "" : "S")")
        }
        // Rows the user has not cleared yet are part of what the list holds,
        // so the count that heads it says so — "EMPTY" above a failed render
        // is the same denial the empty state used to make.
        if failed > 0 { parts.append("\(failed) FAILED") }
        if finished - failed > 0 { parts.append("\(finished - failed) FINISHED") }
        return parts.isEmpty ? "EMPTY" : parts.joined(separator: " · ")
    }
}

extension JobsStore.ActiveJob {
    /// "Take 2 of 4" while a multi-take job renders.
    ///
    /// nil for a single take, and nil until the engine says which take it is
    /// on — during a cold load nothing is rendering yet, and guessing from
    /// `fraction` would be inventing a position (it is null for exactly the
    /// adapters that cannot count).
    var takeLabel: String? {
        let count = max(1, info.count)
        guard count > 1, let take = progress?.take else { return nil }
        // Clamped rather than trusted: a take index past the end would print
        // "take 5 of 4", and a readout is not worth a crash or a lie.
        return "Take \(min(max(take, 0), count - 1) + 1) of \(count)"
    }
}

import Foundation

/// What the queue counters count.
///
/// A submission with **Takes: 3** is three jobs now (contract §5.1), one per
/// take, sharing a group. So counting jobs is the same as counting takes —
/// but "3 jobs" is still not what the user asked for, they asked for three
/// takes of one thing. The counters therefore speak in takes, and name
/// *batches* rather than jobs when more than one submission is outstanding.
///
/// Pure and value-typed so the arithmetic can be tested without a store or a
/// running engine.
struct QueueLoad: Equatable {
    /// Non-terminal jobs.
    var jobs: Int = 0
    /// Distinct submissions those jobs came from (`groupId`). One Generate
    /// press is one batch however many takes it asked for.
    var batches: Int = 0
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
        var groups: Set<String> = []
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
            groups.insert(job.info.groupId)
            load.takes += count
            // `take` is 0-based, so a job reporting take 1 of 4 has 3 left.
            // On a fanned-out batch every job renders one take and reports
            // take 0, which is the same arithmetic: one take left each.
            load.takesLeft += count - (job.progress?.take ?? 0)
        }
        load.batches = groups.count
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

    /// "Rendering 3 takes" / "Rendering 2 renders · 5 takes".
    ///
    /// One submission is described by its takes alone: saying "1 render · 3
    /// takes" makes the reader do arithmetic to learn nothing, and the batch
    /// is not the thing they asked for — the takes are. Counted in batches
    /// rather than jobs because those are now the same number as takes, and
    /// "3 jobs · 3 takes" says one fact twice.
    var renderingLabel: String {
        guard jobs > 0 else { return "Rendering" }
        if batches <= 1 {
            return takes == 1 ? "Rendering 1 take" : "Rendering \(takes) takes"
        }
        return "Rendering \(batches) renders · \(takes) takes"
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
    /// "Take 2 of 4" — which take of its submission this row is.
    ///
    /// Known from the moment the job is queued now that a batch is one job per
    /// take (contract §5.1), which is the point: a queued card can say which
    /// take it will be, where the old single-job row could only say it once
    /// the engine reported a position mid-render.
    ///
    /// nil for a single-take submission, which has nothing to distinguish
    /// itself from. The `count`/`progress.take` fallback keeps a job from an
    /// engine that predates the fan-out reading as it always did: nil until it
    /// says which take it is on, because guessing from `fraction` would be
    /// inventing a position (it is null for exactly the adapters that cannot
    /// count).
    var takeLabel: String? {
        if info.takeOf != nil {
            guard info.takesInBatch > 1 else { return nil }
            return "Take \(info.takeIndexInBatch + 1) of \(info.takesInBatch)"
        }
        let count = max(1, info.count)
        guard count > 1, let take = progress?.take else { return nil }
        // Clamped rather than trusted: a take index past the end would print
        // "take 5 of 4", and a readout is not worth a crash or a lie.
        return "Take \(min(max(take, 0), count - 1) + 1) of \(count)"
    }
}

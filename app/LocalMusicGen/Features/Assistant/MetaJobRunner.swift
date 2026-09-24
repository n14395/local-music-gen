// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Runs a task job whose whole answer is `result.meta`.
///
/// `assist` and `plan` are the two tasks that produce nothing the library ever
/// holds — no song, no part, no stem. Everything they return is a small
/// dictionary the page that asked for it reads once and throws away.
///
/// That is why they run here rather than through `JobsStore`. That store's job
/// is to turn finished work into rows in the library, and its ingest switch is
/// organised around which kind of row a result becomes; a case that means
/// "becomes nothing, and the caller is already waiting for it" would be a case
/// that exists purely to be skipped. Polling a short job from the page that
/// wants it is both simpler and easier to reason about, and it keeps the queue
/// screen free of jobs nobody thinks of as renders.
enum MetaJobRunner {

    enum Failure: Error, Equatable {
        case notConnected
        case refused(String)
        case failed(String)
        case cancelled
        case timedOut
        case empty

        var message: String {
            switch self {
            case .notConnected: "Not connected to the engine."
            case .refused(let why): why
            case .failed(let why): why
            case .cancelled: "Cancelled."
            case .timedOut: "It took too long and was given up on."
            case .empty: "Nothing usable came back."
            }
        }
    }

    /// Submit and wait. Returns the finished job, whose `result.meta` is the
    /// answer.
    ///
    /// `timeout` is generous by default because the first request of a session
    /// also pays for loading the model, and a cold load on a busy machine is
    /// not instant — but it is bounded, so a wedged worker releases the page
    /// instead of holding it forever.
    ///
    /// It is the budget for *running* this job, and so it only starts once the
    /// job leaves the queue. The engine runs one job at a time, and a page like
    /// Compare-describers submits one per ticked model at once: measured from
    /// submit, everything after the first spent its whole budget waiting its
    /// turn and reported "it took too long" while still queued — and then threw
    /// away the answer when it arrived. `queueTimeout` is the separate, much
    /// looser bound on that wait, so a queue that never moves still releases the
    /// page.
    static func run(client: BackendClient, modelId: String, task: String,
                    params: [String: JSONValue],
                    timeout: TimeInterval = 180,
                    queueTimeout: TimeInterval = 1800) async -> Result<JobInfo, Failure> {
        let created: JobsCreated
        do {
            created = try await client.submit(JobSubmission(
                modelIds: [modelId], task: task, prompt: "", lyrics: nil,
                durationS: 0, count: 1, params: params, force: false))
        } catch {
            return .failure(.refused(error.localizedDescription))
        }
        guard let jobId = created.jobs.first?.jobId else {
            return .failure(.refused("The engine accepted no job."))
        }

        let submittedAt = Date()
        // nil while the job is still queued; the run budget starts when it fills.
        var startedAt: Date?
        while true {
            if Task.isCancelled {
                cancelOnEngine(client, jobId)
                return .failure(.cancelled)
            }
            let elapsed = Date().timeIntervalSince(startedAt ?? submittedAt)
            if elapsed >= (startedAt == nil ? queueTimeout : timeout) { break }
            try? await Task.sleep(for: .milliseconds(400))
            // A dropped poll is not a failure: one refused request while the
            // engine is busy should not end a job that is still running fine.
            guard let job = try? await client.job(jobId) else { continue }
            switch job.status {
            case .succeeded: return .success(job)
            case .failed:
                return .failure(.failed(job.error?.message
                                        ?? "The engine reported a failure."))
            case .canceled: return .failure(.cancelled)
            case .queued: continue
            default:
                // loading / generating / encoding: it is our turn now, so this
                // is where the job's own clock starts.
                if startedAt == nil { startedAt = Date() }
                continue
            }
        }
        cancelOnEngine(client, jobId)
        return .failure(.timedOut)
    }

    /// Stop the job on the engine as well as the polling. Giving up here
    /// used to leave the assist, plan or caption running — still loading
    /// its family, still holding the one GPU queue — for a page nobody was
    /// looking at, and the natural answer to "it took too long", pressing
    /// the button again, queued a second one behind it. Detached, because
    /// the task this runs in is the one that was just cancelled, and an
    /// `await` inside it would be cut short before the request left.
    private static func cancelOnEngine(_ client: BackendClient, _ jobId: String) {
        Task.detached { try? await client.cancelJob(jobId) }
    }
}

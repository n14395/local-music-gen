// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The three-way answer to "what is installed on this Mac?", and the single
/// place the rule that decides it lives.
///
/// An empty `[ModelInfo]` is ambiguous for the first second of every launch.
/// The engine is a Python sidecar that has to start before it can answer, so
/// until it does, "nothing is installed" and "nobody has asked yet" are the
/// same value — and reading `catalog.models` directly, treating empty as an
/// answer, is how a launch came to tell a user with forty models installed
/// that every Action needed a download.
///
/// Three-valued on purpose, and an enum rather than a `Bool` on purpose: the
/// store has carried a `hasLoaded` flag since the Models list needed one, and
/// five other screens simply never reached for it. A value every readiness
/// question has to switch over is harder to forget than a flag it can ignore.
enum CatalogReadiness: Equatable, Sendable {
    /// The engine has not answered yet. Claim nothing about what is installed.
    case pending(detail: String)
    /// The engine answered with a failure, so the catalog is not coming on its
    /// own. Still not a licence to say "not installed": the models are very
    /// probably there, behind an engine that will not start. The fix is the
    /// engine, and pointing at a download instead sends the user to a button
    /// that cannot work either.
    case unavailable(message: String)
    /// The engine answered. `models` is the truth now, empty or not.
    case ready

    static func state(hasLoaded: Bool, isConnected: Bool, lastError: String?,
                      backend: BackendPhase) -> CatalogReadiness {
        // A failure outranks "not loaded yet": it is an answer, and a spinner
        // would hide it behind an animation that never ends — the engine that
        // never starts is exactly the case where the user needs to be told.
        if let lastError { return .unavailable(message: lastError) }
        if case .failed(let reason) = backend {
            return .unavailable(message: reason)
        }
        if !hasLoaded {
            if isConnected { return .pending(detail: "Fetching the catalog…") }
            return .pending(detail: backend == .restarting
                            ? "Restarting the engine…" : "Starting the engine…")
        }
        return .ready
    }

    /// Whether a question about installed models can be answered at all.
    ///
    /// Deliberately phrased as a claim about knowledge rather than as
    /// `isReady`: the thing a caller must not do while this is false is *say
    /// something* about the user's install.
    var knowsWhatIsInstalled: Bool { self == .ready }

    /// One line for a screen that has to explain why it is not answering yet,
    /// or nil once it can.
    var waitingLine: String? {
        switch self {
        case .pending(let detail): detail
        case .unavailable(let message): message
        case .ready: nil
        }
    }

    /// Short enough for a card footnote or a chip tooltip, where the engine's
    /// own wording ("Fetching the catalog…") is more detail than the space or
    /// the reader wants.
    var shortLine: String? {
        switch self {
        case .pending: "Checking what's installed…"
        case .unavailable: "The engine isn't running"
        case .ready: nil
        }
    }
}

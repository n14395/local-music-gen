// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import Foundation

enum APIError: Error, LocalizedError {
    case http(status: Int, body: APIErrorBody)
    case transport(underlying: Error)
    case decoding(underlying: Error)
    case notConnected

    var errorDescription: String? {
        switch self {
        case .http(_, let body): humanMessage(for: body)
        case .transport(let e): "The engine is unreachable: \(e.localizedDescription)"
        case .decoding: "The engine sent a response the app couldn't read."
        case .notConnected: "The engine isn't running yet."
        }
    }

    var code: String? {
        if case .http(_, let body) = self { return body.code }
        return nil
    }

    private func humanMessage(for body: APIErrorBody) -> String {
        switch body.code {
        case "OOM":
            "This model ran out of memory — try a shorter duration or close other apps."
        case "INSUFFICIENT_RAM":
            "This model needs more memory than this Mac has available."
        case "INSUFFICIENT_DISK":
            "Not enough free disk space for this download."
        case "MODEL_NOT_INSTALLED":
            "That model isn't downloaded yet."
        case "WORKER_CRASHED":
            "The engine worker exited unexpectedly. See the job details for more information."
        default:
            body.message
        }
    }
}

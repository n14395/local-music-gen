// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// How user content leaves the disk.
///
/// One place rather than a call-site choice, so "Move deleted files to the
/// Trash" means the same thing at every deletion in the app. Derived files —
/// waveform caches, previews — are not routed through this: they regenerate,
/// and a Trash full of `.peaks` files is noise around the audio the user
/// might actually want back.
enum FileDisposal {
    static func dispose(_ url: URL, toTrash: Bool) {
        let fm = FileManager.default
        // `trashItem` throws for a missing file and for volumes with no
        // Trash; both fall through to the plain removal, which no-ops on the
        // former and does the best available thing on the latter.
        if toTrash, (try? fm.trashItem(at: url, resultingItemURL: nil)) != nil {
            return
        }
        try? fm.removeItem(at: url)
    }
}

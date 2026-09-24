// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import Foundation
import UniformTypeIdentifiers

/// Whether a dropped file is something the library can take in.
///
/// Finder hands us file URLs with no type information, so the extension is what
/// we have. Anything `UTType` calls audio (or conforms to it) counts —
/// deliberately wider than `AudioImporter`'s passthrough list, because the
/// importer transcodes whatever CoreAudio can decode and refusing the drop
/// would be the wrong place to find that out.
///
/// Shared rather than per-screen: the Actions gallery and the Library's
/// Imported list are the same offer made in two places, and a file that one of
/// them accepted while the other silently ignored it would read as a bug.
enum AudioDrop {
    static func isAudio(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else {
            return false
        }
        return type.conforms(to: .audio) || type.conforms(to: .audiovisualContent)
    }

    static func audioFiles(in urls: [URL]) -> [URL] {
        urls.filter(isAudio)
    }
}

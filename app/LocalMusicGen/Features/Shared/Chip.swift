// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// Metadata badge shared by the catalog, parts library, and workbench.
///
/// Kept as its own type rather than folded into `BenchBadge` because it is
/// called from a dozen places with a bare string; this is the adapter that
/// gives all of them the design's badge without touching each call site.
struct Chip: View {
    let text: String
    var tone: BenchBadge.Tone = .neutral

    init(_ text: String, tone: BenchBadge.Tone = .neutral) {
        self.text = text
        self.tone = tone
    }

    var body: some View {
        BenchBadge(text, tone: tone)
    }
}

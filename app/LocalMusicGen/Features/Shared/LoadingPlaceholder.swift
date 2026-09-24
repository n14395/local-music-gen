// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// ContentUnavailableView's shape with a spinner where the icon goes, for the
/// "we don't know yet" states that must not be phrased as an empty result.
///
/// The rule that decides when a screen is in one of those states is
/// `CatalogReadiness`, not this view.
struct LoadingPlaceholder: View {
    let title: String
    var detail: String?

    var body: some View {
        VStack(spacing: 10) {
            BenchSpinner(size: 26, lineWidth: 2.5)
                .padding(.bottom, 4)
            Text(title)
                .font(Bench.Typo.sectionTitle)
                .foregroundStyle(Bench.Palette.textPrimary)
            if let detail {
                Text(detail)
                    .font(Bench.Typo.secondary)
                    .foregroundStyle(Bench.Palette.textQuaternary)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, minHeight: 180)
    }
}

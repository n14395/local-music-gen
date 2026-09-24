// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// The top-bar pill that flips a screen between its workspace and its
/// full-page render view — "Rendering 2 takes" one way, "Back to render" the
/// other.
///
/// Extracted from the Generate top bar so Style Transfer and the Workbench
/// draw the *same* control: the spinner inside it is what says "this screen
/// is doing something" from every workspace that renders.
struct RenderStatusPill: View {
    /// Which way pressing this goes. `.toWorkspace` is the render view
    /// offering the controls (chevron left, the way back); `.toRender` is
    /// the workspace offering the render it came from (chevron right).
    ///
    /// Without it the pill read as a status readout — it says "Rendering 2
    /// takes", which is a fact, not an invitation — and nothing announced
    /// that the whole thing was a button.
    enum Direction { case toWorkspace, toRender }

    let label: String
    var direction: Direction = .toWorkspace
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if direction == .toWorkspace { chevron("chevron.left") }
                BenchSpinner(size: 14)
                Text(label)
                    .font(Bench.Typo.secondaryEmphasis)
                    .foregroundStyle(Bench.Palette.accent)
                if direction == .toRender { chevron("chevron.right") }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.button)
                .fill(Bench.Palette.accent.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.button)
                .strokeBorder(Bench.Palette.accent.opacity(0.28), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Switch between the render and the controls — the render keeps "
              + "going either way")
    }

    private func chevron(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Bench.Palette.accent)
    }
}

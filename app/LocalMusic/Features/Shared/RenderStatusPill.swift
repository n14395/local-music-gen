import SwiftUI

/// The top-bar pill that flips a screen between its workspace and its
/// full-page render view — "Rendering 2 takes" one way, "Back to render" the
/// other.
///
/// Extracted from the Generate top bar so Style Transfer and the Workbench
/// draw the *same* control: the spinner inside it is what says "this screen
/// is doing something" from every workspace that renders.
struct RenderStatusPill: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                BenchSpinner(size: 14)
                Text(label)
                    .font(Bench.Typo.secondaryEmphasis)
                    .foregroundStyle(Bench.Palette.accent)
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
}

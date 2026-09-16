import SwiftUI

/// One score, engraved. Sizes itself to the height the page reports, so it
/// sits in a scroll view like any other content; the web view never scrolls.
///
/// Two rules keep it honest. A render that draws nothing — prose filed as
/// ABC, a thrown parse — shows the app's own empty state with the warnings
/// under it, and tells the caller through `onRendered` so it can fall back to
/// the text; never a blank rectangle. And the frame before the page has
/// answered is a fixed height with a spinner, with no animation on the change
/// to the real one: a score popping to size is fine, a score sliding open on
/// every re-render is not.
struct NotationView: View {
    let abc: String
    var scale: Double = 1
    var transpose: Int = 0
    /// A cap on the drawn height, for a slot that should not grow to a
    /// four-voice, two-hundred-bar transcription. The caller learns from
    /// `onRendered` that the cap bit and says "Open to see all".
    var maxHeight: CGFloat? = nil
    var theme: NotationTheme = .bench
    /// For a host that exports — see `NotationBridge`.
    var bridge: NotationBridge? = nil
    var onRendered: ((NotationRender) -> Void)? = nil

    /// The width the last layout gave us, and the one the page has been
    /// asked to fill. They differ only while a resize is settling.
    @State private var width: CGFloat = 0
    @State private var settledWidth: CGFloat = 0
    @State private var settling: Task<Void, Never>?
    @State private var render: NotationRender?

    /// Before the page has ever answered: room for a spinner, not a guess at
    /// the score.
    static let placeholderHeight: CGFloat = 96
    /// How long a width change waits before it is engraved. A resize drags
    /// the layout through many widths, and each engraving is a whole parse;
    /// the first width is drawn at once, only the changes wait.
    static let widthDebounce: Duration = .milliseconds(80)

    private var request: NotationRequest? {
        guard settledWidth > 0 else { return nil }
        return NotationRequest(abc: abc, width: settledWidth, scale: scale,
                               transpose: transpose, theme: theme)
    }

    private var drawnHeight: CGFloat {
        guard let render else { return Self.placeholderHeight }
        if render.isEmpty { return 0 }
        let height = max(40, CGFloat(render.height))
        return maxHeight.map { min($0, height) } ?? height
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                NotationWebView(request: request, bridge: bridge,
                                onRendered: { report in
                                    render = report
                                    onRendered?(report)
                                })
                    .frame(maxWidth: .infinity)
                    .frame(height: drawnHeight)
                    .clipped()
                if render == nil { engraving }
            }
            if let render, render.isEmpty { emptyState(render) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
            widthChanged($0)
        }
        .onDisappear { settling?.cancel() }
    }

    private func widthChanged(_ measured: CGFloat) {
        let rounded = measured.rounded(.down)
        guard rounded > 0, rounded != width else { return }
        width = rounded
        if settledWidth == 0 {
            settledWidth = rounded
            return
        }
        settling?.cancel()
        settling = Task {
            try? await Task.sleep(for: Self.widthDebounce)
            guard !Task.isCancelled else { return }
            settledWidth = rounded
        }
    }

    private var engraving: some View {
        HStack(spacing: 8) {
            BenchSpinner(size: 12)
            Text("Engraving…")
                .font(Bench.Typo.small)
                .foregroundStyle(Bench.Palette.textFaint)
        }
        .padding(10)
    }

    private func emptyState(_ render: NotationRender) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Nothing here reads as notation.")
                .font(Bench.Typo.small)
                .foregroundStyle(Bench.Palette.textFaint)
            NotationWarnings(warnings: render.warnings)
        }
        .padding(.vertical, 4)
    }
}

/// The first few of a render's warnings and "and N more" — the same shape
/// the Models screen's action-error strip uses, so a broken bar reads like
/// every other refusal in the app.
struct NotationWarnings: View {
    let warnings: [String]
    var tone: Color = Bench.Palette.dangerText
    var limit = 3

    var body: some View {
        if !warnings.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(warnings.prefix(limit).enumerated()),
                        id: \.offset) { _, warning in
                    Text(warning)
                        .font(Bench.Typo.small)
                        .foregroundStyle(tone)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if warnings.count > limit {
                    Text("and \(warnings.count - limit) more")
                        .font(Bench.Typo.small)
                        .foregroundStyle(Bench.Palette.textFaintest)
                }
            }
        }
    }
}

/// A score that follows text being typed, a beat behind it — the Words
/// pipeline's editable ABC stage, where editing by hand used to be blind.
///
/// Debounced the way `WorkbenchView.syncPreview` debounces a re-arm: each
/// keystroke cancels the last wait, and the page is asked once the typing
/// pauses. The first fill draws at once, so arriving at a parked run shows
/// the score without a wait it did not need.
struct NotationLivePreview: View {
    let abc: String
    var scale: Double = 0.8

    @State private var shown = ""
    @State private var warnings: [String] = []
    @State private var pending: Task<Void, Never>?

    static let debounce: Duration = .milliseconds(300)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("AS IT WILL BE PLAYED").eyebrow()
            NotationView(abc: shown, scale: scale,
                         onRendered: { warnings = $0.warnings })
            // A typo is visible before Compose, in the quiet tone: this is a
            // draft, and a red strip under every unfinished bar would nag.
            NotationWarnings(warnings: warnings, tone: Bench.Palette.textFaint)
        }
        .onChange(of: abc, initial: true) { schedule() }
        .onDisappear { pending?.cancel() }
    }

    private func schedule() {
        pending?.cancel()
        if shown.isEmpty {
            shown = abc
            return
        }
        pending = Task {
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            shown = abc
        }
    }
}

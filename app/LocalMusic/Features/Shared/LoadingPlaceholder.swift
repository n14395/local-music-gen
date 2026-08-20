import SwiftUI

/// Why the model list is empty right now. An empty catalog is ambiguous until
/// the engine has answered once: "nothing installed" and "not asked yet" look
/// identical in the data, so the decision is made here and unit-tested rather
/// than inferred inside a view body.
enum CatalogPlaceholder: Equatable {
    /// Still waiting on the first answer — show a spinner, claim nothing.
    case loading(detail: String)
    /// The engine answered with a failure.
    case failed(message: String)
    /// The engine answered, and the catalog really is empty.
    case empty

    static func state(hasLoaded: Bool, isConnected: Bool, lastError: String?,
                      backend: BackendPhase) -> CatalogPlaceholder {
        // A failure outranks "not loaded yet": it is an answer, and a spinner
        // would hide it behind an animation that never ends — the engine that
        // never starts is exactly the case where the user needs to be told.
        if let lastError { return .failed(message: lastError) }
        if case .failed(let reason) = backend { return .failed(message: reason) }
        if !hasLoaded {
            if isConnected { return .loading(detail: "Fetching the catalog…") }
            return .loading(detail: backend == .restarting ? "Restarting the engine…"
                                                           : "Starting the engine…")
        }
        return .empty
    }
}

/// ContentUnavailableView's shape with a spinner where the icon goes, for the
/// "we don't know yet" states that must not be phrased as an empty result.
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

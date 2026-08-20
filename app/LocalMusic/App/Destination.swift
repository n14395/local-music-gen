import Foundation

/// The six places in the app.
///
/// The redesign replaced "four destinations plus nested tabs" with flat
/// ones. Split & Recombine is gone as a place: **Split** became an entry in
/// Actions, **Parts** folded into the Library behind a scope switch, and
/// **Recombine** split into Actions (the recipe gallery) and Workbench (the
/// bench itself, now top-level because it is somewhere you work, not a pane
/// you find). Style Transfer arrived the same way, and for the same reason:
/// it was nine one-shot Action pages that threw away their settings on exit.
///
/// `rawValue` is a stable id, never a label — the old `SidebarSection` used
/// its display string as its identity, which makes renaming a label a
/// data-visible change.
enum Destination: String, CaseIterable, Identifiable, Codable {
    case studio
    case actions
    /// Transforming audio that already exists. Declared after Actions because
    /// declaration order *is* `allCases` order, which is sidebar order — and
    /// the raw value is the case name, so moving a case does not disturb a
    /// destination already written to defaults.
    case styleTransfer
    case workbench
    case library
    case models

    var id: String { rawValue }

    var title: String {
        switch self {
        case .studio: "Studio"
        case .styleTransfer: "Style Transfer"
        case .actions: "Actions"
        case .workbench: "Workbench"
        case .library: "Library"
        case .models: "Models"
        }
    }

    /// Which sidebar section it lives under.
    enum Section: String, CaseIterable {
        case make = "MAKE"
        case browse = "BROWSE"
    }

    var section: Section {
        switch self {
        case .studio, .styleTransfer, .actions, .workbench: .make
        case .library, .models: .browse
        }
    }

    static func inSection(_ section: Section) -> [Destination] {
        allCases.filter { $0.section == section }
    }
}

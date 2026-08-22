import Foundation

/// The seven places in the app.
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
    /// First because it is the wider door: Actions is every recipe the app
    /// knows, and one shelf of them opens Generate with a prompt already
    /// written. Somebody who does not yet know what they want to type is
    /// better served by a gallery than by an empty prompt box.
    case actions
    /// Was `studio`, and the raw value still is — see the note above about
    /// labels never being identities. Renaming the case keeps the code
    /// reading like the sidebar; keeping the raw value keeps every
    /// `@AppStorage` destination already written to defaults pointing here.
    case generate = "studio"
    /// Transforming audio that already exists. Declared after Generate because
    /// declaration order *is* `allCases` order, which is sidebar order — and
    /// the raw value is the case name, so moving a case does not disturb a
    /// destination already written to defaults.
    case styleTransfer
    case workbench
    /// One file in detail — the Workbench arranges many. Declared after it
    /// so the sidebar reads make-then-refine top to bottom.
    case editor
    case library
    case models

    var id: String { rawValue }

    /// Where the app opens.
    ///
    /// Actions rather than Generate for the same reason Actions is declared
    /// first: it is the wider door. A gallery of every recipe the app knows
    /// answers "what can this do?" on its own, while an empty prompt box only
    /// helps somebody who already knows what to type.
    ///
    /// The destination is not persisted, so this is every launch, not just the
    /// first one — deliberately: coming back to where the app *starts* is
    /// steadier than coming back to wherever you happened to stop.
    static let launch: Destination = .actions

    var title: String {
        switch self {
        case .generate: "Generate"
        case .styleTransfer: "Style Transfer"
        case .actions: "Actions"
        case .workbench: "AI Workbench"
        case .editor: "Editor"
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
        case .generate, .styleTransfer, .actions, .workbench, .editor: .make
        case .library, .models: .browse
        }
    }

    static func inSection(_ section: Section) -> [Destination] {
        allCases.filter { $0.section == section }
    }
}

extension Destination {
    /// Which of the two job-driven sidebar rows a running job spins.
    ///
    /// Style Transfer, the Editor and Models report their own work and are
    /// subtracted by the caller; everything else is a generate or a transform,
    /// and those are the two rows here.
    ///
    /// Pure and static so the routing has a test. The bug it replaces was a
    /// `task == nil` check standing in for "is this a generate?", which is
    /// false for every job a current engine reports.
    static func busyOwner(task: String?) -> Destination {
        (task ?? "generate") == "generate" ? .generate : .actions
    }
}

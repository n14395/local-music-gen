// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Observation

/// Where the shell is pointed, and what it has in hand.
///
/// This was `MainWindow`'s private `@State` until the menubar arrived. A menu
/// command is declared on the *scene*, not inside the window, so it cannot
/// reach a view's `@State` at all — and "go to the Library", "edit the selected
/// track", "show the queue" are precisely the things a menubar is for. Lifting
/// the routing here gives both the window and the commands one place to read
/// and write, and follows the precedent the mailboxes already set
/// (`PrefillBox`, `StudioBox` live in `AppEnvironment` for the same reason).
///
/// What deliberately stayed in `MainWindow`: the window's own geometry —
/// measured width, the sidebar's fit, the content's minimum. Those describe a
/// frame being laid out, not a place the app is, and no menu item has an
/// opinion about them.
///
/// Two properties are persisted, and only two — the ones that were already
/// `@AppStorage` for the reasons written at their old declarations. They use
/// the `AppSettings` pattern (stored property, `didSet` writes) rather than a
/// computed pass-through, because `@Observable` tracks stored properties and a
/// computed one would not publish.
@MainActor @Observable
final class ShellState {
    // MARK: - Where we are

    var destination: Destination = .launch
    /// The whole library, because that is what the Library row is: arriving
    /// there for the first time in a session should show what you have, not the
    /// slice a previous version of this app happened to open on.
    var libraryScope: LibraryScope = .all

    /// A track the shell wants the Library to open on — set by the queue's
    /// "Show in library", cleared by the Library once it has acted.
    var libraryReveal: LibraryReveal?

    /// Live navigation inside Actions: nil is the gallery, non-nil is the
    /// configuration page currently open. Held here so a jump from another
    /// screen lands on a configured page, and so leaving Actions and coming
    /// back keeps your place.
    var actionsRoute: ActionsScreen.Route?

    /// One-off notes from reopening a finished mix — recovered tempo, missing
    /// parts, settings that were never recorded. Owned here because both
    /// Actions (which can hand the bench a fresh arrangement) and Workbench
    /// (which displays them) need to reach them.
    var workbenchNotices: [String] = []

    /// What a gated feature sent the user to Models to find, so the list there
    /// can narrow to the models that would ungate it.
    var modelRequirement: ModelRequirement?

    /// The model whose properties rail was open.
    var modelInspectedId: String?

    /// Which pane the Settings window should show. A mailbox rather than a
    /// stored preference: the App menu's submenu opens Settings *on* a pane,
    /// and the window clears this once it has moved, so reopening Settings by
    /// ⌘, afterwards lands where you left it rather than where a menu once
    /// sent you.
    var settingsPane: SettingsPane?

    /// Whether the Library groups parts under the song they came from. Lifted
    /// out of the screen for the same reason the selection was: the View menu
    /// carries the toggle, and a `Commands` body cannot reach a view's state.
    /// Not persisted — it is a way of reading one list, not a way of working.
    var libraryGroupsParts = true

    /// Which of those groups are open, by song id. Out here with the toggle
    /// above and the selection below, because the screen is rebuilt on every
    /// navigation and a set it owned would close every group on the way to the
    /// Editor and back. Not persisted either: a launch opens on the clean list
    /// of songs, which is what the closed groups are for.
    var libraryExpandedPartGroups: Set<String> = []

    // MARK: - What is picked

    /// What was picked in the Library — the inspected row of each kind, and
    /// the ticked set beside them. Out here rather than in the screen because
    /// the screen is rebuilt on every navigation, so a selection it owned
    /// itself would not survive a trip to Models and back — and because the
    /// Track menu acts on exactly this.
    var selectedSongId: String?
    var selectedPartId: String?
    var checked: Set<String> = []

    /// A/B comparison of two library rows. It lives in the shell rather than
    /// in the Library because the transport bar — which is where you switch
    /// sides — sits outside the screen, and now so does the Playback menu.
    let compare = LibraryCompare()

    // MARK: - Panels

    /// The queue panel, and the rule for when it shows itself.
    var queuePanel = QueuePanel()

    /// Whether the queue panel holds a column of its own instead of floating
    /// over the screen. Stored, unlike `queuePanel`: where you want the queue
    /// to sit is a way of working — a wide display can afford it permanently,
    /// a laptop cannot — and re-pinning it every launch would be a chore.
    var queuePinned: Bool {
        didSet { defaults.set(queuePinned, forKey: Self.queuePinnedKey) }
    }

    /// Hiding the sidebar is a working preference, not a session accident —
    /// somebody who wants the screen wide wants it wide tomorrow too.
    var sidebarCollapsed: Bool {
        didSet { defaults.set(sidebarCollapsed, forKey: Self.sidebarKey) }
    }

    /// Whether the window is currently too narrow to hold the sidebar and the
    /// screen at once, republished here by `MainWindow` from its `SidebarFit`.
    ///
    /// The fit itself stays with the window — it is measured from the frame
    /// and recomputed on every resize — but the *answer* has to be out here,
    /// because a `Commands` body cannot read the window's environment and the
    /// View menu's item must dim when the sidebar cannot be brought back.
    var sidebarCramped = false

    /// What the window actually draws: the preference unless the window has
    /// overruled it. Mirrors `SidebarFit.isCollapsed(preference:)`.
    var sidebarIsCollapsed: Bool { sidebarCollapsed || sidebarCramped }

    // MARK: - Sheets and confirmations

    /// The first-run flow, shown on its own schedule by `MainWindow` and on
    /// demand from Help.
    var showOnboarding = false

    /// "Add a model from Hugging Face" — a sheet the Models screen owns but
    /// that File can now ask for from anywhere.
    var showAddModel = false

    /// A song the Track menu asked to be renamed — a one-shot request the
    /// detail pane consumes by putting the caret in its title field and
    /// clearing this.
    ///
    /// A mailbox rather than a call, because the field belongs to a view three
    /// levels inside the Library and a menu item cannot reach a `FocusState`.
    var renameRequest: String?

    /// The same one-shot request, aimed at the notes field instead of the
    /// title. Two mailboxes rather than one with a "which field" payload,
    /// because the two fields are consumed by different views.
    var notesRequest: String?

    /// A song whose notation Track ▸ Show Notation asked to see — a one-shot
    /// request `MainWindow` consumes by presenting `NotationSheet` on the
    /// newest ABC document the song carries, and clearing this.
    ///
    /// The window rather than the detail pane, unlike the two above: the
    /// pane is only on screen in the scopes that list songs, and the item is
    /// enabled from a part row and from the Editor too.
    var notationRequest: String?

    /// The keyboard-shortcut reference, opened from Help.
    var showShortcuts = false

    /// A track the user asked to revert, held until they confirm.
    var pendingRevert: SongRecord?

    /// What the Track menu's Delete is waiting to be confirmed for.
    ///
    /// A `MenuTarget` rather than a record, because the same item deletes a
    /// song or a part and the dialog is the same either way — and because the
    /// row it names has to be re-read when the user actually confirms, not
    /// frozen at the moment they chose the item.
    var pendingDelete: MenuTarget?

    /// Set when a revert could not run because a render was in flight — a
    /// confirmed destructive action must never appear to do nothing.
    var revertBlocked: String?

    /// The ticked rows the Track menu's batch Delete is waiting to be
    /// confirmed for. Ids rather than records, for the reason `pendingDelete`
    /// holds a target: the rows are re-read when the user actually confirms.
    var pendingBatchDelete: Set<String>?

    // MARK: - Storage

    private static let queuePinnedKey = "queue.pinned"
    private static let sidebarKey = "sidebar.collapsed"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Both default to false, which `bool(forKey:)` already reads
        // correctly for an absent key — unlike the on-by-default preferences
        // in `AppSettings`, which need its `flag` helper.
        self.queuePinned = defaults.bool(forKey: Self.queuePinnedKey)
        self.sidebarCollapsed = defaults.bool(forKey: Self.sidebarKey)
    }

    // MARK: - Routing

    /// Go somewhere, and bring the window that shows it forward.
    ///
    /// The activation is the whole difference between this and assigning
    /// `destination`: a menu command can be chosen while the Settings window
    /// is frontmost, and switching a screen nobody can see is the kind of
    /// silent no-op that makes a menubar untrustworthy.
    func go(to next: Destination) {
        destination = next
        ShellWindow.focus()
    }

    /// Go to the Library, on this slice of it.
    func go(to scope: LibraryScope) {
        libraryScope = scope
        go(to: .library)
    }

    /// Go to Models, carrying what was missing. Always assigned — including
    /// `nil` — so an errand from one screen cannot leave its filter behind for
    /// the next visit from another.
    func openModels(for requirement: ModelRequirement?) {
        modelRequirement = requirement
        go(to: .models)
    }

    /// Where the panel is sitting right now: the stored preference, unless it
    /// opened itself for a render, which pins it for that showing.
    var queueIsPinned: Bool { queuePanel.isPinned(preference: queuePinned) }
}

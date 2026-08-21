import Foundation

/// Whether the queue panel is showing, and when it shows itself.
///
/// The rule is a **rising edge**: work starting where there was none opens the
/// panel, and nothing else does. So closing it keeps it closed for the rest of
/// that run of work — there is no second edge until the queue has emptied —
/// and the next batch opens it again. That is the behaviour Studio's permanent
/// rail had, minus the part where you could not put it away, and it now
/// applies to renders started from Actions and Style Transfer, which never had
/// a queue view at all.
///
/// Draining the queue deliberately does **not** close it: a panel you opened
/// yourself should not vanish the moment the last take lands, which is exactly
/// when you were looking at it.
///
/// A value type with no store behind it, so the edge detection can be tested
/// without an engine, a job, or a window.
struct QueuePanel: Equatable {
    private(set) var isOpen = false
    /// Set when the panel opened itself because work started. A queue that
    /// arrives unasked is one you are going to watch — it is the thing you
    /// just pressed a button to start — so it takes a column of its own rather
    /// than lying over the screen you were reading. Separate from the stored
    /// preference so it can do that without overwriting it: unpin it and the
    /// answer holds for this showing, not for good.
    private(set) var pinnedByWork = false
    /// What `workChanged` was last told. Held rather than recomputed because
    /// the edge is the whole point: the panel opens on the transition, not on
    /// the state — otherwise every progress tick would reopen it.
    private var isWorking = false

    /// Call whenever work starts or stops.
    mutating func workChanged(isWorking working: Bool) {
        defer { isWorking = working }
        guard working, !isWorking else { return }
        isOpen = true
        pinnedByWork = true
    }

    mutating func toggle() {
        isOpen.toggle()
        if !isOpen { pinnedByWork = false }
    }

    mutating func close() {
        isOpen = false
        pinnedByWork = false
    }

    /// The user reached for the pin. Whatever they chose is now the whole
    /// answer, so the work-driven pin stops speaking over it.
    mutating func pinChanged() { pinnedByWork = false }

    /// Where the panel sits, given the stored preference. Pinned by preference
    /// or pinned because work opened it — either way it holds its own column.
    func isPinned(preference: Bool) -> Bool { preference || pinnedByWork }

    /// How much width the panel takes *out of* the screen behind it: the rail
    /// when it is pinned and showing, nothing otherwise. Pinning is a stored
    /// preference rather than part of this value, so a panel that is pinned
    /// but closed reserves nothing — the pin says where it goes when it opens,
    /// not that it is open.
    ///
    /// The same number widens the window's minimum, which is the point of
    /// having it in one place: the 1100 pt floor is already fully spent by
    /// Studio in Full control, so a pinned rail that did not raise it would
    /// squeeze the prompt column to nothing on a small window.
    static func gutter(isOpen: Bool, isPinned: Bool, width: CGFloat) -> CGFloat {
        isOpen && isPinned ? width : 0
    }
}

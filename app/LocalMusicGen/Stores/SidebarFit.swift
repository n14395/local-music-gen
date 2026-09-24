// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import CoreGraphics

/// Whether the sidebar can have its column.
///
/// Two things decide it, and they are not the same thing: what the user asked
/// for, and whether the window is wide enough to honour it. Kept apart for the
/// reason `QueuePanel` keeps pinning apart from opening — a preference the
/// window has overruled must still be there when the window grows back, or
/// dragging a corner would quietly forget what you chose.
///
/// Pure and value-typed so the arithmetic can be tested without a window.
struct SidebarFit: Equatable {
    /// What to assume the screen needs until it has been measured.
    ///
    /// Only a starting point, and deliberately the old number: the window floor
    /// was 1100 with a 230 pt sidebar permanently inside it. The real figure
    /// comes from `MinWidthReader`, because it is a different number on every
    /// screen and this one is wrong for the Editor by several hundred points.
    static let contentMinWidth: CGFloat = 870

    /// Set when the window cannot hold the sidebar and the screen at once.
    private(set) var isCramped = false

    /// Recompute from the window's width.
    mutating func widthChanged(_ width: CGFloat, contentMinWidth: CGFloat,
                               sidebarWidth: CGFloat = Bench.Metrics.sidebarWidth) {
        isCramped = !Self.fits(windowWidth: width,
                               contentMinWidth: contentMinWidth,
                               sidebarWidth: sidebarWidth)
    }

    /// Whether the sidebar is drawn, given what the user asked for. The window
    /// wins: a sidebar shown where it does not fit takes the room from the
    /// screen it is there to navigate.
    func isCollapsed(preference: Bool) -> Bool { preference || isCramped }

    /// The window width that shows everything at once.
    ///
    /// Read from what the user *asked* for, not from what is currently drawn:
    /// once the sidebar has auto-collapsed, a requirement that had shrunk
    /// along with it would leave the window no reason to grow back, and the
    /// sidebar would never return.
    static func requiredWidth(sidebarPreferredOpen: Bool,
                              contentMinWidth: CGFloat,
                              sidebarWidth: CGFloat = Bench.Metrics.sidebarWidth)
        -> CGFloat {
        contentMinWidth + (sidebarPreferredOpen ? sidebarWidth : 0)
    }

    /// Room for both, at the width the window actually has.
    ///
    /// A width of zero is the first layout pass, before anything has been
    /// measured — answered `true` so the sidebar does not collapse and snap
    /// back open in the first frame of every launch.
    static func fits(windowWidth: CGFloat, contentMinWidth: CGFloat,
                     sidebarWidth: CGFloat = Bench.Metrics.sidebarWidth) -> Bool {
        guard windowWidth > 0 else { return true }
        return windowWidth - sidebarWidth >= contentMinWidth
    }
}

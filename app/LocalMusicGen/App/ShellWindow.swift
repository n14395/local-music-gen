import AppKit

/// Bringing the main window forward from a menu command.
///
/// Menu items are always live, including while the Settings window is the one
/// in front. "Go to Library" chosen from there used to be a silent no-op: the
/// destination changed on a window nobody was looking at. Every command that
/// alters what the main window *shows* raises it first.
@MainActor
enum ShellWindow {
    /// Raise the main window, if there is one and it is not already key.
    ///
    /// The Settings scene is identified by its own scene id, which SwiftUI
    /// stamps onto the `NSWindow`. Everything else that can become main is the
    /// document window — there is only ever the one, since `SingleInstance`
    /// hands a second launch off to the running app.
    static func focus() {
        guard let window = mainWindow, !window.isKeyWindow else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: false)
    }

    /// True when the main window is the one the user is looking at — what a
    /// command needs to know before acting on the screen inside it.
    static var isFrontmost: Bool {
        guard let window = mainWindow else { return false }
        return window.isKeyWindow
    }

    private static var mainWindow: NSWindow? {
        NSApp.windows.first { window in
            window.isVisible && window.canBecomeMain && !isSettings(window)
        }
    }

    /// Matched on a *prefix*, not equality: SwiftUI derives the window's
    /// identifier from the scene id but does not promise it verbatim — the
    /// observed form is `settings-AppWindow-1`.
    private static func isSettings(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue
            .hasPrefix(LocalMusicGenApp.settingsWindowID) ?? false
    }
}

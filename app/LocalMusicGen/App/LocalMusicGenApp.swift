import SwiftUI

@main
struct LocalMusicGenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    static let settingsWindowID = "settings"

    var body: some Scene {
        WindowGroup {
            MainWindow(env: appDelegate.env)
                .task { appDelegate.env.startBackend() }
        }
        // No title bar and no system toolbar: the design draws its own 52 pt
        // bar per screen, and the traffic lights float over the reserved
        // header at the top of the sidebar. This gives the window a full-size
        // content view but not the top of it — SwiftUI keeps a titlebar-sized
        // safe area, which `MainWindow` ignores.
        .windowStyle(.hiddenTitleBar)
        // The menubar. Declared on the main scene rather than on the app, so
        // the items belong to the *document* window — the Settings window gets
        // the stock bar plus whatever it publishes as a focused value of its
        // own, which is how its ⌘F keeps working.
        //
        // Every item reads `appDelegate.env`, which is why the shell's routing
        // had to move out of `MainWindow` and into `ShellState`: a command is
        // built with the scene, long before there is a view to hold state for
        // it, and a menu that cannot reach the state it acts on is a menu of
        // dead items.
        .commands { ShellCommands(env: appDelegate.env) }
        // A `Window`, not the `Settings` scene. Settings ignores
        // `.windowStyle(.hiddenTitleBar)` — it keeps its own titlebar, whose
        // material paints an opaque band across the top 28 pt of the content,
        // which is exactly where the redesign puts the section title and
        // "Reset this section". A plain window takes the modifier, so the rail
        // gets the traffic lights over its reserved header and the content
        // header lines up beside them, as in the main window.
        Window("Settings", id: Self.settingsWindowID) {
            SettingsView(env: appDelegate.env)
        }
        .windowStyle(.hiddenTitleBar)
        // The floor is the content's own `minWidth`/`minHeight`; the window is
        // resizable above it, because the Models section holds a library card
        // taller than any one size suits.
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1020, height: 740)
        .commands {
            // ⌘, still opens it, and still sits where macOS puts Settings in
            // the app menu — replacing the item the `Settings` scene would
            // have installed.
            CommandGroup(replacing: .appSettings) {
                OpenSettingsButton(env: appDelegate.env)
            }
        }
    }
}

/// The app menu's Settings item, and one for each pane.
///
/// A view rather than a plain `Button` because `openWindow` is only reachable
/// from the environment, and command groups get one. The submenu writes the
/// pane into the shell before opening the window, so a Settings window that is
/// already up moves to the chosen pane rather than opening a second one behind
/// the first — see `SettingsView`'s mailbox.
private struct OpenSettingsButton: View {
    let env: AppEnvironment
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Settings\u{2026}") {
            openWindow(id: LocalMusicGenApp.settingsWindowID)
        }
        .keyboardShortcut(",", modifiers: .command)

        Menu("Open Settings Pane") {
            ForEach(SettingsPane.Group.allCases, id: \.self) { group in
                Section(group.rawValue) {
                    ForEach(group.panes) { pane in
                        Button(pane.title) {
                            env.shell.settingsPane = pane
                            openWindow(id: LocalMusicGenApp.settingsWindowID)
                        }
                    }
                }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor let env = AppEnvironment()

    /// Runs before any window is created and before the engine is started, so a
    /// duplicate launch never gets far enough to fight the running instance for
    /// the engine and the data directory.
    @MainActor
    func applicationWillFinishLaunching(_ notification: Notification) {
        SingleInstance.deferToRunningInstanceIfNeeded()
        // The Bench palette is dark-only, and `preferredColorScheme` reaches
        // only SwiftUI's own views — menus, alerts, popovers and the open
        // panel would still come back light on a light Mac.
        NSApp.appearance = NSAppearance(named: .darkAqua)
    }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if env.hasRunningJob, env.settings.confirmQuitWhileRendering {
            let alert = NSAlert()
            alert.messageText = "A generation is still running"
            alert.informativeText = "Quitting cancels the current generation. Quit anyway?"
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Keep generating")
            if alert.runModal() != .alertFirstButtonReturn {
                return .terminateCancel
            }
        }
        Task { @MainActor in
            await env.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

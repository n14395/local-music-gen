import SwiftUI

@main
struct LocalMusicApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            MainWindow(env: appDelegate.env)
                .task { appDelegate.env.startBackend() }
        }
        // No title bar and no system toolbar: the design draws its own 52 pt
        // bar per screen, and the traffic lights float over the reserved
        // header at the top of the sidebar.
        .windowStyle(.hiddenTitleBar)
        Settings {
            SettingsView(env: appDelegate.env)
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
        if env.hasRunningJob {
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

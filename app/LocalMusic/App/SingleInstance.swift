import AppKit

/// One app, one engine. A second instance spawns its own engine against the
/// same data directory, loses the race for it, and leaves the user staring at a
/// window that can never work — so a launch that finds a live instance hands
/// over to it and gets out of the way.
///
/// This is not the same as LaunchServices' own "already running" handling:
/// that only recognises the *same* bundle path, so a second copy (dist build
/// next to a Debug build, an app moved to /Applications) or a directly executed
/// binary still starts a fresh instance.
enum SingleInstance {
    /// Whether this launch should defer to an instance that is already running.
    /// Split out from the lookup so the policy is testable.
    static func shouldDefer(otherInstanceRunning: Bool,
                            environment: [String: String]) -> Bool {
        guard otherInstanceRunning else { return false }
        // XCTest hosts the app binary itself: bailing out here would kill the
        // test run whenever the user happens to have LocalMusic open.
        if environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil { return false }
        // Deliberate side-by-side runs (a Debug build against the stub while
        // the packaged app runs the real engine) opt out.
        if environment["LOCALMUSIC_ALLOW_MULTIPLE_INSTANCES"] == "1" { return false }
        return true
    }

    /// Another live process of this app, if any.
    static func runningSibling() -> NSRunningApplication? {
        guard let id = Bundle.main.bundleIdentifier else { return nil }
        let mine = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .first { $0.processIdentifier != mine && !$0.isTerminated }
    }

    /// Called before anything is started or shown. Returns only if this
    /// instance should carry on launching.
    static func deferToRunningInstanceIfNeeded() {
        guard let sibling = runningSibling(),
              shouldDefer(otherInstanceRunning: true,
                          environment: ProcessInfo.processInfo.environment)
        else { return }
        handOver(to: sibling)
        // exit() rather than NSApp.terminate(): nothing has been started, so
        // there is nothing to unwind, and the termination path would touch the
        // shared data directory this instance has no business touching.
        exit(0)
    }

    /// Bring the running instance forward. `activate` alone is not enough — a
    /// process that is not itself frontmost (a launch from a terminal, or one
    /// that hasn't finished activating yet) has its request ignored — so ask
    /// LaunchServices to open the running app, which also un-minimises it and
    /// reopens its window if it has none.
    private static func handOver(to sibling: NSRunningApplication) {
        sibling.activate(options: [.activateAllWindows])
        guard let url = sibling.bundleURL else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        let handedOver = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            handedOver.signal()
        }
        // Bounded: exiting without the hand-off is better than hanging on it.
        _ = handedOver.wait(timeout: .now() + 2)
    }
}

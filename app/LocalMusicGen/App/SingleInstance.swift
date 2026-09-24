// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

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
    /// A process, as much of one as the tie-break needs.
    struct Instance: Equatable, Sendable {
        var launchDate: Date?
        var pid: pid_t
    }

    /// Which of two processes started first.
    ///
    /// Both processes have to reach the *same* answer, or they both defer —
    /// so this is a total order over facts both of them can see, never
    /// "am I the one that noticed second".
    static func isOlder(_ a: Instance, than b: Instance) -> Bool {
        if let mine = a.launchDate, let theirs = b.launchDate, mine != theirs {
            return mine < theirs
        }
        // LaunchServices does not always have a launch date, and two copies
        // opened together can share one to the millisecond. The pid is an
        // arbitrary winner, but it is antisymmetric — and an arbitrary winner
        // is still exactly one winner.
        return a.pid < b.pid
    }

    /// Whether this launch should defer to an instance that is already running.
    /// Split out from the lookup so the policy is testable.
    ///
    /// `sibling`/`me` break the tie. Asking only "is another instance
    /// running?" is symmetric: two copies started inside the same window each
    /// saw the other, each handed over, and each exited — the app simply did
    /// not start. Defer only to a process that began before this one.
    static func shouldDefer(otherInstanceRunning: Bool,
                            environment: [String: String],
                            sibling: Instance? = nil,
                            me: Instance? = nil) -> Bool {
        guard otherInstanceRunning else { return false }
        // XCTest hosts the app binary itself: bailing out here would kill the
        // test run whenever the user happens to have LocalMusicGen open.
        if environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil { return false }
        // Deliberate side-by-side runs (a Debug build against the stub while
        // the packaged app runs the real engine) opt out.
        if environment["LOCALMUSICGEN_ALLOW_MULTIPLE_INSTANCES"] == "1" { return false }
        guard let sibling, let me else { return true }
        return isOlder(sibling, than: me)
    }

    /// The *oldest* other live process of this app, if any.
    ///
    /// Oldest rather than whichever LaunchServices lists first: with three
    /// copies coming up together, each comparing itself against a different
    /// sibling could leave two survivors. Everyone comparing against the same
    /// process — the one that will not defer — leaves one.
    static func runningSibling() -> NSRunningApplication? {
        guard let id = Bundle.main.bundleIdentifier else { return nil }
        let mine = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { $0.processIdentifier != mine && !$0.isTerminated }
            .min { isOlder(instance(of: $0), than: instance(of: $1)) }
    }

    private static func instance(of app: NSRunningApplication) -> Instance {
        Instance(launchDate: app.launchDate, pid: app.processIdentifier)
    }

    /// Called before anything is started or shown. Returns only if this
    /// instance should carry on launching.
    static func deferToRunningInstanceIfNeeded() {
        let me = Instance(launchDate: NSRunningApplication.current.launchDate,
                          pid: ProcessInfo.processInfo.processIdentifier)
        guard let sibling = runningSibling(),
              shouldDefer(otherInstanceRunning: true,
                          environment: ProcessInfo.processInfo.environment,
                          sibling: instance(of: sibling),
                          me: me)
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

import AppKit
import Foundation
import Observation
import UserNotifications

/// Shows a banner even when the app is the one in front.
///
/// macOS files a notification silently while its own app is active, unless the
/// delegate says otherwise — which is exactly backwards for "Notify me when it
/// lands". The point of arming a render is to be told about it once you have
/// stopped watching, and "stopped watching" usually means you wandered off to
/// another tab of *this* app rather than out of it. Without this the armed
/// notification was posted, accepted, and never drawn.
///
/// Its own object because `UNUserNotificationCenter` holds the delegate weakly
/// and calls it off the main actor.
private final class ForegroundPresenter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }
}

/// Posts "your track is ready" notifications, and owns the permission that
/// lets them through.
///
/// The permission is modelled rather than fired and forgotten. A request whose
/// answer is thrown away leaves the app unable to tell "allowed" from "the
/// user said no eighteen months ago", and the difference is the whole
/// difference between a button that works and a button that lies.
@MainActor @Observable
final class NotificationService {
    /// How the user wants delivery to behave — the Settings window's say.
    /// Which *events* are worth a notification is decided at the call sites
    /// (`AppEnvironment.notify(for:)`), where the events live; this struct is
    /// only about what posting one looks like.
    struct Prefs {
        /// Gates `notifyIfInactive` — every notice the app raises on its own.
        /// `notify` (the armed, asked-for-by-hand path) ignores it: pressing
        /// "Notify me when it lands" is consent given after this toggle was.
        var enabled = true
        /// Deliver even while the app is frontmost.
        var alwaysDeliver = false
        var sound = true
        var dockBounce = true
    }

    /// A live read into Settings, defaulting to the historical behavior so
    /// tests and previews need no wiring.
    var prefs: @MainActor () -> Prefs = { Prefs() }

    /// What the system will currently let through. Refreshed at launch and
    /// after every request, so the UI can say "you have these turned off"
    /// rather than arming something that cannot fire.
    private(set) var authorization: UNAuthorizationStatus = .notDetermined

    /// Kept alive here: the notification centre's delegate is a weak
    /// reference, so a presenter created and dropped inline is a presenter
    /// that stops presenting the moment ARC notices.
    private let presenter = ForegroundPresenter()

    private var askedThisLaunch = false

    /// UNUserNotificationCenter misbehaves inside test hosts; stay inert there.
    private static let isTesting = NSClassFromString("XCTestCase") != nil

    init() {
        guard !Self.isTesting else { return }
        // Apple's guidance is to set this before the app finishes launching,
        // and the delivery this app cares about most arrives while the app is
        // frontmost — so it is set here, at construction, not lazily on first
        // use.
        UNUserNotificationCenter.current().delegate = presenter
    }

    /// Whether a notification posted right now would actually be shown.
    var isAllowed: Bool {
        switch authorization {
        case .authorized, .provisional, .ephemeral: true
        default: false
        }
    }

    /// The user has been asked and said no. Distinct from "not asked yet",
    /// because only one of the two can be fixed by asking again.
    var isDenied: Bool { authorization == .denied }

    func refresh() async {
        guard !Self.isTesting else { return }
        authorization = await UNUserNotificationCenter.current()
            .notificationSettings().authorizationStatus
    }

    /// Ask for permission at a moment the user will understand — pressing
    /// "Notify me when it lands" — and report whether we may post.
    ///
    /// Asking twice shows nothing: after the first answer the system returns
    /// the stored one without a prompt. So a denied user has to be sent to
    /// System Settings instead, which is what `isDenied` is for.
    @discardableResult
    func request() async -> Bool {
        guard !Self.isTesting else { return false }
        askedThisLaunch = true
        await refresh()
        if authorization == .notDetermined {
            _ = try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
            await refresh()
        }
        return isAllowed
    }

    /// Ask once per launch, in the background, for the notices the app raises
    /// on its own initiative. The armed button calls `request()` directly.
    func requestAuthorizationIfNeeded() {
        guard !Self.isTesting, !askedThisLaunch else { return }
        Task { await request() }
    }

    /// Notifications cannot re-prompt once refused, so the only route back is
    /// the Settings pane.
    func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:"
                            + "com.apple.Notifications-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Post only when the app is in the background — the default for every
    /// notice the app raises on its own initiative. A banner over the window
    /// you are already looking at tells you nothing you cannot see, unless
    /// the user has said they want it anyway (`Prefs.alwaysDeliver`).
    func notifyIfInactive(title: String, body: String) {
        let prefs = prefs()
        guard Self.deliversUnprompted(prefs: prefs,
                                      appActive: NSApp.isActive) else { return }
        post(title: title, body: body, prefs: prefs)
    }

    /// The `notifyIfInactive` decision, pure: an unprompted notice goes out
    /// when the master switch is on and the app is in the background — or in
    /// front with the user having asked for that too.
    static func deliversUnprompted(prefs: Prefs, appActive: Bool) -> Bool {
        prefs.enabled && (prefs.alwaysDeliver || !appActive)
    }

    /// Post whether or not the app is frontmost. Only for a notification the
    /// user armed by hand ("Notify me when it lands"): they asked to be told,
    /// and a render long enough to be worth arming is one you go and do
    /// something else during — including something else in this app. The
    /// master toggle does not apply here, for the same reason.
    func notify(title: String, body: String) {
        post(title: title, body: body, prefs: prefs())
    }

    private func post(title: String, body: String, prefs: Prefs) {
        guard !Self.isTesting else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = prefs.sound ? .default : nil
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
        if prefs.dockBounce {
            NSApp.requestUserAttention(.informationalRequest)
        }
    }
}

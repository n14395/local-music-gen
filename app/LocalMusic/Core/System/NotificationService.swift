import AppKit
import Foundation
import UserNotifications

/// Posts "your track is ready" notifications when the app is in the background.
@MainActor
final class NotificationService {
    private var authRequested = false

    /// UNUserNotificationCenter misbehaves inside test hosts; stay inert there.
    private static let isTesting = NSClassFromString("XCTestCase") != nil

    func requestAuthorizationIfNeeded() {
        guard !Self.isTesting, !authRequested else { return }
        authRequested = true
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notifyIfInactive(title: String, body: String) {
        guard !Self.isTesting, !NSApp.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
        NSApp.requestUserAttention(.informationalRequest)
    }
}

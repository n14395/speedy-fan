import Foundation
import AppKit
import UserNotifications

// Delivers user-facing messages as Notification Center banners, asking for
// permission lazily on first use. Falls back to a modal alert when
// notifications are denied or unavailable (e.g. running bare via `swift run`,
// where there is no bundle for UNUserNotificationCenter to attach to).

enum Notifier {
    /// `important` marks a message the user must not miss (the thermal
    /// failsafe): when notifications are denied it falls back to a modal
    /// alert. Everything else — "returned to automatic" and friends — is
    /// informational, and a modal interruption would be worse than silence,
    /// so those simply drop when they can't be a banner.
    static func post(title: String, body: String, important: Bool = false) {
        guard Bundle.main.bundleIdentifier != nil else {
            if important { DispatchQueue.main.async { alert(title, body) } }
            return
        }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else {
                if important { DispatchQueue.main.async { alert(title, body) } }
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            center.add(UNNotificationRequest(
                identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    /// Modal alert: used as the notification fallback and directly for
    /// conditions that demand immediate attention. Call on the main thread.
    static func alert(_ title: String, _ body: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = body
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

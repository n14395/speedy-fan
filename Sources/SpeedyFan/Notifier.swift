import Foundation
import AppKit
import UserNotifications

// Delivers user-facing messages as Notification Center banners, asking for
// permission lazily on first use. Falls back to a modal alert when
// notifications are denied or unavailable (e.g. running bare via `swift run`,
// where there is no bundle for UNUserNotificationCenter to attach to).

/// Everything SpeedyFan can notify about — one case per switch in Settings →
/// Notifications. Every event defaults to on; switching one off silences that
/// event entirely, including any modal fallback. (The alert for a *failed*
/// emergency restore is not an event: it cannot be switched off.)
enum NotificationEvent: String, CaseIterable {
    /// The thermal failsafe returned hot fans to automatic.
    case failsafe
    /// A fan is commanded to spin but isn't turning.
    case stuckFan
    /// "Maximum Fans At" engaged or released.
    case boost
    /// Manual control ended — the time limit ran out, or leftover manual
    /// state was cleaned up at launch.
    case returnToAuto

    var settingsKey: String {
        switch self {
        case .failsafe: return SettingsKey.notifyFailsafe
        case .stuckFan: return SettingsKey.notifyStuckFan
        case .boost: return SettingsKey.notifyBoost
        case .returnToAuto: return SettingsKey.notifyReturnToAuto
        }
    }

    /// Safety events fall back to a modal alert when banners are denied or
    /// unavailable; the rest are informational, where a modal interruption
    /// would be worse than silence, so they simply drop.
    var important: Bool {
        switch self {
        case .failsafe, .stuckFan: return true
        case .boost, .returnToAuto: return false
        }
    }

    var enabled: Bool {
        UserDefaults.standard.object(forKey: settingsKey) as? Bool ?? true
    }
}

enum Notifier {
    static func post(_ event: NotificationEvent, title: String, body: String) {
        guard event.enabled else { return }
        post(title: title, body: body, important: event.important)
    }

    private static func post(title: String, body: String, important: Bool) {
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
            if AppSettings.notificationSound { content.sound = .default }
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

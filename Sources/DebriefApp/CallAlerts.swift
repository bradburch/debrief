/// Seam over UNUserNotificationCenter so unit tests never construct it
/// (UNUserNotificationCenter.current() traps outside a bundled .app).
public protocol CallAlerting: AnyObject {
    func callDetected()
    func clear()
}

import UserNotifications
import OSLog

/// Real notification adapter. Constructed only from AppEnvironment.live()
/// (never in tests — see protocol doc comment).
final class CallAlerts: NSObject, CallAlerting, UNUserNotificationCenterDelegate {
    static let recordActionID = "record"
    static let categoryID = "call-detected"
    static let requestID = "call-detected"
    private static let logger = Logger(subsystem: "com.debrief.app", category: "alerts")

    /// Set by live() to route the notification's Record action into
    /// AppEnvironment.startRecording() on the main actor.
    var onRecord: (@MainActor () -> Void)?

    override init() {
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let record = UNNotificationAction(identifier: Self.recordActionID, title: "Record",
                                          options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.categoryID, actions: [record],
                                   intentIdentifiers: [], options: []),
        ])
        // A denied/failed permission degrades to "no pop-up" (menu-bar icon still shows
        // call state), but LOG the outcome — the original code discarded this result,
        // which hid that permission was simply off in System Settings (requestAuthorization
        // only prompts when status is .notDetermined; once denied it silently returns false).
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                Self.logger.error("requestAuthorization failed: \(error.localizedDescription, privacy: .public)")
            } else if !granted {
                Self.logger.warning("notifications not granted — enable Debrief in System Settings ▸ Notifications")
            } else {
                Self.logger.info("notifications authorized")
            }
        }
    }

    func callDetected() {
        let content = UNMutableNotificationContent()
        content.title = "Call detected"
        content.body = "Record this call with Debrief?"
        content.sound = .default  // authorization/willPresent request sound, but it only plays if set on the content
        content.categoryIdentifier = Self.categoryID
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: Self.requestID, content: content, trigger: nil)) { error in
                if let error {
                    Self.logger.error("callDetected add() failed: \(error.localizedDescription, privacy: .public)")
                } else {
                    Self.logger.info("callDetected notification posted")
                }
            }
    }

    func clear() {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [Self.requestID])
        center.removePendingNotificationRequests(withIdentifiers: [Self.requestID])
    }

    // Show the banner even though a menu-bar (LSUIElement) app counts as
    // "foreground" — without this the notification is silently swallowed.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        // Explicit Record button only. The default body click just dismisses:
        // "never auto-records" means an ambiguous click must not start capture.
        guard response.actionIdentifier == Self.recordActionID else { return }
        await MainActor.run { self.onRecord?() }
    }
}

import Foundation
import UserNotifications

struct CodexNotifier: Sendable {
    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                AppLog.write("notification authorization failed: \(error.localizedDescription)")
            } else {
                AppLog.write("notification authorization granted=\(granted)")
            }
        }
    }

    func send(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "dev.codexbar.notification.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                AppLog.write("notification delivery failed: \(error.localizedDescription)")
            }
        }
    }
}

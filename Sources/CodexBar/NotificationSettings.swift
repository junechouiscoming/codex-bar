import Foundation

@MainActor
final class NotificationSettings: ObservableObject {
    @Published var tokenNotificationsEnabled: Bool {
        didSet { UserDefaults.standard.set(tokenNotificationsEnabled, forKey: tokenNotificationsKey) }
    }

    @Published var quotaNotificationsEnabled: Bool {
        didSet { UserDefaults.standard.set(quotaNotificationsEnabled, forKey: quotaNotificationsKey) }
    }

    private let tokenNotificationsKey = "dev.codexbar.notifications.token.enabled"
    private let quotaNotificationsKey = "dev.codexbar.notifications.quota.enabled"

    init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: tokenNotificationsKey) == nil {
            defaults.set(true, forKey: tokenNotificationsKey)
        }
        if defaults.object(forKey: quotaNotificationsKey) == nil {
            defaults.set(true, forKey: quotaNotificationsKey)
        }

        tokenNotificationsEnabled = defaults.bool(forKey: tokenNotificationsKey)
        quotaNotificationsEnabled = defaults.bool(forKey: quotaNotificationsKey)
    }
}

import Foundation
import UserNotifications

/// Local notifications when research waits for review or an episode is ready.
/// Permission is requested on the first real run, never at launch or during tests.
enum Notifier {
    private static var isTesting: Bool { KeychainStore.isDisabled }

    static func requestPermissionIfNeeded() {
        guard !isTesting else { return }
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
            }
        }
    }

    static func post(title: String, body: String) {
        guard !isTesting else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}

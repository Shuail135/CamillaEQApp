import Foundation
import UserNotifications

@MainActor
final class NotificationManager {
    func requestAuthorization() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    func activated() { post("CamillaApp activated") }
    func deactivated() { post("CamillaApp deactivated") }

    private func post(_ text: String) {
        let content = UNMutableNotificationContent()
        content.title = text
        content.body = ""
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

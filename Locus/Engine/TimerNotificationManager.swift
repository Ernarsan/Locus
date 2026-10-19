import Foundation
import UserNotifications

protocol NotificationManagerProtocol: AnyObject {
    func requestAuthorization() async -> Bool
    func scheduleTimerExpiry(at date: Date, body: String)
    func cancelTimerExpiry()
}

final class TimerNotificationManager: NotificationManagerProtocol {
    static let shared = TimerNotificationManager()
    private let notificationId = "com.chrismack.locus.timer.expiry"

    func requestAuthorization() async -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            return granted
        } catch {
            return false
        }
    }

    func scheduleTimerExpiry(at date: Date, body: String) {
        cancelTimerExpiry()

        let timeInterval = date.timeIntervalSinceNow
        guard timeInterval > 0 else { return }

        let content = UNMutableNotificationContent()
        content.title = "Locus"
        content.body = body
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: timeInterval, repeats: false)
        let request = UNNotificationRequest(identifier: notificationId, content: content, trigger: trigger)

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                NSLog("[Locus] Failed to schedule notification: %@", error.localizedDescription)
            }
        }
    }

    func cancelTimerExpiry() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [notificationId])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [notificationId])
    }
}

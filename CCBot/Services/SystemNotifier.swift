// CCBot/Services/SystemNotifier.swift
import Foundation
import UserNotifications

@MainActor
final class SystemNotifier {
    static let shared = SystemNotifier()

    private init() {}

    nonisolated func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    func notifyCompletion(project: String, message: String) {
        let plain = stripMarkdown(message)
        notify(
            title: "✅ [\(project)] 任务完成",
            body: String(plain.prefix(100))
        )
    }
}

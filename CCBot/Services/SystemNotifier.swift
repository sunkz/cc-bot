// CCBot/Services/SystemNotifier.swift
import Foundation
import UserNotifications

@MainActor
final class SystemNotifier {
    static let shared = SystemNotifier()

    private let delegateHandler = NotificationDelegateHandler()

    private init() {}

    nonisolated func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func setup() {
        UNUserNotificationCenter.current().delegate = delegateHandler
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
}

private final class NotificationDelegateHandler: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

// CCBot/Utilities/NotificationPreferences.swift
import Foundation

enum NotificationPreferences {
    static var systemEnabled: Bool {
        UserDefaults.standard.object(forKey: "systemNotifyEnabled") as? Bool ?? true
    }
    static var telegramEnabled: Bool {
        UserDefaults.standard.object(forKey: "telegramNotifyEnabled") as? Bool ?? true
    }
}

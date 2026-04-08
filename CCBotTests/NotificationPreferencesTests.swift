// CCBotTests/NotificationPreferencesTests.swift
import XCTest
@testable import CCBot

final class NotificationPreferencesTests: XCTestCase {
    private let systemKey = "systemNotifyEnabled"
    private let telegramKey = "telegramNotifyEnabled"

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: systemKey)
        UserDefaults.standard.removeObject(forKey: telegramKey)
        super.tearDown()
    }

    func testDefaultValues() {
        UserDefaults.standard.removeObject(forKey: systemKey)
        UserDefaults.standard.removeObject(forKey: telegramKey)
        XCTAssertTrue(NotificationPreferences.systemEnabled)
        XCTAssertTrue(NotificationPreferences.telegramEnabled)
    }

    func testExplicitlySet() {
        UserDefaults.standard.set(false, forKey: systemKey)
        UserDefaults.standard.set(false, forKey: telegramKey)
        XCTAssertFalse(NotificationPreferences.systemEnabled)
        XCTAssertFalse(NotificationPreferences.telegramEnabled)
    }
}

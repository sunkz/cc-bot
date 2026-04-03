import XCTest
@testable import CCBot

final class TelegramBotTests: XCTestCase {

    func testCompletionMessageFormat() {
        let msg = TelegramBot.formatCompletion(project: "myapp", message: "Done building the feature.")
        XCTAssertTrue(msg.hasPrefix("✅"))
        XCTAssertTrue(msg.contains("myapp"))
        XCTAssertTrue(msg.contains("任务完成"))
        XCTAssertTrue(msg.contains("Done building"))
    }

    func testToolConfirmationFormat() {
        let msg = TelegramBot.formatToolConfirmation(
            project: "myapp",
            message: "Claude needs your permission to use Bash"
        )
        XCTAssertTrue(msg.hasPrefix("⏳"))
        XCTAssertTrue(msg.contains("myapp"))
        XCTAssertTrue(msg.contains("需要确认"))
        XCTAssertTrue(msg.contains("Claude needs your permission to use Bash"))
    }

    func testNotificationMessageFormat() {
        let msg = TelegramBot.formatNotification(project: "myapp", message: "Running tests")
        XCTAssertTrue(msg.hasPrefix("🔔"))
        XCTAssertTrue(msg.contains("myapp"))
        XCTAssertFalse(msg.contains("任务完成"))
        XCTAssertTrue(msg.contains("Running tests"))
    }
}

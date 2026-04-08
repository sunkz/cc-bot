import XCTest
@testable import CCBot

final class MessageFormatterTests: XCTestCase {
    func testPrepareWithDefaultLength() {
        let long = String(repeating: "a", count: 300)
        let result = MessageFormatter.prepare(long)
        XCTAssertEqual(result.count, 200)
    }

    func testPrepareWithCustomLength() {
        let result = MessageFormatter.prepare("hello world", maxLength: 5)
        XCTAssertEqual(result, "hello")
    }

    func testStripMarkdownHTML() {
        let result = MessageFormatter.prepare("<b>bold</b> and <i>italic</i>")
        XCTAssertEqual(result, "bold and italic")
    }

    func testStripMarkdownLists() {
        let input = "1. first\n2. second\n- bullet\n+ plus"
        let result = MessageFormatter.prepare(input)
        XCTAssertEqual(result, "first\nsecond\nbullet\nplus")
    }

    func testStripMarkdownHorizontalRule() {
        let input = "above\n---\nbelow"
        let result = MessageFormatter.prepare(input)
        XCTAssertEqual(result, "above\n\nbelow")
    }

    func testNotificationTitleByKind() {
        XCTAssertEqual(
            MessageFormatter.notificationTitle(kind: .completion, source: "Codex", project: "demo"),
            "✅ [Codex] [demo] 已完成"
        )
        XCTAssertEqual(
            MessageFormatter.notificationTitle(kind: .approval, source: "Claude", project: "demo"),
            "⏳ [Claude] [demo] 待确认"
        )
    }

    func testNotificationBodyDetail() {
        let result = MessageFormatter.notificationBody(detail: "Claude needs your permission to use Bash")
        XCTAssertTrue(result.contains("Bash"))
    }

    func testNotificationBodySmartTruncateKeepsTail() {
        let detail = "error at /Users/a/very/long/path/main.swift line 9999, reason timeout happened in shell command"
        let result = MessageFormatter.notificationBody(detail: detail, maxDetailLength: 40)
        XCTAssertTrue(result.contains("…"))
        XCTAssertTrue(result.hasSuffix("command"))
    }
}

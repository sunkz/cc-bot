import XCTest
@testable import CCBot

final class CodexNotifyInstallerTests: XCTestCase {

    func testMergeIntoEmptyConfig() throws {
        let result = try CodexNotifyInstaller.mergeNotify(into: Data())
        let text = String(decoding: result, as: UTF8.self)

        XCTAssertTrue(text.contains(#"notify = ["bash", ""#))
        XCTAssertTrue(text.contains("cc-bot-notify.sh"))
    }

    func testMergeInsertsBeforeFirstTable() throws {
        let existing = """
        model = "gpt-5.4"

        [projects."/tmp/demo"]
        trust_level = "trusted"
        """.data(using: .utf8)!

        let result = try CodexNotifyInstaller.mergeNotify(into: existing)
        let text = String(decoding: result, as: UTF8.self)
        let notifyIndex = try XCTUnwrap(text.range(of: "notify = ")?.lowerBound)
        let tableIndex = try XCTUnwrap(text.range(of: #"[projects."/tmp/demo"]"#)?.lowerBound)

        XCTAssertLessThan(notifyIndex, tableIndex)
    }

    func testMergeDoesNotDuplicateOwnNotify() throws {
        let once = try CodexNotifyInstaller.mergeNotify(into: Data())
        let twice = try CodexNotifyInstaller.mergeNotify(into: once)
        let text = String(decoding: twice, as: UTF8.self)

        XCTAssertEqual(text.components(separatedBy: "\n").filter { $0.contains("notify = ") }.count, 1)
    }

    func testMergeRejectsExistingForeignNotify() throws {
        let existing = """
        notify = ["terminal-notifier", "-message", "done"]
        model = "gpt-5.4"
        """.data(using: .utf8)!

        XCTAssertThrowsError(try CodexNotifyInstaller.mergeNotify(into: existing)) { error in
            XCTAssertEqual(error as? CodexNotifyInstaller.InstallError, .notifyAlreadyConfigured)
        }
    }

    func testRemoveOnlyDeletesCCBotNotify() throws {
        let config = try CodexNotifyInstaller.mergeNotify(into: """
        model = "gpt-5.4"

        [projects."/tmp/demo"]
        trust_level = "trusted"
        """.data(using: .utf8)!)

        let cleaned = try CodexNotifyInstaller.removeNotify(from: config)
        let text = String(decoding: cleaned, as: UTF8.self)

        XCTAssertFalse(text.contains("cc-bot-notify.sh"))
        XCTAssertTrue(text.contains(#"[projects."/tmp/demo"]"#))
    }

    func testRemoveForeignNotifyNoop() throws {
        let original = """
        notify = ["terminal-notifier", "-message", "done"]
        model = "gpt-5.4"
        """.data(using: .utf8)!

        let cleaned = try CodexNotifyInstaller.removeNotify(from: original)
        XCTAssertEqual(String(decoding: cleaned, as: UTF8.self), String(decoding: original, as: UTF8.self))
    }
}

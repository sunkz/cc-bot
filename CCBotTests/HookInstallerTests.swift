import XCTest
@testable import CCBot

final class HookInstallerTests: XCTestCase {

    func testMergeIntoEmptySettings() throws {
        let empty = Data("{}".utf8)
        let result = try HookInstaller.mergeHooks(into: empty)
        let json = try JSONSerialization.jsonObject(with: result) as! [String: Any]
        let hooks = json["hooks"] as! [String: Any]
        XCTAssertNotNil(hooks["Notification"])
        XCTAssertNotNil(hooks["Stop"])
        XCTAssertNil(hooks["PreToolUse"])
    }

    func testMergePreservesExistingKeys() throws {
        let existing = """
        {"permissions":{"allow":["Bash"]},"hooks":{"Notification":[]}}
        """.data(using: .utf8)!
        let result = try HookInstaller.mergeHooks(into: existing)
        let json = try JSONSerialization.jsonObject(with: result) as! [String: Any]
        XCTAssertNotNil(json["permissions"])
        let hooks = json["hooks"] as! [String: Any]
        let notification = hooks["Notification"] as! [[String: Any]]
        XCTAssertTrue(notification.count >= 1) // cc-bot entry appended
    }

    func testMergeDoesNotDuplicateEntry() throws {
        let existing = Data("{}".utf8)
        let once = try HookInstaller.mergeHooks(into: existing)
        let twice = try HookInstaller.mergeHooks(into: once)
        let json = try JSONSerialization.jsonObject(with: twice) as! [String: Any]
        let hooks = json["hooks"] as! [String: Any]
        let notification = hooks["Notification"] as! [[String: Any]]
        let ccbotEntries = notification.filter { entry in
            let hooksList = entry["hooks"] as? [[String: Any]] ?? []
            return hooksList.contains { ($0["command"] as? String)?.contains("cc-bot") == true }
        }
        XCTAssertEqual(ccbotEntries.count, 1)
    }

    func testRemoveHooksKeepsForeignEntries() throws {
        let existing = """
        {
          "hooks": {
            "Notification": [
              {
                "matcher": "",
                "hooks": [
                  {"type": "command", "command": "bash ~/.claude/hooks/cc-bot-notification.sh"},
                  {"type": "command", "command": "echo foreign"}
                ]
              }
            ],
            "Stop": [
              {
                "matcher": "",
                "hooks": [
                  {"type": "command", "command": "bash ~/.claude/hooks/cc-bot-stop.sh"}
                ]
              }
            ]
          }
        }
        """.data(using: .utf8)!

        let cleaned = try HookInstaller.removeHooks(from: existing)
        let json = try JSONSerialization.jsonObject(with: cleaned) as! [String: Any]
        let hooks = json["hooks"] as? [String: Any]
        let notification = hooks?["Notification"] as? [[String: Any]]
        let commands = notification?.flatMap { entry in
            (entry["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
        } ?? []

        XCTAssertTrue(commands.contains("echo foreign"))
        XCTAssertFalse(commands.contains("bash ~/.claude/hooks/cc-bot-notification.sh"))
        XCTAssertNil(hooks?["Stop"])
    }

    func testMergeRejectsInvalidSettingsJSON() {
        let invalid = Data(#"{"hooks":"#.utf8)

        XCTAssertThrowsError(try HookInstaller.mergeHooks(into: invalid)) { error in
            XCTAssertEqual(error as? HookInstaller.InstallError, .invalidSettingsJSON)
        }
    }
}

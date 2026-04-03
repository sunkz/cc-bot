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
}

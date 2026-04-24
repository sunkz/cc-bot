import XCTest
@testable import CCBot

final class HookInstallerTests: XCTestCase {
    private struct Sandbox {
        let root: URL
        let hooksDir: URL
        let settingsPath: URL
        let notificationPath: URL
        let stopPath: URL
    }

    private func makeSandbox() throws -> Sandbox {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let claudeDir = root.appendingPathComponent(".claude", isDirectory: true)
        let hooksDir = claudeDir.appendingPathComponent("hooks", isDirectory: true)
        try fm.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        return Sandbox(
            root: root,
            hooksDir: hooksDir,
            settingsPath: claudeDir.appendingPathComponent("settings.json"),
            notificationPath: hooksDir.appendingPathComponent("cc-bot-notification.sh"),
            stopPath: hooksDir.appendingPathComponent("cc-bot-stop.sh")
        )
    }

    private func writeScript(_ content: String, to path: URL) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: path, atomically: true, encoding: .utf8)
    }

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

    func testInstallRollsBackScriptsWhenSettingsJSONIsInvalid() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        try #"{"hooks":"#.write(to: sandbox.settingsPath, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(
            try HookInstaller.install(fileManager: .default, homeDirectory: sandbox.root)
        ) { error in
            XCTAssertEqual(error as? HookInstaller.InstallError, .invalidSettingsJSON)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.notificationPath.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.stopPath.path))
        XCTAssertEqual(try String(contentsOf: sandbox.settingsPath, encoding: .utf8), #"{"hooks":"#)
    }

    func testUninstallRollsBackScriptsWhenSettingsJSONIsInvalid() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        try writeScript("notification-original", to: sandbox.notificationPath)
        try writeScript("stop-original", to: sandbox.stopPath)
        try #"{"hooks":"#.write(to: sandbox.settingsPath, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(
            try HookInstaller.uninstall(fileManager: .default, homeDirectory: sandbox.root)
        ) { error in
            XCTAssertEqual(error as? HookInstaller.InstallError, .invalidSettingsJSON)
        }

        XCTAssertEqual(try String(contentsOf: sandbox.notificationPath, encoding: .utf8), "notification-original")
        XCTAssertEqual(try String(contentsOf: sandbox.stopPath, encoding: .utf8), "stop-original")
        XCTAssertEqual(try String(contentsOf: sandbox.settingsPath, encoding: .utf8), #"{"hooks":"#)
    }

    func testIsInstalledRequiresBothScriptsAndRegisteredHooks() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }

        XCTAssertFalse(HookInstaller.isInstalled(fileManager: .default, homeDirectory: sandbox.root))

        try writeScript("#!/bin/bash\nexit 0\n", to: sandbox.notificationPath)
        XCTAssertFalse(HookInstaller.isInstalled(fileManager: .default, homeDirectory: sandbox.root))

        try writeScript("#!/bin/bash\nexit 0\n", to: sandbox.stopPath)
        XCTAssertFalse(HookInstaller.isInstalled(fileManager: .default, homeDirectory: sandbox.root))

        let notificationOnly = """
        {
          "hooks": {
            "Notification": [
              {
                "matcher": "",
                "hooks": [
                  {"type": "command", "command": "bash ~/.claude/hooks/cc-bot-notification.sh"}
                ]
              }
            ]
          }
        }
        """
        try notificationOnly.write(to: sandbox.settingsPath, atomically: true, encoding: .utf8)
        XCTAssertFalse(HookInstaller.isInstalled(fileManager: .default, homeDirectory: sandbox.root))

        let installedSettings = try HookInstaller.mergeHooks(into: Data("{}".utf8))
        try installedSettings.write(to: sandbox.settingsPath, options: .atomic)
        XCTAssertTrue(HookInstaller.isInstalled(fileManager: .default, homeDirectory: sandbox.root))
    }
}

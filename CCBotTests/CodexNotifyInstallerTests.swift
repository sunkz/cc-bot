import XCTest
@testable import CCBot

final class CodexNotifyInstallerTests: XCTestCase {
    private struct Sandbox {
        let root: URL
        let hooksDir: URL
        let configPath: URL
        let hooksPath: URL
        let notifyScriptPath: URL
        let permissionScriptPath: URL
    }

    private func makeSandbox() throws -> Sandbox {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let codexDir = root.appendingPathComponent(".codex", isDirectory: true)
        let hooksDir = codexDir.appendingPathComponent("hooks", isDirectory: true)
        try fm.createDirectory(at: codexDir, withIntermediateDirectories: true)
        return Sandbox(
            root: root,
            hooksDir: hooksDir,
            configPath: codexDir.appendingPathComponent("config.toml"),
            hooksPath: codexDir.appendingPathComponent("hooks.json"),
            notifyScriptPath: hooksDir.appendingPathComponent("cc-bot-notify.sh"),
            permissionScriptPath: hooksDir.appendingPathComponent("cc-bot-permission-request.sh")
        )
    }

    private func writeScript(_ content: String, to path: URL) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: path, atomically: true, encoding: .utf8)
    }

    private func installedConfigData() throws -> Data {
        try CodexNotifyInstaller.mergeHooksFeature(into: CodexNotifyInstaller.mergeNotify(into: Data()))
    }

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

    func testMergePermissionRequestHookIntoEmptyHooksFile() throws {
        let result = try CodexNotifyInstaller.mergePermissionRequestHook(into: Data())
        let json = try JSONSerialization.jsonObject(with: result) as! [String: Any]
        let hooks = try XCTUnwrap(json["hooks"] as? [String: Any])
        let entries = try XCTUnwrap(hooks["PermissionRequest"] as? [[String: Any]])
        let first = try XCTUnwrap(entries.first)
        let matcher = try XCTUnwrap(first["matcher"] as? String)
        let hookList = try XCTUnwrap(first["hooks"] as? [[String: Any]])
        let hook = try XCTUnwrap(hookList.first)

        XCTAssertEqual(matcher, ".*")
        XCTAssertEqual(hook["type"] as? String, "command")
        XCTAssertEqual(hook["command"] as? String, "bash ~/.codex/hooks/cc-bot-permission-request.sh")
    }

    func testMergePermissionRequestHookDoesNotDuplicateOwnEntry() throws {
        let once = try CodexNotifyInstaller.mergePermissionRequestHook(into: Data())
        let twice = try CodexNotifyInstaller.mergePermissionRequestHook(into: once)
        let json = try JSONSerialization.jsonObject(with: twice) as! [String: Any]
        let hooks = try XCTUnwrap(json["hooks"] as? [String: Any])
        let entries = try XCTUnwrap(hooks["PermissionRequest"] as? [[String: Any]])
        let ccbotEntries = entries.filter { entry in
            let hookList = entry["hooks"] as? [[String: Any]] ?? []
            return hookList.contains { ($0["command"] as? String) == "bash ~/.codex/hooks/cc-bot-permission-request.sh" }
        }

        XCTAssertEqual(ccbotEntries.count, 1)
    }

    func testRemovePermissionRequestHookKeepsForeignEntries() throws {
        let existing = """
        {
          "hooks": {
            "PermissionRequest": [
              {
                "matcher": "Bash",
                "hooks": [
                  {"type": "command", "command": "bash ~/.codex/hooks/cc-bot-permission-request.sh"},
                  {"type": "command", "command": "echo foreign"}
                ]
              }
            ]
          }
        }
        """.data(using: .utf8)!

        let cleaned = try CodexNotifyInstaller.removePermissionRequestHook(from: existing)
        let json = try JSONSerialization.jsonObject(with: cleaned) as! [String: Any]
        let hooks = json["hooks"] as? [String: Any]
        let entries = hooks?["PermissionRequest"] as? [[String: Any]]
        let commands = entries?.flatMap { entry in
            (entry["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
        } ?? []

        XCTAssertTrue(commands.contains("echo foreign"))
        XCTAssertFalse(commands.contains("bash ~/.codex/hooks/cc-bot-permission-request.sh"))
    }

    func testMergeHooksFeatureIntoConfigWithoutSection() throws {
        let result = try CodexNotifyInstaller.mergeHooksFeature(into: """
        model = "gpt-5.4"
        """.data(using: .utf8)!)
        let text = String(decoding: result, as: UTF8.self)

        XCTAssertTrue(text.contains("[features]"))
        XCTAssertTrue(text.contains("codex_hooks = true"))
    }

    func testMergeHooksFeatureUpdatesExistingFlagToTrue() throws {
        let result = try CodexNotifyInstaller.mergeHooksFeature(into: """
        [features]
        codex_hooks = false
        """.data(using: .utf8)!)
        let text = String(decoding: result, as: UTF8.self)

        XCTAssertFalse(text.contains("codex_hooks = false"))
        XCTAssertTrue(text.contains("codex_hooks = true"))
    }

    func testInstallRollsBackArtifactsWhenHooksJSONIsInvalid() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        let originalConfig = """
        model = "gpt-5.4"
        """
        try originalConfig.write(to: sandbox.configPath, atomically: true, encoding: .utf8)
        try #"{"hooks":"#.write(to: sandbox.hooksPath, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(
            try CodexNotifyInstaller.install(fileManager: .default, homeDirectory: sandbox.root)
        ) { error in
            XCTAssertEqual(error as? CodexNotifyInstaller.InstallError, .invalidHooksJSON)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.notifyScriptPath.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.permissionScriptPath.path))
        XCTAssertEqual(try String(contentsOf: sandbox.configPath, encoding: .utf8), originalConfig)
        XCTAssertEqual(try String(contentsOf: sandbox.hooksPath, encoding: .utf8), #"{"hooks":"#)
    }

    func testUninstallRollsBackArtifactsWhenHooksJSONIsInvalid() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        try writeScript("notify-original", to: sandbox.notifyScriptPath)
        try writeScript("permission-original", to: sandbox.permissionScriptPath)
        try installedConfigData().write(to: sandbox.configPath, options: .atomic)
        try #"{"hooks":"#.write(to: sandbox.hooksPath, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(
            try CodexNotifyInstaller.uninstall(fileManager: .default, homeDirectory: sandbox.root)
        ) { error in
            XCTAssertEqual(error as? CodexNotifyInstaller.InstallError, .invalidHooksJSON)
        }

        XCTAssertEqual(try String(contentsOf: sandbox.notifyScriptPath, encoding: .utf8), "notify-original")
        XCTAssertEqual(try String(contentsOf: sandbox.permissionScriptPath, encoding: .utf8), "permission-original")
        XCTAssertEqual(
            try String(contentsOf: sandbox.configPath, encoding: .utf8),
            String(decoding: try installedConfigData(), as: UTF8.self)
        )
        XCTAssertEqual(try String(contentsOf: sandbox.hooksPath, encoding: .utf8), #"{"hooks":"#)
    }

    func testIsInstalledRequiresScriptsNotifyFeatureAndPermissionRequestHook() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }

        XCTAssertFalse(CodexNotifyInstaller.isInstalled(fileManager: .default, homeDirectory: sandbox.root))

        try writeScript("#!/bin/bash\nexit 0\n", to: sandbox.notifyScriptPath)
        try installedConfigData().write(to: sandbox.configPath, options: .atomic)
        XCTAssertFalse(CodexNotifyInstaller.isInstalled(fileManager: .default, homeDirectory: sandbox.root))

        try writeScript("#!/bin/bash\nexit 0\n", to: sandbox.permissionScriptPath)
        XCTAssertFalse(CodexNotifyInstaller.isInstalled(fileManager: .default, homeDirectory: sandbox.root))

        let installedHooks = try CodexNotifyInstaller.mergePermissionRequestHook(into: Data("{}".utf8))
        try installedHooks.write(to: sandbox.hooksPath, options: .atomic)
        XCTAssertTrue(CodexNotifyInstaller.isInstalled(fileManager: .default, homeDirectory: sandbox.root))
    }
}

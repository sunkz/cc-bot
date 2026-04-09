// CCBot/Utilities/HookInstaller.swift
import Foundation

struct HookInstaller {
    static let hooksDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/hooks")
    static let settingsPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/settings.json")

    static var notificationScript: String {
        """
        #!/bin/bash
        TOKEN=$(cat ~/.claude/hooks/.ccbot-auth 2>/dev/null)
        INPUT=$(cat)
        echo "$INPUT" | curl -sf -X POST http://localhost:\(Constants.serverPort)/hook/notification \
          -H 'Content-Type: application/json' \
          -H "Authorization: Bearer $TOKEN" \
          -d @- --max-time 5 &
        exit 0
        """
    }

    static var stopScript: String {
        """
        #!/bin/bash
        TOKEN=$(cat ~/.claude/hooks/.ccbot-auth 2>/dev/null)
        INPUT=$(cat)
        if echo "$INPUT" | grep -q '"stop_hook_active"[[:space:]]*:[[:space:]]*true'; then exit 0; fi
        echo "$INPUT" | curl -sf -X POST http://localhost:\(Constants.serverPort)/hook/stop \
          -H 'Content-Type: application/json' \
          -H "Authorization: Bearer $TOKEN" \
          -d @- --max-time 5 &
        exit 0
        """
    }

    enum InstallError: Error {
        case claudeNotInstalled
        case permissionDenied
    }

    static func install() throws {
        let claudeSettings = settingsPath
        let fm = FileManager.default

        guard fm.fileExists(atPath: fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude").path) else {
            throw InstallError.claudeNotInstalled
        }

        // Write hook scripts
        try fm.createDirectory(at: hooksDir, withIntermediateDirectories: true)
        let notificationPath = hooksDir.appendingPathComponent("cc-bot-notification.sh")
        let stopPath = hooksDir.appendingPathComponent("cc-bot-stop.sh")

        try notificationScript.write(to: notificationPath, atomically: true, encoding: .utf8)
        try stopScript.write(to: stopPath, atomically: true, encoding: .utf8)

        // chmod +x
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: notificationPath.path)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stopPath.path)

        // Merge into settings.json
        let existing = (try? Data(contentsOf: claudeSettings)) ?? Data("{}".utf8)
        let merged = try mergeHooks(into: existing)
        try FileUtilities.writeWithBackupRollback(merged, to: claudeSettings, fileManager: fm)
    }

    static func mergeHooks(into data: Data) throws -> Data {
        var json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        var hooks = json["hooks"] as? [String: Any] ?? [:]

        let notificationCommand = "bash ~/.claude/hooks/cc-bot-notification.sh"
        let stopCommand = "bash ~/.claude/hooks/cc-bot-stop.sh"

        func upsert(key: String, command: String) {
            var entries = hooks[key] as? [[String: Any]] ?? []
            let alreadyPresent = entries.contains { entry in
                let hooksList = entry["hooks"] as? [[String: Any]] ?? []
                return hooksList.contains { ($0["command"] as? String) == command }
            }
            if !alreadyPresent {
                entries.append(["matcher": "", "hooks": [["type": "command", "command": command]]])
            }
            hooks[key] = entries
        }

        upsert(key: "Notification", command: notificationCommand)
        upsert(key: "Stop", command: stopCommand)

        json["hooks"] = hooks
        return try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    }

    static func uninstall() throws {
        let fm = FileManager.default

        // Remove hook scripts
        let notificationPath = hooksDir.appendingPathComponent("cc-bot-notification.sh")
        let stopPath = hooksDir.appendingPathComponent("cc-bot-stop.sh")
        try FileUtilities.removeItemIfExists(notificationPath, fileManager: fm)
        try FileUtilities.removeItemIfExists(stopPath, fileManager: fm)
        // Clean up legacy PreToolUse script
        try FileUtilities.removeItemIfExists(hooksDir.appendingPathComponent("cc-bot-pre-tool-use.sh"), fileManager: fm)

        // Remove hook entries from settings.json
        guard fm.fileExists(atPath: settingsPath.path) else { return }
        let existing = try Data(contentsOf: settingsPath)
        let cleaned = try removeHooks(from: existing)
        try FileUtilities.writeWithBackupRollback(cleaned, to: settingsPath, fileManager: fm)
    }

    static func removeHooks(from data: Data) throws -> Data {
        var json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard var hooks = json["hooks"] as? [String: Any] else { return data }

        let notificationCommand = "bash ~/.claude/hooks/cc-bot-notification.sh"
        let preToolUseCommand = "bash ~/.claude/hooks/cc-bot-pre-tool-use.sh"
        let stopCommand = "bash ~/.claude/hooks/cc-bot-stop.sh"

        func remove(key: String, command: String) {
            guard var entries = hooks[key] as? [[String: Any]] else { return }
            entries = entries.compactMap { entry in
                var mutableEntry = entry
                var hooksList = mutableEntry["hooks"] as? [[String: Any]] ?? []
                hooksList.removeAll { ($0["command"] as? String) == command }
                guard !hooksList.isEmpty else { return nil }
                mutableEntry["hooks"] = hooksList
                return mutableEntry
            }
            if entries.isEmpty {
                hooks.removeValue(forKey: key)
            } else {
                hooks[key] = entries
            }
        }

        remove(key: "Notification", command: notificationCommand)
        remove(key: "PreToolUse", command: preToolUseCommand) // clean up legacy
        remove(key: "Stop", command: stopCommand)

        if hooks.isEmpty {
            json.removeValue(forKey: "hooks")
        } else {
            json["hooks"] = hooks
        }
        return try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    }

    static func isInstalled() -> Bool {
        let fm = FileManager.default
        let notificationPath = hooksDir.appendingPathComponent("cc-bot-notification.sh")
        return fm.fileExists(atPath: notificationPath.path)
    }

    /// Overwrite hook scripts with latest version if already installed.
    static func updateScriptsIfInstalled() throws {
        guard isInstalled() else { return }
        let fm = FileManager.default
        let paths: [(URL, String)] = [
            (hooksDir.appendingPathComponent("cc-bot-notification.sh"), notificationScript),
            (hooksDir.appendingPathComponent("cc-bot-stop.sh"), stopScript),
        ]
        // Clean up legacy PreToolUse script
        try FileUtilities.removeItemIfExists(hooksDir.appendingPathComponent("cc-bot-pre-tool-use.sh"), fileManager: fm)
        for (url, content) in paths {
            try content.write(to: url, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }

}

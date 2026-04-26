// CCBot/Utilities/HookInstaller.swift
import Foundation

struct HookInstaller {
    private struct Paths {
        let claudeDir: URL
        let hooksDir: URL
        let settingsPath: URL
        let notificationPath: URL
        let stopPath: URL
        let legacyPreToolUsePath: URL
    }

    private static func paths(for homeDirectory: URL) -> Paths {
        let claudeDir = homeDirectory.appendingPathComponent(".claude", isDirectory: true)
        let hooksDir = claudeDir.appendingPathComponent("hooks", isDirectory: true)
        return Paths(
            claudeDir: claudeDir,
            hooksDir: hooksDir,
            settingsPath: claudeDir.appendingPathComponent("settings.json"),
            notificationPath: hooksDir.appendingPathComponent("cc-bot-notification.sh"),
            stopPath: hooksDir.appendingPathComponent("cc-bot-stop.sh"),
            legacyPreToolUsePath: hooksDir.appendingPathComponent("cc-bot-pre-tool-use.sh")
        )
    }

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

    enum InstallError: Error, Equatable {
        case claudeNotInstalled
        case invalidSettingsJSON
    }

    static func install(
        fileManager fm: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws {
        let paths = paths(for: homeDirectory)

        guard fm.fileExists(atPath: paths.claudeDir.path) else {
            throw InstallError.claudeNotInstalled
        }

        let existing = (try? Data(contentsOf: paths.settingsPath)) ?? Data("{}".utf8)
        let merged = try mergeHooks(into: existing)
        let snapshots = try FileUtilities.captureSnapshots(
            for: [paths.notificationPath, paths.stopPath, paths.settingsPath],
            fileManager: fm
        )

        do {
            try writeScripts(fileManager: fm, paths: paths)
            try FileUtilities.writeWithBackupRollback(merged, to: paths.settingsPath, fileManager: fm)
        } catch {
            try? FileUtilities.restoreSnapshots(snapshots, fileManager: fm)
            throw error
        }
    }

    static func mergeHooks(into data: Data) throws -> Data {
        var json = try parseSettingsJSON(from: data)
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

    static func uninstall(
        fileManager fm: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws {
        let paths = paths(for: homeDirectory)
        let hadSettings = fm.fileExists(atPath: paths.settingsPath.path)
        let cleanedSettings: Data? =
            if hadSettings {
                try removableSettingsData(afterRemovingManagedHooksFrom: Data(contentsOf: paths.settingsPath))
            } else {
                nil
            }
        let snapshots = try FileUtilities.captureSnapshots(
            for: [paths.notificationPath, paths.stopPath, paths.legacyPreToolUsePath, paths.settingsPath],
            fileManager: fm
        )

        do {
            try FileUtilities.removeItemIfExists(paths.notificationPath, fileManager: fm)
            try FileUtilities.removeItemIfExists(paths.stopPath, fileManager: fm)
            try FileUtilities.removeItemIfExists(paths.legacyPreToolUsePath, fileManager: fm)
            if hadSettings {
                try FileUtilities.writeOrRemoveItem(cleanedSettings, to: paths.settingsPath, fileManager: fm)
            }
        } catch {
            try? FileUtilities.restoreSnapshots(snapshots, fileManager: fm)
            throw error
        }

        try? FileUtilities.removeDirectoryIfEmpty(paths.hooksDir, fileManager: fm)
    }

    static func removeHooks(from data: Data) throws -> Data {
        var json = try parseSettingsJSON(from: data)
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

    static func isInstalled(
        fileManager fm: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        let paths = paths(for: homeDirectory)
        guard fm.fileExists(atPath: paths.notificationPath.path),
              fm.fileExists(atPath: paths.stopPath.path),
              let settingsData = try? Data(contentsOf: paths.settingsPath)
        else { return false }
        return hasRequiredHookEntries(in: settingsData)
    }

    static func hasManagedArtifacts(
        fileManager fm: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        let paths = paths(for: homeDirectory)
        if fm.fileExists(atPath: paths.notificationPath.path)
            || fm.fileExists(atPath: paths.stopPath.path)
            || fm.fileExists(atPath: paths.legacyPreToolUsePath.path)
        {
            return true
        }

        guard let settingsData = try? Data(contentsOf: paths.settingsPath) else {
            return false
        }
        return hasManagedHookEntries(in: settingsData)
    }

    /// Overwrite hook scripts with latest version if already installed.
    static func updateScriptsIfInstalled(
        fileManager fm: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws {
        guard isInstalled(fileManager: fm, homeDirectory: homeDirectory) else { return }
        let paths = paths(for: homeDirectory)
        let existingSettings = try Data(contentsOf: paths.settingsPath)
        let updatedSettings = try mergeHooks(into: removeHooks(from: existingSettings))
        let snapshots = try FileUtilities.captureSnapshots(
            for: [paths.notificationPath, paths.stopPath, paths.legacyPreToolUsePath, paths.settingsPath],
            fileManager: fm
        )
        do {
            try FileUtilities.removeItemIfExists(paths.legacyPreToolUsePath, fileManager: fm)
            try writeScripts(fileManager: fm, paths: paths)
            try FileUtilities.writeWithBackupRollback(updatedSettings, to: paths.settingsPath, fileManager: fm)
        } catch {
            try? FileUtilities.restoreSnapshots(snapshots, fileManager: fm)
            throw error
        }
    }

    private static func parseSettingsJSON(from data: Data) throws -> [String: Any] {
        let trimmed = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [:] }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: Data(trimmed.utf8))
        } catch {
            throw InstallError.invalidSettingsJSON
        }
        guard let json = object as? [String: Any] else {
            throw InstallError.invalidSettingsJSON
        }
        return json
    }

    private static func removableSettingsData(afterRemovingManagedHooksFrom data: Data) throws -> Data? {
        let cleaned = try removeHooks(from: data)
        let json = try parseSettingsJSON(from: cleaned)
        return json.isEmpty ? nil : cleaned
    }

    private static func writeScripts(fileManager fm: FileManager, paths: Paths) throws {
        try fm.createDirectory(at: paths.hooksDir, withIntermediateDirectories: true)
        try notificationScript.write(to: paths.notificationPath, atomically: true, encoding: .utf8)
        try stopScript.write(to: paths.stopPath, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.notificationPath.path)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.stopPath.path)
    }

    private static func hasRequiredHookEntries(in data: Data) -> Bool {
        guard let json = try? parseSettingsJSON(from: data),
              let hooks = json["hooks"] as? [String: Any]
        else { return false }
        return hasHookCommand(in: hooks["Notification"], command: "bash ~/.claude/hooks/cc-bot-notification.sh")
            && hasHookCommand(in: hooks["Stop"], command: "bash ~/.claude/hooks/cc-bot-stop.sh")
    }

    private static func hasManagedHookEntries(in data: Data) -> Bool {
        guard let json = try? parseSettingsJSON(from: data),
              let hooks = json["hooks"] as? [String: Any]
        else { return false }
        return hasHookCommand(in: hooks["Notification"], command: "bash ~/.claude/hooks/cc-bot-notification.sh")
            || hasHookCommand(in: hooks["Stop"], command: "bash ~/.claude/hooks/cc-bot-stop.sh")
            || hasHookCommand(in: hooks["PreToolUse"], command: "bash ~/.claude/hooks/cc-bot-pre-tool-use.sh")
    }

    private static func hasHookCommand(in value: Any?, command: String) -> Bool {
        let entries = value as? [[String: Any]] ?? []
        return entries.contains { entry in
            let hooksList = entry["hooks"] as? [[String: Any]] ?? []
            return hooksList.contains { ($0["command"] as? String) == command }
        }
    }

}

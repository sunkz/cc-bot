import Foundation

struct CodexNotifyInstaller {
    private struct Paths {
        let codexDir: URL
        let hooksDir: URL
        let configPath: URL
        let hooksPath: URL
        let notifyScriptPath: URL
        let permissionRequestScriptPath: URL
    }

    private static func paths(for homeDirectory: URL) -> Paths {
        let codexDir = homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        let hooksDir = codexDir.appendingPathComponent("hooks", isDirectory: true)
        return Paths(
            codexDir: codexDir,
            hooksDir: hooksDir,
            configPath: codexDir.appendingPathComponent("config.toml"),
            hooksPath: codexDir.appendingPathComponent("hooks.json"),
            notifyScriptPath: hooksDir.appendingPathComponent("cc-bot-notify.sh"),
            permissionRequestScriptPath: hooksDir.appendingPathComponent("cc-bot-permission-request.sh")
        )
    }

    private static let managedHooksFeatureLine = "codex_hooks = true # ccbot"

    static var notifyScript: String {
        """
        #!/bin/bash
        TOKEN=$(cat ~/.claude/hooks/.ccbot-auth 2>/dev/null)
        INPUT="${1:-$(cat)}"
        printf '%s' "$INPUT" | curl -sf -X POST http://localhost:\(Constants.serverPort)/hook/codex-notify \
          -H 'Content-Type: application/json' \
          -H "Authorization: Bearer $TOKEN" \
          -d @- --max-time 5 &
        exit 0
        """
    }

    static var permissionRequestScript: String {
        """
        #!/bin/bash
        TOKEN=$(cat ~/.claude/hooks/.ccbot-auth 2>/dev/null)
        INPUT=$(cat)
        printf '%s' "$INPUT" | curl -sf -X POST http://localhost:\(Constants.serverPort)/hook/codex-permission-request \
          -H 'Content-Type: application/json' \
          -H "Authorization: Bearer $TOKEN" \
          -d @- --max-time 5 &
        exit 0
        """
    }

    enum InstallError: Error, Equatable {
        case codexNotInstalled
        case notifyAlreadyConfigured
        case invalidHooksJSON
    }

    static func install(
        fileManager fm: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws {
        let paths = paths(for: homeDirectory)
        guard fm.fileExists(atPath: paths.codexDir.path) else {
            throw InstallError.codexNotInstalled
        }

        let existingConfig = (try? Data(contentsOf: paths.configPath)) ?? Data()
        let mergedNotify = try mergeNotify(into: existingConfig, paths: paths)
        let mergedConfig = try mergeHooksFeature(into: mergedNotify)
        let existingHooks = (try? Data(contentsOf: paths.hooksPath)) ?? Data("{}".utf8)
        let mergedHooks = try mergePermissionRequestHook(into: existingHooks)
        let snapshots = try FileUtilities.captureSnapshots(
            for: [
                paths.notifyScriptPath,
                paths.permissionRequestScriptPath,
                paths.configPath,
                paths.hooksPath,
            ],
            fileManager: fm
        )

        do {
            try writeScripts(fileManager: fm, paths: paths)
            try FileUtilities.writeWithBackupRollback(mergedConfig, to: paths.configPath, fileManager: fm)
            try FileUtilities.writeWithBackupRollback(mergedHooks, to: paths.hooksPath, fileManager: fm)
        } catch {
            try? FileUtilities.restoreSnapshots(snapshots, fileManager: fm)
            throw error
        }
    }

    static func uninstall(
        fileManager fm: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws {
        let paths = paths(for: homeDirectory)
        let cleanedConfig: Data?
        if fm.fileExists(atPath: paths.configPath.path) {
            let existingConfig = try Data(contentsOf: paths.configPath)
            let cleanedNotify = try removeNotify(from: existingConfig, paths: paths)
            cleanedConfig = try removeManagedHooksFeature(from: cleanedNotify)
        } else {
            cleanedConfig = nil
        }

        let cleanedHooks: Data?
        if fm.fileExists(atPath: paths.hooksPath.path) {
            cleanedHooks = try removePermissionRequestHook(from: Data(contentsOf: paths.hooksPath))
        } else {
            cleanedHooks = nil
        }
        let snapshots = try FileUtilities.captureSnapshots(
            for: [
                paths.notifyScriptPath,
                paths.permissionRequestScriptPath,
                paths.configPath,
                paths.hooksPath,
            ],
            fileManager: fm
        )

        do {
            try FileUtilities.removeItemIfExists(paths.notifyScriptPath, fileManager: fm)
            try FileUtilities.removeItemIfExists(paths.permissionRequestScriptPath, fileManager: fm)
            if let cleanedConfig {
                try FileUtilities.writeWithBackupRollback(cleanedConfig, to: paths.configPath, fileManager: fm)
            }
            if let cleanedHooks {
                try FileUtilities.writeWithBackupRollback(cleanedHooks, to: paths.hooksPath, fileManager: fm)
            }
        } catch {
            try? FileUtilities.restoreSnapshots(snapshots, fileManager: fm)
            throw error
        }
    }

    static func isInstalled(
        fileManager fm: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        let paths = paths(for: homeDirectory)
        guard fm.fileExists(atPath: paths.notifyScriptPath.path),
              fm.fileExists(atPath: paths.permissionRequestScriptPath.path),
              let configContents = try? String(contentsOf: paths.configPath, encoding: .utf8),
              let hooksData = try? Data(contentsOf: paths.hooksPath)
        else { return false }

        return hasManagedNotify(in: configContents, paths: paths)
            && hasEnabledHooksFeature(in: configContents)
            && hasPermissionRequestHook(in: hooksData)
    }

    static func updateScriptIfInstalled(
        fileManager fm: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws {
        guard isInstalled(fileManager: fm, homeDirectory: homeDirectory) else { return }
        let paths = paths(for: homeDirectory)
        let existingConfig = (try? Data(contentsOf: paths.configPath)) ?? Data()
        let mergedNotify = try mergeNotify(into: existingConfig, paths: paths)
        let mergedConfig = try mergeHooksFeature(into: mergedNotify)
        let existingHooks = (try? Data(contentsOf: paths.hooksPath)) ?? Data("{}".utf8)
        let mergedHooks = try mergePermissionRequestHook(into: existingHooks)
        let snapshots = try FileUtilities.captureSnapshots(
            for: [
                paths.notifyScriptPath,
                paths.permissionRequestScriptPath,
                paths.configPath,
                paths.hooksPath,
            ],
            fileManager: fm
        )

        do {
            try writeScripts(fileManager: fm, paths: paths)
            try FileUtilities.writeWithBackupRollback(mergedConfig, to: paths.configPath, fileManager: fm)
            try FileUtilities.writeWithBackupRollback(mergedHooks, to: paths.hooksPath, fileManager: fm)
        } catch {
            try? FileUtilities.restoreSnapshots(snapshots, fileManager: fm)
            throw error
        }
    }

    static func mergeNotify(into data: Data) throws -> Data {
        try mergeNotify(into: data, paths: paths(for: FileManager.default.homeDirectoryForCurrentUser))
    }

    private static func mergeNotify(into data: Data, paths: Paths) throws -> Data {
        let original = String(data: data, encoding: .utf8) ?? ""
        let canonicalLine = notifyLine(for: paths)

        if let range = notifyLineRange(in: original) {
            let existingLine = String(original[range])
            guard existingLine.contains(paths.notifyScriptPath.path) || existingLine.contains("cc-bot-notify.sh") else {
                throw InstallError.notifyAlreadyConfigured
            }

            var updated = original
            updated.replaceSubrange(range, with: canonicalLine)
            return Data(updated.utf8)
        }

        if original.isEmpty {
            return Data((canonicalLine + "\n").utf8)
        }

        if let firstTable = original.range(of: #"(?m)^\["#, options: .regularExpression) {
            var updated = original
            updated.insert(contentsOf: canonicalLine + "\n\n", at: firstTable.lowerBound)
            return Data(updated.utf8)
        }

        let separator = original.hasSuffix("\n") ? "" : "\n"
        return Data((original + separator + canonicalLine + "\n").utf8)
    }

    static func removeNotify(from data: Data) throws -> Data {
        try removeNotify(from: data, paths: paths(for: FileManager.default.homeDirectoryForCurrentUser))
    }

    private static func removeNotify(from data: Data, paths: Paths) throws -> Data {
        let original = String(data: data, encoding: .utf8) ?? ""
        guard let range = notifyLineRange(in: original) else { return data }

        let line = String(original[range])
        guard line.contains(paths.notifyScriptPath.path) || line.contains("cc-bot-notify.sh") else {
            return data
        }

        var updated = original
        let lineStart = range.lowerBound
        let lineEnd = updated[lineStart...].firstIndex(of: "\n") ?? updated.endIndex
        let removalEnd = lineEnd < updated.endIndex ? updated.index(after: lineEnd) : lineEnd
        updated.removeSubrange(lineStart..<removalEnd)

        while updated.contains("\n\n\n") {
            updated = updated.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }

        return Data(updated.utf8)
    }

    static func mergePermissionRequestHook(into data: Data) throws -> Data {
        var json = try parseHooksJSON(from: data)
        var hooks = json["hooks"] as? [String: Any] ?? [:]

        let command = "bash ~/.codex/hooks/cc-bot-permission-request.sh"
        var entries = hooks["PermissionRequest"] as? [[String: Any]] ?? []
        let alreadyPresent = entries.contains { entry in
            let hookList = entry["hooks"] as? [[String: Any]] ?? []
            return hookList.contains { ($0["command"] as? String) == command }
        }
        if !alreadyPresent {
            entries.append([
                "matcher": ".*",
                "hooks": [[
                    "type": "command",
                    "command": command,
                    "statusMessage": "Sending approval notification",
                ]],
            ])
        }

        hooks["PermissionRequest"] = entries
        json["hooks"] = hooks
        return try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    }

    static func removePermissionRequestHook(from data: Data) throws -> Data {
        var json = try parseHooksJSON(from: data)
        guard var hooks = json["hooks"] as? [String: Any] else { return data }

        let command = "bash ~/.codex/hooks/cc-bot-permission-request.sh"
        if var entries = hooks["PermissionRequest"] as? [[String: Any]] {
            entries = entries.compactMap { entry in
                var mutableEntry = entry
                var hookList = mutableEntry["hooks"] as? [[String: Any]] ?? []
                hookList.removeAll { ($0["command"] as? String) == command }
                guard !hookList.isEmpty else { return nil }
                mutableEntry["hooks"] = hookList
                return mutableEntry
            }
            if entries.isEmpty {
                hooks.removeValue(forKey: "PermissionRequest")
            } else {
                hooks["PermissionRequest"] = entries
            }
        }

        if hooks.isEmpty {
            json.removeValue(forKey: "hooks")
        } else {
            json["hooks"] = hooks
        }
        return try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    }

    static func mergeHooksFeature(into data: Data) throws -> Data {
        let original = String(data: data, encoding: .utf8) ?? ""
        var lines = original.components(separatedBy: .newlines)

        if let start = featuresSectionStart(in: lines) {
            let end = nextSectionStart(in: lines, after: start) ?? lines.count
            if let featureLineIndex = (start + 1..<end).first(where: { index in
                lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("codex_hooks")
            }) {
                lines[featureLineIndex] = managedHooksFeatureLine
            } else {
                lines.insert(managedHooksFeatureLine, at: start + 1)
            }
        } else {
            let insertion = ["[features]", managedHooksFeatureLine, ""]
            if let firstSection = lines.firstIndex(where: isTomlSectionHeader) {
                lines.insert(contentsOf: insertion, at: firstSection)
            } else if lines.allSatisfy({ $0.isEmpty }) {
                lines = ["[features]", managedHooksFeatureLine]
            } else {
                if let last = lines.last, !last.isEmpty {
                    lines.append("")
                }
                lines.append("[features]")
                lines.append(managedHooksFeatureLine)
            }
        }

        return Data(renderTomlLines(lines).utf8)
    }

    static func removeManagedHooksFeature(from data: Data) throws -> Data {
        let original = String(data: data, encoding: .utf8) ?? ""
        var lines = original.components(separatedBy: .newlines)
        guard let start = featuresSectionStart(in: lines) else { return data }
        let end = nextSectionStart(in: lines, after: start) ?? lines.count

        guard let featureLineIndex = (start + 1..<end).first(where: { index in
            lines[index].trimmingCharacters(in: .whitespaces) == managedHooksFeatureLine
        }) else {
            return data
        }

        lines.remove(at: featureLineIndex)

        let refreshedEnd = nextSectionStart(in: lines, after: start) ?? lines.count
        let hasMeaningfulFeatureLines = (start + 1..<refreshedEnd).contains { index in
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && !trimmed.hasPrefix("#")
        }
        if !hasMeaningfulFeatureLines {
            lines.remove(at: start)
            if start < lines.count, lines[start].isEmpty, (start == 0 || lines[start - 1].isEmpty) {
                lines.remove(at: start)
            }
        }

        return Data(renderTomlLines(lines).utf8)
    }

    private static func notifyLine(for paths: Paths) -> String {
        #"notify = ["bash", "\#(paths.notifyScriptPath.path)"]"#
    }

    private static func notifyLineRange(in text: String) -> Range<String.Index>? {
        text.range(of: #"(?m)^notify\s*=.*$"#, options: .regularExpression)
    }

    private static func writeScripts(fileManager fm: FileManager, paths: Paths) throws {
        try fm.createDirectory(at: paths.hooksDir, withIntermediateDirectories: true)
        try notifyScript.write(to: paths.notifyScriptPath, atomically: true, encoding: .utf8)
        try permissionRequestScript.write(to: paths.permissionRequestScriptPath, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.notifyScriptPath.path)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.permissionRequestScriptPath.path)
    }

    private static func parseHooksJSON(from data: Data) throws -> [String: Any] {
        let trimmed = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [:] }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: Data(trimmed.utf8))
        } catch {
            throw InstallError.invalidHooksJSON
        }
        guard let json = object as? [String: Any] else {
            throw InstallError.invalidHooksJSON
        }
        return json
    }

    private static func featuresSectionStart(in lines: [String]) -> Int? {
        lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == "[features]" }
    }

    private static func nextSectionStart(in lines: [String], after index: Int) -> Int? {
        guard index + 1 < lines.count else { return nil }
        return (index + 1..<lines.count).first(where: { isTomlSectionHeader(lines[$0]) })
    }

    private static func isTomlSectionHeader(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("[") && trimmed.hasSuffix("]")
    }

    private static func renderTomlLines(_ lines: [String]) -> String {
        let text = lines.joined(separator: "\n")
        guard !text.isEmpty else { return text }
        return text.hasSuffix("\n") ? text : text + "\n"
    }

    private static func hasManagedNotify(in config: String, paths: Paths) -> Bool {
        notifyLineRange(in: config).map {
            let line = String(config[$0])
            return line.contains(paths.notifyScriptPath.path) || line.contains("cc-bot-notify.sh")
        } ?? false
    }

    private static func hasEnabledHooksFeature(in config: String) -> Bool {
        config.range(of: #"(?m)^\s*codex_hooks\s*=\s*true\b.*$"#, options: .regularExpression) != nil
    }

    private static func hasPermissionRequestHook(in data: Data) -> Bool {
        guard let json = try? parseHooksJSON(from: data),
              let hooks = json["hooks"] as? [String: Any],
              let entries = hooks["PermissionRequest"] as? [[String: Any]]
        else { return false }

        return entries.contains { entry in
            let hookList = entry["hooks"] as? [[String: Any]] ?? []
            return hookList.contains { ($0["command"] as? String) == "bash ~/.codex/hooks/cc-bot-permission-request.sh" }
        }
    }
}

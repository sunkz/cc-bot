import Foundation

struct CodexNotifyInstaller {
    private static let managedNotifyTildePath = "~/.codex/hooks/cc-bot-notify.sh"
    private static let permissionRequestCommand = "bash ~/.codex/hooks/cc-bot-permission-request.sh"
    private static let permissionRequestMatcher = ".*"
    private static let permissionRequestStatusMessage = "Sending approval notification"
    private static let previousNotifyFlag = "--previous-notify"
    private static let computerUseClientExecutableName = "SkyComputerUseClient"
    private static let computerUseTurnEndedEvent = "turn-ended"

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

    private static let managedHooksFeatureLine = "hooks = true # ccbot"
    private static let legacyManagedHooksFeatureLine = "codex_hooks = true # ccbot"

    private enum ManagedNotifyOwnership {
        case none
        case direct
        case wrapped
    }

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
        let hadConfig = fm.fileExists(atPath: paths.configPath.path)
        let hadHooks = fm.fileExists(atPath: paths.hooksPath.path)
        let cleanedConfig: Data? =
            if hadConfig {
                try removableConfigData(from: Data(contentsOf: paths.configPath), paths: paths)
            } else {
                nil
            }
        let cleanedHooks: Data? =
            if hadHooks {
                try removableHooksData(from: Data(contentsOf: paths.hooksPath))
            } else {
                nil
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
            if hadConfig {
                try FileUtilities.writeOrRemoveItem(cleanedConfig, to: paths.configPath, fileManager: fm)
            }
            if hadHooks {
                try FileUtilities.writeOrRemoveItem(cleanedHooks, to: paths.hooksPath, fileManager: fm)
            }
        } catch {
            try? FileUtilities.restoreSnapshots(snapshots, fileManager: fm)
            throw error
        }

        try? FileUtilities.removeDirectoryIfEmpty(paths.hooksDir, fileManager: fm)
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
        try mergeNotify(into: data, homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
    }

    static func mergeNotify(into data: Data, homeDirectory: URL) throws -> Data {
        try mergeNotify(into: data, paths: paths(for: homeDirectory))
    }

    static func hasManagedArtifacts(
        fileManager fm: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        let paths = paths(for: homeDirectory)

        if fm.fileExists(atPath: paths.notifyScriptPath.path)
            || fm.fileExists(atPath: paths.permissionRequestScriptPath.path)
        {
            return true
        }

        if let configContents = try? String(contentsOf: paths.configPath, encoding: .utf8) {
            let ownsManagedNotify = notifyLineRange(in: configContents).map {
                let line = String(configContents[$0])
                return managedNotifyOwnership(of: line, paths: paths) != .none
            } ?? false
            if ownsManagedNotify || hasManagedHooksFeature(in: configContents) {
                return true
            }
        }

        guard let hooksData = try? Data(contentsOf: paths.hooksPath) else {
            return false
        }
        return hasPermissionRequestHook(in: hooksData)
    }

    private static func mergeNotify(into data: Data, paths: Paths) throws -> Data {
        let original = String(data: data, encoding: .utf8) ?? ""
        let canonicalLine = notifyLine(for: paths)

        if let range = notifyLineRange(in: original) {
            let existingLine = String(original[range])
            switch managedNotifyOwnership(of: existingLine, paths: paths) {
            case .direct:
                var updated = original
                updated.replaceSubrange(range, with: canonicalLine)
                return Data(updated.utf8)
            case .wrapped:
                return data
            case .none:
                if let augmentedLine = augmentComputerUseNotifyLine(existingLine, paths: paths) {
                    var updated = original
                    updated.replaceSubrange(range, with: augmentedLine)
                    return Data(updated.utf8)
                }
                throw InstallError.notifyAlreadyConfigured
            }
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
        switch managedNotifyOwnership(of: line, paths: paths) {
        case .none:
            return data
        case .direct:
            var updated = original
            let lineStart = range.lowerBound
            let lineEnd = updated[lineStart...].firstIndex(of: "\n") ?? updated.endIndex
            let removalEnd = lineEnd < updated.endIndex ? updated.index(after: lineEnd) : lineEnd
            updated.removeSubrange(lineStart..<removalEnd)

            while updated.contains("\n\n\n") {
                updated = updated.replacingOccurrences(of: "\n\n\n", with: "\n\n")
            }

            return Data(updated.utf8)
        case .wrapped:
            guard let cleanedLine = removingManagedPreviousNotify(from: line, paths: paths) else {
                return data
            }

            var updated = original
            updated.replaceSubrange(range, with: cleanedLine)
            return Data(updated.utf8)
        }
    }

    static func mergePermissionRequestHook(into data: Data) throws -> Data {
        var json = try parseHooksJSON(from: data)
        var hooks = json["hooks"] as? [String: Any] ?? [:]

        var entries = hooks["PermissionRequest"] as? [[String: Any]] ?? []
        entries = entries.compactMap { entry in
            var mutableEntry = entry
            var hookList = mutableEntry["hooks"] as? [[String: Any]] ?? []
            hookList.removeAll { ($0["command"] as? String) == permissionRequestCommand }
            guard !hookList.isEmpty else { return nil }
            mutableEntry["hooks"] = hookList
            return mutableEntry
        }
        entries.append(permissionRequestEntry())

        hooks["PermissionRequest"] = entries
        json["hooks"] = hooks
        return try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    }

    static func removePermissionRequestHook(from data: Data) throws -> Data {
        var json = try parseHooksJSON(from: data)
        guard var hooks = json["hooks"] as? [String: Any] else { return data }

        if var entries = hooks["PermissionRequest"] as? [[String: Any]] {
            entries = entries.compactMap { entry in
                var mutableEntry = entry
                var hookList = mutableEntry["hooks"] as? [[String: Any]] ?? []
                hookList.removeAll { ($0["command"] as? String) == permissionRequestCommand }
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
            let featureLineIndices = (start + 1..<end).filter { index in
                isHooksFeatureLine(lines[index])
            }
            if let featureLineIndex = featureLineIndices.first {
                lines[featureLineIndex] = managedHooksFeatureLine
                for index in featureLineIndices.dropFirst().reversed() {
                    lines.remove(at: index)
                }
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

        let featureLineIndices = (start + 1..<end).filter { index in
            isManagedHooksFeatureLine(lines[index])
        }

        guard !featureLineIndices.isEmpty else {
            return data
        }

        for index in featureLineIndices.reversed() {
            lines.remove(at: index)
        }

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

    private static func removableConfigData(from data: Data, paths: Paths) throws -> Data? {
        let withoutNotify = try removeNotify(from: data, paths: paths)
        let cleaned = try removeManagedHooksFeature(from: withoutNotify)
        let trimmed = String(decoding: cleaned, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : cleaned
    }

    private static func removableHooksData(from data: Data) throws -> Data? {
        let cleaned = try removePermissionRequestHook(from: data)
        let json = try parseHooksJSON(from: cleaned)
        return json.isEmpty ? nil : cleaned
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
            return managedNotifyOwnership(of: line, paths: paths) != .none
        } ?? false
    }

    private static func hasEnabledHooksFeature(in config: String) -> Bool {
        config.range(of: #"(?m)^\s*(?:hooks|codex_hooks)\s*=\s*true\b.*$"#, options: .regularExpression) != nil
    }

    private static func hasManagedHooksFeature(in config: String) -> Bool {
        config.components(separatedBy: .newlines).contains(where: isManagedHooksFeatureLine)
    }

    private static func isManagedHooksFeatureLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed == managedHooksFeatureLine || trimmed == legacyManagedHooksFeatureLine
    }

    private static func isHooksFeatureLine(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces)
            .range(of: #"^(?:hooks|codex_hooks)\s*="#, options: .regularExpression) != nil
    }

    private static func hasPermissionRequestHook(in data: Data) -> Bool {
        guard let json = try? parseHooksJSON(from: data),
              let hooks = json["hooks"] as? [String: Any],
              let entries = hooks["PermissionRequest"] as? [[String: Any]]
        else { return false }

        return entries.contains { entry in
            let hookList = entry["hooks"] as? [[String: Any]] ?? []
            return hookList.contains { ($0["command"] as? String) == permissionRequestCommand }
        }
    }

    private static func managedNotifyOwnership(of line: String, paths: Paths) -> ManagedNotifyOwnership {
        if hasDirectManagedNotify(in: line, paths: paths) {
            return .direct
        }

        if hasWrappedManagedNotify(in: line, paths: paths) {
            return .wrapped
        }

        let normalizedLine = line.replacingOccurrences(of: #"\/"#, with: "/")
        guard containsManagedNotifyPath(normalizedLine, paths: paths) else {
            return .none
        }
        return normalizedLine.contains("--previous-notify") ? .wrapped : .direct
    }

    private static func hasDirectManagedNotify(in line: String, paths: Paths) -> Bool {
        guard let arguments = parseNotifyArguments(from: line), arguments.count >= 2 else {
            return false
        }

        return arguments[0] == "bash" && containsManagedNotifyPath(arguments[1], paths: paths)
    }

    private static func hasWrappedManagedNotify(in line: String, paths: Paths) -> Bool {
        guard let arguments = parseNotifyArguments(from: line),
              let previousNotifyIndex = arguments.firstIndex(of: previousNotifyFlag),
              arguments.indices.contains(previousNotifyIndex + 1)
        else {
            return false
        }

        return containsManagedNotifyPath(arguments[previousNotifyIndex + 1], paths: paths)
    }

    private static func containsManagedNotifyPath(_ value: String, paths: Paths) -> Bool {
        let normalizedValue = value.replacingOccurrences(of: #"\/"#, with: "/")
        return normalizedValue.contains(paths.notifyScriptPath.path)
            || normalizedValue.contains(managedNotifyTildePath)
    }

    private static func removingManagedPreviousNotify(from line: String, paths: Paths) -> String? {
        guard var arguments = parseNotifyArguments(from: line),
              let previousNotifyIndex = arguments.firstIndex(of: previousNotifyFlag),
              arguments.indices.contains(previousNotifyIndex + 1),
              containsManagedNotifyPath(arguments[previousNotifyIndex + 1], paths: paths)
        else {
            return nil
        }

        arguments.removeSubrange(previousNotifyIndex...previousNotifyIndex + 1)
        return renderNotifyLine(arguments)
    }

    private static func augmentComputerUseNotifyLine(_ line: String, paths: Paths) -> String? {
        guard var arguments = parseNotifyArguments(from: line),
              isComputerUseTurnEndedNotify(arguments),
              !arguments.contains(previousNotifyFlag),
              let managedNotifyCommand = renderJSONStringArrayLiteral(["bash", paths.notifyScriptPath.path])
        else {
            return nil
        }

        arguments.append(previousNotifyFlag)
        arguments.append(managedNotifyCommand)
        return renderNotifyLine(arguments)
    }

    private static func parseNotifyArguments(from line: String) -> [String]? {
        guard let start = line.firstIndex(of: "["),
              let end = line.lastIndex(of: "]"),
              start < end
        else {
            return nil
        }

        let arrayContents = String(line[line.index(after: start)..<end])
        let pattern = #""((?:\\.|[^"\\])*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let nsRange = NSRange(arrayContents.startIndex..<arrayContents.endIndex, in: arrayContents)
        let matches = regex.matches(in: arrayContents, range: nsRange)
        guard !matches.isEmpty else {
            return []
        }

        var arguments: [String] = []
        arguments.reserveCapacity(matches.count)
        for match in matches {
            guard let rawRange = Range(match.range(at: 1), in: arrayContents) else {
                return nil
            }
            let rawValue = String(arrayContents[rawRange])
            let wrappedValue = "[\"\(rawValue)\"]"
            guard let data = wrappedValue.data(using: .utf8),
                  let values = try? JSONSerialization.jsonObject(with: data) as? [String]
            else {
                return nil
            }
            guard let value = values.first else {
                return nil
            }
            arguments.append(value)
        }
        return arguments
    }

    private static func isComputerUseTurnEndedNotify(_ arguments: [String]) -> Bool {
        guard arguments.count >= 2 else {
            return false
        }

        let executableName = URL(fileURLWithPath: arguments[0]).lastPathComponent
        return executableName == computerUseClientExecutableName
            && arguments[1] == computerUseTurnEndedEvent
    }

    private static func renderNotifyLine(_ arguments: [String]) -> String? {
        let renderedArguments = arguments.compactMap(renderTOMLStringLiteral)
        guard renderedArguments.count == arguments.count else {
            return nil
        }

        return "notify = [\(renderedArguments.joined(separator: ", "))]"
    }

    private static func renderTOMLStringLiteral(_ value: String) -> String? {
        guard let escaped = escapeStringLiteral(value) else {
            return nil
        }

        return "\"\(escaped)\""
    }

    private static func renderJSONStringArrayLiteral(_ values: [String]) -> String? {
        let renderedValues = values.compactMap { value in
            escapeStringLiteral(value).map { "\"\($0)\"" }
        }
        guard renderedValues.count == values.count else {
            return nil
        }

        return "[\(renderedValues.joined(separator: ","))]"
    }

    private static func escapeStringLiteral(_ value: String) -> String? {
        var escaped = ""
        escaped.reserveCapacity(value.count)

        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x08:
                escaped.append(#"\b"#)
            case 0x09:
                escaped.append(#"\t"#)
            case 0x0A:
                escaped.append(#"\n"#)
            case 0x0C:
                escaped.append(#"\f"#)
            case 0x0D:
                escaped.append(#"\r"#)
            case 0x22:
                escaped.append(#"\""#)
            case 0x5C:
                escaped.append(#"\\"#)
            case 0x00...0x1F:
                let hex = String(scalar.value, radix: 16, uppercase: false)
                let padded = String(repeating: "0", count: 4 - hex.count) + hex
                escaped.append(#"\u"#)
                escaped.append(padded)
            default:
                escaped.append(String(scalar))
            }
        }

        return escaped
    }

    private static func permissionRequestEntry() -> [String: Any] {
        [
            "matcher": permissionRequestMatcher,
            "hooks": [[
                "type": "command",
                "command": permissionRequestCommand,
                "statusMessage": permissionRequestStatusMessage,
            ]],
        ]
    }
}

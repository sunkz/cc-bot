import Foundation

struct CodexNotifyInstaller {
    static let codexDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex")
    static let hooksDir = codexDir.appendingPathComponent("hooks")
    static let configPath = codexDir.appendingPathComponent("config.toml")
    static let scriptPath = hooksDir.appendingPathComponent("cc-bot-notify.sh")

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

    enum InstallError: Error, Equatable {
        case codexNotInstalled
        case notifyAlreadyConfigured
    }

    static func install() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: codexDir.path) else {
            throw InstallError.codexNotInstalled
        }

        try fm.createDirectory(at: hooksDir, withIntermediateDirectories: true)
        try notifyScript.write(to: scriptPath, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)

        let existing = (try? Data(contentsOf: configPath)) ?? Data()
        let merged = try mergeNotify(into: existing)
        try FileUtilities.writeWithBackupRollback(merged, to: configPath, fileManager: fm)
    }

    static func uninstall() throws {
        let fm = FileManager.default
        try FileUtilities.removeItemIfExists(scriptPath, fileManager: fm)

        guard fm.fileExists(atPath: configPath.path) else { return }
        let existing = try Data(contentsOf: configPath)
        let cleaned = try removeNotify(from: existing)
        try FileUtilities.writeWithBackupRollback(cleaned, to: configPath, fileManager: fm)
    }

    static func isInstalled() -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: scriptPath.path),
              let contents = try? String(contentsOf: configPath, encoding: .utf8)
        else { return false }

        return notifyLineRange(in: contents).map {
            contents[$0].contains(scriptPath.path) || contents[$0].contains("cc-bot-notify.sh")
        } ?? false
    }

    static func updateScriptIfInstalled() throws {
        guard isInstalled() else { return }
        let fm = FileManager.default
        try notifyScript.write(to: scriptPath, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)
    }

    static func mergeNotify(into data: Data) throws -> Data {
        let original = String(data: data, encoding: .utf8) ?? ""
        let canonicalLine = notifyLine

        if let range = notifyLineRange(in: original) {
            let existingLine = String(original[range])
            guard existingLine.contains(scriptPath.path) || existingLine.contains("cc-bot-notify.sh") else {
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
        let original = String(data: data, encoding: .utf8) ?? ""
        guard let range = notifyLineRange(in: original) else { return data }

        let line = String(original[range])
        guard line.contains(scriptPath.path) || line.contains("cc-bot-notify.sh") else {
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

    private static var notifyLine: String {
        #"notify = ["bash", "\#(scriptPath.path)"]"#
    }

    private static func notifyLineRange(in text: String) -> Range<String.Index>? {
        text.range(of: #"(?m)^notify\s*=.*$"#, options: .regularExpression)
    }

}

// CCBot/Constants.swift
import Foundation

enum Constants {
    static let serverPort: UInt16 = 62400
    static let messageTruncateLength = 200

    private static let authTokenPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/hooks/.ccbot-auth")

    /// Reads or creates the auth token file at `~/.claude/hooks/.ccbot-auth`.
    /// Creates the parent directory if needed. Thread safety: all callers are @MainActor.
    static func ensureAuthToken() -> String {
        let path = authTokenPath
        if let existing = try? String(contentsOf: path, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !existing.isEmpty {
            return existing
        }
        let dir = path.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let new = UUID().uuidString
        try? new.write(to: path, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        return new
    }
}

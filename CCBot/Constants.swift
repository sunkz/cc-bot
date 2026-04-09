// CCBot/Constants.swift
import Foundation

enum Constants {
    static let serverPort: UInt16 = 62400
    static let messageTruncateLength = 200

    // MARK: - Notification source names
    static let sourceClaude = "Claude"
    static let sourceCodex = "Codex"

    // MARK: - Codex event types
    static let codexEventTurnComplete = "agent-turn-complete"
    static let codexEventApproval = "approval-requested"
    static let codexEventInput = "user-input-requested"

    // MARK: - CC GUI file prefixes
    static let prefixAskQuestion = "ask-user-question-"
    static let prefixPlanApproval = "plan-approval-"
    static let prefixRequest = "request-"
    static let prefixResponse = "response-"

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

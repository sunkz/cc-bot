// CCBot/Utilities/MessageFormatter.swift
import Foundation

enum MessageFormatter {
    enum NotificationKind {
        case completion
        case approval
        case input
        case info
        case warning
    }

    static func prepare(_ text: String, maxLength: Int = Constants.messageTruncateLength) -> String {
        String(stripMarkdown(text).prefix(maxLength))
    }

    static func notificationTitle(kind: NotificationKind, source: String, project: String) -> String {
        switch kind {
        case .completion:
            return "✅ [\(source)] [\(project)] 已完成"
        case .approval:
            return "⏳ [\(source)] [\(project)] 待确认"
        case .input:
            return "❓ [\(source)] [\(project)] 待输入"
        case .warning:
            return "⚠️ [\(source)] [\(project)] 异常"
        case .info:
            return "🔔 [\(source)] [\(project)] 通知"
        }
    }

    static func notificationBody(detail: String, maxDetailLength: Int = 140) -> String {
        smartTruncate(normalizeInline(detail), maxLength: maxDetailLength)
    }

    private static func normalizeInline(_ text: String) -> String {
        let stripped = stripMarkdown(text)
        return stripped
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func smartTruncate(_ text: String, maxLength: Int) -> String {
        guard maxLength > 4, text.count > maxLength else { return text }
        let suffixCount = min(24, maxLength / 5)
        let prefixCount = max(1, maxLength - suffixCount - 1)
        let head = String(text.prefix(prefixCount))
        let tail = String(text.suffix(suffixCount))
        return "\(head)…\(tail)"
    }
}

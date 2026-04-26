// CCBot/Utilities/MessageFormatter.swift
import Foundation

enum MessageFormatter {
    enum NotificationKind {
        case completion
        case approval
        case input
        case info
    }

    private static let whitespaceRegex = try! NSRegularExpression(pattern: #"\s+"#)

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
        case .info:
            return "🔔 [\(source)] [\(project)] 通知"
        }
    }

    static func notificationBody(detail: String, maxDetailLength: Int = 140) -> String {
        smartTruncate(normalizeInline(detail), maxLength: maxDetailLength)
    }

    static func prepareCodexDetail(_ text: String, maxLength: Int = Constants.messageTruncateLength) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        if let object = parseCodexStructuredPayload(trimmed) {
            let summary = summarizeJSONValue(object) ?? ""
            return String(stripMarkdown(summary).prefix(maxLength))
        }
        return prepare(trimmed, maxLength: maxLength)
    }

    private static func normalizeInline(_ text: String) -> String {
        let stripped = stripMarkdown(text)
        let range = NSRange(stripped.startIndex..<stripped.endIndex, in: stripped)
        return whitespaceRegex
            .stringByReplacingMatches(in: stripped, range: range, withTemplate: " ")
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

    private static func parseCodexStructuredPayload(_ text: String) -> Any? {
        guard let first = text.first, first == "{" || first == "[" else { return nil }
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data)
        else { return nil }
        return object
    }

    private static func summarizeJSONValue(_ value: Any) -> String? {
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        if let dict = value as? [String: Any] {
            if let suggestions = dict["suggestions"] as? [[String: Any]] {
                let items = suggestions.prefix(2).compactMap(suggestionSummary)
                if !items.isEmpty {
                    return items.joined(separator: "；")
                }
            }

            for key in ["message", "text", "title", "description"] {
                if let text = summarizeJSONValue(dict[key] as Any) {
                    return text
                }
            }
            return nil
        }

        if let array = value as? [Any] {
            let items = array.prefix(2).compactMap(summarizeJSONValue)
            return items.isEmpty ? nil : items.joined(separator: "；")
        }

        return nil
    }

    private static func suggestionSummary(_ suggestion: [String: Any]) -> String? {
        let title = (suggestion["title"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let description = (suggestion["description"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if !title.isEmpty, !description.isEmpty {
            return "建议：\(title) - \(description)"
        }
        if !title.isEmpty {
            return "建议：\(title)"
        }
        if !description.isEmpty {
            return "建议：\(description)"
        }
        return nil
    }
}

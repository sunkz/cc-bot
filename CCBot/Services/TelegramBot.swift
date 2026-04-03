// CCBot/Services/TelegramBot.swift
import Foundation
import SwiftUI
import os.log

private let log = Logger(subsystem: "com.ccbot.app", category: "TelegramBot")

@MainActor
final class TelegramBot: ObservableObject {
    @AppStorage("telegramBotToken") var token = ""
    @AppStorage("telegramChatId") var chatId = ""

    // MARK: - Send

    func sendNotification(project: String, message: String) async {
        let text = Self.formatNotification(project: project, message: message)
        await sendMessage(text)
    }

    func sendCompletion(project: String, message: String) async {
        let text = Self.formatCompletion(project: project, message: message)
        await sendMessage(text)
    }

    func sendToolConfirmation(project: String, message: String) async {
        let text = Self.formatToolConfirmation(project: project, message: message)
        await sendMessage(text)
    }

    // MARK: - Format (static for testability)

    nonisolated static func formatNotification(project: String, message: String) -> String {
        let plain = stripMarkdown(message)
        let truncated = String(plain.prefix(200))
        return "🔔 [\(project)]\n\(truncated)"
    }

    nonisolated static func formatCompletion(project: String, message: String) -> String {
        let plain = stripMarkdown(message)
        let truncated = String(plain.prefix(200))
        return "✅ [\(project)] 任务完成\n\(truncated)"
    }

    nonisolated static func formatToolConfirmation(project: String, message: String) -> String {
        let plain = stripMarkdown(message)
        let truncated = String(plain.prefix(200))
        return "⏳ [\(project)] 需要确认\n\(truncated)"
    }

    // MARK: - Send message

    private func sendMessage(_ text: String) async {
        guard !token.isEmpty, !chatId.isEmpty else { return }
        guard let url = URL(string: "https://api.telegram.org/bot\(token)/sendMessage") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["chat_id": chatId, "text": text]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                log.error("sendMessage HTTP \(http.statusCode)")
            }
        } catch {
            log.error("sendMessage failed: \(error.localizedDescription)")
        }
    }
}

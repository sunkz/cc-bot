// CCBot/Services/TelegramBot.swift
import Foundation
import SwiftUI
import os.log

private let log = Logger(subsystem: "com.ccbot.app", category: "TelegramBot")

@MainActor
protocol TelegramHTTPClient {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: TelegramHTTPClient {}

@MainActor
final class TelegramBot: ObservableObject {
    @Published var token: String = ""
    @AppStorage("telegramChatId") var chatId = ""

    private let httpClient: TelegramHTTPClient
    private let userDefaults: UserDefaults
    private static let tokenKey = "telegramBotToken"
    private struct TelegramSendResponse: Decodable {
        let ok: Bool
        let description: String?
    }

    init(httpClient: TelegramHTTPClient = URLSession.shared, userDefaults: UserDefaults = .standard) {
        self.httpClient = httpClient
        self.userDefaults = userDefaults
        _chatId = AppStorage(wrappedValue: "", "telegramChatId", store: userDefaults)
        token = userDefaults.string(forKey: Self.tokenKey) ?? ""
    }

    func saveToken(_ value: String) {
        token = value
        if value.isEmpty {
            userDefaults.removeObject(forKey: Self.tokenKey)
        } else {
            userDefaults.set(value, forKey: Self.tokenKey)
        }
    }

    // MARK: - Send

    func sendNotification(project: String, source: String, message: String) async {
        let text = Self.formatNotification(project: project, source: source, message: message)
        await sendMessage(text)
    }

    func sendCompletion(project: String, source: String, message: String) async {
        let text = Self.formatCompletion(project: project, source: source, message: message)
        await sendMessage(text)
    }

    func sendToolConfirmation(project: String, source: String, message: String) async {
        let text = Self.formatToolConfirmation(project: project, source: source, message: message)
        await sendMessage(text)
    }

    func sendInputRequest(project: String, source: String, message: String) async {
        let text = Self.formatInputRequest(project: project, source: source, message: message)
        await sendMessage(text)
    }

    // MARK: - Format (static for testability)

    nonisolated static func formatNotification(project: String, source: String, message: String) -> String {
        let title = MessageFormatter.notificationTitle(kind: .info, source: source, project: project)
        let body = MessageFormatter.notificationBody(detail: message)
        return "\(title)\n\(body)"
    }

    nonisolated static func formatCompletion(project: String, source: String, message: String) -> String {
        let title = MessageFormatter.notificationTitle(kind: .completion, source: source, project: project)
        let body = MessageFormatter.notificationBody(detail: message)
        return "\(title)\n\(body)"
    }

    nonisolated static func formatToolConfirmation(project: String, source: String, message: String) -> String {
        let title = MessageFormatter.notificationTitle(kind: .approval, source: source, project: project)
        let body = MessageFormatter.notificationBody(detail: message)
        return "\(title)\n\(body)"
    }

    nonisolated static func formatInputRequest(project: String, source: String, message: String) -> String {
        let title = MessageFormatter.notificationTitle(kind: .input, source: source, project: project)
        let body = MessageFormatter.notificationBody(detail: message)
        return "\(title)\n\(body)"
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

        for attempt in 0..<3 {
            do {
                let (data, resp) = try await httpClient.data(for: req)
                if let http = resp as? HTTPURLResponse {
                    let result = Self.parseSendMessageResult(data: data)
                    if http.statusCode == 200 {
                        guard let result else {
                            log.warning("event=telegram_send status=200 retry=true attempt=\(attempt + 1)/3 reason=invalid_json")
                            if attempt < 2 {
                                try? await Task.sleep(for: .seconds(pow(2, Double(attempt))))
                            }
                            continue
                        }
                        if result.ok { return }
                        log.error("event=telegram_send status=200 ok=false attempt=\(attempt + 1) reason=\(result.description ?? "unknown error")")
                        return
                    }
                    if http.statusCode >= 400, http.statusCode < 500 {
                        log.error("event=telegram_send status=\(http.statusCode) retry=false attempt=\(attempt + 1) reason=\(result?.description ?? "invalid_json")")
                        return
                    }
                    log.warning("event=telegram_send status=\(http.statusCode) retry=true attempt=\(attempt + 1)/3 reason=\(result?.description ?? "invalid_json")")
                }
            } catch is CancellationError {
                return
            } catch {
                log.warning("event=telegram_send status=network_error retry=true attempt=\(attempt + 1)/3 error=\(error.localizedDescription)")
            }
            if attempt < 2 {
                try? await Task.sleep(for: .seconds(pow(2, Double(attempt))))
            }
        }
        log.error("event=telegram_send status=failed attempts=3")
    }

    nonisolated static func parseSendMessageResult(data: Data) -> (ok: Bool, description: String?)? {
        guard let decoded = try? JSONDecoder().decode(TelegramSendResponse.self, from: data) else {
            return nil
        }
        return (decoded.ok, decoded.description)
    }
}

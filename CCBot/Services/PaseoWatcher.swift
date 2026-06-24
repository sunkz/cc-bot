// CCBot/Services/PaseoWatcher.swift
import Foundation
import os.log

private let log = Logger(subsystem: "com.ccbot.app", category: "PaseoWatcher")

@MainActor
final class PaseoWatcher: ObservableObject {
    @Published var isWatching = false

    private var webSocketTask: URLSessionWebSocketTask?
    private var telegramBot: TelegramBot?
    private var reconnectAttempts = 0
    private var isRunning = false
    private let maxReconnectDelay: TimeInterval = 30
    private let clientId = "ccbot-\(UUID().uuidString)"
    private var recentPermissionIDs: [String: Date] = [:]
    private var internalAgentIDs: Set<String> = []
    private var agentMeta: [String: AgentMeta] = [:]

    private struct AgentMeta {
        var provider: String
        var cwd: String
    }

    func start(telegram: TelegramBot) {
        guard !isRunning else { return }
        isRunning = true
        telegramBot = telegram
        reconnectAttempts = 0
        connect()
    }

    func stop() {
        isRunning = false
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        isWatching = false
    }

    // MARK: - Connection

    private func connect() {
        guard isRunning else { return }

        var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(Constants.paseoWSPort)/ws")!)
        if let password = Self.readDaemonPassword() {
            request.setValue("paseo.bearer.\(password)", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        }

        let task = URLSession.shared.webSocketTask(with: request)
        webSocketTask = task
        task.resume()

        Task { [weak self] in
            guard let self else { return }
            await self.sendHello()
        }
    }

    private func sendHello() {
        let hello: [String: Any] = [
            "type": "hello",
            "clientId": clientId,
            "clientType": "cli",
            "protocolVersion": 1,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: hello),
              let text = String(data: data, encoding: .utf8)
        else { return }

        webSocketTask?.send(.string(text)) { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    log.error("event=paseo_hello_failed error=\(error.localizedDescription)")
                    self.scheduleReconnect()
                } else {
                    log.notice("event=paseo_connected")
                    self.isWatching = true
                    self.reconnectAttempts = 0
                    self.receiveMessage()
                }
            }
        }
    }

    private func receiveMessage() {
        guard isRunning, let task = webSocketTask else { return }

        task.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.isRunning else { return }
                switch result {
                case .success(let message):
                    switch message {
                    case .string(let text):
                        self.handleRawMessage(text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            self.handleRawMessage(text)
                        }
                    @unknown default:
                        break
                    }
                    self.receiveMessage()
                case .failure(let error):
                    log.error("event=paseo_ws_error error=\(error.localizedDescription)")
                    self.isWatching = false
                    self.scheduleReconnect()
                }
            }
        }
    }

    // MARK: - Reconnect

    private func scheduleReconnect() {
        guard isRunning else { return }
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        isWatching = false

        let delay = min(pow(2.0, Double(reconnectAttempts)) * 1.0, maxReconnectDelay)
        reconnectAttempts += 1
        log.notice("event=paseo_reconnect_scheduled delay=\(delay)s attempt=\(self.reconnectAttempts)")

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, self.isRunning else { return }
            self.connect()
        }
    }

    // MARK: - Message handling

    private func handleRawMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["type"] as? String) == "session",
              let message = json["message"] as? [String: Any],
              let messageType = message["type"] as? String
        else { return }

        switch messageType {
        case "agent_update":
            handleAgentUpdate(message: message)
        case "agent_stream":
            guard let payload = message["payload"] as? [String: Any],
                  let event = payload["event"] as? [String: Any],
                  let eventType = event["type"] as? String
            else { return }

            let agentId = payload["agentId"] as? String ?? "unknown"
            if internalAgentIDs.contains(agentId) { return }

            switch eventType {
            case "permission_requested":
                handlePermissionRequested(agentId: agentId, event: event)
            case "attention_required":
                handleAttentionRequired(agentId: agentId, event: event)
            default:
                break
            }
        default:
            break
        }
    }

    private func handleAgentUpdate(message: [String: Any]) {
        guard let payload = message["payload"] as? [String: Any],
              let agent = payload["agent"] as? [String: Any],
              let agentId = agent["id"] as? String
        else { return }

        let title = agent["title"] as? String ?? ""
        if title == "Agent metadata generator" {
            internalAgentIDs.insert(agentId)
        }

        let provider = agent["provider"] as? String ?? ""
        let cwd = agent["cwd"] as? String ?? ""
        if !provider.isEmpty || !cwd.isEmpty {
            agentMeta[agentId] = AgentMeta(provider: provider, cwd: cwd)
        }
    }

    private func handlePermissionRequested(agentId: String, event: [String: Any]) {
        guard let request = event["request"] as? [String: Any] else { return }

        let requestId = request["id"] as? String ?? UUID().uuidString
        if isDuplicatePermission(id: requestId) { return }

        let kind = request["kind"] as? String ?? "tool"
        let name = request["name"] as? String ?? ""
        let description = request["description"] as? String
        let title = request["title"] as? String

        let notifKind: MessageFormatter.NotificationKind = (kind == "question") ? .input : .approval
        let detail = description ?? title ?? "工具: \(name)"
        let (source, project) = sourceAndProject(for: agentId)

        notify(kind: notifKind, source: source, project: project, message: detail)
    }

    private func handleAttentionRequired(agentId: String, event: [String: Any]) {
        let reason = event["reason"] as? String ?? "finished"
        let notification = event["notification"] as? [String: Any]
        let body = notification?["body"] as? String

        let (source, project) = sourceAndProject(for: agentId)

        switch reason {
        case "permission":
            break
        case "error":
            notify(kind: .info, source: source, project: project, message: body ?? "Paseo agent 遇到错误")
        default:
            break
        }
    }

    // MARK: - Deduplication

    private func isDuplicatePermission(id: String) -> Bool {
        let now = Date()
        if recentPermissionIDs.count > 100 {
            recentPermissionIDs = recentPermissionIDs.filter { now.timeIntervalSince($0.value) < 5 }
        }
        if let last = recentPermissionIDs[id], now.timeIntervalSince(last) < 5 {
            return true
        }
        recentPermissionIDs[id] = now
        return false
    }

    // MARK: - Notification dispatch

    private func notify(kind: MessageFormatter.NotificationKind, source: String, project: String, message: String) {
        guard NotificationPreferences.systemEnabled
            || NotificationPreferences.telegramEnabled
            || NotificationPreferences.flashEnabled else { return }

        let title = MessageFormatter.notificationTitle(kind: kind, source: source, project: project)
        let body = MessageFormatter.notificationBody(detail: message)

        if NotificationPreferences.systemEnabled {
            SystemNotifier.shared.notify(title: title, body: body)
        }
        if NotificationPreferences.flashEnabled {
            FlashNotificationWindow.show(title: title, body: body)
        }
        if NotificationPreferences.telegramEnabled {
            Task {
                switch kind {
                case .completion:
                    await telegramBot?.sendCompletion(project: project, source: source, message: message)
                case .approval:
                    await telegramBot?.sendToolConfirmation(project: project, source: source, message: message)
                case .input:
                    await telegramBot?.sendInputRequest(project: project, source: source, message: message)
                case .info:
                    await telegramBot?.sendNotification(project: project, source: source, message: message)
                }
            }
        }
    }

    // MARK: - Utilities

    private func sourceAndProject(for agentId: String) -> (source: String, project: String) {
        guard let meta = agentMeta[agentId] else {
            return (Constants.sourcePaseo, String(agentId.prefix(8)))
        }
        let source: String
        switch meta.provider {
        case "claude":
            source = Constants.sourceClaude
        case "codex":
            source = Constants.sourceCodex
        default:
            source = Constants.sourcePaseo
        }
        let project = meta.cwd.split(separator: "/").last.map(String.init) ?? String(agentId.prefix(8))
        return (source, project)
    }

    private static func readDaemonPassword() -> String? {
        let configPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".paseo/config.json")
        guard let data = try? Data(contentsOf: configPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let daemon = json["daemon"] as? [String: Any],
              let password = daemon["password"] as? String,
              !password.isEmpty
        else { return nil }
        return password
    }
}

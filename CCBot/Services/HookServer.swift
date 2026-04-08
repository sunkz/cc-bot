// CCBot/Services/HookServer.swift
import Foundation
import Network
import os.log

private let log = Logger(subsystem: "com.ccbot.app", category: "HookServer")
private let maxHookBodyBytes = 1_048_576 // 1 MB
private let maxHookRequestBytes = 1_056_768 // body + headers safety margin

struct ParsedRequest {
    let method: String
    let path: String
    let body: Data
    let authorizationHeader: String?
}

@MainActor
final class HookServer: ObservableObject {
    @Published var errorMessage: String?

    private var listener: NWListener?
    private var telegramBot: TelegramBot?
    let port: UInt16 = Constants.serverPort

    // Throttle: same (project, hookType) within interval skips notification
    private var lastNotifyTimes: [String: Date] = [:]
    private var recentMessageFingerprints: [String: Date] = [:]
    private let throttleInterval: TimeInterval = 3
    private let deduplicateInterval: TimeInterval = 6
    private var restartAttempts = 0
    private let maxRestartAttempts = 3

    func start(telegram: TelegramBot) {
        self.telegramBot = telegram
        startListener()
    }

    private func startListener() {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        guard let listener = try? NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!) else {
            errorMessage = "Port \(port) 被占用"
            return
        }

        listener.newConnectionHandler = { [weak self] conn in
            conn.start(queue: .global())
            self?.receiveHTTPRequest(conn: conn)
        }
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    self?.errorMessage = nil
                    self?.restartAttempts = 0
                    log.notice("event=hook_server_ready port=\(self?.port ?? 0)")
                case .failed(let error):
                    self?.errorMessage = "监听失败: \(error.localizedDescription)"
                    log.error("event=hook_server_failed error=\(error.localizedDescription)")
                    self?.scheduleRestart()
                default:
                    break
                }
            }
        }
        listener.start(queue: .global())
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func scheduleRestart() {
        guard restartAttempts < maxRestartAttempts else {
            log.error("event=hook_server_restart status=max_reached attempts=\(self.maxRestartAttempts)")
            return
        }
        restartAttempts += 1
        let delay = Double(restartAttempts) * 2
        log.notice("event=hook_server_restart status=scheduled attempt=\(self.restartAttempts)/\(self.maxRestartAttempts) delay=\(delay)")
        listener?.cancel()
        listener = nil
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            self.startListener()
        }
    }

    nonisolated private func receiveHTTPRequest(conn: NWConnection) {
        receiveHTTPRequestChunk(conn: conn, buffer: Data())
    }

    nonisolated private func receiveHTTPRequestChunk(conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { conn.cancel(); return }
            guard error == nil else { conn.cancel(); return }

            var accumulated = buffer
            if let data, !data.isEmpty {
                accumulated.append(data)
            }

            guard !accumulated.isEmpty else {
                conn.cancel()
                return
            }

            if accumulated.count > maxHookRequestBytes {
                self.sendResponse(conn: conn, status: 413, body: "{}")
                return
            }

            if let contentLength = self.contentLengthIfAvailable(from: accumulated),
               contentLength > maxHookBodyBytes {
                self.sendResponse(conn: conn, status: 413, body: "{}")
                return
            }

            guard let request = self.parseHTTPRequest(from: accumulated) else {
                if isComplete {
                    self.sendResponse(conn: conn, status: 400, body: "{}")
                } else {
                    self.receiveHTTPRequestChunk(conn: conn, buffer: accumulated)
                }
                return
            }

            let req = request
            Task { @MainActor in
                await self.dispatch(request: req, conn: conn)
            }
        }
    }

    nonisolated func parseHTTPRequest(from data: Data) -> ParsedRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: separator),
              let headerText = String(data: data[..<headerRange.lowerBound], encoding: .utf8)
        else { return nil }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 3 else { return nil }

        let method = String(parts[0]).uppercased()
        let path = String(parts[1])

        var contentLength = 0
        var authHeader: String?
        for line in lines.dropFirst() {
            let pieces = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard pieces.count == 2 else { continue }
            let name = pieces[0].trimmingCharacters(in: .whitespaces)
            let value = pieces[1].trimmingCharacters(in: .whitespaces)
            if name.caseInsensitiveCompare("Content-Length") == .orderedSame {
                contentLength = Int(value) ?? 0
            } else if name.caseInsensitiveCompare("Authorization") == .orderedSame {
                authHeader = value
            }
        }

        let bodyStart = headerRange.upperBound
        let remainingBodyCount = data.count - bodyStart
        guard contentLength >= 0, contentLength <= maxHookBodyBytes else { return nil }
        guard remainingBodyCount >= contentLength else { return nil }

        let bodyEnd = bodyStart + contentLength
        return ParsedRequest(
            method: method,
            path: path,
            body: data.subdata(in: bodyStart..<bodyEnd),
            authorizationHeader: authHeader
        )
    }

    nonisolated private func contentLengthIfAvailable(from data: Data) -> Int? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: separator),
              let headerText = String(data: data[..<headerRange.lowerBound], encoding: .utf8)
        else { return nil }

        for line in headerText.components(separatedBy: "\r\n").dropFirst() {
            let pieces = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard pieces.count == 2 else { continue }
            let name = pieces[0].trimmingCharacters(in: .whitespaces)
            let value = pieces[1].trimmingCharacters(in: .whitespaces)
            if name.caseInsensitiveCompare("Content-Length") == .orderedSame {
                return Int(value)
            }
        }
        return nil
    }

    private func dispatch(request: ParsedRequest, conn: NWConnection) async {
        if request.path == "/health" {
            guard request.method == "GET" else {
                sendResponse(conn: conn, status: 405, body: #"{"error":"method_not_allowed"}"#)
                return
            }
            sendResponse(conn: conn, status: 200, body: #"{"status":"ok"}"#)
            return
        }

        guard request.method == "POST" else {
            sendResponse(conn: conn, status: 405, body: "{}")
            return
        }

        let expectedToken = "Bearer \(Constants.ensureAuthToken())"
        guard request.authorizationHeader == expectedToken else {
            sendResponse(conn: conn, status: 401, body: "{}")
            return
        }

        guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
            sendResponse(conn: conn, status: 400, body: "{}")
            return
        }

        switch request.path {
        case "/hook/notification":
            handleClaudeNotification(json: json)
            sendResponse(conn: conn, status: 200, body: "{}")
        case "/hook/stop":
            handleStop(json: json)
            sendResponse(conn: conn, status: 200, body: "{}")
        case "/hook/codex-notify":
            handleCodexNotification(json: json)
            sendResponse(conn: conn, status: 200, body: "{}")
        default:
            sendResponse(conn: conn, status: 404, body: "{}")
        }
    }

    func shouldThrottle(key: String) -> Bool {
        let now = Date()
        if lastNotifyTimes.count > 100 {
            lastNotifyTimes = lastNotifyTimes.filter { now.timeIntervalSince($0.value) < throttleInterval }
        }
        if let last = lastNotifyTimes[key], now.timeIntervalSince(last) < throttleInterval {
            return true
        }
        lastNotifyTimes[key] = now
        return false
    }

    func shouldDeduplicate(source: String, project: String, eventType: String, message: String) -> Bool {
        let normalized = normalizedMessage(message)
        guard !normalized.isEmpty else { return false }
        let fingerprint = "\(source)|\(project)|\(eventType)|\(normalized)"
        let now = Date()

        if recentMessageFingerprints.count > 300 {
            recentMessageFingerprints = recentMessageFingerprints.filter {
                now.timeIntervalSince($0.value) < deduplicateInterval
            }
        }

        if let last = recentMessageFingerprints[fingerprint],
           now.timeIntervalSince(last) < deduplicateInterval {
            return true
        }

        recentMessageFingerprints[fingerprint] = now
        return false
    }

    private func handleClaudeNotification(json: [String: Any]) {
        let cwd = stringValue(in: json, key: "cwd")
        let message = stringValue(in: json, key: "message")
        let project = projectName(from: cwd)
        guard !shouldThrottle(key: "notification:\(project)") else { return }

        // Detect permission request: "Claude needs your permission to use Bash"
        let isPermission = message.contains("needs your permission")
        let eventType = isPermission ? "approval-requested" : "notification"
        if shouldDeduplicate(source: "Claude", project: project, eventType: eventType, message: message) {
            log.notice("event=hook_deduplicated source=Claude project=\(project) type=\(eventType)")
            return
        }
        let title: String
        let body: String
        if isPermission {
            title = MessageFormatter.notificationTitle(kind: .approval, source: "Claude", project: project)
            body = MessageFormatter.notificationBody(detail: permissionSummary(from: message))
        } else {
            title = MessageFormatter.notificationTitle(kind: .info, source: "Claude", project: project)
            body = MessageFormatter.notificationBody(detail: message)
        }

        if NotificationPreferences.systemEnabled {
            SystemNotifier.shared.notify(title: title, body: body)
        }
        if NotificationPreferences.telegramEnabled {
            if isPermission {
                Task { await telegramBot?.sendToolConfirmation(project: project, source: "Claude", message: body) }
            } else {
                Task { await telegramBot?.sendNotification(project: project, source: "Claude", message: message) }
            }
        }
    }

    private func handleCodexNotification(json: [String: Any]) {
        let eventType = stringValue(in: json, key: "type")
        let cwd = stringValue(in: json, key: "cwd")
        let project = projectName(from: cwd, fallback: "Codex")
        let body = codexBody(from: json)

        guard !shouldThrottle(key: "codex:\(eventType):\(project)") else { return }
        if shouldDeduplicate(source: "Codex", project: project, eventType: eventType, message: body) {
            log.notice("event=hook_deduplicated source=Codex project=\(project) type=\(eventType)")
            return
        }

        switch eventType {
        case "agent-turn-complete":
            if NotificationPreferences.systemEnabled {
                SystemNotifier.shared.notify(
                    title: MessageFormatter.notificationTitle(kind: .completion, source: "Codex", project: project),
                    body: MessageFormatter.notificationBody(detail: body)
                )
            }
            if NotificationPreferences.telegramEnabled {
                Task { await telegramBot?.sendCompletion(project: project, source: "Codex", message: body) }
            }
        case "approval-requested":
            if NotificationPreferences.systemEnabled {
                SystemNotifier.shared.notify(
                    title: MessageFormatter.notificationTitle(kind: .approval, source: "Codex", project: project),
                    body: MessageFormatter.notificationBody(detail: body)
                )
            }
            if NotificationPreferences.telegramEnabled {
                Task { await telegramBot?.sendToolConfirmation(project: project, source: "Codex", message: body) }
            }
        case "user-input-requested":
            if NotificationPreferences.systemEnabled {
                SystemNotifier.shared.notify(
                    title: MessageFormatter.notificationTitle(kind: .input, source: "Codex", project: project),
                    body: MessageFormatter.notificationBody(detail: body)
                )
            }
            if NotificationPreferences.telegramEnabled {
                Task { await telegramBot?.sendNotification(project: project, source: "Codex", message: "等待输入: \(body)") }
            }
        default:
            if NotificationPreferences.systemEnabled {
                SystemNotifier.shared.notify(
                    title: MessageFormatter.notificationTitle(kind: .info, source: "Codex", project: project),
                    body: MessageFormatter.notificationBody(detail: body)
                )
            }
            if NotificationPreferences.telegramEnabled {
                Task { await telegramBot?.sendNotification(project: project, source: "Codex", message: body) }
            }
        }
    }

    private func handleStop(json: [String: Any]) {
        let cwd = stringValue(in: json, key: "cwd")
        let lastMessage = stringValue(in: json, key: "last_assistant_message").isEmpty
            ? stringValue(in: json, key: "lastMessage")
            : stringValue(in: json, key: "last_assistant_message")
        let project = projectName(from: cwd)
        guard !shouldThrottle(key: "stop:\(project)") else { return }
        if shouldDeduplicate(source: "Claude", project: project, eventType: "stop", message: lastMessage) {
            log.notice("event=hook_deduplicated source=Claude project=\(project) type=stop")
            return
        }
        if NotificationPreferences.systemEnabled {
            SystemNotifier.shared.notify(
                title: MessageFormatter.notificationTitle(kind: .completion, source: "Claude", project: project),
                body: MessageFormatter.notificationBody(detail: lastMessage)
            )
        }
        if NotificationPreferences.telegramEnabled {
            Task { await telegramBot?.sendCompletion(project: project, source: "Claude", message: lastMessage) }
        }
    }

    func projectName(from cwd: String, fallback: String = "unknown") -> String {
        let project = cwd.split(separator: "/").last.map(String.init) ?? cwd
        return project.isEmpty ? fallback : project
    }

    private func stringValue(in json: [String: Any], key: String) -> String {
        json[key] as? String ?? ""
    }

    private func normalizedMessage(_ text: String) -> String {
        let stripped = MessageFormatter.prepare(text, maxLength: Constants.messageTruncateLength)
        let lowercased = stripped.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return lowercased.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    private func codexBody(from json: [String: Any]) -> String {
        let lastMessage = stringValue(in: json, key: "last-assistant-message")
        if !lastMessage.isEmpty {
            return MessageFormatter.prepare(lastMessage)
        }

        if let messages = json["input-messages"] as? [String] {
            let joined = messages.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty {
                return MessageFormatter.prepare(joined)
            }
        }

        switch stringValue(in: json, key: "type") {
        case "agent-turn-complete":
            return "Codex 任务已完成"
        case "approval-requested":
            return "Codex 需要你的确认"
        case "user-input-requested":
            return "Codex 正在等待你的输入"
        default:
            return "收到 Codex 通知"
        }
    }

    private func permissionSummary(from message: String) -> String {
        guard let tool = extractFirstMatch(
            pattern: #"(?i)permission to use\s+([a-z0-9._/-]+)"#,
            in: message
        ) else {
            return message
        }
        return "工具: \(tool)"
    }

    private func extractFirstMatch(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges >= 2 else {
            return nil
        }
        guard let captureRange = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[captureRange])
    }

    nonisolated private func sendResponse(conn: NWConnection, status: Int, body: String) {
        let bodyData = body.data(using: .utf8) ?? Data()
        let reason = reasonPhrase(for: status)
        let response = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
        var responseData = response.data(using: .utf8)!
        responseData.append(bodyData)
        conn.send(content: responseData, completion: .contentProcessed { _ in conn.cancel() })
    }

    nonisolated private func reasonPhrase(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Payload Too Large"
        default: return "Error"
        }
    }
}

// CCBot/Services/HookServer.swift
import Foundation
import Network
import os.log

private let log = Logger(subsystem: "com.ccbot.app", category: "HookServer")
private let maxHookBodyBytes = 1_048_576 // 1 MB
private let maxHookRequestBytes = 1_056_768 // body + headers safety margin
private let httpHeaderSeparator = Data("\r\n\r\n".utf8)

struct ParsedRequest {
    let method: String
    let path: String
    let body: Data
    let authorizationHeader: String?
}

struct NotificationDelivery {
    let kind: MessageFormatter.NotificationKind
    let source: String
    let project: String
    let scopeKey: String
    let message: String
    let eventType: String
    let throttleKey: String?
}

private struct RecentInteractiveState {
    let kind: MessageFormatter.NotificationKind
    let recordedAt: Date
}

private struct CodexRolloutCompletionState {
    let isSubagent: Bool
    let hasMatchingTaskComplete: Bool
    let message: String?
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
    private var recentInteractiveStates: [String: RecentInteractiveState] = [:]
    private let throttleInterval: TimeInterval = 3
    private let deduplicateInterval: TimeInterval = 6
    private let completionSuppressionInterval: TimeInterval = 1
    private var restartAttempts = 0
    private let maxRestartAttempts = 3
    private nonisolated static let permissionRegex = try! NSRegularExpression(
        pattern: #"(?i)permission to use\s+([a-z0-9._/-]+)"#
    )
    private nonisolated static let inputRegex = try! NSRegularExpression(
        pattern: #"(?i)\b(?:waiting for|awaiting|needs?|requires?)\s+(?:your\s+)?input\b|\binput required\b"#
    )
    private nonisolated static let claudeMetadataPromptMarkers = [
        "generate metadata for a coding agent based on the user prompt.",
        "title: short descriptive label",
        "return json only with a single field 'title'.",
    ]

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
        guard let headerRange = data.range(of: httpHeaderSeparator),
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
        guard let headerRange = data.range(of: httpHeaderSeparator),
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
            await handleCodexNotification(json: json)
            sendResponse(conn: conn, status: 200, body: "{}")
        case "/hook/codex-permission-request":
            handleCodexPermissionRequest(json: json)
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

    func shouldThrottle(delivery: NotificationDelivery) -> Bool {
        guard let throttleKey = delivery.throttleKey else { return false }
        return shouldThrottle(key: throttleKey)
    }

    func shouldDeduplicate(source: String, project: String, eventType: String, message: String) -> Bool {
        shouldDeduplicate(source: source, scopeKey: project, eventType: eventType, message: message)
    }

    func shouldDeduplicate(source: String, scopeKey: String, eventType: String, message: String) -> Bool {
        let normalized = normalizedMessage(message)
        guard !normalized.isEmpty else { return false }
        let fingerprint = "\(source)|\(scopeKey)|\(eventType)|\(normalized)"
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

    func recordInteractiveStateIfNeeded(for delivery: NotificationDelivery, now: Date = Date()) {
        pruneInteractiveStates(now: now)
        guard delivery.kind == .approval || delivery.kind == .input else { return }
        recentInteractiveStates[interactiveStateKey(for: delivery)] = RecentInteractiveState(
            kind: delivery.kind,
            recordedAt: now
        )
    }

    func shouldSuppressCompletion(for delivery: NotificationDelivery, now: Date = Date()) -> Bool {
        pruneInteractiveStates(now: now)
        guard delivery.kind == .completion else { return false }
        if delivery.source == Constants.sourceCodex,
           delivery.eventType == Constants.codexEventTurnComplete {
            return false
        }
        let key = interactiveStateKey(for: delivery)
        guard let recent = recentInteractiveStates[key] else { return false }
        return now.timeIntervalSince(recent.recordedAt) < completionSuppressionInterval
    }

    private func dispatchNotification(kind: MessageFormatter.NotificationKind, source: String, project: String, message: String) {
        guard NotificationPreferences.systemEnabled || NotificationPreferences.telegramEnabled else { return }
        let title = MessageFormatter.notificationTitle(kind: kind, source: source, project: project)
        let body = MessageFormatter.notificationBody(detail: message)
        if NotificationPreferences.systemEnabled {
            SystemNotifier.shared.notify(title: title, body: body)
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

    private func handleClaudeNotification(json: [String: Any]) {
        guard let delivery = makeClaudeDelivery(json: json) else { return }
        process(delivery: delivery)
    }

    private func handleCodexNotification(json: [String: Any]) async {
        let eventType = stringValue(in: json, key: "type")
        let delivery: NotificationDelivery?
        if eventType == Constants.codexEventTurnComplete {
            delivery = await makeCodexCompletionDelivery(json: json)
        } else {
            delivery = makeCodexDelivery(json: json)
        }

        guard let delivery else {
            log.notice("event=hook_ignored source=Codex type=\(eventType)")
            return
        }
        process(delivery: delivery)
    }

    private func handleCodexPermissionRequest(json: [String: Any]) {
        guard let delivery = makeCodexPermissionRequestDelivery(json: json) else {
            log.notice("event=hook_ignored source=Codex type=permission-request")
            return
        }
        process(delivery: delivery)
    }

    private func handleStop(json: [String: Any]) {
        guard let delivery = makeStopDelivery(json: json) else { return }
        process(delivery: delivery)
    }

    func makeClaudeDelivery(json: [String: Any]) -> NotificationDelivery? {
        let cwd = stringValue(in: json, key: "cwd")
        let rawMessage = stringValue(in: json, key: "message")
        guard let normalizedMessage = nonEmptyMessage(rawMessage) else { return nil }
        let project = projectName(from: cwd)
        let kind = claudeNotificationKind(for: normalizedMessage)
        let eventType: String
        let message: String

        switch kind {
        case .approval:
            eventType = Constants.codexEventApproval
            message = permissionSummary(from: normalizedMessage)
        case .input:
            eventType = Constants.codexEventInput
            message = normalizedMessage
        case .info:
            eventType = "notification"
            message = normalizedMessage
        case .completion:
            eventType = "notification"
            message = normalizedMessage
        }

        return NotificationDelivery(
            kind: kind,
            source: Constants.sourceClaude,
            project: project,
            scopeKey: notificationScopeKey(cwd: cwd, json: json, fallback: project),
            message: message,
            eventType: eventType,
            throttleKey: (kind == .approval || kind == .input) ? nil : "notification:\(project)"
        )
    }

    func makeCodexDelivery(json: [String: Any]) -> NotificationDelivery? {
        let eventType = stringValue(in: json, key: "type")
        guard let kind = codexNotificationKind(for: eventType) else { return nil }

        let cwd = stringValue(in: json, key: "cwd")
        let project = projectName(from: cwd, fallback: Constants.sourceCodex)
        let body = codexBody(from: json, kind: kind)
        let message: String
        if kind == .input, body != "Codex 正在等待你的输入" {
            message = "等待输入: \(body)"
        } else {
            message = body
        }

        return NotificationDelivery(
            kind: kind,
            source: Constants.sourceCodex,
            project: project,
            scopeKey: notificationScopeKey(cwd: cwd, json: json, fallback: project),
            message: message,
            eventType: eventType,
            throttleKey: nil
        )
    }

    func makeCodexCompletionDelivery(
        json: [String: Any],
        codexHome: URL? = nil,
        fileManager: FileManager = .default,
        pollInterval: Duration = .milliseconds(150),
        maxAttempts: Int = 6
    ) async -> NotificationDelivery? {
        guard stringValue(in: json, key: "type") == Constants.codexEventTurnComplete else { return nil }

        let cwd = stringValue(in: json, key: "cwd")
        let project = projectName(from: cwd, fallback: Constants.sourceCodex)
        let scopeKey = notificationScopeKey(cwd: cwd, json: json, fallback: project)

        guard let threadID = codexThreadID(from: json),
              let turnID = codexTurnID(from: json)
        else {
            log.notice("event=hook_ignored source=Codex type=\(Constants.codexEventTurnComplete) reason=missing_identity")
            return nil
        }

        let home = codexHome ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        let attempts = max(1, maxAttempts)

        for attempt in 1...attempts {
            if let rolloutURL = codexRolloutURL(threadID: threadID, codexHome: home, fileManager: fileManager),
               let completionState = codexRolloutCompletionState(at: rolloutURL, turnID: turnID) {
                if completionState.isSubagent {
                    return nil
                }

                if completionState.hasMatchingTaskComplete {
                    return NotificationDelivery(
                        kind: .completion,
                        source: Constants.sourceCodex,
                        project: project,
                        scopeKey: scopeKey,
                        message: completionState.message ?? codexCompletionFallbackMessage(from: json),
                        eventType: Constants.codexEventTurnComplete,
                        throttleKey: nil
                    )
                }
            }

            if attempt < attempts {
                try? await Task.sleep(for: pollInterval)
            }
        }

        return nil
    }

    func makeCodexPermissionRequestDelivery(json: [String: Any]) -> NotificationDelivery? {
        guard stringValue(in: json, key: "hook_event_name") == "PermissionRequest" else { return nil }

        let cwd = stringValue(in: json, key: "cwd")
        let project = projectName(from: cwd, fallback: Constants.sourceCodex)
        let toolInput = json["tool_input"] as? [String: Any] ?? [:]
        let description = stringValue(in: toolInput, key: "description")
        let command = stringValue(in: toolInput, key: "command")
        guard let detail = nonEmptyMessage(description) ?? nonEmptyMessage(command) else { return nil }

        return NotificationDelivery(
            kind: .approval,
            source: Constants.sourceCodex,
            project: project,
            scopeKey: notificationScopeKey(cwd: cwd, json: json, fallback: project),
            message: "命令: \(detail)",
            eventType: Constants.codexEventApproval,
            throttleKey: nil
        )
    }

    func makeStopDelivery(
        json: [String: Any],
        claudeHome: URL? = nil,
        fileManager: FileManager = .default
    ) -> NotificationDelivery? {
        if isClaudeMetadataStop(json: json, claudeHome: claudeHome, fileManager: fileManager) {
            log.notice("event=hook_ignored source=Claude type=stop reason=metadata_session")
            return nil
        }

        let cwd = stringValue(in: json, key: "cwd")
        let rawMessage = stringValue(in: json, key: "last_assistant_message").isEmpty
            ? stringValue(in: json, key: "lastMessage")
            : stringValue(in: json, key: "last_assistant_message")
        let project = projectName(from: cwd)
        let message = nonEmptyMessage(rawMessage) ?? "Claude 任务已完成"

        return NotificationDelivery(
            kind: .completion,
            source: Constants.sourceClaude,
            project: project,
            scopeKey: notificationScopeKey(cwd: cwd, json: json, fallback: project),
            message: message,
            eventType: "stop",
            throttleKey: nil
        )
    }

    private func process(delivery: NotificationDelivery) {
        let now = Date()
        if shouldSuppressCompletion(for: delivery, now: now) {
            let key = interactiveStateKey(for: delivery)
            recentInteractiveStates.removeValue(forKey: key)
            log.notice("event=hook_completion_suppressed source=\(delivery.source) project=\(delivery.project) type=\(delivery.eventType)")
            return
        }

        guard !shouldThrottle(delivery: delivery) else { return }
        if shouldDeduplicate(
            source: delivery.source,
            scopeKey: delivery.scopeKey,
            eventType: delivery.eventType,
            message: delivery.message
        ) {
            log.notice("event=hook_deduplicated source=\(delivery.source) project=\(delivery.project) type=\(delivery.eventType)")
            return
        }

        recordInteractiveStateIfNeeded(for: delivery, now: now)
        dispatchNotification(
            kind: delivery.kind,
            source: delivery.source,
            project: delivery.project,
            message: delivery.message
        )
    }

    func projectName(from cwd: String, fallback: String = "unknown") -> String {
        let project = cwd.split(separator: "/").last.map(String.init) ?? cwd
        return project.isEmpty ? fallback : project
    }

    private func stringValue(in json: [String: Any], key: String) -> String {
        json[key] as? String ?? ""
    }

    private static let whitespaceRegex = try! NSRegularExpression(pattern: #"\s+"#)

    private func normalizedMessage(_ text: String) -> String {
        let stripped = MessageFormatter.prepare(text, maxLength: Constants.messageTruncateLength)
        let lowercased = stripped.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(lowercased.startIndex..<lowercased.endIndex, in: lowercased)
        return Self.whitespaceRegex.stringByReplacingMatches(in: lowercased, range: range, withTemplate: " ")
    }

    private func nonEmptyMessage(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func claudeNotificationKind(for message: String) -> MessageFormatter.NotificationKind {
        if message.contains("needs your permission") {
            return .approval
        }
        let range = NSRange(message.startIndex..<message.endIndex, in: message)
        if Self.inputRegex.firstMatch(in: message, range: range) != nil {
            return .input
        }
        return .info
    }

    private func codexNotificationKind(for eventType: String) -> MessageFormatter.NotificationKind? {
        switch eventType {
        case Constants.codexEventApproval:
            return .approval
        case Constants.codexEventInput:
            return .input
        default:
            return nil
        }
    }

    private func codexBody(from json: [String: Any], kind: MessageFormatter.NotificationKind) -> String {
        if let detail = preparedCodexMessage(
            from: json,
            keys: [
                "last-assistant-message",
                "last_assistant_message",
                "lastAssistantMessage",
                "last-agent-message",
                "last_agent_message",
                "lastAgentMessage",
            ]
        ) {
            return detail
        }

        if let messages = json["input-messages"] as? [String] {
            let joined = messages.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if let detail = nonEmptyMessage(MessageFormatter.prepareCodexDetail(joined)) {
                return detail
            }
        }

        switch kind {
        case .completion:
            return "Codex 任务已完成"
        case .approval:
            return "Codex 需要你的确认"
        case .input:
            return "Codex 正在等待你的输入"
        case .info:
            return "收到 Codex 通知"
        }
    }

    private func permissionSummary(from message: String) -> String {
        let range = NSRange(message.startIndex..<message.endIndex, in: message)
        guard let match = Self.permissionRegex.firstMatch(in: message, range: range),
              match.numberOfRanges >= 2,
              let captureRange = Range(match.range(at: 1), in: message)
        else {
            return message
        }
        return "工具: \(String(message[captureRange]))"
    }

    private func interactiveStateKey(for delivery: NotificationDelivery) -> String {
        "\(delivery.source)|\(delivery.scopeKey)"
    }

    private func notificationScopeKey(cwd: String, json: [String: Any], fallback: String) -> String {
        let base = nonEmptyMessage(cwd) ?? fallback
        let identities = executionIdentityComponents(from: json)
        let suffix = identities.isEmpty ? "" : "|" + identities.joined(separator: "|")
        return "\(base)\(suffix)"
    }

    private func executionIdentityComponents(from json: [String: Any]) -> [String] {
        let directKeys = [
            "session_id",
            "session-id",
            "sessionId",
            "conversation_id",
            "conversation-id",
            "conversationId",
            "request_id",
            "request-id",
            "requestId",
            "tool_call_id",
            "tool-call-id",
            "toolCallId",
        ]
        let nestedKeys = [
            ("session", "session"),
            ("conversation", "conversation"),
            ("request", "request"),
            ("tool_call", "tool_call"),
            ("toolCall", "tool_call"),
        ]

        var components: [String] = []

        for key in directKeys {
            if let value = nonEmptyMessage(stringValue(in: json, key: key)) {
                components.append("\(key)=\(value)")
            }
        }

        for (containerKey, label) in nestedKeys {
            guard let container = json[containerKey] as? [String: Any],
                  let value = nonEmptyMessage(stringValue(in: container, key: "id"))
            else { continue }
            components.append("\(label)=\(value)")
        }

        var uniqueComponents: [String] = []
        for component in components where !uniqueComponents.contains(component) {
            uniqueComponents.append(component)
        }
        return uniqueComponents
    }

    private func codexThreadID(from json: [String: Any]) -> String? {
        identityValue(
            in: json,
            directKeys: [
                "thread-id",
                "thread_id",
                "threadId",
                "session_id",
                "session-id",
                "sessionId",
                "conversation_id",
                "conversation-id",
                "conversationId",
            ],
            nestedKeys: ["thread", "session", "conversation"]
        )
    }

    private func claudeSessionID(from json: [String: Any]) -> String? {
        identityValue(
            in: json,
            directKeys: ["session_id", "session-id", "sessionId"],
            nestedKeys: ["session"]
        )
    }

    private func codexTurnID(from json: [String: Any]) -> String? {
        identityValue(
            in: json,
            directKeys: ["turn-id", "turn_id", "turnId"],
            nestedKeys: ["turn"]
        )
    }

    private func identityValue(in json: [String: Any], directKeys: [String], nestedKeys: [String]) -> String? {
        for key in directKeys {
            if let value = nonEmptyMessage(stringValue(in: json, key: key)) {
                return value
            }
        }

        for containerKey in nestedKeys {
            guard let container = json[containerKey] as? [String: Any],
                  let value = nonEmptyMessage(stringValue(in: container, key: "id"))
            else { continue }
            return value
        }

        return nil
    }

    private func preparedCodexMessage(from json: [String: Any], keys: [String]) -> String? {
        for key in keys {
            let raw = stringValue(in: json, key: key)
            guard !raw.isEmpty else { continue }
            let prepared = MessageFormatter.prepareCodexDetail(raw)
            if let message = nonEmptyMessage(prepared) {
                return message
            }
        }
        return nil
    }

    private func codexCompletionFallbackMessage(from json: [String: Any]) -> String {
        preparedCodexMessage(
            from: json,
            keys: [
                "last-assistant-message",
                "last_assistant_message",
                "lastAssistantMessage",
                "last-agent-message",
                "last_agent_message",
                "lastAgentMessage",
            ]
        ) ?? "Codex 任务已完成"
    }

    private func isClaudeMetadataStop(
        json: [String: Any],
        claudeHome: URL?,
        fileManager: FileManager
    ) -> Bool {
        guard let sessionID = claudeSessionID(from: json) else { return false }

        let home = claudeHome ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
        guard let transcriptURL = claudeTranscriptURL(sessionID: sessionID, claudeHome: home, fileManager: fileManager) else {
            return false
        }

        return claudeTranscriptContainsMetadataPrompt(at: transcriptURL)
    }

    private func codexRolloutURL(threadID: String, codexHome: URL, fileManager: FileManager) -> URL? {
        let sessionsDirectory = codexHome.appendingPathComponent("sessions", isDirectory: true)
        guard let enumerator = fileManager.enumerator(
            at: sessionsDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let expectedSuffix = "-\(threadID).jsonl"
        for case let fileURL as URL in enumerator {
            guard fileURL.lastPathComponent.hasSuffix(expectedSuffix) else { continue }
            return fileURL
        }

        return nil
    }

    private func claudeTranscriptURL(sessionID: String, claudeHome: URL, fileManager: FileManager) -> URL? {
        let projectsDirectory = claudeHome.appendingPathComponent("projects", isDirectory: true)
        guard let enumerator = fileManager.enumerator(
            at: projectsDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let expectedName = "\(sessionID).jsonl"
        for case let fileURL as URL in enumerator {
            guard fileURL.lastPathComponent == expectedName else { continue }
            return fileURL
        }

        return nil
    }

    private func codexRolloutCompletionState(at rolloutURL: URL, turnID: String) -> CodexRolloutCompletionState? {
        guard let contents = try? String(contentsOf: rolloutURL, encoding: .utf8) else {
            return nil
        }

        var isSubagent = false
        var hasMatchingTaskComplete = false
        var message: String?

        for line in contents.split(whereSeparator: \.isNewline) {
            guard let data = String(line).data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String
            else { continue }

            if type == "session_meta" {
                isSubagent = isSubagentCodexRollout(json: json)
                if isSubagent {
                    return CodexRolloutCompletionState(
                        isSubagent: true,
                        hasMatchingTaskComplete: false,
                        message: nil
                    )
                }
                continue
            }

            guard type == "event_msg",
                  let payload = json["payload"] as? [String: Any],
                  stringValue(in: payload, key: "type") == "task_complete",
                  stringValue(in: payload, key: "turn_id") == turnID
            else { continue }

            hasMatchingTaskComplete = true
            if let detail = preparedCodexMessage(
                from: payload,
                keys: ["last_agent_message", "last-agent-message", "lastAgentMessage"]
            ) {
                message = detail
            }
        }

        return CodexRolloutCompletionState(
            isSubagent: isSubagent,
            hasMatchingTaskComplete: hasMatchingTaskComplete,
            message: message
        )
    }

    private func claudeTranscriptContainsMetadataPrompt(at transcriptURL: URL) -> Bool {
        guard let contents = try? String(contentsOf: transcriptURL, encoding: .utf8) else {
            return false
        }

        for line in contents.split(whereSeparator: \.isNewline) {
            guard let data = String(line).data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let prompt = claudePromptText(from: json)
            else { continue }

            if isClaudeMetadataPrompt(prompt) {
                return true
            }
        }

        return false
    }

    private func isSubagentCodexRollout(json: [String: Any]) -> Bool {
        guard let payload = json["payload"] as? [String: Any],
              let source = payload["source"] as? [String: Any],
              let subagent = source["subagent"] as? [String: Any],
              let threadSpawn = subagent["thread_spawn"] as? [String: Any]
        else {
            return false
        }

        return nonEmptyMessage(stringValue(in: threadSpawn, key: "parent_thread_id")) != nil
    }

    private func claudePromptText(from json: [String: Any]) -> String? {
        let type = stringValue(in: json, key: "type")
        if type == "last-prompt" {
            return nonEmptyMessage(stringValue(in: json, key: "lastPrompt"))
        }

        guard type == "user",
              let message = json["message"] as? [String: Any],
              stringValue(in: message, key: "role") == "user",
              let content = message["content"] as? [[String: Any]]
        else {
            return nil
        }

        let text = content.compactMap { item -> String? in
            guard stringValue(in: item, key: "type") == "text" else { return nil }
            return nonEmptyMessage(stringValue(in: item, key: "text"))
        }.joined(separator: "\n")

        return nonEmptyMessage(text)
    }

    private func isClaudeMetadataPrompt(_ prompt: String) -> Bool {
        let normalized = normalizedPromptText(prompt)
        return Self.claudeMetadataPromptMarkers.allSatisfy { normalized.contains($0) }
    }

    private func normalizedPromptText(_ text: String) -> String {
        let trimmed = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        return Self.whitespaceRegex.stringByReplacingMatches(in: trimmed, range: range, withTemplate: " ")
    }

    private func pruneInteractiveStates(now: Date) {
        if recentInteractiveStates.count > 100 {
            recentInteractiveStates = recentInteractiveStates.filter {
                now.timeIntervalSince($0.value.recordedAt) < completionSuppressionInterval
            }
            return
        }

        recentInteractiveStates = recentInteractiveStates.filter {
            now.timeIntervalSince($0.value.recordedAt) < completionSuppressionInterval
        }
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

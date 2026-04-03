// CCBot/Services/HookServer.swift
import Foundation
import Network
import os.log

private let log = Logger(subsystem: "com.ccbot.app", category: "HookServer")

@MainActor
final class HookServer: ObservableObject {
    @Published var errorMessage: String?

    private var listener: NWListener?
    private var telegramBot: TelegramBot?
    let port: UInt16 = 62400

    // Throttle: same (project, hookType) within interval skips notification
    private var lastNotifyTimes: [String: Date] = [:]
    private let throttleInterval: TimeInterval = 3

    private var systemEnabled: Bool {
        UserDefaults.standard.object(forKey: "systemNotifyEnabled") as? Bool ?? true
    }

    private var telegramEnabled: Bool {
        UserDefaults.standard.object(forKey: "telegramNotifyEnabled") as? Bool ?? true
    }

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
                    log.notice("HookServer ready on :\(self?.port ?? 0)")
                case .failed(let error):
                    self?.errorMessage = "监听失败: \(error.localizedDescription)"
                    log.error("HookServer failed: \(error)")
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

    nonisolated private func receiveHTTPRequest(conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, let data, !data.isEmpty else { conn.cancel(); return }
            guard let text = String(data: data, encoding: .utf8) else { conn.cancel(); return }

            // Parse HTTP: find path and body
            let lines = text.components(separatedBy: "\r\n")
            guard let requestLine = lines.first else { conn.cancel(); return }
            let parts = requestLine.split(separator: " ")
            guard parts.count >= 2 else { conn.cancel(); return }
            let path = String(parts[1])

            // Extract JSON body (after \r\n\r\n)
            guard let bodyRange = text.range(of: "\r\n\r\n"),
                  let bodyData = text[bodyRange.upperBound...].data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
            else { self.sendResponse(conn: conn, status: 400, body: "{}"); return }

            // json is [String: Any] (not Sendable); copy scalar values before hopping to MainActor
            let pathCopy = path
            let jsonCopy: [String: String] = json.reduce(into: [:]) { result, pair in
                if let value = pair.value as? String {
                    result[pair.key] = value
                }
            }
            Task { @MainActor in
                await self.dispatch(path: pathCopy, json: jsonCopy, conn: conn)
            }
        }
    }

    private func dispatch(path: String, json: [String: String], conn: NWConnection) async {
        switch path {
        case "/hook/notification":
            handleNotification(json: json)
            sendResponse(conn: conn, status: 200, body: "{}")
        case "/hook/stop":
            handleStop(json: json)
            sendResponse(conn: conn, status: 200, body: "{}")
        default:
            sendResponse(conn: conn, status: 404, body: "{}")
        }
    }

    private func shouldThrottle(key: String) -> Bool {
        let now = Date()
        if let last = lastNotifyTimes[key], now.timeIntervalSince(last) < throttleInterval {
            return true
        }
        lastNotifyTimes[key] = now
        return false
    }

    private func handleNotification(json: [String: String]) {
        let cwd = json["cwd"] ?? ""
        let message = json["message"] ?? ""
        let project = cwd.split(separator: "/").last.map(String.init) ?? cwd
        guard !shouldThrottle(key: "notification:\(project)") else { return }

        // Detect permission request: "Claude needs your permission to use Bash"
        let isPermission = message.contains("needs your permission")
        let title: String
        let body: String
        if isPermission {
            title = "⏳ [\(project)] 需要确认"
            body = message
        } else {
            title = "🔔 [\(project)]"
            body = String(message.prefix(200))
        }

        if systemEnabled {
            SystemNotifier.shared.notify(title: title, body: body)
        }
        if telegramEnabled {
            if isPermission {
                Task { await telegramBot?.sendToolConfirmation(project: project, message: body) }
            } else {
                Task { await telegramBot?.sendNotification(project: project, message: message) }
            }
        }
    }

    private func handleStop(json: [String: String]) {
        let cwd = json["cwd"] ?? ""
        let lastMessage = json["last_assistant_message"] ?? json["lastMessage"] ?? ""
        let project = cwd.split(separator: "/").last.map(String.init) ?? cwd
        guard !shouldThrottle(key: "stop:\(project)") else { return }
        if systemEnabled {
            SystemNotifier.shared.notifyCompletion(project: project, message: lastMessage)
        }
        if telegramEnabled {
            Task { await telegramBot?.sendCompletion(project: project, message: lastMessage) }
        }
    }

    nonisolated private func sendResponse(conn: NWConnection, status: Int, body: String) {
        let bodyData = body.data(using: .utf8) ?? Data()
        let response = "HTTP/1.1 \(status) OK\r\nContent-Type: application/json\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
        var responseData = response.data(using: .utf8)!
        responseData.append(bodyData)
        conn.send(content: responseData, completion: .contentProcessed { _ in conn.cancel() })
    }
}

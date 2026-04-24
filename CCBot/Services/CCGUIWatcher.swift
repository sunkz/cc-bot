// CCBot/Services/CCGUIWatcher.swift
import Foundation
import os.log

private let log = Logger(subsystem: "com.ccbot.app", category: "CCGUIWatcher")

// MARK: - Permission request info (passed across threads)

struct PermissionRequestInfo: Sendable {
    let toolName: String
    let project: String
    let file: String
    let detail: String?
}

// MARK: - File system monitor (non-actor-isolated, runs on global queue)

/// Monitors a directory for new files matching permission-request patterns.
/// Completely free of actor isolation — safe to call from any queue.
private final class DirectoryMonitor: @unchecked Sendable {
    private let dir: String
    private let autoApproveGracePeriod: TimeInterval
    private let seenLock = NSLock()
    private var seenFiles: Set<String>
    /// Permission requests awaiting notification — cancelled if a response file appears.
    private var pendingNotifications: [String: PermissionRequestInfo] = [:]
    let onNewRequests: @Sendable ([PermissionRequestInfo]) -> Void

    init(
        dir: String,
        initialFiles: Set<String>,
        autoApproveGracePeriod: TimeInterval = 1.5,
        onNewRequests: @escaping @Sendable ([PermissionRequestInfo]) -> Void
    ) {
        self.dir = dir
        self.autoApproveGracePeriod = autoApproveGracePeriod
        self.seenFiles = initialFiles
        self.onNewRequests = onNewRequests
    }

    func scan() {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
        let existingResponseMatches = Set(files.compactMap { file -> String? in
            guard file.hasSuffix(".json"), file.hasPrefix(Constants.prefixResponse) else { return nil }
            return Constants.prefixRequest + file.dropFirst(Constants.prefixResponse.count)
        })

        var immediateNotifications: [PermissionRequestInfo] = []
        var deferredRequests: [(String, PermissionRequestInfo)] = []

        seenLock.lock()
        for file in files {
            guard !seenFiles.contains(file) else { continue }
            seenFiles.insert(file)

            guard file.hasSuffix(".json") else { continue }

            if file.hasPrefix(Constants.prefixResponse) {
                let requestFile = Constants.prefixRequest + file.dropFirst(Constants.prefixResponse.count)
                if pendingNotifications.removeValue(forKey: requestFile) != nil {
                    log.debug("Auto-approved (response detected), skipping notification: \(requestFile)")
                }
                continue
            }

            let isAskQuestion = file.hasPrefix(Constants.prefixAskQuestion) && !file.contains("-response-")
            let isPlanApproval = file.hasPrefix(Constants.prefixPlanApproval) && !file.contains("-response-")
            let isPermissionRequest = file.hasPrefix(Constants.prefixRequest)

            guard isAskQuestion || isPlanApproval || isPermissionRequest else { continue }
            if isPermissionRequest, existingResponseMatches.contains(file) {
                log.debug("Existing response matched, skipping notification: \(file)")
                continue
            }

            let path = (dir as NSString).appendingPathComponent(file)
            guard let data = FileManager.default.contents(atPath: path),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            let toolName = json["toolName"] as? String ?? "unknown"
            let cwd = json["cwd"] as? String ?? ""
            let project = cwd.split(separator: "/").last.map(String.init) ?? "unknown"
            let detail = Self.requestDetail(from: json, file: file)
            let info = PermissionRequestInfo(toolName: toolName, project: project, file: file, detail: detail)

            log.notice("CC GUI permission request detected: \(toolName) in \(project)")

            if isAskQuestion || isPlanApproval {
                immediateNotifications.append(info)
            } else {
                pendingNotifications[file] = info
                deferredRequests.append((file, info))
            }
        }
        seenFiles = seenFiles.filter { files.contains($0) }
        seenLock.unlock()

        // Schedule deferred notifications OUTSIDE the lock
        for (file, _) in deferredRequests {
            let callback = self.onNewRequests
            DispatchQueue.global().asyncAfter(deadline: .now() + autoApproveGracePeriod) { [self] in
                seenLock.lock()
                let pending = pendingNotifications.removeValue(forKey: file)
                seenLock.unlock()
                if let pending {
                    callback([pending])
                }
            }
        }

        if !immediateNotifications.isEmpty {
            onNewRequests(immediateNotifications)
        }
    }

    private static func requestDetail(from json: [String: Any], file: String) -> String? {
        if file.hasPrefix(Constants.prefixAskQuestion) {
            return firstNonEmptyText(in: json, keys: ["question", "prompt", "message", "text"])
        }
        if file.hasPrefix(Constants.prefixPlanApproval) {
            return firstNonEmptyText(in: json, keys: ["summary", "message", "plan", "text", "title"])
        }
        return firstNonEmptyText(in: json, keys: ["description", "command", "message", "prompt", "text"])
    }

    private static func firstNonEmptyText(in json: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let text = normalizedText(from: json[key]) {
                return text
            }
        }
        return nil
    }

    private static func normalizedText(from value: Any?) -> String? {
        switch value {
        case let text as String:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let items as [String]:
            let joined = items
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            return joined.isEmpty ? nil : joined
        default:
            return nil
        }
    }
}

// MARK: - CCGUIWatcher (MainActor, owns the monitor)

/// Watches the CC GUI plugin's file-system IPC directory for permission requests.
/// When a `request-*.json` file appears, it triggers a notification.
@MainActor
final class CCGUIWatcher: ObservableObject {
    @Published var isWatching = false

    private var source: DispatchSourceFileSystemObject?
    private var dirFD: Int32 = -1
    private var monitor: DirectoryMonitor?
    private var telegramBot: TelegramBot?
    private let permissionDirOverride: String?
    private let autoApproveGracePeriod: TimeInterval
    private let notificationSink: ((PermissionRequestInfo) -> Void)?

    init(
        permissionDir: String? = nil,
        autoApproveGracePeriod: TimeInterval = 1.5,
        notificationSink: ((PermissionRequestInfo) -> Void)? = nil
    ) {
        self.permissionDirOverride = permissionDir
        self.autoApproveGracePeriod = autoApproveGracePeriod
        self.notificationSink = notificationSink
    }


    /// Directory the CC GUI plugin uses for permission IPC.
    nonisolated static var permissionDir: String {
        ProcessInfo.processInfo.environment["CLAUDE_PERMISSION_DIR"]
            ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("claude-permission")
    }

    func start(telegram: TelegramBot) {
        guard !isWatching else { return }
        self.telegramBot = telegram

        let dir = permissionDirOverride ?? Self.permissionDir
        let fm = FileManager.default

        // Ensure directory exists
        if !fm.fileExists(atPath: dir) {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }

        // Create monitor with callback that dispatches to MainActor
        let monitor = DirectoryMonitor(
            dir: dir,
            initialFiles: [],
            autoApproveGracePeriod: autoApproveGracePeriod
        ) { [weak self] requests in
            Task { @MainActor [weak self] in
                guard let self else { return }
                for req in requests {
                    self.notify(req)
                }
            }
        }
        self.monitor = monitor

        let fd = open(dir, O_EVTONLY)
        guard fd >= 0 else {
            log.error("Failed to open watch directory: \(dir)")
            return
        }
        dirFD = fd

        let source = Self.makeSource(fd: fd, monitor: monitor)
        source.resume()
        self.source = source
        isWatching = true
        monitor.scan()
        log.notice("Watching CC GUI permission dir: \(dir)")
    }

    func stop() {
        source?.cancel()
        source = nil
        monitor = nil
        dirFD = -1
        isWatching = false
    }

    // MARK: - DispatchSource factory (nonisolated to avoid inheriting MainActor)

    nonisolated private static func makeSource(fd: Int32, monitor: DirectoryMonitor) -> DispatchSourceFileSystemObject {
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,
            queue: .global()
        )
        source.setEventHandler {
            monitor.scan()
        }
        source.setCancelHandler {
            close(fd)
        }
        return source
    }

    // MARK: - Notify (MainActor)

    private func notify(_ req: PermissionRequestInfo) {
        if let notificationSink {
            notificationSink(req)
            return
        }

        let content = Self.notificationContent(for: req)
        let kind = content.kind
        let body = content.body

        guard NotificationPreferences.systemEnabled || NotificationPreferences.telegramEnabled else { return }
        let source = Constants.sourceClaude
        let title = MessageFormatter.notificationTitle(kind: kind, source: source, project: req.project)
        let formattedBody = MessageFormatter.notificationBody(detail: body)
        if NotificationPreferences.systemEnabled {
            SystemNotifier.shared.notify(title: title, body: formattedBody)
        }
        if NotificationPreferences.telegramEnabled {
            Task {
                switch kind {
                case .input:
                    await telegramBot?.sendInputRequest(project: req.project, source: source, message: body)
                case .approval:
                    await telegramBot?.sendToolConfirmation(project: req.project, source: source, message: body)
                case .completion, .info:
                    await telegramBot?.sendNotification(project: req.project, source: source, message: body)
                }
            }
        }
    }

    static func notificationContent(for req: PermissionRequestInfo) -> (kind: MessageFormatter.NotificationKind, body: String) {
        if req.file.hasPrefix(Constants.prefixAskQuestion) {
            return (.input, req.detail ?? "需要回答问题")
        }
        if req.file.hasPrefix(Constants.prefixPlanApproval) {
            return (.approval, req.detail ?? "需要确认计划")
        }
        return (.approval, req.detail ?? "工具: \(req.toolName)")
    }
}

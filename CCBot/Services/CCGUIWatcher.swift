// CCBot/Services/CCGUIWatcher.swift
import Foundation
import os.log

private let log = Logger(subsystem: "com.ccbot.app", category: "CCGUIWatcher")

// MARK: - Permission request info (passed across threads)

struct PermissionRequestInfo: Sendable {
    let toolName: String
    let project: String
    let file: String
}

// MARK: - File system monitor (non-actor-isolated, runs on global queue)

/// Monitors a directory for new files matching permission-request patterns.
/// Completely free of actor isolation — safe to call from any queue.
private final class DirectoryMonitor: @unchecked Sendable {
    private let dir: String
    private let seenLock = NSLock()
    private var seenFiles: Set<String>
    /// Permission requests awaiting notification — cancelled if a response file appears.
    private var pendingNotifications: [String: PermissionRequestInfo] = [:]
    let onNewRequests: @Sendable ([PermissionRequestInfo]) -> Void

    /// Grace period before firing a notification. Gives CC GUI time to
    /// auto-approve and produce a response file that we can detect.
    /// Java PermissionRequestWatcher polls every 500ms; auto-approved
    /// responses appear within ~600ms and are consumed by Node.js ~100ms later.
    private static let autoApproveGracePeriod: TimeInterval = 1.5

    init(dir: String, initialFiles: Set<String>, onNewRequests: @escaping @Sendable ([PermissionRequestInfo]) -> Void) {
        self.dir = dir
        self.seenFiles = initialFiles
        self.onNewRequests = onNewRequests
    }

    func scan() {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }

        var immediateNotifications: [PermissionRequestInfo] = []
        var deferredRequests: [(String, PermissionRequestInfo)] = []

        seenLock.lock()
        for file in files {
            guard !seenFiles.contains(file) else { continue }
            seenFiles.insert(file)

            guard file.hasSuffix(".json") else { continue }

            if file.hasPrefix("response-") {
                let requestFile = "request-" + file.dropFirst("response-".count)
                if pendingNotifications.removeValue(forKey: requestFile) != nil {
                    log.debug("Auto-approved (response detected), skipping notification: \(requestFile)")
                }
                continue
            }

            let isAskQuestion = file.hasPrefix("ask-user-question-") && !file.contains("-response-")
            let isPlanApproval = file.hasPrefix("plan-approval-") && !file.contains("-response-")
            let isPermissionRequest = file.hasPrefix("request-")

            guard isAskQuestion || isPlanApproval || isPermissionRequest else { continue }

            let path = (dir as NSString).appendingPathComponent(file)
            guard let data = FileManager.default.contents(atPath: path),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            let toolName = json["toolName"] as? String ?? "unknown"
            let cwd = json["cwd"] as? String ?? ""
            let project = cwd.split(separator: "/").last.map(String.init) ?? "unknown"
            let info = PermissionRequestInfo(toolName: toolName, project: project, file: file)

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
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.autoApproveGracePeriod) { [self] in
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


    /// Directory the CC GUI plugin uses for permission IPC.
    nonisolated static var permissionDir: String {
        ProcessInfo.processInfo.environment["CLAUDE_PERMISSION_DIR"]
            ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("claude-permission")
    }

    func start(telegram: TelegramBot) {
        guard !isWatching else { return }
        self.telegramBot = telegram

        let dir = Self.permissionDir
        let fm = FileManager.default

        // Ensure directory exists
        if !fm.fileExists(atPath: dir) {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }

        // Seed seen files so we don't fire on stale requests
        let initialFiles = Set((try? fm.contentsOfDirectory(atPath: dir)) ?? [])

        // Create monitor with callback that dispatches to MainActor
        let monitor = DirectoryMonitor(dir: dir, initialFiles: initialFiles) { [weak self] requests in
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
        let title: String
        let body: String

        if req.file.hasPrefix("ask-user-question-") {
            title = "❓ [Claude] [\(req.project)] 需要回答"
            body = "AskUserQuestion"
        } else if req.file.hasPrefix("plan-approval-") {
            title = "📋 [Claude] [\(req.project)] 计划待审批"
            body = "ExitPlanMode"
        } else {
            title = "⏳ [Claude] [\(req.project)] 需要确认"
            body = req.toolName
        }

        if NotificationPreferences.systemEnabled {
            SystemNotifier.shared.notify(title: title, body: body)
        }
        if NotificationPreferences.telegramEnabled {
            Task { await telegramBot?.sendToolConfirmation(project: req.project, source: "Claude", message: body) }
        }
    }
}

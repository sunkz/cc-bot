// CCBot/AppState.swift
import SwiftUI
import os.log

private let log = Logger(subsystem: "com.ccbot.app", category: "AppState")

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    let hookServer = HookServer()
    let telegramBot = TelegramBot()
    let ccguiWatcher = CCGUIWatcher()
    let updateChecker = UpdateChecker()

    private var started = false

    func start() {
        guard !started else { return }
        started = true

        // Ensure auth token file exists
        _ = Constants.ensureAuthToken()

        SystemNotifier.shared.requestPermission()

        do { try HookInstaller.updateScriptsIfInstalled() }
        catch { log.error("Hook scripts update failed: \(error)") }

        do { try CodexNotifyInstaller.updateScriptIfInstalled() }
        catch { log.error("Codex notify update failed: \(error)") }

        hookServer.start(telegram: telegramBot)

        if UserDefaults.standard.object(forKey: "ccguiWatcherEnabled") as? Bool ?? true {
            ccguiWatcher.start(telegram: telegramBot)
        }
    }
}

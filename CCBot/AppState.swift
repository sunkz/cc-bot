// CCBot/AppState.swift
import SwiftUI

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
        SystemNotifier.shared.requestPermission()
        HookInstaller.updateScriptsIfInstalled()
        ACPProxy.updateIfInstalled()
        hookServer.start(telegram: telegramBot)

        // Start CC GUI watcher if enabled
        if UserDefaults.standard.object(forKey: "ccguiWatcherEnabled") as? Bool ?? true {
            ccguiWatcher.start(telegram: telegramBot)
        }
    }
}

// CCBot/CCBotApp.swift
import SwiftUI

@main
struct CCBotApp: App {
    @StateObject private var appState = AppState.shared

    init() {
        if !RuntimeEnvironment.isRunningTests() {
            DispatchQueue.main.async {
                AppState.shared.start()
            }
            NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil,
                queue: .main
            ) { _ in
                AppState.shared.stop()
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                hookServer: appState.hookServer,
                telegramBot: appState.telegramBot,
                ccguiWatcher: appState.ccguiWatcher,
                updateChecker: appState.updateChecker
            )
        } label: {
            menuBarLabel
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarLabel: some View {
        Image(nsImage: {
            let img = NSImage(named: "MenuBarIcon") ?? NSImage()
            img.size = NSSize(width: 18, height: 18)
            img.isTemplate = false
            return img
        }())
    }
}

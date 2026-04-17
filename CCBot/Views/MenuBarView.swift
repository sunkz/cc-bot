// CCBot/Views/MenuBarView.swift
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var hookServer: HookServer
    @ObservedObject var telegramBot: TelegramBot
    @ObservedObject var ccguiWatcher: CCGUIWatcher
    @ObservedObject var updateChecker: UpdateChecker

    @AppStorage("telegramChatId") private var chatId = ""
    @AppStorage("systemNotifyEnabled") private var systemNotifyEnabled = true
    @AppStorage("telegramNotifyEnabled") private var telegramNotifyEnabled = true
    @AppStorage("ccguiWatcherEnabled") private var ccguiWatcherEnabled = true

    @State private var tokenInput: String = ""
    @State private var hookInstalled = HookInstaller.isInstalled()
    @State private var codexNotifyInstalled = CodexNotifyInstaller.isInstalled()
    @State private var alertMessage: String?
    @State private var tokenPersistTask: Task<Void, Never>?

    private let claudeHookPaths = [
        "~/.claude/hooks/cc-bot-notification.sh",
        "~/.claude/hooks/cc-bot-stop.sh",
        "~/.claude/settings.json",
    ]

    private let codexHookPaths = [
        "~/.codex/hooks/cc-bot-notify.sh",
        "~/.codex/config.toml",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 状态
            HStack(spacing: 6) {
                Circle()
                    .fill(hookServer.errorMessage == nil ? .green : .red)
                    .frame(width: 8, height: 8)
                Text(hookServer.errorMessage ?? "监听中 :\(hookServer.port)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Divider().padding(.vertical, 6)

            // 通知渠道
            channelSection
            Divider().padding(.vertical, 6)

            // Hook
            hookSection
            Divider().padding(.vertical, 6)

            // IDEA 集成
            ideaSection
            Divider().padding(.vertical, 6)

            // 版本 & 获取更新 & 退出
            HStack {
                Link("获取更新 ↗", destination: URL(string: "https://github.com/sunkz/cc-bot/releases")!)
                    .font(.callout)
                if updateChecker.hasUpdate, let latest = updateChecker.latestVersion {
                    HStack(spacing: 3) {
                        Text("v\(updateChecker.currentVersion)")
                            .strikethrough()
                            .foregroundStyle(.tertiary)
                        Text("v\(latest)")
                            .foregroundColor(.orange)
                    }
                    .font(.caption)
                } else {
                    Text("v\(updateChecker.currentVersion)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button("退出") {
                    NSApplication.shared.terminate(nil)
                }
                .controlSize(.small)
            }
            if let updateError = updateChecker.lastErrorMessage {
                Text(updateError)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.top, 4)
            }
        }
        .padding(14)
        .frame(width: 260)
        .task {
            tokenInput = telegramBot.token
            hookInstalled = HookInstaller.isInstalled()
            codexNotifyInstalled = CodexNotifyInstaller.isInstalled()
            await updateChecker.check()
        }
        .alert("CCBot", isPresented: .init(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button("OK") { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
        .onDisappear {
            tokenPersistTask?.cancel()
            telegramBot.saveToken(tokenInput)
        }
    }

    // MARK: - Sections

    private var channelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("通知渠道").font(.caption).foregroundStyle(.tertiary)

            HStack {
                Text("系统通知")
                Spacer()
                Toggle("", isOn: $systemNotifyEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }

            HStack {
                Text("Telegram Bot 通知")
                Spacer()
                Toggle("", isOn: $telegramNotifyEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }

            VStack(spacing: 6) {
                SecureField("Bot Token", text: $tokenInput)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .onChange(of: tokenInput) { newValue in
                        tokenPersistTask?.cancel()
                        tokenPersistTask = Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(400))
                            guard !Task.isCancelled else { return }
                            telegramBot.saveToken(newValue)
                        }
                    }
                    .onSubmit {
                        tokenPersistTask?.cancel()
                        telegramBot.saveToken(tokenInput)
                    }
                TextField("Chat ID", text: $chatId)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
            }
        }
    }

    private var hookSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CLI 集成").font(.caption).foregroundStyle(.tertiary)

            HStack {
                Circle()
                    .fill(hookInstalled ? .green : .gray)
                    .frame(width: 8, height: 8)
                Text("Claude Code Hook")
                    .font(.callout)

                Spacer()

                Button(hookInstalled ? "卸载" : "安装") {
                    toggleHook()
                }
                .controlSize(.small)
            }

            if hookInstalled {
                ForEach(claudeHookPaths, id: \.self) { path in
                    Text(path)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            HStack {
                Circle()
                    .fill(codexNotifyInstalled ? .green : .gray)
                    .frame(width: 8, height: 8)
                Text("Codex Notify")
                    .font(.callout)

                Spacer()

                Button(codexNotifyInstalled ? "卸载" : "安装") {
                    toggleCodexNotify()
                }
                .controlSize(.small)
            }

            if codexNotifyInstalled {
                ForEach(codexHookPaths, id: \.self) { path in
                    Text(path)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
    }

    private var ideaSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("IDEA 集成").font(.caption).foregroundStyle(.tertiary)

            // CC GUI Watcher
            HStack {
                Circle()
                    .fill(ccguiWatcher.isWatching ? .green : .gray)
                    .frame(width: 8, height: 8)
                Text("CC GUI 监听")
                    .font(.callout)
                Spacer()
                Toggle("", isOn: $ccguiWatcherEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .onChange(of: ccguiWatcherEnabled) { enabled in
                        toggleCCGUIWatcher(enabled: enabled)
                    }
            }

        }
    }

    // MARK: - Actions

    private func toggleCCGUIWatcher(enabled: Bool) {
        if enabled {
            ccguiWatcher.start(telegram: AppState.shared.telegramBot)
        } else {
            ccguiWatcher.stop()
        }
    }

    private func toggleHook() {
        do {
            if hookInstalled {
                try HookInstaller.uninstall()
            } else {
                try HookInstaller.install()
            }
            hookInstalled = HookInstaller.isInstalled()
        } catch HookInstaller.InstallError.claudeNotInstalled {
            alertMessage = "未检测到 ~/.claude 目录，请先安装 Claude Code"
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func toggleCodexNotify() {
        do {
            if codexNotifyInstalled {
                try CodexNotifyInstaller.uninstall()
            } else {
                try CodexNotifyInstaller.install()
            }
            codexNotifyInstalled = CodexNotifyInstaller.isInstalled()
        } catch CodexNotifyInstaller.InstallError.codexNotInstalled {
            alertMessage = "未检测到 ~/.codex 目录，请先安装 Codex"
        } catch CodexNotifyInstaller.InstallError.notifyAlreadyConfigured {
            alertMessage = "检测到 ~/.codex/config.toml 已有 notify 配置，请先手动处理现有配置"
        } catch {
            alertMessage = error.localizedDescription
        }
    }

}

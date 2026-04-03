// CCBot/Views/MenuBarView.swift
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var hookServer: HookServer
    @ObservedObject var telegramBot: TelegramBot
    @ObservedObject var ccguiWatcher: CCGUIWatcher
    @ObservedObject var updateChecker: UpdateChecker

    @AppStorage("telegramBotToken") private var token = ""
    @AppStorage("telegramChatId") private var chatId = ""
    @AppStorage("systemNotifyEnabled") private var systemNotifyEnabled = true
    @AppStorage("telegramNotifyEnabled") private var telegramNotifyEnabled = true
    @AppStorage("ccguiWatcherEnabled") private var ccguiWatcherEnabled = true

    @State private var hookInstalled = HookInstaller.isInstalled()
    @State private var acpProxyInstalled = ACPProxy.isInstalled()
    @State private var alertMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 状态
            statusSection
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
        }
        .padding(14)
        .frame(width: 260)
        .task {
            hookInstalled = HookInstaller.isInstalled()
            acpProxyInstalled = ACPProxy.isInstalled()
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
    }

    // MARK: - Sections

    private var statusSection: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(hookServer.errorMessage == nil ? .green : .red)
                .frame(width: 8, height: 8)
            Text(hookServer.errorMessage ?? "监听中 :\(hookServer.port)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

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
                SecureField("Bot Token", text: $token)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                TextField("Chat ID", text: $chatId)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
            }
        }
    }

    private var hookSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Claude Code Hook").font(.caption).foregroundStyle(.tertiary)

            HStack {
                Circle()
                    .fill(hookInstalled ? .green : .gray)
                    .frame(width: 8, height: 8)
                Text(hookInstalled ? "已安装" : "未安装")
                    .font(.callout)

                Spacer()

                Button(hookInstalled ? "卸载" : "安装") {
                    toggleHook()
                }
                .controlSize(.small)
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

            // ACP Proxy
            HStack {
                Circle()
                    .fill(acpProxyInstalled ? .green : .gray)
                    .frame(width: 8, height: 8)
                Text("ACP Proxy")
                    .font(.callout)
                Spacer()
                Button(acpProxyInstalled ? "卸载" : "安装") {
                    toggleACPProxy()
                }
                .controlSize(.small)
            }

            if acpProxyInstalled {
                Text("~/.claude/hooks/cc-bot-acp-proxy.mjs")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
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

    private func toggleACPProxy() {
        do {
            if acpProxyInstalled {
                ACPProxy.uninstall()
            } else {
                try ACPProxy.install()
            }
            acpProxyInstalled = ACPProxy.isInstalled()
        } catch {
            alertMessage = error.localizedDescription
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
}

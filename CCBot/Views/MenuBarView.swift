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
    @State private var hookPathDisclosureState = HookPathDisclosureState()
    @State private var alertMessage: String?
    @State private var tokenPersistTask: Task<Void, Never>?

    private let claudeHookPaths = [
        "~/.claude/hooks/cc-bot-notification.sh",
        "~/.claude/hooks/cc-bot-stop.sh",
        "~/.claude/settings.json",
    ]

    private let codexHookPaths = [
        "~/.codex/hooks/cc-bot-notify.sh",
        "~/.codex/hooks/cc-bot-permission-request.sh",
        "~/.codex/hooks.json",
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
            HStack(alignment: .center, spacing: 8) {
                footerActionButton(
                    title: Constants.projectHomepageLinkTitle,
                    iconAssetName: Constants.projectHomepageIconAssetName,
                    help: "打开 GitHub 项目主页",
                    accessibilityLabel: "打开 GitHub 项目主页",
                    action: openProjectHomepage
                )
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
                Spacer(minLength: 0)
                footerActionButton(title: "退出", action: terminateApp)
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
            hookPathDisclosureState.reset()
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

            hookRow(
                title: "Claude Code Hook",
                isInstalled: hookInstalled,
                disclosureKind: .claude,
                paths: claudeHookPaths,
                action: toggleHook
            )

            hookRow(
                title: "Codex Hook",
                isInstalled: codexNotifyInstalled,
                disclosureKind: .codex,
                paths: codexHookPaths,
                action: toggleCodexNotify
            )
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

    private func openProjectHomepage() {
        NSWorkspace.shared.open(Constants.projectHomepageURL)
    }

    private func terminateApp() {
        NSApplication.shared.terminate(nil)
    }

    @ViewBuilder
    private func hookRow(
        title: String,
        isInstalled: Bool,
        disclosureKind: HookPathDisclosureKind,
        paths: [String],
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle()
                    .fill(isInstalled ? .green : .gray)
                    .frame(width: 8, height: 8)
                Text(title)
                    .font(.callout)

                Spacer()

                if isInstalled {
                    Button {
                        hookPathDisclosureState.toggle(disclosureKind)
                    } label: {
                        Image(systemName: hookPathDisclosureState.isExpanded(disclosureKind) ? "chevron.down" : "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(hookPathDisclosureState.isExpanded(disclosureKind) ? "收起安装路径" : "展开安装路径")
                }

                Button(isInstalled ? "卸载" : "安装") {
                    action()
                }
                .controlSize(.small)
            }

            if isInstalled && hookPathDisclosureState.isExpanded(disclosureKind) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(paths, id: \.self) { path in
                        Text(path)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                .padding(.leading, 14)
            }
        }
    }

    private func footerActionButton(
        title: String,
        iconAssetName: String? = nil,
        help: String? = nil,
        accessibilityLabel: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let iconAssetName {
                    Image(iconAssetName)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 11, height: 11)
                        .foregroundStyle(.secondary)
                }

                Text(title)
                    .font(.caption.weight(.medium))
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(help ?? title)
        .accessibilityLabel(accessibilityLabel ?? title)
    }

    private func toggleHook() {
        do {
            if hookInstalled {
                try HookInstaller.uninstall()
            } else {
                try HookInstaller.install()
            }
            hookInstalled = HookInstaller.isInstalled()
            if !hookInstalled {
                hookPathDisclosureState.setExpanded(.claude, isExpanded: false)
            }
        } catch HookInstaller.InstallError.claudeNotInstalled {
            alertMessage = "未检测到 ~/.claude 目录，请先安装 Claude Code"
        } catch HookInstaller.InstallError.invalidSettingsJSON {
            alertMessage = "检测到 ~/.claude/settings.json 不是合法 JSON，请先手动修复后再操作"
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
            if !codexNotifyInstalled {
                hookPathDisclosureState.setExpanded(.codex, isExpanded: false)
            }
        } catch CodexNotifyInstaller.InstallError.codexNotInstalled {
            alertMessage = "未检测到 ~/.codex 目录，请先安装 Codex"
        } catch CodexNotifyInstaller.InstallError.notifyAlreadyConfigured {
            alertMessage = "检测到 ~/.codex/config.toml 已有 notify 配置，请先手动处理现有配置"
        } catch CodexNotifyInstaller.InstallError.invalidHooksJSON {
            alertMessage = "检测到 ~/.codex/hooks.json 不是合法 JSON，请先手动修复后再操作"
        } catch {
            alertMessage = error.localizedDescription
        }
    }

}

enum HookPathDisclosureKind: Hashable {
    case claude
    case codex
}

struct HookPathDisclosureState {
    private var expandedKinds: Set<HookPathDisclosureKind> = []

    func isExpanded(_ kind: HookPathDisclosureKind) -> Bool {
        expandedKinds.contains(kind)
    }

    mutating func toggle(_ kind: HookPathDisclosureKind) {
        setExpanded(kind, isExpanded: !isExpanded(kind))
    }

    mutating func setExpanded(_ kind: HookPathDisclosureKind, isExpanded: Bool) {
        if isExpanded {
            expandedKinds.insert(kind)
        } else {
            expandedKinds.remove(kind)
        }
    }

    mutating func reset() {
        expandedKinds.removeAll()
    }
}

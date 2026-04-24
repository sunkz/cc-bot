# IDEA 集成：让 Claude Code 在 IDE 中也能发送系统通知

## 背景

CCBot 最初只支持 Claude Code **终端 CLI** 的通知 — 通过 Claude Code 的 `Notification` Hook 机制，在权限确认（Yes/No）时推送桌面通知。

但在 **IntelliJ IDEA** 中使用 Claude Code 时，权限确认（Allow/Not Allow）**不会触发系统通知**。用户必须盯着 IDE 等待，体验很差。

IDEA 中有两种 Claude Code 集成方式，它们的通信机制完全不同：

| 集成方式 | 通信协议 | 权限确认机制 |
|---------|---------|------------|
| **ACP 官方集成** | JSON-RPC over stdio (ACP 协议) | `session/request_permission` 消息，IDE 渲染 Allow/Deny 按钮 |
| **CC GUI 插件** | NDJSON over stdio + 文件系统 IPC | 写 `/tmp/claude-permission/request-*.json`，Java 端轮询并渲染 UI |

两种方式都绕过了 CLI 的 `Notification` Hook，所以 CCBot 原有的 Hook 机制无法感知。

## 研究过程

### ACP 协议分析

ACP（Agent Client Protocol）使用 **stdio 管道** 进行 1:1 的点对点通信：

```
IDEA (ACP Client) ←→ stdin/stdout ←→ Claude Code (ACP Server)
```

当 Claude Code 需要权限时，它向 IDE 发送一个 JSON-RPC request：

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "session/request_permission",
  "params": {
    "toolCallUpdate": { "toolName": "Bash", ... },
    "options": [
      { "id": "allow_once", "kind": "allowOnce" },
      { "id": "reject_once", "kind": "rejectOnce" }
    ]
  }
}
```

stdio 管道由 IDE 独占，**第三方进程无法直接订阅**。

### CC GUI 插件分析

通过分析 [jetbrains-cc-gui](https://github.com/zhukunpenglinyutong/jetbrains-cc-gui) 源码（`ai-bridge/permission-ipc.js`），发现它使用**文件系统 IPC**：

```
Node.js daemon                              Java Plugin
     │                                           │
     │  写入 request-{session}-{id}.json ──────→ │  检测文件，显示 Allow/Deny UI
     │                                           │
     │  ←────── 写入 response-{session}-{id}.json │  用户点击后写入响应
     │                                           │
     │  读取响应文件，返回结果                      │
```

所有文件都在 `/tmp/claude-permission/` 目录下，这意味着**任何进程都可以监听这个目录**。

## 解决方案

### 方案一：CC GUI — 文件系统 Watcher

直接用 `DispatchSource` 监控 `/tmp/claude-permission/` 目录：

```
/tmp/claude-permission/
├── request-*.json           ← 权限请求（触发通知）
├── ask-user-question-*.json ← 问答请求（触发通知）
└── plan-approval-*.json     ← 计划审批（触发通知）
```

当新的 `request-*.json` 文件出现时，读取 `toolName` 和 `cwd`，发送系统通知。

**优点**：零侵入，不修改 CC GUI 任何代码，纯旁路监听。

### 方案二：ACP — stdio 管道代理

由于无法直接订阅 stdio 管道，采用**中间人代理**方式：

```
IDEA ←→ stdin/stdout ←→ ACP Proxy ←→ stdin/stdout ←→ Claude Code
                            │
                            ├─ 检测 request_permission
                            └─ POST → CCBot HTTP :62400
```

代理脚本安装到 `~/.claude/hooks/cc-bot-acp-proxy.mjs`，用户在 IDEA 的 `acp.json` 中配置 `command` 指向它即可。

## 实现

### CCGUIWatcher

核心挑战是 **Swift 6 严格并发**。`CCGUIWatcher` 是 `@MainActor`（因为 `ObservableObject` 需要），但 `DispatchSource` 回调在 global queue 执行。

**踩坑 1**：直接在 `setEventHandler` 闭包中调用 `self?.scanDirectory()`

```swift
// 崩溃：Block was expected to execute on queue [com.apple.main-thread]
source.setEventHandler { [weak self] in
    self?.scanDirectory() // ← self 是 @MainActor，触发隔离检查
}
```

**踩坑 2**：将 `scanDirectory` 标记为 `nonisolated`，用 `NSLock` 保护共享状态

```swift
// 还是崩溃！Swift 6 中 @MainActor 方法内定义的闭包自动继承 MainActor 隔离
// 即使调用的是 nonisolated 方法，闭包本身也会被检查
```

**最终方案**：将文件监听逻辑抽到独立的 `DirectoryMonitor` 类（非 actor 隔离），DispatchSource 创建移到 `nonisolated static` 方法中：

```swift
// DirectoryMonitor: @unchecked Sendable，完全脱离 actor 隔离
private final class DirectoryMonitor: @unchecked Sendable {
    func scan() { /* 安全地在任意队列执行 */ }
}

// DispatchSource 在 nonisolated 上下文中创建，闭包不继承 MainActor
@MainActor final class CCGUIWatcher: ObservableObject {
    nonisolated private static func makeSource(fd: Int32, monitor: DirectoryMonitor)
        -> DispatchSourceFileSystemObject
    {
        let source = DispatchSource.makeFileSystemObjectSource(...)
        source.setEventHandler { monitor.scan() } // 不继承 MainActor
        return source
    }
}
```

### ACP Proxy

Node.js 脚本，spawn 真正的 `claude` 进程，逐行读取 stdout，检测 `request_permission`：

```javascript
const rl = createInterface({ input: child.stdout });
rl.on('line', (line) => {
  process.stdout.write(line + '\n'); // 原样转发
  if (line.includes('request_permission')) {
    // 解析 JSON-RPC，POST 到 CCBot
    notifyCCBot(toolName, cwd);
  }
});
```

## 文件变更

```
CCBot/
├── Services/
│   ├── ACPProxy.swift        ← 新增：ACP 代理脚本管理 + 内嵌 Node.js 脚本
│   └── CCGUIWatcher.swift    ← 新增：文件系统监听器
├── AppState.swift            ← 修改：启动 CCGUIWatcher
├── CCBotApp.swift            ← 修改：传入 ccguiWatcher
└── Views/
    └── MenuBarView.swift     ← 修改：新增「IDEA 集成」区域
```

## 使用

### CC GUI 插件

开箱即用。CCBot 启动后自动监听 `/tmp/claude-permission/`，无需额外配置。

菜单栏「IDEA 集成」区域可以开关 CC GUI 监听。

### ACP 官方集成

1. 在 CCBot 菜单栏点击「安装」ACP Proxy
2. 修改 IDEA 的 ACP 配置，将 `command` 指向代理脚本：

```json
{
  "command": "~/.claude/hooks/cc-bot-acp-proxy.mjs",
  "args": ["--acp"]
}
```

## 参考

- [Agent Client Protocol 规范](https://agentclientprotocol.com/protocol/overview)
- [CC GUI 插件源码](https://github.com/zhukunpenglinyutong/jetbrains-cc-gui)
- [CC GUI permission-ipc.js](https://github.com/zhukunpenglinyutong/jetbrains-cc-gui/blob/main/ai-bridge/permission-ipc.js)
- [JetBrains ACP 文档](https://www.jetbrains.com/help/ai-assistant/acp.html)
- [Claude Code Hooks 文档](https://code.claude.com/docs/en/hooks)

# CC GUI 自动批准操作过滤

## 背景

cc-bot 的 `CCGUIWatcher` 监听 `$TMPDIR/claude-permission/` 目录中的 request 文件来检测权限请求。但用户反馈：部分收到的通知实际上是 cc-gui **自动批准**的操作，并不需要用户确认。

## 根因分析

通过阅读 [jetbrains-cc-gui](https://github.com/zhukunpenglinyutong/jetbrains-cc-gui) 源码，发现权限判断分为 **两个阶段**：

### 第一阶段：Node.js 端直接放行（不写文件）

`ai-bridge/services/claude/permission-mode.js` 中的 `shouldAutoApproveTool()` 在以下情况直接返回 `approve`，**不产生任何 request 文件**：

| 模式 | 自动放行的工具 |
|------|--------------|
| 所有模式 | `AUTO_ALLOW_TOOLS`：TaskCreate/Get/Update/List、CronCreate/Delete/List、EnterPlanMode 等 |
| `bypassPermissions` | 所有工具（除 AskUserQuestion） |
| `acceptEdits` | READ_ONLY_TOOLS（Glob/Grep/Read/WebFetch 等）+ EDIT_TOOLS（Edit/Write）+ 文件操作工具 |

这些操作 cc-bot 本来就看不到，不存在问题。

### 第二阶段：文件 IPC → Java 端可能自动批准（问题所在）

未被第一阶段放行的工具会调用 `requestPermissionFromJava()`，写入 `request-*.json` 文件。Java 端 `PermissionService.handlePermissionRequest()` 处理时：

```
1. 检查 tool-level 记忆（用户之前选了 "Allow and don't ask again"）
   → 命中：自动批准，写 response，删除 request，不弹对话框
2. 检查 parameter-level 记忆
   → 命中：同上
3. 都没命中 → 弹出权限对话框，等待用户操作
```

**典型场景**：在 `default` 模式下，用户对 `Read` 工具点过 "Allow always" 后，后续每次 `Read` 调用仍会写 request 文件（被 CCGUIWatcher 捕获并发通知），但 cc-gui 直接从内存自动批准了。

### 时序分析

cc-gui **两种情况都会删除 request 文件**，不能靠检查 request 文件是否存在来区分：

```
自动批准路径：
t=0ms       Node.js 写入 request-X.json
t=0~500ms   Java PermissionRequestWatcher 轮询（间隔 500ms）
t=~500ms    Java 读取文件，内存命中 → 写入 response-X.json → 删除 request-X.json
t=~600ms    Node.js 轮询（间隔 100ms）发现 response → 读取 → 删除 response-X.json

弹对话框路径：
t=0ms       Node.js 写入 request-X.json
t=0~500ms   Java PermissionRequestWatcher 轮询
t=~500ms    Java 读取文件，无记忆命中 → 删除 request-X.json → 弹出对话框
t=???       用户操作后 → Java 写入 response-X.json
t=???+100ms Node.js 发现 response → 读取 → 删除
```

**关键区别**：自动批准时 `response-*.json` 在 request 被处理后**立即出现**（~500ms），而弹对话框时 response 要等用户操作后才出现（秒级到分钟级）。

## 解决方案

利用 kqueue 事件驱动 + response 文件检测的**双信号机制**：

1. **检测到 `request-*.json`** → 存入 `pendingNotifications` 字典，启动 1.5 秒定时器
2. **检测到 `response-*.json`**（kqueue 因 Java 写入 response 触发 scan）→ 通过文件名匹配对应 request（`response-` 前缀替换为 `request-`），从 `pendingNotifications` 中移除 → **取消通知**
3. **1.5 秒定时器到期** → 检查 request 是否仍在 `pendingNotifications` 中，如果在则发通知（说明没有被 response 取消，真正需要用户确认）
4. **`ask-user-question-*` / `plan-approval-*`** → 始终需要用户交互，**立即通知**，不走延迟逻辑

response 文件从 Java 写入到 Node.js 消费约有 **~100ms 窗口**，kqueue 在 Java 写入时触发 scan，此时 Node.js 尚未删除 response 文件，因此能可靠地捕获到。

### 代码变更

文件：`CCBot/Services/CCGUIWatcher.swift` — `DirectoryMonitor`

```swift
private var pendingNotifications: [String: PermissionRequestInfo] = [:]
private static let autoApproveGracePeriod: TimeInterval = 1.5

func scan() {
    // ...
    for file in files {
        // 检测 response 文件 → 取消匹配的待发通知
        if file.hasPrefix("response-") {
            let requestFile = "request-" + file.dropFirst("response-".count)
            pendingNotifications.removeValue(forKey: requestFile)
            continue
        }

        // ask-user-question / plan-approval → 立即通知
        // request-* → 存入 pendingNotifications，延迟 1.5s
        if isPermissionRequest {
            pendingNotifications[file] = info
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
                // 如果还在 pending 中（未被 response 取消），则通知
                if let pending = pendingNotifications.removeValue(forKey: file) {
                    callback([pending])
                }
            }
        }
    }
}
```

### 影响范围

- 真正需要确认的 `request-*`：通知延迟 1.5 秒
- 自动批准的 `request-*`：通过 response 文件检测取消通知，不再发送
- `ask-user-question-*` / `plan-approval-*`：立即通知，无延迟

# CCBot Comprehensive Optimization Design

## Overview

CCBot is a macOS menu-bar notification bridge for Claude Code CLI and Codex CLI (unsandboxed, no `com.apple.security.app-sandbox`). This spec covers 12 optimization items across architecture, reliability, security, and code quality — executed as an aggressive refactoring pass.

**Note:** This version is not backwards-compatible. Downgrade to previous versions is unsupported (Keychain-stored tokens and auth-bearing hook scripts will not work with older builds).

## 1. Global Configuration & Shared Infrastructure

### 1.1 Unified Port Constant

**Problem:** Port `62400` is hardcoded independently in 4 files (`HookServer.swift`, `HookInstaller.swift`, `CodexNotifyInstaller.swift`, `ACPProxy.swift`). Changing one without updating others breaks hook→server communication.

**Solution:** New `CCBot/Constants.swift`:

```swift
enum Constants {
    static let serverPort: UInt16 = 62400
    static let messageTruncateLength = 200
}
```

All bash/Node.js script templates use string interpolation `\(Constants.serverPort)` instead of literal `62400`. `HookServer.port` references `Constants.serverPort`.

### 1.2 Notification Preferences Extraction

**Problem:** Identical `systemEnabled` / `telegramEnabled` computed properties duplicated in `HookServer` and `CCGUIWatcher`.

**Solution:** New `CCBot/Utilities/NotificationPreferences.swift`:

```swift
enum NotificationPreferences {
    static var systemEnabled: Bool {
        UserDefaults.standard.object(forKey: "systemNotifyEnabled") as? Bool ?? true
    }
    static var telegramEnabled: Bool {
        UserDefaults.standard.object(forKey: "telegramNotifyEnabled") as? Bool ?? true
    }
}
```

Both `HookServer` and `CCGUIWatcher` reference `NotificationPreferences` instead of their own copies.

### 1.3 Unified Message Processing Pipeline

**Problem:** `stripMarkdown + truncate` pattern repeated in 5+ places with inconsistent truncation lengths (SystemNotifier uses 100, everything else uses 200).

**Solution:** New `CCBot/Utilities/MessageFormatter.swift`:

```swift
enum MessageFormatter {
    static func prepare(_ text: String, maxLength: Int = Constants.messageTruncateLength) -> String {
        String(stripMarkdown(text).prefix(maxLength))
    }
}
```

The canonical truncation point is `MessageFormatter.prepare()`. All callers use it instead of inline `stripMarkdown + .prefix()`:
- `TelegramBot.format*` static methods — preserved with unchanged signatures, refactored internally to use `MessageFormatter.prepare()`
- `SystemNotifier.notifyCompletion` — use `MessageFormatter.prepare()` (was 100 chars, now unified to 200)
- `HookServer.handleClaudeNotification` line 182 — remove the inline `String(message.prefix(200))`, let downstream `TelegramBot.format*` and `SystemNotifier` handle truncation via `MessageFormatter`

### 1.4 Enhanced stripMarkdown

**Problem:** Current implementation only removes `*_`\`~>#` characters and `[text](url)` links. Leaves HTML tags, list markers, horizontal rules.

**Solution:** Extend `stripMarkdown` in `StringUtils.swift` to also handle (all patterns use `(?m)` multiline flag where anchors are needed):
- HTML tags: `<[^>]+>` → removed
- Ordered list markers: `(?m)^\d+\.\s+` → removed
- Unordered list markers: `(?m)^[-+]\s+` → removed
- Horizontal rules: `(?m)^-{3,}$` → removed

---

## 2. Reliability & Self-Healing

### 2.1 Telegram Send Retry

**Problem:** `TelegramBot.sendMessage` logs errors and gives up. Transient network failures silently drop notifications.

**Solution:** Exponential backoff retry, max 3 attempts:
- Attempt 1: immediate
- Attempt 2: after 1 second
- Attempt 3: after 2 seconds
- 4xx client errors → no retry (permanent failure)
- 5xx / network errors → retry
- Use `try await Task.sleep(for:)` which respects Task cancellation — if the enclosing Task is cancelled (e.g. app quitting), the retry loop exits cleanly
- Concurrent retries from rapid notifications are acceptable — each notification is independent and the Telegram API handles concurrent requests fine. No serialization needed.

### 2.2 HookServer Auto-Recovery

**Problem:** If the TCP listener fails after startup (e.g. port stolen), only `errorMessage` is set. No recovery attempt.

**Solution:** Add `scheduleRestart()` in the `.failed` state handler:
- Max 3 restart attempts
- Delays: 2s, 4s, 6s (linear backoff)
- Reset counter on successful `.ready` state
- Log each restart attempt via the existing `Logger` instance pattern (`private let log = Logger(...)`)
- **Lifecycle:** `scheduleRestart()` must cancel the old listener (`listener?.cancel(); listener = nil`) before calling `startListener()` to avoid leaking the NWListener
- **Delay mechanism:** Use `Task { @MainActor in try? await Task.sleep(for: .seconds(delay)); self.startListener() }` inside the `stateUpdateHandler`'s MainActor task block

### 2.3 Throttle Map Pruning

**Problem:** `lastNotifyTimes` dictionary grows unbounded. Each unique `(hookType, project)` key persists forever.

**Solution:** In `shouldThrottle()`, when map exceeds 100 entries, prune expired entries. The threshold of 100 is generous — in practice each unique `(hookType, project)` creates one entry, and a developer rarely exceeds 50 projects. 100 is a defensive upper bound with no observable overhead:

```swift
if lastNotifyTimes.count > 100 {
    lastNotifyTimes = lastNotifyTimes.filter { now.timeIntervalSince($0.value) < throttleInterval }
}
```

### 2.4 UpdateChecker Time Cache

**Problem:** `MenuBarView.task` calls `updateChecker.check()` every time the menu opens, hitting GitHub API each time.

**Solution:** Add `lastCheckTime` tracking with 1-hour cache interval. `check()` returns immediately if last check was within the interval.

---

## 3. Concurrency Safety & Error Handling

### 3.1 DirectoryMonitor Lock Granularity

**Problem:** `scan()` holds `seenLock` while registering `asyncAfter` callbacks. The callbacks later re-acquire the same lock. While unlikely to deadlock in practice (kqueue is serial + 1.5s delay), the design is fragile.

**Solution:** Shrink lock scope — collect deferred requests into a local array inside the lock, then schedule `asyncAfter` callbacks outside the lock:

1. Lock → iterate files, update `seenFiles`, populate `pendingNotifications`, collect `deferredRequests` array → unlock
2. Loop over `deferredRequests` to schedule `asyncAfter` (lock-free)
3. Fire `immediateNotifications` callback (lock-free)

The `asyncAfter` closures still acquire the lock briefly to check/remove from `pendingNotifications`, but this is safe because the outer lock is no longer held.

### 3.2 Unified Error Handling in Installers

**Problem:** `install()` methods throw errors, but `uninstall()` and `updateScriptsIfInstalled()` use `try?` to silently swallow all errors. Failed updates are invisible.

**Solution:**
- `HookInstaller.updateScriptsIfInstalled()` → `throws`
- `CodexNotifyInstaller.updateScriptIfInstalled()` → `throws`
- `ACPProxy.uninstall()` → `throws`
- `ACPProxy.updateIfInstalled()` → `throws`
- `AppState.start()` wraps each update call in `do/catch` with `os.log` error logging
- `MenuBarView` toggle actions surface uninstall errors via `alertMessage`

---

## 4. Security Hardening

### 4.1 Telegram Token in Keychain

**Problem:** Bot token stored in `@AppStorage` (UserDefaults) = plaintext plist readable by any same-user process.

**Solution:** New `CCBot/Utilities/KeychainHelper.swift` wrapping Security framework:

```swift
enum KeychainHelper {
    static func save(key: String, value: String) -> Bool
    static func load(key: String) -> String?
    static func delete(key: String)
}
```

Uses `kSecClassGenericPassword` with service = `"com.ccbot.app"`.

`TelegramBot` changes:
- Replace `@AppStorage("telegramBotToken")` with `@Published var token: String`
- `init()`: load from Keychain; if empty, check UserDefaults for legacy value, migrate to Keychain, then **delete** the UserDefaults key (`UserDefaults.standard.removeObject(forKey: "telegramBotToken")`)
- Add explicit `func saveToken(_ value: String)` method that writes to Keychain and updates `@Published token`

`chatId` remains in `@AppStorage` — it is not a secret (useless without the bot token).

**SwiftUI binding mechanism in `MenuBarView`:**
- Remove `@AppStorage("telegramBotToken") private var token` from `MenuBarView`
- Use a local `@State private var tokenInput: String` initialized from `telegramBot.token`
- `SecureField` binds to `$tokenInput`
- `.onChange(of: tokenInput)` calls `telegramBot.saveToken(tokenInput)`
- This avoids the `@Published` + `didSet` bypass issue (SwiftUI writes through projected `$` bindings without triggering `didSet`)

### 4.2 HTTP Server Authentication

**Problem:** Any localhost process can POST to `127.0.0.1:62400` and trigger arbitrary notifications.

**Solution:** Random UUID token stored in a dedicated file, read at runtime by hook scripts. This decouples token lifecycle from script reinstallation and avoids baking secrets into plaintext scripts.

**Token storage — file-based (not baked into scripts):**

Token file: `~/.claude/hooks/.ccbot-auth` with `0600` permissions.

```swift
// Constants.swift
static func ensureAuthToken() -> String {
    let tokenPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/hooks/.ccbot-auth")
    if let existing = try? String(contentsOf: tokenPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
       !existing.isEmpty {
        return existing
    }
    let new = UUID().uuidString
    try? new.write(to: tokenPath, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenPath.path)
    return new
}
```

This is a `static func` (not a computed property) to make the side effect explicit. Thread safety: all callers are `@MainActor`, so no race condition.

**HookServer validation:**

New return type for `parseHTTPRequest`:

```swift
struct ParsedRequest {
    let path: String
    let body: Data
    let authorizationHeader: String?
}
```

`dispatch()` validates: `guard request.authorizationHeader == "Bearer \(Constants.ensureAuthToken())" else { sendResponse(401) }`

**Hook scripts read token at runtime:**

Bash scripts:
```bash
#!/bin/bash
TOKEN=$(cat ~/.claude/hooks/.ccbot-auth 2>/dev/null)
INPUT=$(cat)
echo "$INPUT" | curl -sf -X POST http://localhost:\(Constants.serverPort)/hook/notification \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $TOKEN" \
  -d @- --max-time 5 &
exit 0
```

ACP proxy Node.js script:
```javascript
import { readFileSync } from 'node:fs';
const TOKEN = (() => { try { return readFileSync(
  `${process.env.HOME}/.claude/hooks/.ccbot-auth`, 'utf8').trim(); } catch { return ''; } })();
// ... inject into request headers: { 'Authorization': `Bearer ${TOKEN}` }
```

**Benefits over baking token into scripts:**
- Token rotation does not require script reinstallation
- Token is not visible in script files (only in `0600` auth file)
- Consistent security model with Keychain approach for Telegram token
- `install()` writes the token file; `updateScriptsIfInstalled()` does not need to rewrite scripts for token changes

---

## 5. Test Coverage

### 5.1 Testability Improvements

To make `HookServer` methods testable:
- `parseHTTPRequest` → promote from `private` to `internal` (or extract as a static utility)
- `shouldThrottle` → promote from `private` to `internal`
- `projectName(from:)` → promote from `private` to `internal`

### 5.2 New Test Files

**`CCBotTests/MessageFormatterTests.swift`**
- `testPrepareWithDefaultLength` — truncates at 200 chars
- `testPrepareWithCustomLength` — custom max length
- `testStripMarkdownHTML` — removes HTML tags
- `testStripMarkdownLists` — removes ordered/unordered list markers
- `testStripMarkdownHorizontalRule` — removes `---` rules

**`CCBotTests/HookServerTests.swift`**
- `testParseHTTPRequest` — valid POST with body
- `testParseHTTPRequestMissingBody` — incomplete body returns nil
- `testShouldThrottle` — first call not throttled, second within interval throttled
- `testThrottleMapPruning` — map pruned when exceeding 100 entries
- `testProjectNameExtraction` — various cwd inputs

**`CCBotTests/KeychainHelperTests.swift`**
- `testSaveAndLoad`
- `testDelete`
- `testOverwrite`

**`CCBotTests/ConstantsTests.swift`**
- `testAuthTokenConsistency` — consecutive calls to `ensureAuthToken()` return same token
- `testAuthTokenFilePermissions` — token file has `0600` permissions

**`CCBotTests/NotificationPreferencesTests.swift`**
- `testDefaultValues` — returns `true` when no UserDefaults key exists
- `testExplicitlySet` — returns the stored value when key is set

**Existing tests preservation:**
- `TelegramBotTests` — all 3 existing tests remain valid. The `format*` static methods keep their signatures; only internal implementation changes to use `MessageFormatter.prepare()`.

---

## Files Changed Summary

| Action | File | Changes |
|--------|------|---------|
| **New** | `CCBot/Constants.swift` | `serverPort`, `messageTruncateLength`, `ensureAuthToken()` |
| **New** | `CCBot/Utilities/NotificationPreferences.swift` | `systemEnabled`, `telegramEnabled` |
| **New** | `CCBot/Utilities/MessageFormatter.swift` | `prepare(_:maxLength:)` |
| **New** | `CCBot/Utilities/KeychainHelper.swift` | `save/load/delete` for Keychain |
| **New** | `CCBotTests/MessageFormatterTests.swift` | 5 tests |
| **New** | `CCBotTests/HookServerTests.swift` | 5 tests |
| **New** | `CCBotTests/KeychainHelperTests.swift` | 3 tests |
| **New** | `CCBotTests/ConstantsTests.swift` | 2 tests |
| **New** | `CCBotTests/NotificationPreferencesTests.swift` | 2 tests |
| **Modified** | `CCBot/Utilities/StringUtils.swift` | Enhanced `stripMarkdown` (HTML, lists, hr) |
| **Modified** | `CCBot/Services/HookServer.swift` | Auth via `ParsedRequest`, auto-restart, throttle pruning, use `Constants`/`NotificationPreferences` |
| **Modified** | `CCBot/Services/TelegramBot.swift` | Retry logic, Keychain token + `saveToken()`, use `MessageFormatter` |
| **Modified** | `CCBot/Services/SystemNotifier.swift` | Use `MessageFormatter` |
| **Modified** | `CCBot/Services/CCGUIWatcher.swift` | `DirectoryMonitor` lock refactor (private class within this file), `CCGUIWatcher` uses `NotificationPreferences` |
| **Modified** | `CCBot/Services/UpdateChecker.swift` | Time cache (1-hour interval) |
| **Modified** | `CCBot/Services/ACPProxy.swift` | Use `Constants.serverPort`, read auth token file at runtime, `uninstall()`/`updateIfInstalled()` → `throws` |
| **Modified** | `CCBot/Utilities/HookInstaller.swift` | Use `Constants.serverPort`, scripts read auth token file at runtime, `updateScriptsIfInstalled()` → `throws` |
| **Modified** | `CCBot/Utilities/CodexNotifyInstaller.swift` | Use `Constants.serverPort`, scripts read auth token file at runtime, `updateScriptIfInstalled()` → `throws` |
| **Modified** | `CCBot/AppState.swift` | `do/catch` + `Logger` for update calls, write auth token file on start |
| **Modified** | `CCBot/Views/MenuBarView.swift` | `@State tokenInput` + `.onChange` → `telegramBot.saveToken()` |
| **Modified** | `project.yml` | Add new source and test files |

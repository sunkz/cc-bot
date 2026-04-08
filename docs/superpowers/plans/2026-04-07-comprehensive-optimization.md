# CCBot Comprehensive Optimization — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Optimize CCBot across 12 dimensions — unified constants, message pipeline, reliability, concurrency safety, error handling, security hardening, and test coverage.

**Architecture:** Extract shared concerns (constants, preferences, message formatting, Keychain) into focused utility files. Harden services with retry/restart/auth. Test all new and refactored logic via TDD.

**Tech Stack:** Swift 6, SwiftUI, macOS 13+, Network framework, Security framework (Keychain), XCTest

**Spec:** `docs/superpowers/specs/2026-04-07-comprehensive-optimization-design.md`

**Build system note:** `project.yml` uses directory-based sources (`- CCBot`, `- CCBotTests`), so new files are auto-discovered by XcodeGen. No yml changes needed for adding source files.

**Build & test commands:**
```bash
./run.sh generate   # Regenerate Xcode project after adding files
./run.sh build      # Build the project
./run.sh test       # Run all tests
```

---

## File Map

| Action | File | Responsibility |
|--------|------|----------------|
| **Create** | `CCBot/Constants.swift` | `serverPort`, `messageTruncateLength`, `ensureAuthToken()` |
| **Create** | `CCBot/Utilities/KeychainHelper.swift` | Keychain CRUD wrapper |
| **Create** | `CCBot/Utilities/NotificationPreferences.swift` | Shared `systemEnabled`/`telegramEnabled` |
| **Create** | `CCBot/Utilities/MessageFormatter.swift` | `prepare(_:maxLength:)` — canonical truncation |
| **Create** | `CCBotTests/KeychainHelperTests.swift` | 3 tests |
| **Create** | `CCBotTests/ConstantsTests.swift` | 2 tests |
| **Create** | `CCBotTests/NotificationPreferencesTests.swift` | 2 tests |
| **Create** | `CCBotTests/MessageFormatterTests.swift` | 5 tests |
| **Create** | `CCBotTests/HookServerTests.swift` | 5 tests |
| **Modify** | `CCBot/Utilities/StringUtils.swift` | Enhanced `stripMarkdown` |
| **Modify** | `CCBot/Services/HookServer.swift` | Auth, auto-restart, throttle prune, use shared utilities |
| **Modify** | `CCBot/Services/TelegramBot.swift` | Retry, Keychain token, `MessageFormatter` |
| **Modify** | `CCBot/Services/SystemNotifier.swift` | Use `MessageFormatter` |
| **Modify** | `CCBot/Services/CCGUIWatcher.swift` | Lock refactor, use `NotificationPreferences` |
| **Modify** | `CCBot/Services/UpdateChecker.swift` | Time cache |
| **Modify** | `CCBot/Services/ACPProxy.swift` | Use `Constants`, auth token file, `throws` |
| **Modify** | `CCBot/Utilities/HookInstaller.swift` | Use `Constants`, auth token file, `throws` |
| **Modify** | `CCBot/Utilities/CodexNotifyInstaller.swift` | Use `Constants`, auth token file, `throws` |
| **Modify** | `CCBot/AppState.swift` | Error-logged updates, ensure auth token |
| **Modify** | `CCBot/Views/MenuBarView.swift` | Keychain token binding |

---

## Task 1: Constants & KeychainHelper (Foundation Layer)

**Files:**
- Create: `CCBot/Constants.swift`
- Create: `CCBot/Utilities/KeychainHelper.swift`
- Create: `CCBotTests/KeychainHelperTests.swift`
- Create: `CCBotTests/ConstantsTests.swift`

- [ ] **Step 1: Create `Constants.swift`**

```swift
// CCBot/Constants.swift
import Foundation

enum Constants {
    static let serverPort: UInt16 = 62400
    static let messageTruncateLength = 200

    private static let authTokenPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/hooks/.ccbot-auth")

    /// Reads or creates the auth token file at `~/.claude/hooks/.ccbot-auth`.
    /// Creates the parent directory if needed. Thread safety: all callers are @MainActor.
    static func ensureAuthToken() -> String {
        let path = authTokenPath
        if let existing = try? String(contentsOf: path, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !existing.isEmpty {
            return existing
        }
        let dir = path.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let new = UUID().uuidString
        try? new.write(to: path, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        return new
    }
}
```

- [ ] **Step 2: Create `KeychainHelper.swift`**

```swift
// CCBot/Utilities/KeychainHelper.swift
import Foundation
import Security

enum KeychainHelper {
    private static let service = "com.ccbot.app"

    @discardableResult
    static func save(key: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        delete(key: key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8)
        else { return nil }
        return string
    }

    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
```

- [ ] **Step 3: Write `KeychainHelperTests.swift`**

```swift
// CCBotTests/KeychainHelperTests.swift
import XCTest
@testable import CCBot

final class KeychainHelperTests: XCTestCase {
    private let testKey = "ccbot-test-\(UUID().uuidString)"

    override func tearDown() {
        KeychainHelper.delete(key: testKey)
        super.tearDown()
    }

    func testSaveAndLoad() {
        XCTAssertTrue(KeychainHelper.save(key: testKey, value: "secret123"))
        XCTAssertEqual(KeychainHelper.load(key: testKey), "secret123")
    }

    func testDelete() {
        KeychainHelper.save(key: testKey, value: "toDelete")
        KeychainHelper.delete(key: testKey)
        XCTAssertNil(KeychainHelper.load(key: testKey))
    }

    func testOverwrite() {
        KeychainHelper.save(key: testKey, value: "first")
        KeychainHelper.save(key: testKey, value: "second")
        XCTAssertEqual(KeychainHelper.load(key: testKey), "second")
    }
}
```

- [ ] **Step 4: Write `ConstantsTests.swift`**

```swift
// CCBotTests/ConstantsTests.swift
import XCTest
@testable import CCBot

final class ConstantsTests: XCTestCase {
    func testAuthTokenConsistency() {
        let first = Constants.ensureAuthToken()
        let second = Constants.ensureAuthToken()
        XCTAssertEqual(first, second)
        XCTAssertFalse(first.isEmpty)
    }

    func testAuthTokenFilePermissions() {
        _ = Constants.ensureAuthToken()
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/hooks/.ccbot-auth")
        let attrs = try? FileManager.default.attributesOfItem(atPath: path.path)
        let perms = attrs?[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
    }
}
```

- [ ] **Step 5: Regenerate project and run tests**

Run: `./run.sh generate && ./run.sh test`
Expected: All tests pass (existing 11 + new 5 = 16 tests)

- [ ] **Step 6: Commit**

```bash
git add CCBot/Constants.swift CCBot/Utilities/KeychainHelper.swift \
  CCBotTests/KeychainHelperTests.swift CCBotTests/ConstantsTests.swift
git commit -m "feat: add Constants and KeychainHelper with tests"
```

---

## Task 2: NotificationPreferences & Enhanced stripMarkdown

**Files:**
- Create: `CCBot/Utilities/NotificationPreferences.swift`
- Create: `CCBotTests/NotificationPreferencesTests.swift`
- Modify: `CCBot/Utilities/StringUtils.swift`

- [ ] **Step 1: Create `NotificationPreferences.swift`**

```swift
// CCBot/Utilities/NotificationPreferences.swift
import Foundation

enum NotificationPreferences {
    static var systemEnabled: Bool {
        UserDefaults.standard.object(forKey: "systemNotifyEnabled") as? Bool ?? true
    }
    static var telegramEnabled: Bool {
        UserDefaults.standard.object(forKey: "telegramNotifyEnabled") as? Bool ?? true
    }
}
```

- [ ] **Step 2: Write `NotificationPreferencesTests.swift`**

```swift
// CCBotTests/NotificationPreferencesTests.swift
import XCTest
@testable import CCBot

final class NotificationPreferencesTests: XCTestCase {
    private let systemKey = "systemNotifyEnabled"
    private let telegramKey = "telegramNotifyEnabled"

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: systemKey)
        UserDefaults.standard.removeObject(forKey: telegramKey)
        super.tearDown()
    }

    func testDefaultValues() {
        UserDefaults.standard.removeObject(forKey: systemKey)
        UserDefaults.standard.removeObject(forKey: telegramKey)
        XCTAssertTrue(NotificationPreferences.systemEnabled)
        XCTAssertTrue(NotificationPreferences.telegramEnabled)
    }

    func testExplicitlySet() {
        UserDefaults.standard.set(false, forKey: systemKey)
        UserDefaults.standard.set(false, forKey: telegramKey)
        XCTAssertFalse(NotificationPreferences.systemEnabled)
        XCTAssertFalse(NotificationPreferences.telegramEnabled)
    }
}
```

- [ ] **Step 3: Enhance `stripMarkdown` in `StringUtils.swift`**

Replace the entire file content:

```swift
// CCBot/Utilities/StringUtils.swift
import Foundation

func stripMarkdown(_ text: String) -> String {
    text
        .replacingOccurrences(of: #"[*_`~>#]+"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: #"(?m)^\d+\.\s+"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: #"(?m)^[-+]\s+"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: #"(?m)^-{3,}$"#, with: "", options: .regularExpression)
}
```

- [ ] **Step 4: Run tests**

Run: `./run.sh generate && ./run.sh test`
Expected: All tests pass (18 tests)

- [ ] **Step 5: Commit**

```bash
git add CCBot/Utilities/NotificationPreferences.swift \
  CCBotTests/NotificationPreferencesTests.swift \
  CCBot/Utilities/StringUtils.swift
git commit -m "feat: add NotificationPreferences, enhance stripMarkdown"
```

---

## Task 3: MessageFormatter + Refactor Callers

**Files:**
- Create: `CCBot/Utilities/MessageFormatter.swift`
- Create: `CCBotTests/MessageFormatterTests.swift`
- Modify: `CCBot/Services/TelegramBot.swift`
- Modify: `CCBot/Services/SystemNotifier.swift`
- Modify: `CCBot/Services/HookServer.swift`

- [ ] **Step 1: Create `MessageFormatter.swift`**

```swift
// CCBot/Utilities/MessageFormatter.swift
import Foundation

enum MessageFormatter {
    static func prepare(_ text: String, maxLength: Int = Constants.messageTruncateLength) -> String {
        String(stripMarkdown(text).prefix(maxLength))
    }
}
```

- [ ] **Step 2: Write `MessageFormatterTests.swift`**

```swift
// CCBotTests/MessageFormatterTests.swift
import XCTest
@testable import CCBot

final class MessageFormatterTests: XCTestCase {
    func testPrepareWithDefaultLength() {
        let long = String(repeating: "a", count: 300)
        let result = MessageFormatter.prepare(long)
        XCTAssertEqual(result.count, 200)
    }

    func testPrepareWithCustomLength() {
        let result = MessageFormatter.prepare("hello world", maxLength: 5)
        XCTAssertEqual(result, "hello")
    }

    func testStripMarkdownHTML() {
        let result = MessageFormatter.prepare("<b>bold</b> and <i>italic</i>")
        XCTAssertEqual(result, "bold and italic")
    }

    func testStripMarkdownLists() {
        let input = "1. first\n2. second\n- bullet\n+ plus"
        let result = MessageFormatter.prepare(input)
        XCTAssertEqual(result, "first\nsecond\nbullet\nplus")
    }

    func testStripMarkdownHorizontalRule() {
        let input = "above\n---\nbelow"
        let result = MessageFormatter.prepare(input)
        XCTAssertEqual(result, "above\n\nbelow")
    }
}
```

- [ ] **Step 3: Run new tests to verify they pass**

Run: `./run.sh generate && ./run.sh test`
Expected: All 23 tests pass

- [ ] **Step 4: Refactor `TelegramBot.swift` format methods**

In `CCBot/Services/TelegramBot.swift`, replace the three `format*` method bodies to use `MessageFormatter.prepare()`. Keep signatures unchanged:

```swift
nonisolated static func formatNotification(project: String, message: String) -> String {
    let truncated = MessageFormatter.prepare(message)
    return "🔔 [\(project)]\n\(truncated)"
}

nonisolated static func formatCompletion(project: String, message: String) -> String {
    let truncated = MessageFormatter.prepare(message)
    return "✅ [\(project)] 任务完成\n\(truncated)"
}

nonisolated static func formatToolConfirmation(project: String, message: String) -> String {
    let truncated = MessageFormatter.prepare(message)
    return "⏳ [\(project)] 需要确认\n\(truncated)"
}
```

- [ ] **Step 5: Refactor `SystemNotifier.swift`**

In `CCBot/Services/SystemNotifier.swift`, update `notifyCompletion`:

```swift
func notifyCompletion(project: String, message: String) {
    notify(
        title: "✅ [\(project)] 任务完成",
        body: MessageFormatter.prepare(message)
    )
}
```

- [ ] **Step 6: Remove inline truncation from `HookServer.swift`**

In `CCBot/Services/HookServer.swift`, in `handleClaudeNotification`, change line 182 from:

```swift
body = String(message.prefix(200))
```

to:

```swift
body = MessageFormatter.prepare(message)
```

`SystemNotifier.notify(title:body:)` does not truncate internally (only `notifyCompletion` does), so we truncate here before passing to it. The Telegram path also truncates via `format*`, but double-truncation is harmless.

Also in `codexBody(from:)`, replace the two `String(stripMarkdown(...).prefix(200))` calls with `MessageFormatter.prepare(...)`:

```swift
private func codexBody(from json: [String: Any]) -> String {
    if let messages = json["input-messages"] as? [String] {
        let joined = messages.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !joined.isEmpty {
            return MessageFormatter.prepare(joined)
        }
    }

    let lastMessage = stringValue(in: json, key: "last-assistant-message")
    if !lastMessage.isEmpty {
        return MessageFormatter.prepare(lastMessage)
    }

    switch stringValue(in: json, key: "type") {
    case "agent-turn-complete":
        return "Codex 任务已完成"
    case "approval-requested":
        return "Codex 需要你的确认"
    case "user-input-requested":
        return "Codex 正在等待你的输入"
    default:
        return "收到 Codex 通知"
    }
}
```

- [ ] **Step 7: Run all tests**

Run: `./run.sh test`
Expected: All 23 tests pass (including existing `TelegramBotTests`)

- [ ] **Step 8: Commit**

```bash
git add CCBot/Utilities/MessageFormatter.swift CCBotTests/MessageFormatterTests.swift \
  CCBot/Services/TelegramBot.swift CCBot/Services/SystemNotifier.swift \
  CCBot/Services/HookServer.swift
git commit -m "feat: add MessageFormatter, unify truncation pipeline"
```

---

## Task 4: Use NotificationPreferences & Constants in Services

**Files:**
- Modify: `CCBot/Services/HookServer.swift`
- Modify: `CCBot/Services/CCGUIWatcher.swift`

- [ ] **Step 1: Refactor `HookServer.swift` — remove duplicate preferences, use Constants**

In `CCBot/Services/HookServer.swift`:

Remove the two private computed properties:
```swift
// DELETE these:
private var systemEnabled: Bool { ... }
private var telegramEnabled: Bool { ... }
```

Replace `let port: UInt16 = 62400` with:
```swift
let port: UInt16 = Constants.serverPort
```

Replace all occurrences of `systemEnabled` with `NotificationPreferences.systemEnabled` and `telegramEnabled` with `NotificationPreferences.telegramEnabled` throughout the file.

- [ ] **Step 2: Refactor `CCGUIWatcher.swift` — remove duplicate preferences**

In `CCBot/Services/CCGUIWatcher.swift`:

Remove the two private computed properties from `CCGUIWatcher`:
```swift
// DELETE these:
private var systemEnabled: Bool { ... }
private var telegramEnabled: Bool { ... }
```

Replace all occurrences in the `notify(_:)` method with `NotificationPreferences.systemEnabled` and `NotificationPreferences.telegramEnabled`.

- [ ] **Step 3: Run all tests**

Run: `./run.sh test`
Expected: All 23 tests pass

- [ ] **Step 4: Commit**

```bash
git add CCBot/Services/HookServer.swift CCBot/Services/CCGUIWatcher.swift
git commit -m "refactor: use NotificationPreferences and Constants in services"
```

---

## Task 5: HookServer Reliability — Throttle Pruning, Auto-Restart, ParsedRequest

**Files:**
- Modify: `CCBot/Services/HookServer.swift`
- Create: `CCBotTests/HookServerTests.swift`

- [ ] **Step 1: Add `ParsedRequest` struct and refactor `parseHTTPRequest`**

In `CCBot/Services/HookServer.swift`, add the struct at file scope (inside the class, above the methods):

```swift
struct ParsedRequest {
    let path: String
    let body: Data
    let authorizationHeader: String?
}
```

Change `parseHTTPRequest` from `private` to `internal` and update its return type:

```swift
nonisolated func parseHTTPRequest(from data: Data) -> ParsedRequest? {
    let separator = Data("\r\n\r\n".utf8)
    guard let headerRange = data.range(of: separator),
          let headerText = String(data: data[..<headerRange.lowerBound], encoding: .utf8)
    else { return nil }

    let lines = headerText.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else { return nil }
    let parts = requestLine.split(separator: " ")
    guard parts.count >= 2 else { return nil }

    let path = String(parts[1])

    var contentLength = 0
    var authHeader: String?
    for line in lines.dropFirst() {
        let pieces = line.split(separator: ":", maxSplits: 1).map(String.init)
        guard pieces.count == 2 else { continue }
        let name = pieces[0].trimmingCharacters(in: .whitespaces)
        let value = pieces[1].trimmingCharacters(in: .whitespaces)
        if name.caseInsensitiveCompare("Content-Length") == .orderedSame {
            contentLength = Int(value) ?? 0
        } else if name.caseInsensitiveCompare("Authorization") == .orderedSame {
            authHeader = value
        }
    }

    let bodyStart = headerRange.upperBound
    let remainingBodyCount = data.count - bodyStart
    guard remainingBodyCount >= contentLength else { return nil }

    let bodyEnd = bodyStart + contentLength
    return ParsedRequest(
        path: path,
        body: data.subdata(in: bodyStart..<bodyEnd),
        authorizationHeader: authHeader
    )
}
```

- [ ] **Step 2: Update `receiveHTTPRequestChunk` to use `ParsedRequest`**

```swift
nonisolated private func receiveHTTPRequestChunk(conn: NWConnection, buffer: Data) {
    conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
        guard let self else { conn.cancel(); return }
        guard error == nil else { conn.cancel(); return }

        var accumulated = buffer
        if let data, !data.isEmpty {
            accumulated.append(data)
        }

        guard !accumulated.isEmpty else {
            conn.cancel()
            return
        }

        guard let request = self.parseHTTPRequest(from: accumulated) else {
            if isComplete {
                self.sendResponse(conn: conn, status: 400, body: "{}")
            } else {
                self.receiveHTTPRequestChunk(conn: conn, buffer: accumulated)
            }
            return
        }

        let req = request
        Task { @MainActor in
            await self.dispatch(request: req, conn: conn)
        }
    }
}
```

- [ ] **Step 3: Update `dispatch` to validate auth and accept `ParsedRequest`**

```swift
private func dispatch(request: ParsedRequest, conn: NWConnection) async {
    let expectedToken = "Bearer \(Constants.ensureAuthToken())"
    guard request.authorizationHeader == expectedToken else {
        sendResponse(conn: conn, status: 401, body: "{}")
        return
    }

    guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
        sendResponse(conn: conn, status: 400, body: "{}")
        return
    }

    switch request.path {
    case "/hook/notification":
        handleClaudeNotification(json: json)
        sendResponse(conn: conn, status: 200, body: "{}")
    case "/hook/stop":
        handleStop(json: json)
        sendResponse(conn: conn, status: 200, body: "{}")
    case "/hook/codex-notify":
        handleCodexNotification(json: json)
        sendResponse(conn: conn, status: 200, body: "{}")
    default:
        sendResponse(conn: conn, status: 404, body: "{}")
    }
}
```

- [ ] **Step 4: Add throttle pruning to `shouldThrottle`**

Change `shouldThrottle` from `private` to `internal` and add pruning:

```swift
func shouldThrottle(key: String) -> Bool {
    let now = Date()
    if lastNotifyTimes.count > 100 {
        lastNotifyTimes = lastNotifyTimes.filter { now.timeIntervalSince($0.value) < throttleInterval }
    }
    if let last = lastNotifyTimes[key], now.timeIntervalSince(last) < throttleInterval {
        return true
    }
    lastNotifyTimes[key] = now
    return false
}
```

- [ ] **Step 5: Add auto-restart logic**

Add properties after `throttleInterval`:

```swift
private var restartAttempts = 0
private let maxRestartAttempts = 3
```

In `stateUpdateHandler`, update the `.ready` and `.failed` cases:

```swift
listener.stateUpdateHandler = { [weak self] state in
    Task { @MainActor in
        switch state {
        case .ready:
            self?.errorMessage = nil
            self?.restartAttempts = 0
            log.notice("HookServer ready on :\(self?.port ?? 0)")
        case .failed(let error):
            self?.errorMessage = "监听失败: \(error.localizedDescription)"
            log.error("HookServer failed: \(error)")
            self?.scheduleRestart()
        default:
            break
        }
    }
}
```

Add the `scheduleRestart` method:

```swift
private func scheduleRestart() {
    guard restartAttempts < maxRestartAttempts else {
        log.error("HookServer max restart attempts (\(maxRestartAttempts)) reached")
        return
    }
    restartAttempts += 1
    let delay = Double(restartAttempts) * 2
    log.notice("HookServer scheduling restart attempt \(restartAttempts)/\(maxRestartAttempts) in \(delay)s")
    listener?.cancel()
    listener = nil
    Task { @MainActor in
        try? await Task.sleep(for: .seconds(delay))
        self.startListener()
    }
}
```

- [ ] **Step 6: Promote `projectName` to internal**

Change from `private` to `internal`:

```swift
func projectName(from cwd: String, fallback: String = "unknown") -> String {
    let project = cwd.split(separator: "/").last.map(String.init) ?? cwd
    return project.isEmpty ? fallback : project
}
```

- [ ] **Step 7: Write `HookServerTests.swift`**

```swift
// CCBotTests/HookServerTests.swift
import XCTest
@testable import CCBot

final class HookServerTests: XCTestCase {
    func testParseHTTPRequest() {
        let server = HookServer()
        let raw = "POST /hook/notification HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: 13\r\nAuthorization: Bearer test-token\r\n\r\n{\"key\":\"val\"}"
        let data = Data(raw.utf8)
        let result = server.parseHTTPRequest(from: data)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.path, "/hook/notification")
        XCTAssertEqual(result?.authorizationHeader, "Bearer test-token")
        XCTAssertEqual(result?.body.count, 13)
    }

    func testParseHTTPRequestMissingBody() {
        let server = HookServer()
        let raw = "POST /hook/notification HTTP/1.1\r\nContent-Length: 100\r\n\r\nshort"
        let data = Data(raw.utf8)
        let result = server.parseHTTPRequest(from: data)
        XCTAssertNil(result)
    }

    @MainActor
    func testShouldThrottle() {
        let server = HookServer()
        XCTAssertFalse(server.shouldThrottle(key: "test:project"))
        XCTAssertTrue(server.shouldThrottle(key: "test:project"))
    }

    @MainActor
    func testThrottleMapPruning() {
        let server = HookServer()
        for i in 0..<105 {
            _ = server.shouldThrottle(key: "key-\(i)")
        }
        // After next call, map should be pruned (all entries are fresh so none removed,
        // but the pruning code path executes without crash)
        XCTAssertFalse(server.shouldThrottle(key: "new-key"))
    }

    @MainActor
    func testProjectNameExtraction() {
        let server = HookServer()
        XCTAssertEqual(server.projectName(from: "/Users/dev/code/my-app"), "my-app")
        XCTAssertEqual(server.projectName(from: ""), "unknown")
        XCTAssertEqual(server.projectName(from: "/single"), "single")
        XCTAssertEqual(server.projectName(from: "/a/b/c", fallback: "fallback"), "c")
    }
}
```

- [ ] **Step 8: Run all tests**

Run: `./run.sh generate && ./run.sh test`
Expected: All 28 tests pass

- [ ] **Step 9: Commit**

```bash
git add CCBot/Services/HookServer.swift CCBotTests/HookServerTests.swift
git commit -m "feat: HookServer auth, auto-restart, throttle pruning, and tests"
```

---

## Task 6: Telegram Bot — Retry Logic & Keychain Token

**Files:**
- Modify: `CCBot/Services/TelegramBot.swift`

- [ ] **Step 1: Replace `@AppStorage` token with Keychain-backed `@Published`**

In `CCBot/Services/TelegramBot.swift`, replace the token property and add `saveToken` + migration in init:

```swift
@MainActor
final class TelegramBot: ObservableObject {
    @Published var token: String = ""
    @AppStorage("telegramChatId") var chatId = ""

    private static let keychainKey = "telegramBotToken"

    init() {
        // Load from Keychain
        if let saved = KeychainHelper.load(key: Self.keychainKey) {
            token = saved
        } else if let legacy = UserDefaults.standard.string(forKey: "telegramBotToken"),
                  !legacy.isEmpty {
            // Migrate from UserDefaults
            KeychainHelper.save(key: Self.keychainKey, value: legacy)
            UserDefaults.standard.removeObject(forKey: "telegramBotToken")
            token = legacy
        }
    }

    func saveToken(_ value: String) {
        token = value
        if value.isEmpty {
            KeychainHelper.delete(key: Self.keychainKey)
        } else {
            KeychainHelper.save(key: Self.keychainKey, value: value)
        }
    }
```

- [ ] **Step 2: Add retry logic to `sendMessage`**

Replace the `sendMessage` method:

```swift
private func sendMessage(_ text: String) async {
    guard !token.isEmpty, !chatId.isEmpty else { return }
    guard let url = URL(string: "https://api.telegram.org/bot\(token)/sendMessage") else { return }
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let body: [String: Any] = ["chat_id": chatId, "text": text]
    req.httpBody = try? JSONSerialization.data(withJSONObject: body)

    for attempt in 0..<3 {
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse {
                if http.statusCode == 200 { return }
                if http.statusCode >= 400, http.statusCode < 500 {
                    log.error("sendMessage HTTP \(http.statusCode) (not retrying)")
                    return
                }
                log.warning("sendMessage HTTP \(http.statusCode), attempt \(attempt + 1)/3")
            }
        } catch is CancellationError {
            return
        } catch {
            log.warning("sendMessage attempt \(attempt + 1)/3 failed: \(error.localizedDescription)")
        }
        if attempt < 2 {
            try? await Task.sleep(for: .seconds(pow(2, Double(attempt))))
        }
    }
    log.error("sendMessage failed after 3 attempts")
}
```

- [ ] **Step 3: Run all tests**

Run: `./run.sh test`
Expected: All 28 tests pass (existing `TelegramBotTests` still pass — `format*` signatures unchanged)

- [ ] **Step 4: Commit**

```bash
git add CCBot/Services/TelegramBot.swift
git commit -m "feat: TelegramBot Keychain token storage and send retry"
```

---

## Task 7: MenuBarView — Keychain Token Binding & UpdateChecker Cache

**Files:**
- Modify: `CCBot/Views/MenuBarView.swift`
- Modify: `CCBot/Services/UpdateChecker.swift`

- [ ] **Step 1: Update `MenuBarView` token binding**

In `CCBot/Views/MenuBarView.swift`:

Remove:
```swift
@AppStorage("telegramBotToken") private var token = ""
```

Add:
```swift
@State private var tokenInput: String = ""
```

In the `SecureField`, change binding from `$token` to `$tokenInput`:
```swift
SecureField("Bot Token", text: $tokenInput)
    .textFieldStyle(.roundedBorder)
    .controlSize(.small)
    .onChange(of: tokenInput) { newValue in
        telegramBot.saveToken(newValue)
    }
```

In the `.task` modifier, add initialization of `tokenInput`:
```swift
.task {
    tokenInput = telegramBot.token
    hookInstalled = HookInstaller.isInstalled()
    codexNotifyInstalled = CodexNotifyInstaller.isInstalled()
    acpProxyInstalled = ACPProxy.isInstalled()
    await updateChecker.check()
}
```

- [ ] **Step 2: Add time cache to `UpdateChecker`**

In `CCBot/Services/UpdateChecker.swift`, add caching:

```swift
@MainActor
final class UpdateChecker: ObservableObject {
    @Published var latestVersion: String?

    let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

    private var lastCheckTime: Date?
    private let checkInterval: TimeInterval = 3600

    var hasUpdate: Bool {
        guard let latest = latestVersion else { return false }
        return latest.compare(currentVersion, options: .numeric) == .orderedDescending
    }

    func check() async {
        if let last = lastCheckTime, Date().timeIntervalSince(last) < checkInterval { return }
        lastCheckTime = Date()

        guard let url = URL(string: "https://api.github.com/repos/sunkz/cc-bot/releases/latest") else { return }
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else { return }
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            latestVersion = version
        } catch {
            log.error("check update failed: \(error.localizedDescription)")
        }
    }
}
```

- [ ] **Step 3: Run all tests**

Run: `./run.sh test`
Expected: All 28 tests pass

- [ ] **Step 4: Commit**

```bash
git add CCBot/Views/MenuBarView.swift CCBot/Services/UpdateChecker.swift
git commit -m "feat: Keychain token binding in MenuBarView, UpdateChecker time cache"
```

---

## Task 8: CCGUIWatcher — DirectoryMonitor Lock Refactor

**Files:**
- Modify: `CCBot/Services/CCGUIWatcher.swift`

- [ ] **Step 1: Refactor `DirectoryMonitor.scan()` lock granularity**

In `CCBot/Services/CCGUIWatcher.swift`, replace the `scan()` method in the private `DirectoryMonitor` class:

```swift
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
```

- [ ] **Step 2: Run all tests**

Run: `./run.sh test`
Expected: All 28 tests pass

- [ ] **Step 3: Commit**

```bash
git add CCBot/Services/CCGUIWatcher.swift
git commit -m "refactor: DirectoryMonitor lock granularity — schedule asyncAfter outside lock"
```

---

## Task 9: Installer Error Handling & Auth Token Scripts

**Files:**
- Modify: `CCBot/Utilities/HookInstaller.swift`
- Modify: `CCBot/Utilities/CodexNotifyInstaller.swift`
- Modify: `CCBot/Services/ACPProxy.swift`
- Modify: `CCBot/AppState.swift`

- [ ] **Step 1: Update `HookInstaller` — use Constants, auth token file, throws for update**

In `CCBot/Utilities/HookInstaller.swift`:

Update script templates to use Constants port and read auth token at runtime:

```swift
static var notificationScript: String {
    """
    #!/bin/bash
    TOKEN=$(cat ~/.claude/hooks/.ccbot-auth 2>/dev/null)
    INPUT=$(cat)
    echo "$INPUT" | curl -sf -X POST http://localhost:\(Constants.serverPort)/hook/notification \
      -H 'Content-Type: application/json' \
      -H "Authorization: Bearer $TOKEN" \
      -d @- --max-time 5 &
    exit 0
    """
}

static var stopScript: String {
    """
    #!/bin/bash
    TOKEN=$(cat ~/.claude/hooks/.ccbot-auth 2>/dev/null)
    INPUT=$(cat)
    if echo "$INPUT" | grep -q '"stop_hook_active"[[:space:]]*:[[:space:]]*true'; then exit 0; fi
    echo "$INPUT" | curl -sf -X POST http://localhost:\(Constants.serverPort)/hook/stop \
      -H 'Content-Type: application/json' \
      -H "Authorization: Bearer $TOKEN" \
      -d @- --max-time 5 &
    exit 0
    """
}
```

Change `updateScriptsIfInstalled` to throw:

```swift
static func updateScriptsIfInstalled() throws {
    guard isInstalled() else { return }
    let fm = FileManager.default
    let paths: [(URL, String)] = [
        (hooksDir.appendingPathComponent("cc-bot-notification.sh"), notificationScript),
        (hooksDir.appendingPathComponent("cc-bot-stop.sh"), stopScript),
    ]
    try? FileManager.default.removeItem(at: hooksDir.appendingPathComponent("cc-bot-pre-tool-use.sh"))
    for (url, content) in paths {
        try content.write(to: url, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
```

- [ ] **Step 2: Update `CodexNotifyInstaller` — use Constants, auth token file, throws for update**

In `CCBot/Utilities/CodexNotifyInstaller.swift`:

Update script template:

```swift
static var notifyScript: String {
    """
    #!/bin/bash
    TOKEN=$(cat ~/.claude/hooks/.ccbot-auth 2>/dev/null)
    INPUT="${1:-$(cat)}"
    printf '%s' "$INPUT" | curl -sf -X POST http://localhost:\(Constants.serverPort)/hook/codex-notify \
      -H 'Content-Type: application/json' \
      -H "Authorization: Bearer $TOKEN" \
      -d @- --max-time 5 &
    exit 0
    """
}
```

Change `updateScriptIfInstalled` to throw:

```swift
static func updateScriptIfInstalled() throws {
    guard isInstalled() else { return }
    let fm = FileManager.default
    try notifyScript.write(to: scriptPath, atomically: true, encoding: .utf8)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)
}
```

- [ ] **Step 3: Update `ACPProxy` — use Constants, auth token, throws**

In `CCBot/Services/ACPProxy.swift`:

Update the `proxyScript` to import `readFileSync` and read the auth token. In the existing script string, add the token reading and inject into request headers. Also replace the hardcoded port:

At the top of the Node.js script (after existing imports):
```javascript
import { readFileSync } from 'node:fs';
const CCBOT_PORT = parseInt(process.env.CCBOT_PORT || '\(Constants.serverPort)', 10);
const CCBOT_TOKEN = (() => { try { return readFileSync(
  `${process.env.HOME}/.claude/hooks/.ccbot-auth`, 'utf8').trim(); } catch { return ''; } })();
```

In the `notifyCCBot` function, add auth header:
```javascript
headers: {
  'Content-Type': 'application/json',
  'Content-Length': Buffer.byteLength(body),
  'Authorization': `Bearer ${CCBOT_TOKEN}`,
},
```

Change `uninstall` and `updateIfInstalled` to throw:

```swift
static func uninstall() throws {
    try FileManager.default.removeItem(at: scriptPath)
}

static func updateIfInstalled() throws {
    guard isInstalled() else { return }
    try proxyScript.write(to: scriptPath, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)
}
```

- [ ] **Step 4: Update `AppState` — error-logged updates, ensure auth token**

In `CCBot/AppState.swift`:

```swift
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

        do { try ACPProxy.updateIfInstalled() }
        catch { log.error("ACP proxy update failed: \(error)") }

        hookServer.start(telegram: telegramBot)

        if UserDefaults.standard.object(forKey: "ccguiWatcherEnabled") as? Bool ?? true {
            ccguiWatcher.start(telegram: telegramBot)
        }
    }
}
```

- [ ] **Step 5: Update `MenuBarView.toggleACPProxy()` for throwing `uninstall()`**

In `CCBot/Views/MenuBarView.swift`, update `toggleACPProxy()` to use `try` on `uninstall()`:

```swift
private func toggleACPProxy() {
    do {
        if acpProxyInstalled {
            try ACPProxy.uninstall()
        } else {
            try ACPProxy.install()
        }
        acpProxyInstalled = ACPProxy.isInstalled()
    } catch {
        alertMessage = error.localizedDescription
    }
}
```

- [ ] **Step 6: Run all tests**

Run: `./run.sh test`
Expected: All 28 tests pass

Note: Existing `HookInstallerTests` and `CodexNotifyInstallerTests` should still pass since the script templates now use computed properties but produce the same structural output. If any tests do string-matching on exact port numbers, they will still match because `Constants.serverPort` is still `62400`.

- [ ] **Step 7: Commit**

```bash
git add CCBot/Utilities/HookInstaller.swift CCBot/Utilities/CodexNotifyInstaller.swift \
  CCBot/Services/ACPProxy.swift CCBot/AppState.swift CCBot/Views/MenuBarView.swift
git commit -m "feat: auth token file, installer error propagation, Constants in scripts"
```

---

## Task 10: Final Build Verification

- [ ] **Step 1: Regenerate project**

Run: `./run.sh generate`

- [ ] **Step 2: Full build**

Run: `./run.sh build`
Expected: Build succeeds with no errors

- [ ] **Step 3: Run all tests**

Run: `./run.sh test`
Expected: All 28 tests pass

- [ ] **Step 4: Verify test count**

Expected test inventory:
- `HookInstallerTests` — 3 tests (existing)
- `TelegramBotTests` — 3 tests (existing, unchanged)
- `CodexNotifyInstallerTests` — 5 tests (existing)
- `KeychainHelperTests` — 3 tests (new)
- `ConstantsTests` — 2 tests (new)
- `NotificationPreferencesTests` — 2 tests (new)
- `MessageFormatterTests` — 5 tests (new)
- `HookServerTests` — 5 tests (new)
- **Total: 28 tests**

- [ ] **Step 5: Commit any remaining changes**

```bash
git add -A
git status
# If there are changes:
git commit -m "chore: final cleanup after comprehensive optimization"
```

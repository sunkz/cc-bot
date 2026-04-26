// CCBotTests/HookServerTests.swift
import XCTest
@testable import CCBot

final class HookServerTests: XCTestCase {
    private func writeCodexRollout(
        codexHome: URL,
        threadID: String,
        source: Any = "vscode",
        taskCompleteTurnID: String? = nil,
        taskCompleteMessage: String? = nil
    ) throws -> URL {
        let sessionsDir = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026", isDirectory: true)
            .appendingPathComponent("04", isDirectory: true)
            .appendingPathComponent("25", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

        let rolloutPath = sessionsDir.appendingPathComponent("rollout-2026-04-25T21-04-37-\(threadID).jsonl")
        var lines: [Data] = []

        let sessionMeta: [String: Any] = [
            "timestamp": "2026-04-25T13:04:39.853Z",
            "type": "session_meta",
            "payload": [
                "id": threadID,
                "timestamp": "2026-04-25T13:04:37.745Z",
                "cwd": "/Users/dev/code/demo",
                "originator": "paseo",
                "cli_version": "0.122.0",
                "source": source,
                "model_provider": "custom",
            ],
        ]
        lines.append(try JSONSerialization.data(withJSONObject: sessionMeta))

        if let taskCompleteTurnID, let taskCompleteMessage {
            let taskComplete: [String: Any] = [
                "timestamp": "2026-04-25T13:07:57.321Z",
                "type": "event_msg",
                "payload": [
                    "type": "task_complete",
                    "turn_id": taskCompleteTurnID,
                    "last_agent_message": taskCompleteMessage,
                    "completed_at": 1_777_122_477,
                    "duration_ms": 199_539,
                ],
            ]
            lines.append(try JSONSerialization.data(withJSONObject: taskComplete))
        }

        let data = lines.reduce(into: Data()) { partialResult, line in
            partialResult.append(line)
            partialResult.append(Data("\n".utf8))
        }
        try data.write(to: rolloutPath)
        return rolloutPath
    }

    private func writeClaudeTranscript(
        claudeHome: URL,
        sessionID: String,
        projectDirectory: String = "-Users-dev-code-demo",
        userPrompt: String
    ) throws -> URL {
        let projectsDir = claudeHome
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(projectDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: projectsDir, withIntermediateDirectories: true)

        let transcriptURL = projectsDir.appendingPathComponent("\(sessionID).jsonl")
        let userEvent: [String: Any] = [
            "type": "user",
            "sessionId": sessionID,
            "message": [
                "role": "user",
                "content": [
                    [
                        "type": "text",
                        "text": userPrompt,
                    ],
                ],
            ],
        ]
        let lastPromptEvent: [String: Any] = [
            "type": "last-prompt",
            "sessionId": sessionID,
            "lastPrompt": userPrompt.replacingOccurrences(of: "\n", with: " "),
        ]

        let lines = try [userEvent, lastPromptEvent]
            .map { try JSONSerialization.data(withJSONObject: $0) }
        let data = lines.reduce(into: Data()) { partialResult, line in
            partialResult.append(line)
            partialResult.append(Data("\n".utf8))
        }
        try data.write(to: transcriptURL)
        return transcriptURL
    }

    private func makePermissionFile(
        dir: URL,
        name: String,
        toolName: String = "Bash",
        cwd: String = "/Users/dev/code/demo",
        extraPayload: [String: Any] = [:]
    ) throws {
        var payload: [String: Any] = [
            "toolName": toolName,
            "cwd": cwd,
        ]
        extraPayload.forEach { payload[$0.key] = $0.value }
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: dir.appendingPathComponent(name))
    }

    @MainActor
    func testParseHTTPRequest() {
        let server = HookServer()
        let raw = "POST /hook/notification HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: 13\r\nAuthorization: Bearer test-token\r\n\r\n{\"key\":\"val\"}"
        let data = Data(raw.utf8)
        let result = server.parseHTTPRequest(from: data)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.method, "POST")
        XCTAssertEqual(result?.path, "/hook/notification")
        XCTAssertEqual(result?.authorizationHeader, "Bearer test-token")
        XCTAssertEqual(result?.body.count, 13)
    }

    @MainActor
    func testParseHTTPRequestMissingBody() {
        let server = HookServer()
        let raw = "POST /hook/notification HTTP/1.1\r\nContent-Length: 100\r\n\r\nshort"
        let data = Data(raw.utf8)
        let result = server.parseHTTPRequest(from: data)
        XCTAssertNil(result)
    }

    @MainActor
    func testParseHTTPRequestWithGetMethod() {
        let server = HookServer()
        let raw = "GET /health HTTP/1.1\r\nContent-Length: 0\r\n\r\n"
        let data = Data(raw.utf8)
        let result = server.parseHTTPRequest(from: data)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.method, "GET")
        XCTAssertEqual(result?.path, "/health")
    }

    @MainActor
    func testParseHTTPRequestRejectsOversizedBody() {
        let server = HookServer()
        let raw = "POST /hook/notification HTTP/1.1\r\nContent-Length: 1048577\r\n\r\n{}"
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

    @MainActor
    func testMessageDeduplicateByFingerprint() {
        let server = HookServer()
        XCTAssertFalse(server.shouldDeduplicate(source: "Codex", project: "demo", eventType: "agent-turn-complete", message: "Hello   World"))
        XCTAssertTrue(server.shouldDeduplicate(source: "Codex", project: "demo", eventType: "agent-turn-complete", message: "hello world"))
    }

    @MainActor
    func testMessageDeduplicateRespectsSourceAndEventType() {
        let server = HookServer()
        XCTAssertFalse(server.shouldDeduplicate(source: "Claude", project: "demo", eventType: "notification", message: "same"))
        XCTAssertFalse(server.shouldDeduplicate(source: "Codex", project: "demo", eventType: "notification", message: "same"))
        XCTAssertFalse(server.shouldDeduplicate(source: "Claude", project: "demo", eventType: "stop", message: "same"))
    }

    @MainActor
    func testCodexInputDeliveryScopeKeepsSameLeafDirectoriesSeparate() {
        let server = HookServer()
        let first = try! XCTUnwrap(server.makeCodexDelivery(json: [
            "type": Constants.codexEventInput,
            "cwd": "/Users/dev/code/demo",
            "input-messages": ["继续执行"],
        ]))
        let second = try! XCTUnwrap(server.makeCodexDelivery(json: [
            "type": Constants.codexEventInput,
            "cwd": "/tmp/worktrees/demo",
            "input-messages": ["继续执行"],
        ]))

        XCTAssertNotEqual(first.scopeKey, second.scopeKey)
    }

    @MainActor
    func testCodexInputDeliveryScopeIncludesConversationIdentityWhenPresent() {
        let server = HookServer()
        let first = try! XCTUnwrap(server.makeCodexDelivery(json: [
            "type": Constants.codexEventInput,
            "cwd": "/Users/dev/code/demo",
            "conversation_id": "conversation-a",
            "input-messages": ["继续执行"],
        ]))
        let second = try! XCTUnwrap(server.makeCodexDelivery(json: [
            "type": Constants.codexEventInput,
            "cwd": "/Users/dev/code/demo",
            "conversation_id": "conversation-b",
            "input-messages": ["继续执行"],
        ]))

        XCTAssertNotEqual(first.scopeKey, second.scopeKey)
    }

    @MainActor
    func testClaudeApprovalDeliveryBypassesNotificationThrottle() {
        let server = HookServer()
        let info = try! XCTUnwrap(server.makeClaudeDelivery(json: [
            "cwd": "/Users/dev/code/demo",
            "message": "普通通知",
        ]))
        let approval = try! XCTUnwrap(server.makeClaudeDelivery(json: [
            "cwd": "/Users/dev/code/demo",
            "message": "Claude needs your permission to use Bash",
        ]))

        XCTAssertFalse(server.shouldThrottle(delivery: info))
        XCTAssertFalse(server.shouldThrottle(delivery: approval))
        XCTAssertEqual(approval.kind, .approval)
    }

    @MainActor
    func testClaudeInputDeliveryUsesInputKind() {
        let server = HookServer()
        let delivery = try! XCTUnwrap(server.makeClaudeDelivery(json: [
            "cwd": "/Users/dev/code/demo",
            "message": "Claude is waiting for your input before continuing",
        ]))

        XCTAssertEqual(delivery.kind, .input)
        XCTAssertEqual(delivery.eventType, Constants.codexEventInput)
        XCTAssertEqual(delivery.project, "demo")
    }

    @MainActor
    func testCodexTurnEndedIsIgnored() {
        let server = HookServer()

        XCTAssertNil(server.makeCodexDelivery(json: [
            "type": "turn-ended",
            "cwd": "/Users/dev/code/demo",
            "last-assistant-message": "done",
        ]))
    }

    @MainActor
    func testCodexInputDeliveryUsesInputKind() {
        let server = HookServer()
        let delivery = try! XCTUnwrap(server.makeCodexDelivery(json: [
            "type": Constants.codexEventInput,
            "cwd": "/Users/dev/code/demo",
            "input-messages": ["是否继续执行？"],
        ]))

        XCTAssertEqual(delivery.kind, .input)
        XCTAssertEqual(delivery.project, "demo")
        XCTAssertEqual(delivery.message, "等待输入: 是否继续执行？")
    }

    @MainActor
    func testCodexTurnCompleteUsesRootTaskCompleteMessage() async throws {
        let server = HookServer()
        let codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: codexHome) }

        _ = try writeCodexRollout(
            codexHome: codexHome,
            threadID: "thread-root",
            taskCompleteTurnID: "turn-root",
            taskCompleteMessage: "最终答复：主任务已完成"
        )

        let delivery = await server.makeCodexCompletionDelivery(
            json: [
            "type": Constants.codexEventTurnComplete,
            "cwd": "/Users/dev/code/demo",
            "thread-id": "thread-root",
            "turn-id": "turn-root",
            "last-assistant-message": #"{"exclude":[]}"#,
            ],
            codexHome: codexHome,
            fileManager: .default,
            pollInterval: .zero,
            maxAttempts: 1
        )

        XCTAssertEqual(delivery?.kind, .completion)
        XCTAssertEqual(delivery?.project, "demo")
        XCTAssertEqual(delivery?.message, "最终答复：主任务已完成")
    }

    @MainActor
    func testCodexTurnCompleteIgnoresSubagentRollout() async throws {
        let server = HookServer()
        let codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: codexHome) }

        _ = try writeCodexRollout(
            codexHome: codexHome,
            threadID: "thread-child",
            source: [
                "subagent": [
                    "thread_spawn": [
                        "parent_thread_id": "thread-parent",
                        "depth": 1,
                    ],
                ],
            ],
            taskCompleteTurnID: "turn-child",
            taskCompleteMessage: "子线程完成"
        )

        let delivery = await server.makeCodexCompletionDelivery(
            json: [
            "type": Constants.codexEventTurnComplete,
            "cwd": "/Users/dev/code/demo",
            "thread-id": "thread-child",
            "turn-id": "turn-child",
            "last-assistant-message": #"{"exclude":[]}"#,
            ],
            codexHome: codexHome,
            fileManager: .default,
            pollInterval: .zero,
            maxAttempts: 1
        )

        XCTAssertNil(delivery)
    }

    @MainActor
    func testCodexTurnCompleteWithoutMatchingTaskCompleteIsIgnored() async throws {
        let server = HookServer()
        let codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: codexHome) }

        _ = try writeCodexRollout(
            codexHome: codexHome,
            threadID: "thread-generic"
        )

        let delivery = await server.makeCodexCompletionDelivery(
            json: [
                "type": Constants.codexEventTurnComplete,
                "cwd": "/Users/dev/code/demo",
                "thread-id": "thread-generic",
                "turn-id": "turn-generic",
                "last-assistant-message": #"{"exclude":[]}"#,
            ],
            codexHome: codexHome,
            fileManager: .default,
            pollInterval: .zero,
            maxAttempts: 1
        )

        XCTAssertNil(delivery)
    }

    @MainActor
    func testCodexTurnCompleteFallsBackToGenericMessageWhenTaskCompleteMessageIsUnreadable() async throws {
        let server = HookServer()
        let codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: codexHome) }

        _ = try writeCodexRollout(
            codexHome: codexHome,
            threadID: "thread-fallback",
            taskCompleteTurnID: "turn-fallback",
            taskCompleteMessage: #"{"exclude":[]}"#
        )

        let delivery = await server.makeCodexCompletionDelivery(
            json: [
                "type": Constants.codexEventTurnComplete,
                "cwd": "/Users/dev/code/demo",
                "thread-id": "thread-fallback",
                "turn-id": "turn-fallback",
                "last-assistant-message": #"{"exclude":[]}"#,
            ],
            codexHome: codexHome,
            fileManager: .default,
            pollInterval: .zero,
            maxAttempts: 1
        )

        XCTAssertEqual(delivery?.message, "Codex 任务已完成")
    }

    @MainActor
    func testCodexPermissionRequestDeliveryUsesDescriptionWhenPresent() {
        let server = HookServer()
        let delivery = try! XCTUnwrap(server.makeCodexPermissionRequestDelivery(json: [
            "hook_event_name": "PermissionRequest",
            "cwd": "/Users/dev/code/demo",
            "tool_name": "Bash",
            "tool_input": [
                "command": "git push --force-with-lease",
                "description": "Push current branch with force-with-lease",
            ],
        ]))

        XCTAssertEqual(delivery.kind, .approval)
        XCTAssertEqual(delivery.source, Constants.sourceCodex)
        XCTAssertEqual(delivery.project, "demo")
        XCTAssertEqual(delivery.eventType, Constants.codexEventApproval)
        XCTAssertEqual(delivery.message, "命令: Push current branch with force-with-lease")
    }

    @MainActor
    func testCodexPermissionRequestDeliveryFallsBackToCommand() {
        let server = HookServer()
        let delivery = try! XCTUnwrap(server.makeCodexPermissionRequestDelivery(json: [
            "hook_event_name": "PermissionRequest",
            "cwd": "/Users/dev/code/demo",
            "tool_name": "Bash",
            "tool_input": [
                "command": "git reset --soft origin/main",
            ],
        ]))

        XCTAssertEqual(delivery.message, "命令: git reset --soft origin/main")
    }

    @MainActor
    func testClaudeStopDeliveryDoesNotThrottleDistinctRuns() {
        let server = HookServer()
        let first = try! XCTUnwrap(server.makeStopDelivery(json: [
            "cwd": "/Users/dev/code/demo",
            "last_assistant_message": "first completion",
        ]))
        let second = try! XCTUnwrap(server.makeStopDelivery(json: [
            "cwd": "/Users/dev/code/demo",
            "last_assistant_message": "second completion",
        ]))

        XCTAssertFalse(server.shouldThrottle(delivery: first))
        XCTAssertFalse(server.shouldThrottle(delivery: second))
    }

    @MainActor
    func testClaudeStopDeliveryIgnoresMetadataTitleSession() throws {
        let server = HookServer()
        let claudeHome = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: claudeHome) }

        let sessionID = "88fe5e65-72b2-414c-a6f3-9b7a3e2e7baf"
        _ = try writeClaudeTranscript(
            claudeHome: claudeHome,
            sessionID: sessionID,
            userPrompt: """
            Generate metadata for a coding agent based on the user prompt.
            Title: short descriptive label (<= 40 chars).
            Return JSON only with a single field 'title'.

            User prompt:
            看看这个报错
            """
        )

        let delivery = server.makeStopDelivery(
            json: [
                "cwd": "/Users/dev/code/demo",
                "session_id": sessionID,
                "last_assistant_message": #"{"title":"Xcode CoreSimulator版本不匹配错误"}"#,
            ],
            claudeHome: claudeHome,
            fileManager: .default
        )

        XCTAssertNil(delivery)
    }

    @MainActor
    func testClaudeStopDeliveryKeepsRegularSessionTranscript() throws {
        let server = HookServer()
        let claudeHome = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: claudeHome) }

        let sessionID = "session-regular"
        _ = try writeClaudeTranscript(
            claudeHome: claudeHome,
            sessionID: sessionID,
            userPrompt: """
            修一下 HookServer 的 stop 通知逻辑。
            """
        )

        let delivery = try XCTUnwrap(server.makeStopDelivery(
            json: [
                "cwd": "/Users/dev/code/demo",
                "session_id": sessionID,
                "last_assistant_message": "已完成普通任务",
            ],
            claudeHome: claudeHome,
            fileManager: .default
        ))

        XCTAssertEqual(delivery.message, "已完成普通任务")
        XCTAssertEqual(delivery.eventType, "stop")
    }

    @MainActor
    func testClaudeNotificationWithBlankMessageIsIgnored() {
        let server = HookServer()

        XCTAssertNil(server.makeClaudeDelivery(json: [
            "cwd": "/Users/dev/code/demo",
            "message": "   \n  ",
        ]))
    }

    @MainActor
    func testClaudeStopDeliveryFallsBackWhenLastAssistantMessageMissing() {
        let server = HookServer()
        let delivery = try! XCTUnwrap(server.makeStopDelivery(json: [
            "cwd": "/Users/dev/code/demo",
            "last_assistant_message": NSNull(),
        ]))

        XCTAssertEqual(delivery.message, "Claude 任务已完成")
    }

    @MainActor
    func testRecentApprovalStateSuppressesImmediateCompletion() {
        let server = HookServer()
        let now = Date()
        let approval = NotificationDelivery(
            kind: .approval,
            source: Constants.sourceClaude,
            project: "demo",
            scopeKey: "/Users/dev/code/demo",
            message: "工具: Bash",
            eventType: Constants.codexEventApproval,
            throttleKey: nil
        )
        let completion = NotificationDelivery(
            kind: .completion,
            source: Constants.sourceClaude,
            project: "demo",
            scopeKey: "/Users/dev/code/demo",
            message: "Claude 任务已完成",
            eventType: "stop",
            throttleKey: nil
        )

        server.recordInteractiveStateIfNeeded(for: approval, now: now)

        XCTAssertTrue(server.shouldSuppressCompletion(for: completion, now: now.addingTimeInterval(0.5)))
        XCTAssertFalse(server.shouldSuppressCompletion(for: completion, now: now.addingTimeInterval(5)))
    }

    @MainActor
    func testRecentInputStateSuppressesImmediateCompletion() {
        let server = HookServer()
        let now = Date()
        let input = NotificationDelivery(
            kind: .input,
            source: Constants.sourceClaude,
            project: "demo",
            scopeKey: "/Users/dev/code/demo",
            message: "等待输入: 是否继续执行？",
            eventType: Constants.codexEventInput,
            throttleKey: nil
        )
        let completion = NotificationDelivery(
            kind: .completion,
            source: Constants.sourceClaude,
            project: "demo",
            scopeKey: "/Users/dev/code/demo",
            message: "Claude 任务已完成",
            eventType: "stop",
            throttleKey: nil
        )

        server.recordInteractiveStateIfNeeded(for: input, now: now)

        XCTAssertTrue(server.shouldSuppressCompletion(for: completion, now: now.addingTimeInterval(0.5)))
    }

    @MainActor
    func testCodexOverallCompletionBypassesInteractiveSuppression() {
        let server = HookServer()
        let now = Date()
        let approval = NotificationDelivery(
            kind: .approval,
            source: Constants.sourceCodex,
            project: "demo",
            scopeKey: "/Users/dev/code/demo|thread-id=thread-root",
            message: "命令: git push",
            eventType: Constants.codexEventApproval,
            throttleKey: nil
        )
        let completion = NotificationDelivery(
            kind: .completion,
            source: Constants.sourceCodex,
            project: "demo",
            scopeKey: "/Users/dev/code/demo|thread-id=thread-root",
            message: "Codex 任务已完成",
            eventType: Constants.codexEventTurnComplete,
            throttleKey: nil
        )

        server.recordInteractiveStateIfNeeded(for: approval, now: now)

        XCTAssertFalse(server.shouldSuppressCompletion(for: completion, now: now.addingTimeInterval(0.1)))
    }

    @MainActor
    func testCCGUIWatcherStartupNotifiesPendingRequest() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try makePermissionFile(dir: dir, name: "request-1.json")

        let exp = expectation(description: "pending request should be emitted on startup")
        var received: [PermissionRequestInfo] = []
        let watcher = CCGUIWatcher(
            permissionDir: dir.path,
            autoApproveGracePeriod: 0.05
        ) { request in
            received.append(request)
            exp.fulfill()
        }

        watcher.start(telegram: TelegramBot())
        wait(for: [exp], timeout: 1.0)
        watcher.stop()

        XCTAssertEqual(received.map(\.file), ["request-1.json"])
        XCTAssertEqual(received.map(\.project), ["demo"])
    }

    @MainActor
    func testCCGUIWatcherStartupSkipsRequestWithExistingResponse() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try makePermissionFile(dir: dir, name: "request-2.json")
        try makePermissionFile(dir: dir, name: "response-2.json")

        let exp = expectation(description: "matched startup response should suppress notification")
        exp.isInverted = true
        let watcher = CCGUIWatcher(
            permissionDir: dir.path,
            autoApproveGracePeriod: 0.05
        ) { _ in
            exp.fulfill()
        }

        watcher.start(telegram: TelegramBot())
        wait(for: [exp], timeout: 0.2)
        watcher.stop()
    }

    @MainActor
    func testCCGUIReadablePromptFallbacks() {
        let ask = CCGUIWatcher.notificationContent(for: PermissionRequestInfo(
            toolName: "AskUserQuestion",
            project: "demo",
            file: "ask-user-question-1.json",
            detail: nil
        ))
        let plan = CCGUIWatcher.notificationContent(for: PermissionRequestInfo(
            toolName: "ExitPlanMode",
            project: "demo",
            file: "plan-approval-1.json",
            detail: nil
        ))

        XCTAssertEqual(ask.kind, .input)
        XCTAssertEqual(ask.body, "需要回答问题")
        XCTAssertEqual(plan.kind, .approval)
        XCTAssertEqual(plan.body, "需要确认计划")
    }

    @MainActor
    func testCCGUIWatcherReadsQuestionDetailFromRequestFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try makePermissionFile(
            dir: dir,
            name: "ask-user-question-1.json",
            toolName: "AskUserQuestion",
            extraPayload: ["question": "是否继续执行发布流程？"]
        )

        let exp = expectation(description: "question request should preserve readable detail")
        var received: [PermissionRequestInfo] = []
        let watcher = CCGUIWatcher(
            permissionDir: dir.path,
            autoApproveGracePeriod: 0.05
        ) { request in
            received.append(request)
            exp.fulfill()
        }

        watcher.start(telegram: TelegramBot())
        wait(for: [exp], timeout: 1.0)
        watcher.stop()

        XCTAssertEqual(received.map(\.detail), ["是否继续执行发布流程？"])
    }
}

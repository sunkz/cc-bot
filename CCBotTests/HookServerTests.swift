// CCBotTests/HookServerTests.swift
import XCTest
@testable import CCBot

final class HookServerTests: XCTestCase {
    private func makePermissionFile(
        dir: URL,
        name: String,
        toolName: String = "Bash",
        cwd: String = "/Users/dev/code/demo"
    ) throws {
        let payload: [String: String] = [
            "toolName": toolName,
            "cwd": cwd,
        ]
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
    func testCodexCompletionDeliveryDoesNotThrottleDistinctRuns() {
        let server = HookServer()
        let first = try! XCTUnwrap(server.makeCodexDelivery(json: [
            "type": Constants.codexEventTurnComplete,
            "cwd": "/Users/dev/code/demo",
            "last-assistant-message": "first result",
        ]))
        let second = try! XCTUnwrap(server.makeCodexDelivery(json: [
            "type": Constants.codexEventTurnComplete,
            "cwd": "/Users/dev/code/demo",
            "last-assistant-message": "second result",
        ]))

        XCTAssertFalse(server.shouldThrottle(delivery: first))
        XCTAssertFalse(server.shouldThrottle(delivery: second))
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
}

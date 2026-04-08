// CCBotTests/HookServerTests.swift
import XCTest
@testable import CCBot

final class HookServerTests: XCTestCase {
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
}

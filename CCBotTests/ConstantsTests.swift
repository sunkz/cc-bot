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

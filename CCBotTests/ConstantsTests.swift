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

    func testProjectHomepageURLPointsToRepositoryRoot() {
        XCTAssertEqual(Constants.projectHomepageURL.absoluteString, "https://github.com/sunkz/cc-bot")
    }

    func testProjectHomepageIconAssetNameUsesGitHubMarkAsset() {
        XCTAssertEqual(Constants.projectHomepageIconAssetName, "GitHubMark")
    }

    func testProjectHomepageLinkTitleUsesCallToActionCopy() {
        XCTAssertEqual(Constants.projectHomepageLinkTitle, "主页")
    }
}

final class HookPathDisclosureStateTests: XCTestCase {
    func testToggleExpandsOnlyRequestedHook() {
        var state = HookPathDisclosureState()

        state.toggle(.claude)

        XCTAssertTrue(state.isExpanded(.claude))
        XCTAssertFalse(state.isExpanded(.codex))
    }

    func testResetCollapsesAllExpandedHooks() {
        var state = HookPathDisclosureState()
        state.toggle(.claude)
        state.toggle(.codex)

        state.reset()

        XCTAssertFalse(state.isExpanded(.claude))
        XCTAssertFalse(state.isExpanded(.codex))
    }
}

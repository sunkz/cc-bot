import XCTest
@testable import CCBot

final class TelegramBotTests: XCTestCase {
    private let defaultsSuiteName = "CCBotTests.TelegramBotTests"

    private var testDefaults: UserDefaults {
        guard let defaults = UserDefaults(suiteName: defaultsSuiteName) else {
            fatalError("Failed to create test UserDefaults suite")
        }
        return defaults
    }

    override func setUp() {
        super.setUp()
        testDefaults.removePersistentDomain(forName: defaultsSuiteName)
    }

    override func tearDown() {
        testDefaults.removePersistentDomain(forName: defaultsSuiteName)
        super.tearDown()
    }

    @MainActor
    private final class MockHTTPClient: TelegramHTTPClient {
        enum MockError: Error { case noResponse }

        private(set) var requestCount = 0
        private var responses: [(Data, URLResponse)] = []

        init(responses: [(Data, URLResponse)]) {
            self.responses = responses
        }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            requestCount += 1
            guard !responses.isEmpty else { throw MockError.noResponse }
            return responses.removeFirst()
        }
    }

    func testCompletionMessageFormat() {
        let msg = TelegramBot.formatCompletion(project: "myapp", source: "Codex", message: "Done building the feature.")
        XCTAssertTrue(msg.hasPrefix("✅"))
        XCTAssertTrue(msg.contains("Codex"))
        XCTAssertTrue(msg.contains("myapp"))
        XCTAssertTrue(msg.contains("已完成"))
        XCTAssertTrue(msg.contains("Done building the feature."))
        XCTAssertFalse(msg.contains("关键:"))
    }

    func testToolConfirmationFormat() {
        let msg = TelegramBot.formatToolConfirmation(
            project: "myapp",
            source: "Claude",
            message: "Claude needs your permission to use Bash"
        )
        XCTAssertTrue(msg.hasPrefix("⏳"))
        XCTAssertTrue(msg.contains("Claude"))
        XCTAssertTrue(msg.contains("myapp"))
        XCTAssertTrue(msg.contains("待确认"))
        XCTAssertTrue(msg.contains("Claude needs your permission to use Bash"))
    }

    func testNotificationMessageFormat() {
        let msg = TelegramBot.formatNotification(project: "myapp", source: "Codex", message: "Running tests")
        XCTAssertTrue(msg.hasPrefix("🔔"))
        XCTAssertTrue(msg.contains("Codex"))
        XCTAssertTrue(msg.contains("myapp"))
        XCTAssertTrue(msg.contains("通知"))
        XCTAssertTrue(msg.contains("Running tests"))
    }

    func testInputRequestMessageFormat() {
        let msg = TelegramBot.formatInputRequest(project: "myapp", source: "Codex", message: "继续执行？")
        XCTAssertTrue(msg.hasPrefix("❓"))
        XCTAssertTrue(msg.contains("Codex"))
        XCTAssertTrue(msg.contains("myapp"))
        XCTAssertTrue(msg.contains("待输入"))
        XCTAssertTrue(msg.contains("继续执行？"))
    }

    func testParseSendMessageResultSuccess() {
        let data = Data(#"{"ok":true,"result":{"message_id":1}}"#.utf8)
        let result = try! XCTUnwrap(TelegramBot.parseSendMessageResult(data: data))
        XCTAssertTrue(result.ok)
        XCTAssertNil(result.description)
    }

    func testParseSendMessageResultFailure() {
        let data = Data(#"{"ok":false,"description":"chat not found"}"#.utf8)
        let result = try! XCTUnwrap(TelegramBot.parseSendMessageResult(data: data))
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.description, "chat not found")
    }

    func testParseSendMessageResultInvalidJSON() {
        let data = Data("not-json".utf8)
        XCTAssertNil(TelegramBot.parseSendMessageResult(data: data))
    }

    @MainActor
    func testRetryOnServerErrorThenSuccess() async {
        let url = URL(string: "https://api.telegram.org/mock")!
        let resp500 = HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil, headerFields: nil)!
        let resp200 = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let mock = MockHTTPClient(responses: [
            (Data(#"{"ok":false,"description":"server error"}"#.utf8), resp500),
            (Data(#"{"ok":true}"#.utf8), resp200),
        ])
        let bot = TelegramBot(httpClient: mock, userDefaults: testDefaults)
        bot.token = "token"
        bot.chatId = "chat"

        await bot.sendNotification(project: "myapp", source: "Codex", message: "hello")
        XCTAssertEqual(mock.requestCount, 2)
    }

    @MainActor
    func testNoRetryOnClientError() async {
        let url = URL(string: "https://api.telegram.org/mock")!
        let resp400 = HTTPURLResponse(url: url, statusCode: 400, httpVersion: nil, headerFields: nil)!
        let mock = MockHTTPClient(responses: [
            (Data(#"{"ok":false,"description":"bad request"}"#.utf8), resp400),
        ])
        let bot = TelegramBot(httpClient: mock, userDefaults: testDefaults)
        bot.token = "token"
        bot.chatId = "chat"

        await bot.sendNotification(project: "myapp", source: "Codex", message: "hello")
        XCTAssertEqual(mock.requestCount, 1)
    }

    @MainActor
    func testNoRetryWhenTelegramOkFalseOn200() async {
        let url = URL(string: "https://api.telegram.org/mock")!
        let resp200 = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let mock = MockHTTPClient(responses: [
            (Data(#"{"ok":false,"description":"chat not found"}"#.utf8), resp200),
        ])
        let bot = TelegramBot(httpClient: mock, userDefaults: testDefaults)
        bot.token = "token"
        bot.chatId = "chat"

        await bot.sendNotification(project: "myapp", source: "Codex", message: "hello")
        XCTAssertEqual(mock.requestCount, 1)
    }

    @MainActor
    func testRetryOnInvalidJSONEvenWhenHTTP200() async {
        let url = URL(string: "https://api.telegram.org/mock")!
        let resp200 = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let mock = MockHTTPClient(responses: [
            (Data("not-json".utf8), resp200),
            (Data(#"{"ok":true}"#.utf8), resp200),
        ])
        let bot = TelegramBot(httpClient: mock, userDefaults: testDefaults)
        bot.token = "token"
        bot.chatId = "chat"

        await bot.sendNotification(project: "myapp", source: "Codex", message: "hello")
        XCTAssertEqual(mock.requestCount, 2)
    }
}

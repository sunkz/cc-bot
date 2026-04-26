import XCTest
@testable import CCBot

final class UpdateCheckerTests: XCTestCase {
    private let localVersionSuffixKey = "CCBOT_LOCAL_VERSION_SUFFIX"
    private let defaultsSuiteName = "CCBotTests.UpdateCheckerTests"

    @MainActor
    private final class MockHTTPClient: UpdateCheckHTTPClient {
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

    private var testDefaults: UserDefaults {
        guard let defaults = UserDefaults(suiteName: defaultsSuiteName) else {
            fatalError("Failed to create test UserDefaults suite")
        }
        return defaults
    }

    override func tearDown() {
        unsetenv(localVersionSuffixKey)
        testDefaults.removePersistentDomain(forName: defaultsSuiteName)
        super.tearDown()
    }

    @MainActor
    func testCurrentVersionAppendsLocalSuffixWhenEnvironmentPresent() {
        let baseVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        setenv(localVersionSuffixKey, "local", 1)

        let checker = UpdateChecker()

        XCTAssertEqual(checker.currentVersion, "\(baseVersion)-local")
    }

    @MainActor
    func testHasUpdateIgnoresLocalSuffixForSameRelease() {
        let baseVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let checker = UpdateChecker(
            httpClient: MockHTTPClient(responses: []),
            userDefaults: testDefaults,
            now: Date.init,
            environment: [localVersionSuffixKey: "local"]
        )
        checker.latestVersion = baseVersion

        XCTAssertFalse(checker.hasUpdate)
    }

    func testRunScriptDoesNotInjectLocalVersionSuffixWhenLaunchingApp() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let scriptURL = repoRoot.appendingPathComponent("run.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        XCTAssertFalse(
            script.contains("open --env CCBOT_LOCAL_VERSION_SUFFIX=local"),
            "run.sh 本地启动时不应再强制附加 -local 版本后缀"
        )
    }

    func testRunScriptFailsWhenXcodebuildFailsEvenIfStaleAppExists() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        try fileManager.copyItem(at: repoRoot.appendingPathComponent("run.sh"), to: root.appendingPathComponent("run.sh"))

        try fileManager.createDirectory(at: root.appendingPathComponent("CCBot.xcodeproj"), withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: root.appendingPathComponent(".build/DerivedData/Build/Products/Debug/CCBot.app", isDirectory: true),
            withIntermediateDirectories: true
        )

        let binDir = root.appendingPathComponent("bin", isDirectory: true)
        try fileManager.createDirectory(at: binDir, withIntermediateDirectories: true)
        let xcodebuildPath = binDir.appendingPathComponent("xcodebuild")
        try """
        #!/usr/bin/env bash
        echo "error: synthetic build failure"
        exit 1
        """.write(to: xcodebuildPath, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: xcodebuildPath.path)

        let outputPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.currentDirectoryURL = root
        process.arguments = ["run.sh", "build"]
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(binDir.path):\(environment["PATH"] ?? "/usr/bin:/bin")"
        process.environment = environment

        try process.run()
        process.waitUntilExit()

        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertNotEqual(process.terminationStatus, 0)
        XCTAssertTrue(output.contains("Build failed"), "run.sh 应该在 xcodebuild 失败时直接报错，而不是复用旧产物")
    }

    func testRunScriptFailsWhenPortRemainsBusy() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        try fileManager.copyItem(at: repoRoot.appendingPathComponent("run.sh"), to: root.appendingPathComponent("run.sh"))

        try fileManager.createDirectory(at: root.appendingPathComponent("CCBot.xcodeproj"), withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: root.appendingPathComponent(".build/DerivedData/Build/Products/Debug/CCBot.app", isDirectory: true),
            withIntermediateDirectories: true
        )

        let binDir = root.appendingPathComponent("bin", isDirectory: true)
        try fileManager.createDirectory(at: binDir, withIntermediateDirectories: true)
        let openMarkerPath = root.appendingPathComponent("open-called").path
        let stubScripts: [(String, String)] = [
            ("xcodebuild", """
            #!/usr/bin/env bash
            echo "Build Succeeded"
            exit 0
            """),
            ("pkill", """
            #!/usr/bin/env bash
            exit 0
            """),
            ("lsof", """
            #!/usr/bin/env bash
            exit 0
            """),
            ("sleep", """
            #!/usr/bin/env bash
            exit 0
            """),
            ("open", """
            #!/usr/bin/env bash
            touch "\(openMarkerPath)"
            exit 0
            """),
        ]

        for (name, contents) in stubScripts {
            let scriptPath = binDir.appendingPathComponent(name)
            try contents.write(to: scriptPath, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)
        }

        let outputPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.currentDirectoryURL = root
        process.arguments = ["run.sh", "run"]
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(binDir.path):\(environment["PATH"] ?? "/usr/bin:/bin")"
        process.environment = environment

        try process.run()
        process.waitUntilExit()

        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertNotEqual(process.terminationStatus, 0)
        XCTAssertTrue(output.contains("port 62400 is still in use"))
        XCTAssertFalse(fileManager.fileExists(atPath: openMarkerPath))
    }

    @MainActor
    func testCheckSkipsNetworkWhenRecentAutomaticCheckExists() async {
        let url = URL(string: "https://api.github.com/repos/sunkz/cc-bot/releases/latest")!
        let resp200 = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let mock = MockHTTPClient(responses: [
            (Data(#"{"tag_name":"v1.0.1"}"#.utf8), resp200),
        ])
        let now = Date(timeIntervalSince1970: 1_000)
        testDefaults.set(now.timeIntervalSince1970, forKey: UpdateChecker.lastCheckedAtDefaultsKey)
        let checker = UpdateChecker(
            httpClient: mock,
            userDefaults: testDefaults,
            now: { now.addingTimeInterval(60) }
        )

        await checker.check()

        XCTAssertEqual(mock.requestCount, 0)
        XCTAssertNil(checker.latestVersion)
    }

    @MainActor
    func testCheckPersistsLastCheckedAtAfterSuccessfulFetch() async {
        let url = URL(string: "https://api.github.com/repos/sunkz/cc-bot/releases/latest")!
        let resp200 = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let mock = MockHTTPClient(responses: [
            (Data(#"{"tag_name":"v1.0.1"}"#.utf8), resp200),
        ])
        let now = Date(timeIntervalSince1970: 2_000)
        let checker = UpdateChecker(
            httpClient: mock,
            userDefaults: testDefaults,
            now: { now }
        )

        await checker.check()

        XCTAssertEqual(mock.requestCount, 1)
        XCTAssertEqual(testDefaults.double(forKey: UpdateChecker.lastCheckedAtDefaultsKey), now.timeIntervalSince1970)
        XCTAssertEqual(checker.latestVersion, "1.0.1")
    }

    @MainActor
    func testFailedCheckDoesNotPersistLastCheckedAt() async {
        let checker = UpdateChecker(
            httpClient: MockHTTPClient(responses: []),
            userDefaults: testDefaults,
            now: { Date(timeIntervalSince1970: 3_000) }
        )

        await checker.check()

        XCTAssertEqual(testDefaults.double(forKey: UpdateChecker.lastCheckedAtDefaultsKey), 0)
        XCTAssertNotNil(checker.lastErrorMessage)
    }

    func testRuntimeEnvironmentDetectsXCTestConfiguration() {
        XCTAssertTrue(RuntimeEnvironment.isRunningTests(environment: [
            "XCTestConfigurationFilePath": "/tmp/test.xctestconfiguration",
        ]))
        XCTAssertFalse(RuntimeEnvironment.isRunningTests(environment: [:]))
    }
}

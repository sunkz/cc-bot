// CCBot/Services/UpdateChecker.swift
import Foundation
import SwiftUI
import os.log

private let log = Logger(subsystem: "com.ccbot.app", category: "UpdateChecker")

@MainActor
protocol UpdateCheckHTTPClient {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: UpdateCheckHTTPClient {}

@MainActor
final class UpdateChecker: ObservableObject {
    private static let localVersionSuffixEnvKey = "CCBOT_LOCAL_VERSION_SUFFIX"
    static let lastCheckedAtDefaultsKey = "updateChecker.lastCheckedAt"

    @Published var latestVersion: String?
    @Published var isChecking = false
    @Published var lastErrorMessage: String?

    let currentVersion: String

    private let httpClient: UpdateCheckHTTPClient
    private let userDefaults: UserDefaults
    private let now: () -> Date
    private let releaseURL: URL
    private let minimumCheckInterval: TimeInterval

    init(
        httpClient: UpdateCheckHTTPClient = URLSession.shared,
        userDefaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        releaseURL: URL = URL(string: "https://api.github.com/repos/sunkz/cc-bot/releases/latest")!,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main,
        minimumCheckInterval: TimeInterval = 60 * 60 * 24
    ) {
        self.httpClient = httpClient
        self.userDefaults = userDefaults
        self.now = now
        self.releaseURL = releaseURL
        self.minimumCheckInterval = minimumCheckInterval

        let baseVersion = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        if let suffix = environment[Self.localVersionSuffixEnvKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !suffix.isEmpty {
            currentVersion = "\(baseVersion)-\(suffix)"
        } else {
            currentVersion = baseVersion
        }
    }

    var hasUpdate: Bool {
        guard let latest = latestVersion else { return false }
        return normalizedVersion(latest).compare(normalizedVersion(currentVersion), options: .numeric) == .orderedDescending
    }

    func check(force: Bool = false) async {
        guard force || shouldCheckNow() else { return }
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        var req = URLRequest(url: releaseURL)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, resp) = try await httpClient.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                lastErrorMessage = "检查更新失败：invalid response"
                return
            }
            guard http.statusCode == 200 else {
                lastErrorMessage = "检查更新失败：HTTP \(http.statusCode)"
                return
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else {
                lastErrorMessage = "检查更新失败：invalid payload"
                return
            }
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            latestVersion = version
            recordCheckAttempt()
            lastErrorMessage = nil
            log.notice("event=update_check status=success version=\(version)")
        } catch {
            lastErrorMessage = "检查更新失败：\(error.localizedDescription)"
            log.error("event=update_check status=failed reason=\(error.localizedDescription)")
        }
    }

    private func shouldCheckNow() -> Bool {
        let lastCheckedAt = userDefaults.double(forKey: Self.lastCheckedAtDefaultsKey)
        guard lastCheckedAt > 0 else { return true }
        return now().timeIntervalSince1970 - lastCheckedAt >= minimumCheckInterval
    }

    private func recordCheckAttempt() {
        userDefaults.set(now().timeIntervalSince1970, forKey: Self.lastCheckedAtDefaultsKey)
    }

    private func normalizedVersion(_ version: String) -> String {
        version.split(separator: "-", maxSplits: 1).first.map(String.init) ?? version
    }
}

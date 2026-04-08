// CCBot/Services/UpdateChecker.swift
import Foundation
import SwiftUI
import os.log

private let log = Logger(subsystem: "com.ccbot.app", category: "UpdateChecker")

@MainActor
final class UpdateChecker: ObservableObject {
    @Published var latestVersion: String?
    @Published var isChecking = false
    @Published var lastErrorMessage: String?

    let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

    var hasUpdate: Bool {
        guard let latest = latestVersion else { return false }
        return latest.compare(currentVersion, options: .numeric) == .orderedDescending
    }

    func check() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        guard let url = URL(string: "https://api.github.com/repos/sunkz/cc-bot/releases/latest") else { return }
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
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
            lastErrorMessage = nil
            log.notice("event=update_check status=success version=\(version)")
        } catch {
            lastErrorMessage = "检查更新失败：\(error.localizedDescription)"
            log.error("event=update_check status=failed reason=\(error.localizedDescription)")
        }
    }
}

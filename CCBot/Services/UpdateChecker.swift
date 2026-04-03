// CCBot/Services/UpdateChecker.swift
import Foundation
import SwiftUI
import os.log

private let log = Logger(subsystem: "com.ccbot.app", category: "UpdateChecker")

@MainActor
final class UpdateChecker: ObservableObject {
    @Published var latestVersion: String?

    let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

    var hasUpdate: Bool {
        guard let latest = latestVersion else { return false }
        return latest.compare(currentVersion, options: .numeric) == .orderedDescending
    }

    func check() async {
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

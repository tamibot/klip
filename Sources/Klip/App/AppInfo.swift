import Foundation

/// App metadata for the "About" panel and links.
enum AppInfo {
    static let name = "Klip"
    static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.6"
    }
    static let repoURL = "https://github.com/tamibot/klip"
    static let issuesURL = "https://github.com/tamibot/klip/issues"
}

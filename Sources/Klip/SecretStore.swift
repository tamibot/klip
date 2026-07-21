import Foundation

/// Local store for the API key, in a file inside the app's support directory.
///
/// A file (perms 0600) is used instead of the Keychain because, with **ad-hoc** signing,
/// macOS re-prompts for Keychain permission on every rebuild (the identity changes),
/// which broke transcription. The file is plain text on your Mac (same level as the
/// history). For real encryption, sign with a Developer ID and switch back to the Keychain.
enum SecretStore {
    /// Each provider stores its key in a separate file (0600) in the app's directory.
    enum Key: String { case openai = "openai.key", gemini = "gemini.key", s3 = "s3.key" }

    private static func fileURL(_ k: Key) -> URL {
        Storage.shared.baseURL.appendingPathComponent(k.rawValue)
    }

    static func get(_ k: Key = .openai) -> String? {
        guard let s = try? String(contentsOf: fileURL(k), encoding: .utf8) else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// Saves the key and CONFIRMS it by reading it back. Returns `true` only if the file
    /// was written with exactly the expected value. Propagates the real error if the write fails
    /// (e.g. directory permissions), instead of swallowing it with `try?`.
    @discardableResult
    static func set(_ value: String, _ k: Key = .openai) throws -> Bool {
        let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        let url = fileURL(k)
        // Ensure the base directory exists (Storage creates it, but it doesn't hurt to be safe).
        try? FileManager.default.createDirectory(at: Storage.shared.baseURL,
                                                 withIntermediateDirectories: true)
        try t.write(to: url, atomically: true, encoding: .utf8)   // no try?: let the error propagate
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        // Confirmation: reread from disk and compare (detects silently failed writes).
        return get(k) == t
    }

    static func delete(_ k: Key = .openai) { try? FileManager.default.removeItem(at: fileURL(k)) }

    static func hasKey(_ k: Key = .openai) -> Bool { get(k) != nil }

    static func last4(_ k: Key = .openai) -> String? {
        guard let v = get(k), v.count >= 4 else { return nil }
        return String(v.suffix(4))
    }
}

import Foundation

/// Detecta si un texto parece una credencial (API key, token, secreto) para el mini gestor.
enum CredentialDetector {
    private static let patterns: [String] = [
        "sk-[A-Za-z0-9_-]{20,}",                              // OpenAI
        "ghp_[A-Za-z0-9]{20,}", "github_pat_[A-Za-z0-9_]{20,}", "gho_[A-Za-z0-9]{20,}", // GitHub
        "xox[baprs]-[A-Za-z0-9-]{10,}",                        // Slack
        "AKIA[0-9A-Z]{16}",                                    // AWS
        "AIza[0-9A-Za-z_-]{30,}",                              // Google API
        "ya29\\.[0-9A-Za-z_-]+",                               // Google OAuth
        "eyJ[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{6,}", // JWT
        "(?i)bearer\\s+[A-Za-z0-9._-]{20,}",                   // Bearer token
        "(?i)(api[_-]?key|secret|access[_-]?token|password)\\s*[:=]\\s*[A-Za-z0-9._\\-+/]{12,}"
    ]

    static func looksLikeCredential(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 12, t.count <= 4096, !t.contains("\n") || t.count < 200 else { return false }
        for p in patterns where t.range(of: p, options: .regularExpression) != nil { return true }
        return false
    }

    /// Versión enmascarada para mostrar sin revelar el secreto (••••1234).
    static func masked(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > 4 else { return "••••" }
        return "••••" + String(t.suffix(4))
    }
}

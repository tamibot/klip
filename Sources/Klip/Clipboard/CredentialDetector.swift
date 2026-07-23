import Foundation

/// Detects whether a text looks like a credential (API key, token, secret) for the mini manager.
enum CredentialDetector {
    private static let patterns: [String] = [
        "sk-[A-Za-z0-9_-]{20,}",                              // OpenAI
        "ghp_[A-Za-z0-9]{20,}", "github_pat_[A-Za-z0-9_]{20,}", "gho_[A-Za-z0-9]{20,}", // GitHub
        "xox[baprs]-[A-Za-z0-9-]{10,}",                        // Slack
        "AKIA[0-9A-Z]{16}",                                    // AWS
        "AIza[0-9A-Za-z_-]{30,}",                              // Google API
        "ya29\\.[0-9A-Za-z_-]+",                               // Google OAuth
        "eyJ[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{6,}", // JWT
        "(sk|rk|pk)_(live|test)_[A-Za-z0-9]{16,}", "whsec_[A-Za-z0-9]{16,}",  // Stripe
        "SG\\.[A-Za-z0-9_-]{16,}\\.[A-Za-z0-9_-]{16,}",        // SendGrid
        "SK[0-9a-fA-F]{32}", "AC[0-9a-fA-F]{32}",              // Twilio
        "(?i)npm_[A-Za-z0-9]{20,}",                            // npm token
        "glpat-[A-Za-z0-9_-]{20,}",                            // GitLab PAT
        "-----BEGIN [A-Z ]*PRIVATE KEY-----",                  // PEM private key
        "hf_[A-Za-z0-9]{20,}",                                 // Hugging Face
        "(?i)bearer\\s+[A-Za-z0-9._-]{20,}",                   // Bearer token
        "(?i)[a-z][a-z0-9+.-]*://[^\\s:/@]+:[^\\s:/@]{6,}@",    // credentials embedded in a URL: scheme://user:pass@host (postgres/mongodb/redis/https…)
        "(?i)AccountKey=[A-Za-z0-9+/]{40,}={0,2}",             // Azure storage connection string
        "(?i)(api[_-]?key|secret|access[_-]?token|password|token)\\s*[:=]\\s*\"?[A-Za-z0-9._\\-+/]{12,}"
    ]

    static func looksLikeCredential(_ text: String) -> Bool {
        matchedSecret(in: text) != nil
    }

    /// Stricter, UNAMBIGUOUS-PREFIX subset used ONLY for the silent at-rest promotion on load (Storage
    /// .decryptCredentials). The loose `sk-…` (which matches kebab/CSS like `sk-modal-overlay-backdrop`) and
    /// the prose-prone `key:value` / `bearer …` patterns are deliberately EXCLUDED here, so loading history
    /// never silently encrypts+hides an ordinary clip. Live capture still uses the broader `looksLikeCredential`
    /// (where a false positive is visible and one click to undo).
    private static let strongPatterns: [String] = [
        "sk-(proj|svcacct|admin|ant)-[A-Za-z0-9_-]{20,}",      // OpenAI/Anthropic structured keys
        "sk-[A-Za-z0-9]{40,}",                                 // legacy bare key: a long pure-alnum run (kebab can't)
        "ghp_[A-Za-z0-9]{20,}", "github_pat_[A-Za-z0-9_]{20,}", "gho_[A-Za-z0-9]{20,}",
        "xox[baprs]-[A-Za-z0-9-]{10,}",
        "AKIA[0-9A-Z]{16}",
        "AIza[0-9A-Za-z_-]{30,}", "ya29\\.[0-9A-Za-z_-]+",
        "(sk|rk|pk)_(live|test)_[A-Za-z0-9]{16,}", "whsec_[A-Za-z0-9]{16,}",
        "SG\\.[A-Za-z0-9_-]{16,}\\.[A-Za-z0-9_-]{16,}",
        "SK[0-9a-fA-F]{32}", "AC[0-9a-fA-F]{32}",
        "(?i)npm_[A-Za-z0-9]{20,}", "glpat-[A-Za-z0-9_-]{20,}", "hf_[A-Za-z0-9]{20,}",
        "-----BEGIN [A-Z ]*PRIVATE KEY-----",
        "eyJ[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{6,}",   // JWT
    ]

    /// True only on a high-confidence, structured secret — safe for silent at-rest promotion (see above).
    static func looksLikeHighConfidenceCredential(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 16, t.count <= 20_000 else { return false }
        for line in t.split(separator: "\n", omittingEmptySubsequences: true) {
            let s = line.trimmingCharacters(in: .whitespaces)
            guard s.count >= 16 else { continue }
            for p in strongPatterns where s.range(of: p, options: .regularExpression) != nil { return true }
        }
        return false
    }

    /// The substring that matched a secret pattern, or nil. Scans LINE BY LINE so a secret inside a
    /// larger multi-line blob (e.g. a pasted .env, a config block, or a chat message with a token) is
    /// still caught — the previous `(newline && >=200 chars) → not a credential` rule let those through
    /// and showed them in cleartext. Only an upper byte cap remains, purely for performance.
    static func matchedSecret(in text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 12, t.count <= 20_000 else { return nil }
        for line in t.split(separator: "\n", omittingEmptySubsequences: true) {
            let s = line.trimmingCharacters(in: .whitespaces)
            guard s.count >= 12 else { continue }
            for p in patterns {
                if let r = s.range(of: p, options: .regularExpression) { return String(s[r]) }
            }
        }
        return nil
    }

    /// A constant placeholder with NO secret-derived characters. Used for anything PERSISTED (the on-disk
    /// preview, backups) so the last-4 reveal hint from `masked` never lands in items.json / the .zip.
    static let maskedPlaceholder = "🔑 ••••••"

    /// Masked version to display without revealing the secret. For multi-line blobs we never echo the
    /// content (masking just the tail would hide a harmless trailing line, not the secret).
    static func masked(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.contains("\n") { return "🔑 ••••••" }
        guard t.count > 4 else { return "••••" }
        return "••••" + String(t.suffix(4))
    }
}

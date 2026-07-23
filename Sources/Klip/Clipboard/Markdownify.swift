import Foundation

/// Local (offline) conversion of text to Markdown.
enum Markdownify {

    private static func rx(_ s: String, _ pattern: String, _ template: String) -> String {
        s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
    }

    /// Reformats Markdown/rich text (e.g. an AI chat answer) into WhatsApp's own markup so it pastes cleanly:
    /// *bold*, _italic_, ~strike~, • bullets; headers become bold; links become "text (url)". The clip is
    /// plain text to begin with, so any dark background / rich styling is dropped automatically.
    static func toWhatsApp(_ text: String) -> String {
        var s = text.replacingOccurrences(of: "\r\n", with: "\n")
        s = s.replacingOccurrences(of: "\u{1}", with: "")            // strip any literal SOH so our bold placeholder is unambiguous
        s = rx(s, "(?m)^[ \\t]*[-*+][ \\t]+", "• ")                   // bullets FIRST → line-start * isn't seen as italic
        s = rx(s, "(?m)^#{1,6}[ \\t]+(.+)$", "\u{1}$1\u{1}")         // headers → bold (placeholder, protected from italic)
        s = rx(s, "\\*\\*\\*(.+?)\\*\\*\\*", "_\u{1}$1\u{1}_")       // ***bold-italic*** → _*x*_ (nested)
        s = rx(s, "\\*\\*(.+?)\\*\\*", "\u{1}$1\u{1}")               // **bold** → placeholder
        s = rx(s, "__(.+?)__", "\u{1}$1\u{1}")                        // __bold__ → placeholder
        s = rx(s, "(?<![\\*\\w])\\*(\\S(?:.*?\\S)?)\\*(?![\\*\\w])", "_$1_")  // *italic* → _italic_ (non-space content)
        s = s.replacingOccurrences(of: "\u{1}", with: "*")           // restore bold → *bold*
        s = rx(s, "~~(.+?)~~", "~$1~")                                // ~~strike~~ → ~strike~
        s = rx(s, "`([^`\\n]+)`", "$1")                               // inline `code` → code (no inline mono)
        if s.count < 20_000 { s = rx(s, "\\[(.+?)\\]\\((.+?)\\)", "$1 ($2)") }   // links (bounded: avoid backtracking)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Reformats Markdown/rich text into clean plain text for an email body: strips Markdown symbols, keeps
    /// readable structure (bullets, "text (url)" links), removes code fences. The email app adds its own styling.
    static func toEmail(_ text: String) -> String {
        var s = text.replacingOccurrences(of: "\r\n", with: "\n")
        s = rx(s, "(?m)^[ \\t]*[-*+][ \\t]+", "• ")                   // bullets FIRST → line-start * isn't seen as italic
        s = rx(s, "(?m)^#{1,6}[ \\t]+", "")                           // headers → plain line
        s = rx(s, "\\*\\*\\*(.+?)\\*\\*\\*", "$1")                    // ***bold-italic***
        s = rx(s, "\\*\\*(.+?)\\*\\*", "$1")                          // **bold**
        s = rx(s, "__(.+?)__", "$1")                                  // __bold__
        s = rx(s, "(?<![\\*\\w])\\*(\\S(?:.*?\\S)?)\\*(?![\\*\\w])", "$1")  // *italic* (non-space content)
        s = rx(s, "(?<![_\\w])_(\\S(?:.*?\\S)?)_(?![_\\w])", "$1")    // _italic_
        s = rx(s, "~~(.+?)~~", "$1")                                  // ~~strike~~
        s = rx(s, "(?m)^```[a-zA-Z0-9]*\\n?", "")                     // code fences ```lang
        s = rx(s, "`([^`\\n]+)`", "$1")                               // inline `code`
        if s.count < 20_000 { s = rx(s, "\\[(.+?)\\]\\((.+?)\\)", "$1 ($2)") }   // links (bounded: avoid backtracking)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func fromText(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "" }

        // URL on its own? → link.
        if t.range(of: "^https?://\\S+$", options: .regularExpression) != nil {
            return "[\(t)](\(t))"
        }
        // Looks like code? → fenced block (with a best-effort language tag).
        if looksLikeCode(t) {
            return "```\(inferCodeLanguage(t))\n\(text)\n```"
        }
        // Normal text → paragraphs separated by a blank line.
        let paras = text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return paras.joined(separator: "\n\n")
    }

    static func looksLikeCode(_ s: String) -> Bool {
        let keywords = ["func ", "var ", "let ", "import ", "class ", "struct ",
                        "def ", "function ", "const ", "#include", "public ", "private ",
                        "=>", "</", "/>", "});"]
        if keywords.contains(where: { s.contains($0) }) { return true }
        let codeChars = Set("{};=<>()[]")
        let symbolCount = s.filter { codeChars.contains($0) }.count
        return s.count > 0 && Double(symbolCount) / Double(s.count) > 0.06
    }

    /// Best-effort language tag for a fenced code block (cheap heuristics). Returns "" when unsure —
    /// a wrong/empty tag still renders fine, it just helps the AI/editor highlight when we're confident.
    static func inferCodeLanguage(_ s: String) -> String {
        // Inspect only a prefix: the language is detectable from the start, and this bounds the regex work
        // (the SELECT…FROM alternative uses [\s\S]+, which could backtrack on a huge pasted blob).
        let t = String(s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4000))
        let lower = t.lowercased()
        if (t.hasPrefix("{") || t.hasPrefix("[")), t.contains("\""), t.contains(":") { return "json" }
        if t.hasPrefix("#!"), lower.contains("sh") { return "bash" }
        // Keywords anchored to line start so a word in prose ("git is great") doesn't trigger a tag.
        if t.range(of: "(?m)^\\s*(\\$ |sudo |npm |yarn |pnpm |brew |curl |cd |git (clone|pull|push|commit|checkout|switch|status|add|rebase|merge|log|diff|branch|stash|fetch|reset|init|remote|tag) )", options: .regularExpression) != nil { return "bash" }
        if t.hasPrefix("<") { return (lower.contains("<!doctype html") || lower.contains("<html")) ? "html" : "xml" }
        // SQL only when UPPERCASE keywords pair up (SELECT…FROM), so prose "select the file from…" doesn't match.
        if t.range(of: "\\b(SELECT\\b[\\s\\S]+\\bFROM\\b|INSERT INTO\\b|UPDATE\\b[\\s\\S]+\\bSET\\b|DELETE FROM\\b|CREATE TABLE\\b)", options: .regularExpression) != nil { return "sql" }
        if t.contains("func ") || t.range(of: "@(MainActor|objc|State|Published|IBOutlet|escaping)", options: .regularExpression) != nil
            || t.range(of: "(?m)^\\s*(import \\w+$|guard .+ else \\{)", options: .regularExpression) != nil { return "swift" }
        if t.range(of: "(?m)^\\s*(def |class \\w+.*:|from \\w[\\w.]* import |import \\w)", options: .regularExpression) != nil { return "python" }
        if t.range(of: "=>", options: .regularExpression) != nil
            || t.range(of: "(?m)^\\s*(function |const |let |var |export )", options: .regularExpression) != nil
            || t.contains("require(") { return "javascript" }
        return ""
    }
}

/// Exports the entire history as a Markdown document.
enum MarkdownExporter {
    static func history(_ items: [ClipboardItem]) -> String {
        var out = "# \(L10n.t("export.doc.title"))\n\n"
        let df = DateFormatter()
        df.locale = Locale.current
        df.dateFormat = "yyyy-MM-dd HH:mm"

        for item in items {
            let time = df.string(from: item.createdAt)
            var meta = time
            if item.isRemote == true { meta += " · \(L10n.t("export.otherDevice"))" }
            else if let s = item.sourceName { meta += " · \(s)" }
            if item.isVoiceNote == true { meta += " · 🎙 \(L10n.t("export.voiceNote"))" }
            out += "## \(meta)\n\n"

            switch item.kind {
            case .text:
                if item.isCredential == true {
                    // Don't export secrets in the clear, and don't leak the real last-4 either: constant placeholder.
                    out += "🔑 _\(String(format: L10n.t("export.credentialHidden"), CredentialDetector.maskedPlaceholder))_\n\n"
                } else {
                    out += Markdownify.fromText(item.text ?? "") + "\n\n"
                }
            case .image:
                out += "![image](images/\(item.imageFileName ?? "image.png"))\n\n"
            case .video:
                out += "🎬 \(item.name ?? item.preview) — `videos/\(item.videoFileName ?? "recording.mov")`\n\n"
            }
        }
        return out
    }
}

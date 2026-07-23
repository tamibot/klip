import Foundation
import Testing
@testable import Klip

// Credential masking on the export paths (`Storage.exportableText`, `MarkdownExporter.history`) is
// pinned by `CredentialExportTests` in CredentialTests.swift — including the "not even the secret's
// last 4" half. Not duplicated here.

// MARK: - Downloads filenames

/// `uniqueDownloadsURL` is the single funnel for every save-to-Downloads (PDF, ZIP, .txt, PNG, GIF,
/// video copy, backup zip). Every caller writes with `.atomic`, and there is deliberately no save
/// dialog — so if the "-2"/"-3" ladder regresses, an earlier export in ~/Downloads is silently
/// destroyed. The sanitizer matters for the same reason: `base` is a user-set clip name.
///
/// These run against a temp directory, never ~/Downloads.
@Suite("Downloads export filenames")
struct UniqueDownloadsURLTests {

    private func inTempDir(_ body: (URL) throws -> Void) rethrows {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("KlipTransformTests-\(UUID().uuidString)",
                                                               isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        try body(dir)
    }

    /// Path-significant characters in a clip name become dashes. A colon is included because HFS/Finder
    /// still treats it as a separator, and "12:30 backup" is a plausible name.
    @Test("path separators in a clip name are flattened into the filename")
    func separatorsAreSanitized() {
        #expect(Storage.uniqueDownloadsURL(base: "a/b/c", ext: "pdf").lastPathComponent == "a-b-c.pdf")
        #expect(Storage.uniqueDownloadsURL(base: "12:30 backup", ext: "pdf").lastPathComponent == "12-30 backup.pdf")
        #expect(Storage.uniqueDownloadsURL(base: "a\\b", ext: "pdf").lastPathComponent == "a-b.pdf")
    }

    /// The security half of the same rule: a clip name is untrusted input, so it must not be able to
    /// walk the export out of the target folder.
    @Test("a clip name cannot escape the export folder")
    func traversalStaysInsideTheFolder() {
        inTempDir { dir in
            let url = Storage.uniqueDownloadsURL(base: "../../evil", ext: "pdf", in: dir)
            #expect(url.lastPathComponent == "..-..-evil.pdf")
            #expect(url.deletingLastPathComponent().standardizedFileURL.path == dir.standardizedFileURL.path)
        }
    }

    /// Unnamed captures (PNG snaps, GIFs, backup zips) rely on this fallback for their whole name.
    @Test("an unnamed export falls back to a timestamped name")
    func nilOrEmptyBaseFallsBackToTimestamp() {
        #expect(Storage.uniqueDownloadsURL(base: nil, ext: "pdf").lastPathComponent.hasPrefix("Klip "))
        #expect(Storage.uniqueDownloadsURL(base: "", ext: "pdf").lastPathComponent.hasPrefix("Klip "))
    }

    /// The data-loss guard. Two captures in the same second produce the same base name, and the caller
    /// writes with `.atomic` — without this ladder the second one overwrites the first with no prompt.
    @Test("an existing export is never overwritten")
    func collidingNamesGetASuffix() throws {
        try inTempDir { dir in
            for n in ["shot.png", "shot-2.png", "shot-3.png"] {
                try Data("x".utf8).write(to: dir.appendingPathComponent(n))
            }
            #expect(Storage.uniqueDownloadsURL(base: "shot", ext: "png", in: dir).lastPathComponent == "shot-4.png")
        }
    }
}

// MARK: - Markdownify: is this clip code?

/// `fromText` runs on every "Copy as Markdown" AND on every text item of the whole-history export, so
/// a false positive here is the most frequently visible defect in the app: an everyday note comes back
/// out of the clipboard wrapped in a ``` fence.
///
/// The keyword list used to be matched as bare substrings, which fired on "let ", "class " and
/// "function " in the middle of ordinary English sentences; the symbol-ratio branch had no length
/// floor, so a single pair of parentheses in a short clip beat the 0.06 threshold.
@Suite("Markdownify code detection")
struct LooksLikeCodeTests {

    @Test("ordinary English sentences are not code")
    func proseIsNotCode() {
        #expect(!Markdownify.looksLikeCode("Please let me know if that works for you."))
        #expect(!Markdownify.looksLikeCode("The class starts at 9am in room 4."))
        #expect(!Markdownify.looksLikeCode("The main function of this team is support."))
        #expect(!Markdownify.looksLikeCode("Done (finally)."))
        #expect(!Markdownify.looksLikeCode("The result (see below) was good."))
        #expect(!Markdownify.looksLikeCode("The quick brown fox jumps over the lazy dog again."))
    }

    /// The other half: the fix must not have turned the detector off. These are the shapes the feature
    /// exists for — a declaration at line start, and an arrow function with no keyword line of its own.
    @Test("real code is still detected")
    func codeIsStillCode() {
        #expect(Markdownify.looksLikeCode("func main() {\n  return 0\n}"))
        #expect(Markdownify.looksLikeCode("const x = () => 1;"))
        #expect(Markdownify.looksLikeCode("    let total = items.count\n    print(total)"))
    }

    @Test("a plain sentence is not fenced as code")
    func proseIsNotFenced() {
        #expect(Markdownify.fromText("Please let me know if that works for you.")
                == "Please let me know if that works for you.")
    }

    /// Detection runs on the trimmed string; the fence used to be built from the untrimmed one, which
    /// dropped the clip's surrounding blank lines inside the ``` block.
    @Test("blank lines around a code clip stay outside the fence")
    func fenceDoesNotSwallowSurroundingBlankLines() {
        #expect(Markdownify.fromText("\n\nfunc a() {}\n\n") == "```swift\nfunc a() {}\n```")
    }

    /// A lone URL is the one input that gets a link instead of a paragraph. The regex is anchored on
    /// purpose (not multiline), so a clip with two URLs is ordinary text.
    @Test("a lone URL becomes a self-link, a list of URLs does not")
    func loneURLBecomesALink() {
        #expect(Markdownify.fromText("https://example.com/x") == "[https://example.com/x](https://example.com/x)")
        #expect(Markdownify.fromText("https://example.com/x\nhttps://example.com/y")
                == "https://example.com/x\n\nhttps://example.com/y")
    }
}

// MARK: - Markdownify: language tag

/// The tag is written straight to the clipboard by "Copy as code" and into every fenced block of the
/// history export. Wrong tags are cosmetic, but this is the cheapest pure function in the area and the
/// two anti-false-positive rules below are one careless regex edit away from breaking.
@Suite("Markdownify language tag")
struct InferCodeLanguageTests {

    /// Both were wrong: the swift branch runs first and its bare `import \w+` swallowed python's
    /// commonest first line, and the shebang test matched "sh" anywhere in the first 4000 characters —
    /// so the word "shutil" in the body decided the language.
    @Test("a python snippet is tagged python, not swift or bash")
    func pythonIsNotMistaggged() {
        #expect(Markdownify.inferCodeLanguage("import os\n\nprint('hi')") == "python")
        #expect(Markdownify.inferCodeLanguage("#!/usr/bin/env python3\nimport shutil\nshutil.copy(a,b)") == "python")
        #expect(Markdownify.inferCodeLanguage("def add(a, b):\n    return a + b") == "python")
    }

    /// The fix narrowed swift's import alternative to capitalised module names — check it still fires.
    @Test("the common tags still resolve")
    func knownLanguagesAreTagged() {
        #expect(Markdownify.inferCodeLanguage("import Foundation\n\nfunc a() {}") == "swift")
        #expect(Markdownify.inferCodeLanguage("const x = 1;\nexport default x;") == "javascript")
        #expect(Markdownify.inferCodeLanguage("{\"a\": 1}") == "json")
        #expect(Markdownify.inferCodeLanguage("<html><body></body></html>") == "html")
        #expect(Markdownify.inferCodeLanguage("<note><to>a</to></note>") == "xml")
        #expect(Markdownify.inferCodeLanguage("#!/bin/bash\necho hi") == "bash")
    }

    /// The two deliberate anti-false-positive rules: SQL needs UPPERCASE SELECT…FROM, and the bash
    /// keywords are anchored to line start. Relaxing either one tags English prose as code.
    @Test("prose that reads like keywords gets no tag")
    func proseGetsNoTag() {
        #expect(Markdownify.inferCodeLanguage("select the file from the folder") == "")
        #expect(Markdownify.inferCodeLanguage("git is great for teams") == "")
    }
}

// MARK: - Markdownify: text the user sends to a human

/// `toWhatsApp` and `toEmail` produce text that leaves the app for another person, so corruption here
/// is invisible until the recipient reads it. `CleanPreviewTests` already documents this bug class for
/// the preview path ("identifiers like GN_MASIVO_X being mangled by the underscore rule") — the same
/// class was still live in the two transforms that actually send text out.
@Suite("Send-to-human transforms")
struct WhatsAppEmailTests {

    /// A Python dunder is lexically identical to Markdown `__bold__`, so the `__…__` rule was dropped
    /// from both transforms: eating characters out of an identifier in a message is worse than leaving
    /// a rare marker visible. The `_italic_` rule also had to stop accepting content that begins or
    /// ends with an underscore, or it re-mangled `__init__` into `_init_`.
    @Test("a dunder identifier survives being sent")
    func dundersAreNotMangled() {
        #expect(Markdownify.toWhatsApp("Override __init__ in your class.") == "Override __init__ in your class.")
        #expect(Markdownify.toEmail("Override __init__ in your class.") == "Override __init__ in your class.")
    }

    /// `**args`/`**kwargs` in prose: the two stray markers used to pair up into one "bold" span,
    /// deleting a character from each. Emphasis now requires non-space content at both ends.
    @Test("stray ** markers in prose do not pair into bold")
    func strayAsterisksAreNotBold() {
        #expect(Markdownify.toWhatsApp("Pass **args and **kwargs through.") == "Pass **args and **kwargs through.")
        #expect(Markdownify.toEmail("Pass **args and **kwargs through.") == "Pass **args and **kwargs through.")
    }

    /// The control the single-underscore guard was added for. Must keep working.
    @Test("snake_case identifiers survive being sent")
    func snakeCaseSurvives() {
        #expect(Markdownify.toEmail("Use GN_MASIVO_X and GN_MASIVO_Y ids.") == "Use GN_MASIVO_X and GN_MASIVO_Y ids.")
    }

    /// The reason the function exists: Markdown markup mapped onto WhatsApp's own markup.
    @Test("Markdown markup is rewritten in WhatsApp's own syntax")
    func whatsAppMarkupIsRewritten() {
        #expect(Markdownify.toWhatsApp("# Title\n\n**bold** and *it* and ~~s~~") == "*Title*\n\n*bold* and _it_ and ~s~")
        #expect(Markdownify.toWhatsApp("***both***") == "_*both*_")
        #expect(Markdownify.toWhatsApp("See [docs](https://a.b/c) now") == "See docs (https://a.b/c) now")
    }

    /// Nesting is FLATTENED on purpose — WhatsApp has no nested lists. And the bullet rule requires
    /// whitespace after the marker, which is the only thing keeping a "---" rule from being eaten.
    @Test("lists flatten to bullets and a horizontal rule is left alone")
    func bulletsFlattenAndRulesSurvive() {
        #expect(Markdownify.toWhatsApp("- one\n  - nested") == "• one\n• nested")
        #expect(Markdownify.toWhatsApp("above\n---\nbelow") == "above\n---\nbelow")
    }

    /// Deliberate asymmetry: an email body has no monospace, so fences go; WhatsApp renders ``` as
    /// monospace, so they stay — including the language tag, which shows up as literal text.
    @Test("code fences are stripped for email and kept for WhatsApp")
    func fenceHandlingDiffersByTarget() {
        #expect(Markdownify.toEmail("```swift\nlet x = 1\n```") == "let x = 1")
        #expect(Markdownify.toWhatsApp("```swift\nlet x = 1\n```") == "```swift\nlet x = 1\n```")
    }
}

import AppKit
import Testing
@testable import Klip

/// `RichText.cleanMarkdown` reads whatever the clipboard happens to hold, so its input is UNTRUSTED.
/// The rule these tests pin is a security boundary, not a formatting preference: pasteboard HTML must
/// never reach `NSAttributedString(.documentType: .html)`. That importer is WebKit-backed and resolves
/// the document's external sub-resources while parsing, so an `<img src="http://…">` in copied HTML
/// turned a plain ⌘C into an outbound request — a tracking beacon, and a blind SSRF into localhost/LAN
/// from this non-sandboxed process. See the comment in RichText.swift for the full write-up.
///
/// Reintroducing the branch makes `htmlOnlyIsNotParsed` fail, which is the entire point: the guard used
/// to be a code comment, and a comment does not survive a refactor.
///
/// These use a uniquely-named scratch pasteboard rather than `.general`, so they never read or clobber
/// the user's real clipboard. That is still within the test target's no-UI/no-disk/no-network rule — a
/// private pasteboard is an IPC scratch buffer, with no NSApplication and no window server involved.
@Suite("RichText.cleanMarkdown")
struct RichTextTests {

    /// A throwaway pasteboard, released even if an expectation fails.
    private func scratch(_ body: (NSPasteboard) -> Void) {
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        body(pb)
    }

    /// Bold RTF, built through AppKit so the test does not hand-roll RTF syntax.
    private func boldRTF(_ text: String) -> Data {
        let attr = NSAttributedString(
            string: text, attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
        return attr.rtf(from: NSRange(location: 0, length: attr.length), documentAttributes: [:])!
    }

    /// The regression test for the SSRF/beacon fix. The payload points at a port nothing is listening
    /// on: the assertion is `nil`, not "no connection", so this stays a pure-logic test. A non-nil
    /// return here means something parsed the HTML, and that is the bug.
    @Test("HTML-only clipboard is not parsed")
    func htmlOnlyIsNotParsed() {
        scratch { pb in
            let html = """
            <html><body><b>bold</b><img src="http://127.0.0.1:9/beacon"></body></html>
            """
            pb.declareTypes([.html], owner: nil)
            pb.setData(Data(html.utf8), forType: .html)

            #expect(RichText.cleanMarkdown(from: pb) == nil)
        }
    }

    /// HTML alongside RTF must resolve through RTF. Guards the ordering in `cleanMarkdown`: if the HTML
    /// branch ever came back ABOVE the RTF one, this would still return markdown and pass — so it is the
    /// test above, not this one, that catches a reintroduction. This one catches the reverse mistake of
    /// dropping RTF because "the clipboard has HTML anyway".
    @Test("RTF wins when both RTF and HTML are present")
    func rtfWinsOverHTML() {
        scratch { pb in
            pb.declareTypes([.rtf, .html], owner: nil)
            pb.setData(boldRTF("bold"), forType: .rtf)
            pb.setData(Data("<b>from-html</b>".utf8), forType: .html)

            #expect(RichText.cleanMarkdown(from: pb) == "**bold**")
        }
    }

    /// The feature the fail-closed fix had to preserve: RTF is the common case (AI answers, docs,
    /// browsers all put RTF on the pasteboard), so dropping HTML did not cost rich capture.
    @Test("RTF still produces markdown")
    func rtfProducesMarkdown() {
        scratch { pb in
            pb.declareTypes([.rtf], owner: nil)
            pb.setData(boldRTF("bold"), forType: .rtf)

            #expect(RichText.cleanMarkdown(from: pb) == "**bold**")
        }
    }

    /// Plain text is not rich text — `capture()` relies on nil here to fall back to the raw string.
    @Test("plain-text-only clipboard yields nil")
    func plainTextYieldsNil() {
        scratch { pb in
            pb.declareTypes([.string], owner: nil)
            pb.setString("just text", forType: .string)

            #expect(RichText.cleanMarkdown(from: pb) == nil)
        }
    }

    /// Oversized rich text is skipped to keep the 0.5s capture poll off the main thread for seconds.
    /// Pinned because the cap is easy to "simplify" away — it is a UI-freeze guard, not a content check.
    @Test("oversized RTF is skipped")
    func oversizedRTFIsSkipped() {
        scratch { pb in
            pb.declareTypes([.rtf], owner: nil)
            pb.setData(boldRTF(String(repeating: "a", count: 300_000)), forType: .rtf)

            #expect(RichText.cleanMarkdown(from: pb) == nil)
        }
    }
}

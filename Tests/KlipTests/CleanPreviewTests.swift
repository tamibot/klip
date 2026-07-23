import Testing
@testable import Klip

/// `ItemRow.cleanPreview` strips Markdown markers so the history list shows prose, not syntax.
/// It is display-only — the stored text and the search index keep the original.
///
/// Both bugs below were reported from real use, which is why they are pinned here:
///   · markers leaking into the list ("Se ve ahora con asteriscos y no se entiende bien")
///   · identifiers like GN_MASIVO_X being mangled by the underscore rule
@Suite("cleanPreview")
struct CleanPreviewTests {

    @Test("strips paired markers")
    func stripsPairedMarkers() {
        #expect(ItemRow.cleanPreview("**bold**") == "bold")
        #expect(ItemRow.cleanPreview("*italic*") == "italic")
        #expect(ItemRow.cleanPreview("`code`") == "code")
        #expect(ItemRow.cleanPreview("a **b** and `c` here") == "a b and c here")
    }

    /// `__bold__` and `__init__` are the same string, so this is a choice, not a fix: a dunder in a
    /// row is far more likely than `__bold__` (Markdown's common bold is `**`), and a clipboard for
    /// people writing Python should not rename their code. `__bold__` keeps its underscores.
    @Test("a Python dunder is shown intact, not read as bold")
    func dunderSurvives() {
        #expect(ItemRow.cleanPreview("def __init__(self):") == "def __init__(self):")
        #expect(ItemRow.cleanPreview("if __name__ == '__main__':") == "if __name__ == '__main__':")
        #expect(ItemRow.cleanPreview("__bold__") == "__bold__")
    }

    @Test("strips leading headings only")
    func stripsHeadings() {
        #expect(ItemRow.cleanPreview("# Title") == "Title")
        #expect(ItemRow.cleanPreview("###### Deep") == "Deep")
        #expect(ItemRow.cleanPreview("   ## Indented") == "Indented")
        // 4+ spaces is a code block in Markdown, not a heading — the marker stays.
        #expect(ItemRow.cleanPreview("    # Code") == "    # Code")
        // Only the leading marker goes; a # mid-line is just text.
        #expect(ItemRow.cleanPreview("# Bug #42") == "Bug #42")
    }

    /// The reason the underscore rule only matches PAIRS: identifiers must survive intact.
    @Test("keeps lone markers")
    func keepsLoneMarkers() {
        #expect(ItemRow.cleanPreview("GN_MASIVO_X") == "GN_MASIVO_X")
        #expect(ItemRow.cleanPreview("snake_case_name") == "snake_case_name")
        #expect(ItemRow.cleanPreview("2 * 3 = 6") == "2 * 3 = 6")
        #expect(ItemRow.cleanPreview("unclosed **bold") == "unclosed **bold")
    }

    /// Bold is `**`, so the single-asterisk rule has to ignore it rather than eat one star per side.
    @Test("bold is not treated as italic")
    func boldIsNotItalic() {
        #expect(ItemRow.cleanPreview("**bold** and *italic*") == "bold and italic")
        #expect(ItemRow.cleanPreview("***both***") == "both")
        // The case that actually earns the lookarounds in the italic rule. Paired bold is already
        // gone by the time it runs, so only LEFTOVER bold markers reach it — and a plain
        // `\*(.+?)\*` would chew this into "*a b". Drop the lookarounds and this is the only
        // assertion here that notices.
        #expect(ItemRow.cleanPreview("**a* b") == "**a* b")
    }

    @Test("leaves plain text alone")
    func leavesPlainTextAlone() {
        #expect(ItemRow.cleanPreview("just plain text") == "just plain text")
        #expect(ItemRow.cleanPreview("") == "")
    }
}

import Testing
@testable import Klip

/// `Sources/Klip/App/L10n.swift` is the app's ENTIRE localization surface — there is no .lproj
/// bundle, no Localizable.strings and no NSLocalizedString anywhere in Sources/. Eight dictionary
/// literals, hand-edited, 348 keys each. Nothing in the toolchain checks them: a duplicate key is a
/// runtime trap, a missing key is silent, and a mistyped format specifier is a memory-safety bug in
/// one language only. These tests are the only thing standing between a translation edit and the user.
///
/// Why the whole suite matters more than it looks: `L10n.lang` is "en" in this process, so every
/// assertion an English-speaking maintainer makes through `t()` passes even when seven languages are
/// broken. The tests below read the tables directly instead.
///
/// CEILINGS, stated so nobody mistakes this for full coverage:
///   • Translation QUALITY is not machine-checkable. A key translated by a bad machine translator, or
///     left in English on purpose, passes everything here.
///   • Text FIT is not checkable from a no-UI target. German runs ~30% longer than English and can
///     overflow a button; that is a property of a rendered NSView.
///   • ARGUMENT ORDER inside a format string is not checkable — see `formatSpecifiersMatchEnglish`.
@Suite("L10n table integrity")
struct L10nIntegrityTests {

    // MARK: - The tables load at all

    /// A Swift dictionary literal with a repeated key traps at RUNTIME on first access
    /// ("Fatal error: Dictionary literal contains duplicate keys"), never at compile time.
    /// `L10n.tables` is a lazy global holding all eight literals, so the FIRST `t()` call anywhere
    /// collapses all eight — in the app that is during menu-bar construction, i.e. before any window
    /// exists. The user sees no icon, no error, no crash dialog: it reads as "the app didn't launch".
    /// This already happened once here (a duplicated "rec.stop", caught by hand).
    ///
    /// LIMITATION, read before deleting this test: the `#expect` is not what does the work. Swift
    /// exposes no way to inspect a literal for duplicates before it collapses, so a duplicate makes
    /// this TEST PROCESS die with a trap rather than report a clean failure. "The test binary dies
    /// loudly instead of the user's app dying silently" is the strongest signal available.
    @Test("loading any string forces all eight tables to collapse without a duplicate key")
    func allTablesInitialise() {
        #expect(L10n.t("menu.quit") == "Quit Klip")
        #expect(L10n.tables.count == 8)
    }

    /// The fallback chain is `(tables[lang] ?? en)[key] ?? en[key] ?? key`. The tail matters: an
    /// unknown key must surface as the key itself, which is ugly but debuggable, rather than as an
    /// empty string, which renders as an invisible button nobody can report.
    @Test("an unknown key degrades to the key itself, not to an empty label")
    func unknownKeyReturnsTheKey() {
        #expect(L10n.t("no.such.key") == "no.such.key")
    }

    // MARK: - The eight tables agree with each other

    /// The failure this pins actually happened: 47 keys were deleted from one language while another
    /// edit was in flight, and nothing noticed. `t` falls back to English on a missing key, so the
    /// broken language returns a byte-identical string to a correct one — no test that calls `t()`
    /// can tell them apart (three ja values legitimately equal their English counterparts). Only
    /// comparing the raw key sets catches it, in both directions: missing AND accidentally-extra.
    @Test("every language defines exactly the same keys as English")
    func everyLanguageHasTheSameKeysAsEnglish() {
        let english = L10n.tables["en"]
        #expect(english != nil, "the fallback chain ends in en[key]; without an en table every language shows raw keys")
        guard let english else { return }
        // Asserted as two empty-difference checks rather than one set equality: `#expect` prints its
        // operands, and comparing the sets directly dumps 696 keys into the log for a one-key drift.
        for (code, table) in L10n.tables {
            let missing = Set(english.keys).subtracting(table.keys).sorted()
            let extra = Set(table.keys).subtracting(english.keys).sorted()
            #expect(missing.isEmpty, "\(code) is missing \(missing)")
            #expect(extra.isEmpty, "\(code) has keys English does not: \(extra)")
        }
    }

    /// An empty value is the one typo the set comparison above cannot see: the key is present, so the
    /// table looks complete, and the UI draws a blank menu item or a button with no label.
    @Test("no translation is an empty string")
    func noTranslationIsEmpty() {
        for (code, table) in L10n.tables {
            let blanks = table.filter { $0.value.isEmpty }.keys.sorted()
            #expect(blanks.isEmpty, "\(code) has empty values for \(blanks)")
        }
    }

    /// `L10n.supported` (what Preferences lists) and the keys of `L10n.tables` (what actually
    /// translates) are two hand-maintained lists that must agree. Adding ("ko", "한국어") to
    /// `supported` without a `ko` table compiles and ships: Preferences offers Korean, selecting it
    /// changes nothing, and the setting reads as dead.
    @Test("Preferences offers exactly the languages that have a translation table")
    func supportedLanguagesAllHaveTables() {
        #expect(Set(L10n.supported.map(\.code)) == Set(L10n.tables.keys))
    }

    // MARK: - printf format specifiers

    /// The only memory-unsafe failure in this file. 16 keys reach `String(format:)` at 18 call sites.
    /// A translator writing "%@ von %d" where English has "%d von %d" makes String(format:)
    /// dereference an Int as an object pointer: a crash or garbage text, in one language only, so it
    /// never reproduces for the maintainer.
    ///
    /// Swept over ALL keys rather than a hardcoded list of the 16, because "which keys reach
    /// String(format:)" lives at the call sites, not in the table — a 17th call site added later gets
    /// coverage for free this way. Only 17 of the 348 keys contain a "%" at all, so the sweep is cheap.
    ///
    /// CEILING: comparing the conversion SEQUENCE catches %@-vs-%d drift but cannot catch a translator
    /// reversing the two numbers in "%d of %d items" — both orders are [d, d]. Catching that would
    /// need positional specifiers (%1$d/%2$d) in all 16 source strings. Not covered here; do not
    /// assume it is.
    @Test("every format specifier sequence matches English in all eight languages")
    func formatSpecifiersMatchEnglish() {
        // The German value is "Zoom — Klick setzt auf 100 % zurück". CFString parses "% zu" as a real
        // conversion (space flag + z length modifier + %u), so it does not match English's bare
        // trailing "%". Harmless ONLY because SnapEditorController uses this key as a plain tooltip
        // and never formats it. Whoever wraps it in String(format:) crashes German users and nobody
        // else — delete this exemption at the same time, do not silence it again.
        let notAFormatString: Set<String> = ["editor.zoom.reset"]

        guard let english = L10n.tables["en"] else { return }
        for (code, table) in L10n.tables where code != "en" {
            for (key, value) in table where !notAFormatString.contains(key) {
                guard let base = english[key] else { continue }  // key drift is the test above's job
                #expect(Self.conversions(in: value) == Self.conversions(in: base),
                        "\(code) \(key): \(Self.conversions(in: value)) vs en \(Self.conversions(in: base))")
            }
        }
    }

    /// Conversion characters of every printf specifier in `s`, in order. Deliberately mirrors what
    /// CFString will accept — flags, width/precision, length modifiers — because the point is to see
    /// the same accidental conversions it would (see the German "% zu" above), not to be strict.
    private static func conversions(in s: String) -> [Character] {
        let flags: Set<Character> = ["-", "+", " ", "#", "0"]
        let lengths: Set<Character> = ["h", "l", "L", "z", "t", "j", "q"]
        let convs: Set<Character> = ["d", "i", "o", "u", "x", "X", "e", "E", "f", "F",
                                     "g", "G", "a", "A", "c", "s", "p", "n", "@"]
        var out: [Character] = []
        var i = s.startIndex
        while let percent = s[i...].firstIndex(of: "%") {
            i = s.index(after: percent)          // always past the %, so the loop always progresses
            guard i < s.endIndex else { break }
            if s[i] == "%" { i = s.index(after: i); continue }   // "%%" is a literal percent sign
            while i < s.endIndex, flags.contains(s[i]) { i = s.index(after: i) }
            // "$" so a future positional specifier (%1$d) reads as one conversion, not as a bare width.
            while i < s.endIndex, s[i].isNumber || s[i] == "." || s[i] == "*" || s[i] == "$" {
                i = s.index(after: i)
            }
            while i < s.endIndex, lengths.contains(s[i]) { i = s.index(after: i) }
            guard i < s.endIndex else { break }
            if convs.contains(s[i]) { out.append(s[i]); i = s.index(after: i) }
        }
        return out
    }

    // MARK: - Keys no grep can find

    /// These three families are the blind spot. Their keys are built by interpolating an enum, so
    /// they appear NOWHERE in Sources/ as a literal — a grep for unused keys reports every one of
    /// them as dead, and a cleanup pass would happily delete them. There is no compile-time signal
    /// either: `t()` returns the raw key, and the toolbar tooltip literally reads "tool.hint.blur".
    /// Asserting against the `en` table rather than against `t()` means these fail in CI even though
    /// CI runs in English.

    /// 11 tools × 2 key families = 22 keys, none of them greppable. `.rectangle` maps to "rect", so
    /// a renamed case breaks the pair silently too.
    ///
    /// Checked through the rendered string rather than the table, because SnapTool's key stem is
    /// private and AnnotationModel.swift is out of this change's scope: a missing key makes `t()`
    /// hand back the raw key, and no real translation begins with "tool.".
    @Test("every snapshot tool has a tooltip and a hint in the tables")
    func everySnapToolHasItsKeys() {
        for tool in SnapTool.allCases {
            #expect(!tool.tooltip.hasPrefix("tool."), "missing tooltip key for \(tool.rawValue)")
            #expect(!tool.hint.hasPrefix("tool.hint."), "missing hint key for \(tool.rawValue)")
        }
    }

    /// The history filter chips. A missing key here shows the user a row of "filter.all",
    /// "filter.cred" — in every language, English included.
    @Test("every history filter chip has a label in the tables")
    func everyHistoryFilterHasItsKey() {
        guard let english = L10n.tables["en"] else { return }
        for filter in HistoryFilter.allCases {
            #expect(english[filter.labelKey] != nil, "missing \(filter.labelKey)")
        }
    }

    /// ExtractionError carries an associated value, so it is not CaseIterable — the five cases are
    /// built by hand. They collapse onto three keys; the point is that all five reach a real string.
    @Test("every audio extraction failure maps to a translated upload row")
    func everyExtractionErrorHasItsKey() {
        guard let english = L10n.tables["en"] else { return }
        let all: [MediaAudioExtractor.ExtractionError] =
            [.drmProtected, .noAudioTrack, .unreadable, .readFailed(nil), .writeFailed]
        for error in all {
            #expect(english[error.uploadErrorKey] != nil, "missing \(error.uploadErrorKey)")
        }
    }
}

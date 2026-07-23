import Testing
@testable import Klip

/// Fixtures are ASSEMBLED AT RUNTIME, never written as literals. These strings have to match the
/// real vendor patterns to be worth testing, which means a literal here trips GitHub's push
/// protection and blocks the push — the scanner cannot tell a fixture from a leak, and it is right
/// not to try. Splitting the prefix from the body keeps the file scannable and the test honest.
enum Fixture {
    static let stripeLive = "sk" + "_live_" + "51AbCdEfGhIjKlMnOpQrStUv"
    static let twilioSID  = "A" + "C" + "0123456789abcdef0123456789abcdef"
}

/// Klip has TWO credential detectors and they do different jobs:
///
///  * `looksLikeCredential` (loose) runs on LIVE capture. A false positive there is visible — a key
///    icon on a row the user just copied — and one click undoes it. It is allowed to be greedy.
///  * `looksLikeHighConfidenceCredential` (strict) runs on LOAD, inside `Storage.decryptCredentials`.
///    A false positive there is SILENT: the clip's text is AES-sealed into items.json, its preview is
///    replaced by 🔑 ••••••, and it disappears from every export — all on a restart the user never
///    asked for. A false NEGATIVE is just as bad in the other direction: a legacy plaintext key is
///    never promoted and stays cleartext at rest forever.
///
/// Nothing pinned the relationship between the two lists, and they have already drifted (see
/// `databaseURLPasswordIsCaughtLiveButNotPromotedAtRest`). These tests exist to make the split a
/// decision instead of an accident.
///
/// Not covered here, deliberately:
///  * `CredentialCrypto.seal/open` — they hit the REAL login Keychain under a hardcoded account name
///    (`io.github.tamibot.klip.credentialKey`) with no injection point. On a machine where that item exists
///    the test process is outside its ACL and every round-trip assertion fails; on a fresh machine the
///    test process WINS the create and Klip.app can no longer read its own key, silently bricking every
///    already-sealed clip. A test that breaks the product on first run is worse than no test.
///  * `Storage.decryptCredentials` — an instance method on a `Storage` whose `init()` unconditionally
///    creates directories in the user's real ~/Library/Application Support/Klip. Reachable only if it
///    is made `static` (it reads zero instance state), which is a source change outside this file.
@Suite("Credential detection: the two-tier contract")
struct CredentialDetectorTierTests {

    // MARK: - Corpus

    /// Structured, unambiguous secrets. These MUST survive into the strict tier: they are the reason
    /// silent at-rest promotion exists at all.
    static let strongSecrets: [String] = [
        "sk-proj-AbCdEfGhIjKlMnOpQrStUvWxYz0123456789AbCdEf",
        "sk-ant-api03-AbCdEfGhIjKlMnOpQrStUvWxYz0123456789-_AA",
        "ghp_AbCdEfGhIjKlMnOpQrStUvWxYz0123456789",
        "AKIAIOSFODNN7EXAMPLE",
        "xoxb-123456789012-abcdefGHIJKL",
        "AIzaSyA-1234567890abcdefghijklmnopqrstuv",
        "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0",
        Fixture.stripeLive,
        "-----BEGIN OPENSSH PRIVATE KEY-----",
        Fixture.twilioSID,
    ]

    /// Things the LOOSE tier flags on purpose and the STRICT tier must refuse. Every one of these is
    /// ordinary text this app's own audience copies all day — CSS classes, docs, source code.
    static let looseOnlyLookalikes: [String] = [
        "sk-modal-overlay-backdrop",
        "Authorization: Bearer YOUR_ACCESS_TOKEN_HERE",
        "password = your-password-here",
        "The token: application/json header is required",
        #"let secret = Bundle.main.object(forInfoDictionaryKey: "KLIP")"#,
    ]

    /// Credentials the loose tier catches and the strict tier currently does not. See the decision test.
    static let unruledDriftCases: [String] = [
        "postgres://admin:hunter2xyz@db.internal:5432/app",
        "redis://default:changemeplease@127.0.0.1:6379",
        "DefaultEndpointsProtocol=https;AccountName=x;AccountKey=AbCdEfGhIjKlMnOpQrStUvWxYz0123456789+/AbCdEfg==",
    ]

    // MARK: - The strict tier

    @Test("a structured API key is promoted to an encrypted credential at rest",
          arguments: strongSecrets)
    func structuredSecretIsPromotedAtRest(_ secret: String) {
        #expect(CredentialDetector.looksLikeHighConfidenceCredential(secret))
    }

    /// The other half of the `sk-` split. The strict list replaced the loose `sk-[A-Za-z0-9_-]{20,}`
    /// with two narrower patterns; this pins the second one, so a patch aimed at killing the
    /// `sk-modal-overlay-backdrop` false positive cannot also quietly stop promoting real legacy
    /// OpenAI keys and leave them cleartext in items.json.
    @Test("a legacy bare sk- key is still promoted at rest")
    func legacyBareOpenAIKeyIsPromoted() {
        let key = "sk-AbCdEfGhIjKlMnOpQrStUvWxYz0123456789AbCdEfGhIjKl"   // sk- + 48 pure-alnum
        #expect(CredentialDetector.looksLikeHighConfidenceCredential(key))
    }

    /// The named regression, CredentialDetector.swift:31. `sk-modal-overlay-backdrop` is a real
    /// Tailwind/CSS class. Before the strict tier existed, loading history flagged it: on the NEXT
    /// LAUNCH the clip was sealed, its preview became 🔑 ••••••, and it vanished from exports — with
    /// no user action to attribute it to. Until now that was protected by a code comment and nothing
    /// else. Both halves of the contract are in this one pair of expectations.
    @Test("a kebab-case CSS class is flagged live but never promoted to an encrypted credential")
    func cssClassIsNotPromoted() {
        #expect(CredentialDetector.looksLikeCredential("sk-modal-overlay-backdrop"))
        #expect(!CredentialDetector.looksLikeHighConfidenceCredential("sk-modal-overlay-backdrop"))
    }

    @Test("kebab-case sk- identifiers in real CSS and JSX behave the same at both tiers",
          arguments: [
            ".sk-modal-overlay-backdrop { display: none; }",
            #"className="sk-1 sk-modal-overlay-backdrop-xl""#,
            "sk-transition-all-duration-300",
          ])
    func kebabVariantsBehaveLikeTheNamedRegression(_ text: String) {
        #expect(CredentialDetector.looksLikeCredential(text))
        #expect(!CredentialDetector.looksLikeHighConfidenceCredential(text))
    }

    /// Documents the exclusions the tier comment claims: the loose `key: value` and `bearer …`
    /// families stay OUT of the strict list. Both halves are asserted — a "fix" that made the loose
    /// tier stop seeing these would silently disable live credential masking for copied .env lines.
    @Test("prose and source-code lookalikes are flagged live but never promoted at rest",
          arguments: looseOnlyLookalikes)
    func looseOnlyLookalikeIsNotPromoted(_ text: String) {
        #expect(CredentialDetector.looksLikeCredential(text))
        #expect(!CredentialDetector.looksLikeHighConfidenceCredential(text))
    }

    // MARK: - The drift

    /// UNRULED DRIFT — this test pins TODAY'S behaviour, not a blessing of it.
    ///
    /// `looksLikeCredential` catches URL-embedded credentials (patterns line 21) and Azure
    /// `AccountKey=` (line 22). Neither pattern was ever copied into `strongPatterns`, and the tier
    /// comment at CredentialDetector.swift:30-34 lists only the `sk-`/`bearer`/`key:value` families
    /// as intended exclusions — so the code and its own explanation disagree.
    ///
    /// Consequence today: a `postgres://admin:…@db/app` clip captured before the credential feature
    /// shipped, restored from a backup, or imported, is never promoted — it stays in items.json in
    /// CLEARTEXT forever, shows its password in the history row, and is exported in the clear. For
    /// `https://user:pass@host` it is worse: `ClipboardItem.linkURL` only suppresses items already
    /// flagged, so the row keeps a clickable "Open link" that hands the password to the browser.
    ///
    /// IF THE TEAM RULES THIS A BUG the fix is to copy those two patterns into `strongPatterns` and
    /// flip the second expectation here to `#expect(strict)`. That edit is the point of this test.
    @Test("a database URL password is caught live but is NOT promoted at rest — unruled drift",
          arguments: unruledDriftCases)
    func databaseURLPasswordIsCaughtLiveButNotPromotedAtRest(_ text: String) {
        #expect(CredentialDetector.looksLikeCredential(text))
        #expect(!CredentialDetector.looksLikeHighConfidenceCredential(text))
    }

    /// THE INVARIANT that keeps the two lists from diverging in the dangerous direction. A pattern
    /// added only to `strongPatterns` yields a clip that is cleartext when captured live but silently
    /// sealed and hidden after the next restart — a change the user never triggered and cannot
    /// attribute to anything. True for every input in this file today.
    @Test("anything promoted at rest is also flagged live")
    func strictImpliesLoose() {
        let corpus = Self.strongSecrets + Self.looseOnlyLookalikes + Self.unruledDriftCases + [
            "sk-AbCdEfGhIjKlMnOpQrStUvWxYz0123456789AbCdEfGhIjKl",
            ".sk-modal-overlay-backdrop { display: none; }",
            "plain english with no secrets in it whatsoever",
        ]
        for text in corpus where CredentialDetector.looksLikeHighConfidenceCredential(text) {
            #expect(CredentialDetector.looksLikeCredential(text),
                    "promoted at rest but not flagged live: \(text)")
        }
    }

    /// Fixed-bug marker (CredentialDetector.swift:62-65). The old rule was
    /// `newline && >= 200 chars → not a credential`, so a token pasted inside a .env block or a chat
    /// log was stored and previewed in cleartext. Both tiers now scan line by line. One test, not a
    /// family — the line-splitting is shared code.
    @Test("a token buried in a pasted .env block is still detected")
    func secretInsideMultiLineBlobIsDetected() {
        let env = """
        # local development
        DATABASE_URL=postgres://localhost/app
        GITHUB_TOKEN=ghp_AbCdEfGhIjKlMnOpQrStUvWxYz0123456789
        DEBUG=true
        """
        #expect(CredentialDetector.looksLikeCredential(env))
        #expect(CredentialDetector.looksLikeHighConfidenceCredential(env))
    }
}

/// The two choke points that stop a live secret riding along into a file the user hands to an AI or a
/// teammate — the app's headline workflow. `Storage.exportableText` feeds the combined PDF and the ZIP
/// .txt files; `MarkdownExporter.history` feeds Copy-all-as-Markdown.
///
/// `Storage.exportableText` is `static` and pure: calling it does NOT initialize `Storage.shared`, so
/// no directory is created and no disk is touched.
@Suite("Credentials never leave the machine inside an export")
struct CredentialExportTests {

    private static let secret = Fixture.stripeLive

    private static func credentialItem() -> ClipboardItem {
        ClipboardItem(kind: .text, text: secret,
                      preview: CredentialDetector.maskedPlaceholder, isCredential: true)
    }

    /// The `!contains("StUv")` half is the one that matters: it fails the day someone "tidies" the
    /// placeholder into a `masked()` call, which would print the secret's REAL last four characters
    /// into a document that then leaves the machine.
    @Test("an exported credential becomes a placeholder with none of the secret's characters")
    func exportableTextMasksCredentialWithoutLastFour() {
        let out = Storage.exportableText(Self.credentialItem())
        #expect(out == CredentialDetector.maskedPlaceholder)
        #expect(out?.contains("StUv") == false)
        #expect(out?.contains(Self.secret) == false)
    }

    /// The other side: the placeholder path must not swallow ordinary clips, or every export would
    /// come out as a page of key icons.
    @Test("an ordinary clip is exported verbatim, and an empty one is skipped")
    func exportableTextPassesOrdinaryTextThrough() {
        let normal = ClipboardItem(kind: .text, text: "deploy notes for friday", preview: "deploy notes")
        #expect(Storage.exportableText(normal) == "deploy notes for friday")
        #expect(Storage.exportableText(ClipboardItem(kind: .text, text: "", preview: "")) == nil)
        #expect(Storage.exportableText(ClipboardItem(kind: .text, text: nil, preview: "")) == nil)
    }

    /// Containment, NOT equality against the emitted line: that branch renders
    /// `L10n.t("export.credentialHidden")`, so an equality assertion would pass in English and fail
    /// for a Spanish- or German-UI user. Containment pins the actual security property and is
    /// locale-proof.
    @Test("a Markdown export of a credential contains no part of the secret")
    func markdownHistoryHidesCredential() {
        let out = MarkdownExporter.history([Self.credentialItem()])
        #expect(!out.contains(Self.secret))
        #expect(!out.contains("StUv"))
    }

    /// Without this, a regression that made `history` emit nothing at all would look green above.
    @Test("a Markdown export of an ordinary clip still contains its text")
    func markdownHistoryKeepsOrdinaryText() {
        let normal = ClipboardItem(kind: .text, text: "deploy notes for friday", preview: "deploy notes")
        #expect(MarkdownExporter.history([normal]).contains("deploy notes for friday"))
    }
}

/// Display-only masking (the menu-bar recents row and the history row). Lower stakes than the suites
/// above — one row of text, not a file leaving the machine — so this stays at five expectations.
@Suite("CredentialDetector.masked")
struct CredentialMaskTests {

    /// Multi-line blobs must never echo their content: masking only the tail would hide a harmless
    /// trailing line and reveal the secret above it. The literal in that branch DUPLICATES
    /// `maskedPlaceholder` instead of referencing it — comparing against the constant is what catches
    /// the two drifting apart and showing two different masks for the same concept.
    @Test("a multi-line secret is masked to the shared placeholder, never to its last line")
    func multiLineMasksToPlaceholder() {
        #expect(CredentialDetector.masked("a\nb") == CredentialDetector.maskedPlaceholder)
    }

    @Test("at most the last four characters are ever revealed")
    func revealsOnlyLastFour() {
        #expect(CredentialDetector.masked("sk-proj-AbCdEfGhIjKlMnOpQrStUv0123") == "••••0123")
    }

    /// The sharp edge. At 4 characters nothing is revealed; at 5, four of the five are. Both sides are
    /// pinned so the guard cannot be flipped to `>= 4` — which would make a 4-character secret render
    /// as itself.
    @Test("a four-character secret reveals nothing, a five-character one reveals four")
    func theLengthBoundary() {
        #expect(CredentialDetector.masked("abcd") == "••••")
        #expect(CredentialDetector.masked("abcde") == "••••bcde")
    }

    /// Pasteboard text routinely arrives padded. Trailing spaces must not become the "revealed" tail —
    /// that would show `•••• ` and hide nothing useful while looking like it worked.
    @Test("surrounding whitespace is not mistaken for the revealed tail")
    func whitespaceIsTrimmedBeforeMasking() {
        #expect(CredentialDetector.masked("  " + Fixture.stripeLive + "  ") == "••••StUv")
    }
}

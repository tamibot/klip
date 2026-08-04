import Foundation
import Testing
@testable import Klip

/// `VocabularyMiner` reads the user's clipboard history and proposes words for the transcription
/// context-words field. Two things must hold or the feature is worse than nothing: it has to surface the
/// terms Whisper actually mangles (acronyms, product names) instead of common prose, and it must never
/// put a secret into a settings field the user might screenshot.
@Suite("Vocabulary mining from the history")
struct VocabularyMinerTests {

    /// Real-shaped history: fast Spanish business text with English technical terms mixed in.
    private let history = [
        "Revisamos el ROI del CRM con el equipo de ventas.",
        "El ROI subió y el CRM ya está conectado con WhatsApp.",
        "Mandé el reporte por WhatsApp; falta el LTV y el LTV por cohorte.",
        "WhisperKit corre en el Mac. Probé WhisperKit con audio en español."
    ]

    @Test("Acronyms and product names are found")
    func findsAcronymsAndProducts() {
        let found = VocabularyMiner.suggestions(from: history)
        for word in ["ROI", "CRM", "LTV", "WhatsApp", "WhisperKit"] {
            #expect(found.contains(word), "\(word) missing from \(found)")
        }
    }

    /// Frequency alone would rank "el" and "the" first. Anything a speech model already transcribes
    /// correctly is noise in this list — it dilutes the prompt Whisper is given.
    @Test("Ordinary Spanish and English words are not suggested")
    func ignoresOrdinaryProse() {
        let spanish = Array(repeating: "Hola, gracias por el correo. Este es el resumen de la reunión de hoy con el equipo.", count: 5)
        #expect(VocabularyMiner.suggestions(from: spanish).isEmpty)

        let english = Array(repeating: "Thanks for the email. This is the summary of the meeting with the team.", count: 5)
        #expect(VocabularyMiner.suggestions(from: english).isEmpty)

        // And not from the mixed history either, where they sit next to real candidates.
        let found = VocabularyMiner.suggestions(from: history)
        for word in ["equipo", "ventas", "reporte", "Revisamos", "el", "con"] {
            #expect(!found.contains(word), "\(word) should not be suggested")
        }
    }

    /// The loanword shape only fires inside Spanish text: in English prose the same orthographic
    /// markers match half the dictionary.
    @Test("English technical terms inside Spanish text are found; in English text they are not")
    func loanwordsOnlyInSpanish() {
        let spanish = Array(repeating: "Gastamos muchos tokens en el workflow de marketing.", count: 2)
        let found = VocabularyMiner.suggestions(from: spanish)
        for word in ["tokens", "workflow", "marketing"] {
            #expect(found.contains(word), "\(word) missing from \(found)")
        }
        let english = Array(repeating: "We spent tokens on the marketing workflow again.", count: 2)
        #expect(VocabularyMiner.suggestions(from: english).isEmpty)
    }

    /// A mined word lands in a Preferences text field the user may screenshot or share. Clips holding
    /// anything `CredentialDetector` recognises are dropped WHOLE — the words around a secret ("OpenAI",
    /// "NuevoCRM" here) would otherwise score well and drag the secret's own fragments along with them.
    @Test("Credentials never reach the suggestions")
    func neverSuggestsSecrets() {
        let secret = "sk-proj-abcdefghijklmnopqrstuvwxyzABCDEFGH012345"
        let clips = [
            "\(secret) es la key de OpenAI para el proyecto NuevoCRM",
            "Rota \(secret) y guarda la key de OpenAI del proyecto NuevoCRM",
            "ghp_abcdefghijklmnopqrstuvwxyz0123 token de GitHub para el repo NuevoCRM",
            "Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVPmB92K27uhbUJU1p1r"
        ]
        let found = VocabularyMiner.suggestions(from: clips)
        #expect(found.isEmpty, "mined \(found) out of clips that all contain credentials")

        // Belt and braces: mixed history plus one secret-bearing clip. The clean clips still yield
        // words, and no fragment of the secret is among them.
        let mixed = history + clips
        let mixedFound = VocabularyMiner.suggestions(from: mixed)
        #expect(mixedFound.contains("ROI"))
        for word in mixedFound {
            #expect(!secret.localizedCaseInsensitiveContains(word), "\(word) is a fragment of the key")
            #expect(word.allSatisfy { $0.isLetter }, "\(word) is not a plain word")
            #expect(!["OpenAI", "NuevoCRM", "GitHub", "Bearer"].contains(word),
                    "\(word) came from a clip that holds a credential")
        }
    }

    /// The list is shown as buttons the user taps one by one: it must not reshuffle between two presses
    /// of the same button. Score first (shape weight × how many clips used the word), then the word
    /// itself, so ties have one defined order.
    @Test("Ranking is stable and score-ordered")
    func rankingIsStable() {
        #expect(VocabularyMiner.suggestions(from: history) == ["CRM", "ROI", "WhatsApp", "LTV", "WhisperKit"])
        #expect(VocabularyMiner.rank(history) == VocabularyMiner.rank(history))
        // Recurring across clips outranks recurring inside one: ROI (2 clips) over LTV (1 clip).
        let scores = Dictionary(uniqueKeysWithValues: VocabularyMiner.rank(history).map { ($0.word, $0.score) })
        #expect(scores["ROI"]! > scores["LTV"]!)
    }

    /// The scan is bounded so the button can never walk the whole store: clips past `maxClips` are not
    /// read at all, however loud they are.
    @Test("Work is bounded")
    func boundIsEnforced() {
        let clips = Array(repeating: "Revisamos el ROI del CRM.", count: VocabularyMiner.maxClips)
            + Array(repeating: "Sincronizamos Kommo con Kommo.", count: 2000)
        #expect(!VocabularyMiner.suggestions(from: clips).contains("Kommo"))
        #expect(VocabularyMiner.suggestions(from: clips).contains("ROI"))
    }

    /// The regression that shipped: seven fragments of ONE 116-character base64 token reached the
    /// user's Preferences window. Every secret in `neverSuggestsSecrets` is one CredentialDetector
    /// already recognises, so barrier 1 caught them all and the later barriers were never exercised —
    /// the suite could not fail on the case that actually occurred. This one uses an OPAQUE token no
    /// pattern knows, which is the only honest test of the entropy barrier.
    @Test("an opaque token no detector recognises never reaches the suggestions")
    func opaqueTokenIsNeverSuggested() {
        // Deliberately matches no CredentialDetector pattern: no sk-/ghp_/AKIA prefix, no JWT dots.
        let opaque = "Zm9vYmFyYmF6cXV4MTIzNDU2Nzg5MGFiY2RlZmdoaWprbG1ub3BxcnN0dXZ3eHl6QUJDREVGR0hJSktMTU5PUFFS"
        #expect(!CredentialDetector.looksLikeCredential(opaque),
                "if this starts failing the test is no longer exercising the entropy barrier")

        // Copied eight times, the way a real credential ends up in a history.
        let texts = Array(repeating: "Pega esto en el panel: \(opaque)", count: 8)
            + ["Hablamos del CRM y del ROI con la inmobiliaria", "El CRM manda el lead por WhatsApp"]
        let words = VocabularyMiner.suggestions(from: texts, limit: 20)

        // No suggestion may be a substring of the secret — that is what a "fragment" is.
        for w in words {
            #expect(!opaque.lowercased().contains(w.lowercased()),
                    "leaked a fragment of the opaque token: \(w)")
        }
        // And the real vocabulary in the same history still comes through.
        #expect(words.contains { $0.uppercased() == "CRM" })
    }

    @Test("a long mixed-alphanumeric run is treated as opaque, short ones are not")
    func opaqueRunBoundary() {
        let long = "AbCd1234EfGh5678IjKl9012MnOp"          // 28 chars, letters + digits
        #expect(VocabularyMiner.isOpaqueRun(around: long.prefix(4), in: long))
        // Versions and product names must stay minable.
        for ok in ["macOS-26", "large-v3-turbo", "WhatsApp", "Klip-2026"] {
            #expect(!VocabularyMiner.isOpaqueRun(around: ok.prefix(4), in: ok), "false positive on \(ok)")
        }
    }

}

import Foundation

/// Mines the clipboard history for the words a speech model gets wrong and the user would never think
/// to type into the context-words field: acronyms (ROI, CRM, LTV), product names (WhatsApp, WhisperKit),
/// loanwords inside Spanish text (tokens, workflow) and recurring proper nouns (Kommo, Miraflores).
///
/// Pure, `nonisolated`, no I/O: the caller hands it strings and gets ranked words back, so it can run
/// off the main actor. Frequency alone would rank "the" first — every candidate must therefore have a
/// SHAPE that is unusual in ordinary prose, and the shape sets the weight.
enum VocabularyMiner {

    // MARK: - Bound

    /// Hard bound on the work, so pressing the button can never scan the whole store: the newest
    /// `maxClips` text clips, each read up to `maxCharsPerClip` characters — one pass, no I/O.
    ///
    /// 400, not the full 1000-clip history, because the credential screen dominates the cost (~6 ms per
    /// clip: `CredentialDetector` runs 24 regexes over every line). Measured, release build, on 400 clips
    /// of the maximum 2000 characters each: ~2.7 s worst case, ~0.4 s on realistically short clips —
    /// against ~7 s if the bound were 1000. A word worth suggesting is one that RECURS, so it is almost
    /// certainly already in the newest 400 clips.
    /// ponytail: caching the compiled regexes in CredentialDetector would buy back the whole budget —
    /// it is shared privacy code, so it wants its own change, not a drive-by here.
    static let maxClips = 400
    static let maxCharsPerClip = 2000

    // MARK: - Public

    struct Candidate: Equatable {
        let word: String
        let score: Int
    }

    /// Ranked words, best first. Deterministic: equal scores are ordered case-insensitively by the word,
    /// so the same history always proposes the same list in the same order.
    static func rank(_ texts: [String]) -> [Candidate] {
        // key = lowercased word; value = surface forms with their counts + the clips it appeared in.
        var forms: [String: [String: Int]] = [:]
        var clips: [String: Set<Int>] = [:]
        var shapes: [String: Shape] = [:]

        for (clipIndex, raw) in texts.prefix(maxClips).enumerated() {
            // BARRIER 1 — a clip holding anything CredentialDetector recognises is dropped whole, not
            // scrubbed: a secret is usually surrounded by the very context that would score well.
            guard !CredentialDetector.looksLikeCredential(raw) else { continue }
            let text = String(raw.prefix(maxCharsPerClip))
            let spanish = looksSpanish(text)

            for token in text.split(whereSeparator: { !$0.isLetter }) {
                // BARRIER 1b — the run this token was CUT OUT OF, digits and symbols included.
                // Barrier 1 only knows the secret formats it has patterns for; an opaque token from
                // an unknown vendor passes it untouched. Splitting on non-letters then throws away
                // the digits that were the only evidence it was opaque, and the surviving letter
                // fragments look like product names — which is exactly how seven fragments of one
                // 116-character base64 string reached this user's Preferences window.
                guard !isOpaqueRun(around: token, in: text) else { continue }
                guard let shape = shape(of: token, inSpanishText: spanish) else { continue }
                let word = String(token)
                let key = word.lowercased()
                guard !stopwords.contains(key) else { continue }
                forms[key, default: [:]][word, default: 0] += 1
                clips[key, default: []].insert(clipIndex)
                // First shape seen wins; a word's shape is a property of its spelling, not of the clip.
                if shapes[key] == nil { shapes[key] = shape }
            }
        }

        return forms.compactMap { key, surfaces -> Candidate? in
            let total = surfaces.values.reduce(0, +)
            // Said once, anywhere, is noise — and it is also the shape a stray base64 fragment takes.
            guard total >= 2, let shape = shapes[key], let clipCount = clips[key]?.count else { return nil }
            // Most frequent spelling wins ("WhatsApp" over "Whatsapp"); alphabetical on a tie, for determinism.
            let word = surfaces.max { ($0.value, $1.key) < ($1.value, $0.key) }!.key
            return Candidate(word: word, score: shape.weight * clipCount)
        }
        .sorted { ($1.score, $0.word.lowercased()) < ($0.score, $1.word.lowercased()) }
    }

    /// Convenience for the UI: the top `limit` words.
    static func suggestions(from texts: [String], limit: Int = 12) -> [String] {
        rank(texts).prefix(limit).map(\.word)
    }

    // MARK: - Shapes

    private enum Shape {
        case acronym    // ROI, CRM, API
        case product    // WhatsApp, WhisperKit, TikTok
        case loanword   // "tokens", "workflow" — inside Spanish text
        case proper     // Kommo, Miraflores

        /// How much a single clip's worth of this shape is worth. Acronyms and product names are what
        /// transcription actually mangles; a capitalised word is often just a sentence start.
        var weight: Int {
            switch self {
            case .acronym, .product: return 3
            case .loanword: return 2
            case .proper: return 1
            }
        }
    }

    private static func shape(of token: Substring, inSpanishText spanish: Bool) -> Shape? {
        let chars = Array(token)
        guard chars.count >= 3, chars.count <= 20 else { return nil }
        let hasLower = chars.contains(where: \.isLowercase)

        if !hasLower {
            // All caps. Long shouted words ("GRACIAS") are not acronyms.
            return chars.count <= 8 && chars.allSatisfy(\.isUppercase) ? .acronym : nil
        }
        // BARRIER 2 (partial) — a vowel-less letter run is hex/base64 debris, never a word.
        guard chars.contains(where: { "aeiouAEIOUáéíóúüÁÉÍÓÚÜ".contains($0) }) else { return nil }

        // A capital after a lowercase = CamelCase: only product names are written that way.
        for i in 1..<chars.count where chars[i].isUppercase && chars[i - 1].isLowercase { return .product }

        if chars[0].isUppercase { return .proper }

        // Lowercase word. Only interesting inside Spanish prose, where non-Spanish spelling means a
        // borrowed technical term. In English text these markers match half the dictionary.
        // ponytail: orthographic markers, not a dictionary — it catches "tokens"/"workflow"/"marketing"
        // but not "lead" or "deal". A frequency table would catch those; it is not worth 100 KB of data.
        guard spanish else { return nil }
        let w = String(token).lowercased()
        guard !spanishNativeWithForeignLook.contains(w) else { return nil }
        let markers = ["k", "w", "sh", "ck", "th", "ph", "ss", "ff"]
        if markers.contains(where: { w.contains($0) }) || w.hasSuffix("ing") { return .loanword }
        return nil
    }

    /// Cheap "is this clip Spanish?" check: accents or the commonest function words. Only gates the
    /// loanword shape, so a wrong answer costs a missed suggestion, never a bad one.
    private static func looksSpanish(_ text: String) -> Bool {
        let t = " " + text.lowercased() + " "
        if t.contains(where: { "áéíóúñ¿¡".contains($0) }) { return true }
        for w in [" que ", " de ", " la ", " el ", " los ", " para ", " con ", " una ", " por "]
        where t.contains(w) { return true }
        return false
    }

    /// Spanish words that trip the foreign-spelling markers.
    private static let spanishNativeWithForeignLook: Set<String> = [
        "kilo", "kilos", "kilómetro", "kilómetros", "kiosco", "karate", "whisky", "web", "okay", "kit"
    ]

    /// Common words that survive the shape filters: sentence-initial capitals ("Para", "The"), everyday
    /// shouted words, and the Spanish/English function words that would otherwise dominate the ranking.
    private static let stopwords: Set<String> = [
        // Spanish
        "que", "para", "con", "por", "los", "las", "una", "unos", "unas", "del", "este", "esta", "esto",
        "estos", "estas", "ese", "esa", "eso", "pero", "como", "más", "muy", "todo", "toda", "todos",
        "todas", "hay", "son", "está", "están", "ser", "hacer", "puede", "pueden", "cuando", "donde",
        "porque", "también", "sobre", "entre", "hasta", "desde", "ahora", "hola", "gracias", "buenos",
        "buenas", "días", "tardes", "señor", "señora", "favor", "bien", "sí", "no", "nos", "les",
        // English
        "the", "this", "that", "these", "those", "and", "but", "for", "with", "from", "you", "your",
        "our", "their", "they", "them", "have", "has", "had", "was", "were", "are", "will", "would",
        "can", "could", "should", "not", "all", "any", "some", "what", "when", "where", "which", "who",
        "why", "how", "hello", "hi", "thanks", "thank", "please", "here", "there", "then", "than",
        "about", "into", "out", "just", "like", "make", "made", "need", "want", "get", "got", "new",
        "one", "two", "now", "yes",
        // shouted acronym-shaped noise
        "www", "http", "https", "html", "faq", "nan", "null"
    ]

    /// True when the unbroken run of secret-ish characters containing `token` looks like an opaque
    /// blob rather than words: long, and mixing letters with digits or base64 padding.
    ///
    /// This is the barrier CredentialDetector cannot be: it recognises FORMATS it has patterns for,
    /// so a token from a vendor it has never seen walks straight through. Entropy needs no pattern.
    /// Deliberately conservative — it only fires on a long run, so ordinary prose, hyphenated words
    /// and version numbers ("macOS-26", "v3-turbo") stay minable.
    static func isOpaqueRun(around token: Substring, in text: String) -> Bool {
        // Grow outward through the characters a secret is actually made of.
        let secretish: (Character) -> Bool = { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "+" || $0 == "/" || $0 == "=" || $0 == "." }
        var lo = token.startIndex, hi = token.endIndex
        while lo > text.startIndex {
            let prev = text.index(before: lo)
            if secretish(text[prev]) { lo = prev } else { break }
        }
        while hi < text.endIndex, secretish(text[hi]) { hi = text.index(after: hi) }
        let run = text[lo..<hi]
        guard run.count >= 24 else { return false }          // short runs are words, paths, versions
        let digits = run.filter(\.isNumber).count
        let letters = run.filter(\.isLetter).count
        guard letters > 0 else { return false }
        // A long run carrying digits, or base64 padding, is not language.
        return digits > 0 || run.contains("=") || run.contains("/") || run.contains("+")
    }

}

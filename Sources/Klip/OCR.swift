import Foundation
import Vision
import AppKit

/// Text recognition in images using the Vision framework (on-device).
enum OCR {
    static func recognizeText(in image: NSImage) -> String {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return ""
        }
        return recognizeText(in: cg)
    }

    /// Common code tokens that language correction tends to "fix" into prose; listing them as custom
    /// words keeps them intact even though correction is off.
    private static let codeWords = ["func", "let", "var", "const", "async", "await", "return", "nil",
                                    "null", "void", "import", "export", "class", "struct", "enum",
                                    "true", "false", "=>", "->", "==", "!=", "&&", "||"]

    /// The user's preferred languages (mapped to identifiers this Vision revision actually supports —
    /// raw locale ids like "es-PE"/"zh-CN" don't match Vision's "es-ES"/"zh-Hans") followed by the
    /// en/es defaults, deduped. OCR reads the user's own language without paying the auto-detect pass.
    private static func recognitionLanguages(for request: VNRecognizeTextRequest) -> [String] {
        let supported = (try? request.supportedRecognitionLanguages()) ?? []
        let preferred = Locale.preferredLanguages.compactMap { pref in
            supported.first { $0 == pref || $0.hasPrefix(String(pref.prefix(2))) }
        }
        var out: [String] = []
        for l in preferred + ["en-US", "es-ES"] where !out.contains(l) { out.append(l) }
        return out
    }

    static func recognizeText(in cgImage: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // OFF for code: language correction rewrites symbols/identifiers into prose (== → =, names →
        // dictionary words, dropped punctuation). Off is both more accurate for code and faster.
        request.usesLanguageCorrection = false
        request.recognitionLanguages = recognitionLanguages(for: request)
        request.automaticallyDetectsLanguage = false   // we specify the languages → skip the detection pass (faster)
        request.customWords = codeWords
        request.minimumTextHeight = 0   // don't skip tiny terminal/log fonts

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return ""
        }

        guard let observations = request.results else { return "" }
        let lines = observations.compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }
}

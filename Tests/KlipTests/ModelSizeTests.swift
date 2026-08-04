import Foundation
import Testing
@testable import Klip

/// `Recorder.modelSize` reads the download size out of `LocalTranscriber.models`' free-text `note`
/// ("~464 MB · balanced"). That is a display string, so a reformat there would silently
/// feed the Upload window either garbage or nothing at all — and this number is the whole reason the
/// first upload no longer looks hung. Pin the contract from both ends.
@Suite("On-device model download size")
struct ModelSizeTests {

    @Test("Every offered model reports a size, and only the size")
    func everyModelHasASize() {
        for m in LocalTranscriber.models {
            let size = Recorder.modelSize(m.id)
            #expect(!size.isEmpty, "no size parsed for \(m.id) from note \"\(m.note)\"")
            // A size and nothing else: no leaked "·", no trailing prose like "balanced".
            #expect(size.range(of: "^~?[0-9.]+ (MB|GB)$", options: .regularExpression) != nil,
                    "\(m.id) yielded \"\(size)\"")
        }
    }

    @Test("Empty model name resolves to the default model's size")
    func emptyFallsBackToDefault() {
        #expect(Recorder.modelSize("") == Recorder.modelSize(LocalTranscriber.defaultModel))
    }

    /// Settings seeds fresh installs with `recommendedModel` and everything else resolves to
    /// `defaultModel`. Either one missing from `models` = a Preferences picker with no selected row and a
    /// download the user was never shown a size for.
    @Test("The seeded and fallback models are both offered in the picker")
    func seededModelsAreOffered() {
        for id in [LocalTranscriber.recommendedModel, LocalTranscriber.defaultModel] {
            #expect(LocalTranscriber.models.contains { $0.id == id }, "\(id) is not in the picker")
        }
    }

    @Test("Unknown model promises no number")
    func unknownModelIsBlank() {
        // The UI drops the size when this is empty rather than inventing one.
        #expect(Recorder.modelSize("not-a-model").isEmpty)
    }
}

/// The two pure gates behind "re-transcribe this note with a better model". Both decide whether the UI
/// OFFERS the action, and getting either wrong is destructive: an empty upgrade list hides the feature,
/// a missed meeting transcript lets a retry flatten the Me/Them labels that can never be rebuilt.
@Suite("Re-transcribe with a better model")
struct ImproveEligibilityTests {

    @Test("Only strictly more accurate models are offered, best last")
    func betterModelsAreTheTail() {
        // `models` is ordered by accuracy: the upgrades for entry i are exactly i+1…end.
        for (i, m) in LocalTranscriber.models.enumerated() {
            let better = Recorder.betterModels(than: m.id)
            #expect(better.map(\.id) == LocalTranscriber.models.dropFirst(i + 1).map(\.id), "wrong tail for \(m.id)")
            #expect(!better.contains { $0.id == m.id }, "\(m.id) offered as an upgrade over itself")
        }
        // The most accurate model has nothing to upgrade to → the UI offers nothing.
        #expect(Recorder.betterModels(than: LocalTranscriber.models.last!.id).isEmpty)
        // "" means "the default model" everywhere else in Klip; it must here too.
        #expect(Recorder.betterModels(than: "").map(\.id)
                == Recorder.betterModels(than: LocalTranscriber.defaultModel).map(\.id))
    }

    @Test("A meeting transcript is recognised in every UI language")
    func meetingTranscriptsAreDetected() {
        for (lang, table) in L10n.tables {
            for key in ["meeting.me", "meeting.them"] {
                let label = table[key]!
                #expect(Recorder.isSpeakerLabeled("\(label): hola qué tal\n\nx"), "\(lang)/\(key) not detected")
            }
        }
        // Leading whitespace/newlines must not hide the label.
        #expect(Recorder.isSpeakerLabeled("\n  Me: hello"))
    }

    @Test("A normal voice note is not mistaken for a meeting")
    func plainNotesAreImprovable() {
        #expect(!Recorder.isSpeakerLabeled(""))
        #expect(!Recorder.isSpeakerLabeled("   \n "))
        #expect(!Recorder.isSpeakerLabeled("Necesito los leads de WhatsApp para el ROI de mañana"))
        #expect(!Recorder.isSpeakerLabeled("Metrics: revenue, tokens, ROI"))   // a colon, but not a speaker label
    }
}

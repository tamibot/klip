import Foundation
import Testing
@testable import Klip

/// `Recorder.modelSize` reads the download size out of `LocalTranscriber.models`' free-text `note`
/// ("~480 MB · balanced (recommended)"). That is a display string, so a reformat there would silently
/// feed the Upload window either garbage or nothing at all — and this number is the whole reason the
/// first upload no longer looks hung. Pin the contract from both ends.
@Suite("On-device model download size")
struct ModelSizeTests {

    @Test("Every offered model reports a size, and only the size")
    func everyModelHasASize() {
        for m in LocalTranscriber.models {
            let size = Recorder.modelSize(m.id)
            #expect(!size.isEmpty, "no size parsed for \(m.id) from note \"\(m.note)\"")
            // A size and nothing else: no leaked "·", no trailing prose like "balanced (recommended)".
            #expect(size.range(of: "^~?[0-9.]+ (MB|GB)$", options: .regularExpression) != nil,
                    "\(m.id) yielded \"\(size)\"")
        }
    }

    @Test("Empty model name resolves to the default model's size")
    func emptyFallsBackToDefault() {
        #expect(Recorder.modelSize("") == Recorder.modelSize(LocalTranscriber.defaultModel))
    }

    @Test("Unknown model promises no number")
    func unknownModelIsBlank() {
        // The UI drops the size when this is empty rather than inventing one.
        #expect(Recorder.modelSize("not-a-model").isEmpty)
    }
}

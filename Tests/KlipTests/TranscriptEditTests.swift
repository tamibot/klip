import Foundation
import Testing
@testable import Klip

/// Hand-editing a wrong transcription (panel row → "Fix the transcript", or ⌘E).
///
/// The edit is written through `ClipboardManager.finishVoiceNote(id:text:)` — the same call the
/// transcriber makes — which mutates the item IN PLACE and then saves. Three things must hold and
/// none of them is obvious from reading the call site:
///
///   1. the new text survives a save/load cycle;
///   2. the audio file, its duration and the item's identity (id, createdAt) come back untouched,
///      along with everything else the user owns (name, pinned, collection);
///   3. an edit that types a secret is still caught by the credential path, so editing cannot be
///      used to smuggle a token past the mask / the export filter.
///
/// CEILING, stated so nobody mistakes this for more than it is: `finishVoiceNote` itself is not
/// called here. It lives on a `@MainActor ClipboardManager` whose `init()` binds `Storage.shared`,
/// i.e. the developer's REAL ~/Library/Application Support/Klip — instantiating one in a test
/// process would load and then overwrite a live history. (`HOME` is not an escape hatch either:
/// `FileManager.urls(for:.applicationSupportDirectory)` resolved to the real home under an
/// overridden `HOME` when this was checked.) So the round trip below goes through the same encoder
/// and decoder configuration `Storage.saveItems` / `loadItemsRaw` use, on a temp file.
@Suite("Editing a transcript by hand")
struct TranscriptEditTests {

    /// A finished voice note with everything an edit must not disturb: stored audio, a measured
    /// duration, a user-set name, a star, and a collection.
    private static func voiceNote(text: String) -> ClipboardItem {
        ClipboardItem(kind: .text,
                      text: text,
                      preview: "🎙 " + text,
                      createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                      pinned: true,
                      isVoiceNote: true,
                      transcribing: false,
                      audioFileName: "voice-2026-08-04-091200.m4a",
                      audioDuration: 73.5,
                      name: "Llamada con el cliente",
                      collection: "CRM")
    }

    /// Same configuration as `Storage.saveItems` / `Storage.loadItemsRaw`, on a temp file.
    private static func saveLoad(_ items: [ClipboardItem]) throws -> [ClipboardItem] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("klip-edit-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try encoder.encode(items).write(to: url, options: .atomic)
        return try decoder.decode([ClipboardItem].self, from: try Data(contentsOf: url))
    }

    /// The real failure this pins: the transcription said "MIDI" where the user said "lead".
    @Test("the corrected text survives a save/load cycle and disturbs nothing else")
    func editedTextRoundTrips() throws {
        let original = Self.voiceNote(text: "el MIDI entró por WhatsApp con TOTEN de más")
        let fixed = "el lead entró por WhatsApp con tokens de más"

        // Exactly the fields finishVoiceNote writes — nothing else is touched.
        var edited = original
        edited.text = fixed
        edited.preview = "🎙 " + fixed
        edited.transcribing = false

        let loaded = try #require(try Self.saveLoad([edited]).first)

        #expect(loaded.text == fixed)
        #expect(loaded.preview == "🎙 " + fixed)
        // Identity and audio: the note must still be the same note, still playable, still retryable.
        #expect(loaded.id == original.id)
        #expect(loaded.createdAt == original.createdAt)
        #expect(loaded.audioFileName == original.audioFileName)
        #expect(loaded.audioDuration == original.audioDuration)
        #expect(loaded.isVoiceNote == true)
        #expect(loaded.transcribing == false)
        // Everything else the user set by hand.
        #expect(loaded.name == original.name)
        #expect(loaded.pinned == original.pinned)
        #expect(loaded.collection == original.collection)
        #expect(loaded.kind == .text)
    }

    /// The row swaps on `ClipboardItem.==`. If text were left out of it the edit would be invisible
    /// until the panel was reopened, and the user would retype it.
    @Test("the edited item is not equal to the original, so the row re-renders")
    func equalitySeesTheEdit() {
        var edited = Self.voiceNote(text: "antes")
        edited.text = "después"
        #expect(edited != Self.voiceNote(text: "antes"))
    }

    /// Editing must not become a side door around the credential rules. `finishVoiceNote` re-runs the
    /// live detector on whatever was typed, so a secret dictated OR typed into the editor comes back
    /// masked, and `Storage.saveItems` seals it. Both halves are asserted with the real functions.
    @Test("typing a secret into the editor is still detected, masked and kept out of exports")
    func editingInASecretIsStillTreatedAsACredential() throws {
        let typed = "the key is " + Fixture.stripeLive
        #expect(CredentialDetector.looksLikeCredential(typed))

        // What finishVoiceNote does with a positive detection.
        var edited = Self.voiceNote(text: "wrong transcript")
        edited.text = typed
        edited.isCredential = true
        edited.preview = CredentialDetector.maskedPlaceholder

        let loaded = try #require(try Self.saveLoad([edited]).first)
        #expect(loaded.isCredential == true)
        #expect(loaded.preview == CredentialDetector.maskedPlaceholder)
        #expect(!loaded.preview.contains(Fixture.stripeLive))
        // The export filter keeps working on the edited item: the secret never reaches a PDF/ZIP.
        let exported = Storage.exportableText(loaded)
        #expect(exported == nil || !(exported ?? "").contains(Fixture.stripeLive))
    }
}

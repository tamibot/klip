import Foundation

/// Type of item stored in the clipboard history.
enum ClipboardKind: String, Codable {
    case text
    case image
    case video   // screen recording — the movie lives in the store's videos/ dir
}

/// An item in the clipboard history (text or image).
struct ClipboardItem: Identifiable, Codable, Equatable {
    let id: UUID
    var kind: ClipboardKind
    var text: String?
    var imageFileName: String?
    var preview: String
    var createdAt: Date
    var pinned: Bool

    // New fields (Optional => the old items.json decodes without error: they stay nil).
    var sourceName: String?       // "Google Chrome", "Notas"…
    var sourceBundleID: String?   // "com.google.Chrome"
    var isRemote: Bool?           // heuristic: "another Apple device"
    var isVoiceNote: Bool?        // voice note transcription
    var transcribing: Bool?       // voice note: transcription in progress (state, language-independent)
    var isCredential: Bool?       // marked as a credential (token/API key)
    var audioFileName: String?    // voice note: original audio file saved (m4a) for playback
    var audioDuration: Double?    // audio duration in seconds (for display and the progress bar)
    var name: String?             // user-set label (searchable title; applies to any item)
    var collection: String?       // name of the collection it belongs to (groups batches of context)
    var videoFileName: String?    // screen recording: movie file in the store (videos/)
    var videoDuration: Double?    // recording duration in seconds (for the row subtitle)

    init(id: UUID = UUID(),
         kind: ClipboardKind,
         text: String? = nil,
         imageFileName: String? = nil,
         preview: String,
         createdAt: Date = Date(),
         pinned: Bool = false,
         sourceName: String? = nil,
         sourceBundleID: String? = nil,
         isRemote: Bool? = nil,
         isVoiceNote: Bool? = nil,
         transcribing: Bool? = nil,
         isCredential: Bool? = nil,
         audioFileName: String? = nil,
         audioDuration: Double? = nil,
         name: String? = nil,
         collection: String? = nil,
         videoFileName: String? = nil,
         videoDuration: Double? = nil) {
        self.id = id
        self.kind = kind
        self.text = text
        self.imageFileName = imageFileName
        self.preview = preview
        self.createdAt = createdAt
        self.pinned = pinned
        self.sourceName = sourceName
        self.sourceBundleID = sourceBundleID
        self.isRemote = isRemote
        self.isVoiceNote = isVoiceNote
        self.transcribing = transcribing
        self.isCredential = isCredential
        self.audioFileName = audioFileName
        self.audioDuration = audioDuration
        self.name = name
        self.collection = collection
        self.videoFileName = videoFileName
        self.videoDuration = videoDuration
    }

    /// The clip as a web URL if it's exactly a single http(s) link — used by the Links filter and the
    /// "Open link" row action.
    var linkURL: URL? {
        guard kind == .text, isVoiceNote != true, isCredential != true,
              let t = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              t.lowercased().hasPrefix("http://") || t.lowercased().hasPrefix("https://"),
              !t.contains(where: \.isWhitespace),   // a single URL: no spaces, tabs or newlines
              let u = URL(string: t), u.host != nil else { return nil }
        return u
    }

    // Full ==: SwiftUI uses it to decide whether to re-render a row. It must also reflect
    // text/preview/audioFileName so the voice note updates when it goes from "Transcribiendo…"
    // to its final text (and when its audio is saved).
    static func == (lhs: ClipboardItem, rhs: ClipboardItem) -> Bool {
        lhs.id == rhs.id && lhs.pinned == rhs.pinned && lhs.createdAt == rhs.createdAt
            && lhs.isCredential == rhs.isCredential && lhs.isVoiceNote == rhs.isVoiceNote
            && lhs.transcribing == rhs.transcribing
            && lhs.isRemote == rhs.isRemote
            && lhs.text == rhs.text && lhs.preview == rhs.preview
            && lhs.imageFileName == rhs.imageFileName && lhs.audioFileName == rhs.audioFileName
            && lhs.audioDuration == rhs.audioDuration   // drives the voice-note progress bar UI
            && lhs.name == rhs.name && lhs.collection == rhs.collection
            && lhs.videoFileName == rhs.videoFileName && lhs.videoDuration == rhs.videoDuration
    }
}

import AppKit
import Combine

/// Snapshot of the source taken at the start of poll().
struct CaptureSource {
    let name: String?
    let bundleID: String?
}

/// Monitors the pasteboard, maintains the history, and exposes actions.
/// @MainActor: all state (items, voicePasteGuards…) is driven from the main RunLoop poll and SwiftUI, so
/// the main-thread requirement is guaranteed by the compiler instead of by convention.
@MainActor
final class ClipboardManager: ObservableObject {
    @Published private(set) var items: [ClipboardItem] = []

    private var timer: Timer?
    private var lastChangeCount: Int
    private var maxItems: Int { Settings.shared.maxItems }
    private let storage = Storage.shared
    private let settings = Settings.shared
    private let ownBundleID = Bundle.main.bundleIdentifier

    init() {
        lastChangeCount = NSPasteboard.general.changeCount
        items = storage.loadItemsRaw()   // sealed credentials stay sealed here: NO Keychain access on the
                                         // launch/main thread (it can trigger a blocking trust prompt → hang)
        decryptCredentialsInBackground() // decrypts off the main thread, then merges the plaintext back in
        reconcileVoiceNotesOnLoad()
        // Clean up orphans (audio/images with no item, e.g. after quitting mid-transcription).
        // Only when there are items: an empty items array also happens when items.json is corrupt/unreadable, and in
        // that case the sweep would delete ALL media (we avoid that loss; the files stay there for recovery).
        if !items.isEmpty {
            storage.pruneOrphans(
                referencedAudio: Set(items.compactMap { $0.audioFileName }),
                referencedImages: Set(items.compactMap { $0.imageFileName }))
        }
    }

    /// Repairs voice notes stuck at "Transcribing…" (the app quit during transcription):
    /// if they still have their audio, they become "no transcription" (recoverable); otherwise they are discarded.
    private func reconcileVoiceNotesOnLoad() {
        var changed = false
        for idx in items.indices where items[idx].isVoiceNote == true && items[idx].transcribing == true {
            if let af = items[idx].audioFileName, storage.audioExists(fileName: af) {
                items[idx].text = nil
                items[idx].preview = Self.voiceFailed
                items[idx].transcribing = false   // recoverable: no longer "in progress"
            } else {
                items[idx].audioFileName = nil     // mark for deletion (keeps transcribing == true)
            }
            changed = true
        }
        let before = items.count
        items.removeAll { $0.isVoiceNote == true && $0.transcribing == true && $0.audioFileName == nil }
        if changed || items.count != before { storage.saveItems(items) }
    }

    /// Decrypts sealed credentials OFF the main thread, then merges the plaintext back in. Keychain access
    /// can trigger a blocking trust prompt (e.g. after re-signing the app); doing it on the launch/main
    /// thread would stall the app. Until this finishes, sealed credentials simply show the
    /// masked placeholder. Merges by id and only touches the credential fields, so a clip captured (or an item
    /// pinned/deleted) during the brief window is not clobbered.
    private func decryptCredentialsInBackground() {
        let snapshot = items
        guard !snapshot.isEmpty else { return }
        Task.detached(priority: .userInitiated) {
            let decrypted = Storage.shared.decryptCredentials(snapshot)
            let byId = Dictionary(decrypted.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            // Was any legacy cleartext secret flagged? If so, its plaintext must be persisted (sealed) —
            // pre-create the encryption key HERE (off the main thread) so the saveItems on the main thread below never runs a
            // Keychain WRITE (SecItemAdd) on the main thread.
            let snapById = Dictionary(snapshot.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let promoted = decrypted.contains { d in snapById[d.id]?.isCredential != true && d.isCredential == true }
            if promoted { CredentialCrypto.warmKey() }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.items = self.items.map { cur in
                    guard let d = byId[cur.id], let snap = snapById[cur.id] else { return cur }
                    // Skip if the user edited this item during the off-main window (toggled credential,
                    // re-copied, renamed…): apply the decryption ONLY when it still matches the
                    // pre-decryption snapshot, so we never silently revert the user's change.
                    guard cur.text == snap.text, cur.isCredential == snap.isCredential, cur.preview == snap.preview else { return cur }
                    guard cur.text != d.text || cur.isCredential != d.isCredential || cur.preview != d.preview else { return cur }
                    var c = cur
                    c.text = d.text; c.isCredential = d.isCredential; c.preview = d.preview
                    return c
                }
                // Only re-save for legacy promotions; a plain sealed→plaintext decryption is in-memory only
                // (the sealed form on disk is already correct), so don't rewrite items.json on every launch.
                // The key was pre-warmed off the main thread above, so seal() here only reads the key (fast, no prompt).
                if promoted { self.storage.saveItems(self.items) }
            }
        }
    }

    func start() {
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }   // runs on RunLoop.main; we assert it for the compiler
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Pauses pasteboard monitoring (e.g. during an import: avoids writing to the same
    /// directory as the background import). Call on the main thread.
    func pauseMonitoring() { timer?.invalidate(); timer = nil }

    /// Resumes monitoring. Re-anchors lastChangeCount so anything copied during the pause is not captured.
    func resumeMonitoring() {
        guard timer == nil else { return }
        lastChangeCount = NSPasteboard.general.changeCount
        start()
    }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount
        let source = currentSource()                // source BEFORE the filter (focus can change)
        guard !shouldIgnore(pb) else { return }
        capture(from: pb, source: source)
    }

    private func currentSource() -> CaptureSource {
        // Disabled: attributing the "source" to the frontmost app at poll time was unreliable
        // (it flagged the wrong active app, e.g. whichever had focus 0.5s later).
        CaptureSource(name: nil, bundleID: nil)
    }

    // MARK: - Privacy filter

    private func shouldIgnore(_ pb: NSPasteboard) -> Bool {
        hasPrivacyMarker(pb) || isFrontmostAppExcluded()
    }

    private func hasPrivacyMarker(_ pb: NSPasteboard) -> Bool {
        guard let types = pb.types else { return false }
        let s = Set(types)
        if settings.ignoreConcealed     && s.contains(PasteboardPrivacyTypes.concealed)     { return true }
        if settings.ignoreTransient     && s.contains(PasteboardPrivacyTypes.transient)     { return true }
        if settings.ignoreAutoGenerated && s.contains(PasteboardPrivacyTypes.autoGenerated) { return true }
        return false
    }

    private func isFrontmostAppExcluded() -> Bool {
        guard let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
        if id == ownBundleID { return false }
        return settings.excludedBundleIDs.contains(id)
    }

    // MARK: - Capture

    private func capture(from pb: NSPasteboard, source: CaptureSource) {
        let remote = settings.detectRemoteSource
            && RemoteClipboardHeuristic.looksRemote(pb: pb, source: source,
                                                    captureSourceEnabled: settings.captureSource)
        // A Finder file copy (and some rich copies) carries BOTH a thumbnail and the file's URL/text.
        // Prefer the text/URL so we don't lose it by storing the thumbnail as the content.
        let trimmedString = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if (trimmedString?.isEmpty ?? true),
           let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            addText(urls.map { $0.isFileURL ? $0.path : $0.absoluteString }.joined(separator: "\n"),
                    source: source, remote: remote); return
        }
        if let str = trimmedString, !str.isEmpty {
            let raw = pb.string(forType: .string) ?? str
            // "Always paste clean": if the copy carries rich text, store a clean Markdown version that keeps
            // bold/italics + emojis but drops dark background / colors / fonts. Plain copies are unaffected.
            // Use the cleaned version only if it produced real content — an empty/blank result (e.g. an
            // image-only RTF) must NOT replace the user's plain text.
            let cleaned = settings.cleanCapture ? RichText.cleanMarkdown(from: pb) : nil
            let text = (cleaned?.isEmpty == false) ? cleaned! : raw
            addText(text, source: source, remote: remote); return
        }
        if hasImageData(pb), let image = NSImage(pasteboard: pb) {
            addImage(image, source: source, remote: remote)
        }
    }

    private func hasImageData(_ pb: NSPasteboard) -> Bool {
        guard let types = pb.types else { return false }
        if types.contains(.tiff) || types.contains(.png)
            || types.contains(NSPasteboard.PasteboardType("public.jpeg")) { return true }
        // Accept anything NSImage can actually decode (HEIC, GIF, WebP, …) instead of silently discarding it.
        let readable = Set(NSImage.imageTypes)
        return types.contains { readable.contains($0.rawValue) }
    }

    private func addText(_ text: String, source: CaptureSource, remote: Bool) {
        if let idx = items.firstIndex(where: { $0.kind == .text && $0.isVoiceNote != true && $0.text == text }) {
            var item = items.remove(at: idx)
            item.createdAt = Date()
            item.sourceName = source.name           // refresh the source with the new capture
            item.sourceBundleID = source.bundleID
            item.isRemote = remote ? true : nil
            // Re-evaluate credential status on re-copy so a re-copied secret gets masked again (don't keep
            // showing, in cleartext in the preview, a secret that previously went unflagged).
            let isCred = CredentialDetector.looksLikeCredential(text)
            item.isCredential = isCred ? true : nil
            item.preview = isCred ? CredentialDetector.maskedPlaceholder
                : String(text.prefix(160)).replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            items.insert(item, at: 0)
        } else {
            let isCred = CredentialDetector.looksLikeCredential(text)
            let preview = isCred
                ? CredentialDetector.maskedPlaceholder   // constant placeholder: never persist characters derived from the secret (the row shows masked(text) live)
                : String(text.prefix(160)).replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            items.insert(ClipboardItem(kind: .text, text: text, preview: preview,
                                       sourceName: source.name, sourceBundleID: source.bundleID,
                                       isRemote: remote ? true : nil,
                                       isCredential: isCred ? true : nil), at: 0)
        }
        trimAndSave()
    }

    private func addImage(_ image: NSImage, source: CaptureSource, remote: Bool) {
        let fileName = "\(UUID().uuidString).png"
        guard storage.saveImage(image, fileName: fileName) != nil else { return }   // don't add a ghost row if the file wasn't saved
        let size = image.pixelDimensions
        let preview = String(format: L10n.t("preview.image"), Int(size.width), Int(size.height))
        items.insert(ClipboardItem(kind: .image, imageFileName: fileName, preview: preview,
                                   sourceName: source.name, sourceBundleID: source.bundleID,
                                   isRemote: remote ? true : nil), at: 0)
        trimAndSave()
    }

    /// Inserts an annotated capture (Klip Snap) into the persistent history and optionally leaves it
    /// on the pasteboard. Public counterpart of `addImage`, but for images generated by the app
    /// (not captured from the pasteboard). Available to OCR and search like any other image.
    @discardableResult
    func addAnnotatedScreenshot(_ image: NSImage, copyToClipboard: Bool = true) -> UUID {
        let fileName = "\(UUID().uuidString).png"
        let size = image.pixelDimensions   // real pixels (not points): consistent badge on Retina
        let preview = String(format: L10n.t("preview.capture"), Int(size.width), Int(size.height))
        let item = ClipboardItem(kind: .image, imageFileName: fileName, preview: preview)
        if storage.saveImage(image, fileName: fileName) != nil {
            items.insert(item, at: 0)   // only add a history row if the file was actually saved
            trimAndSave()
        } else {
            NSSound.beep()
        }
        if copyToClipboard {            // still deliver the image to the clipboard even if saving failed
            let pb = NSPasteboard.general
            pb.clearContents(); pb.writeObjects([image])
            lastChangeCount = pb.changeCount   // already handled here: don't re-capture it as a new item
        }
        return item.id
    }

    // MARK: - Voice notes (saved audio + 3-step transcription)

    static var voiceTranscribing: String { "🎙 " + L10n.t("voice.transcribing") }
    static var voiceFailed: String { "🎙 " + L10n.t("voice.failed") }
    static var voiceFailedNoAudio: String { "🎙 " + L10n.t("voice.failedNoAudio") }

    private static func voicePreview(_ clean: String) -> String {
        "🎙 " + String(clean.prefix(160))
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Pasteboard changeCount when each note starts: we only auto-paste its transcription if the
    /// user did NOT copy anything else while it was transcribing (don't clobber their pasteboard in the background).
    private var voicePasteGuards: [UUID: Int] = [:]

    /// Creates the voice-note item with its audio ("Transcribing…" placeholder) and returns its id.
    @discardableResult
    func beginVoiceNote(audioFileName: String?, duration: Double?, allowAutoCopy: Bool = true) -> UUID {
        let item = ClipboardItem(kind: .text, preview: Self.voiceTranscribing,
                                 isVoiceNote: true, transcribing: true,
                                 audioFileName: audioFileName, audioDuration: duration)
        items.insert(item, at: 0)
        // No guard registered → finishVoiceNote won't auto-copy (multi-file uploads: each finished file
        // would silently rewrite the clipboard).
        if allowAutoCopy { voicePasteGuards[item.id] = NSPasteboard.general.changeCount }
        trimAndSave()
        return item.id
    }

    /// Fills in a voice note's audio duration once it's read off the main thread. In-memory only — the
    /// imminent transcription result (finishVoiceNote/failVoiceNote) persists it, so no extra save here.
    func setVoiceNoteDuration(id: UUID, duration: Double) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].audioDuration = duration
    }

    /// Attaches the saved audio file to a voice note after the fact (an audio-only upload that arrived in a
    /// video-typed container and was saved once confirmed not to be a real video). Keeps it playable/retryable.
    func setVoiceNoteAudioFile(id: UUID, fileName: String) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].audioFileName = fileName
        // Persist NOW: if the app quits mid-transcription, reconcileVoiceNotesOnLoad would discard
        // a "transcribing" note without audioFileName and pruneOrphans would delete the just-imported audio.
        storage.saveItems(items)
    }

    /// Marks an item as "Transcribing…" again (retry of a failed note).
    func markVoiceNoteTranscribing(id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].text = nil
        items[idx].preview = Self.voiceTranscribing
        items[idx].transcribing = true
        // Re-register the pasteboard guard: otherwise a successful retry would never auto-paste
        // (removeValue would return nil → canPaste=false). Auto-paste on retries was dead.
        voicePasteGuards[id] = NSPasteboard.general.changeCount
        storage.saveItems(items)
    }

    static var voiceDownloading: String { "🎙 " + L10n.t("voice.downloading") }

    /// First use on the device: the model is still downloading. Show that instead of the generic "Transcribing…".
    func markVoiceNoteDownloadingModel(id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].preview = Self.voiceDownloading
        storage.saveItems(items)
    }

    /// Fills in the transcription. Only leaves it on the pasteboard if the user did NOT copy something else
    /// while it was transcribing (avoids clobbering their pasteboard in the background).
    func finishVoiceNote(id: UUID, text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let canPaste = voicePasteGuards.removeValue(forKey: id).map { $0 == NSPasteboard.general.changeCount } ?? false
        guard let idx = items.firstIndex(where: { $0.id == id }) else {
            // The item no longer exists: the user deleted it (or it was replaced by an import). Don't touch their
            // pasteboard with the transcription of a note they intentionally removed.
            return
        }
        // A dictated/transcribed secret must go through the same mask + seal-on-save path as a
        // copied one — otherwise it would persist in cleartext (text + preview) and auto-paste.
        let isCred = !clean.isEmpty && CredentialDetector.looksLikeCredential(clean)
        items[idx].text = clean.isEmpty ? nil : clean
        items[idx].isCredential = isCred ? true : nil
        items[idx].preview = clean.isEmpty ? Self.voiceFailed
                           : isCred ? CredentialDetector.maskedPlaceholder : Self.voicePreview(clean)
        items[idx].transcribing = false
        let item = items[idx]
        trimAndSave()
        if !clean.isEmpty, !isCred, canPaste {   // never auto-paste a detected secret
            copyToPasteboard(item)     // only if nothing changed the pasteboard
            rebaselineVoiceGuards()    // OUR own paste is not a user clobber: keep sibling notes auto-pasteable
            // The popup closed on stop and the user is waiting in another app: a soft cue says
            // "the transcript is on your clipboard now" without any window.
            NSSound(named: "Pop")?.play()
            ToastHUD.show(L10n.t("toast.transcriptCopied"), detail: clean)
        }
    }

    /// Re-anchors every still-pending voice-note paste guard to the pasteboard's current changeCount.
    /// Called right after THIS app pastes a finished note, so a second concurrent note
    /// is not falsely suppressed by our own write (changeCount is a single global counter).
    private func rebaselineVoiceGuards() {
        let cc = NSPasteboard.general.changeCount
        for id in voicePasteGuards.keys { voicePasteGuards[id] = cc }
    }

    /// Transcription failed: keeps the item visible (with playable audio if any) instead of
    /// silently deleting it, so the user knows what happened and can recover or remove it.
    func failVoiceNote(id: UUID) {
        voicePasteGuards.removeValue(forKey: id)
        NSSound.beep()   // the popup is long gone: without a cue the user pastes stale clipboard content
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].text = nil
        items[idx].transcribing = false
        items[idx].preview = items[idx].audioFileName != nil ? Self.voiceFailed : Self.voiceFailedNoAudio
        storage.saveItems(items)
    }

    /// Never trimmed: neither pinned items nor a voice note still transcribing (its audio/text would be lost).
    private func isProtectedFromTrim(_ it: ClipboardItem) -> Bool {
        it.pinned || (it.isVoiceNote == true && it.transcribing == true)
    }

    private func trimAndSave() {
        if items.count > maxItems {
            let keep = items.filter { isProtectedFromTrim($0) }
            var trimmable = items.filter { !isProtectedFromTrim($0) }
            let allowed = max(0, maxItems - keep.count)
            if trimmable.count > allowed {
                for it in trimmable[allowed...] {
                    if it.kind == .image, let f = it.imageFileName { storage.deleteImage(fileName: f) }
                    if let af = it.audioFileName { AudioPlayer.shared.stopIfPlaying(af); storage.deleteAudio(fileName: af) }
                }
                trimmable = Array(trimmable.prefix(allowed))
            }
            items = (keep + trimmable).sorted { $0.createdAt > $1.createdAt }
        }
        storage.saveItems(items)
    }

    func applyMaxItems() { trimAndSave() }

    // MARK: - Actions

    func copyToPasteboard(_ item: ClipboardItem) {
        defer { NotificationCenter.default.post(name: .klipDidCopy, object: nil) }
        let pb = NSPasteboard.general
        switch item.kind {
        case .text:
            guard let t = item.text, !t.isEmpty else { return }   // voice note without text: don't touch the pasteboard
            if item.isCredential == true, CredentialCrypto.isSealed(t) { return }   // undecryptable on this Mac: don't copy the raw token
            pb.clearContents(); pb.setString(t, forType: .string)
        case .image:
            guard let f = item.imageFileName, let img = storage.loadImage(fileName: f) else { return }
            pb.clearContents(); pb.writeObjects([img])
        }
        lastChangeCount = pb.changeCount
    }

    func setClipboardText(_ text: String) {
        defer { NotificationCenter.default.post(name: .klipDidCopy, object: nil) }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        lastChangeCount = pb.changeCount   // avoids re-capturing the Markdown/OCR output as a new item
    }

    /// Copies for an email body as RICH text (RTF): renders **bold**/*italics*/links and PRESERVES
    /// line breaks, so Mail/Gmail display it formatted instead of flat plain text. Headings/bullets are cleaned to plain/•.
    func copyForEmail(_ text: String) {
        defer { NotificationCenter.default.post(name: .klipDidCopy, object: nil) }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        var md = t.replacingOccurrences(of: "\r\n", with: "\n")
        md = md.replacingOccurrences(of: "(?m)^#{1,6}[ \\t]+", with: "", options: .regularExpression)          // headings → plain
        md = md.replacingOccurrences(of: "(?m)^[ \\t]*[-*+•◦][ \\t]+", with: "• ", options: .regularExpression) // bullets (incl. tab-indented bullets) → "• "
        md = restoreParagraphSpacing(md)   // the rich→text capture flattens blank lines; restore a blank line between prose paragraphs
        let pb = NSPasteboard.general
        pb.clearContents()
        // inlineOnlyPreservingWhitespace renders emphasis/links but keeps every line break (no paragraph collapsing).
        if let parsed = try? NSAttributedString(markdown: md, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            // The parser marks bold/italics as `inlinePresentationIntent` (semantic), which RTF ignores —
            // turn it into a real bold/italic FONT so Mail/Gmail actually render it.
            let attr = NSMutableAttributedString(attributedString: parsed)
            let full = NSRange(location: 0, length: attr.length)
            attr.addAttribute(.font, value: NSFont.systemFont(ofSize: 13), range: full)
            attr.enumerateAttribute(.inlinePresentationIntent, in: full) { value, range, _ in
                guard let raw = (value as? NSNumber)?.uintValue else { return }
                let intent = InlinePresentationIntent(rawValue: raw)
                var f = NSFont.systemFont(ofSize: 13)
                if intent.contains(.stronglyEmphasized) { f = NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask) }
                if intent.contains(.emphasized) { f = NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask) }
                attr.addAttribute(.font, value: f, range: range)
            }
            if let rtf = try? attr.data(from: full, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
                pb.setData(rtf, forType: .rtf)
                pb.setString(attr.string, forType: .string)   // plain fallback for apps that ignore RTF
            } else {
                pb.setString(attr.string, forType: .string)
            }
        } else {
            pb.setString(Markdownify.toEmail(t), forType: .string)
        }
        lastChangeCount = pb.changeCount   // our own write — don't re-capture it
    }

    /// Rich-text capture flattens paragraph spacing to single line breaks. Restore a blank line BETWEEN
    /// prose lines (so the email isn't one dense block), keeping a bullet list compact and adding no
    /// blank line where one already exists.
    private func restoreParagraphSpacing(_ md: String) -> String {
        let lines = md.components(separatedBy: "\n")
        func isBullet(_ s: String) -> Bool { s.hasPrefix("• ") }
        var out = ""
        for (i, line) in lines.enumerated() {
            if i > 0 {
                let prev = lines[i - 1].trimmingCharacters(in: .whitespaces)
                let curr = line.trimmingCharacters(in: .whitespaces)
                let tight = prev.isEmpty || curr.isEmpty || (isBullet(prev) && isBullet(curr))
                out += tight ? "\n" : "\n\n"
            }
            out += line
        }
        return out
    }

    /// Result of the OCR text capture: put it on the clipboard (ready to paste) AND add it to the history. Returns
    /// false if there was nothing to add (empty OCR).
    @discardableResult
    func addCapturedText(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        setClipboardText(t)   // ready to paste; this also bumps lastChangeCount so the poll doesn't add it twice
        addText(t, source: CaptureSource(name: nil, bundleID: nil), remote: false)
        return true
    }

    func delete(_ item: ClipboardItem) {
        if item.kind == .image, let f = item.imageFileName { storage.deleteImage(fileName: f) }
        if let af = item.audioFileName { AudioPlayer.shared.stopIfPlaying(af); storage.deleteAudio(fileName: af) }
        voicePasteGuards.removeValue(forKey: item.id)
        items.removeAll { $0.id == item.id }
        storage.saveItems(items)
    }

    /// Replaces the in-memory history after importing a backup.
    /// True while at least one voice note is still transcribing in the background.
    var hasActiveTranscription: Bool { items.contains { $0.transcribing == true } }

    func reload(_ newItems: [ClipboardItem]) {
        AudioPlayer.shared.stop()
        voicePasteGuards.removeAll()   // old ids vanish after a reload/import: don't paste a stale transcription
        items = newItems
        storage.saveItems(items)
    }

    func clearAll() {
        AudioPlayer.shared.stop()
        voicePasteGuards.removeAll()
        for it in items {
            if it.kind == .image, let f = it.imageFileName { storage.deleteImage(fileName: f) }
            if let af = it.audioFileName { storage.deleteAudio(fileName: af) }
        }
        items.removeAll()
        storage.saveItems(items)
    }

    func togglePin(_ item: ClipboardItem) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[idx].pinned.toggle()
        trimAndSave()   // re-evaluate trimming on unpin (it may exceed maxItems)
    }

    // MARK: - Collections (vibe coders)

    /// Assigns (or clears, with an empty name) a collection for several items.
    func assignCollection(_ ids: Set<UUID>, to name: String?) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (trimmed?.isEmpty ?? true) ? nil : trimmed
        for idx in items.indices where ids.contains(items[idx].id) { items[idx].collection = value }
        storage.saveItems(items)
    }

    /// Names of the existing collections (for the filters).
    var collections: [String] { Array(Set(items.compactMap { $0.collection })).sorted() }

    /// Sets (or clears) an item's label/name. The name is searchable and shown as the title.
    func rename(_ item: ClipboardItem, to name: String) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        items[idx].name = trimmed.isEmpty ? nil : trimmed
        storage.saveItems(items)
    }

    /// Marks or unmarks an item as a credential (mini manager).
    func toggleCredential(_ item: ClipboardItem) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        if let t = items[idx].text, CredentialCrypto.isSealed(t) {
            // Sealed-but-undecryptable on this Mac (encrypted on another machine): the "text" is ciphertext,
            // not the secret. Don't let unmarking dump the raw klipenc1: token into the preview — keep it as a
            // credential with the constant placeholder.
            items[idx].isCredential = true
            items[idx].preview = CredentialDetector.maskedPlaceholder
            storage.saveItems(items)
            return
        }
        let nowCred = !(items[idx].isCredential == true)
        items[idx].isCredential = nowCred ? true : nil
        if let t = items[idx].text {   // regenerate the preview (mask / unmask)
            items[idx].preview = nowCred
                ? CredentialDetector.maskedPlaceholder   // constant: the row computes masked(text) live
                : String(t.prefix(160)).replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        }
        storage.saveItems(items)
    }
}

/// Best-effort heuristic for "another device" (there is NO reliable public Universal Clipboard API).
enum RemoteClipboardHeuristic {
    static func looksRemote(pb: NSPasteboard, source: CaptureSource, captureSourceEnabled: Bool) -> Bool {
        // We only flag "another device" when Apple's reliable marker is present.
        // The "no source app" heuristic produced false positives (SecurityAgent, helpers…);
        // it was removed: better NOT to flag than to flag wrongly.
        pb.types?.contains(where: { $0.rawValue == "com.apple.is-remote-clipboard" }) == true
    }
}

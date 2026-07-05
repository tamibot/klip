import AppKit
import Combine

/// Snapshot of the source taken at the start of poll().
struct CaptureSource {
    let name: String?
    let bundleID: String?
}

/// Monitors the pasteboard, maintains the history, and exposes actions.
/// @MainActor: all state (items, voicePasteGuards…) is driven by the main-RunLoop poll and SwiftUI, so the
/// main-thread requirement is compiler-enforced rather than by convention.
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
                                         // launch/main thread (that can raise a blocking trust prompt → hang)
        decryptCredentialsInBackground() // decrypt off-main, then merge the plaintext back in
        reconcileVoiceNotesOnLoad()
        // Clean up orphans (audio/images with no item, e.g. after quitting mid-transcription).
        // Only if there are items: an empty items array also happens when items.json is corrupt/unreadable, and in
        // that case sweeping would delete ALL the media (we avoid that loss; the files stay there for recovery).
        if !items.isEmpty {
            storage.pruneOrphans(
                referencedAudio: Set(items.compactMap { $0.audioFileName }),
                referencedImages: Set(items.compactMap { $0.imageFileName }))
        }
    }

    /// Repairs voice notes left in "Transcribiendo…" (the app was closed during transcription):
    /// if they still have their audio, they move to "no transcription" (recoverable); otherwise they are discarded.
    private func reconcileVoiceNotesOnLoad() {
        var changed = false
        for idx in items.indices where items[idx].isVoiceNote == true && items[idx].transcribing == true {
            if let af = items[idx].audioFileName, storage.audioExists(fileName: af) {
                items[idx].text = nil
                items[idx].preview = Self.voiceFailed
                items[idx].transcribing = false   // recoverable: no longer "in progress"
            } else {
                items[idx].audioFileName = nil     // mark for removal (keeps transcribing == true)
            }
            changed = true
        }
        let before = items.count
        items.removeAll { $0.isVoiceNote == true && $0.transcribing == true && $0.audioFileName == nil }
        if changed || items.count != before { storage.saveItems(items) }
    }

    /// Decrypts sealed credentials OFF the main thread, then merges the plaintext back in. Keychain access
    /// can raise a blocking trust prompt (e.g. after the app is re-signed); doing it on the launch/main
    /// thread would wedge the app. Until this completes, sealed credentials simply show the masked
    /// placeholder. Merges by id and only touches credential fields, so a clip captured (or an item
    /// pinned/deleted) during the brief window is not clobbered.
    private func decryptCredentialsInBackground() {
        let snapshot = items
        guard !snapshot.isEmpty else { return }
        Task.detached(priority: .userInitiated) {
            let decrypted = Storage.shared.decryptCredentials(snapshot)
            let byId = Dictionary(decrypted.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            // Did any legacy cleartext secret get flagged? If so its plaintext must be persisted (sealed) —
            // pre-create the encryption key HERE (off-main) so the on-main saveItems below never runs a
            // Keychain WRITE (SecItemAdd) on the main thread.
            let snapById = Dictionary(snapshot.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let promoted = decrypted.contains { d in snapById[d.id]?.isCredential != true && d.isCredential == true }
            if promoted { CredentialCrypto.warmKey() }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.items = self.items.map { cur in
                    guard let d = byId[cur.id], let snap = snapById[cur.id] else { return cur }
                    // Skip if the user edited this item during the off-main window (toggled credential,
                    // re-copied, renamed…): apply the decrypt ONLY when it still matches the pre-decrypt
                    // snapshot, so we never silently revert the user's change.
                    guard cur.text == snap.text, cur.isCredential == snap.isCredential, cur.preview == snap.preview else { return cur }
                    guard cur.text != d.text || cur.isCredential != d.isCredential || cur.preview != d.preview else { return cur }
                    var c = cur
                    c.text = d.text; c.isCredential = d.isCredential; c.preview = d.preview
                    return c
                }
                // Only re-save for legacy promotions; a plain sealed→plaintext decrypt is in-memory only
                // (the on-disk sealed form is already correct), so don't rewrite items.json every launch.
                // The key was warmed off-main above, so seal() here only reads the key (fast, no prompt).
                if promoted { self.storage.saveItems(self.items) }
            }
        }
    }

    func start() {
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }   // runs on RunLoop.main; assert it for the compiler
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
        let source = currentSource()                // source BEFORE the gate (focus may change)
        guard !shouldIgnore(pb) else { return }
        capture(from: pb, source: source)
    }

    private func currentSource() -> CaptureSource {
        // Disabled: attributing the "source" to the frontmost app at poll time was unreliable
        // (it marked the wrong active app, e.g. the one that had focus 0.5s later).
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
        // A Finder file copy (and some rich copies) carry BOTH a thumbnail image and the file URL/text.
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
            // bold/italic + emojis but drops dark background / colours / fonts. Plain copies are unaffected.
            // Use the clean version only if it produced real content — an empty/blank result (e.g. a
            // picture-only RTF) must NOT replace the user's plain text.
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
        // Accept anything NSImage can actually decode (HEIC, GIF, WebP, …) instead of silently dropping it.
        let readable = Set(NSImage.imageTypes)
        return types.contains { readable.contains($0.rawValue) }
    }

    private func addText(_ text: String, source: CaptureSource, remote: Bool) {
        if let idx = items.firstIndex(where: { $0.kind == .text && $0.isVoiceNote != true && $0.text == text }) {
            var item = items.remove(at: idx)
            item.createdAt = Date()
            item.sourceName = source.name           // refresh source with the new capture
            item.sourceBundleID = source.bundleID
            item.isRemote = remote ? true : nil
            // Re-evaluate credential state on re-copy so a re-copied secret is masked again (don't keep
            // showing a previously-unmarked secret in cleartext in the preview).
            let isCred = CredentialDetector.looksLikeCredential(text)
            item.isCredential = isCred ? true : nil
            item.preview = isCred ? CredentialDetector.maskedPlaceholder
                : String(text.prefix(160)).replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            items.insert(item, at: 0)
        } else {
            let isCred = CredentialDetector.looksLikeCredential(text)
            let preview = isCred
                ? CredentialDetector.maskedPlaceholder   // constant placeholder: never persist secret-derived chars (the row shows masked(text) live)
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
        guard storage.saveImage(image, fileName: fileName) != nil else { return }   // don't add a phantom row if the file didn't save
        let size = image.pixelDimensions
        let preview = String(format: L10n.t("preview.image"), Int(size.width), Int(size.height))
        items.insert(ClipboardItem(kind: .image, imageFileName: fileName, preview: preview,
                                   sourceName: source.name, sourceBundleID: source.bundleID,
                                   isRemote: remote ? true : nil), at: 0)
        trimAndSave()
    }

    /// Inserts an annotated screenshot (Klip Snap) into the persistent history and, optionally, leaves it
    /// on the pasteboard. Public counterpart to `addImage`, but for images generated by the app
    /// (not captured from the pasteboard). It becomes available for OCR and search like any other image.
    @discardableResult
    func addAnnotatedScreenshot(_ image: NSImage, copyToClipboard: Bool = true) -> UUID {
        let fileName = "\(UUID().uuidString).png"
        let size = image.pixelDimensions   // real pixels (not points): consistent badge on Retina
        let preview = String(format: L10n.t("preview.capture"), Int(size.width), Int(size.height))
        let item = ClipboardItem(kind: .image, imageFileName: fileName, preview: preview)
        if storage.saveImage(image, fileName: fileName) != nil {
            items.insert(item, at: 0)   // only add a history row if the file actually saved
            trimAndSave()
        } else {
            NSSound.beep()
        }
        if copyToClipboard {            // still hand the image to the clipboard even if saving failed
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

    /// Creates the voice note item with its audio (placeholder "Transcribiendo…") and returns its id.
    @discardableResult
    func beginVoiceNote(audioFileName: String?, duration: Double?) -> UUID {
        let item = ClipboardItem(kind: .text, preview: Self.voiceTranscribing,
                                 isVoiceNote: true, transcribing: true,
                                 audioFileName: audioFileName, audioDuration: duration)
        items.insert(item, at: 0)
        voicePasteGuards[item.id] = NSPasteboard.general.changeCount
        trimAndSave()
        return item.id
    }

    /// Fills in a voice note's audio duration once it's been read off-thread. In-memory only — the
    /// imminent transcription result (finishVoiceNote/failVoiceNote) persists it, so no extra save here.
    func setVoiceNoteDuration(id: UUID, duration: Double) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].audioDuration = duration
    }

    /// Attaches the saved audio file to a voice note after the fact (an audio-only upload that arrived in a
    /// movie-typed container and was stored once we confirmed it wasn't a real video). Keeps it playable/retryable.
    func setVoiceNoteAudioFile(id: UUID, fileName: String) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].audioFileName = fileName
    }

    /// Marks an item as "Transcribiendo…" again (retry of a failed note).
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

    /// First on-device use: the model is still downloading. Show that instead of the generic "Transcribing…".
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
            // The item no longer exists: the user deleted it (or it was replaced on import). Don't touch their
            // pasteboard with the transcription of a note they intentionally removed.
            return
        }
        // A dictated/transcribed secret must go through the same masking + seal-on-save path as a copied
        // one — otherwise it would persist in cleartext (text + preview) and auto-paste.
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
            rebaselineVoiceGuards()    // OUR own paste isn't a user clobber: keep sibling notes auto-pasteable
        }
    }

    /// Re-anchors every still-pending voice-note paste guard to the current pasteboard changeCount.
    /// Called right after THIS app pastes a finished note, so a second concurrent note isn't falsely
    /// suppressed by our own write (changeCount is a single global counter).
    private func rebaselineVoiceGuards() {
        let cc = NSPasteboard.general.changeCount
        for id in voicePasteGuards.keys { voicePasteGuards[id] = cc }
    }

    /// Transcription failed: keeps the item visible (with playable audio if any) instead of
    /// deleting it silently, so the user knows what happened and can recover or remove it.
    func failVoiceNote(id: UUID) {
        voicePasteGuards.removeValue(forKey: id)
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].text = nil
        items[idx].transcribing = false
        items[idx].preview = items[idx].audioFileName != nil ? Self.voiceFailed : Self.voiceFailedNoAudio
        storage.saveItems(items)
    }

    /// Not trimmed: neither pinned items nor a voice note still being transcribed (its audio/text would be lost).
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
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        lastChangeCount = pb.changeCount   // avoids re-capturing the Markdown/OCR output as a new item
    }

    /// Copy for an email body as RICH text (RTF): renders **bold**/*italic*/links and KEEPS the line breaks,
    /// so Mail/Gmail show it formatted instead of flat plain text. Headers/bullets are cleaned to plain/•.
    func copyForEmail(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        var md = t.replacingOccurrences(of: "\r\n", with: "\n")
        md = md.replacingOccurrences(of: "(?m)^#{1,6}[ \\t]+", with: "", options: .regularExpression)          // headers → plain
        md = md.replacingOccurrences(of: "(?m)^[ \\t]*[-*+•◦][ \\t]+", with: "• ", options: .regularExpression) // bullets (incl. tab-bullets) → "• "
        md = restoreParagraphSpacing(md)   // rich→text capture flattens blank lines; put a blank line back between prose paragraphs
        let pb = NSPasteboard.general
        pb.clearContents()
        // inlineOnlyPreservingWhitespace renders emphasis/links but keeps every newline (no paragraph collapse).
        if let parsed = try? NSAttributedString(markdown: md, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            // The parser marks bold/italic as `inlinePresentationIntent` (semantic), which RTF ignores —
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

    /// Rich-text capture flattens paragraph spacing to single newlines. Put a blank line back BETWEEN prose
    /// lines (so the email isn't one dense block), while keeping a bullet list tight and not adding blanks
    /// where one already exists.
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

    /// OCR text-capture result: put it on the clipboard (ready to paste) AND add it to history. Returns
    /// false if there was nothing to add (empty OCR).
    @discardableResult
    func addCapturedText(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        setClipboardText(t)   // ready to paste; this also bumps lastChangeCount so the poll won't double-add it
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
    /// True while at least one voice note is still being transcribed in the background.
    var hasActiveTranscription: Bool { items.contains { $0.transcribing == true } }

    func reload(_ newItems: [ClipboardItem]) {
        AudioPlayer.shared.stop()
        voicePasteGuards.removeAll()   // old ids are gone after a reload/import: don't paste a stale transcription
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
        trimAndSave()   // re-evaluate trimming when unpinning (may exceed maxItems)
    }

    // MARK: - Collections (vibe coders)

    /// Assigns (or clears, with an empty name) a collection to several items.
    func assignCollection(_ ids: Set<UUID>, to name: String?) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (trimmed?.isEmpty ?? true) ? nil : trimmed
        for idx in items.indices where ids.contains(items[idx].id) { items[idx].collection = value }
        storage.saveItems(items)
    }

    /// Names of existing collections (for the filters).
    var collections: [String] { Array(Set(items.compactMap { $0.collection })).sorted() }

    /// Sets (or clears) an item's label/name. The name is searchable and is shown as the title.
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
            // not the secret. Don't let unmarking echo the raw klipenc1: token into the preview — keep it a
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
        // We only mark "another device" if Apple's reliable marker is present.
        // The "no source app" heuristic produced false positives (SecurityAgent, helpers…);
        // it's removed: we'd rather NOT mark than mark incorrectly.
        pb.types?.contains(where: { $0.rawValue == "com.apple.is-remote-clipboard" }) == true
    }
}
